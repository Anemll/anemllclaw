import SwiftUI
import Foundation

@main
struct OpenClawApp: App {
    @State private var appModel: NodeAppModel
    @State private var gatewayController: GatewayConnectionController
    #if os(tvOS)
    @State private var tvOSGatewayRuntime: TVOSLocalGatewayRuntime
    #endif
    @Environment(\.scenePhase) private var scenePhase

    init() {
        Self.installUncaughtExceptionLogger()
        GatewaySettingsStore.bootstrapPersistence()
        let appModel = NodeAppModel()
        _appModel = State(initialValue: appModel)
        _gatewayController = State(initialValue: GatewayConnectionController(appModel: appModel))
        #if os(tvOS)
        _tvOSGatewayRuntime = State(initialValue: TVOSLocalGatewayRuntime())
        #endif
    }

    var body: some Scene {
        WindowGroup {
            RootCanvas()
                .environment(self.appModel)
                .environment(self.appModel.voiceWake)
                .environment(self.gatewayController)
                #if os(tvOS)
                .environment(self.tvOSGatewayRuntime)
                .task {
                    await self.tvOSGatewayRuntime.start()
                    await self.tvOSGatewayRuntime.probeHealth()
                }
                #endif
                .onOpenURL { url in
                    Task { await self.appModel.handleDeepLink(url: url) }
                }
                .onChange(of: self.scenePhase) { _, newValue in
                    self.appModel.setScenePhase(newValue)
                    self.gatewayController.setScenePhase(newValue)
                    #if os(tvOS)
                    self.updateTVOSGatewayScenePhase(newValue)
                    #endif
                }
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
            case .active, .inactive:
                await self.tvOSGatewayRuntime.start()
                await self.tvOSGatewayRuntime.probeHealth()
            @unknown default:
                await self.tvOSGatewayRuntime.start()
                await self.tvOSGatewayRuntime.probeHealth()
            }
        }
    }
    #endif
}
