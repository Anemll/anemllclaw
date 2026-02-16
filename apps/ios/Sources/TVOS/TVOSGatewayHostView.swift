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
                Text("Health probe: \(self.probeLabel)")
                    .font(.headline)
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
            }
            .buttonStyle(.borderedProminent)

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
}
#endif
