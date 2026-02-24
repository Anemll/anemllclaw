#if os(iOS) || os(tvOS)
import OpenClawGatewayCore
import SwiftUI
#if os(iOS)
import AuthenticationServices
import Network
import UIKit
#endif

#if os(iOS)
private final class OpenAIOAuthPresentationContextProvider: NSObject, ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for _: ASWebAuthenticationSession) -> ASPresentationAnchor {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        for scene in scenes {
            if let keyWindow = scene.windows.first(where: \.isKeyWindow) {
                return keyWindow
            }
        }
        return ASPresentationAnchor()
    }
}

private enum OpenAIOAuthLoopbackServerError: LocalizedError, Equatable {
    case invalidPort
    case listenerFailed(String)
    case timedOut
    case canceled

    var errorDescription: String? {
        switch self {
        case .invalidPort:
            "OpenAI OAuth callback listener failed to bind localhost:1455."
        case let .listenerFailed(reason):
            "OpenAI OAuth callback listener failed: \(reason)"
        case .timedOut:
            "OpenAI OAuth callback timed out waiting for localhost redirect."
        case .canceled:
            "OpenAI OAuth callback listener was canceled."
        }
    }
}

private final class OpenAIOAuthLoopbackCallbackServer {
    private let queue = DispatchQueue(label: "ai.openclaw.oauth.loopback")
    private let port: NWEndpoint.Port
    private let expectedPath: String
    private var listener: NWListener?
    private var continuation: CheckedContinuation<URL, Error>?
    private var result: Result<URL, Error>?
    private var timeoutWorkItem: DispatchWorkItem?

    init(port: UInt16 = 1455, expectedPath: String = "/auth/callback") throws {
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else {
            throw OpenAIOAuthLoopbackServerError.invalidPort
        }
        self.port = endpointPort
        self.expectedPath = expectedPath
    }

    func start() throws {
        let listener = try NWListener(using: .tcp, on: self.port)
        listener.stateUpdateHandler = { [weak self] state in
            self?.queue.async {
                self?.handleListenerState(state)
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection: connection)
        }
        self.listener = listener
        listener.start(queue: self.queue)
    }

    func waitForCallback(timeoutSeconds: TimeInterval = 180) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            self.queue.async {
                if let result = self.result {
                    continuation.resume(with: result)
                    return
                }
                self.continuation = continuation
                let timeout = DispatchWorkItem { [weak self] in
                    self?.finish(.failure(OpenAIOAuthLoopbackServerError.timedOut))
                }
                self.timeoutWorkItem = timeout
                self.queue.asyncAfter(deadline: .now() + timeoutSeconds, execute: timeout)
            }
        }
    }

    func stop() {
        self.queue.async {
            if self.result == nil {
                self.finish(.failure(OpenAIOAuthLoopbackServerError.canceled))
            } else {
                self.timeoutWorkItem?.cancel()
                self.timeoutWorkItem = nil
                self.listener?.cancel()
                self.listener = nil
            }
        }
    }

    private func handleListenerState(_ state: NWListener.State) {
        switch state {
        case let .failed(error):
            self.finish(.failure(OpenAIOAuthLoopbackServerError.listenerFailed(error.localizedDescription)))
        default:
            break
        }
    }

    private func handle(connection: NWConnection) {
        connection.start(queue: self.queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, _, _ in
            guard let self else {
                connection.cancel()
                return
            }
            guard let data,
                  let request = String(data: data, encoding: .utf8),
                  let callbackURL = self.extractCallbackURL(from: request)
            else {
                self.respond(
                    on: connection,
                    statusLine: "HTTP/1.1 404 Not Found",
                    body: "OpenAI OAuth callback path not found.")
                return
            }

            self.respond(
                on: connection,
                statusLine: "HTTP/1.1 200 OK",
                body: "OpenAI OAuth complete. You can close this page and return to the app.")
            self.finish(.success(callbackURL))
        }
    }

    private func extractCallbackURL(from request: String) -> URL? {
        guard let firstLine = request.components(separatedBy: "\r\n").first else {
            return nil
        }
        let parts = firstLine.split(separator: " ")
        guard parts.count >= 2, parts[0].uppercased() == "GET" else {
            return nil
        }

        var target = String(parts[1])
        if let absolute = URL(string: target),
           let scheme = absolute.scheme,
           scheme == "http" || scheme == "https"
        {
            target = absolute.path
            if let query = absolute.query, !query.isEmpty {
                target += "?\(query)"
            }
        }

        guard target.hasPrefix(self.expectedPath) else {
            return nil
        }

        guard let callbackURL = URL(string: "http://localhost:\(self.port.rawValue)\(target)"),
              let components = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)
        else {
            return nil
        }
        let hasOAuthParams = (components.queryItems ?? []).contains { item in
            switch item.name {
            case "code", "state", "error":
                true
            default:
                false
            }
        }
        guard hasOAuthParams else {
            return nil
        }
        return callbackURL
    }

    private func respond(on connection: NWConnection, statusLine: String, body: String) {
        let html = """
        <html><head><meta charset="utf-8"></head><body>\(body)</body></html>
        """
        let payload = """
        \(statusLine)\r
        Content-Type: text/html; charset=utf-8\r
        Content-Length: \(html.utf8.count)\r
        Cache-Control: no-store\r
        Connection: close\r
        \r
        \(html)
        """
        connection.send(content: Data(payload.utf8), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func finish(_ result: Result<URL, Error>) {
        guard self.result == nil else { return }
        self.result = result
        self.timeoutWorkItem?.cancel()
        self.timeoutWorkItem = nil
        self.listener?.cancel()
        self.listener = nil
        if let continuation = self.continuation {
            self.continuation = nil
            continuation.resume(with: result)
        }
    }
}

extension OpenAIOAuthLoopbackCallbackServer: @unchecked Sendable {}
#endif

struct LLMProviderEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(TVOSLocalGatewayRuntime.self) private var localGatewayRuntime: TVOSLocalGatewayRuntime

    @State private var name: String
    @State private var provider: GatewayLocalLLMProviderKind
    @State private var baseURL: String
    @State private var apiKey: String
    @State private var model: String
    @State private var transport: GatewayLocalLLMTransport
    @State private var toolCallingMode: GatewayLocalLLMToolCallingMode
    @State private var authMode: SavedLLMProviderAuthMode
    @State private var oauthAccessExpiresAtMs: Int64?
    @State private var oauthAccountID: String
    @State private var oauthRefreshToken: String
    @State private var oauthAvailableModels: [String] = []
    @State private var oauthLoadingModels = false
    @State private var oauthSigningIn = false
    @State private var oauthStatusText: String?
    @State private var oauthStatusIsError = false

    @State private var isApplyingChanges = false
    @State private var statusText: String?
    @State private var statusIsError = false
    @State private var statusResponsePreview: String?
    @State private var operationStartedAt: Date?
    @State private var operationElapsedSeconds = 0
    @State private var operationIsTest = false
    @State private var progressTickerTask: Task<Void, Never>?
    @State private var saveOperationTask: Task<Void, Never>?
    @State private var operationToken = UUID()
    @State private var statusScrollTrigger = UUID()

    #if os(iOS)
    @State private var oauthAuthorizationContext: OpenAIOAuthSubAuthorizationContext?
    @State private var oauthSession: ASWebAuthenticationSession?
    @State private var oauthLoopbackServer: OpenAIOAuthLoopbackCallbackServer?
    @State private var oauthLoopbackTask: Task<Void, Never>?
    @State private var oauthCompletionHandled = false
    private let oauthPresentationContextProvider = OpenAIOAuthPresentationContextProvider()
    #endif

    private let providerID: String
    private let isNew: Bool
    private let onSave: @MainActor (SavedLLMProvider, Bool) async -> Void
    private static let statusSectionID = "llm-provider-editor-status"
    private static let statusCancelButtonID = "llm-provider-editor-status-cancel"

    init(
        provider: SavedLLMProvider,
        isNew: Bool,
        onSave: @escaping @MainActor (SavedLLMProvider, Bool) async -> Void)
    {
        self.providerID = provider.id
        self.isNew = isNew
        self._name = State(initialValue: provider.name)
        self._provider = State(initialValue: isNew ? .disabled : provider.provider)
        self._baseURL = State(initialValue: provider.baseURL)
        self._apiKey = State(initialValue: provider.apiKey)
        self._model = State(initialValue: provider.model)
        self._transport = State(initialValue: provider.transport)
        self._toolCallingMode = State(initialValue: provider.toolCallingMode)
        self._authMode = State(initialValue: provider.authMode)
        self._oauthAccessExpiresAtMs = State(initialValue: provider.oauthAccessExpiresAtMs)
        self._oauthAccountID = State(initialValue: provider.oauthAccountID)
        self._oauthRefreshToken = State(initialValue: provider.oauthRefreshToken)
        self.onSave = onSave
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                Form {
                    Section("Provider") {
                        TextField("Name (optional)", text: self.$name)
                            .textInputAutocapitalization(.words)

                        Picker("Type", selection: self.$provider) {
                            Text("None").tag(GatewayLocalLLMProviderKind.disabled)
                            Text("Grok-compatible").tag(GatewayLocalLLMProviderKind.grokCompatible)
                            Text("OpenAI-compatible").tag(GatewayLocalLLMProviderKind.openAICompatible)
                            Text("Anthropic-compatible").tag(GatewayLocalLLMProviderKind.anthropicCompatible)
                            Text("MiniMax-compatible").tag(GatewayLocalLLMProviderKind.minimaxCompatible)
                        }
                    }

                    Section("Connection") {
                        TextField("Base URL", text: self.$baseURL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)

                        if self.provider == .openAICompatible {
                            Picker("Auth", selection: self.$authMode) {
                                Text(SavedLLMProviderAuthMode.apiKey.displayLabel).tag(SavedLLMProviderAuthMode.apiKey)
                                Text(SavedLLMProviderAuthMode.openAIOAuthSub.displayLabel).tag(
                                    SavedLLMProviderAuthMode.openAIOAuthSub)
                            }
                        }

                        if self.provider != .openAICompatible || self.authMode == .apiKey {
                            SecureField("API Key", text: self.$apiKey)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                        } else {
                            self.openAIOAuthControls
                        }

                        if self.provider == .openAICompatible,
                           self.authMode == .openAIOAuthSub,
                           !self.oauthAvailableModels.isEmpty
                        {
                            Picker("Detected Model", selection: self.$model) {
                                ForEach(self.oauthAvailableModels, id: \.self) { id in
                                    Text(id).tag(id)
                                }
                            }
                        }

                        TextField("Model", text: self.$model)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        if self.provider == .openAICompatible, self.authMode == .openAIOAuthSub {
                            Text("Select from your OAuth model list, or enter a model ID manually.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }

                        Picker("Transport", selection: self.$transport) {
                            Text("HTTP").tag(GatewayLocalLLMTransport.http)
                            if self.provider == .openAICompatible {
                                Text("WebSocket (Experimental)").tag(GatewayLocalLLMTransport.websocket)
                            }
                        }
                        if self.provider == .openAICompatible {
                            Text(
                                "Recommended for lower latency on iterative chats. "
                                    + "OpenAI + WebSocket defaults Tool Calling to On.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        } else {
                            Text("WebSocket is currently available for OpenAI-compatible providers only.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }

                        Picker("Tool Calling", selection: self.$toolCallingMode) {
                            Text("Auto").tag(GatewayLocalLLMToolCallingMode.auto)
                            Text("On").tag(GatewayLocalLLMToolCallingMode.on)
                            Text("Off").tag(GatewayLocalLLMToolCallingMode.off)
                        }
                        Text(self.toolCallingMode.helpText)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

                    if !self.canSave {
                        Section {
                            Text(self.validationMessage)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }

                    if self.canSave {
                        Section {
                            Button {
                                self.applyAndOptionallyDismiss(test: false, dismissAfterSave: false)
                            } label: {
                                Label(
                                    "Save & Restart",
                                    systemImage: "arrow.clockwise")
                            }
                            .disabled(self.isApplyingChanges)

                            Button {
                                self.applyAndOptionallyDismiss(test: true, dismissAfterSave: false)
                            } label: {
                                Label(
                                    "Save, Restart & Test",
                                    systemImage: "arrow.clockwise.circle")
                            }
                            .disabled(self.isApplyingChanges)
                        }
                    }

                    if self.isApplyingChanges || self.statusText != nil {
                        Section("Status") {
                            if self.isApplyingChanges {
                                HStack(spacing: 8) {
                                    ProgressView()
                                        .progressViewStyle(.circular)
                                    Text(self.inFlightStatusText)
                                }
                                Button("Cancel", role: .destructive) {
                                    self.cancelCurrentOperation()
                                }
                                .id(Self.statusCancelButtonID)
                            }
                            if let statusText = self.statusText {
                                HStack(spacing: 8) {
                                    Image(systemName: self
                                        .statusIsError ? "xmark.circle.fill" : "checkmark.circle.fill")
                                        .foregroundStyle(self.statusIsError ? .red : .green)
                                    Text(statusText)
                                        .foregroundStyle(self.statusIsError ? .red : .primary)
                                }
                            }
                            if let preview = self.statusResponsePreview,
                               !preview.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            {
                                Text(preview)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(3)
                            }
                        }
                        .id(Self.statusSectionID)
                    }
                }
                .navigationTitle(self.isNew ? "Add Provider" : "Edit Provider")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") {
                            self.dismiss()
                        }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save & Exit") {
                            self.applyAndOptionallyDismiss(test: false, dismissAfterSave: true)
                        }
                        .disabled(!self.canSave || self.isApplyingChanges)
                    }
                }
                .onChange(of: self.provider) { _, newValue in
                    self.applyDefaults(for: newValue)
                    if newValue != .openAICompatible {
                        self.transport = .http
                        self.authMode = .apiKey
                        self.clearOAuthStatus()
                    } else if self.authMode == .openAIOAuthSub, self.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        self.prefillModelFromOAuthCatalog()
                    }
                }
                .onChange(of: self.transport) { _, newValue in
                    guard self.provider == .openAICompatible else { return }
                    guard newValue == .websocket else { return }
                    if self.toolCallingMode == .auto {
                        self.toolCallingMode = .on
                    }
                }
                .onChange(of: self.authMode) { _, newValue in
                    if self.provider != .openAICompatible, newValue != .apiKey {
                        self.authMode = .apiKey
                        return
                    }
                    self.clearOAuthStatus()
                    if newValue == .openAIOAuthSub {
                        self.applyOAuthSubscriptionDefaults()
                        self.prefillModelFromOAuthCatalog()
                    }
                }
                .onChange(of: self.statusScrollTrigger) { _, _ in
                    withAnimation(.easeInOut(duration: 0.2)) {
                        let targetID = self.isApplyingChanges
                            ? Self.statusCancelButtonID
                            : Self.statusSectionID
                        proxy.scrollTo(targetID, anchor: .center)
                    }
                }
                .onAppear {
                    if self.provider == .openAICompatible,
                       self.authMode == .openAIOAuthSub,
                       !self.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    {
                        Task { @MainActor in
                            await self.reloadOpenAIModelCatalog(force: false)
                        }
                    }
                }
                .onDisappear {
                    self.saveOperationTask?.cancel()
                    self.saveOperationTask = nil
                    self.stopProgressTicker()
                    #if os(iOS)
                    self.oauthSession?.cancel()
                    self.oauthSession = nil
                    self.oauthLoopbackTask?.cancel()
                    self.oauthLoopbackTask = nil
                    self.oauthLoopbackServer?.stop()
                    self.oauthLoopbackServer = nil
                    #endif
                }
            }
        }
    }

    private var openAIOAuthControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            #if os(iOS)
            Button {
                self.beginOpenAIOAuthSignIn()
            } label: {
                HStack(spacing: 8) {
                    if self.oauthSigningIn {
                        ProgressView()
                            .progressViewStyle(.circular)
                    }
                    Text(self.oauthSigningIn ? "Signing in…" : "Sign in with OpenAI (Web)")
                }
            }
            .disabled(self.oauthSigningIn || self.oauthLoadingModels)
            .buttonStyle(.borderedProminent)

            Button {
                Task { @MainActor in
                    await self.reloadOpenAIModelCatalog(force: true)
                }
            } label: {
                HStack(spacing: 8) {
                    if self.oauthLoadingModels {
                        ProgressView()
                            .progressViewStyle(.circular)
                    }
                    Text(self.oauthLoadingModels ? "Loading models…" : "Reload Model List")
                }
            }
            .disabled(self.oauthSigningIn || self.oauthLoadingModels || self.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .buttonStyle(.bordered)
            #else
            Text("OpenAI OAuth web sign-in is available on iOS.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            #endif

            if !self.oauthAccountID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text("Connected account: \(self.oauthAccountID)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if let expiry = self.oauthAccessExpiresAtMs {
                Text("Access token expires: \(self.formatTimestampMs(expiry))")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if let status = self.oauthStatusText,
               !status.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            {
                HStack(spacing: 8) {
                    Image(systemName: self.oauthStatusIsError ? "xmark.circle.fill" : "checkmark.circle.fill")
                        .foregroundStyle(self.oauthStatusIsError ? .red : .green)
                    Text(status)
                        .foregroundStyle(self.oauthStatusIsError ? .red : .secondary)
                        .font(.footnote)
                }
            }
        }
    }

    private var canSave: Bool {
        let hasModel = !self.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        guard hasModel else { return false }
        if self.provider == .openAICompatible, self.authMode == .openAIOAuthSub {
            return !self.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return true
    }

    private var validationMessage: String {
        if self.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Model is required."
        }
        if self.provider == .openAICompatible, self.authMode == .openAIOAuthSub {
            return "OpenAI OAuth sign-in is required."
        }
        return "Provider configuration is incomplete."
    }

    private var inFlightStatusText: String {
        let suffix = " \(self.operationElapsedSeconds)s"
        if self.operationIsTest {
            return "Running test…\(suffix)"
        }
        return "Applying changes…\(suffix)"
    }

    private func applyDefaults(for kind: GatewayLocalLLMProviderKind) {
        if self.baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let url = TVOSLocalGatewayRuntime.defaultLocalLLMBaseURL(for: kind)
        {
            self.baseURL = url
        }
        if self.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let m = TVOSLocalGatewayRuntime.defaultLocalLLMModel(for: kind)
        {
            self.model = m
        }
    }

    private func applyOAuthSubscriptionDefaults() {
        self.baseURL = OpenAIOAuthSubClient.subscriptionBaseURL
        if self.transport == .http {
            self.transport = .websocket
        }
        if self.toolCallingMode == .auto {
            self.toolCallingMode = .on
        }
    }

    private func clearOAuthStatus() {
        self.oauthStatusText = nil
        self.oauthStatusIsError = false
    }

    private func prefillModelFromOAuthCatalog() {
        guard self.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let preferred = OpenAIOAuthSubClient.preferredModelID(from: self.oauthAvailableModels)
        else {
            return
        }
        self.model = preferred
    }

    private func applyAndOptionallyDismiss(test: Bool, dismissAfterSave: Bool) {
        guard !self.isApplyingChanges else { return }
        guard self.canSave else { return }

        let token = UUID()
        self.operationToken = token
        self.isApplyingChanges = true
        self.statusText = nil
        self.statusIsError = false
        self.statusResponsePreview = nil
        self.startProgressTicker(isTest: test)
        self.statusScrollTrigger = UUID()

        let normalizedAuthMode: SavedLLMProviderAuthMode = if self.provider == .openAICompatible {
            self.authMode
        } else {
            .apiKey
        }
        let normalizedBaseURL: String = if self.provider == .openAICompatible,
            normalizedAuthMode == .openAIOAuthSub
        {
            OpenAIOAuthSubClient.subscriptionBaseURL
        } else {
            self.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        self.baseURL = normalizedBaseURL

        let saved = SavedLLMProvider(
            id: self.providerID,
            name: self.name.trimmingCharacters(in: .whitespacesAndNewlines),
            provider: self.provider,
            baseURL: normalizedBaseURL,
            apiKey: self.apiKey.trimmingCharacters(in: .whitespacesAndNewlines),
            model: self.model.trimmingCharacters(in: .whitespacesAndNewlines),
            toolCallingMode: self.toolCallingMode,
            transport: self.provider == .openAICompatible ? self.transport : .http,
            authMode: normalizedAuthMode,
            oauthAccessExpiresAtMs: normalizedAuthMode == .openAIOAuthSub ? self.oauthAccessExpiresAtMs : nil,
            oauthAccountID: normalizedAuthMode == .openAIOAuthSub
                ? self.oauthAccountID.trimmingCharacters(in: .whitespacesAndNewlines)
                : "",
            oauthRefreshToken: normalizedAuthMode == .openAIOAuthSub
                ? self.oauthRefreshToken.trimmingCharacters(in: .whitespacesAndNewlines)
                : "")

        let task = Task { @MainActor in
            defer {
                if self.operationToken == token {
                    self.saveOperationTask = nil
                    self.isApplyingChanges = false
                    self.stopProgressTicker()
                    if dismissAfterSave, !Task.isCancelled {
                        self.dismiss()
                    }
                }
            }

            await self.onSave(saved, test)
            guard self.operationToken == token, !Task.isCancelled else { return }

            if test {
                let passed = self.localGatewayRuntime.lastLocalLLMProbeSucceeded == true
                self.statusIsError = !passed
                if passed {
                    self.statusText = "Quick test passed."
                    self.statusResponsePreview = self.localGatewayRuntime.lastLocalLLMProbeResponseText
                } else {
                    self.statusText = self.localGatewayRuntime.lastLocalLLMProbeErrorText ?? "Quick test failed."
                    self.statusResponsePreview = nil
                }
            } else if !dismissAfterSave {
                self.statusText = "Saved and restarted."
                self.statusIsError = false
            }
            self.statusScrollTrigger = UUID()
        }
        self.saveOperationTask = task
    }

    private func startProgressTicker(isTest: Bool) {
        self.stopProgressTicker()
        self.operationIsTest = isTest
        self.operationStartedAt = Date()
        self.operationElapsedSeconds = 0
        self.progressTickerTask = Task { @MainActor in
            while !Task.isCancelled, self.isApplyingChanges {
                if let startedAt = self.operationStartedAt {
                    self.operationElapsedSeconds = max(0, Int(Date().timeIntervalSince(startedAt)))
                }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    private func stopProgressTicker() {
        self.progressTickerTask?.cancel()
        self.progressTickerTask = nil
        self.operationStartedAt = nil
        self.operationElapsedSeconds = 0
    }

    private func cancelCurrentOperation() {
        self.saveOperationTask?.cancel()
        self.saveOperationTask = nil
        self.operationToken = UUID()
        self.isApplyingChanges = false
        self.stopProgressTicker()
        self.statusIsError = true
        self.statusResponsePreview = nil
        self.statusText = self.operationIsTest ? "Test canceled." : "Operation canceled."
        self.statusScrollTrigger = UUID()
    }

    @MainActor
    private func reloadOpenAIModelCatalog(force: Bool) async {
        guard self.provider == .openAICompatible, self.authMode == .openAIOAuthSub else {
            return
        }
        guard !self.oauthLoadingModels else { return }
        if !force, !self.oauthAvailableModels.isEmpty { return }

        var accessToken = self.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if accessToken.isEmpty {
            self.oauthStatusText = "Sign in to OpenAI before loading models."
            self.oauthStatusIsError = true
            return
        }

        self.oauthLoadingModels = true
        defer { self.oauthLoadingModels = false }

        do {
            let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
            let refreshSkewMs: Int64 = 90_000
            if let expiry = self.oauthAccessExpiresAtMs,
               expiry <= nowMs + refreshSkewMs,
               !self.oauthRefreshToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            {
                let refreshed = try await OpenAIOAuthSubClient.refresh(
                    refreshToken: self.oauthRefreshToken.trimmingCharacters(in: .whitespacesAndNewlines))
                self.apiKey = refreshed.accessToken
                self.oauthRefreshToken = refreshed.refreshToken
                self.oauthAccessExpiresAtMs = refreshed.expiresAtMs
                self.oauthAccountID = refreshed.accountID
                accessToken = refreshed.accessToken
            }

            let models = try await OpenAIOAuthSubClient.fetchModelIDs(accessToken: accessToken)
            self.oauthAvailableModels = models
            if self.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !models.contains(self.model)
            {
                self.model = OpenAIOAuthSubClient.preferredModelID(from: models) ?? self.model
            }

            if models.isEmpty {
                self.oauthStatusText = "Signed in, but no models were returned for this account."
                self.oauthStatusIsError = true
            } else {
                self.oauthStatusText = "Loaded \(models.count) OpenAI models."
                self.oauthStatusIsError = false
            }
        } catch {
            self.oauthStatusText = error.localizedDescription
            self.oauthStatusIsError = true
        }
    }

    private func formatTimestampMs(_ ms: Int64) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(ms) / 1000)
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    #if os(iOS)
    @MainActor
    private func beginOpenAIOAuthSignIn() {
        guard !self.oauthSigningIn else { return }
        self.applyOAuthSubscriptionDefaults()
        do {
            let context = try OpenAIOAuthSubClient.makeAuthorizationContext(originator: "pi-ios")
            let loopback = try OpenAIOAuthLoopbackCallbackServer()
            try loopback.start()

            self.oauthAuthorizationContext = context
            self.oauthLoopbackServer = loopback
            self.oauthCompletionHandled = false
            self.oauthSigningIn = true
            self.oauthStatusText = "Opening OpenAI sign-in…"
            self.oauthStatusIsError = false

            self.oauthLoopbackTask = Task { [loopback] in
                do {
                    let callbackURL = try await loopback.waitForCallback(timeoutSeconds: 240)
                    await MainActor.run {
                        self.oauthSession?.cancel()
                    }
                    await self.handleOpenAIOAuthCompletionIfNeeded(
                        callbackURL: callbackURL,
                        error: nil,
                        context: context)
                } catch is CancellationError {
                    return
                } catch let error as OpenAIOAuthLoopbackServerError where error == .canceled {
                    return
                } catch {
                    await self.handleOpenAIOAuthCompletionIfNeeded(
                        callbackURL: nil,
                        error: error,
                        context: context)
                }
            }

            let session = ASWebAuthenticationSession(
                url: context.url,
                callbackURLScheme: OpenAIOAuthSubClient.callbackURLScheme)
            { callbackURL, error in
                Task { @MainActor in
                    await self.handleOpenAIOAuthCompletionIfNeeded(
                        callbackURL: callbackURL,
                        error: error,
                        context: context)
                }
            }
            session.presentationContextProvider = self.oauthPresentationContextProvider
            // Avoid sticky browser/OAuth cache so users can re-consent after scope changes.
            session.prefersEphemeralWebBrowserSession = true
            self.oauthSession = session
            if !session.start() {
                self.oauthSigningIn = false
                self.oauthSession = nil
                self.oauthLoopbackTask?.cancel()
                self.oauthLoopbackTask = nil
                self.oauthLoopbackServer?.stop()
                self.oauthLoopbackServer = nil
                self.oauthStatusText = "Failed to start OpenAI web authentication."
                self.oauthStatusIsError = true
            }
        } catch {
            self.oauthSigningIn = false
            self.oauthLoopbackTask?.cancel()
            self.oauthLoopbackTask = nil
            self.oauthLoopbackServer?.stop()
            self.oauthLoopbackServer = nil
            self.oauthStatusText = error.localizedDescription
            self.oauthStatusIsError = true
        }
    }

    @MainActor
    private func handleOpenAIOAuthCompletionIfNeeded(
        callbackURL: URL?,
        error: Error?,
        context: OpenAIOAuthSubAuthorizationContext) async
    {
        guard !self.oauthCompletionHandled else { return }
        self.oauthCompletionHandled = true
        await self.handleOpenAIOAuthCompletion(
            callbackURL: callbackURL,
            error: error,
            context: context)
    }

    @MainActor
    private func handleOpenAIOAuthCompletion(
        callbackURL: URL?,
        error: Error?,
        context: OpenAIOAuthSubAuthorizationContext) async
    {
        defer {
            self.oauthSigningIn = false
            self.oauthSession = nil
            self.oauthAuthorizationContext = nil
            self.oauthLoopbackTask?.cancel()
            self.oauthLoopbackTask = nil
            self.oauthLoopbackServer?.stop()
            self.oauthLoopbackServer = nil
        }

        if let authError = error as? ASWebAuthenticationSessionError,
           authError.code == .canceledLogin
        {
            self.oauthStatusText = "OpenAI sign-in canceled."
            self.oauthStatusIsError = true
            return
        }
        if let error {
            self.oauthStatusText = error.localizedDescription
            self.oauthStatusIsError = true
            return
        }
        guard let callbackURL else {
            self.oauthStatusText = "OpenAI sign-in did not return a callback URL."
            self.oauthStatusIsError = true
            return
        }

        let parsed = OpenAIOAuthSubClient.parseAuthorizationCallback(callbackURL)
        guard parsed.state == context.state else {
            self.oauthStatusText = OpenAIOAuthSubClientError.stateMismatch.localizedDescription
            self.oauthStatusIsError = true
            return
        }
        if let callbackError = parsed.error,
           !callbackError.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            self.oauthStatusText = OpenAIOAuthSubClientError.callbackAuthorizationFailed(
                code: callbackError,
                description: parsed.errorDescription).localizedDescription
            self.oauthStatusIsError = true
            return
        }
        guard let code = parsed.code, !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            self.oauthStatusText = OpenAIOAuthSubClientError.callbackMissingCode.localizedDescription
            self.oauthStatusIsError = true
            return
        }

        do {
            let tokens = try await OpenAIOAuthSubClient.exchangeCode(
                code: code,
                verifier: context.verifier)
            self.authMode = .openAIOAuthSub
            self.apiKey = tokens.accessToken
            self.oauthRefreshToken = tokens.refreshToken
            self.oauthAccessExpiresAtMs = tokens.expiresAtMs
            self.oauthAccountID = tokens.accountID
            self.applyOAuthSubscriptionDefaults()
            self.oauthStatusText = "OpenAI sign-in succeeded."
            self.oauthStatusIsError = false
            await self.reloadOpenAIModelCatalog(force: true)
        } catch {
            self.oauthStatusText = error.localizedDescription
            self.oauthStatusIsError = true
        }
    }
    #endif
}
#endif
