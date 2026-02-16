#if os(tvOS)
import SwiftUI

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
            id: "gateway.session.pairing",
            title: "Pairing + session control",
            support: .remoteOnly,
            details: "Session and pairing workflows currently require an upstream full gateway."),
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

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("OpenClaw Gateway (tvOS)")
                    .font(.largeTitle.weight(.semibold))

                VStack(alignment: .leading, spacing: 10) {
                    Text("Runtime: \(self.runtime.state.rawValue)")
                        .font(.headline)

                    Text("WebSocket listener: \(self.webSocketListenerLabel)")
                        .font(.headline)
                    Text("Listener auth: \(self.listenerAuthLabel)")
                        .font(.headline)
                    if let port = self.runtime.listenerPort {
                        Text("WebSocket port: \(port)")
                            .font(.headline)
                    }
                    if let error = self.runtime.listenerErrorText, !error.isEmpty {
                        Text("WebSocket error: \(error)")
                            .font(.subheadline)
                            .foregroundStyle(.orange)
                    }

                    Text("In-process health probe: \(self.probeLabel)")
                        .font(.headline)
                    Text("WebSocket probe: \(self.webSocketProbeLabel)")
                        .font(.headline)
                    if let error = self.runtime.lastWebSocketProbeErrorText, !error.isEmpty {
                        Text("WebSocket probe error: \(error)")
                            .font(.subheadline)
                            .foregroundStyle(.orange)
                    }

                    Text("Upstream gateway: \(self.upstreamConfigurationLabel)")
                        .font(.headline)
                    if let upstreamURL = self.runtime.upstreamURLText {
                        Text("Upstream URL: \(upstreamURL)")
                            .font(.subheadline)
                    }
                    if let error = self.runtime.upstreamConfigErrorText, !error.isEmpty {
                        Text("Upstream config error: \(error)")
                            .font(.subheadline)
                            .foregroundStyle(.orange)
                    }
                    Text("Upstream probe: \(self.upstreamProbeLabel)")
                        .font(.headline)
                    if let error = self.runtime.lastUpstreamProbeErrorText, !error.isEmpty {
                        Text("Upstream probe error: \(error)")
                            .font(.subheadline)
                            .foregroundStyle(.orange)
                    }

                    Text("TCP debug listener: \(self.tcpListenerLabel)")
                        .font(.headline)
                    if let port = self.runtime.tcpListenerPort {
                        Text("TCP debug port: \(port)")
                            .font(.headline)
                    }
                    if let error = self.runtime.tcpListenerErrorText, !error.isEmpty {
                        Text("TCP listener error: \(error)")
                            .font(.subheadline)
                            .foregroundStyle(.orange)
                    }
                    Text("TCP debug probe: \(self.tcpProbeLabel)")
                        .font(.headline)
                    if let error = self.runtime.lastTCPProbeErrorText, !error.isEmpty {
                        Text("TCP probe error: \(error)")
                            .font(.subheadline)
                            .foregroundStyle(.orange)
                    }
                }

                HStack(spacing: 12) {
                    Button("Start Runtime") {
                        Task { await self.runtime.start() }
                    }
                    Button("Stop Runtime") {
                        Task { await self.runtime.stop() }
                    }
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
                    Button("Start WebSocket") {
                        Task { await self.runtime.startWebSocketListenerIfNeeded() }
                    }
                    Button("Restart WebSocket") {
                        Task { await self.runtime.restartWebSocketListener() }
                    }
                    Button("Stop WebSocket") {
                        Task { await self.runtime.stopWebSocketListener() }
                    }
                    Button("Clear Log") {
                        self.runtime.clearDiagnosticsLog()
                    }
                }
                .buttonStyle(.bordered)

                HStack(spacing: 12) {
                    Button("Start TCP Debug") {
                        Task { await self.runtime.startTCPListenerIfNeeded() }
                    }
                    Button("Restart TCP Debug") {
                        Task { await self.runtime.restartTCPListener() }
                    }
                    Button("Stop TCP Debug") {
                        Task { await self.runtime.stopTCPListener() }
                    }
                    Button("Probe TCP Debug") {
                        Task { await self.runtime.probeHealthOverTCP() }
                    }
                }
                .buttonStyle(.bordered)

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
#endif
