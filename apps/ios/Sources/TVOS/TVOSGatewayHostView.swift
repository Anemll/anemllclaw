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
                Text("TCP listener: \(self.listenerLabel)")
                    .font(.headline)
                Text("Listener auth: \(self.listenerAuthLabel)")
                    .font(.headline)
                if let port = self.runtime.listenerPort {
                    Text("Listener port: \(port)")
                        .font(.headline)
                }
                if let error = self.runtime.listenerErrorText, !error.isEmpty {
                    Text("Listener error: \(error)")
                        .font(.subheadline)
                        .foregroundStyle(.orange)
                }
                Text("Health probe: \(self.probeLabel)")
                    .font(.headline)
                Text("TCP health probe: \(self.tcpProbeLabel)")
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
                Button("Probe Health") {
                    Task { await self.runtime.probeHealth() }
                }
                Button("Probe via TCP") {
                    Task { await self.runtime.probeHealthOverTCP() }
                }
            }
            .buttonStyle(.borderedProminent)

            HStack(spacing: 12) {
                Button("Start Listener") {
                    Task { await self.runtime.startTCPListenerIfNeeded() }
                }
                Button("Restart Listener") {
                    Task { await self.runtime.restartTCPListener() }
                }
                Button("Stop Listener") {
                    Task { await self.runtime.stopTCPListener() }
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

    private var listenerLabel: String {
        self.runtime.listenerState.rawValue
    }

    private var listenerAuthLabel: String {
        if let hint = self.runtime.listenerAuthHint {
            return hint
        }
        return self.runtime.listenerAuthMode.rawValue
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
