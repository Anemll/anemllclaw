#if os(tvOS)
import Foundation
import Observation
import OpenClawGatewayCore

@MainActor
@Observable
final class TVOSLocalGatewayRuntime {
    enum State: String, Sendable {
        case stopped
        case running
    }

    private(set) var state: State = .stopped
    private(set) var lastProbeSucceeded: Bool?
    private let host: GatewayLoopbackHost

    init(host: GatewayLoopbackHost = GatewayLoopbackHost()) {
        self.host = host
    }

    func start() async {
        guard self.state != .running else { return }
        await self.host.start()
        self.state = .running
    }

    func stop() async {
        guard self.state != .stopped else { return }
        await self.host.stop()
        self.state = .stopped
    }

    func probeHealth(nowMs: Int64 = GatewayCore.currentTimestampMs()) async {
        guard self.state == .running else {
            self.lastProbeSucceeded = nil
            return
        }
        do {
            let response = try await self.host.invoke(
                GatewayRequestFrame(id: UUID().uuidString, method: "health"),
                nowMs: nowMs)
            self.lastProbeSucceeded = response.ok
        } catch {
            self.lastProbeSucceeded = false
        }
    }
}
#endif
