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
            id: "gateway.channel.integrations",
            title: "Messaging channel integrations",
            support: .remoteOnly,
            details: "Telegram/Discord/Slack/Signal/WhatsApp remain upstream-host features."),
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

    @Environment(TVOSLocalGatewayRuntime.self) private var runtime
    @State private var settingsDraft = TVOSGatewayControlPlaneSettings.default
    @State private var applyingSettings = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("OpenClaw Gateway (tvOS)")
                    .font(.largeTitle.weight(.semibold))

                HStack(alignment: .top, spacing: 24) {
                    self.networkStatusColumn
                    self.upstreamAndTCPStatusColumn
                }

                self.controlPlaneSettingsSection

                HStack(spacing: 12) {
                    self.runtimeToggleButton
                    Button("Probe In-Process") {
                        Task { await self.runtime.probeHealth() }
                    }
                    Button("Probe WebSocket") {
                        Task { await self.runtime.probeHealthOverWebSocket() }
                    }
                    Button("Probe Upstream") {
                        Task { await self.runtime.probeUpstreamHealth() }
                    }
                }
                .buttonStyle(.borderedProminent)

                HStack(spacing: 12) {
                    self.webSocketToggleButton
                    Button("Force Rebind WS") {
                        Task { await self.runtime.restartWebSocketListener() }
                    }
                    Button("Clear Log") {
                        self.runtime.clearDiagnosticsLog()
                    }
                    Button("Clear Errors") {
                        self.runtime.clearErrorStates()
                    }
                }
                .buttonStyle(.bordered)

                HStack(spacing: 12) {
                    self.tcpDebugToggleButton
                    Button("Rebind TCP Debug") {
                        Task { await self.runtime.restartTCPListener() }
                    }
                    Button("Probe TCP Debug") {
                        Task { await self.runtime.probeHealthOverTCP() }
                    }
                }
                .buttonStyle(.bordered)

                Text("Normal operation only needs Runtime + WebSocket. TCP debug is a developer-only raw JSON-line endpoint.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                self.capabilityMatrixSection
                self.runtimeLogSection

                Spacer()
            }
        }
        .padding(32)
        .background(
            LinearGradient(
                colors: [Color.black, Color(red: 0.08, green: 0.08, blue: 0.1)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing))
        .foregroundStyle(.white)
        .task {
            self.runtime.refreshLocalNetworkAddresses()
            self.settingsDraft = self.runtime.controlPlaneSettings
        }
        .onChange(of: self.runtime.controlPlaneSettings) { _, next in
            guard !self.applyingSettings else { return }
            self.settingsDraft = next
        }
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

    @ViewBuilder
    private var networkStatusColumn: some View {
        VStack(alignment: .leading, spacing: 8) {
            self.statusLine(
                "Runtime",
                self.runtime.state.rawValue,
                color: self.runtimeStateColor)
            self.statusLine(
                "Local IP",
                self.localIPAddressLabel,
                color: self.localIPAddressColor)
            if self.runtime.localIPv4Addresses.count > 1 {
                self.detailLine("All local IPs: \(self.runtime.localIPv4Addresses.joined(separator: ", "))")
            }

            self.statusLine(
                "WebSocket listener",
                self.webSocketListenerLabel,
                color: self.webSocketListenerColor)
            self.detailLine("Listener auth: \(self.listenerAuthLabel)")
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
            self.statusLine(
                "Local LLM",
                self.localLLMStatusLabel,
                color: self.localLLMStatusColor)
            self.detailLine("Local LLM provider: \(self.runtime.localLLMProviderLabel)")
            if let error = self.runtime.localLLMConfigErrorText, !error.isEmpty {
                self.detailLine("Local LLM config error: \(error)", color: .orange)
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

    private var controlPlaneSettingsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Control Plane Settings")
                .font(.headline)

            HStack(alignment: .top, spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Listener Auth")
                        .font(.subheadline.weight(.semibold))
                    Picker("Auth Mode", selection: self.$settingsDraft.authMode) {
                        Text("none").tag(GatewayCoreAuthMode.none)
                        Text("token").tag(GatewayCoreAuthMode.token)
                        Text("password").tag(GatewayCoreAuthMode.password)
                    }
                    .pickerStyle(.segmented)
                    SecureField("Auth token", text: self.$settingsDraft.authToken)
                        .tvosConfigInputFieldStyle()
                    SecureField("Auth password", text: self.$settingsDraft.authPassword)
                        .tvosConfigInputFieldStyle()
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(alignment: .leading, spacing: 8) {
                    Text("Upstream Gateway")
                        .font(.subheadline.weight(.semibold))
                    TextField("ws://host:18789", text: self.$settingsDraft.upstreamURL)
                        .tvosConfigInputFieldStyle()
                    SecureField("Upstream token", text: self.$settingsDraft.upstreamToken)
                        .tvosConfigInputFieldStyle()
                    SecureField("Upstream password", text: self.$settingsDraft.upstreamPassword)
                        .tvosConfigInputFieldStyle()
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(alignment: .leading, spacing: 8) {
                    Text("Local LLM")
                        .font(.subheadline.weight(.semibold))
                    Picker("Provider", selection: self.$settingsDraft.localLLMProvider) {
                        Text("disabled").tag(GatewayLocalLLMProviderKind.disabled)
                        Text("openai").tag(GatewayLocalLLMProviderKind.openAICompatible)
                        Text("anthropic").tag(GatewayLocalLLMProviderKind.anthropicCompatible)
                    }
                    .pickerStyle(.segmented)
                    TextField("https://api.openai.com", text: self.$settingsDraft.localLLMBaseURL)
                        .tvosConfigInputFieldStyle()
                    SecureField("Local LLM API key", text: self.$settingsDraft.localLLMAPIKey)
                        .tvosConfigInputFieldStyle()
                    TextField("Model (e.g. gpt-4o-mini)", text: self.$settingsDraft.localLLMModel)
                        .tvosConfigInputFieldStyle()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(spacing: 12) {
                Button(self.applyingSettings ? "Applying…" : "Apply + Restart Runtime") {
                    self.applyControlPlaneSettings()
                }
                .disabled(self.applyingSettings)
                .buttonStyle(.borderedProminent)

                Button("Reload Saved") {
                    self.reloadControlPlaneSettingsDraft()
                }
                .buttonStyle(.bordered)
            }

            Text("Saved in tvOS UserDefaults and applied immediately by rebuilding the local gateway stack.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .background(Color.white.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 12))
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
        } else if self.runtime.listenerState == .failed {
            Button("Retry WebSocket") {
                Task { await self.runtime.startWebSocketListenerIfNeeded() }
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
        } else if self.runtime.tcpListenerState == .failed {
            Button("Retry TCP Debug") {
                Task { await self.runtime.startTCPListenerIfNeeded() }
            }
        } else {
            Button("Start TCP Debug") {
                Task { await self.runtime.startTCPListenerIfNeeded() }
            }
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
            .frame(height: 220)
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
