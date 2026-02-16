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

    enum ListenerState: String, Sendable {
        case stopped
        case listening
        case failed
    }

    private(set) var state: State = .stopped
    private(set) var listenerState: ListenerState = .stopped
    private(set) var listenerPort: UInt16?
    private(set) var listenerErrorText: String?
    private(set) var lastProbeSucceeded: Bool?
    private let listenPortPreference: UInt16
    private let exposeTCPListener: Bool
    private let host: GatewayLoopbackHost
    private let tcpServer: GatewayTCPJSONServer

    init(
        exposeTCPListener: Bool = true,
        listenPort: UInt16 = 18_789,
        transport: GatewayLoopbackTransport = GatewayLoopbackTransport())
    {
        self.exposeTCPListener = exposeTCPListener
        self.listenPortPreference = listenPort
        self.host = GatewayLoopbackHost(transport: transport)
        self.tcpServer = GatewayTCPJSONServer(transport: transport)
    }

    func start() async {
        guard self.state != .running else { return }
        await self.host.start()
        if self.exposeTCPListener {
            await self.startTCPListenerIfNeeded()
        }
        self.state = .running
    }

    func stop() async {
        guard self.state != .stopped else { return }
        if self.exposeTCPListener {
            await self.stopTCPListener()
        }
        await self.host.stop()
        self.state = .stopped
        self.lastProbeSucceeded = nil
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

    func startTCPListenerIfNeeded() async {
        guard self.exposeTCPListener else { return }
        guard self.listenerState != .listening else { return }
        do {
            let boundPort = try await self.tcpServer.start(port: self.listenPortPreference)
            self.listenerPort = boundPort
            self.listenerErrorText = nil
            self.listenerState = .listening
        } catch {
            self.listenerPort = nil
            self.listenerErrorText = error.localizedDescription
            self.listenerState = .failed
        }
    }

    func restartTCPListener() async {
        guard self.exposeTCPListener else { return }
        await self.stopTCPListener()
        await self.startTCPListenerIfNeeded()
    }

    func stopTCPListener() async {
        await self.tcpServer.stop()
        self.listenerPort = nil
        self.listenerState = .stopped
    }
}
#endif
