import SwiftUI
import Foundation

@main
struct OpenClawApp: App {
    #if os(tvOS)
    @State private var tvOSGatewayRuntime: TVOSLocalGatewayRuntime
    @Environment(\.scenePhase) private var scenePhase
    #else
    @State private var appModel: NodeAppModel
    @State private var gatewayController: GatewayConnectionController
    @State private var localGatewayRuntime: TVOSLocalGatewayRuntime
    @Environment(\.scenePhase) private var scenePhase
    #endif

    init() {
        Self.installUncaughtExceptionLogger()
        #if os(tvOS)
        _tvOSGatewayRuntime = State(initialValue: TVOSLocalGatewayRuntime())
        #else
        GatewaySettingsStore.bootstrapPersistence()
        let appModel = NodeAppModel()
        _appModel = State(initialValue: appModel)
        _gatewayController = State(initialValue: GatewayConnectionController(appModel: appModel))
        _localGatewayRuntime = State(initialValue: TVOSLocalGatewayRuntime())
        #endif
    }

    var body: some Scene {
        WindowGroup {
            #if os(tvOS)
            TVOSGatewayHostView()
                .environment(self.tvOSGatewayRuntime)
                .task {
                    if self.tvOSGatewayRuntime.state == .stopped {
                        await self.tvOSGatewayRuntime.start()
                    }
                }
                .onChange(of: self.scenePhase) { _, newValue in
                    self.updateTVOSGatewayScenePhase(newValue)
                }
            #else
            RootCanvas()
                .environment(self.appModel)
                .environment(self.appModel.voiceWake)
                .environment(self.gatewayController)
                .environment(self.localGatewayRuntime)
                .onOpenURL { url in
                    Task { await self.appModel.handleDeepLink(url: url) }
                }
                .task {
                    if self.localGatewayRuntime.state == .stopped {
                        await self.localGatewayRuntime.start()
                    }
                    // Local server is primary — auto-complete onboarding so the wizard
                    // never blocks the app on fresh install.
                    if self.localGatewayRuntime.state == .running {
                        UserDefaults.standard.set(true, forKey: "gateway.onboardingComplete")
                        UserDefaults.standard.set(true, forKey: "gateway.hasConnectedOnce")
                    }
                }
                .onChange(of: self.scenePhase) { _, newValue in
                    self.appModel.setScenePhase(newValue)
                    self.gatewayController.setScenePhase(newValue)
                    self.updateLocalGatewayScenePhase(newValue)
                }
            #endif
        }
    }
}

extension OpenClawApp {
    private static func installUncaughtExceptionLogger() {
        NSLog("OpenClaw: installing uncaught exception handler")
        NSSetUncaughtExceptionHandler { exception in
            // Useful when the app hits NSExceptions from SwiftUI/WebKit internals; these do not
            // produce a normal Swift error backtrace.
            let reason = exception.reason ?? "(no reason)"
            NSLog("UNCAUGHT EXCEPTION: %@ %@", exception.name.rawValue, reason)
            for line in exception.callStackSymbols {
                NSLog("  %@", line)
            }
        }
    }

    #if os(tvOS)
    private func updateTVOSGatewayScenePhase(_ phase: ScenePhase) {
        Task { @MainActor in
            switch phase {
            case .background:
                await self.tvOSGatewayRuntime.stop()
            case .active:
                if self.tvOSGatewayRuntime.state == .stopped {
                    await self.tvOSGatewayRuntime.start()
                }
                await self.tvOSGatewayRuntime.probeHealth()
                await self.tvOSGatewayRuntime.probeHealthOverWebSocket()
                await self.tvOSGatewayRuntime.probeUpstreamHealth()
            case .inactive:
                break
            @unknown default:
                if self.tvOSGatewayRuntime.state == .stopped {
                    await self.tvOSGatewayRuntime.start()
                }
                await self.tvOSGatewayRuntime.probeHealth()
                await self.tvOSGatewayRuntime.probeHealthOverWebSocket()
                await self.tvOSGatewayRuntime.probeUpstreamHealth()
            }
        }
    }
    #else
    private func updateLocalGatewayScenePhase(_ phase: ScenePhase) {
        Task { @MainActor in
            switch phase {
            case .background:
                await self.localGatewayRuntime.stop()
            case .active:
                if self.localGatewayRuntime.state == .stopped {
                    await self.localGatewayRuntime.start()
                }
                await self.localGatewayRuntime.probeHealth()
            case .inactive:
                break
            @unknown default:
                if self.localGatewayRuntime.state == .stopped {
                    await self.localGatewayRuntime.start()
                }
                await self.localGatewayRuntime.probeHealth()
            }
        }
    }
    #endif
}
