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
            id: "gateway.channel.integrations",
            title: "Messaging channel integrations",
            support: .remoteOnly,
            details: "Telegram/Discord/Slack/Signal/WhatsApp remain remote-host features."),
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
    static let activeCapabilities: [GatewayHostCapability] = []
    #endif

    static func summaryLines() -> [String] {
        activeCapabilities.map { capability in
            "[\(capability.support.label)] \(capability.title) - \(capability.details)"
        }
    }
}
