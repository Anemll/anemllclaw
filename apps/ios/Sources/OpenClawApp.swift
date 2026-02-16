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
        #endif
    }

    var body: some Scene {
        WindowGroup {
            #if os(tvOS)
            TVOSGatewayHostView()
                .environment(self.tvOSGatewayRuntime)
                .task {
                    await self.tvOSGatewayRuntime.start()
                    await self.tvOSGatewayRuntime.probeHealth()
                    await self.tvOSGatewayRuntime.probeHealthOverWebSocket()
                }
                .onChange(of: self.scenePhase) { _, newValue in
                    self.updateTVOSGatewayScenePhase(newValue)
                }
            #else
            RootCanvas()
                .environment(self.appModel)
                .environment(self.appModel.voiceWake)
                .environment(self.gatewayController)
                .onOpenURL { url in
                    Task { await self.appModel.handleDeepLink(url: url) }
                }
                .onChange(of: self.scenePhase) { _, newValue in
                    self.appModel.setScenePhase(newValue)
                    self.gatewayController.setScenePhase(newValue)
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
            case .active, .inactive:
                await self.tvOSGatewayRuntime.start()
                await self.tvOSGatewayRuntime.probeHealth()
                await self.tvOSGatewayRuntime.probeHealthOverWebSocket()
            @unknown default:
                await self.tvOSGatewayRuntime.start()
                await self.tvOSGatewayRuntime.probeHealth()
                await self.tvOSGatewayRuntime.probeHealthOverWebSocket()
            }
        }
    }
    #endif
}
