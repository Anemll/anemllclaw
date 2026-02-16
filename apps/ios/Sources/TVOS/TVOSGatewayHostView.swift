#if os(tvOS)
import SwiftUI

struct TVOSGatewayHostView: View {
    @Environment(TVOSLocalGatewayRuntime.self) private var runtime

    var body: some View {
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

            Spacer()
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
}
#endif
