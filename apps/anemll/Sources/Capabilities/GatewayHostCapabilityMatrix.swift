import Foundation

enum GatewayHostCapabilitySupport: String, Sendable {
    case supported
    case remoteOnly
    case unsupported

    var label: String {
        switch self {
        case .supported:
            "supported"
        case .remoteOnly:
            "remote-only"
        case .unsupported:
            "unsupported"
        }
    }
}

struct GatewayHostCapability: Identifiable, Sendable {
    let id: String
    let title: String
    let support: GatewayHostCapabilitySupport
    let details: String
}

enum GatewayHostCapabilityMatrix {
    #if os(tvOS)
    static let activeHostLabel = "tvOS"
    static let activeCapabilities: [GatewayHostCapability] = [
        GatewayHostCapability(
            id: "gateway.transport.ws",
            title: "Gateway WebSocket v3 transport",
            support: .supported,
            details: "Served locally on tvOS by the Swift gateway host."),
        GatewayHostCapability(
            id: "gateway.health",
            title: "Gateway health/status RPC",
            support: .supported,
            details: "Served locally by the Swift gateway core."),
        GatewayHostCapability(
            id: "gateway.session.pairing",
            title: "Pairing + session control",
            support: .remoteOnly,
            details: "Session and pairing workflows still require a remote full gateway host."),
        GatewayHostCapability(
            id: "gateway.channel.telegram.outbound",
            title: "Telegram outbound notifications",
            support: .supported,
            details: "Local Telegram send + cron delivery supported with bot token configuration."),
        GatewayHostCapability(
            id: "gateway.channel.integrations",
            title: "Messaging channel integrations",
            support: .remoteOnly,
            details: "Inbound channel adapters still require a remote full gateway host."),
        GatewayHostCapability(
            id: "gateway.hooks.external",
            title: "Hooks and external command execution",
            support: .remoteOnly,
            details: "Requires a remote gateway host with shell/process access."),
        GatewayHostCapability(
            id: "gateway.node.child-process",
            title: "Node child_process/cluster model",
            support: .unsupported,
            details: "Replaced by native Swift capability routing on tvOS."),
        GatewayHostCapability(
            id: "gateway.daemon.supervisor",
            title: "launchd/systemd/schtasks supervision",
            support: .unsupported,
            details: "tvOS app lifecycle controls gateway uptime instead."),
    ]
    #else
    static let activeHostLabel = "iOS"
    static let activeCapabilities: [GatewayHostCapability] = [
        GatewayHostCapability(
            id: "gateway.transport.ws",
            title: "Gateway WebSocket v3 transport",
            support: .supported,
            details: "Served locally on iOS by the Swift gateway host."),
        GatewayHostCapability(
            id: "gateway.health",
            title: "Gateway health/status RPC",
            support: .supported,
            details: "Served locally by the Swift gateway core."),
        GatewayHostCapability(
            id: "gateway.chat.local",
            title: "chat.send + chat.history",
            support: .supported,
            details: "Handled locally when a local LLM provider is configured."),
        GatewayHostCapability(
            id: "gateway.memory.local",
            title: "memory.search + memory.get",
            support: .supported,
            details: "Stored locally in SQLite + FTS for persistent transcript recall."),
        GatewayHostCapability(
            id: "gateway.tools.safe",
            title: "Safe node.invoke commands",
            support: .supported,
            details: "Local-only safe commands: time.now, device.info, network.fetch."),
        GatewayHostCapability(
            id: "gateway.channel.integrations",
            title: "Messaging channel integrations",
            support: .remoteOnly,
            details: "Inbound channel adapters still require a remote full gateway host."),
        GatewayHostCapability(
            id: "gateway.hooks.external",
            title: "Hooks and external command execution",
            support: .remoteOnly,
            details: "Requires a remote gateway host with shell/process access."),
    ]
    #endif

    static func summaryLines() -> [String] {
        self.activeCapabilities.map { capability in
            "[\(capability.support.label)] \(capability.title) - \(capability.details)"
        }
    }
}
