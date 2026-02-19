#if os(tvOS)
import SwiftUI
import OpenClawGatewayCore

struct TVOSGatewayHostView: View {
    private struct CapabilityRow: Identifiable {
        enum Support: String {
            case supported
            case remoteOnly = "remote-only"
            case unsupported
        }

        let id: String
        let title: String
        let support: Support
        let details: String
    }

    private static let capabilityRows: [CapabilityRow] = [
        CapabilityRow(
            id: "gateway.transport.ws",
            title: "Gateway WebSocket v3 transport",
            support: .supported,
            details: "Served locally on tvOS by the Swift gateway host."),
        CapabilityRow(
            id: "gateway.health",
            title: "Gateway health/status RPC",
            support: .supported,
            details: "Served locally by the Swift gateway core."),
        CapabilityRow(
            id: "gateway.chat.local",
            title: "chat.send + chat.history",
            support: .supported,
            details: "Handled locally when a local LLM provider is configured."),
        CapabilityRow(
            id: "gateway.memory.local",
            title: "memory.search + memory.get",
            support: .supported,
            details: "Stored locally in SQLite + FTS for persistent transcript recall."),
        CapabilityRow(
            id: "gateway.tools.safe",
            title: "Safe node.invoke commands",
            support: .supported,
            details: "Local-only safe commands: time.now, device.info, network.fetch."),
        CapabilityRow(
            id: "gateway.tools.unsafe",
            title: "Unsafe/system/browser tools",
            support: .remoteOnly,
            details: "Routed upstream only; local tvOS host intentionally blocks unsafe classes."),
        CapabilityRow(
            id: "gateway.channel.telegram.outbound",
            title: "Telegram outbound notifications",
            support: .supported,
            details: "Local telegram.send + cron delivery when bot token is configured."),
        CapabilityRow(
            id: "gateway.channel.integrations",
            title: "Messaging channel integrations",
            support: .remoteOnly,
            details: "Inbound adapters still require an upstream full gateway host."),
        CapabilityRow(
            id: "gateway.hooks.external",
            title: "Hooks and external command execution",
            support: .remoteOnly,
            details: "Requires an upstream host with shell/process access."),
        CapabilityRow(
            id: "gateway.node.child-process",
            title: "Node child_process/cluster model",
            support: .unsupported,
            details: "Not available on tvOS runtime."),
        CapabilityRow(
            id: "gateway.daemon.supervisor",
            title: "launchd/systemd/schtasks supervision",
            support: .unsupported,
            details: "tvOS app lifecycle controls runtime uptime."),
    ]

    private enum FocusTarget: Hashable {
        case restart
        case settings
        case chatScrollUp
        case chatScrollDown
        case input
        case send
    }

    /// Focus targets for the Settings sheet.
    /// Organised in rows so tvOS remote navigation maps intuitively.
    private enum SettingsFocus: Hashable {
        case done
        // Row 1 – runtime actions
        case runtimeToggle
        case probeInProcess
        case probeWebSocket
        case probeUpstream
        // Row 2 – websocket actions
        case wsToggle
        case forceRebindWS
        case clearLog
        case clearErrors
        // Row 3 – TCP debug
        case tcpToggle
        case rebindTCP
        case probeTCP
        // Row 4 – LLM / agent
        case testLocalLLM
        case testAgenticRun
        case agentStatus
        case abortAgent
        // Row 5 – Listener auth
        case authMode
        case authToken
        case authPassword
        // Row 6 – Upstream gateway
        case upstreamURL
        case upstreamToken
        case upstreamPassword
        // Row 7 – LLM settings
        case llmProvider
        case llmBaseURL
        case llmAPIKey
        case llmModel
        case llmApply
        case llmReload
    }

    /// All settings focus targets grouped by visual row for directional navigation.
    private static let settingsFocusRows: [[SettingsFocus]] = [
        [.done],
        [.runtimeToggle, .probeInProcess, .probeWebSocket, .probeUpstream],
        [.wsToggle, .forceRebindWS, .clearLog, .clearErrors],
        [.tcpToggle, .rebindTCP, .probeTCP],
        [.testLocalLLM, .testAgenticRun, .agentStatus, .abortAgent],
        [.authMode, .authToken, .authPassword],
        [.upstreamURL, .upstreamToken, .upstreamPassword],
        [.llmProvider, .llmBaseURL, .llmAPIKey, .llmModel],
        [.llmApply, .llmReload],
    ]

    private static let chatTopAnchor = "tvos-chat-top-anchor"
    private static let chatBottomAnchor = "tvos-chat-bottom-anchor"
    @Environment(TVOSLocalGatewayRuntime.self) private var runtime

    @State private var isSettingsPresented = false
    @State private var settingsDraft = TVOSGatewayControlPlaneSettings.default
    @State private var applyingSettings = false
    @State private var chatInputText = ""
    @State private var chatScrollProxy: ScrollViewProxy?
    @State private var chatScrollTargetIndex: Int = 0
    @State private var collapsedToolTraceTurnIDs: Set<String> = []
    /// Timestamp of the last accepted directional move – used to lock out
    /// rapid-fire events from the Siri Remote trackpad.
    @State private var lastMoveDate: Date = .distantPast
    /// The focus target BEFORE the native tvOS focus engine moves it.
    /// `onMoveCommand` fires AFTER the native engine already changed focus,
    /// so we need the previous value to compute the correct destination.
    @State private var previousFocusTarget: FocusTarget? = .input
    @FocusState private var focusedTarget: FocusTarget?
    @FocusState private var settingsFocus: SettingsFocus?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            self.topBar
            self.chatWindow
            self.chatScrollButtons
            self.chatComposer
        }
        .padding(24)
        .background(
            LinearGradient(
                colors: [Color.black, Color(red: 0.08, green: 0.08, blue: 0.1)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing))
        .foregroundStyle(.white)
        .task {
            self.runtime.refreshLocalNetworkAddresses()
            await self.runtime.refreshChatHistory(quiet: true)
            self.settingsDraft = self.runtime.controlPlaneSettings
            if self.focusedTarget == nil {
                self.focusedTarget = .input
            }
        }
        .onChange(of: self.runtime.controlPlaneSettings) { _, next in
            guard !self.applyingSettings else { return }
            self.settingsDraft = next
        }
        .fullScreenCover(isPresented: self.$isSettingsPresented) {
            self.settingsSheet
        }
        .onChange(of: self.focusedTarget) { old, _ in
            // Track where focus WAS so onMoveCommand can route from the
            // correct origin (the native focus engine moves focus before
            // onMoveCommand fires).
            if let old {
                self.previousFocusTarget = old
            }
        }
        .onMoveCommand { direction in
            self.handleMoveCommand(direction)
        }
        .onPlayPauseCommand {
            // Play/Pause on the Siri Remote sends the chat message.
            if self.focusedTarget == .input || self.focusedTarget == .send {
                self.sendChatInput()
            }
        }
    }

    private var topBar: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("OpenClaw ANEMLL Server")
                    .font(.title2.weight(.semibold))

                Text("HTML: \(self.htmlReadout)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.mint)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Text("WS: \(self.webSocketReadout)")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 20)

            Button("Restart") {
                Task {
                    await self.runtime.restart(with: self.runtime.controlPlaneSettings)
                }
            }
            .buttonStyle(.borderedProminent)
            .focused(self.$focusedTarget, equals: .restart)

            Button("Settings") {
                self.isSettingsPresented = true
            }
            .buttonStyle(.bordered)
            .focused(self.$focusedTarget, equals: .settings)
        }
    }

    private var chatWindow: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    Color.clear
                        .frame(height: 1)
                        .id(Self.chatTopAnchor)

                    if self.runtime.chatTurns.isEmpty {
                        self.emptyChatState
                    } else {
                        ForEach(self.runtime.chatTurns) { turn in
                            self.chatTurnRow(turn)
                        }
                    }

                    if self.runtime.chatSendInProgress, let progress = self.runtime.chatProgressText {
                        HStack(spacing: 8) {
                            ProgressView()
                                .controlSize(.small)
                            Text(progress)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 4)
                    }

                    Color.clear
                        .frame(height: 1)
                        .id(Self.chatBottomAnchor)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(14)
            .background(Color.white.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .onAppear {
                self.chatScrollProxy = proxy
                self.chatScrollTargetIndex = max(0, self.runtime.chatTurns.count - 1)
                self.scrollChatToBottom(proxy, animated: false)
            }
            .onDisappear {
                self.chatScrollProxy = nil
            }
            .onChange(of: self.runtime.chatTurns) { _, newTurns in
                self.pruneCollapsedToolTraceTurnIDs(using: newTurns)
                self.chatScrollTargetIndex = max(0, newTurns.count - 1)
                self.scrollChatToBottom(proxy)
            }
            .onChange(of: self.runtime.chatSendInProgress) { _, _ in
                self.scrollChatToBottom(proxy)
            }
            .onChange(of: self.runtime.chatProgressText) { _, _ in
                self.scrollChatToBottom(proxy)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var emptyChatState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("No chat turns yet")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text("Type in the input below. Turns will stream here as user/tool/assistant messages.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(6)
    }

    private func chatTurnRow(_ turn: TVOSGatewayChatTurn) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(self.displayRole(for: turn.role))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(self.roleColor(for: turn.role))
                if let runID = turn.runID, !runID.isEmpty {
                    Text(runID)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 8)
                if let timestamp = turn.timestamp {
                    Text(timestamp.formatted(.dateTime.hour().minute().second()))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            if self.isToolTraceTurn(turn) {
                VStack(alignment: .leading, spacing: 8) {
                    Button {
                        self.toggleToolTraceCollapse(turnID: turn.id)
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: self.isToolTraceExpanded(turnID: turn.id) ? "chevron.down" : "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Text(self.toolTraceSummary(for: turn.text))
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                            Spacer(minLength: 8)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)

                    if self.isToolTraceExpanded(turnID: turn.id) {
                        Text(turn.text)
                            .font(.body.monospaced())
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            } else {
                Text(turn.text)
                    .font(.body)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(12)
        .background(self.chatBubbleBackground(for: turn.role))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func isToolTraceTurn(_ turn: TVOSGatewayChatTurn) -> Bool {
        let normalizedRole = turn.role.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalizedRole == "tool" {
            return true
        }
        if normalizedRole != "assistant" {
            return false
        }
        return self.compactWhitespace(turn.text).hasPrefix("[tool-plan]")
    }

    private func toolTraceSummary(for text: String) -> String {
        let compact = self.compactWhitespace(text)
        guard !compact.isEmpty else {
            return "Tool trace"
        }

        var summaryText = compact
        if summaryText.hasPrefix("[tool-plan]") {
            let startIndex = summaryText.index(summaryText.startIndex, offsetBy: "[tool-plan]".count)
            let planBody = summaryText[startIndex...].trimmingCharacters(in: .whitespacesAndNewlines)
            summaryText = planBody.isEmpty ? "tool-plan" : "tool-plan: \(planBody)"
        }

        if summaryText.count > 120 {
            return String(summaryText.prefix(119)) + "…"
        }
        return summaryText
    }

    private func compactWhitespace(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    private func isToolTraceExpanded(turnID: String) -> Bool {
        !self.collapsedToolTraceTurnIDs.contains(turnID)
    }

    private func toggleToolTraceCollapse(turnID: String) {
        if self.collapsedToolTraceTurnIDs.contains(turnID) {
            self.collapsedToolTraceTurnIDs.remove(turnID)
        } else {
            self.collapsedToolTraceTurnIDs.insert(turnID)
        }
    }

    private func pruneCollapsedToolTraceTurnIDs(using turns: [TVOSGatewayChatTurn]) {
        let knownIDs = Set(turns.map(\.id))
        self.collapsedToolTraceTurnIDs = self.collapsedToolTraceTurnIDs.intersection(knownIDs)
    }

    private var chatScrollButtons: some View {
        HStack(spacing: 10) {
            Button {
                self.scrollChatPageUp()
            } label: {
                Image(systemName: "chevron.up")
            }
            .buttonStyle(.bordered)
            .focused(self.$focusedTarget, equals: .chatScrollUp)

            Button {
                self.scrollChatPageDown()
            } label: {
                Image(systemName: "chevron.down")
            }
            .buttonStyle(.bordered)
            .focused(self.$focusedTarget, equals: .chatScrollDown)

            Spacer(minLength: 8)

            Text("Scroll")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var chatComposer: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                TextField("Type a message", text: self.$chatInputText)
                    .tvosConfigInputFieldStyle()
                    .submitLabel(.send)
                    .onSubmit {
                        self.sendChatInput()
                    }
                    .focused(self.$focusedTarget, equals: .input)

                Button(self.runtime.chatSendInProgress ? "Sending…" : "Send") {
                    self.sendChatInput()
                }
                .buttonStyle(.borderedProminent)
                .disabled(self.runtime.chatSendInProgress)
                .focused(self.$focusedTarget, equals: .send)
            }

            if self.runtime.state != .running {
                Text("Runtime is stopped. Use Restart on the top bar.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if let error = self.runtime.chatLastErrorText, !error.isEmpty {
                Text("Chat error: \(error)")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(2)
                    .truncationMode(.tail)
            }
        }
    }

    private func sendChatInput() {
        guard self.runtime.state == .running, !self.runtime.chatSendInProgress else { return }
        let message = self.chatInputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else { return }
        self.chatInputText = ""
        Task {
            await self.runtime.sendChatMessage(message)
        }
    }

    private func scrollChatToBottom(_ proxy: ScrollViewProxy, animated: Bool = true) {
        self.scrollChatToAnchor(proxy, id: Self.chatBottomAnchor, anchor: .bottom, animated: animated)
    }

    private func scrollChatToAnchor(
        _ proxy: ScrollViewProxy,
        id: String,
        anchor: UnitPoint,
        animated: Bool = true)
    {
        DispatchQueue.main.async {
            if animated {
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo(id, anchor: anchor)
                }
            } else {
                proxy.scrollTo(id, anchor: anchor)
            }
        }
    }

    private static let chatScrollPageSize = 3

    private func scrollChatPageUp() {
        guard let proxy = self.chatScrollProxy else { return }
        if self.runtime.chatTurns.isEmpty {
            return
        }
        let newIndex = max(0, self.chatScrollTargetIndex - Self.chatScrollPageSize)
        self.chatScrollTargetIndex = newIndex
        let turn = self.runtime.chatTurns[newIndex]
        DispatchQueue.main.async {
            withAnimation(.easeOut(duration: 0.2)) {
                proxy.scrollTo(turn.id, anchor: .top)
            }
        }
    }

    private func scrollChatPageDown() {
        guard let proxy = self.chatScrollProxy else { return }
        if self.runtime.chatTurns.isEmpty {
            return
        }
        let maxIndex = self.runtime.chatTurns.count - 1
        let newIndex = min(maxIndex, self.chatScrollTargetIndex + Self.chatScrollPageSize)
        self.chatScrollTargetIndex = newIndex
        if newIndex >= maxIndex {
            self.scrollChatToBottom(proxy)
        } else {
            let turn = self.runtime.chatTurns[newIndex]
            DispatchQueue.main.async {
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo(turn.id, anchor: .top)
                }
            }
        }
    }

    // MARK: - Main-screen directional navigation

    /// Minimum interval between accepted directional moves (seconds).
    /// Prevents the Siri Remote trackpad from chaining through buttons
    /// faster than a human can react.
    private static let moveLockInterval: TimeInterval = 0.35

    private func handleMoveCommand(_ direction: MoveCommandDirection) {
        // IMPORTANT: The native tvOS focus engine moves focus BEFORE
        // onMoveCommand fires.  So `self.focusedTarget` is already the
        // native engine's guess.  We use `previousFocusTarget` (where
        // the user actually was) to compute the correct destination.
        guard let origin = self.previousFocusTarget else { return }

        let now = Date()
        let elapsed = now.timeIntervalSince(self.lastMoveDate)
        if elapsed < Self.moveLockInterval {
            // Rapid-fire event – revert to origin so we don't chain.
            print("[NAV] LOCKED \(direction) from \(origin) — \(Int(elapsed * 1000))ms, reverting to \(origin)")
            self.focusedTarget = origin
            return
        }

        let next: FocusTarget? = {
            switch (origin, direction) {
            // ── Top row (Restart ↔ Settings) ──
            case (.restart, .right):  return .settings
            case (.settings, .left):  return .restart

            // ── Top → Chevron row ──
            case (.restart, .down), (.settings, .down):
                return .chatScrollUp

            // ── Chevron row ↔ ──
            case (.chatScrollUp, .right):  return .chatScrollDown
            case (.chatScrollDown, .left): return .chatScrollUp

            // ── Chevron row ↕ ──
            case (.chatScrollUp, .up), (.chatScrollDown, .up):
                return .restart
            case (.chatScrollUp, .down):
                return .input
            case (.chatScrollDown, .down):
                return .send

            // ── Composer row ↕ ──
            case (.input, .up):
                return .chatScrollUp
            case (.send, .up):
                return .chatScrollDown
            case (.send, .left):    return .input
            case (.send, .down):    return .input

            default: return nil
            }
        }()

        guard let target = next else {
            print("[NAV] IGNORED \(direction) from \(origin) (native moved to \(String(describing: self.focusedTarget))) — no mapping")
            return
        }

        self.lastMoveDate = now
        print("[NAV] \(origin) → \(direction) → \(target) (native had: \(String(describing: self.focusedTarget)))")
        self.focusedTarget = target
        self.previousFocusTarget = target
    }

    // MARK: - Settings sheet directional navigation

    private func handleSettingsMoveCommand(_ direction: MoveCommandDirection) {
        guard let current = self.settingsFocus else {
            self.settingsFocus = .runtimeToggle
            return
        }

        let rows = Self.settingsFocusRows

        // Find current position in the grid.
        var rowIndex = 0
        var colIndex = 0
        for (r, row) in rows.enumerated() {
            if let c = row.firstIndex(of: current) {
                rowIndex = r
                colIndex = c
                break
            }
        }

        switch direction {
        case .up:
            if rowIndex > 0 {
                let targetRow = rows[rowIndex - 1]
                let clamped = min(colIndex, targetRow.count - 1)
                self.settingsFocus = targetRow[clamped]
            }
        case .down:
            if rowIndex < rows.count - 1 {
                let targetRow = rows[rowIndex + 1]
                let clamped = min(colIndex, targetRow.count - 1)
                self.settingsFocus = targetRow[clamped]
            }
        case .left:
            if colIndex > 0 {
                self.settingsFocus = rows[rowIndex][colIndex - 1]
            }
        case .right:
            if colIndex < rows[rowIndex].count - 1 {
                self.settingsFocus = rows[rowIndex][colIndex + 1]
            }
        @unknown default:
            break
        }
    }

    private var settingsSheet: some View {
        List {
            // Close button as first row — always reachable via Up on tvOS.
            Section {
                Button {
                    self.isSettingsPresented = false
                } label: {
                    HStack {
                        Image(systemName: "xmark.circle.fill")
                        Text("Close Settings")
                            .font(.headline)
                    }
                }
            } header: {
                Text("Settings")
                    .font(.title3.weight(.semibold))
            }

            // Runtime actions — immediately focusable on tvOS.
            Section {
                self.settingsRuntimeActionsContent
            } header: {
                Text("Runtime Actions")
            }

            Section {
                self.configurationHintContent
            } header: {
                Text("Configuration")
            }

            Section {
                self.listenerAuthSettingsContent
            } header: {
                Text("Listener Auth")
            }

            Section {
                self.upstreamGatewaySettingsContent
            } header: {
                Text("Upstream Gateway")
            }

            Section {
                self.localLLMSettingsContent
            } header: {
                Text("Local LLM + Runtime State")
            }

            Section {
                self.networkStatusContent
            } header: {
                Text("Network Status")
            }

            Section {
                self.upstreamAndTCPStatusContent
            } header: {
                Text("Upstream & TCP")
            }

            Section {
                self.capabilityMatrixContent
            } header: {
                Text("Capability Matrix (tvOS)")
            }

            Section {
                self.runtimeLogContent
            } header: {
                Text("Runtime Log (\(self.runtime.diagnosticsLog.count))")
            }
        }
        .listStyle(.grouped)
        .background(
            LinearGradient(
                colors: [Color.black, Color(red: 0.08, green: 0.08, blue: 0.12)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing)
                .ignoresSafeArea())
        .onExitCommand {
            self.isSettingsPresented = false
        }
        .onAppear {
            self.settingsDraft = self.runtime.controlPlaneSettings
        }
    }

    // MARK: - Settings List content views (for tvOS List rows)

    @ViewBuilder
    private var settingsRuntimeActionsContent: some View {
        HStack(spacing: 12) {
            self.settingsRuntimeToggleButton
            Button("Probe In-Process") {
                Task { await self.runtime.probeHealth() }
            }
            .focused(self.$settingsFocus, equals: .probeInProcess)
            Button("Probe WebSocket") {
                Task { await self.runtime.probeHealthOverWebSocket() }
            }
            .focused(self.$settingsFocus, equals: .probeWebSocket)
            Button("Probe Upstream") {
                Task { await self.runtime.probeUpstreamHealth() }
            }
            .focused(self.$settingsFocus, equals: .probeUpstream)
        }
        .buttonStyle(.borderedProminent)

        HStack(spacing: 12) {
            self.settingsWebSocketToggleButton
            Button("Force Rebind WS") {
                Task { await self.runtime.restartWebSocketListener() }
            }
            .focused(self.$settingsFocus, equals: .forceRebindWS)
            Button("Clear Log") {
                self.runtime.clearDiagnosticsLog()
            }
            .focused(self.$settingsFocus, equals: .clearLog)
            Button("Clear Errors") {
                self.runtime.clearErrorStates()
            }
            .focused(self.$settingsFocus, equals: .clearErrors)
        }
        .buttonStyle(.bordered)

        HStack(spacing: 12) {
            self.settingsTCPDebugToggleButton
            Button("Rebind TCP Debug") {
                Task { await self.runtime.restartTCPListener() }
            }
            .focused(self.$settingsFocus, equals: .rebindTCP)
            Button("Probe TCP Debug") {
                Task { await self.runtime.probeHealthOverTCP() }
            }
            .focused(self.$settingsFocus, equals: .probeTCP)
        }
        .buttonStyle(.bordered)

        HStack(spacing: 12) {
            Button("Test Local LLM") {
                Task { await self.runtime.probeLocalLLM(prompt: "Who are you?") }
            }
            .disabled(self.runtime.state != .running)
            .focused(self.$settingsFocus, equals: .testLocalLLM)

            Button("Test Agentic Run") {
                Task { await self.runtime.probeAgentRun() }
            }
            .disabled(self.runtime.state != .running)
            .focused(self.$settingsFocus, equals: .testAgenticRun)

            Button("Agent Status") {
                Task { await self.runtime.probeAgentStatus() }
            }
            .disabled(self.runtime.state != .running || self.runtime.lastAgentRunID == nil)
            .focused(self.$settingsFocus, equals: .agentStatus)

            Button("Abort Agent") {
                Task { await self.runtime.abortAgentRun() }
            }
            .disabled(self.runtime.state != .running || self.runtime.lastAgentRunID == nil)
            .focused(self.$settingsFocus, equals: .abortAgent)
        }
        .buttonStyle(.bordered)

        Text("Normal operation needs Runtime + WebSocket. TCP debug is developer-only raw JSON-line.")
            .font(.footnote)
            .foregroundStyle(.secondary)
    }

    private var configurationHintContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("All configurable parameters (listener auth, upstream, local LLM/API keys) are managed from Admin Web.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Text("Admin URL hint: \(self.htmlReadout)")
                .font(.footnote.monospaced())
                .foregroundStyle(.mint)
            Text("Gateway WS endpoint: \(self.webSocketReadout)")
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
        }
        .focusable()
    }

    @ViewBuilder
    private var listenerAuthSettingsContent: some View {
        HStack(spacing: 14) {
            Text("Auth Mode")
                .font(.subheadline.weight(.semibold))
                .frame(width: 200, alignment: .leading)
            Picker("", selection: self.$settingsDraft.authMode) {
                Text("none").tag(GatewayCoreAuthMode.none)
                Text("token").tag(GatewayCoreAuthMode.token)
                Text("password").tag(GatewayCoreAuthMode.password)
            }
            .pickerStyle(.segmented)
            .focused(self.$settingsFocus, equals: .authMode)
        }

        HStack(spacing: 14) {
            Text("Auth Token")
                .font(.subheadline.weight(.semibold))
                .frame(width: 200, alignment: .leading)
            SecureField("Auth token", text: self.$settingsDraft.authToken)
                .tvosConfigInputFieldStyle()
                .focused(self.$settingsFocus, equals: .authToken)
        }

        HStack(spacing: 14) {
            Text("Auth Password")
                .font(.subheadline.weight(.semibold))
                .frame(width: 200, alignment: .leading)
            SecureField("Auth password", text: self.$settingsDraft.authPassword)
                .tvosConfigInputFieldStyle()
                .focused(self.$settingsFocus, equals: .authPassword)
        }
    }

    @ViewBuilder
    private var upstreamGatewaySettingsContent: some View {
        HStack(spacing: 14) {
            Text("Upstream URL")
                .font(.subheadline.weight(.semibold))
                .frame(width: 200, alignment: .leading)
            TextField("ws://host:18789", text: self.$settingsDraft.upstreamURL)
                .tvosConfigInputFieldStyle()
                .focused(self.$settingsFocus, equals: .upstreamURL)
        }

        HStack(spacing: 14) {
            Text("Upstream Token")
                .font(.subheadline.weight(.semibold))
                .frame(width: 200, alignment: .leading)
            SecureField("Upstream token", text: self.$settingsDraft.upstreamToken)
                .tvosConfigInputFieldStyle()
                .focused(self.$settingsFocus, equals: .upstreamToken)
        }

        HStack(spacing: 14) {
            Text("Upstream Password")
                .font(.subheadline.weight(.semibold))
                .frame(width: 200, alignment: .leading)
            SecureField("Upstream password", text: self.$settingsDraft.upstreamPassword)
                .tvosConfigInputFieldStyle()
                .focused(self.$settingsFocus, equals: .upstreamPassword)
        }
    }

    @ViewBuilder
    private var localLLMSettingsContent: some View {
        HStack(spacing: 14) {
            Text("Local LLM Provider")
                .font(.subheadline.weight(.semibold))
                .frame(width: 200, alignment: .leading)
            Picker("", selection: self.$settingsDraft.localLLMProvider) {
                Text("disabled").tag(GatewayLocalLLMProviderKind.disabled)
                Text("openai").tag(GatewayLocalLLMProviderKind.openAICompatible)
                Text("anthropic").tag(GatewayLocalLLMProviderKind.anthropicCompatible)
                Text("minimax").tag(GatewayLocalLLMProviderKind.minimaxCompatible)
            }
            .pickerStyle(.segmented)
            .focused(self.$settingsFocus, equals: .llmProvider)
        }

        HStack(spacing: 14) {
            Text("Base URL")
                .font(.subheadline.weight(.semibold))
                .frame(width: 200, alignment: .leading)
            TextField("https://api.openai.com", text: self.$settingsDraft.localLLMBaseURL)
                .tvosConfigInputFieldStyle()
                .focused(self.$settingsFocus, equals: .llmBaseURL)
        }

        HStack(spacing: 14) {
            Text("API Key")
                .font(.subheadline.weight(.semibold))
                .frame(width: 200, alignment: .leading)
            SecureField("Local LLM API key", text: self.$settingsDraft.localLLMAPIKey)
                .tvosConfigInputFieldStyle()
                .focused(self.$settingsFocus, equals: .llmAPIKey)
        }

        HStack(spacing: 14) {
            Text("Model")
                .font(.subheadline.weight(.semibold))
                .frame(width: 200, alignment: .leading)
            TextField("Model (e.g. gpt-4o-mini)", text: self.$settingsDraft.localLLMModel)
                .tvosConfigInputFieldStyle()
                .focused(self.$settingsFocus, equals: .llmModel)
        }

        HStack(spacing: 12) {
            Button(self.applyingSettings ? "Applying…" : "Apply + Restart Runtime") {
                self.applyControlPlaneSettings()
            }
            .disabled(self.applyingSettings)
            .buttonStyle(.borderedProminent)
            .focused(self.$settingsFocus, equals: .llmApply)

            Button("Reload Saved") {
                self.reloadControlPlaneSettingsDraft()
            }
            .buttonStyle(.bordered)
            .focused(self.$settingsFocus, equals: .llmReload)
        }

        Text("Saved in tvOS UserDefaults and applied immediately by rebuilding the local gateway stack.")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private func applyControlPlaneSettings() {
        guard !self.applyingSettings else { return }
        let draft = self.settingsDraft
        self.applyingSettings = true
        Task {
            await self.runtime.applyControlPlaneSettings(draft)
            self.settingsDraft = self.runtime.controlPlaneSettings
            self.applyingSettings = false
        }
    }

    private func reloadControlPlaneSettingsDraft() {
        self.settingsDraft = self.runtime.controlPlaneSettings
    }

    private var networkStatusContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            self.statusLine("Runtime", self.runtime.state.rawValue, color: self.runtimeStateColor)
            self.statusLine("Local IP", self.localIPAddressLabel, color: self.localIPAddressColor)
            if self.runtime.localIPv4Addresses.count > 1 {
                self.detailLine("All local IPs: \(self.runtime.localIPv4Addresses.joined(separator: ", "))")
            }
            self.statusLine(
                "WebSocket listener",
                self.webSocketListenerLabel,
                color: self.webSocketListenerColor)
            self.detailLine(
                "Listener auth: \(self.listenerAuthLabel) | Local IP: \(self.runtime.localIPv4Address ?? "not detected")")
            if let port = self.runtime.listenerPort {
                self.detailLine("WebSocket port: \(port)")
                if let localIP = self.runtime.localIPv4Address {
                    self.detailLine("LAN endpoint: ws://\(localIP):\(port)")
                }
            }
            if let error = self.runtime.listenerErrorText, !error.isEmpty {
                self.detailLine("WebSocket error: \(error)", color: .orange)
            }
            if self.runtime.webSocketRetryAttempt > 0 {
                self.detailLine(
                    "WebSocket retry attempt \(self.runtime.webSocketRetryAttempt) in \(self.runtime.webSocketRetryDelaySeconds ?? 0)s",
                    color: .orange)
            }
            self.statusLine(
                "In-process health probe",
                self.probeLabel,
                color: self.probeColor(self.runtime.lastProbeSucceeded))
            self.statusLine(
                "WebSocket probe",
                self.webSocketProbeLabel,
                color: self.probeColor(self.runtime.lastWebSocketProbeSucceeded))
            if let error = self.runtime.lastWebSocketProbeErrorText, !error.isEmpty {
                self.detailLine("WebSocket probe error: \(error)", color: .orange)
            }
        }
        .focusable()
    }

    private var upstreamAndTCPStatusContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            self.statusLine(
                "Upstream gateway",
                self.upstreamConfigurationLabel,
                color: self.upstreamConfigurationColor)
            if let upstreamURL = self.runtime.upstreamURLText {
                self.detailLine("Upstream URL: \(upstreamURL)")
            }
            if let error = self.runtime.upstreamConfigErrorText, !error.isEmpty {
                self.detailLine("Upstream config error: \(error)", color: .orange)
            }
            self.statusLine(
                "Upstream probe",
                self.upstreamProbeLabel,
                color: self.probeColor(self.runtime.lastUpstreamProbeSucceeded))
            if let error = self.runtime.lastUpstreamProbeErrorText, !error.isEmpty {
                self.detailLine("Upstream probe error: \(error)", color: .orange)
            }
            self.statusLine("Local LLM", self.localLLMStatusLabel, color: self.localLLMStatusColor)
            self.detailLine("Local LLM provider: \(self.runtime.localLLMProviderLabel)")
            if let error = self.runtime.localLLMConfigErrorText, !error.isEmpty {
                self.detailLine("Local LLM config error: \(error)", color: .orange)
            }
            self.statusLine(
                "Local LLM probe",
                self.localLLMProbeLabel,
                color: self.probeColor(self.runtime.lastLocalLLMProbeSucceeded))
            if let error = self.runtime.lastLocalLLMProbeErrorText, !error.isEmpty {
                self.detailLine("Local LLM probe error: \(error)", color: .orange)
            }
            if let response = self.runtime.lastLocalLLMProbeResponseText, !response.isEmpty {
                self.detailLineExpanded("Local LLM probe reply: \(response)")
            }

            self.statusLine(
                "Agent run",
                self.agentRunProbeLabel,
                color: self.probeColor(self.runtime.lastAgentRunProbeSucceeded))
            if let runID = self.runtime.lastAgentRunID {
                self.detailLine("Agent run id: \(runID)")
            }
            if let error = self.runtime.lastAgentRunProbeErrorText, !error.isEmpty {
                self.detailLine("Agent run error: \(error)", color: .orange)
            }
            if let response = self.runtime.lastAgentRunProbeResponseText, !response.isEmpty {
                self.detailLineExpanded("Agent run result: \(response)")
            }

            self.statusLine(
                "Agent status",
                self.agentStatusProbeLabel,
                color: self.probeColor(self.runtime.lastAgentStatusProbeSucceeded))
            if let error = self.runtime.lastAgentStatusProbeErrorText, !error.isEmpty {
                self.detailLine("Agent status error: \(error)", color: .orange)
            }
            if let response = self.runtime.lastAgentStatusProbeResponseText, !response.isEmpty {
                self.detailLineExpanded("Agent status result: \(response)")
            }

            self.statusLine(
                "Agent abort",
                self.agentAbortProbeLabel,
                color: self.probeColor(self.runtime.lastAgentAbortProbeSucceeded))
            if let error = self.runtime.lastAgentAbortProbeErrorText, !error.isEmpty {
                self.detailLine("Agent abort error: \(error)", color: .orange)
            }
            if let response = self.runtime.lastAgentAbortProbeResponseText, !response.isEmpty {
                self.detailLineExpanded("Agent abort result: \(response)")
            }

            self.statusLine(
                "TCP debug listener",
                self.tcpListenerLabel,
                color: self.tcpListenerColor)
            if let port = self.runtime.tcpListenerPort {
                self.detailLine("TCP debug port: \(port)")
            }
            if let error = self.runtime.tcpListenerErrorText, !error.isEmpty {
                self.detailLine("TCP listener error: \(error)", color: .orange)
            }
            if self.runtime.tcpRetryAttempt > 0 {
                self.detailLine(
                    "TCP retry attempt \(self.runtime.tcpRetryAttempt) in \(self.runtime.tcpRetryDelaySeconds ?? 0)s",
                    color: .orange)
            }
            self.statusLine(
                "TCP debug probe",
                self.tcpProbeLabel,
                color: self.probeColor(self.runtime.lastTCPProbeSucceeded))
            if let error = self.runtime.lastTCPProbeErrorText, !error.isEmpty {
                self.detailLine("TCP probe error: \(error)", color: .orange)
            }
        }
        .focusable()
    }

    private var capabilityMatrixContent: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Self.capabilityRows) { capability in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(capability.title)
                        Spacer(minLength: 12)
                        Text(capability.support.rawValue)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(self.supportColor(capability.support))
                    }
                    Text(capability.details)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
            }
        }
        .focusable()
    }

    private var runtimeLogContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            if self.runtime.diagnosticsLog.isEmpty {
                Text("No log entries yet.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(self.runtime.diagnosticsLog) { entry in
                    HStack(alignment: .top, spacing: 8) {
                        Text(entry.timestamp.formatted(.dateTime.hour().minute().second()))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                        Text(entry.level.rawValue.uppercased())
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(self.logLevelColor(entry.level))
                        Text(entry.message)
                            .font(.caption)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
        .focusable()
    }

    private var configurationHintSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Configuration")
                .font(.headline)
            Text("All configurable parameters (listener auth, upstream, local LLM/API keys) are managed from Admin Web.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Text("Admin URL hint: \(self.htmlReadout)")
                .font(.footnote.monospaced())
                .foregroundStyle(.mint)
            Text("Gateway WS endpoint: \(self.webSocketReadout)")
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .background(Color.white.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    /// Original (main-view) runtime actions section — kept for potential reuse.
    private var runtimeActionsSection: some View {
        self.settingsRuntimeActionsSection
    }

    /// Runtime actions with full tvOS focus management for the Settings sheet.
    private var settingsRuntimeActionsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Runtime Actions")
                .font(.headline)

            HStack(spacing: 12) {
                self.settingsRuntimeToggleButton
                Button("Probe In-Process") {
                    Task { await self.runtime.probeHealth() }
                }
                .focused(self.$settingsFocus, equals: .probeInProcess)
                Button("Probe WebSocket") {
                    Task { await self.runtime.probeHealthOverWebSocket() }
                }
                .focused(self.$settingsFocus, equals: .probeWebSocket)
                Button("Probe Upstream") {
                    Task { await self.runtime.probeUpstreamHealth() }
                }
                .focused(self.$settingsFocus, equals: .probeUpstream)
            }
            .buttonStyle(.borderedProminent)

            HStack(spacing: 12) {
                self.settingsWebSocketToggleButton
                Button("Force Rebind WS") {
                    Task { await self.runtime.restartWebSocketListener() }
                }
                .focused(self.$settingsFocus, equals: .forceRebindWS)
                Button("Clear Log") {
                    self.runtime.clearDiagnosticsLog()
                }
                .focused(self.$settingsFocus, equals: .clearLog)
                Button("Clear Errors") {
                    self.runtime.clearErrorStates()
                }
                .focused(self.$settingsFocus, equals: .clearErrors)
            }
            .buttonStyle(.bordered)

            HStack(spacing: 12) {
                self.settingsTCPDebugToggleButton
                Button("Rebind TCP Debug") {
                    Task { await self.runtime.restartTCPListener() }
                }
                .focused(self.$settingsFocus, equals: .rebindTCP)
                Button("Probe TCP Debug") {
                    Task { await self.runtime.probeHealthOverTCP() }
                }
                .focused(self.$settingsFocus, equals: .probeTCP)
            }
            .buttonStyle(.bordered)

            HStack(spacing: 12) {
                Button("Test Local LLM") {
                    Task { await self.runtime.probeLocalLLM(prompt: "Who are you?") }
                }
                .disabled(self.runtime.state != .running)
                .focused(self.$settingsFocus, equals: .testLocalLLM)

                Button("Test Agentic Run") {
                    Task { await self.runtime.probeAgentRun() }
                }
                .disabled(self.runtime.state != .running)
                .focused(self.$settingsFocus, equals: .testAgenticRun)

                Button("Agent Status") {
                    Task { await self.runtime.probeAgentStatus() }
                }
                .disabled(self.runtime.state != .running || self.runtime.lastAgentRunID == nil)
                .focused(self.$settingsFocus, equals: .agentStatus)

                Button("Abort Agent") {
                    Task { await self.runtime.abortAgentRun() }
                }
                .disabled(self.runtime.state != .running || self.runtime.lastAgentRunID == nil)
                .focused(self.$settingsFocus, equals: .abortAgent)
            }
            .buttonStyle(.bordered)

            Text("Normal operation needs Runtime + WebSocket. TCP debug is developer-only raw JSON-line.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .background(Color.white.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var probeLabel: String {
        switch self.runtime.lastProbeSucceeded {
        case .none:
            return "not yet run"
        case .some(true):
            return "ok"
        case .some(false):
            return "failed"
        }
    }

    private var webSocketListenerLabel: String {
        self.runtime.listenerState.rawValue
    }

    private var tcpListenerLabel: String {
        self.runtime.tcpListenerState.rawValue
    }

    private var listenerAuthLabel: String {
        if let hint = self.runtime.listenerAuthHint {
            return hint
        }
        return self.runtime.listenerAuthMode.rawValue
    }

    private var webSocketProbeLabel: String {
        switch self.runtime.lastWebSocketProbeSucceeded {
        case .none:
            return "not yet run"
        case .some(true):
            return "ok"
        case .some(false):
            return "failed"
        }
    }

    private var upstreamConfigurationLabel: String {
        self.runtime.upstreamConfigured ? "configured" : "not configured"
    }

    private var upstreamProbeLabel: String {
        switch self.runtime.lastUpstreamProbeSucceeded {
        case .none:
            return "not yet run"
        case .some(true):
            return "ok"
        case .some(false):
            return "failed"
        }
    }

    private var tcpProbeLabel: String {
        switch self.runtime.lastTCPProbeSucceeded {
        case .none:
            return "not yet run"
        case .some(true):
            return "ok"
        case .some(false):
            return "failed"
        }
    }

    private var localLLMStatusLabel: String {
        if self.runtime.localLLMConfigured {
            return "configured"
        }
        if self.runtime.controlPlaneSettings.localLLMProvider == .disabled {
            return "disabled"
        }
        return "incomplete"
    }

    private var localLLMProbeLabel: String {
        switch self.runtime.lastLocalLLMProbeSucceeded {
        case .none:
            return "not yet run"
        case .some(true):
            return "ok"
        case .some(false):
            return "failed"
        }
    }

    private var agentRunProbeLabel: String {
        switch self.runtime.lastAgentRunProbeSucceeded {
        case .none:
            return "not yet run"
        case .some(true):
            return "ok"
        case .some(false):
            return "failed"
        }
    }

    private var agentStatusProbeLabel: String {
        switch self.runtime.lastAgentStatusProbeSucceeded {
        case .none:
            return "not yet run"
        case .some(true):
            return "ok"
        case .some(false):
            return "failed"
        }
    }

    private var agentAbortProbeLabel: String {
        switch self.runtime.lastAgentAbortProbeSucceeded {
        case .none:
            return "not yet run"
        case .some(true):
            return "ok"
        case .some(false):
            return "failed"
        }
    }

    @ViewBuilder
    private var networkStatusColumn: some View {
        VStack(alignment: .leading, spacing: 8) {
            self.statusLine("Runtime", self.runtime.state.rawValue, color: self.runtimeStateColor)
            self.statusLine("Local IP", self.localIPAddressLabel, color: self.localIPAddressColor)
            if self.runtime.localIPv4Addresses.count > 1 {
                self.detailLine("All local IPs: \(self.runtime.localIPv4Addresses.joined(separator: ", "))")
            }

            self.statusLine(
                "WebSocket listener",
                self.webSocketListenerLabel,
                color: self.webSocketListenerColor)
            self.detailLine(
                "Listener auth: \(self.listenerAuthLabel) | Local IP: \(self.runtime.localIPv4Address ?? "not detected")")
            if let port = self.runtime.listenerPort {
                self.detailLine("WebSocket port: \(port)")
                if let localIP = self.runtime.localIPv4Address {
                    self.detailLine("LAN endpoint: ws://\(localIP):\(port)")
                }
            }
            if let error = self.runtime.listenerErrorText, !error.isEmpty {
                self.detailLine("WebSocket error: \(error)", color: .orange)
            }
            if self.runtime.webSocketRetryAttempt > 0 {
                self.detailLine(
                    "WebSocket retry attempt \(self.runtime.webSocketRetryAttempt) in \(self.runtime.webSocketRetryDelaySeconds ?? 0)s",
                    color: .orange)
            }

            self.statusLine(
                "In-process health probe",
                self.probeLabel,
                color: self.probeColor(self.runtime.lastProbeSucceeded))
            self.statusLine(
                "WebSocket probe",
                self.webSocketProbeLabel,
                color: self.probeColor(self.runtime.lastWebSocketProbeSucceeded))
            if let error = self.runtime.lastWebSocketProbeErrorText, !error.isEmpty {
                self.detailLine("WebSocket probe error: \(error)", color: .orange)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var upstreamAndTCPStatusColumn: some View {
        VStack(alignment: .leading, spacing: 8) {
            self.statusLine(
                "Upstream gateway",
                self.upstreamConfigurationLabel,
                color: self.upstreamConfigurationColor)
            if let upstreamURL = self.runtime.upstreamURLText {
                self.detailLine("Upstream URL: \(upstreamURL)")
            }
            if let error = self.runtime.upstreamConfigErrorText, !error.isEmpty {
                self.detailLine("Upstream config error: \(error)", color: .orange)
            }
            self.statusLine(
                "Upstream probe",
                self.upstreamProbeLabel,
                color: self.probeColor(self.runtime.lastUpstreamProbeSucceeded))
            if let error = self.runtime.lastUpstreamProbeErrorText, !error.isEmpty {
                self.detailLine("Upstream probe error: \(error)", color: .orange)
            }
            self.statusLine("Local LLM", self.localLLMStatusLabel, color: self.localLLMStatusColor)
            self.detailLine("Local LLM provider: \(self.runtime.localLLMProviderLabel)")
            if let error = self.runtime.localLLMConfigErrorText, !error.isEmpty {
                self.detailLine("Local LLM config error: \(error)", color: .orange)
            }
            self.statusLine(
                "Local LLM probe",
                self.localLLMProbeLabel,
                color: self.probeColor(self.runtime.lastLocalLLMProbeSucceeded))
            if let error = self.runtime.lastLocalLLMProbeErrorText, !error.isEmpty {
                self.detailLine("Local LLM probe error: \(error)", color: .orange)
            }
            if let response = self.runtime.lastLocalLLMProbeResponseText, !response.isEmpty {
                self.detailLineExpanded("Local LLM probe reply: \(response)")
            }

            self.statusLine(
                "Agent run",
                self.agentRunProbeLabel,
                color: self.probeColor(self.runtime.lastAgentRunProbeSucceeded))
            if let runID = self.runtime.lastAgentRunID {
                self.detailLine("Agent run id: \(runID)")
            }
            if let error = self.runtime.lastAgentRunProbeErrorText, !error.isEmpty {
                self.detailLine("Agent run error: \(error)", color: .orange)
            }
            if let response = self.runtime.lastAgentRunProbeResponseText, !response.isEmpty {
                self.detailLineExpanded("Agent run result: \(response)")
            }

            self.statusLine(
                "Agent status",
                self.agentStatusProbeLabel,
                color: self.probeColor(self.runtime.lastAgentStatusProbeSucceeded))
            if let error = self.runtime.lastAgentStatusProbeErrorText, !error.isEmpty {
                self.detailLine("Agent status error: \(error)", color: .orange)
            }
            if let response = self.runtime.lastAgentStatusProbeResponseText, !response.isEmpty {
                self.detailLineExpanded("Agent status result: \(response)")
            }

            self.statusLine(
                "Agent abort",
                self.agentAbortProbeLabel,
                color: self.probeColor(self.runtime.lastAgentAbortProbeSucceeded))
            if let error = self.runtime.lastAgentAbortProbeErrorText, !error.isEmpty {
                self.detailLine("Agent abort error: \(error)", color: .orange)
            }
            if let response = self.runtime.lastAgentAbortProbeResponseText, !response.isEmpty {
                self.detailLineExpanded("Agent abort result: \(response)")
            }

            self.statusLine(
                "TCP debug listener",
                self.tcpListenerLabel,
                color: self.tcpListenerColor)
            if let port = self.runtime.tcpListenerPort {
                self.detailLine("TCP debug port: \(port)")
            }
            if let error = self.runtime.tcpListenerErrorText, !error.isEmpty {
                self.detailLine("TCP listener error: \(error)", color: .orange)
            }
            if self.runtime.tcpRetryAttempt > 0 {
                self.detailLine(
                    "TCP retry attempt \(self.runtime.tcpRetryAttempt) in \(self.runtime.tcpRetryDelaySeconds ?? 0)s",
                    color: .orange)
            }
            self.statusLine(
                "TCP debug probe",
                self.tcpProbeLabel,
                color: self.probeColor(self.runtime.lastTCPProbeSucceeded))
            if let error = self.runtime.lastTCPProbeErrorText, !error.isEmpty {
                self.detailLine("TCP probe error: \(error)", color: .orange)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var runtimeToggleButton: some View {
        if self.runtime.state == .running {
            Button("Stop Runtime", role: .destructive) {
                Task { await self.runtime.stop() }
            }
        } else {
            Button("Start Runtime") {
                Task { await self.runtime.start() }
            }
        }
    }

    @ViewBuilder
    private var webSocketToggleButton: some View {
        if self.runtime.listenerState == .listening {
            Button("Stop WebSocket", role: .destructive) {
                Task { await self.runtime.stopWebSocketListener() }
            }
        } else {
            Button("Start WebSocket") {
                Task { await self.runtime.startWebSocketListenerIfNeeded() }
            }
        }
    }

    @ViewBuilder
    private var tcpDebugToggleButton: some View {
        if self.runtime.tcpListenerState == .listening {
            Button("Stop TCP Debug", role: .destructive) {
                Task { await self.runtime.stopTCPListener() }
            }
        } else {
            Button("Start TCP Debug") {
                Task { await self.runtime.startTCPListenerIfNeeded() }
            }
        }
    }

    // MARK: - Settings-sheet focused toggle buttons

    @ViewBuilder
    private var settingsRuntimeToggleButton: some View {
        if self.runtime.state == .running {
            Button("Stop Runtime", role: .destructive) {
                Task { await self.runtime.stop() }
            }
            .focused(self.$settingsFocus, equals: .runtimeToggle)
        } else {
            Button("Start Runtime") {
                Task { await self.runtime.start() }
            }
            .focused(self.$settingsFocus, equals: .runtimeToggle)
        }
    }

    @ViewBuilder
    private var settingsWebSocketToggleButton: some View {
        if self.runtime.listenerState == .listening {
            Button("Stop WebSocket", role: .destructive) {
                Task { await self.runtime.stopWebSocketListener() }
            }
            .focused(self.$settingsFocus, equals: .wsToggle)
        } else {
            Button("Start WebSocket") {
                Task { await self.runtime.startWebSocketListenerIfNeeded() }
            }
            .focused(self.$settingsFocus, equals: .wsToggle)
        }
    }

    @ViewBuilder
    private var settingsTCPDebugToggleButton: some View {
        if self.runtime.tcpListenerState == .listening {
            Button("Stop TCP Debug", role: .destructive) {
                Task { await self.runtime.stopTCPListener() }
            }
            .focused(self.$settingsFocus, equals: .tcpToggle)
        } else {
            Button("Start TCP Debug") {
                Task { await self.runtime.startTCPListenerIfNeeded() }
            }
            .focused(self.$settingsFocus, equals: .tcpToggle)
        }
    }

    private var runtimeStateColor: Color {
        self.runtime.state == .running ? .green : .gray
    }

    private var localIPAddressLabel: String {
        self.runtime.localIPv4Address ?? "not detected"
    }

    private var localIPAddressColor: Color {
        self.runtime.localIPv4Address == nil ? .orange : .green
    }

    private var webSocketListenerColor: Color {
        switch self.runtime.listenerState {
        case .listening:
            return .green
        case .failed:
            return .red
        case .stopped:
            return .gray
        }
    }

    private var tcpListenerColor: Color {
        switch self.runtime.tcpListenerState {
        case .listening:
            return .green
        case .failed:
            return .red
        case .stopped:
            return .gray
        }
    }

    private var upstreamConfigurationColor: Color {
        if self.runtime.upstreamConfigured {
            return .green
        }
        if self.runtime.upstreamConfigErrorText != nil {
            return .orange
        }
        return .gray
    }

    private var localLLMStatusColor: Color {
        if self.runtime.localLLMConfigured {
            return .green
        }
        if self.runtime.controlPlaneSettings.localLLMProvider == .disabled {
            return .gray
        }
        return .orange
    }

    private var webSocketReadout: String {
        guard let ip = self.runtime.localIPv4Address else {
            return "ws://<ip>:\(self.runtime.listenerPort ?? 18_789)"
        }
        return "ws://\(ip):\(self.runtime.listenerPort ?? 18_789)"
    }

    private var htmlReadout: String {
        let port = self.runtime.listenerPort ?? 18_789
        guard let ip = self.runtime.localIPv4Address else {
            return "http://<ip>:\(port)/html"
        }
        return "http://\(ip):\(port)/html"
    }

    private func probeColor(_ value: Bool?) -> Color {
        switch value {
        case .none:
            return .gray
        case .some(true):
            return .green
        case .some(false):
            return .red
        }
    }

    private func displayRole(for rawRole: String) -> String {
        switch rawRole.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "user":
            return "User"
        case "assistant":
            return "Assistant"
        case "tool":
            return "Tool"
        case "system":
            return "System"
        default:
            return rawRole
        }
    }

    private func roleColor(for rawRole: String) -> Color {
        switch rawRole.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "user":
            return .cyan
        case "assistant":
            return .mint
        case "tool":
            return .orange
        case "system":
            return .yellow
        default:
            return .secondary
        }
    }

    private func chatBubbleBackground(for rawRole: String) -> Color {
        switch rawRole.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "user":
            return Color.cyan.opacity(0.16)
        case "assistant":
            return Color.mint.opacity(0.14)
        case "tool":
            return Color.orange.opacity(0.14)
        case "system":
            return Color.yellow.opacity(0.12)
        default:
            return Color.white.opacity(0.08)
        }
    }

    @ViewBuilder
    private func statusLine(_ title: String, _ value: String, color: Color) -> some View {
        HStack(spacing: 10) {
            Text("\(title):")
                .font(.subheadline.weight(.semibold))
            Text(value)
                .font(.caption.weight(.bold))
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(color.opacity(0.22))
                .foregroundStyle(color)
                .clipShape(Capsule())
        }
    }

    private func detailLine(_ text: String, color: Color = .secondary) -> some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(color)
            .lineLimit(2)
            .truncationMode(.middle)
    }

    private func detailLineExpanded(_ text: String, color: Color = .secondary) -> some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(color)
            .lineLimit(6)
            .truncationMode(.tail)
    }

    private var capabilityMatrixSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Capability Matrix (tvOS)")
                .font(.headline)

            ForEach(Self.capabilityRows) { capability in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(capability.title)
                        Spacer(minLength: 12)
                        Text(capability.support.rawValue)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(self.supportColor(capability.support))
                    }
                    Text(capability.details)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
            }
        }
        .padding(14)
        .background(Color.white.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var runtimeLogSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Runtime Log (\(self.runtime.diagnosticsLog.count))")
                .font(.headline)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(self.runtime.diagnosticsLog) { entry in
                        HStack(alignment: .top, spacing: 8) {
                            Text(entry.timestamp.formatted(.dateTime.hour().minute().second()))
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                            Text(entry.level.rawValue.uppercased())
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(self.logLevelColor(entry.level))
                            Text(entry.message)
                                .font(.caption)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 260)
            .padding(10)
            .background(Color.white.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }

    private func supportColor(_ support: CapabilityRow.Support) -> Color {
        switch support {
        case .supported:
            return .green
        case .remoteOnly:
            return .orange
        case .unsupported:
            return .red
        }
    }

    private func logLevelColor(_ level: TVOSGatewayRuntimeLogEntry.Level) -> Color {
        switch level {
        case .info:
            return .mint
        case .warning:
            return .orange
        case .error:
            return .red
        }
    }
}

private extension View {
    func tvosConfigInputFieldStyle() -> some View {
        self
            .textFieldStyle(.plain)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(Color.white.opacity(0.12))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.white.opacity(0.2), lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
#endif
