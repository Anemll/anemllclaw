#if os(iOS) || os(tvOS)
#if os(iOS)
import CoreLocation
import OpenClawKit
#endif
import Darwin
import Foundation
import Network
import Observation
import OpenClawGatewayCore
import os

struct TVOSGatewayRuntimeLogEntry: Identifiable, Sendable {
    enum Level: String, Sendable {
        case info
        case warning
        case error
    }

    let id: UUID
    let timestamp: Date
    let level: Level
    let message: String

    init(id: UUID = UUID(), timestamp: Date = Date(), level: Level = .info, message: String) {
        self.id = id
        self.timestamp = timestamp
        self.level = level
        self.message = message
    }
}

struct TVOSGatewayChatTurn: Identifiable, Sendable, Equatable {
    let id: String
    let role: String
    let text: String
    let timestamp: Date?
    let runID: String?

    init(
        id: String,
        role: String,
        text: String,
        timestamp: Date?,
        runID: String?)
    {
        self.id = id
        self.role = role
        self.text = text
        self.timestamp = timestamp
        self.runID = runID
    }
}

private struct TVOSGatewayUpstreamConfigLoadResult: Sendable {
    let config: GatewayUpstreamWebSocketConfig?
    let urlText: String?
    let errorText: String?
}

struct TVOSGatewayControlPlaneSettings: Sendable, Equatable {
    var authMode: GatewayCoreAuthMode
    var authToken: String
    var authPassword: String

    var upstreamURL: String
    var upstreamToken: String
    var upstreamPassword: String
    var upstreamRole: String
    var upstreamScopesCSV: String

    var localLLMProvider: GatewayLocalLLMProviderKind
    var localLLMBaseURL: String
    var localLLMAPIKey: String
    var localLLMModel: String
    var localLLMToolCallingMode: GatewayLocalLLMToolCallingMode

    var telegramBotToken: String
    var telegramDefaultChatID: String

    var enableLocalDeviceTools: Bool
    var disabledToolNames: Set<String>

    /// Maximum characters injected per bootstrap file (skills, AGENTS.md, etc.).
    var bootstrapPerFileMaxChars: Int
    /// Total character budget for all bootstrap-injected files combined.
    var bootstrapTotalMaxChars: Int

    static let `default` = TVOSGatewayControlPlaneSettings(
        authMode: .none,
        authToken: "",
        authPassword: "",
        upstreamURL: "",
        upstreamToken: "",
        upstreamPassword: "",
        upstreamRole: "node",
        upstreamScopesCSV: "",
        localLLMProvider: .disabled,
        localLLMBaseURL: "",
        localLLMAPIKey: "",
        localLLMModel: "",
        localLLMToolCallingMode: .auto,
        telegramBotToken: "",
        telegramDefaultChatID: "",
        enableLocalDeviceTools: true,
        disabledToolNames: [],
        bootstrapPerFileMaxChars: GatewayBootstrapConfig.default.perFileMaxChars,
        bootstrapTotalMaxChars: GatewayBootstrapConfig.default.totalMaxChars)

    /// Suggested LLM defaults shown in the provider editor when no provider
    /// has been configured yet.  Kept separate from `default` so that a fresh
    /// install starts unconfigured (triggering the setup prompt).
    static let suggestedLLMProvider: GatewayLocalLLMProviderKind = .grokCompatible
    static let suggestedLLMBaseURL = "https://api.x.ai/v1"
    static let suggestedLLMModel = "grok-4-1-fast-non-reasoning"
}

private struct TVOSTelegramPairingRequest: Codable, Sendable, Equatable {
    var id: String
    var code: String
    var createdAtMs: Int64
    var lastSeenAtMs: Int64
    var meta: [String: String]
}

private struct TVOSTelegramPairingStore: Codable, Sendable, Equatable {
    var version: Int
    var lastUpdateID: Int64
    var allowFrom: [String]
    var requests: [TVOSTelegramPairingRequest]

    static let empty = TVOSTelegramPairingStore(
        version: 1,
        lastUpdateID: 0,
        allowFrom: [],
        requests: [])
}

private struct TVOSTelegramInboundUpdate: Sendable {
    let updateID: Int64
    let chatID: String
    let senderID: String
    let username: String?
    let firstName: String?
    let chatType: String?
    let text: String?
}

private enum TVOSRuntimeAdminBridgeError: LocalizedError {
    case runtimeUnavailable
    case invalidRequest(String)

    var errorDescription: String? {
        switch self {
        case .runtimeUnavailable:
            "runtime unavailable"
        case let .invalidRequest(message):
            message
        }
    }
}

private actor TVOSRuntimeAdminBridge: GatewayLocalMethodRouterAdminBridge {
    private weak var runtime: TVOSLocalGatewayRuntime?

    init(runtime: TVOSLocalGatewayRuntime) {
        self.runtime = runtime
    }

    func configGet(nowMs: Int64) async throws -> GatewayJSONValue {
        guard let runtime = self.runtime else {
            throw TVOSRuntimeAdminBridgeError.runtimeUnavailable
        }
        return await runtime.adminConfigSnapshot(nowMs: nowMs)
    }

    func configSet(params: GatewayJSONValue, nowMs: Int64) async throws -> GatewayJSONValue {
        guard let runtime = self.runtime else {
            throw TVOSRuntimeAdminBridgeError.runtimeUnavailable
        }
        return try await runtime.adminConfigSet(params: params, nowMs: nowMs)
    }

    func runtimeRestart(nowMs: Int64) async throws -> GatewayJSONValue {
        guard let runtime = self.runtime else {
            throw TVOSRuntimeAdminBridgeError.runtimeUnavailable
        }
        return await runtime.adminRuntimeRestart(nowMs: nowMs)
    }

    func pairingList(params: GatewayJSONValue, nowMs: Int64) async throws -> GatewayJSONValue {
        guard let runtime = self.runtime else {
            throw TVOSRuntimeAdminBridgeError.runtimeUnavailable
        }
        return try await runtime.adminPairingList(params: params, nowMs: nowMs)
    }

    func pairingApprove(params: GatewayJSONValue, nowMs: Int64) async throws -> GatewayJSONValue {
        guard let runtime = self.runtime else {
            throw TVOSRuntimeAdminBridgeError.runtimeUnavailable
        }
        return try await runtime.adminPairingApprove(params: params, nowMs: nowMs)
    }

    func backupExport(nowMs: Int64) async throws -> GatewayJSONValue {
        guard let runtime = self.runtime else {
            throw TVOSRuntimeAdminBridgeError.runtimeUnavailable
        }
        return try await runtime.adminBackupExport(nowMs: nowMs)
    }

    func backupImport(params: GatewayJSONValue, nowMs: Int64) async throws -> GatewayJSONValue {
        guard let runtime = self.runtime else {
            throw TVOSRuntimeAdminBridgeError.runtimeUnavailable
        }
        return try await runtime.adminBackupImport(params: params, nowMs: nowMs)
    }
}

// MARK: - Device Tool Bridge

#if os(iOS)
final class DeviceToolBridgeImpl: GatewayDeviceToolBridge, @unchecked Sendable {
    private let reminders: any RemindersServicing
    private let calendar: any CalendarServicing
    private let contacts: any ContactsServicing
    private let location: any LocationServicing
    private let photos: any PhotosServicing
    private let camera: any CameraServicing
    private let motion: any MotionServicing

    init(
        reminders: any RemindersServicing,
        calendar: any CalendarServicing,
        contacts: any ContactsServicing,
        location: any LocationServicing,
        photos: any PhotosServicing,
        camera: any CameraServicing,
        motion: any MotionServicing)
    {
        self.reminders = reminders
        self.calendar = calendar
        self.contacts = contacts
        self.location = location
        self.photos = photos
        self.camera = camera
        self.motion = motion
    }

    func supportedCommands() -> [String] {
        [
            "reminders.list", "reminders.add",
            "calendar.events", "calendar.add",
            "contacts.search", "contacts.add",
            "location.get",
            "photos.latest",
            "camera.snap",
            "motion.activity", "motion.pedometer",
            "credentials.get", "credentials.set",
            "credentials.delete",
        ]
    }

    func execute(command: String, params: GatewayJSONValue?) async -> GatewayLocalTooling.ToolResult {
        do {
            switch command {
            case "reminders.list":
                let p = Self.decodeParams(OpenClawRemindersListParams.self, from: params)
                    ?? OpenClawRemindersListParams()
                let result = try await self.reminders.list(params: p)
                return Self.encodeResult(command: command, payload: result)

            case "reminders.add":
                guard let p = Self.decodeParams(OpenClawRemindersAddParams.self, from: params) else {
                    return GatewayLocalTooling.ToolResult(payload: .null, error: "invalid reminders.add params: title required")
                }
                let result = try await self.reminders.add(params: p)
                return Self.encodeResult(command: command, payload: result)

            case "calendar.events":
                let p = Self.decodeParams(OpenClawCalendarEventsParams.self, from: params)
                    ?? OpenClawCalendarEventsParams()
                let result = try await self.calendar.events(params: p)
                return Self.encodeResult(command: command, payload: result)

            case "calendar.add":
                guard let p = Self.decodeParams(OpenClawCalendarAddParams.self, from: params) else {
                    return GatewayLocalTooling.ToolResult(payload: .null, error: "invalid calendar.add params")
                }
                let result = try await self.calendar.add(params: p)
                return Self.encodeResult(command: command, payload: result)

            case "contacts.search":
                let p = Self.decodeParams(OpenClawContactsSearchParams.self, from: params)
                    ?? OpenClawContactsSearchParams()
                let result = try await self.contacts.search(params: p)
                return Self.encodeResult(command: command, payload: result)

            case "contacts.add":
                guard let p = Self.decodeParams(OpenClawContactsAddParams.self, from: params) else {
                    return GatewayLocalTooling.ToolResult(payload: .null, error: "invalid contacts.add params")
                }
                let result = try await self.contacts.add(params: p)
                return Self.encodeResult(command: command, payload: result)

            case "location.get":
                let p = Self.decodeParams(OpenClawLocationGetParams.self, from: params)
                    ?? OpenClawLocationGetParams()
                let desired = p.desiredAccuracy ?? .balanced
                let location = try await self.location.currentLocation(
                    params: p, desiredAccuracy: desired,
                    maxAgeMs: p.maxAgeMs, timeoutMs: p.timeoutMs)
                let isPrecise = await self.location.accuracyAuthorization() == .fullAccuracy
                let payload: [String: GatewayJSONValue] = [
                    "ok": .bool(true),
                    "command": .string(command),
                    "lat": .double(location.coordinate.latitude),
                    "lon": .double(location.coordinate.longitude),
                    "accuracyMeters": .double(location.horizontalAccuracy),
                    "altitudeMeters": location.verticalAccuracy >= 0
                        ? .double(location.altitude) : .null,
                    "speedMps": location.speed >= 0
                        ? .double(location.speed) : .null,
                    "headingDeg": location.course >= 0
                        ? .double(location.course) : .null,
                    "timestamp": .string(
                        ISO8601DateFormatter().string(from: location.timestamp)),
                    "isPrecise": .bool(isPrecise),
                ]
                return GatewayLocalTooling.ToolResult(payload: .object(payload), error: nil)

            case "photos.latest":
                let p = Self.decodeParams(OpenClawPhotosLatestParams.self, from: params)
                    ?? OpenClawPhotosLatestParams()
                let result = try await self.photos.latest(params: p)
                return Self.encodeResult(command: command, payload: result)

            case "camera.snap":
                let p = Self.decodeParams(OpenClawCameraSnapParams.self, from: params)
                    ?? OpenClawCameraSnapParams()
                let res = try await self.camera.snap(params: p)
                let payload: [String: GatewayJSONValue] = [
                    "ok": .bool(true),
                    "command": .string(command),
                    "format": .string(res.format),
                    "base64": .string(res.base64),
                    "width": .integer(Int64(res.width)),
                    "height": .integer(Int64(res.height)),
                ]
                return GatewayLocalTooling.ToolResult(payload: .object(payload), error: nil)

            case "motion.activity":
                let p = Self.decodeParams(OpenClawMotionActivityParams.self, from: params)
                    ?? OpenClawMotionActivityParams()
                let result = try await self.motion.activities(params: p)
                return Self.encodeResult(command: command, payload: result)

            case "motion.pedometer":
                let p = Self.decodeParams(OpenClawPedometerParams.self, from: params)
                    ?? OpenClawPedometerParams()
                let result = try await self.motion.pedometer(params: p)
                return Self.encodeResult(command: command, payload: result)

            case "credentials.get":
                guard let service = params?.objectValue?["service"]?.stringValue,
                      !service.isEmpty
                else {
                    return GatewayLocalTooling.ToolResult(
                        payload: .null,
                        error: "credentials.get: 'service' param required")
                }
                let key = KeychainStore.loadString(
                    service: "ai.openclaw.skill.\(service)",
                    account: "api_key")
                if let key {
                    return GatewayLocalTooling.ToolResult(
                        payload: .object([
                            "ok": .bool(true),
                            "command": .string(command),
                            "service": .string(service),
                            "hasKey": .bool(true),
                            "key": .string(key),
                        ]), error: nil)
                } else {
                    return GatewayLocalTooling.ToolResult(
                        payload: .object([
                            "ok": .bool(true),
                            "command": .string(command),
                            "service": .string(service),
                            "hasKey": .bool(false),
                        ]), error: nil)
                }

            case "credentials.set":
                guard let obj = params?.objectValue,
                      let service = obj["service"]?.stringValue,
                      !service.isEmpty,
                      let key = obj["key"]?.stringValue,
                      !key.isEmpty
                else {
                    return GatewayLocalTooling.ToolResult(
                        payload: .null,
                        error: "credentials.set: 'service' and 'key' params required")
                }
                let saved = KeychainStore.saveString(
                    key,
                    service: "ai.openclaw.skill.\(service)",
                    account: "api_key")
                if saved {
                    return GatewayLocalTooling.ToolResult(
                        payload: .object([
                            "ok": .bool(true),
                            "command": .string(command),
                            "service": .string(service),
                            "message": .string("API key stored securely"),
                        ]), error: nil)
                } else {
                    return GatewayLocalTooling.ToolResult(
                        payload: .null,
                        error: "credentials.set: failed to save to keychain")
                }

            case "credentials.delete":
                guard let service = params?.objectValue?["service"]?.stringValue,
                      !service.isEmpty
                else {
                    return GatewayLocalTooling.ToolResult(
                        payload: .null,
                        error: "credentials.delete: 'service' param required")
                }
                _ = KeychainStore.delete(
                    service: "ai.openclaw.skill.\(service)",
                    account: "api_key")
                return GatewayLocalTooling.ToolResult(
                    payload: .object([
                        "ok": .bool(true),
                        "command": .string(command),
                        "service": .string(service),
                        "message": .string("API key removed"),
                    ]), error: nil)

            default:
                return GatewayLocalTooling.ToolResult(
                    payload: .null, error: "unsupported device command: \(command)")
            }
        } catch {
            return GatewayLocalTooling.ToolResult(
                payload: .null, error: "\(command) failed: \(error.localizedDescription)")
        }
    }

    private static func decodeParams<T: Decodable>(_ type: T.Type, from value: GatewayJSONValue?) -> T? {
        guard let value else { return nil }
        guard let data = try? JSONEncoder().encode(value) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    private static func encodeResult(
        command: String,
        payload: some Encodable) -> GatewayLocalTooling.ToolResult
    {
        guard let data = try? JSONEncoder().encode(payload),
              let json = try? JSONDecoder().decode(GatewayJSONValue.self, from: data)
        else {
            return GatewayLocalTooling.ToolResult(payload: .null, error: "\(command): encoding error")
        }
        var result: [String: GatewayJSONValue] = ["ok": .bool(true), "command": .string(command)]
        if case let .object(obj) = json {
            for (key, value) in obj { result[key] = value }
        } else {
            result["payload"] = json
        }
        return GatewayLocalTooling.ToolResult(payload: .object(result), error: nil)
    }
}
#endif

@MainActor
@Observable
final class TVOSLocalGatewayRuntime {
    private static let runtimeLogger = Logger(subsystem: "ai.openclaw.ios", category: "OpenClawTV.Runtime")

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

    // Primary WebSocket listener used by OpenClaw clients.
    private(set) var listenerState: ListenerState = .stopped
    private(set) var listenerPort: UInt16?
    private(set) var listenerErrorText: String?

    // Optional debug TCP listener for raw JSON-line testing.
    private(set) var tcpListenerState: ListenerState = .stopped
    private(set) var tcpListenerPort: UInt16?
    private(set) var tcpListenerErrorText: String?

    // Optional upstream full gateway used for delegated Node-only methods.
    private(set) var upstreamConfigured: Bool = false
    private(set) var upstreamURLText: String?
    private(set) var upstreamConfigErrorText: String?
    private(set) var lastUpstreamProbeSucceeded: Bool?
    private(set) var lastUpstreamProbeErrorText: String?

    private(set) var listenerAuthMode: GatewayCoreAuthMode
    private(set) var listenerAuthHint: String?
    private(set) var controlPlaneSettings: TVOSGatewayControlPlaneSettings
    private(set) var localLLMConfigured: Bool
    private(set) var localLLMProviderLabel: String
    private(set) var localLLMConfigErrorText: String?

    private(set) var webSocketRetryAttempt: Int = 0
    private(set) var webSocketRetryDelaySeconds: Int?
    private(set) var tcpRetryAttempt: Int = 0
    private(set) var tcpRetryDelaySeconds: Int?

    private(set) var localIPv4Address: String?
    private(set) var localIPv4Addresses: [String]

    private(set) var lastProbeSucceeded: Bool?
    private(set) var lastWebSocketProbeSucceeded: Bool?
    private(set) var lastWebSocketProbeErrorText: String?
    private(set) var lastTCPProbeSucceeded: Bool?
    private(set) var lastTCPProbeErrorText: String?
    private(set) var lastLocalLLMProbeSucceeded: Bool?
    private(set) var lastLocalLLMProbeErrorText: String?
    private(set) var lastLocalLLMProbeResponseText: String?
    private(set) var lastAgentRunProbeSucceeded: Bool?
    private(set) var lastAgentRunProbeErrorText: String?
    private(set) var lastAgentRunProbeResponseText: String?
    private(set) var lastAgentStatusProbeSucceeded: Bool?
    private(set) var lastAgentStatusProbeErrorText: String?
    private(set) var lastAgentStatusProbeResponseText: String?
    private(set) var lastAgentAbortProbeSucceeded: Bool?
    private(set) var lastAgentAbortProbeErrorText: String?
    private(set) var lastAgentAbortProbeResponseText: String?
    private(set) var lastAgentRunID: String?
    private(set) var chatSessionKey: String
    var chatAssistantName: String {
        Self.bootstrapAssistantName(workspacePath: Self.defaultBootstrapWorkspacePath()) ?? "AnemllClaw"
    }

    private(set) var showExternalTelegramMessagesInChat: Bool
    private(set) var chatTurns: [TVOSGatewayChatTurn]
    private(set) var chatSendInProgress: Bool
    private(set) var chatProgressText: String?
    private(set) var chatLastErrorText: String?
    private(set) var diagnosticsLog: [TVOSGatewayRuntimeLogEntry]

    private(set) var lanAccessEnabled: Bool
    #if os(iOS)
    private var deviceToolBridge: DeviceToolBridgeImpl?
    #endif

    private var deviceBridgeConfigured: Bool {
        #if os(iOS)
        return self.deviceToolBridge != nil
        #else
        return false
        #endif
    }

    private let webSocketListenPortPreference: UInt16
    private let tcpListenPortPreference: UInt16
    private let exposeTCPListener: Bool
    private var gatewayAuthConfig: GatewayCoreAuthConfig
    private let transportOverride: GatewayLoopbackTransport?

    /// The loopback host used for in-process RPC.  Exposed so that
    /// ``LocalGatewayChatTransport`` (and similar adapters) can invoke
    /// gateway methods without a WebSocket round-trip.
    private(set) var host: GatewayLoopbackHost?
    private var webSocketServer: GatewayWebSocketServer?
    private var tcpServer: GatewayTCPJSONServer?
    private var upstreamClient: GatewayUpstreamWebSocketClient?

    private var webSocketRetryTask: Task<Void, Never>?
    private var tcpRetryTask: Task<Void, Never>?
    private var chatHistoryPollTask: Task<Void, Never>?
    private var telegramPairingPollTask: Task<Void, Never>?
    private var networkWatchdogTask: Task<Void, Never>?
    /// Tracks the last known set of local IPv4 addresses so the watchdog
    /// can detect interface changes (e.g. WiFi reconnect, new DHCP lease).
    private var networkWatchdogLastAddresses: Set<String> = []
    private var sessionChatTurns: [TVOSGatewayChatTurn]
    private var mirroredTelegramChatTurns: [TVOSGatewayChatTurn]
    private var chatSendStartedAt: Date?
    private var runtimeTransitionTask: Task<Void, Never> = Task {}
    private var runtimeTransitionInProgress = false
    private var telegramPairingStorePath: URL
    private var telegramPairingStore: TVOSTelegramPairingStore
    private(set) var lastTelegramPairingPollSucceeded: Bool?
    private(set) var lastTelegramPairingPollErrorText: String?

    private static let maxDiagnosticsLogEntries = 150
    private static let listenerRestartQuiesceDurationNanoseconds: UInt64 = 120_000_000
    private static let defaultChatSessionKey = "main"
    private static let defaultChatHistoryLimit = 240
    private static let chatProgressPollIntervalNanoseconds: UInt64 = 700_000_000
    private static let telegramPairingPollIntervalNanoseconds: UInt64 = 3_000_000_000
    private static let telegramPairingCodeLength = 8
    private static let telegramPairingCodeAlphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
    private static let telegramPairingPendingTTLms: Int64 = 60 * 60 * 1000
    private static let telegramPairingPendingMax = 5
    private static let telegramChatHistoryLimit = 16
    private static let telegramReplyMaxChars = 3800
    private static let telegramReplyPollAttempts = 16
    private static let telegramReplyPollDelayNanoseconds: UInt64 = 750_000_000
    private static let showExternalTelegramMessagesInChatDefaultsKey =
        "gateway.tvos.chat.showExternalTelegramMessagesInChat"
    private static let maxMirroredTelegramChatTurns = 120

    init(
        exposeTCPListener: Bool = true,
        listenPort: UInt16 = 18789,
        tcpDebugPort: UInt16 = 18790,
        transport: GatewayLoopbackTransport? = nil,
        upstreamConfig: GatewayUpstreamWebSocketConfig? = nil,
        tcpAuthConfig: GatewayCoreAuthConfig = .none)
    {
        self.exposeTCPListener = exposeTCPListener
        self.webSocketListenPortPreference = listenPort
        self.tcpListenPortPreference = tcpDebugPort
        self.transportOverride = transport
        self.lanAccessEnabled = UserDefaults.standard.bool(forKey: "network.lanAccess.enabled")

        var settings = Self.loadControlPlaneSettings()
        if tcpAuthConfig.mode != .none {
            settings.authMode = tcpAuthConfig.mode
            settings.authToken = tcpAuthConfig.token ?? ""
            settings.authPassword = tcpAuthConfig.password ?? ""
        }
        if let upstreamConfig {
            settings.upstreamURL = upstreamConfig.url.absoluteString
            settings.upstreamToken = upstreamConfig.token ?? ""
            settings.upstreamPassword = upstreamConfig.password ?? ""
            settings.upstreamRole = upstreamConfig.role ?? "node"
            settings.upstreamScopesCSV = upstreamConfig.scopes?.joined(separator: ",") ?? ""
        }

        let normalizedSettings = Self.normalizedSettings(settings)
        let needsInitAuthNormalization = normalizedSettings != settings
        let initialAuthConfig = Self.makeAuthConfig(from: normalizedSettings)
        self.controlPlaneSettings = normalizedSettings
        self.gatewayAuthConfig = initialAuthConfig
        self.listenerAuthMode = initialAuthConfig.mode
        self.listenerAuthHint = Self.authHint(for: initialAuthConfig)
        self.localLLMConfigured = false
        self.localLLMProviderLabel = normalizedSettings.localLLMProvider.rawValue
        self.localLLMConfigErrorText = nil

        self.diagnosticsLog = []
        self.localIPv4Address = nil
        self.localIPv4Addresses = []
        self.lastUpstreamProbeSucceeded = nil
        self.lastUpstreamProbeErrorText = nil
        self.lastLocalLLMProbeSucceeded = nil
        self.lastLocalLLMProbeErrorText = nil
        self.lastLocalLLMProbeResponseText = nil
        self.lastAgentRunProbeSucceeded = nil
        self.lastAgentRunProbeErrorText = nil
        self.lastAgentRunProbeResponseText = nil
        self.lastAgentStatusProbeSucceeded = nil
        self.lastAgentStatusProbeErrorText = nil
        self.lastAgentStatusProbeResponseText = nil
        self.lastAgentAbortProbeSucceeded = nil
        self.lastAgentAbortProbeErrorText = nil
        self.lastAgentAbortProbeResponseText = nil
        self.lastAgentRunID = nil
        self.chatSessionKey = Self.defaultChatSessionKey
        self.showExternalTelegramMessagesInChat = Self.loadShowExternalTelegramMessagesInChat()
        self.sessionChatTurns = []
        self.mirroredTelegramChatTurns = []
        self.chatTurns = []
        self.chatSendInProgress = false
        self.chatProgressText = nil
        self.chatLastErrorText = nil

        self.host = nil
        self.webSocketServer = nil
        self.tcpServer = nil
        self.upstreamClient = nil
        self.webSocketRetryTask = nil
        self.tcpRetryTask = nil
        self.chatHistoryPollTask = nil
        self.telegramPairingPollTask = nil
        self.chatSendStartedAt = nil
        let initialTelegramPairingStorePath = Self.defaultTelegramPairingStorePath()
        self.telegramPairingStorePath = initialTelegramPairingStorePath
        self.telegramPairingStore = Self.loadTelegramPairingStore(at: initialTelegramPairingStorePath)
        self.lastTelegramPairingPollSucceeded = nil
        self.lastTelegramPairingPollErrorText = nil

        self.rebuildGatewayStack()
        self.refreshLocalNetworkAddresses()
        if needsInitAuthNormalization {
            self.appendLog("auth settings normalized during runtime init", level: .warning)
            self.logAuthNormalization(
                from: settings,
                to: normalizedSettings,
                context: "runtime init")
            Self.persistControlPlaneSettings(normalizedSettings)
            self.verifyPersistedControlPlaneSettings(normalizedSettings)
        }
        self.logControlPlaneConfigDump(context: "runtime initialized")

        self.appendLog(
            "runtime initialized wsPort=\(listenPort)"
                + " tcpDebug=\(exposeTCPListener ? "enabled" : "disabled")"
                + " auth=\(self.gatewayAuthConfig.mode.rawValue)"
                + " telegramMirrorInChat=\(self.showExternalTelegramMessagesInChat ? "on" : "off")")
        if self.upstreamConfigured {
            self.appendLog("upstream configured url=\(self.upstreamURLText ?? "(unknown)")")
        } else if let errorText = self.upstreamConfigErrorText {
            self.appendLog("upstream config error: \(errorText)", level: .error)
        } else {
            self.appendLog("upstream not configured", level: .warning)
        }
    }

    #if os(iOS)
    /// Inject native device service implementations into the runtime.
    /// Call this before ``start()`` so that device tools are available to the LLM.
    /// Triggers ``rebuildGatewayStack()`` so the router immediately picks up the bridge.
    func configureDeviceServices(
        reminders: any RemindersServicing,
        calendar: any CalendarServicing,
        contacts: any ContactsServicing,
        location: any LocationServicing,
        photos: any PhotosServicing,
        camera: any CameraServicing,
        motion: any MotionServicing)
    {
        self.deviceToolBridge = DeviceToolBridgeImpl(
            reminders: reminders,
            calendar: calendar,
            contacts: contacts,
            location: location,
            photos: photos,
            camera: camera,
            motion: motion)
        self.appendLog(
            "device tool bridge configured with \(self.deviceToolBridge?.supportedCommands().count ?? 0) commands")
        // Rebuild so the router picks up the newly configured bridge.
        self.rebuildGatewayStack()
    }
    #endif

    func start() async {
        guard !self.runtimeTransitionInProgress else {
            self.appendLog("runtime start skipped: transition in progress")
            return
        }
        guard self.state == .stopped else {
            self.appendLog("runtime start skipped: already running")
            return
        }
        await self.withRuntimeTransition("start") {
            await self.startLocked()
        }
    }

    private func withRuntimeTransition(
        _ label: String,
        operation: @escaping @MainActor () async -> Void) async
    {
        if self.runtimeTransitionInProgress {
            self.appendLog("runtime transition skipped: another transition in progress [\(label)]")
            return
        }

        self.runtimeTransitionInProgress = true
        let previousTransition = self.runtimeTransitionTask
        let nextTransition = Task { @MainActor in
            await previousTransition.value
            self.appendLog("runtime transition start [\(label)]")
            defer {
                self.runtimeTransitionInProgress = false
                self.appendLog("runtime transition end [\(label)]")
            }
            await operation()
        }

        self.runtimeTransitionTask = nextTransition
        await nextTransition.value
    }

    private func startLocked() async {
        guard self.state == .stopped else {
            self.appendLog("runtime start skipped: already running")
            return
        }

        self.refreshLocalNetworkAddresses()
        await self.host?.start()
        await self.installListenerStateCallback()
        await self.startWebSocketListenerIfNeeded()
        guard self.listenerState == .listening else {
            self.state = .stopped
            self.appendLog("runtime start aborted: websocket listener failed")
            return
        }
        // Log if we fell back to localhost.
        if let ws = self.webSocketServer, await ws.isFallbackLoopback {
            self.appendLog(
                "websocket listener fell back to localhost — LAN access unavailable",
                level: .warning)
        }
        if self.exposeTCPListener {
            await self.startTCPListenerIfNeeded()
        }
        self.state = .running
        self.startNetworkWatchdog()
        self.startTelegramPairingPollingIfNeeded()
        await self.refreshChatHistory(limit: Self.defaultChatHistoryLimit, quiet: true)
        self.appendLog(
            "runtime running ws=\(self.listenerState.rawValue) tcp=\(self.tcpListenerState.rawValue)")
    }

    func restart(with settings: TVOSGatewayControlPlaneSettings) async {
        await self.withRuntimeTransition("restart") {
            self.appendLog("runtime restart requested")

            let normalized = Self.normalizedSettings(settings)
            if normalized != settings {
                self.logAuthNormalization(from: settings, to: normalized, context: "runtime restart")
            }

            let hadRunning = self.state == .running
            if hadRunning {
                await self.stopLocked()
                try? await Task.sleep(nanoseconds: Self.listenerRestartQuiesceDurationNanoseconds)
            }

            self.controlPlaneSettings = normalized
            Self.persistControlPlaneSettings(normalized)
            self.verifyPersistedControlPlaneSettings(normalized)
            self.logControlPlaneConfigDump(context: "settings applied via restart")
            self.rebuildGatewayStack()
            self.clearErrorStates()

            if hadRunning {
                await self.startLocked()
                await self.probeHealth()
                await self.probeHealthOverWebSocket()
                await self.probeUpstreamHealth()
            }
        }
    }

    func stop() async {
        await self.withRuntimeTransition("stop") {
            await self.stopLocked()
        }
    }

    private func stopLocked() async {
        guard self.state != .stopped else { return }

        self.appendLog("runtime stop requested")
        self.stopChatProgressPolling()
        self.stopNetworkWatchdog()

        self.webSocketRetryTask?.cancel()
        self.webSocketRetryTask = nil
        self.webSocketRetryAttempt = 0
        self.webSocketRetryDelaySeconds = nil

        self.tcpRetryTask?.cancel()
        self.tcpRetryTask = nil
        self.tcpRetryAttempt = 0
        self.tcpRetryDelaySeconds = nil
        self.stopTelegramPairingPolling()

        if self.exposeTCPListener {
            await self.stopTCPListener()
        }
        await self.stopWebSocketListener()

        if let upstreamClient = self.upstreamClient {
            await upstreamClient.disconnect()
            self.appendLog("upstream disconnected")
        }

        await self.host?.stop()

        self.state = .stopped
        self.lastProbeSucceeded = nil
        self.lastWebSocketProbeSucceeded = nil
        self.lastWebSocketProbeErrorText = nil
        self.lastTCPProbeSucceeded = nil
        self.lastTCPProbeErrorText = nil
        self.lastUpstreamProbeSucceeded = nil
        self.lastUpstreamProbeErrorText = nil
        self.lastLocalLLMProbeSucceeded = nil
        self.lastLocalLLMProbeErrorText = nil
        self.lastLocalLLMProbeResponseText = nil
        self.lastAgentRunProbeSucceeded = nil
        self.lastAgentRunProbeErrorText = nil
        self.lastAgentRunProbeResponseText = nil
        self.lastAgentStatusProbeSucceeded = nil
        self.lastAgentStatusProbeErrorText = nil
        self.lastAgentStatusProbeResponseText = nil
        self.lastAgentAbortProbeSucceeded = nil
        self.lastAgentAbortProbeErrorText = nil
        self.lastAgentAbortProbeResponseText = nil
        self.lastAgentRunID = nil
        self.lastTelegramPairingPollSucceeded = nil
        self.lastTelegramPairingPollErrorText = nil
        self.chatSendInProgress = false
        self.chatProgressText = nil
        self.chatLastErrorText = nil
        self.chatSendStartedAt = nil
        self.appendLog("runtime stopped")
    }

    func clearDiagnosticsLog() {
        self.diagnosticsLog.removeAll(keepingCapacity: true)
        self.appendLog("diagnostics log cleared")
    }

    func clearErrorStates() {
        self.listenerErrorText = nil
        self.tcpListenerErrorText = nil
        self.lastWebSocketProbeErrorText = nil
        self.lastTCPProbeErrorText = nil
        self.lastUpstreamProbeErrorText = nil
        self.upstreamConfigErrorText = nil
        self.localLLMConfigErrorText = nil
        self.lastLocalLLMProbeErrorText = nil
        self.lastAgentRunProbeErrorText = nil
        self.lastAgentRunProbeResponseText = nil
        self.lastAgentStatusProbeErrorText = nil
        self.lastAgentStatusProbeResponseText = nil
        self.lastAgentAbortProbeErrorText = nil
        self.lastAgentAbortProbeResponseText = nil
        self.lastTelegramPairingPollErrorText = nil
        self.lastTelegramPairingPollSucceeded = nil
        self.chatLastErrorText = nil
        self.webSocketRetryAttempt = 0
        self.webSocketRetryDelaySeconds = nil
        self.tcpRetryAttempt = 0
        self.tcpRetryDelaySeconds = nil
        self.appendLog("error states cleared")
    }

    func applyControlPlaneSettings(_ next: TVOSGatewayControlPlaneSettings) async {
        let normalized = Self.normalizedSettings(next)
        await self.withRuntimeTransition("apply settings") {
            if normalized != next {
                self.logAuthNormalization(from: next, to: normalized, context: "apply settings")
            }

            guard normalized != self.controlPlaneSettings else {
                self.appendLog("control plane settings unchanged")
                return
            }

            let wasRunning = self.state == .running
            if wasRunning {
                await self.stopLocked()
            }

            self.controlPlaneSettings = normalized
            Self.persistControlPlaneSettings(normalized)
            self.verifyPersistedControlPlaneSettings(normalized)
            self.logControlPlaneConfigDump(context: "settings applied")
            self.rebuildGatewayStack()
            self.clearErrorStates()
            self.appendLog(
                "control plane settings applied auth=\(normalized.authMode.rawValue)"
                    + " upstream=\(Self.trimmed(normalized.upstreamURL) ?? "(none)")"
                    + " llm=\(normalized.localLLMProvider.rawValue)"
                    + " llmTools=\(normalized.localLLMToolCallingMode.rawValue)"
                    + " deviceTools=\(normalized.enableLocalDeviceTools)"
                    + " telegram=\(Self.presenceState(normalized.telegramBotToken))")

            if wasRunning {
                if self.exposeTCPListener {
                    try? await Task.sleep(nanoseconds: Self.listenerRestartQuiesceDurationNanoseconds)
                }
                await self.startLocked()
                await self.probeHealth()
                await self.probeHealthOverWebSocket()
                await self.probeUpstreamHealth()
            }
        }
    }

    func reloadPersistedControlPlaneSettings(startIfStopped: Bool = false) async {
        let persisted = Self.loadControlPlaneSettings()
        let normalized = Self.normalizedSettings(persisted)
        await self.withRuntimeTransition("reload persisted settings") {
            let wasRunning = self.state == .running
            if wasRunning {
                await self.stopLocked()
                try? await Task.sleep(nanoseconds: Self.listenerRestartQuiesceDurationNanoseconds)
            }

            self.controlPlaneSettings = normalized
            Self.persistControlPlaneSettings(normalized)
            self.verifyPersistedControlPlaneSettings(normalized)
            self.logControlPlaneConfigDump(context: "settings reloaded from persistence")
            self.rebuildGatewayStack()
            self.clearErrorStates()

            if wasRunning || startIfStopped {
                await self.startLocked()
                await self.probeHealth()
                await self.probeHealthOverWebSocket()
                await self.probeUpstreamHealth()
            }
        }
    }

    func setLanAccessEnabled(_ enabled: Bool) async {
        guard enabled != self.lanAccessEnabled else { return }
        self.lanAccessEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "network.lanAccess.enabled")
        self.appendLog("LAN access \(enabled ? "enabled" : "disabled") — restarting listeners")
        // Restart listeners with the new bind scope.
        await self.stopWebSocketListener()
        await self.startWebSocketListenerIfNeeded()
        if self.exposeTCPListener {
            await self.stopTCPListener()
            await self.startTCPListenerIfNeeded()
        }
    }

    func refreshLocalNetworkAddresses() {
        let addresses = Self.collectLocalIPv4Interfaces()
        self.localIPv4Address = addresses.first?.address
        self.localIPv4Addresses = addresses.map(\.address)
    }

    func setChatSessionKey(_ rawValue: String) async {
        let normalized = Self.normalizedSessionKey(rawValue)
        guard normalized != self.chatSessionKey else { return }
        self.chatSessionKey = normalized
        self.sessionChatTurns = []
        self.rebuildDisplayedChatTurns()
        self.chatLastErrorText = nil
        self.appendLog("chat session switched to \(normalized)")
        await self.refreshChatHistory(limit: Self.defaultChatHistoryLimit, quiet: true)
    }

    func setShowExternalTelegramMessagesInChat(_ enabled: Bool) {
        guard self.showExternalTelegramMessagesInChat != enabled else { return }
        self.showExternalTelegramMessagesInChat = enabled
        Self.persistShowExternalTelegramMessagesInChat(enabled)
        self.rebuildDisplayedChatTurns()
        self.appendLog("chat mirror external telegram messages \(enabled ? "enabled" : "disabled")")
    }

    func refreshChatHistory(limit: Int = 240, quiet: Bool = false) async {
        guard self.state == .running else {
            if !quiet {
                self.chatLastErrorText = "runtime not running"
            }
            return
        }
        guard let host = self.host else {
            if !quiet {
                self.chatLastErrorText = "runtime host unavailable"
                self.appendLog("chat history refresh failed: runtime host unavailable", level: .error)
            }
            return
        }

        let boundedLimit = max(1, min(limit, 1000))
        let request = GatewayRequestFrame(
            id: UUID().uuidString,
            method: "chat.history",
            params: .object([
                "sessionKey": .string(self.chatSessionKey),
                "limit": .integer(Int64(boundedLimit)),
            ]))

        do {
            let response = try await host.invoke(request)
            guard response.ok else {
                let message = response.error?.message ?? "chat.history failed"
                if !quiet {
                    self.chatLastErrorText = message
                    self.appendLog("chat.history failed: \(message)", level: .warning)
                }
                return
            }

            self.sessionChatTurns = Self.decodeChatTurns(from: response.payload)
            self.rebuildDisplayedChatTurns()
            if !quiet {
                self.chatLastErrorText = nil
            }
        } catch {
            if !quiet {
                self.chatLastErrorText = error.localizedDescription
                self.appendLog("chat.history threw: \(error.localizedDescription)", level: .error)
            }
        }
    }

    func sendChatMessage(_ rawMessage: String) async {
        let message = rawMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else { return }

        guard self.state == .running else {
            self.chatLastErrorText = "runtime not running"
            self.appendLog("chat.send skipped: runtime not running", level: .warning)
            return
        }
        guard let host = self.host else {
            self.chatLastErrorText = "runtime host unavailable"
            self.appendLog("chat.send failed: runtime host unavailable", level: .error)
            return
        }
        guard !self.chatSendInProgress else {
            self.appendLog("chat.send skipped: another chat send is already in progress", level: .warning)
            return
        }

        self.chatSendInProgress = true
        self.chatSendStartedAt = Date()
        self.chatProgressText = "Sending user message…"
        self.chatLastErrorText = nil
        await self.refreshChatHistory(limit: Self.defaultChatHistoryLimit, quiet: true)
        self.startChatProgressPolling()
        defer {
            self.stopChatProgressPolling()
            self.chatSendInProgress = false
            self.chatSendStartedAt = nil
            self.chatProgressText = nil
        }

        self.appendLog("chat.send start session=\(self.chatSessionKey) chars=\(message.count)")
        let request = GatewayRequestFrame(
            id: UUID().uuidString,
            method: "chat.send",
            params: .object([
                "sessionKey": .string(self.chatSessionKey),
                "message": .string(message),
                "thinking": .string("low"),
                "idempotencyKey": .string(UUID().uuidString),
            ]))

        do {
            let response = try await host.invoke(request)
            guard response.ok else {
                let code = response.error?.code ?? "UNKNOWN"
                let message = response.error?.message ?? "chat.send failed"
                self.chatLastErrorText = message
                self.appendLog("chat.send failed code=\(code) message=\(message)", level: .error)
                return
            }

            self.chatProgressText = "Refreshing conversation…"
            await self.refreshChatHistory(limit: Self.defaultChatHistoryLimit, quiet: true)
            let runID = Self.extractChatRunID(from: response.payload) ?? "(unknown)"
            self.appendLog("chat.send ok runId=\(runID)")
        } catch {
            self.chatLastErrorText = error.localizedDescription
            self.appendLog("chat.send threw: \(error.localizedDescription)", level: .error)
            return
        }
    }

    private func startChatProgressPolling() {
        self.stopChatProgressPolling()
        self.chatHistoryPollTask = Task { @MainActor in
            while !Task.isCancelled, self.chatSendInProgress {
                try? await Task.sleep(nanoseconds: Self.chatProgressPollIntervalNanoseconds)
                guard !Task.isCancelled, self.chatSendInProgress else { break }

                await self.refreshChatHistory(limit: Self.defaultChatHistoryLimit, quiet: true)
                if let startedAt = self.chatSendStartedAt {
                    let elapsed = max(0, Int(Date().timeIntervalSince(startedAt)))
                    self.chatProgressText = "Assistant is thinking… \(elapsed)s"
                } else {
                    self.chatProgressText = "Assistant is thinking…"
                }
            }
        }
    }

    private func stopChatProgressPolling() {
        self.chatHistoryPollTask?.cancel()
        self.chatHistoryPollTask = nil
    }

    private func rebuildDisplayedChatTurns() {
        if self.showExternalTelegramMessagesInChat {
            self.chatTurns = self.sessionChatTurns + self.mirroredTelegramChatTurns
        } else {
            self.chatTurns = self.sessionChatTurns
        }
    }

    private func mirrorTelegramInboundChatMessage(senderID: String, text: String) {
        self.appendMirroredTelegramChatTurn(
            role: "user",
            senderID: senderID,
            text: text,
            directionPrefix: "Telegram -> AnemllClaw")
    }

    private func mirrorTelegramOutboundChatReply(senderID: String, text: String) {
        self.appendMirroredTelegramChatTurn(
            role: "assistant",
            senderID: senderID,
            text: text,
            directionPrefix: "AnemllClaw -> Telegram")
    }

    private func appendMirroredTelegramChatTurn(
        role: String,
        senderID: String,
        text: String,
        directionPrefix: String)
    {
        guard self.showExternalTelegramMessagesInChat else { return }
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else { return }

        let now = Date()
        let timestampMs = Int64((now.timeIntervalSince1970 * 1000).rounded())
        let maskedSenderID = Self.maskedDisplayUserID(senderID)
        let displayText = "[\(directionPrefix) @\(maskedSenderID)] \(trimmedText)"
        let turn = TVOSGatewayChatTurn(
            id: "telegram-mirror|\(timestampMs)|\(role)|\(maskedSenderID)|\(UUID().uuidString)",
            role: role,
            text: displayText,
            timestamp: now,
            runID: "telegram:\(maskedSenderID)")

        self.mirroredTelegramChatTurns.append(turn)
        if self.mirroredTelegramChatTurns.count > Self.maxMirroredTelegramChatTurns {
            self.mirroredTelegramChatTurns.removeFirst(
                self.mirroredTelegramChatTurns.count - Self.maxMirroredTelegramChatTurns)
        }
        self.rebuildDisplayedChatTurns()
    }

    func probeHealth(nowMs: Int64 = GatewayCore.currentTimestampMs()) async {
        guard self.state == .running else {
            self.lastProbeSucceeded = nil
            return
        }
        guard let host = self.host else {
            self.lastProbeSucceeded = false
            self.appendLog("in-process probe failed: runtime host unavailable", level: .error)
            return
        }
        do {
            let response = try await host.invoke(
                GatewayRequestFrame(id: UUID().uuidString, method: "health"),
                nowMs: nowMs)
            self.lastProbeSucceeded = response.ok
            if response.ok {
                self.appendLog("in-process probe ok")
            } else {
                self.appendLog(
                    "in-process probe failed: \(response.error?.message ?? "unknown error")",
                    level: .warning)
            }
        } catch {
            self.lastProbeSucceeded = false
            self.appendLog("in-process probe threw: \(error.localizedDescription)", level: .error)
        }
    }

    func probeLocalLLM(prompt: String = "Who are you?") async {
        guard self.state == .running else {
            self.appendLog("local llm probe skipped: runtime not running", level: .warning)
            self.lastLocalLLMProbeSucceeded = nil
            self.lastLocalLLMProbeErrorText = nil
            self.lastLocalLLMProbeResponseText = nil
            return
        }
        guard self.localLLMConfigured else {
            let message = if self.controlPlaneSettings.localLLMProvider == .disabled {
                "local llm provider is disabled"
            } else {
                "local llm config is incomplete"
            }
            self.lastLocalLLMProbeSucceeded = false
            self.lastLocalLLMProbeErrorText = message
            self.lastLocalLLMProbeResponseText = nil
            self.appendLog("local llm probe skipped: \(message)", level: .warning)
            return
        }
        guard let host = self.host else {
            self.lastLocalLLMProbeSucceeded = false
            self.lastLocalLLMProbeErrorText = "runtime host unavailable"
            self.lastLocalLLMProbeResponseText = nil
            self.appendLog("local llm probe failed: runtime host unavailable", level: .error)
            return
        }

        let sessionKey = "tvos-agentic-llm-probe-\(UUID().uuidString.lowercased())"

        // Clean up the probe session when done so it doesn't appear as a ghost thread.
        defer {
            Task { [host] in
                let deleteRequest = GatewayRequestFrame(
                    id: UUID().uuidString,
                    method: "sessions.delete",
                    params: .object([
                        "key": .string(sessionKey),
                        "deleteTranscript": .bool(true),
                    ]))
                _ = try? await host.invoke(deleteRequest)
            }
        }

        let normalizedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Who are you?"
            : prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let baseURLText = Self.trimmed(self.controlPlaneSettings.localLLMBaseURL) ?? "(none)"
        let modelText = Self.trimmed(self.controlPlaneSettings.localLLMModel) ?? "(none)"
        self.appendLog(
            "local llm probe start provider=\(self.controlPlaneSettings.localLLMProvider.rawValue)"
                + " baseURL=\(baseURLText) model=\(modelText) session=\(sessionKey)"
                + " skipPreamble=1 disableTools=1")

        do {
            let sendRequest = GatewayRequestFrame(
                id: UUID().uuidString,
                method: "chat.send",
                params: .object([
                    "sessionKey": .string(sessionKey),
                    "message": .string(normalizedPrompt),
                    "thinking": .string("low"),
                    "historyLimit": .integer(12),
                    "skipPreamble": .bool(true),
                    "disableTools": .bool(true),
                    "idempotencyKey": .string(UUID().uuidString),
                ]))
            let sendResponse = try await host.invoke(sendRequest)
            guard sendResponse.ok else {
                let message = sendResponse.error?.message ?? "local llm chat.send failed"
                self.lastLocalLLMProbeSucceeded = false
                self.lastLocalLLMProbeErrorText = message
                self.lastLocalLLMProbeResponseText = nil
                self.appendLog(
                    "local llm probe chat.send failed code=\(sendResponse.error?.code ?? "UNKNOWN") message=\(message)",
                    level: .error)
                return
            }

            let historyRequest = GatewayRequestFrame(
                id: UUID().uuidString,
                method: "chat.history",
                params: .object([
                    "sessionKey": .string(sessionKey),
                    "limit": .integer(12),
                ]))
            let historyResponse = try await host.invoke(historyRequest)
            guard historyResponse.ok else {
                let message = historyResponse.error?.message ?? "local llm chat.history failed"
                self.lastLocalLLMProbeSucceeded = false
                self.lastLocalLLMProbeErrorText = message
                self.lastLocalLLMProbeResponseText = nil
                self.appendLog(
                    "local llm probe chat.history failed"
                        + " code=\(historyResponse.error?.code ?? "UNKNOWN")"
                        + " message=\(message)",
                    level: .error)
                return
            }

            let replyText = Self.latestAssistantReplyText(from: historyResponse.payload)
            self.lastLocalLLMProbeSucceeded = true
            self.lastLocalLLMProbeErrorText = nil
            self.lastLocalLLMProbeResponseText = replyText
            if let replyText {
                self.appendLog("local llm probe ok prompt=\"\(normalizedPrompt)\"")
                self.appendLog("local llm probe reply: \(replyText)")
            } else {
                self.appendLog("local llm probe ok but no assistant reply found in history", level: .warning)
            }
        } catch {
            self.lastLocalLLMProbeSucceeded = false
            self.lastLocalLLMProbeErrorText = error.localizedDescription
            self.lastLocalLLMProbeResponseText = nil
            self.appendLog("local llm probe threw: \(error.localizedDescription)", level: .error)
        }
    }

    func probeAgentRun() async {
        let runID = "tvos-agent-run-\(UUID().uuidString)"
        let sessionKey = "tvos-agent-session"
        let goal = "Summarize this device readiness in one short sentence."

        guard self.state == .running else {
            self.appendLog("agent run probe skipped: runtime not running", level: .warning)
            self.lastAgentRunProbeSucceeded = nil
            self.lastAgentRunProbeErrorText = nil
            self.lastAgentRunProbeResponseText = nil
            return
        }
        guard let host = self.host else {
            self.lastAgentRunProbeSucceeded = false
            self.lastAgentRunProbeErrorText = "runtime host unavailable"
            self.lastAgentRunProbeResponseText = nil
            self.appendLog("agent run probe failed: runtime host unavailable", level: .error)
            return
        }

        self.appendLog("agent run probe start runId=\(runID)")
        let request = GatewayRequestFrame(
            id: UUID().uuidString,
            method: "agents.run",
            params: .object([
                "runId": .string(runID),
                "sessionKey": .string(sessionKey),
                "goal": .string(goal),
                "maxSteps": .integer(1),
            ]))

        do {
            let response = try await host.invoke(request)
            self.lastAgentRunID = Self.extractAgentRunID(from: response.payload) ?? runID
            self.lastAgentRunProbeSucceeded = response.ok
            self.lastAgentRunProbeErrorText = response.error?.message
            if response.ok {
                self.lastAgentRunProbeResponseText = Self.formatAgentSnapshot(from: response.payload)
                self.appendLog(
                    "agent run probe ok runId=\(self.lastAgentRunID ?? runID)")
                if let snapshot = self.lastAgentRunProbeResponseText, !snapshot.isEmpty {
                    self.appendLog("agent run probe snapshot: \(snapshot)")
                }
            } else {
                let codeText = response.error?.code ?? "UNKNOWN"
                self.lastAgentRunProbeResponseText = nil
                self.appendLog(
                    "agent run probe failed code=\(codeText) message=\(response.error?.message ?? "unknown error")",
                    level: .warning)
            }
        } catch {
            self.lastAgentRunProbeSucceeded = false
            self.lastAgentRunProbeErrorText = error.localizedDescription
            self.lastAgentRunProbeResponseText = nil
            self.appendLog("agent run probe threw: \(error.localizedDescription)", level: .error)
        }
    }

    func probeAgentStatus() async {
        guard self.state == .running else {
            self.appendLog("agent status probe skipped: runtime not running", level: .warning)
            self.lastAgentStatusProbeSucceeded = nil
            self.lastAgentStatusProbeErrorText = nil
            self.lastAgentStatusProbeResponseText = nil
            return
        }
        guard let runID = self.lastAgentRunID else {
            self.lastAgentStatusProbeSucceeded = false
            self.lastAgentStatusProbeErrorText = "no active agent run id"
            self.lastAgentStatusProbeResponseText = nil
            self.appendLog("agent status probe skipped: no known run id", level: .warning)
            return
        }
        guard let host = self.host else {
            self.lastAgentStatusProbeSucceeded = false
            self.lastAgentStatusProbeErrorText = "runtime host unavailable"
            self.lastAgentStatusProbeResponseText = nil
            self.appendLog("agent status probe failed: runtime host unavailable", level: .error)
            return
        }

        self.appendLog("agent status probe start runId=\(runID)")
        let request = GatewayRequestFrame(
            id: UUID().uuidString,
            method: "agents.status",
            params: .object(["runId": .string(runID)]))
        do {
            let response = try await host.invoke(request)
            self.lastAgentStatusProbeSucceeded = response.ok
            self.lastAgentStatusProbeErrorText = response.error?.message
            if response.ok {
                self.lastAgentStatusProbeResponseText = Self.formatAgentSnapshot(from: response.payload)
                self.appendLog("agent status ok runId=\(runID)")
                if let snapshot = self.lastAgentStatusProbeResponseText, !snapshot.isEmpty {
                    self.appendLog("agent status snapshot: \(snapshot)")
                }
            } else {
                let codeText = response.error?.code ?? "UNKNOWN"
                self.lastAgentStatusProbeResponseText = nil
                self.appendLog(
                    "agent status probe failed code=\(codeText) message=\(response.error?.message ?? "unknown error")",
                    level: .warning)
            }
        } catch {
            self.lastAgentStatusProbeSucceeded = false
            self.lastAgentStatusProbeErrorText = error.localizedDescription
            self.lastAgentStatusProbeResponseText = nil
            self.appendLog("agent status probe threw: \(error.localizedDescription)", level: .error)
        }
    }

    func abortAgentRun() async {
        guard self.state == .running else {
            self.appendLog("agent abort skipped: runtime not running", level: .warning)
            self.lastAgentAbortProbeSucceeded = nil
            self.lastAgentAbortProbeErrorText = nil
            self.lastAgentAbortProbeResponseText = nil
            return
        }
        guard let runID = self.lastAgentRunID else {
            self.lastAgentAbortProbeSucceeded = false
            self.lastAgentAbortProbeErrorText = "no active agent run id"
            self.lastAgentAbortProbeResponseText = nil
            self.appendLog("agent abort skipped: no known run id", level: .warning)
            return
        }
        guard let host = self.host else {
            self.lastAgentAbortProbeSucceeded = false
            self.lastAgentAbortProbeErrorText = "runtime host unavailable"
            self.lastAgentAbortProbeResponseText = nil
            self.appendLog("agent abort failed: runtime host unavailable", level: .error)
            return
        }

        self.appendLog("agent abort start runId=\(runID)")
        let request = GatewayRequestFrame(
            id: UUID().uuidString,
            method: "agents.abort",
            params: .object(["runId": .string(runID)]))
        do {
            let response = try await host.invoke(request)
            self.lastAgentAbortProbeSucceeded = response.ok
            self.lastAgentAbortProbeErrorText = response.error?.message
            if response.ok {
                self.lastAgentAbortProbeResponseText = Self.formatAgentSnapshot(from: response.payload)
                self.lastAgentRunID = nil
                self.appendLog("agent abort ok runId=\(runID)")
                if let snapshot = self.lastAgentAbortProbeResponseText, !snapshot.isEmpty {
                    self.appendLog("agent abort snapshot: \(snapshot)")
                }
            } else {
                let codeText = response.error?.code ?? "UNKNOWN"
                let message = response.error?.message ?? "unknown error"
                let lowerMessage = message.lowercased()
                if codeText == "METHOD_NOT_FOUND",
                   lowerMessage.contains("agent run not found")
                   || lowerMessage.contains("already finished")
                {
                    self.lastAgentAbortProbeSucceeded = true
                    self.lastAgentAbortProbeErrorText = nil
                    self.lastAgentAbortProbeResponseText = nil
                    self.lastAgentRunID = nil
                    self.appendLog("agent abort no-op runId=\(runID) already finished or not found")
                } else {
                    self.lastAgentAbortProbeResponseText = nil
                    self.appendLog(
                        "agent abort failed code=\(codeText) message=\(message)",
                        level: .warning)
                }
            }
        } catch {
            self.lastAgentAbortProbeSucceeded = false
            self.lastAgentAbortProbeErrorText = error.localizedDescription
            self.lastAgentAbortProbeResponseText = nil
            self.appendLog("agent abort threw: \(error.localizedDescription)", level: .error)
        }
    }

    func probeUpstreamHealth() async {
        guard self.state == .running else {
            self.lastUpstreamProbeSucceeded = nil
            self.lastUpstreamProbeErrorText = nil
            return
        }
        guard let upstreamClient = self.upstreamClient else {
            self.lastUpstreamProbeSucceeded = nil
            self.lastUpstreamProbeErrorText = "not configured"
            self.appendLog("upstream probe skipped: not configured", level: .warning)
            return
        }

        do {
            let response = try await upstreamClient.probeHealth()
            self.lastUpstreamProbeSucceeded = response.ok
            self.lastUpstreamProbeErrorText = response.error?.message
            if response.ok {
                self.appendLog("upstream probe ok")
            } else {
                self.appendLog(
                    "upstream probe failed: \(response.error?.message ?? "unknown error")",
                    level: .warning)
            }
        } catch {
            self.lastUpstreamProbeSucceeded = false
            self.lastUpstreamProbeErrorText = error.localizedDescription
            self.appendLog("upstream probe threw: \(error.localizedDescription)", level: .error)
        }
    }

    func startWebSocketListenerIfNeeded() async {
        guard self.listenerState != .listening else { return }
        guard let webSocketServer = self.webSocketServer else {
            self.listenerState = .failed
            self.listenerErrorText = "websocket server unavailable"
            return
        }
        do {
            let boundPort = try await webSocketServer.start(
                port: self.webSocketListenPortPreference,
                localhostOnly: !self.lanAccessEnabled)
            self.listenerPort = boundPort
            self.listenerErrorText = nil
            self.listenerState = .listening
            self.webSocketRetryTask?.cancel()
            self.webSocketRetryTask = nil
            self.webSocketRetryAttempt = 0
            self.webSocketRetryDelaySeconds = nil
            let localhostOnly = !self.lanAccessEnabled
            let endpointSummary = Self.listenerEndpointSummary(
                port: boundPort,
                localAddresses: self.localIPv4Addresses,
                scheme: "ws",
                localhostOnly: localhostOnly)
            self.appendLog("websocket listener active on \(endpointSummary)")
        } catch {
            self.listenerPort = nil
            self.listenerErrorText = error.localizedDescription
            self.listenerState = .failed
            self.appendLog("websocket listener failed: \(error.localizedDescription)", level: .error)
            self.scheduleWebSocketRetry()
        }
    }

    func restartWebSocketListener() async {
        self.appendLog("websocket listener restart requested")
        await self.stopWebSocketListener()
        await self.startWebSocketListenerIfNeeded()
    }

    func stopWebSocketListener() async {
        self.webSocketRetryTask?.cancel()
        self.webSocketRetryTask = nil
        self.webSocketRetryAttempt = 0
        self.webSocketRetryDelaySeconds = nil
        await self.webSocketServer?.stop()
        self.listenerPort = nil
        self.listenerState = .stopped
        self.listenerErrorText = nil
        self.lastWebSocketProbeSucceeded = nil
        self.lastWebSocketProbeErrorText = nil
        self.appendLog("websocket listener stopped")
    }

    func probeHealthOverWebSocket() async {
        guard self.state == .running, let listenerPort = self.listenerPort else {
            self.lastWebSocketProbeSucceeded = nil
            self.lastWebSocketProbeErrorText = nil
            return
        }

        do {
            let response = try await Self.sendHealthProbeOverWebSocket(
                port: listenerPort,
                authConfig: self.gatewayAuthConfig)
            self.lastWebSocketProbeSucceeded = response.ok
            self.lastWebSocketProbeErrorText = response.error?.message
            if response.ok {
                self.appendLog("websocket probe ok")
            } else {
                self.appendLog(
                    "websocket probe failed: \(response.error?.message ?? "unknown error")",
                    level: .warning)
            }
        } catch {
            self.lastWebSocketProbeSucceeded = false
            self.lastWebSocketProbeErrorText = error.localizedDescription
            self.appendLog("websocket probe threw: \(error.localizedDescription)", level: .error)
        }
    }

    func startTCPListenerIfNeeded() async {
        guard self.exposeTCPListener else { return }
        guard self.tcpListenerState != .listening else { return }
        guard let tcpServer = self.tcpServer else {
            self.tcpListenerState = .failed
            self.tcpListenerErrorText = "tcp debug server unavailable"
            return
        }

        if let existingPort = await tcpServer.currentPort() {
            self.tcpListenerPort = existingPort
            self.tcpListenerErrorText = nil
            self.tcpListenerState = .listening
            self.tcpRetryTask?.cancel()
            self.tcpRetryTask = nil
            self.tcpRetryAttempt = 0
            self.tcpRetryDelaySeconds = nil
            let endpointSummary = Self.listenerEndpointSummary(
                port: existingPort,
                localAddresses: self.localIPv4Addresses,
                scheme: "tcp",
                localhostOnly: !self.lanAccessEnabled)
            self.appendLog("tcp debug listener already bound on \(endpointSummary), marking active")
            return
        }

        await self.startTCPListenerOnPort(self.tcpListenPortPreference, allowFallbackToEphemeral: true)
    }

    private func startTCPListenerOnPort(
        _ port: UInt16,
        allowFallbackToEphemeral: Bool) async
    {
        guard let tcpServer = self.tcpServer else { return }

        do {
            let boundPort = try await tcpServer.start(
                port: port,
                localhostOnly: !self.lanAccessEnabled)
            self.tcpListenerPort = boundPort
            self.tcpListenerErrorText = nil
            self.tcpListenerState = .listening
            self.tcpRetryTask?.cancel()
            self.tcpRetryTask = nil
            self.tcpRetryAttempt = 0
            self.tcpRetryDelaySeconds = nil
            let tcpLocalhostOnly = !self.lanAccessEnabled
            let endpointSummary = Self.listenerEndpointSummary(
                port: boundPort,
                localAddresses: self.localIPv4Addresses,
                scheme: "tcp",
                localhostOnly: tcpLocalhostOnly)
            self.appendLog("tcp debug listener active on \(endpointSummary)")
            return
        } catch {
            if let tcpError = error as? GatewayTCPJSONServerError, tcpError == .alreadyRunning {
                if let existingPort = await tcpServer.currentPort() {
                    self.tcpListenerPort = existingPort
                    self.tcpListenerState = .listening
                    self.tcpListenerErrorText = nil
                    self.tcpRetryTask?.cancel()
                    self.tcpRetryTask = nil
                    self.tcpRetryAttempt = 0
                    self.tcpRetryDelaySeconds = nil
                    let endpointSummary = Self.listenerEndpointSummary(
                        port: existingPort,
                        localAddresses: self.localIPv4Addresses,
                        scheme: "tcp",
                        localhostOnly: !self.lanAccessEnabled)
                    self.appendLog("tcp debug listener already running on \(endpointSummary), marking active")
                    return
                }

                self.appendLog(
                    "tcp debug listener already running without bound port, forcing rebind",
                    level: .warning)
                await tcpServer.stop()
                self.tcpListenerState = .stopped
                self.tcpListenerPort = nil
                self.scheduleTCPRetry(after: 1)
                return
            }

            if allowFallbackToEphemeral,
               Self.isTCPAddressInUseError(error),
               port != 0
            {
                self.appendLog(
                    "tcp debug listener port \(port) unavailable, retrying ephemeral port",
                    level: .warning)
                await self.startTCPListenerOnPort(0, allowFallbackToEphemeral: false)
                if self.tcpListenerState == .listening {
                    return
                }
                if self.tcpListenerState == .failed {
                    return
                }
            }

            self.tcpListenerPort = nil
            self.tcpListenerErrorText = error.localizedDescription
            self.tcpListenerState = .failed
            self.appendLog("tcp debug listener failed: \(error.localizedDescription)", level: .error)
            self.scheduleTCPRetry()
            return
        }
    }

    func restartTCPListener() async {
        guard self.exposeTCPListener else { return }
        self.appendLog("tcp debug listener restart requested")
        await self.stopTCPListener()
        await self.startTCPListenerIfNeeded()
    }

    func stopTCPListener() async {
        self.tcpRetryTask?.cancel()
        self.tcpRetryTask = nil
        self.tcpRetryAttempt = 0
        self.tcpRetryDelaySeconds = nil
        await self.tcpServer?.stop()
        self.tcpListenerPort = nil
        self.tcpListenerState = .stopped
        self.tcpListenerErrorText = nil
        self.lastTCPProbeSucceeded = nil
        self.lastTCPProbeErrorText = nil
        self.appendLog("tcp debug listener stopped")
    }

    func probeHealthOverTCP() async {
        guard self.state == .running, let listenerPort = self.tcpListenerPort else {
            self.lastTCPProbeSucceeded = nil
            self.lastTCPProbeErrorText = nil
            return
        }

        do {
            let response = try await Self.sendHealthProbeOverTCP(
                port: listenerPort,
                authConfig: self.gatewayAuthConfig)
            self.lastTCPProbeSucceeded = response.ok
            self.lastTCPProbeErrorText = response.error?.message
            if response.ok {
                self.appendLog("tcp probe ok")
            } else {
                self.appendLog(
                    "tcp probe failed: \(response.error?.message ?? "unknown error")",
                    level: .warning)
            }
        } catch {
            self.lastTCPProbeSucceeded = false
            self.lastTCPProbeErrorText = error.localizedDescription
            self.appendLog("tcp probe threw: \(error.localizedDescription)", level: .error)
        }
    }

    private func scheduleWebSocketRetry() {
        guard self.state == .running else { return }
        guard self.webSocketRetryTask == nil else { return }
        self.webSocketRetryAttempt += 1
        let exponentialDelay = 1 << min(self.webSocketRetryAttempt - 1, 5)
        let delaySeconds = min(30, max(1, exponentialDelay))
        self.webSocketRetryDelaySeconds = delaySeconds
        self.appendLog(
            "websocket retry in \(delaySeconds)s (attempt \(self.webSocketRetryAttempt))",
            level: .warning)

        self.webSocketRetryTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(delaySeconds) * 1_000_000_000)
            guard !Task.isCancelled else { return }
            self.webSocketRetryTask = nil
            self.webSocketRetryDelaySeconds = nil
            await self.startWebSocketListenerIfNeeded()
        }
    }

    // MARK: - Network Watchdog

    /// Poll interval for the network watchdog (seconds).
    private static let networkWatchdogIntervalSeconds: UInt64 = 5

    /// Installs the `onListenerStateChange` callback on the WebSocket
    /// server so that NWListener failures (e.g. interface loss) trigger
    /// an automatic listener restart.
    private func installListenerStateCallback() async {
        await self.webSocketServer?.setOnListenerStateChange { [weak self] failed in
            Task { @MainActor [weak self] in
                guard let self, self.state == .running else { return }
                self.appendLog(
                    "NWListener state change detected (failed=\(failed)) — restarting listeners",
                    level: .warning)
                await self.restartWebSocketListener()
                if self.exposeTCPListener {
                    await self.restartTCPListener()
                }
            }
        }
    }

    /// Starts a periodic watchdog that monitors local network addresses.
    /// When the set of addresses changes (WiFi reconnect, DHCP renewal,
    /// interface up/down), the watchdog restarts the listeners so they
    /// bind to the current interfaces.  If LAN binding fails, the
    /// listener automatically falls back to localhost.
    private func startNetworkWatchdog() {
        self.stopNetworkWatchdog()
        self.networkWatchdogLastAddresses = Set(self.localIPv4Addresses)
        self.appendLog(
            "network watchdog started (addresses: \(self.localIPv4Addresses.joined(separator: ", ")))")

        self.networkWatchdogTask = Task { @MainActor [weak self] in
            while let self, !Task.isCancelled, self.state == .running {
                try? await Task.sleep(
                    nanoseconds: Self.networkWatchdogIntervalSeconds * 1_000_000_000)
                guard !Task.isCancelled else { return }
                await self.networkWatchdogTick()
            }
        }
    }

    private func stopNetworkWatchdog() {
        self.networkWatchdogTask?.cancel()
        self.networkWatchdogTask = nil
    }

    private func networkWatchdogTick() async {
        guard self.state == .running else { return }

        self.refreshLocalNetworkAddresses()
        let currentAddresses = Set(self.localIPv4Addresses)

        guard currentAddresses != self.networkWatchdogLastAddresses else { return }

        let added = currentAddresses.subtracting(self.networkWatchdogLastAddresses)
        let removed = self.networkWatchdogLastAddresses.subtracting(currentAddresses)
        self.appendLog(
            "network watchdog: addresses changed"
                + (added.isEmpty ? "" : " +[\(added.sorted().joined(separator: ", "))]")
                + (removed.isEmpty ? "" : " -[\(removed.sorted().joined(separator: ", "))]")
                + " — restarting listeners",
            level: .warning)
        self.networkWatchdogLastAddresses = currentAddresses

        // Restart listeners so they bind to the current interfaces.
        await self.restartWebSocketListener()
        if let ws = self.webSocketServer, await ws.isFallbackLoopback {
            self.appendLog(
                "websocket listener fell back to localhost after network change",
                level: .warning)
        }
        if self.exposeTCPListener {
            await self.restartTCPListener()
        }
    }

    // MARK: - TCP Retry

    private func scheduleTCPRetry() {
        self.scheduleTCPRetry(after: nil)
    }

    private func scheduleTCPRetry(after overrideDelay: Int?) {
        guard self.state == .running else { return }
        guard self.tcpRetryTask == nil else { return }
        self.tcpRetryAttempt += 1
        let delaySeconds: Int
        if let overrideDelay {
            delaySeconds = max(1, min(20, overrideDelay))
        } else {
            let exponentialDelay = 1 << min(self.tcpRetryAttempt - 1, 4)
            delaySeconds = min(20, max(1, exponentialDelay))
        }
        self.tcpRetryDelaySeconds = delaySeconds
        self.appendLog(
            "tcp debug retry in \(delaySeconds)s (attempt \(self.tcpRetryAttempt))",
            level: .warning)

        self.tcpRetryTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(delaySeconds) * 1_000_000_000)
            guard !Task.isCancelled else { return }
            self.tcpRetryTask = nil
            self.tcpRetryDelaySeconds = nil
            await self.startTCPListenerIfNeeded()
        }
    }

    /// Reload skill registry and rebuild the gateway stack.
    /// If the runtime is currently running, the listeners are restarted
    /// so the new transport (with updated skills) is fully wired up.
    func reloadSkills() async {
        await self.withRuntimeTransition("reload skills") {
            let wasRunning = self.state == .running
            if wasRunning {
                await self.stopLocked()
            }
            self.rebuildGatewayStack()
            if wasRunning {
                await self.startLocked()
            }
            self.appendLog("skills reloaded")
        }
    }

    private func rebuildGatewayStack() {
        self.webSocketRetryTask?.cancel()
        self.webSocketRetryTask = nil
        self.webSocketRetryAttempt = 0
        self.webSocketRetryDelaySeconds = nil
        self.tcpRetryTask?.cancel()
        self.tcpRetryTask = nil
        self.tcpRetryAttempt = 0
        self.tcpRetryDelaySeconds = nil

        self.gatewayAuthConfig = Self.makeAuthConfig(from: self.controlPlaneSettings)
        self.listenerAuthMode = self.gatewayAuthConfig.mode
        self.listenerAuthHint = Self.authHint(for: self.gatewayAuthConfig)

        let upstreamLoad = Self.makeUpstreamConfig(from: self.controlPlaneSettings)
        self.upstreamConfigured = upstreamLoad.config != nil
        self.upstreamURLText = upstreamLoad.urlText
        self.upstreamConfigErrorText = upstreamLoad.errorText
        self.upstreamClient = upstreamLoad.config.map { GatewayUpstreamWebSocketClient(config: $0) }

        let localLLMConfig = Self.makeLocalLLMConfig(from: self.controlPlaneSettings)
        let localTelegramConfig = Self.makeLocalTelegramConfig(from: self.controlPlaneSettings)
        self.localLLMConfigured = localLLMConfig.isConfigured
        self.localLLMProviderLabel = Self.localLLMProviderDisplayName(localLLMConfig.provider)
        self.localLLMConfigErrorText = nil
        if localLLMConfig.provider != .disabled, !localLLMConfig.isConfigured {
            self.localLLMConfigErrorText = "provider selected but local LLM config is incomplete"
        }
        let bootstrapWorkspacePath = Self.defaultBootstrapWorkspacePath()
        if bootstrapWorkspacePath.isEmpty {
            self.appendLog("bootstrap workspace unavailable; auto-install skipped", level: .warning)
        } else {
            do {
                let seedResult = try TVOSBootstrapWorkspaceSeeder.ensureSeeded(
                    workspacePath: bootstrapWorkspacePath)
                if seedResult.createdCount > 0 {
                    self.appendLog(
                        "bootstrap install created \(seedResult.createdCount) file(s): "
                            + seedResult.createdFiles.joined(separator: ", "))
                }
                if !seedResult.failedFiles.isEmpty {
                    let failures = seedResult.failedFiles
                        .sorted(by: { $0.key < $1.key })
                        .map { "\($0.key)=\($0.value)" }
                        .joined(separator: "; ")
                    self.appendLog(
                        "bootstrap install write failures: \(failures)",
                        level: .error)
                }
                if !seedResult.missingTemplateFiles.isEmpty {
                    self.appendLog(
                        "bootstrap install missing templates: "
                            + seedResult.missingTemplateFiles.joined(separator: ", "),
                        level: .warning)
                }
                if let status = seedResult.status {
                    if status.bootstrapPending {
                        self.appendLog(
                            "bootstrap onboarding pending"
                                + (status.bootstrapSeededAt.map { " (seeded=\($0))" } ?? ""))
                    } else {
                        self.appendLog(
                            "bootstrap onboarding completed"
                                + (status.onboardingCompletedAt.map { " (\($0))" } ?? ""))
                    }
                }
            } catch {
                self.appendLog("bootstrap install failed: \(error.localizedDescription)", level: .error)
            }
        }

        var resolvedFileNames = Self.bootstrapInjectionFileNames(
            workspacePath: bootstrapWorkspacePath)
        if !bootstrapWorkspacePath.isEmpty {
            let workspaceURL = URL(
                fileURLWithPath: bootstrapWorkspacePath)
            if let skillRegistry = GatewaySkillRegistry.load(
                from: workspaceURL)
            {
                resolvedFileNames = skillRegistry.filterFileNames(
                    resolvedFileNames)
                self.appendLog(
                    "skill registry loaded: "
                        + "\(skillRegistry.skills.count) skills, "
                        + "\(skillRegistry.enabledFileNames.count) enabled")
            }
        }

        let resolvedPerFileMaxChars = self.controlPlaneSettings.bootstrapPerFileMaxChars
        let resolvedTotalMaxChars = self.controlPlaneSettings.bootstrapTotalMaxChars
        let bootstrapConfig = GatewayBootstrapConfig(
            enabled: true,
            workspacePath: bootstrapWorkspacePath,
            fileNames: resolvedFileNames,
            perFileMaxChars: resolvedPerFileMaxChars,
            totalMaxChars: resolvedTotalMaxChars,
            includeMissingMarkers: false)

        // Warn if total injection content exceeds the budget.
        if !bootstrapWorkspacePath.isEmpty {
            let workspaceURL = URL(fileURLWithPath: bootstrapWorkspacePath)
            var totalBytes = 0
            var fittingCount = 0
            var droppedNames: [String] = []
            for fileName in resolvedFileNames {
                let fileURL = workspaceURL.appendingPathComponent(fileName)
                guard let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
                      let size = attrs[.size] as? Int
                else { continue }
                let clamped = min(size, resolvedPerFileMaxChars)
                if totalBytes + clamped <= resolvedTotalMaxChars {
                    totalBytes += clamped
                    fittingCount += 1
                } else {
                    droppedNames.append(fileName)
                }
            }
            if !droppedNames.isEmpty {
                self.appendLog(
                    "bootstrap budget warning: \(droppedNames.count) file(s) will be dropped "
                        + "(totalMaxChars=\(resolvedTotalMaxChars), "
                        + "used=\(totalBytes)): "
                        + droppedNames.joined(separator: ", "),
                    level: .warning)
            }
        }

        let resolvedTransport: GatewayLoopbackTransport
        #if os(iOS)
        let resolvedDeviceToolBridge: (any GatewayDeviceToolBridge)? = self.deviceToolBridge
        let resolvedEnableDeviceTools = self.controlPlaneSettings.enableLocalDeviceTools
        #else
        let resolvedDeviceToolBridge: (any GatewayDeviceToolBridge)? = nil
        let resolvedEnableDeviceTools = false
        #endif
        if let transportOverride = self.transportOverride {
            resolvedTransport = transportOverride
        } else {
            var localRouter: GatewayLocalMethodRouter?
            let adminBridge = TVOSRuntimeAdminBridge(runtime: self)
            let primaryMemoryStorePath = Self.defaultMemoryStorePath()
            self.appendLog("local memory store path: \(primaryMemoryStorePath.path)")
            do {
                localRouter = try GatewayLocalMethodRouter(
                    config: GatewayLocalMethodRouterConfig(
                        hostLabel: "tvos-local",
                        upstreamConfigured: self.upstreamConfigured,
                        upstreamForwarder: self.upstreamClient,
                        llmConfig: localLLMConfig,
                        telegramConfig: localTelegramConfig,
                        memoryStorePath: primaryMemoryStorePath,
                        bootstrapConfig: bootstrapConfig,
                        enableLocalSafeTools: true,
                        enableLocalFileTools: true,
                        enableLocalDeviceTools: resolvedEnableDeviceTools,
                        deviceToolBridge: resolvedDeviceToolBridge,
                        llmToolCallingMode: self.controlPlaneSettings.localLLMToolCallingMode,
                        enableAutoProfileRewrite: false,
                        adminBridge: adminBridge,
                        disabledToolNames: self.controlPlaneSettings.disabledToolNames))
            } catch {
                let firstErrorText = "local router init failed: \(error.localizedDescription)"
                self.localLLMConfigErrorText = firstErrorText
                self.appendLog("local method router init failed: \(error.localizedDescription)", level: .error)

                let fallbackMemoryStorePath = Self.fallbackMemoryStorePath()
                if fallbackMemoryStorePath.path != primaryMemoryStorePath.path {
                    self.appendLog(
                        "retrying local router with fallback memory path: \(fallbackMemoryStorePath.path)",
                        level: .warning)
                    do {
                        localRouter = try GatewayLocalMethodRouter(
                            config: GatewayLocalMethodRouterConfig(
                                hostLabel: "tvos-local",
                                upstreamConfigured: self.upstreamConfigured,
                                upstreamForwarder: self.upstreamClient,
                                llmConfig: localLLMConfig,
                                telegramConfig: localTelegramConfig,
                                memoryStorePath: fallbackMemoryStorePath,
                                bootstrapConfig: bootstrapConfig,
                                enableLocalSafeTools: true,
                                enableLocalFileTools: true,
                                enableLocalDeviceTools: resolvedEnableDeviceTools,
                                deviceToolBridge: resolvedDeviceToolBridge,
                                llmToolCallingMode: self.controlPlaneSettings.localLLMToolCallingMode,
                                enableAutoProfileRewrite: false,
                                adminBridge: adminBridge,
                                disabledToolNames: self.controlPlaneSettings.disabledToolNames))
                        self.localLLMConfigErrorText = nil
                        self.appendLog(
                            "local router recovered with fallback memory path",
                            level: .warning)
                    } catch {
                        self.localLLMConfigErrorText = firstErrorText
                        self.appendLog(
                            "local method router fallback init failed: \(error.localizedDescription)",
                            level: .error)
                    }
                }
            }
            resolvedTransport = GatewayLoopbackTransport(
                core: GatewayCore(authConfig: self.gatewayAuthConfig),
                upstream: self.upstreamClient,
                localMethods: localRouter)
        }

        self.host = GatewayLoopbackHost(transport: resolvedTransport)
        self.webSocketServer = GatewayWebSocketServer(transport: resolvedTransport)
        self.tcpServer = GatewayTCPJSONServer(
            transport: resolvedTransport,
            authConfig: self.gatewayAuthConfig)
    }

    fileprivate func adminConfigSnapshot(nowMs: Int64) -> GatewayJSONValue {
        _ = self.pruneTelegramPairingRequests(nowMs: nowMs)
        let settingsPayload = self.adminSettingsPayload(self.controlPlaneSettings)
        var payload = settingsPayload
        payload["settings"] = .object(settingsPayload)
        payload["state"] = self.adminRuntimeStatePayload(nowMs: nowMs)
        payload["bootstrap"] = self.adminBootstrapPayload()
        payload["skills"] = self.adminSkillsPayload()
        payload["pairing"] = self.adminPairingPayload(nowMs: nowMs)
        payload["config"] = .object([
            "gatewayTVOS": .object(settingsPayload),
            "session": .object([
                "mainKey": .string("main"),
                "scope": .string("local"),
            ]),
        ])
        payload["ts"] = .integer(nowMs)
        return .object(payload)
    }

    fileprivate func adminConfigSet(params: GatewayJSONValue, nowMs: Int64) async throws -> GatewayJSONValue {
        self.logAdminConfigSetInputSummary(params: params)
        let nextSettings = try self.adminSettingsFromParams(params)
        let wasRunning = self.state == .running
        await self.applyControlPlaneSettings(nextSettings)
        let settingsPayload = self.adminSettingsPayload(self.controlPlaneSettings)
        self.appendLog("admin config.set applied via RPC")
        return .object([
            "applied": .bool(true),
            "settings": .object(settingsPayload),
            "state": self.adminRuntimeStatePayload(nowMs: nowMs),
            "bootstrap": self.adminBootstrapPayload(),
            "skills": self.adminSkillsPayload(),
            "pairing": self.adminPairingPayload(nowMs: nowMs),
            "wasRunning": .bool(wasRunning),
            "ts": .integer(nowMs),
        ])
    }

    private func logAdminConfigSetInputSummary(params: GatewayJSONValue) {
        guard let root = params.objectValue else {
            self.appendLog("admin config.set request params: non-object", level: .warning)
            return
        }
        let source: [String: GatewayJSONValue] = if let settings = root["settings"]?.objectValue {
            settings
        } else if let configObject = root["config"]?.objectValue,
                  let gatewayTVOS = configObject["gatewayTVOS"]?.objectValue
        {
            gatewayTVOS
        } else if let configObject = root["config"]?.objectValue {
            configObject
        } else {
            root
        }

        let sourceTelegram = source["telegram"]?.objectValue
        let rootTelegram = root["telegram"]?.objectValue

        let sourceDirectToken = source["telegramBotToken"]?.stringValue
        let rootDirectToken = root["telegramBotToken"]?.stringValue
        let directToken = sourceDirectToken ?? rootDirectToken

        let sourceNestedToken = sourceTelegram?["botToken"]?.stringValue ?? sourceTelegram?["token"]?.stringValue
        let rootNestedToken = rootTelegram?["botToken"]?.stringValue ?? rootTelegram?["token"]?.stringValue
        let nestedToken = sourceNestedToken ?? rootNestedToken

        let sourceChatID = source["telegramDefaultChatID"]?.stringValue
            ?? sourceTelegram?["defaultChatID"]?.stringValue
            ?? sourceTelegram?["chatId"]?.stringValue
        let rootChatID = root["telegramDefaultChatID"]?.stringValue
            ?? rootTelegram?["defaultChatID"]?.stringValue
            ?? rootTelegram?["chatId"]?.stringValue
        let chatID = sourceChatID ?? rootChatID

        self.appendLog(
            "admin config.set request telegram.direct=\(Self.presenceState(directToken ?? ""))"
                + " telegram.nested=\(Self.presenceState(nestedToken ?? ""))"
                + " telegram.chat=\(Self.trimmed(chatID) ?? "(none)")")
    }

    fileprivate func adminRuntimeRestart(nowMs: Int64) async -> GatewayJSONValue {
        let wasRunning = self.state == .running
        await self.restart(with: self.controlPlaneSettings)
        self.appendLog("admin runtime.restart applied via RPC")
        return .object([
            "restarted": .bool(true),
            "state": self.adminRuntimeStatePayload(nowMs: nowMs),
            "bootstrap": self.adminBootstrapPayload(),
            "skills": self.adminSkillsPayload(),
            "pairing": self.adminPairingPayload(nowMs: nowMs),
            "wasRunning": .bool(wasRunning),
            "ts": .integer(nowMs),
        ])
    }

    private func adminSettingsFromParams(_ params: GatewayJSONValue) throws -> TVOSGatewayControlPlaneSettings {
        guard let root = params.objectValue else {
            throw TVOSRuntimeAdminBridgeError.invalidRequest("config.set params must be an object")
        }

        var source = root
        if let settings = root["settings"]?.objectValue {
            source = settings
        } else if let configObject = root["config"]?.objectValue {
            if let tvosSettings = configObject["gatewayTVOS"]?.objectValue {
                source = tvosSettings
            } else if let tvosSettings = configObject["tvos"]?.objectValue {
                source = tvosSettings
            } else {
                source = configObject
            }
        }

        var next = self.controlPlaneSettings
        let authObject = Self.firstObject(in: source, keys: ["auth", "listenerAuth"])
        let upstreamObject = Self.firstObject(in: source, keys: ["upstream", "gateway"])
        let localLLMObject = Self.firstObject(in: source, keys: ["localLLM", "localLlm", "llm"])
        let sourceTelegramObject = Self.firstObject(in: source, keys: ["telegram"])
        let rootTelegramObject = Self.firstObject(in: root, keys: ["telegram"])
        let telegramObject = sourceTelegramObject ?? rootTelegramObject

        let authModeRaw =
            Self.firstString(in: source, keys: ["authMode", "auth_mode"])
            ?? authObject?["mode"]?.stringValue
        if let authModeRaw {
            guard let mode = Self.parseAuthMode(authModeRaw) else {
                throw TVOSRuntimeAdminBridgeError.invalidRequest("invalid authMode: \(authModeRaw)")
            }
            next.authMode = mode
        }

        if let authToken =
            Self.firstString(in: source, keys: ["authToken", "auth_token"])
            ?? authObject?["token"]?.stringValue
        {
            next.authToken = authToken
        }

        if let authPassword =
            Self.firstString(in: source, keys: ["authPassword", "auth_password"])
            ?? authObject?["password"]?.stringValue
        {
            next.authPassword = authPassword
        }

        if let upstreamURL =
            Self.firstString(in: source, keys: ["upstreamURL", "upstreamUrl", "url"])
            ?? upstreamObject?["url"]?.stringValue
        {
            next.upstreamURL = upstreamURL
        }

        if let upstreamToken =
            Self.firstString(in: source, keys: ["upstreamToken", "upstream_token"])
            ?? upstreamObject?["token"]?.stringValue
        {
            next.upstreamToken = upstreamToken
        }

        if let upstreamPassword =
            Self.firstString(in: source, keys: ["upstreamPassword", "upstream_password"])
            ?? upstreamObject?["password"]?.stringValue
        {
            next.upstreamPassword = upstreamPassword
        }

        if let upstreamRole =
            Self.firstString(in: source, keys: ["upstreamRole", "upstream_role"])
            ?? upstreamObject?["role"]?.stringValue
        {
            next.upstreamRole = upstreamRole
        }

        if let upstreamScopes =
            Self.firstString(in: source, keys: ["upstreamScopesCSV", "upstreamScopes", "scopes"])
            ?? upstreamObject?["scopes"]?.stringValue
        {
            next.upstreamScopesCSV = upstreamScopes
        }

        let providerRaw =
            Self.firstString(in: source, keys: ["localLLMProvider", "localLlmProvider", "llmProvider"])
            ?? localLLMObject?["provider"]?.stringValue
        if let providerRaw {
            guard let provider = Self.parseLocalLLMProvider(providerRaw) else {
                throw TVOSRuntimeAdminBridgeError.invalidRequest(
                    "invalid localLLMProvider: \(providerRaw)")
            }
            next.localLLMProvider = provider
        }

        if let baseURL =
            Self.firstString(in: source, keys: ["localLLMBaseURL", "localLlmBaseURL", "llmBaseURL", "baseURL"])
            ?? localLLMObject?["baseURL"]?.stringValue
        {
            next.localLLMBaseURL = baseURL
        }

        if let apiKey =
            Self.firstString(in: source, keys: ["localLLMAPIKey", "localLlmApiKey", "llmAPIKey", "apiKey"])
            ?? localLLMObject?["apiKey"]?.stringValue
        {
            next.localLLMAPIKey = apiKey
        }

        if let model =
            Self.firstString(in: source, keys: ["localLLMModel", "localLlmModel", "llmModel", "model"])
            ?? localLLMObject?["model"]?.stringValue
        {
            next.localLLMModel = model
        }

        let toolCallingModeRaw =
            Self.firstString(
                in: source,
                keys: ["localLLMToolCallingMode", "localLlmToolCallingMode", "llmToolCallingMode", "toolCallingMode"])
            ?? localLLMObject?["toolCallingMode"]?.stringValue
            ?? localLLMObject?["toolMode"]?.stringValue
        if let toolCallingModeRaw {
            guard let toolCallingMode = Self.parseLocalLLMToolCallingMode(toolCallingModeRaw) else {
                throw TVOSRuntimeAdminBridgeError.invalidRequest(
                    "invalid localLLMToolCallingMode: \(toolCallingModeRaw)")
            }
            next.localLLMToolCallingMode = toolCallingMode
        }

        if let telegramBotToken =
            Self.firstString(in: source, keys: ["telegramBotToken", "telegramToken", "telegram.token"])
            ?? Self.firstString(in: root, keys: ["telegramBotToken", "telegramToken", "telegram.token"])
            ?? telegramObject?["botToken"]?.stringValue
            ?? telegramObject?["token"]?.stringValue
        {
            next.telegramBotToken = telegramBotToken
        }

        if let telegramDefaultChatID =
            Self.firstString(in: source, keys: ["telegramDefaultChatID", "telegramChatID", "telegram.chatId"])
            ?? Self.firstString(in: root, keys: ["telegramDefaultChatID", "telegramChatID", "telegram.chatId"])
            ?? telegramObject?["defaultChatID"]?.stringValue
            ?? telegramObject?["chatId"]?.stringValue
            ?? telegramObject?["to"]?.stringValue
        {
            next.telegramDefaultChatID = telegramDefaultChatID
        }

        if let perFile = source["bootstrapPerFileMaxChars"]?.int64Value {
            next.bootstrapPerFileMaxChars = Int(perFile)
        }
        if let total = source["bootstrapTotalMaxChars"]?.int64Value {
            next.bootstrapTotalMaxChars = Int(total)
        }

        return Self.normalizedSettings(next)
    }

    private func adminSettingsPayload(_ settings: TVOSGatewayControlPlaneSettings) -> [String: GatewayJSONValue] {
        [
            "authMode": .string(settings.authMode.rawValue),
            "authToken": .string(settings.authToken),
            "authPassword": .string(settings.authPassword),
            "upstreamURL": .string(settings.upstreamURL),
            "upstreamToken": .string(settings.upstreamToken),
            "upstreamPassword": .string(settings.upstreamPassword),
            "upstreamRole": .string(settings.upstreamRole),
            "upstreamScopesCSV": .string(settings.upstreamScopesCSV),
            "localLLMProvider": .string(settings.localLLMProvider.rawValue),
            "localLLMBaseURL": .string(settings.localLLMBaseURL),
            "localLLMAPIKey": .string(settings.localLLMAPIKey),
            "localLLMModel": .string(settings.localLLMModel),
            "localLLMToolCallingMode": .string(settings.localLLMToolCallingMode.rawValue),
            "telegramBotToken": .string(settings.telegramBotToken),
            "telegramDefaultChatID": .string(settings.telegramDefaultChatID),
            "telegram": .object([
                "botToken": .string(settings.telegramBotToken),
                "defaultChatID": .string(settings.telegramDefaultChatID),
            ]),
            "bootstrapPerFileMaxChars": .integer(Int64(settings.bootstrapPerFileMaxChars)),
            "bootstrapTotalMaxChars": .integer(Int64(settings.bootstrapTotalMaxChars)),
        ]
    }

    private func adminRuntimeStatePayload(nowMs: Int64) -> GatewayJSONValue {
        .object([
            "runtime": .string(self.state.rawValue),
            "webSocket": .string(self.listenerState.rawValue),
            "webSocketPort": self.listenerPort.map { .integer(Int64($0)) } ?? .null,
            "tcpDebug": .string(self.tcpListenerState.rawValue),
            "tcpDebugPort": self.tcpListenerPort.map { .integer(Int64($0)) } ?? .null,
            "upstreamConfigured": .bool(self.upstreamConfigured),
            "localLLMConfigured": .bool(self.localLLMConfigured),
            "telegramConfigured": .bool(Self.trimmed(self.controlPlaneSettings.telegramBotToken) != nil),
            "telegramDefaultChatID": .string(self.controlPlaneSettings.telegramDefaultChatID),
            "pairingPendingCount": .integer(Int64(self.telegramPairingStore.requests.count)),
            "pairingAllowCount": .integer(Int64(self.telegramPairingStore.allowFrom.count)),
            "pairingLastUpdateID": .integer(self.telegramPairingStore.lastUpdateID),
            "pairingPollSucceeded": self.lastTelegramPairingPollSucceeded.map { .bool($0) } ?? .null,
            "pairingPollErrorText": self.lastTelegramPairingPollErrorText.map { .string($0) } ?? .null,
            "ts": .integer(nowMs),
        ])
    }

    private func adminBootstrapPayload() -> GatewayJSONValue {
        let workspacePath = Self.defaultBootstrapWorkspacePath()
        guard !workspacePath.isEmpty else {
            return .object([
                "enabled": .bool(false),
                "workspacePath": .null,
                "bootstrapPending": .bool(true),
                "files": .array([]),
            ])
        }

        let workspaceURL = URL(fileURLWithPath: workspacePath, isDirectory: true)
        let fileManager = FileManager.default
        let status = TVOSBootstrapWorkspaceSeeder.loadStatus(workspacePath: workspacePath)
        let maxChars = max(256, GatewayBootstrapConfig.default.perFileMaxChars)
        let bootstrapFileNames = Self.bootstrapInjectionFileNames(workspacePath: workspacePath)
        var fileEntries: [GatewayJSONValue] = []
        var existingCount = 0

        for filename in bootstrapFileNames {
            let fileURL = workspaceURL.appendingPathComponent(filename, isDirectory: false)
            var isDirectory: ObjCBool = false
            let exists = fileManager.fileExists(atPath: fileURL.path, isDirectory: &isDirectory) && !isDirectory
                .boolValue
            if exists {
                existingCount += 1
            }

            var entry: [String: GatewayJSONValue] = [
                "name": .string(filename),
                "path": .string(fileURL.path),
                "exists": .bool(exists),
            ]

            if exists, let data = try? Data(contentsOf: fileURL) {
                entry["bytes"] = .integer(Int64(data.count))
                if let text = String(data: data, encoding: .utf8) {
                    let preview = Self.clampAdminPreview(text, maxChars: maxChars)
                    entry["content"] = .string(preview.text)
                    entry["truncated"] = .bool(preview.truncated)
                } else {
                    entry["content"] = .string("(binary or non-utf8 content)")
                    entry["truncated"] = .bool(false)
                }
            } else {
                entry["bytes"] = .integer(0)
                entry["content"] = .string("")
                entry["truncated"] = .bool(false)
            }

            fileEntries.append(.object(entry))
        }

        return .object([
            "enabled": .bool(true),
            "workspacePath": .string(workspacePath),
            "statePath": status.map { .string($0.statePath) } ?? .null,
            "bootstrapSeededAt": status?.bootstrapSeededAt.map { .string($0) } ?? .null,
            "onboardingCompletedAt": status?.onboardingCompletedAt.map { .string($0) } ?? .null,
            "bootstrapPending": .bool(status?.bootstrapPending ?? true),
            "bootstrapExists": .bool(status?.bootstrapExists ?? false),
            "expectedFiles": .integer(Int64(bootstrapFileNames.count)),
            "existingFiles": .integer(Int64(existingCount)),
            "files": .array(fileEntries),
        ])
    }

    private func adminSkillsPayload() -> GatewayJSONValue {
        let workspacePath = Self.defaultBootstrapWorkspacePath()
        guard !workspacePath.isEmpty else {
            return .object([
                "enabled": .bool(false),
                "workspacePath": .null,
                "skillsRootPath": .null,
                "skillsRootExists": .bool(false),
                "files": .array([]),
            ])
        }

        let workspaceURL = URL(fileURLWithPath: workspacePath, isDirectory: true)
        let skillsRootURL = workspaceURL.appendingPathComponent("skills", isDirectory: true)
        let fileManager = FileManager.default
        let maxChars = max(256, GatewayBootstrapConfig.default.perFileMaxChars)
        var rootIsDirectory: ObjCBool = false
        let skillsRootExists = fileManager.fileExists(atPath: skillsRootURL.path, isDirectory: &rootIsDirectory)
            && rootIsDirectory.boolValue

        guard skillsRootExists else {
            return .object([
                "enabled": .bool(true),
                "workspacePath": .string(workspacePath),
                "skillsRootPath": .string(skillsRootURL.path),
                "skillsRootExists": .bool(false),
                "fileCount": .integer(0),
                "files": .array([]),
            ])
        }

        let skillFileURLs = Self.collectSkillFileURLs(rootURL: skillsRootURL, fileManager: fileManager)
        var fileEntries: [GatewayJSONValue] = []
        fileEntries.reserveCapacity(skillFileURLs.count)

        for fileURL in skillFileURLs {
            let relativePath = Self.relativeAdminPath(fileURL: fileURL, rootURL: workspaceURL)
            var entry: [String: GatewayJSONValue] = [
                "name": .string(relativePath),
                "path": .string(fileURL.path),
                "exists": .bool(true),
            ]
            if let resourceValues = try? fileURL.resourceValues(forKeys: [
                .creationDateKey,
                .contentModificationDateKey,
            ]) {
                if let createdAt = resourceValues.creationDate {
                    entry["createdAtMs"] = .integer(Self.epochMilliseconds(for: createdAt))
                    entry["createdAtISO8601"] = .string(Self.iso8601String(from: createdAt))
                }
                if let modifiedAt = resourceValues.contentModificationDate {
                    entry["modifiedAtMs"] = .integer(Self.epochMilliseconds(for: modifiedAt))
                    entry["modifiedAtISO8601"] = .string(Self.iso8601String(from: modifiedAt))
                }
            }
            if let data = try? Data(contentsOf: fileURL) {
                entry["bytes"] = .integer(Int64(data.count))
                if let text = String(data: data, encoding: .utf8) {
                    let preview = Self.clampAdminPreview(text, maxChars: maxChars)
                    entry["content"] = .string(preview.text)
                    entry["truncated"] = .bool(preview.truncated)
                } else {
                    entry["content"] = .string("(binary or non-utf8 content)")
                    entry["truncated"] = .bool(false)
                }
            } else {
                entry["bytes"] = .integer(0)
                entry["content"] = .string("(unreadable)")
                entry["truncated"] = .bool(false)
            }
            fileEntries.append(.object(entry))
        }

        return .object([
            "enabled": .bool(true),
            "workspacePath": .string(workspacePath),
            "skillsRootPath": .string(skillsRootURL.path),
            "skillsRootExists": .bool(true),
            "fileCount": .integer(Int64(fileEntries.count)),
            "files": .array(fileEntries),
        ])
    }

    fileprivate func adminPairingList(params: GatewayJSONValue, nowMs: Int64) async throws -> GatewayJSONValue {
        let source = params.objectValue ?? [:]
        let channelRaw = Self.firstString(in: source, keys: ["channel"]) ?? "telegram"
        let channel = channelRaw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard channel == "telegram" || channel == "tg" else {
            throw TVOSRuntimeAdminBridgeError.invalidRequest(
                "unsupported pairing channel: \(channelRaw)")
        }

        _ = self.pruneTelegramPairingRequests(nowMs: nowMs)
        return self.adminPairingPayload(nowMs: nowMs)
    }

    fileprivate func adminPairingApprove(params: GatewayJSONValue, nowMs: Int64) async throws -> GatewayJSONValue {
        guard let source = params.objectValue else {
            throw TVOSRuntimeAdminBridgeError.invalidRequest("pairing.approve params must be an object")
        }

        let channelRaw = Self.firstString(in: source, keys: ["channel"]) ?? "telegram"
        let channel = channelRaw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard channel == "telegram" || channel == "tg" else {
            throw TVOSRuntimeAdminBridgeError.invalidRequest(
                "unsupported pairing channel: \(channelRaw)")
        }

        guard let code = Self.trimmed(Self.firstString(in: source, keys: ["code"]))?.uppercased() else {
            throw TVOSRuntimeAdminBridgeError.invalidRequest("pairing.approve requires code")
        }
        if Self.looksLikeTelegramBotToken(code) {
            throw TVOSRuntimeAdminBridgeError.invalidRequest(
                "pairing.approve expects 8-character pairing code, not bot token")
        }
        guard Self.isValidTelegramPairingCode(code) else {
            throw TVOSRuntimeAdminBridgeError.invalidRequest(
                "pairing.approve code must be 8 chars (A-Z, 2-9)")
        }

        _ = self.pruneTelegramPairingRequests(nowMs: nowMs)
        guard let approved = self.consumeTelegramPairingCode(code: code, nowMs: nowMs) else {
            throw TVOSRuntimeAdminBridgeError.invalidRequest("no pending pairing request found for code: \(code)")
        }
        self.persistTelegramPairingStore()

        let sendResult = await self.sendTelegramMessage(
            chatID: approved.id,
            text: "AnemllClaw tvOS pairing approved. You are now linked.")
        if let sendError = sendResult {
            self.appendLog("telegram pairing approval notice failed: \(sendError)", level: .warning)
        }

        self.appendLog("telegram pairing approved id=\(Self.maskedDisplayUserID(approved.id)) code=\(code)")

        return .object([
            "approved": .bool(true),
            "channel": .string("telegram"),
            "id": .string(approved.id),
            "code": .string(code),
            "state": self.adminRuntimeStatePayload(nowMs: nowMs),
            "pairing": self.adminPairingPayload(nowMs: nowMs),
            "ts": .integer(nowMs),
        ])
    }

    fileprivate func adminBackupExport(nowMs: Int64) async throws -> GatewayJSONValue {
        // Export is read-only (captures files, defaults, keychain) so we do NOT
        // stop the runtime.  Stopping tears down the WebSocket listener and
        // kills the very connection the admin client is using to receive the
        // response, which always resulted in "socket closed" on the client side.
        let artifact = try await Task.detached(priority: .userInitiated) {
            try OpenClawBackupManager.createBackupArtifact()
        }.value

        let base64String = artifact.data.base64EncodedString()
        return .object([
            "ok": .bool(true),
            "fileName": .string(artifact.defaultFileName),
            "fileCount": .integer(Int64(artifact.fileCount)),
            "defaultsCount": .integer(Int64(artifact.defaultsCount)),
            "keychainCount": .integer(Int64(artifact.keychainCount)),
            "sizeBytes": .integer(Int64(artifact.data.count)),
            "data": .string(base64String),
            "ts": .integer(nowMs),
        ])
    }

    fileprivate func adminBackupImport(params: GatewayJSONValue, nowMs: Int64) async throws -> GatewayJSONValue {
        guard let source = params.objectValue else {
            throw TVOSRuntimeAdminBridgeError.invalidRequest("backup.import params must be an object")
        }

        guard let base64String = Self.firstString(in: source, keys: ["data"]),
              !base64String.isEmpty
        else {
            throw TVOSRuntimeAdminBridgeError
                .invalidRequest("backup.import requires 'data' field with base64-encoded backup")
        }

        guard let archiveData = Data(base64Encoded: base64String, options: [.ignoreUnknownCharacters]) else {
            throw TVOSRuntimeAdminBridgeError.invalidRequest("backup.import 'data' is not valid base64")
        }

        let wasRunning = self.state == .running
        if wasRunning {
            await self.stop()
            try? await Task.sleep(nanoseconds: Self.listenerRestartQuiesceDurationNanoseconds)
        }

        do {
            let result = try await Task.detached(priority: .userInitiated) {
                try OpenClawBackupManager.restoreBackupArchive(from: archiveData)
            }.value

            await self.reloadPersistedControlPlaneSettings(startIfStopped: wasRunning)

            var payload: [String: GatewayJSONValue] = [
                "ok": .bool(true),
                "restoredFileCount": .integer(Int64(result.restoredFileCount)),
                "restoredDefaultsCount": .integer(Int64(result.restoredDefaultsCount)),
                "restoredKeychainCount": .integer(Int64(result.restoredKeychainCount)),
                "state": self.adminRuntimeStatePayload(nowMs: nowMs),
                "ts": .integer(nowMs),
            ]
            if !result.skippedFileTokens.isEmpty {
                payload["skippedFileCount"] = .integer(Int64(result.skippedFileTokens.count))
                payload["skippedFileTokens"] = .array(result.skippedFileTokens.map { .string($0) })
                self.appendLog(
                    "backup.import skipped \(result.skippedFileTokens.count) file(s): "
                        + result.skippedFileTokens.joined(separator: ", "),
                    level: .warning)
            }
            return .object(payload)
        } catch {
            if wasRunning { await self.start() }
            throw error
        }
    }

    private func adminPairingPayload(nowMs: Int64) -> GatewayJSONValue {
        _ = self.pruneTelegramPairingRequests(nowMs: nowMs)

        let requests: [GatewayJSONValue] = self.telegramPairingStore.requests.map { request in
            var object: [String: GatewayJSONValue] = [
                "id": .string(request.id),
                "code": .string(request.code),
                "createdAtMs": .integer(request.createdAtMs),
                "lastSeenAtMs": .integer(request.lastSeenAtMs),
                "createdAt": .string(Self.iso8601String(from: Self.date(fromMs: request.createdAtMs))),
                "lastSeenAt": .string(Self.iso8601String(from: Self.date(fromMs: request.lastSeenAtMs))),
            ]
            let meta = request.meta
            if meta.isEmpty {
                object["meta"] = .object([:])
            } else {
                object["meta"] = .object(meta.mapValues { .string($0) })
            }
            return .object(object)
        }

        return .object([
            "channel": .string("telegram"),
            "enabled": .bool(Self.trimmed(self.controlPlaneSettings.telegramBotToken) != nil),
            "requestCount": .integer(Int64(requests.count)),
            "allowFromCount": .integer(Int64(self.telegramPairingStore.allowFrom.count)),
            "allowFrom": .array(self.telegramPairingStore.allowFrom.map { .string($0) }),
            "lastUpdateID": .integer(self.telegramPairingStore.lastUpdateID),
            "pollingActive": .bool(self.telegramPairingPollTask != nil),
            "pollSucceeded": self.lastTelegramPairingPollSucceeded.map { .bool($0) } ?? .null,
            "pollErrorText": self.lastTelegramPairingPollErrorText.map { .string($0) } ?? .null,
            "requests": .array(requests),
            "ts": .integer(nowMs),
        ])
    }

    private static func epochMilliseconds(for date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1000.0).rounded())
    }

    private static func iso8601String(from date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    private static func date(fromMs timestampMs: Int64) -> Date {
        Date(timeIntervalSince1970: TimeInterval(timestampMs) / 1000.0)
    }

    private static func collectSkillFileURLs(rootURL: URL, fileManager: FileManager) -> [URL] {
        guard let enumerator = fileManager.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants])
        else {
            return []
        }

        var results: [URL] = []
        for case let fileURL as URL in enumerator {
            let resourceValues = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey])
            if resourceValues?.isDirectory == true {
                continue
            }
            guard resourceValues?.isRegularFile == true else {
                continue
            }

            let filename = fileURL.lastPathComponent.lowercased()
            if filename == "skill.md" || filename.hasSuffix(".md") {
                results.append(fileURL)
            }
        }

        results.sort { $0.path.localizedCaseInsensitiveCompare($1.path) == .orderedAscending }
        return results
    }

    private static func relativeAdminPath(fileURL: URL, rootURL: URL) -> String {
        let rootPath = rootURL.path.hasSuffix("/") ? rootURL.path : rootURL.path + "/"
        let fullPath = fileURL.path
        if fullPath.hasPrefix(rootPath) {
            return String(fullPath.dropFirst(rootPath.count))
        }
        return fileURL.lastPathComponent
    }

    private static func bootstrapInjectionFileNames(workspacePath: String) -> [String] {
        var ordered = GatewayBootstrapConfig.default.fileNames
        let trimmedWorkspacePath = workspacePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedWorkspacePath.isEmpty else {
            return ordered
        }

        let fileManager = FileManager.default
        let workspaceURL = URL(fileURLWithPath: trimmedWorkspacePath, isDirectory: true)
        let skillsRootURL = workspaceURL.appendingPathComponent("skills", isDirectory: true)
        let skillURLs = Self.collectSkillFileURLs(rootURL: skillsRootURL, fileManager: fileManager)

        for fileURL in skillURLs {
            let relativePath = Self.relativeAdminPath(fileURL: fileURL, rootURL: workspaceURL)
            if !ordered.contains(relativePath) {
                ordered.append(relativePath)
            }
        }
        return ordered
    }

    private static func clampAdminPreview(_ raw: String, maxChars: Int) -> (text: String, truncated: Bool) {
        let normalized = raw.replacingOccurrences(of: "\r\n", with: "\n")
        guard maxChars > 0 else {
            return ("", !normalized.isEmpty)
        }
        if normalized.count <= maxChars {
            return (normalized, false)
        }
        let prefix = String(normalized.prefix(max(0, maxChars - 1)))
        return (prefix + "…", true)
    }

    private static func firstString(
        in object: [String: GatewayJSONValue],
        keys: [String]) -> String?
    {
        for key in keys {
            guard let value = object[key] else { continue }
            if let text = value.stringValue {
                return text
            }
            if case .null = value {
                return ""
            }
        }
        return nil
    }

    private static func firstObject(
        in object: [String: GatewayJSONValue],
        keys: [String]) -> [String: GatewayJSONValue]?
    {
        for key in keys {
            if let nested = object[key]?.objectValue {
                return nested
            }
        }
        return nil
    }

    private static func parseAuthMode(_ raw: String) -> GatewayCoreAuthMode? {
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch normalized {
        case "none", "off", "disabled":
            return GatewayCoreAuthMode.none
        case "token":
            return .token
        case "password", "pass":
            return .password
        default:
            return nil
        }
    }

    private static func parseLocalLLMProvider(_ raw: String) -> GatewayLocalLLMProviderKind? {
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch normalized {
        case "disabled", "none", "off":
            return .disabled
        case "openai", "openai-compatible", "openai_compatible":
            return .openAICompatible
        case "anthropic", "anthropic-compatible", "anthropic_compatible":
            return .anthropicCompatible
        case "minimax", "minimax-compatible", "minimax_compatible":
            return .minimaxCompatible
        case "grok", "grok-compatible", "grok_compatible", "xai", "x-ai", "x.ai":
            return .grokCompatible
        default:
            return GatewayLocalLLMProviderKind(rawValue: normalized)
        }
    }

    private static func parseLocalLLMToolCallingMode(_ raw: String) -> GatewayLocalLLMToolCallingMode? {
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch normalized {
        case "auto", "":
            return .auto
        case "on", "enabled", "true", "force":
            return .on
        case "off", "disabled", "false", "none":
            return .off
        default:
            return GatewayLocalLLMToolCallingMode(rawValue: normalized)
        }
    }

    private static func normalizedSessionKey(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? Self.defaultChatSessionKey : trimmed
    }

    private static func extractChatRunID(from payload: GatewayJSONValue?) -> String? {
        payload?.objectValue?["runId"]?.stringValue
    }

    private static func decodeChatTurns(from payload: GatewayJSONValue?) -> [TVOSGatewayChatTurn] {
        guard let payloadObject = payload?.objectValue,
              let messagesValue = payloadObject["messages"],
              case let .array(messages) = messagesValue
        else {
            return []
        }

        var turns: [TVOSGatewayChatTurn] = []
        turns.reserveCapacity(messages.count)

        for (index, message) in messages.enumerated() {
            guard let messageObject = message.objectValue else { continue }

            let role = messageObject["role"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalizedRole = (role?.isEmpty == false) ? role! : "assistant"
            let text = Self.chatText(from: messageObject["content"])
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                continue
            }

            let timestampMs: Int64? = {
                guard let raw = messageObject["timestamp"] else { return nil }
                switch raw {
                case let .integer(value):
                    return value
                case let .double(value):
                    guard value.isFinite else { return nil }
                    return Int64(value.rounded())
                default:
                    return nil
                }
            }()
            let timestamp = timestampMs.map { Date(timeIntervalSince1970: TimeInterval($0) / 1000.0) }
            let runID = messageObject["runId"]?.stringValue
            let uniqueID = [
                String(timestampMs ?? Int64(index)),
                String(index),
                normalizedRole,
                runID ?? "",
                String(text.hashValue),
            ].joined(separator: "|")

            turns.append(
                TVOSGatewayChatTurn(
                    id: uniqueID,
                    role: normalizedRole,
                    text: text,
                    timestamp: timestamp,
                    runID: runID))
        }
        return turns
    }

    private static func chatText(from content: GatewayJSONValue?) -> String {
        guard let content else { return "" }
        if let text = content.stringValue {
            return text
        }
        guard case let .array(items) = content else {
            return ""
        }

        var chunks: [String] = []
        chunks.reserveCapacity(items.count)
        for item in items {
            guard let itemObject = item.objectValue else { continue }
            let type = itemObject["type"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if type == nil || type == "text",
               let text = itemObject["text"]?.stringValue,
               !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            {
                chunks.append(text)
            }
        }
        return chunks.joined(separator: "\n")
    }

    private static func latestAssistantReplyText(from payload: GatewayJSONValue?) -> String? {
        guard let payloadObject = payload?.objectValue,
              let messagesValue = payloadObject["messages"],
              case let .array(messages) = messagesValue
        else {
            return nil
        }

        for message in messages.reversed() {
            guard let messageObject = message.objectValue,
                  messageObject["role"]?.stringValue == "assistant",
                  let contentValue = messageObject["content"],
                  case let .array(contentItems) = contentValue
            else {
                continue
            }

            var textChunks: [String] = []
            for item in contentItems {
                guard let itemObject = item.objectValue else { continue }
                if itemObject["type"]?.stringValue == "text",
                   let text = itemObject["text"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !text.isEmpty
                {
                    textChunks.append(text)
                }
            }

            if !textChunks.isEmpty {
                return textChunks.joined(separator: " ")
            }
        }
        return nil
    }

    private static func assistantTurnCount(from payload: GatewayJSONValue?) -> Int {
        self.decodeChatTurns(from: payload).reduce(into: 0) { count, turn in
            if turn.role == "assistant" {
                count += 1
            }
        }
    }

    private static func sanitizeTelegramReplyText(_ rawText: String) -> String {
        let withoutThinkBlocks = rawText.replacingOccurrences(
            of: "(?is)<think>.*?</think>",
            with: "",
            options: .regularExpression)
        let normalized = withoutThinkBlocks.trimmingCharacters(in: .whitespacesAndNewlines)
        if !normalized.isEmpty {
            return normalized
        }
        return rawText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func clampTelegramReply(_ text: String, maxChars: Int) -> String {
        guard maxChars > 0 else { return "" }
        guard text.count > maxChars else { return text }
        guard maxChars > 1 else { return "…" }
        let prefix = text.prefix(maxChars - 1)
        return String(prefix) + "…"
    }

    static func localLLMProviderDisplayName(_ provider: GatewayLocalLLMProviderKind) -> String {
        switch provider {
        case .disabled:
            "disabled"
        case .openAICompatible:
            "openai-compatible"
        case .anthropicCompatible:
            "anthropic-compatible"
        case .minimaxCompatible:
            "minimax-compatible"
        case .grokCompatible:
            "grok-compatible"
        }
    }

    static func defaultLocalLLMBaseURL(for provider: GatewayLocalLLMProviderKind) -> String? {
        switch provider {
        case .disabled:
            nil
        case .openAICompatible:
            "https://api.openai.com/v1"
        case .anthropicCompatible:
            "https://api.anthropic.com/v1"
        case .minimaxCompatible:
            "https://api.minimax.io/v1"
        case .grokCompatible:
            "https://api.x.ai/v1"
        }
    }

    static func defaultLocalLLMModel(for provider: GatewayLocalLLMProviderKind) -> String? {
        switch provider {
        case .disabled:
            nil
        case .openAICompatible:
            "gpt-4o-mini"
        case .anthropicCompatible:
            "claude-sonnet-4-6"
        case .minimaxCompatible:
            "MiniMax-M2.5"
        case .grokCompatible:
            "grok-4-1-fast-non-reasoning"
        }
    }

    private static func extractAgentRunID(from payload: GatewayJSONValue?) -> String? {
        payload?.objectValue?["runId"]?.stringValue
    }

    private static func formatAgentSnapshot(from payload: GatewayJSONValue?) -> String {
        guard let payloadObject = payload?.objectValue else {
            return "no snapshot"
        }

        var parts: [String] = []
        if let runId = payloadObject["runId"]?.stringValue {
            parts.append("runId=\(runId)")
        }
        if let sessionKey = payloadObject["sessionKey"]?.stringValue {
            parts.append("session=\(sessionKey)")
        }
        if let status = payloadObject["status"]?.stringValue {
            parts.append("status=\(status)")
        }
        if let currentStep = payloadObject["currentStep"]?.stringValue {
            parts.append("currentStep=\(currentStep)")
        }
        if let totalSteps = payloadObject["totalSteps"]?.int64Value {
            parts.append("totalSteps=\(totalSteps)")
        }
        if let stepsCompleted = payloadObject["stepsCompleted"]?.int64Value {
            parts.append("stepsCompleted=\(stepsCompleted)")
        }
        if let output = payloadObject["output"]?.stringValue {
            parts.append("output=\(Self.compactText(output, max: 160))")
        }
        if let error = payloadObject["error"]?.stringValue {
            parts.append("error=\(Self.compactText(error, max: 160))")
        }
        return parts.isEmpty ? "empty snapshot" : parts.joined(separator: " | ")
    }

    private static func compactText(_ text: String, max: Int) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > max else { return trimmed }
        return String(trimmed.prefix(max - 1)) + "…"
    }

    private static func sendHealthProbeOverWebSocket(
        port: UInt16,
        authConfig: GatewayCoreAuthConfig) async throws -> GatewayResponseFrame
    {
        guard let url = URL(string: "ws://127.0.0.1:\(port)") else {
            throw URLError(.badURL)
        }

        let session = URLSession(configuration: .ephemeral)
        let task = session.webSocketTask(with: url)
        task.resume()
        defer {
            task.cancel(with: .goingAway, reason: nil)
            session.invalidateAndCancel()
        }

        let connectRequest = Self.makeConnectRequest(authConfig: authConfig)
        try await Self.sendWebSocketRequest(task: task, frame: connectRequest)

        let connectResponse = try await Self.waitForResponse(task: task, requestID: connectRequest.id)
        guard connectResponse.ok else {
            return connectResponse
        }

        let healthRequest = GatewayRequestFrame(id: UUID().uuidString, method: "health")
        try await Self.sendWebSocketRequest(task: task, frame: healthRequest)
        return try await Self.waitForResponse(task: task, requestID: healthRequest.id)
    }

    private static func sendWebSocketRequest(
        task: URLSessionWebSocketTask,
        frame: GatewayRequestFrame) async throws
    {
        let data = try JSONEncoder().encode(frame)
        try await task.send(.data(data))
    }

    private static func waitForResponse(
        task: URLSessionWebSocketTask,
        requestID: String) async throws -> GatewayResponseFrame
    {
        while true {
            let message = try await task.receive()
            guard let data = Self.webSocketMessageData(message) else { continue }

            if let response = try? JSONDecoder().decode(GatewayResponseFrame.self, from: data),
               response.type == "res"
            {
                if response.id == requestID {
                    return response
                }
                continue
            }

            // Ignore event frames while waiting for the matching response.
            if (try? JSONDecoder().decode(GatewayEventFrame.self, from: data)) != nil {
                continue
            }
        }
    }

    private static func webSocketMessageData(_ message: URLSessionWebSocketTask.Message) -> Data? {
        switch message {
        case let .data(data):
            return data
        case let .string(text):
            return text.data(using: .utf8)
        @unknown default:
            return nil
        }
    }

    private static func makeConnectRequest(authConfig: GatewayCoreAuthConfig) -> GatewayRequestFrame {
        var params: [String: GatewayJSONValue] = [
            "minProtocol": .integer(Int64(GatewayCore.defaultProtocolVersion)),
            "maxProtocol": .integer(Int64(GatewayCore.defaultProtocolVersion)),
            "client": .object([
                "id": .string("openclaw.tvos.gateway-probe"),
                "displayName": .string("OpenClawTV Probe"),
                "version": .string("0.0.0-dev"),
                "platform": .string("tvOS"),
                "mode": .string("gateway-host"),
            ]),
            "role": .string("operator"),
            "scopes": .array([.string("operator.admin")]),
        ]

        if let auth = Self.authPayload(for: authConfig) {
            var authObject: [String: GatewayJSONValue] = [:]
            if let token = auth.token {
                authObject["token"] = .string(token)
            }
            if let password = auth.password {
                authObject["password"] = .string(password)
            }
            params["auth"] = .object(authObject)
        }

        return GatewayRequestFrame(
            id: UUID().uuidString,
            method: "connect",
            params: .object(params))
    }

    private static func sendHealthProbeOverTCP(
        port: UInt16,
        authConfig: GatewayCoreAuthConfig) async throws -> GatewayResponseFrame
    {
        let connection = NWConnection(
            host: NWEndpoint.Host("127.0.0.1"),
            port: NWEndpoint.Port(rawValue: port) ?? .any,
            using: .tcp)
        let queue = DispatchQueue(label: "ai.openclaw.tvos.gateway-probe.tcp.\(UUID().uuidString)")
        connection.start(queue: queue)

        let request = GatewayRequestFrame(id: UUID().uuidString, method: "health")
        let envelope = GatewayTCPRequestEnvelope(
            request: request,
            auth: Self.authPayload(for: authConfig))
        var requestData = try JSONEncoder().encode(envelope)
        requestData.append(0x0A)

        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: requestData, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                continuation.resume()
            })
        }

        let responseData = try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Data, Error>) in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 1_048_576) {
                data,
                    _,
                    _,
                    error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                continuation.resume(returning: data ?? Data())
            }
        }
        connection.cancel()

        let line = responseData.split(
            separator: 0x0A,
            maxSplits: 1,
            omittingEmptySubsequences: true).first
        let frameData = Data(line ?? responseData[...])
        return try JSONDecoder().decode(GatewayResponseFrame.self, from: frameData)
    }

    private static func authPayload(for config: GatewayCoreAuthConfig) -> GatewayConnectAuth? {
        switch config.mode {
        case .none:
            return nil
        case .token:
            guard let token = config.token, !token.isEmpty else { return nil }
            return GatewayConnectAuth(token: token)
        case .password:
            guard let password = config.password, !password.isEmpty else { return nil }
            return GatewayConnectAuth(password: password)
        }
    }

    private static func authHint(for config: GatewayCoreAuthConfig) -> String? {
        switch config.mode {
        case .none:
            return nil
        case .token:
            guard let token = config.token else { return "(missing token)" }
            return "token (\(Self.redacted(token)))"
        case .password:
            guard let password = config.password else { return "(missing password)" }
            return "password (\(Self.redacted(password)))"
        }
    }

    private static func redacted(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "empty" }
        let suffix = String(trimmed.suffix(4))
        return "***\(suffix)"
    }

    private static func loadShowExternalTelegramMessagesInChat(defaults: UserDefaults = .standard) -> Bool {
        guard let raw = defaults.object(
            forKey: showExternalTelegramMessagesInChatDefaultsKey) as? NSNumber
        else {
            return true
        }
        return raw.boolValue
    }

    private static func persistShowExternalTelegramMessagesInChat(
        _ enabled: Bool,
        defaults: UserDefaults = .standard)
    {
        defaults.set(enabled, forKey: self.showExternalTelegramMessagesInChatDefaultsKey)
    }

    private static func loadControlPlaneSettings(
        defaults: UserDefaults = .standard) -> TVOSGatewayControlPlaneSettings
    {
        var settings = TVOSGatewayControlPlaneSettings.default

        let authModeRaw =
            Self.trimmed(defaults.string(forKey: "gateway.tvos.auth.mode"))
            ?? GatewayCoreAuthMode.none.rawValue
        settings.authMode = GatewayCoreAuthMode(rawValue: authModeRaw) ?? .none
        settings.authToken =
            Self.trimmed(defaults.string(forKey: "gateway.tvos.auth.token"))
            ?? ""
        settings.authPassword =
            Self.trimmed(defaults.string(forKey: "gateway.tvos.auth.password"))
            ?? ""

        settings.upstreamURL =
            Self.trimmed(defaults.string(forKey: "gateway.tvos.upstream.url"))
            ?? ""
        settings.upstreamToken =
            Self.trimmed(defaults.string(forKey: "gateway.tvos.upstream.token"))
            ?? ""
        settings.upstreamPassword =
            Self.trimmed(defaults.string(forKey: "gateway.tvos.upstream.password"))
            ?? ""
        settings.upstreamRole =
            Self.trimmed(defaults.string(forKey: "gateway.tvos.upstream.role"))
            ?? "node"
        settings.upstreamScopesCSV =
            Self.trimmed(defaults.string(forKey: "gateway.tvos.upstream.scopes"))
            ?? ""

        let persistedProviderRaw = Self.trimmed(defaults.string(forKey: "gateway.tvos.localLLM.provider"))
        let persistedBaseURL = Self.trimmed(defaults.string(forKey: "gateway.tvos.localLLM.baseURL"))
        // API key lives in Keychain, not UserDefaults.
        var persistedAPIKey = Self.trimmed(
            KeychainStore.loadString(service: "ai.openclaw.llm.runtime", account: "localLLMAPIKey"))

        // Migration: if the runtime Keychain entry is empty, recover the key
        // from legacy sources so existing users don't lose their API key.
        if persistedAPIKey == nil || persistedAPIKey!.isEmpty {
            // 1) Try the old UserDefaults key (pre-Keychain builds).
            if let legacyKey = Self.trimmed(defaults.string(forKey: "gateway.tvos.localLLM.apiKey")),
               !legacyKey.isEmpty
            {
                persistedAPIKey = legacyKey
                _ = KeychainStore.saveString(legacyKey, service: "ai.openclaw.llm.runtime", account: "localLLMAPIKey")
                defaults.removeObject(forKey: "gateway.tvos.localLLM.apiKey")
            }
            #if os(iOS)
            // 2) Try the active LLMProviderStore provider (Keychain service "ai.openclaw.llm").
            if persistedAPIKey == nil || persistedAPIKey!.isEmpty,
               let activeID = LLMProviderStore.activeID(defaults: defaults)
            {
                let providers = LLMProviderStore.load(defaults: defaults)
                if let active = providers.first(where: { $0.id == activeID }),
                   !active.apiKey.isEmpty
                {
                    persistedAPIKey = active.apiKey
                    _ = KeychainStore.saveString(
                        active.apiKey, service: "ai.openclaw.llm.runtime", account: "localLLMAPIKey")
                }
            }
            #endif
        }

        let persistedModel = Self.trimmed(defaults.string(forKey: "gateway.tvos.localLLM.model"))

        let localProviderRaw = persistedProviderRaw
            ?? TVOSGatewayControlPlaneSettings.default.localLLMProvider.rawValue
        settings.localLLMProvider = GatewayLocalLLMProviderKind(rawValue: localProviderRaw)
            ?? TVOSGatewayControlPlaneSettings.default.localLLMProvider
        settings.localLLMBaseURL = persistedBaseURL
            ?? TVOSGatewayControlPlaneSettings.default.localLLMBaseURL
        settings.localLLMAPIKey = persistedAPIKey ?? ""
        settings.localLLMModel = persistedModel
            ?? TVOSGatewayControlPlaneSettings.default.localLLMModel
        let localToolCallingModeRaw =
            Self.trimmed(defaults.string(forKey: "gateway.tvos.localLLM.toolCallingMode"))
            ?? GatewayLocalLLMToolCallingMode.auto.rawValue
        settings.localLLMToolCallingMode =
            Self.parseLocalLLMToolCallingMode(localToolCallingModeRaw) ?? .auto
        settings.telegramBotToken =
            Self.trimmed(defaults.string(forKey: "gateway.tvos.telegram.botToken"))
            ?? ""
        settings.telegramDefaultChatID =
            Self.trimmed(defaults.string(forKey: "gateway.tvos.telegram.defaultChatID"))
            ?? ""

        // Device tools default to enabled (true) when no persisted value exists.
        if defaults.object(forKey: "gateway.tvos.deviceTools.enabled") != nil {
            settings.enableLocalDeviceTools = defaults.bool(forKey: "gateway.tvos.deviceTools.enabled")
        } else {
            settings.enableLocalDeviceTools = true
        }

        if let disabled = defaults.stringArray(forKey: "gateway.tvos.disabledToolNames") {
            settings.disabledToolNames = Set(disabled)
        }

        if defaults.object(forKey: "gateway.tvos.bootstrap.perFileMaxChars") != nil {
            settings.bootstrapPerFileMaxChars = defaults.integer(forKey: "gateway.tvos.bootstrap.perFileMaxChars")
        }
        if defaults.object(forKey: "gateway.tvos.bootstrap.totalMaxChars") != nil {
            settings.bootstrapTotalMaxChars = defaults.integer(forKey: "gateway.tvos.bootstrap.totalMaxChars")
        }

        return Self.normalizedSettings(settings)
    }

    private static func persistControlPlaneSettings(
        _ settings: TVOSGatewayControlPlaneSettings,
        defaults: UserDefaults = .standard)
    {
        defaults.set(settings.authMode.rawValue, forKey: "gateway.tvos.auth.mode")

        switch settings.authMode {
        case .none:
            defaults.removeObject(forKey: "gateway.tvos.auth.token")
            defaults.removeObject(forKey: "gateway.tvos.auth.password")
        case .token:
            defaults.set(self.trimmed(settings.authToken), forKey: "gateway.tvos.auth.token")
            defaults.removeObject(forKey: "gateway.tvos.auth.password")
        case .password:
            defaults.removeObject(forKey: "gateway.tvos.auth.token")
            defaults.set(self.trimmed(settings.authPassword), forKey: "gateway.tvos.auth.password")
        }

        defaults.set(self.trimmed(settings.upstreamURL), forKey: "gateway.tvos.upstream.url")
        defaults.set(self.trimmed(settings.upstreamToken), forKey: "gateway.tvos.upstream.token")
        defaults.set(self.trimmed(settings.upstreamPassword), forKey: "gateway.tvos.upstream.password")
        defaults.set(self.trimmed(settings.upstreamRole), forKey: "gateway.tvos.upstream.role")
        defaults.set(self.trimmed(settings.upstreamScopesCSV), forKey: "gateway.tvos.upstream.scopes")

        defaults.set(settings.localLLMProvider.rawValue, forKey: "gateway.tvos.localLLM.provider")
        defaults.set(self.trimmed(settings.localLLMBaseURL), forKey: "gateway.tvos.localLLM.baseURL")
        // API key persisted in Keychain, not UserDefaults.
        let llmKey = (self.trimmed(settings.localLLMAPIKey) ?? "")
        if llmKey.isEmpty {
            _ = KeychainStore.delete(service: "ai.openclaw.llm.runtime", account: "localLLMAPIKey")
        } else {
            _ = KeychainStore.saveString(llmKey, service: "ai.openclaw.llm.runtime", account: "localLLMAPIKey")
        }
        defaults.removeObject(forKey: "gateway.tvos.localLLM.apiKey") // clean up legacy
        defaults.set(self.trimmed(settings.localLLMModel), forKey: "gateway.tvos.localLLM.model")
        defaults.set(
            settings.localLLMToolCallingMode.rawValue,
            forKey: "gateway.tvos.localLLM.toolCallingMode")
        defaults.set(self.trimmed(settings.telegramBotToken), forKey: "gateway.tvos.telegram.botToken")
        defaults.set(
            self.trimmed(settings.telegramDefaultChatID),
            forKey: "gateway.tvos.telegram.defaultChatID")
        defaults.set(settings.enableLocalDeviceTools, forKey: "gateway.tvos.deviceTools.enabled")
        defaults.set(Array(settings.disabledToolNames), forKey: "gateway.tvos.disabledToolNames")
        defaults.set(settings.bootstrapPerFileMaxChars, forKey: "gateway.tvos.bootstrap.perFileMaxChars")
        defaults.set(settings.bootstrapTotalMaxChars, forKey: "gateway.tvos.bootstrap.totalMaxChars")
    }

    private func verifyPersistedControlPlaneSettings(_ expected: TVOSGatewayControlPlaneSettings) {
        let persisted = Self.loadControlPlaneSettings()
        guard persisted != expected else { return }

        var mismatches: [String] = []
        func markIfDifferent<T: Equatable>(_ key: String, _ lhs: T, _ rhs: T) {
            if lhs != rhs {
                mismatches.append(key)
            }
        }

        markIfDifferent("authMode", expected.authMode, persisted.authMode)
        markIfDifferent("authToken", expected.authToken, persisted.authToken)
        markIfDifferent("authPassword", expected.authPassword, persisted.authPassword)
        markIfDifferent("upstreamURL", expected.upstreamURL, persisted.upstreamURL)
        markIfDifferent("upstreamToken", expected.upstreamToken, persisted.upstreamToken)
        markIfDifferent("upstreamPassword", expected.upstreamPassword, persisted.upstreamPassword)
        markIfDifferent("upstreamRole", expected.upstreamRole, persisted.upstreamRole)
        markIfDifferent("upstreamScopesCSV", expected.upstreamScopesCSV, persisted.upstreamScopesCSV)
        markIfDifferent("localLLMProvider", expected.localLLMProvider, persisted.localLLMProvider)
        markIfDifferent("localLLMBaseURL", expected.localLLMBaseURL, persisted.localLLMBaseURL)
        markIfDifferent("localLLMAPIKey", expected.localLLMAPIKey, persisted.localLLMAPIKey)
        markIfDifferent("localLLMModel", expected.localLLMModel, persisted.localLLMModel)
        markIfDifferent(
            "localLLMToolCallingMode",
            expected.localLLMToolCallingMode,
            persisted.localLLMToolCallingMode)
        markIfDifferent("telegramBotToken", expected.telegramBotToken, persisted.telegramBotToken)
        markIfDifferent(
            "telegramDefaultChatID",
            expected.telegramDefaultChatID,
            persisted.telegramDefaultChatID)
        markIfDifferent(
            "enableLocalDeviceTools",
            expected.enableLocalDeviceTools,
            persisted.enableLocalDeviceTools)

        self.appendLog(
            "settings persistence mismatch fields=\(mismatches.joined(separator: ","))"
                + " runtime.auth=\(expected.authMode.rawValue)/\(Self.redacted(expected.authToken))/\(Self.redacted(expected.authPassword))"
                + " persisted.auth=\(persisted.authMode.rawValue)/\(Self.redacted(persisted.authToken))/\(Self.redacted(persisted.authPassword))"
                + " runtime.upstream=\(Self.trimmed(expected.upstreamURL) ?? "(none)") role=\(Self.trimmed(expected.upstreamRole) ?? "node") scopes=\(Self.trimmed(expected.upstreamScopesCSV) ?? "(none)") token=\(Self.presenceState(expected.upstreamToken)) password=\(Self.presenceState(expected.upstreamPassword))"
                + " persisted.upstream=\(Self.trimmed(persisted.upstreamURL) ?? "(none)") role=\(Self.trimmed(persisted.upstreamRole) ?? "node") scopes=\(Self.trimmed(persisted.upstreamScopesCSV) ?? "(none)") token=\(Self.presenceState(persisted.upstreamToken)) password=\(Self.presenceState(persisted.upstreamPassword))"
                + " runtime.llm=\(expected.localLLMProvider.rawValue) baseURL=\(Self.trimmed(expected.localLLMBaseURL) ?? "(none)") model=\(Self.trimmed(expected.localLLMModel) ?? "(none)") apiKey=\(Self.presenceState(expected.localLLMAPIKey)) tools=\(expected.localLLMToolCallingMode.rawValue)"
                + " persisted.llm=\(persisted.localLLMProvider.rawValue) baseURL=\(Self.trimmed(persisted.localLLMBaseURL) ?? "(none)") model=\(Self.trimmed(persisted.localLLMModel) ?? "(none)") apiKey=\(Self.presenceState(persisted.localLLMAPIKey)) tools=\(persisted.localLLMToolCallingMode.rawValue)"
                + " runtime.telegram.chat=\(Self.trimmed(expected.telegramDefaultChatID) ?? "(none)") token=\(Self.presenceState(expected.telegramBotToken))"
                +
                " persisted.telegram.chat=\(Self.trimmed(persisted.telegramDefaultChatID) ?? "(none)") token=\(Self.presenceState(persisted.telegramBotToken))",
            level: .warning)
    }

    private func startTelegramPairingPollingIfNeeded() {
        self.stopTelegramPairingPolling()

        guard Self.trimmed(self.controlPlaneSettings.telegramBotToken) != nil else {
            self.appendLog("telegram pairing polling disabled: bot token missing")
            return
        }

        self.telegramPairingPollTask = Task { @MainActor [weak self] in
            while let self, !Task.isCancelled, self.state == .running {
                await self.pollTelegramPairingOnce()
                try? await Task.sleep(nanoseconds: Self.telegramPairingPollIntervalNanoseconds)
            }
        }
        self.appendLog("telegram pairing polling started")
    }

    private func stopTelegramPairingPolling() {
        guard let task = self.telegramPairingPollTask else { return }
        task.cancel()
        self.telegramPairingPollTask = nil
        self.appendLog("telegram pairing polling stopped")
    }

    private func pollTelegramPairingOnce() async {
        guard let botToken = Self.trimmed(self.controlPlaneSettings.telegramBotToken) else { return }

        let offset = self.telegramPairingStore.lastUpdateID > 0
            ? self.telegramPairingStore.lastUpdateID + 1
            : nil
        do {
            let updates = try await self.fetchTelegramUpdates(botToken: botToken, offset: offset)
            if !updates.isEmpty {
                let offsetText = offset.map(String.init) ?? "(none)"
                self.appendLog(
                    "telegram poll received updates=\(updates.count) offset=\(offsetText)")
            }
            let nowMs = GatewayCore.currentTimestampMs()
            var maxUpdateID = self.telegramPairingStore.lastUpdateID
            var changed = false

            for update in updates {
                maxUpdateID = max(maxUpdateID, update.updateID)
                changed = await self.handleTelegramInboundUpdate(update, nowMs: nowMs) || changed
            }

            if maxUpdateID != self.telegramPairingStore.lastUpdateID {
                self.telegramPairingStore.lastUpdateID = maxUpdateID
                changed = true
            }

            changed = self.pruneTelegramPairingRequests(nowMs: nowMs) || changed
            if changed {
                self.persistTelegramPairingStore()
            }

            self.lastTelegramPairingPollSucceeded = true
            self.lastTelegramPairingPollErrorText = nil
        } catch {
            self.lastTelegramPairingPollSucceeded = false
            let nextError = error.localizedDescription
            if self.lastTelegramPairingPollErrorText != nextError {
                self.lastTelegramPairingPollErrorText = nextError
                self.appendLog("telegram pairing poll failed: \(nextError)", level: .warning)
            }
        }
    }

    private func handleTelegramInboundUpdate(_ update: TVOSTelegramInboundUpdate, nowMs: Int64) async -> Bool {
        let senderID = update.senderID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !senderID.isEmpty else {
            self.appendLog("telegram update ignored: missing sender id", level: .warning)
            return false
        }
        let maskedSenderID = Self.maskedDisplayUserID(senderID)

        let chatType = update.chatType?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? "private"
        let isAllowedSender = self.telegramPairingStore.allowFrom.contains(senderID)
        guard chatType == "private" else {
            if isAllowedSender {
                let sendError = await self.sendTelegramReplyAndMirror(
                    chatID: update.chatID,
                    senderID: senderID,
                    text: "AnemllClaw tvOS currently supports Telegram replies in private chats only.")
                if let sendError {
                    self.appendLog("telegram non-private notice failed: \(sendError)", level: .warning)
                }
                self.appendLog(
                    "telegram update ignored: non-private chat type=\(chatType) sender=\(maskedSenderID)",
                    level: .warning)
                return true
            }
            return false
        }

        if isAllowedSender {
            return await self.handleTelegramInboundChat(update, senderID: senderID)
        }

        if let pairCode = Self.extractPairCode(from: update.text) {
            if let approved = self.consumeTelegramPairingCodeForSender(
                code: pairCode,
                senderID: senderID,
                nowMs: nowMs)
            {
                let sendError = await self.sendTelegramReplyAndMirror(
                    chatID: approved.id,
                    senderID: senderID,
                    text: "AnemllClaw tvOS pairing approved. You are now linked.")
                if let sendError {
                    self.appendLog("telegram /pair reply failed: \(sendError)", level: .warning)
                }
                self.appendLog("telegram pairing self-approved sender=\(maskedSenderID) code=\(pairCode)")
                return true
            }

            let sendError = await self.sendTelegramReplyAndMirror(
                chatID: update.chatID,
                senderID: senderID,
                text: "Pairing code not found. Request a new code by sending any message.")
            if let sendError {
                self.appendLog("telegram /pair invalid reply failed: \(sendError)", level: .warning)
            }
            return false
        }

        if let existingIndex = self.telegramPairingStore.requests.firstIndex(where: { $0.id == senderID }) {
            self.telegramPairingStore.requests[existingIndex].lastSeenAtMs = nowMs
            return true
        }

        let code = self.generateUniqueTelegramPairingCode()
        var meta: [String: String] = [:]
        if let username = Self.trimmed(update.username) {
            meta["username"] = username
        }
        if let firstName = Self.trimmed(update.firstName) {
            meta["firstName"] = firstName
        }
        meta["chatId"] = update.chatID

        let request = TVOSTelegramPairingRequest(
            id: senderID,
            code: code,
            createdAtMs: nowMs,
            lastSeenAtMs: nowMs,
            meta: meta)
        self.telegramPairingStore.requests.append(request)
        _ = self.pruneTelegramPairingRequests(nowMs: nowMs)

        let message = """
        OpenClaw tvOS pairing request
        Your Telegram user id: \(senderID)
        Pairing code: \(code)
        Approve in tvOS admin panel (Pairing List + Approve).
        """
        let sendError = await self.sendTelegramReplyAndMirror(
            chatID: update.chatID,
            senderID: senderID,
            text: message)
        if let sendError {
            self.appendLog("telegram pairing code send failed: \(sendError)", level: .warning)
        }
        self.appendLog("telegram pairing request queued sender=\(maskedSenderID) code=\(code)")
        return true
    }

    private func handleTelegramInboundChat(
        _ update: TVOSTelegramInboundUpdate,
        senderID: String) async -> Bool
    {
        guard let messageText = Self.trimmed(update.text) else {
            let sendError = await self.sendTelegramReplyAndMirror(
                chatID: update.chatID,
                senderID: senderID,
                text: "Please send a text message.")
            if let sendError {
                self.appendLog("telegram non-text reply failed: \(sendError)", level: .warning)
            }
            return true
        }

        let maskedSenderID = Self.maskedDisplayUserID(senderID)
        self.mirrorTelegramInboundChatMessage(senderID: senderID, text: messageText)

        if messageText.hasPrefix("/pair") {
            let sendError = await self.sendTelegramReplyAndMirror(
                chatID: update.chatID,
                senderID: senderID,
                text: "This account is already paired. Send a normal message to chat.")
            if let sendError {
                self.appendLog("telegram already-paired reply failed: \(sendError)", level: .warning)
            }
            return true
        }

        if messageText == "/start" {
            let sendError = await self.sendTelegramReplyAndMirror(
                chatID: update.chatID,
                senderID: senderID,
                text: "AnemllClaw tvOS is linked. Send a message and I will reply.")
            if let sendError {
                self.appendLog("telegram start reply failed: \(sendError)", level: .warning)
            }
            return true
        }

        guard self.state == .running else {
            let sendError = await self.sendTelegramReplyAndMirror(
                chatID: update.chatID,
                senderID: senderID,
                text: "AnemllClaw tvOS runtime is not running.")
            if let sendError {
                self.appendLog("telegram runtime-not-running reply failed: \(sendError)", level: .warning)
            }
            return true
        }
        guard let host = self.host else {
            let sendError = await self.sendTelegramReplyAndMirror(
                chatID: update.chatID,
                senderID: senderID,
                text: "AnemllClaw tvOS runtime host is unavailable.")
            if let sendError {
                self.appendLog("telegram host-unavailable reply failed: \(sendError)", level: .warning)
            }
            return true
        }

        let sessionKey = "telegram:\(senderID)"
        self.appendLog("telegram chat inbound sender=\(maskedSenderID) chars=\(messageText.count)")

        do {
            func historyRequest() -> GatewayRequestFrame {
                GatewayRequestFrame(
                    id: UUID().uuidString,
                    method: "chat.history",
                    params: .object([
                        "sessionKey": .string(sessionKey),
                        "limit": .integer(Int64(Self.telegramChatHistoryLimit)),
                    ]))
            }

            var baselineAssistantReply: String?
            var baselineAssistantCount = 0
            if let baselineResponse = try? await host.invoke(historyRequest()), baselineResponse.ok {
                baselineAssistantReply = Self.latestAssistantReplyText(from: baselineResponse.payload)
                baselineAssistantCount = Self.assistantTurnCount(from: baselineResponse.payload)
            }

            let sendRequest = GatewayRequestFrame(
                id: UUID().uuidString,
                method: "chat.send",
                params: .object([
                    "sessionKey": .string(sessionKey),
                    "message": .string(messageText),
                    "thinking": .string("low"),
                    "idempotencyKey": .string(UUID().uuidString),
                ]))
            let sendResponse = try await host.invoke(sendRequest)
            guard sendResponse.ok else {
                let code = sendResponse.error?.code ?? "UNKNOWN"
                let message = sendResponse.error?.message ?? "chat.send failed"
                self.appendLog(
                    "telegram chat.send failed sender=\(maskedSenderID) code=\(code) message=\(message)",
                    level: .error)
                let sendError = await self.sendTelegramReplyAndMirror(
                    chatID: update.chatID,
                    senderID: senderID,
                    text: "Chat request failed (\(code)): \(message)")
                if let sendError {
                    self.appendLog("telegram chat.send-failure reply failed: \(sendError)", level: .warning)
                }
                return true
            }

            var finalHistoryPayload: GatewayJSONValue?
            for attempt in 0..<Self.telegramReplyPollAttempts {
                let historyResponse = try await host.invoke(historyRequest())
                guard historyResponse.ok else {
                    let code = historyResponse.error?.code ?? "UNKNOWN"
                    let message = historyResponse.error?.message ?? "chat.history failed"
                    self.appendLog(
                        "telegram chat.history failed sender=\(maskedSenderID) code=\(code) message=\(message)",
                        level: .error)
                    let sendError = await self.sendTelegramReplyAndMirror(
                        chatID: update.chatID,
                        senderID: senderID,
                        text: "I processed your message, but failed to fetch the reply (\(code)).")
                    if let sendError {
                        self.appendLog("telegram history-failure reply failed: \(sendError)", level: .warning)
                    }
                    return true
                }

                finalHistoryPayload = historyResponse.payload
                let assistantReply = Self.latestAssistantReplyText(from: historyResponse.payload)
                let assistantCount = Self.assistantTurnCount(from: historyResponse.payload)
                let hasFreshReply =
                    (assistantReply != nil)
                    && (assistantCount > baselineAssistantCount
                        || assistantReply != baselineAssistantReply)
                let isLastAttempt = attempt == (Self.telegramReplyPollAttempts - 1)
                if hasFreshReply || isLastAttempt {
                    break
                }

                if attempt == 0 {
                    self.appendLog("telegram reply pending sender=\(maskedSenderID) waiting for assistant output")
                }
                try? await Task.sleep(nanoseconds: Self.telegramReplyPollDelayNanoseconds)
            }

            guard let historyPayload = finalHistoryPayload,
                  let assistantReplyRaw = Self.latestAssistantReplyText(from: historyPayload)
            else {
                self.appendLog("telegram reply missing from chat.history sender=\(maskedSenderID)", level: .warning)
                let sendError = await self.sendTelegramReplyAndMirror(
                    chatID: update.chatID,
                    senderID: senderID,
                    text: "I processed your message, but no assistant reply was found.")
                if let sendError {
                    self.appendLog("telegram empty-reply notice failed: \(sendError)", level: .warning)
                }
                return true
            }

            let sanitizedReply = Self.sanitizeTelegramReplyText(assistantReplyRaw)
            let clampedReply = Self.clampTelegramReply(sanitizedReply, maxChars: Self.telegramReplyMaxChars)
            let sendError = await self.sendTelegramReplyAndMirror(
                chatID: update.chatID,
                senderID: senderID,
                text: clampedReply)
            if let sendError {
                self.appendLog("telegram reply send failed sender=\(maskedSenderID): \(sendError)", level: .warning)
            } else {
                self.appendLog("telegram chat reply sent sender=\(maskedSenderID) chars=\(clampedReply.count)")
            }
            return true
        } catch {
            self.appendLog(
                "telegram chat route threw sender=\(maskedSenderID): \(error.localizedDescription)",
                level: .error)
            let sendError = await self.sendTelegramReplyAndMirror(
                chatID: update.chatID,
                senderID: senderID,
                text: "Internal error while processing your message.")
            if let sendError {
                self.appendLog("telegram thrown-error reply failed: \(sendError)", level: .warning)
            }
            return true
        }
    }

    private func sendTelegramReplyAndMirror(chatID: String, senderID: String, text: String) async -> String? {
        let sendError = await self.sendTelegramMessage(chatID: chatID, text: text)
        if sendError == nil {
            self.mirrorTelegramOutboundChatReply(senderID: senderID, text: text)
        }
        return sendError
    }

    private func fetchTelegramUpdates(
        botToken: String,
        offset: Int64?) async throws -> [TVOSTelegramInboundUpdate]
    {
        guard let endpointURL = URL(string: "https://api.telegram.org/bot\(botToken)/getUpdates") else {
            throw TVOSRuntimeAdminBridgeError.invalidRequest("malformed telegram bot token")
        }

        var payloadObject: [String: Any] = [
            "timeout": 10,
            "limit": 50,
            "allowed_updates": ["message"],
        ]
        if let offset {
            payloadObject["offset"] = offset
        }

        let payloadData = try JSONSerialization.data(withJSONObject: payloadObject, options: [])
        var request = URLRequest(url: endpointURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 20.0
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = payloadData

        let (data, response) = try await URLSession.shared.data(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0

        guard let root = (try? JSONSerialization.jsonObject(with: data, options: [])) as? [String: Any] else {
            throw TVOSRuntimeAdminBridgeError.invalidRequest("telegram getUpdates invalid response")
        }
        let okFlag = (root["ok"] as? Bool) ?? false
        guard statusCode >= 200, statusCode < 300, okFlag else {
            let description =
                (root["description"] as? String)
                ?? String(data: data, encoding: .utf8)
                ?? "unknown Telegram API error"
            throw TVOSRuntimeAdminBridgeError.invalidRequest(
                "telegram getUpdates failed: status \(statusCode) \(description)")
        }

        guard let result = root["result"] as? [[String: Any]] else {
            return []
        }

        var updates: [TVOSTelegramInboundUpdate] = []
        updates.reserveCapacity(result.count)
        for item in result {
            guard let updateID = Self.anyInt64(item["update_id"]),
                  let message = item["message"] as? [String: Any],
                  let chat = message["chat"] as? [String: Any]
            else {
                continue
            }
            guard let chatIDRaw = Self.anyString(chat["id"]),
                  let senderIDRaw =
                  Self.anyString((message["from"] as? [String: Any])?["id"])
                  ?? Self.anyString(chat["id"])
            else {
                continue
            }
            let from = message["from"] as? [String: Any]
            let update = TVOSTelegramInboundUpdate(
                updateID: updateID,
                chatID: chatIDRaw,
                senderID: senderIDRaw,
                username: Self.anyString(from?["username"]),
                firstName: Self.anyString(from?["first_name"]),
                chatType: chat["type"] as? String,
                text: message["text"] as? String)
            updates.append(update)
        }
        return updates
    }

    private func sendTelegramMessage(chatID: String, text: String) async -> String? {
        guard let botToken = Self.trimmed(self.controlPlaneSettings.telegramBotToken) else {
            return "telegram bot token missing"
        }
        guard let endpointURL = URL(string: "https://api.telegram.org/bot\(botToken)/sendMessage") else {
            return "malformed telegram bot token"
        }
        let trimmedChatID = chatID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedChatID.isEmpty else {
            return "chat id missing"
        }
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else {
            return "text missing"
        }

        let bodyObject: [String: Any] = [
            "chat_id": trimmedChatID,
            "text": trimmedText,
        ]
        let payloadData: Data
        do {
            payloadData = try JSONSerialization.data(withJSONObject: bodyObject, options: [])
        } catch {
            return "invalid telegram message payload"
        }

        do {
            var request = URLRequest(url: endpointURL)
            request.httpMethod = "POST"
            request.timeoutInterval = 20.0
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = payloadData

            let (data, response) = try await URLSession.shared.data(for: request)
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            let decoded = (try? JSONSerialization.jsonObject(with: data, options: [])) as? [String: Any]
            let okFlag = (decoded?["ok"] as? Bool) ?? false
            guard statusCode >= 200, statusCode < 300, okFlag else {
                let description =
                    (decoded?["description"] as? String)
                    ?? String(data: data, encoding: .utf8)
                    ?? "unknown Telegram API error"
                return "telegram send failed: status \(statusCode) \(description)"
            }
            return nil
        } catch {
            return "telegram send failed: \(error.localizedDescription)"
        }
    }

    @discardableResult
    private func pruneTelegramPairingRequests(nowMs: Int64) -> Bool {
        let previousRequests = self.telegramPairingStore.requests
        let cutoff = nowMs - Self.telegramPairingPendingTTLms
        self.telegramPairingStore.requests = self.telegramPairingStore.requests.filter { request in
            request.createdAtMs >= cutoff
        }
        if self.telegramPairingStore.requests.count > Self.telegramPairingPendingMax {
            self.telegramPairingStore.requests.sort { lhs, rhs in
                lhs.lastSeenAtMs > rhs.lastSeenAtMs
            }
            self.telegramPairingStore.requests = Array(
                self.telegramPairingStore.requests.prefix(Self.telegramPairingPendingMax))
        }
        return previousRequests != self.telegramPairingStore.requests
    }

    private func consumeTelegramPairingCode(code: String, nowMs: Int64) -> TVOSTelegramPairingRequest? {
        guard let index = self.telegramPairingStore.requests.firstIndex(where: {
            $0.code.caseInsensitiveCompare(code) == .orderedSame
        }) else {
            return nil
        }
        return self.approveTelegramPairingRequest(at: index, nowMs: nowMs)
    }

    private func consumeTelegramPairingCodeForSender(
        code: String,
        senderID: String,
        nowMs: Int64) -> TVOSTelegramPairingRequest?
    {
        guard let index = self.telegramPairingStore.requests.firstIndex(where: {
            $0.id == senderID && $0.code.caseInsensitiveCompare(code) == .orderedSame
        }) else {
            return nil
        }
        return self.approveTelegramPairingRequest(at: index, nowMs: nowMs)
    }

    private func approveTelegramPairingRequest(
        at index: Int,
        nowMs: Int64) -> TVOSTelegramPairingRequest?
    {
        guard self.telegramPairingStore.requests.indices.contains(index) else {
            return nil
        }
        var request = self.telegramPairingStore.requests[index]
        request.lastSeenAtMs = nowMs
        self.telegramPairingStore.requests.remove(at: index)
        if !self.telegramPairingStore.allowFrom.contains(request.id) {
            self.telegramPairingStore.allowFrom.append(request.id)
        }
        return request
    }

    private func persistTelegramPairingStore() {
        do {
            try FileManager.default.createDirectory(
                at: self.telegramPairingStorePath.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(self.telegramPairingStore)
            try data.write(to: self.telegramPairingStorePath, options: .atomic)
        } catch {
            self.appendLog("telegram pairing store persist failed: \(error.localizedDescription)", level: .warning)
        }
    }

    private func generateUniqueTelegramPairingCode() -> String {
        let existing = Set(self.telegramPairingStore.requests.map(\.code))
        for _ in 0..<500 {
            let code = Self.randomTelegramPairingCode()
            if !existing.contains(code) {
                return code
            }
        }
        return Self.randomTelegramPairingCode()
    }

    private static func randomTelegramPairingCode() -> String {
        var output = ""
        output.reserveCapacity(Self.telegramPairingCodeLength)
        for _ in 0..<Self.telegramPairingCodeLength {
            if let random = Self.telegramPairingCodeAlphabet.randomElement() {
                output.append(random)
            }
        }
        return output
    }

    private static func isValidTelegramPairingCode(_ value: String) -> Bool {
        guard value.count == self.telegramPairingCodeLength else {
            return false
        }
        for scalar in value.unicodeScalars {
            let character = Character(scalar)
            if !Self.telegramPairingCodeAlphabet.contains(character) {
                return false
            }
        }
        return true
    }

    private static func looksLikeTelegramBotToken(_ value: String) -> Bool {
        let parts = value.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2 else {
            return false
        }
        let prefix = String(parts[0])
        let suffix = String(parts[1])
        guard !prefix.isEmpty, !suffix.isEmpty else {
            return false
        }
        guard prefix.allSatisfy(\.isNumber) else {
            return false
        }
        return suffix.allSatisfy { character in
            character.isLetter || character.isNumber || character == "_" || character == "-"
        }
    }

    private static func extractPairCode(from rawText: String?) -> String? {
        guard let rawText else { return nil }
        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let prefix = "/pair "
        if trimmed.lowercased().hasPrefix(prefix) {
            let code = String(trimmed.dropFirst(prefix.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .uppercased()
            return code.isEmpty ? nil : code
        }
        return nil
    }

    private static func anyInt64(_ value: Any?) -> Int64? {
        switch value {
        case let number as NSNumber:
            number.int64Value
        case let string as String:
            Int64(string.trimmingCharacters(in: .whitespacesAndNewlines))
        case let int as Int:
            Int64(int)
        case let int64 as Int64:
            int64
        default:
            nil
        }
    }

    private static func anyString(_ value: Any?) -> String? {
        switch value {
        case let string as String:
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        case let number as NSNumber:
            return number.stringValue
        default:
            return nil
        }
    }

    private static func presenceState(_ value: String) -> String {
        (self.trimmed(value)?.isEmpty == false) ? "present" : "missing"
    }

    private static func normalizedSettings(
        _ settings: TVOSGatewayControlPlaneSettings) -> TVOSGatewayControlPlaneSettings
    {
        let authMode: GatewayCoreAuthMode
        let normalizedAuthToken = Self.trimmed(settings.authToken) ?? ""
        let normalizedAuthPassword = Self.trimmed(settings.authPassword) ?? ""

        switch settings.authMode {
        case .none:
            authMode = .none
        case .token:
            authMode = normalizedAuthToken.isEmpty ? .none : .token
        case .password:
            authMode = normalizedAuthPassword.isEmpty ? .none : .password
        }

        let sanitizedAuthToken =
            authMode == .token ? normalizedAuthToken : ""
        let sanitizedAuthPassword =
            authMode == .password ? normalizedAuthPassword : ""

        return TVOSGatewayControlPlaneSettings(
            authMode: authMode,
            authToken: sanitizedAuthToken,
            authPassword: sanitizedAuthPassword,
            upstreamURL: Self.trimmed(settings.upstreamURL) ?? "",
            upstreamToken: Self.trimmed(settings.upstreamToken) ?? "",
            upstreamPassword: Self.trimmed(settings.upstreamPassword) ?? "",
            upstreamRole: Self.trimmed(settings.upstreamRole) ?? "node",
            upstreamScopesCSV: Self.trimmed(settings.upstreamScopesCSV) ?? "",
            localLLMProvider: settings.localLLMProvider,
            localLLMBaseURL: Self.trimmed(settings.localLLMBaseURL) ?? "",
            localLLMAPIKey: Self.trimmed(settings.localLLMAPIKey) ?? "",
            localLLMModel: Self.trimmed(settings.localLLMModel) ?? "",
            localLLMToolCallingMode: settings.localLLMToolCallingMode,
            telegramBotToken: Self.trimmed(settings.telegramBotToken) ?? "",
            telegramDefaultChatID: Self.trimmed(settings.telegramDefaultChatID) ?? "",
            enableLocalDeviceTools: settings.enableLocalDeviceTools,
            disabledToolNames: settings.disabledToolNames,
            bootstrapPerFileMaxChars: max(1000, settings.bootstrapPerFileMaxChars),
            bootstrapTotalMaxChars: max(4000, settings.bootstrapTotalMaxChars))
    }

    private static func makeAuthConfig(from settings: TVOSGatewayControlPlaneSettings) -> GatewayCoreAuthConfig {
        let token = Self.trimmed(settings.authToken)
        let password = Self.trimmed(settings.authPassword)

        switch settings.authMode {
        case .none:
            return .none
        case .token:
            guard let token else { return .none }
            return GatewayCoreAuthConfig(mode: .token, token: token)
        case .password:
            guard let password else { return .none }
            return GatewayCoreAuthConfig(mode: .password, password: password)
        }
    }

    private func logAuthNormalization(
        from original: TVOSGatewayControlPlaneSettings,
        to normalized: TVOSGatewayControlPlaneSettings,
        context: String)
    {
        if original.authMode == .token, normalized.authMode == .none {
            self.appendLog(
                "auth mode normalization [\(context)]: token mode requested without token; "
                    + "falling back to none")
        }
        if original.authMode == .password, normalized.authMode == .none {
            self.appendLog(
                "auth mode normalization [\(context)]: password mode requested without password; "
                    + "falling back to none")
        }
        if original.authMode == .none, normalized.authMode == .none {
            if Self.trimmed(original.authToken) != nil || Self.trimmed(original.authPassword) != nil {
                self.appendLog(
                    "auth mode normalization [\(context)]: auth mode none, credentials ignored")
            }
        }
    }

    private func logControlPlaneConfigDump(context: String) {
        let upstreamURL = Self.trimmed(self.controlPlaneSettings.upstreamURL) ?? "(none)"
        let upstreamRole = Self.trimmed(self.controlPlaneSettings.upstreamRole) ?? "node"
        let localModel = Self.trimmed(self.controlPlaneSettings.localLLMModel) ?? "(none)"
        let localBaseURL =
            Self.trimmed(self.controlPlaneSettings.localLLMBaseURL) ?? "(none)"
        let telegramDefaultChatID =
            Self.trimmed(self.controlPlaneSettings.telegramDefaultChatID) ?? "(none)"
        let telegramTokenState = self.controlPlaneSettings.telegramBotToken.isEmpty
            ? "(missing)"
            : Self.redacted(self.controlPlaneSettings.telegramBotToken)
        let bootstrapPath = Self.defaultBootstrapWorkspacePath()
        let bootstrapState = bootstrapPath.isEmpty ? "(none)" : bootstrapPath
        let authTokenState = self.controlPlaneSettings.authToken.isEmpty
            ? "(missing)"
            : Self.redacted(self.controlPlaneSettings.authToken)
        let authPasswordState = self.controlPlaneSettings.authPassword.isEmpty
            ? "(missing)"
            : Self.redacted(self.controlPlaneSettings.authPassword)

        let localAPIKeyState = self.controlPlaneSettings.localLLMAPIKey.isEmpty
            ? "(missing)"
            : Self.redacted(self.controlPlaneSettings.localLLMAPIKey)

        self.appendLog(
            "config dump [\(context)] authMode=\(self.controlPlaneSettings.authMode.rawValue)"
                + " authToken=\(authTokenState)"
                + " authPassword=\(authPasswordState)"
                + " upstream=\(upstreamURL)"
                + " role=\(upstreamRole)"
                + " llm=\(self.controlPlaneSettings.localLLMProvider.rawValue)"
                + " model=\(localModel)"
                + " baseURL=\(localBaseURL)"
                + " apiKey=\(localAPIKeyState)"
                + " llmConfigured=\(self.localLLMConfigured)"
                + " tools=\(self.controlPlaneSettings.localLLMToolCallingMode.rawValue)"
                + " deviceTools=\(self.controlPlaneSettings.enableLocalDeviceTools)"
                + " deviceBridge=\(self.deviceBridgeConfigured ? "yes" : "no")"
                + " telegramChat=\(telegramDefaultChatID)"
                + " telegramToken=\(telegramTokenState)"
                + " bootstrapPath=\(bootstrapState)")
    }

    private static func makeUpstreamConfig(
        from settings: TVOSGatewayControlPlaneSettings) -> TVOSGatewayUpstreamConfigLoadResult
    {
        guard let rawURL = trimmed(settings.upstreamURL) else {
            return TVOSGatewayUpstreamConfigLoadResult(
                config: nil,
                urlText: nil,
                errorText: nil)
        }
        guard let url = URL(string: rawURL) else {
            return TVOSGatewayUpstreamConfigLoadResult(
                config: nil,
                urlText: rawURL,
                errorText: "invalid upstream URL")
        }
        let scheme = url.scheme?.lowercased() ?? ""
        guard scheme == "ws" || scheme == "wss" else {
            return TVOSGatewayUpstreamConfigLoadResult(
                config: nil,
                urlText: rawURL,
                errorText: "upstream URL scheme must be ws or wss")
        }

        let scopes = Self.trimmed(settings.upstreamScopesCSV)?
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        return TVOSGatewayUpstreamConfigLoadResult(
            config: GatewayUpstreamWebSocketConfig(
                url: url,
                token: Self.trimmed(settings.upstreamToken),
                password: Self.trimmed(settings.upstreamPassword),
                role: Self.trimmed(settings.upstreamRole) ?? "node",
                scopes: scopes),
            urlText: url.absoluteString,
            errorText: nil)
    }

    private static func makeLocalLLMConfig(from settings: TVOSGatewayControlPlaneSettings) -> GatewayLocalLLMConfig {
        let baseURL = Self.trimmed(settings.localLLMBaseURL).flatMap(URL.init(string:))
        return GatewayLocalLLMConfig(
            provider: settings.localLLMProvider,
            baseURL: baseURL,
            apiKey: Self.trimmed(settings.localLLMAPIKey),
            model: Self.trimmed(settings.localLLMModel))
    }

    private static func makeLocalTelegramConfig(
        from settings: TVOSGatewayControlPlaneSettings) -> GatewayLocalTelegramConfig
    {
        GatewayLocalTelegramConfig(
            botToken: self.trimmed(settings.telegramBotToken) ?? "",
            defaultChatID: self.trimmed(settings.telegramDefaultChatID) ?? "")
    }

    private static func defaultTelegramPairingStorePath() -> URL {
        let fileManager = FileManager.default
        if let cachesBase = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first {
            let preferredDirectory = cachesBase.appendingPathComponent("OpenClawTV", isDirectory: true)
            if self.isWritableDirectory(preferredDirectory) {
                return preferredDirectory.appendingPathComponent("TelegramPairing.json", isDirectory: false)
            }
            if self.isWritableDirectory(cachesBase) {
                return cachesBase.appendingPathComponent("TelegramPairing.json", isDirectory: false)
            }
        }
        return fileManager.temporaryDirectory
            .appendingPathComponent("TelegramPairing.json", isDirectory: false)
    }

    private static func loadTelegramPairingStore(at path: URL) -> TVOSTelegramPairingStore {
        guard let data = try? Data(contentsOf: path),
              let store = try? JSONDecoder().decode(TVOSTelegramPairingStore.self, from: data)
        else {
            return .empty
        }
        return TVOSTelegramPairingStore(
            version: store.version == 0 ? 1 : store.version,
            lastUpdateID: max(0, store.lastUpdateID),
            allowFrom: Array(
                Set(
                    store.allowFrom
                        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                        .filter { !$0.isEmpty })).sorted(),
            requests: store.requests)
    }

    private static func defaultMemoryStorePath() -> URL {
        let fileManager = FileManager.default
        if let cachesBase = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first {
            let preferredStore = cachesBase
                .appendingPathComponent("OpenClawTV", isDirectory: true)
            if self.isWritableDirectory(preferredStore) {
                return preferredStore.appendingPathComponent("GatewayMemory.sqlite", isDirectory: false)
            }
            if self.isWritableDirectory(cachesBase) {
                return cachesBase.appendingPathComponent("GatewayMemory.sqlite", isDirectory: false)
            }
        }

        if let libraryBase = fileManager.urls(for: .libraryDirectory, in: .userDomainMask).first {
            let legacyStore = libraryBase
                .appendingPathComponent("Caches", isDirectory: true)
                .appendingPathComponent("OpenClawTV", isDirectory: true)
            if self.isWritableDirectory(legacyStore) {
                return legacyStore.appendingPathComponent("GatewayMemory.sqlite", isDirectory: false)
            }
            if self.isWritableDirectory(libraryBase) {
                return libraryBase
                    .appendingPathComponent("Caches", isDirectory: true)
                    .appendingPathComponent("GatewayMemory.sqlite", isDirectory: false)
            }
        }

        return fileManager.temporaryDirectory
            .appendingPathComponent("GatewayMemory.sqlite", isDirectory: false)
    }

    var bootstrapWorkspacePath: String {
        Self.defaultBootstrapWorkspacePath()
    }

    private static func defaultBootstrapWorkspacePath() -> String {
        let fileManager = FileManager.default
        var candidates: [URL] = []
        if let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first {
            candidates.append(
                documents
                    .appendingPathComponent("OpenClawTV", isDirectory: true)
                    .appendingPathComponent("Workspace", isDirectory: true))
        }
        if let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first {
            candidates.append(
                caches
                    .appendingPathComponent("OpenClawTVWorkspace", isDirectory: true))
        }
        candidates.append(
            fileManager.temporaryDirectory
                .appendingPathComponent("OpenClawTVWorkspace", isDirectory: true))

        for candidate in candidates {
            if self.isWritableDirectory(candidate) {
                return candidate.path
            }
        }
        return ""
    }

    private static func bootstrapAssistantName(workspacePath: String) -> String? {
        let trimmedPath = workspacePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPath.isEmpty else { return nil }

        let identityURL = URL(fileURLWithPath: trimmedPath, isDirectory: true)
            .appendingPathComponent("IDENTITY.md", isDirectory: false)
        guard let content = try? String(contentsOf: identityURL, encoding: .utf8) else { return nil }

        for rawLine in content.split(whereSeparator: \.isNewline) {
            let line = String(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
            guard line.lowercased().hasPrefix("- **name:**") else { continue }
            guard let separator = line.firstIndex(of: ":") else { continue }
            let rawValue = String(line[line.index(after: separator)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !rawValue.isEmpty else { return nil }
            guard !rawValue.hasPrefix("_("), !rawValue.hasPrefix("(") else { return nil }

            let cleaned = rawValue.trimmingCharacters(in: CharacterSet(charactersIn: "*_` "))
            if cleaned.isEmpty { return nil }
            return cleaned
        }

        return nil
    }

    private static func isWritableDirectory(_ directory: URL) -> Bool {
        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true)
            let testURL = directory.appendingPathComponent(".openclaw-write-test-\(UUID().uuidString)")
            let marker = Data("ok".utf8)
            try marker.write(to: testURL, options: .atomic)
            try? fileManager.removeItem(at: testURL)
            return true
        } catch {
            return false
        }
    }

    private static func isTCPAddressInUseError(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSPOSIXErrorDomain, nsError.code == EADDRINUSE {
            return true
        }
        return error.localizedDescription.lowercased().contains("address already in use")
    }

    private static func fallbackMemoryStorePath() -> URL {
        let fileManager = FileManager.default
        if let cachesBase = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first {
            if self.isWritableDirectory(cachesBase) {
                return cachesBase.appendingPathComponent("GatewayMemory.sqlite", isDirectory: false)
            }
            return cachesBase
                .appendingPathComponent("OpenClawTV", isDirectory: true)
                .appendingPathComponent("GatewayMemory.sqlite", isDirectory: false)
        }
        return fileManager.temporaryDirectory
            .appendingPathComponent("GatewayMemory.sqlite", isDirectory: false)
    }

    private func appendLog(_ message: String, level: TVOSGatewayRuntimeLogEntry.Level = .info) {
        let formattedMessage = "[AnemllClaw tvOS][\(level.rawValue.uppercased())] \(message)"
        #if DEBUG
        print(formattedMessage)
        #endif
        switch level {
        case .info:
            Self.runtimeLogger.info("\(formattedMessage, privacy: .public)")
        case .warning:
            Self.runtimeLogger.warning("\(formattedMessage, privacy: .public)")
        case .error:
            Self.runtimeLogger.error("\(formattedMessage, privacy: .public)")
        }

        self.diagnosticsLog.append(
            TVOSGatewayRuntimeLogEntry(level: level, message: message))

        let overflowCount = self.diagnosticsLog.count - Self.maxDiagnosticsLogEntries
        if overflowCount > 0 {
            self.diagnosticsLog.removeFirst(overflowCount)
        }
    }

    private static func trimmed(_ value: String?) -> String? {
        let raw = (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return raw.isEmpty ? nil : raw
    }

    private static func maskedDisplayUserID(_ rawID: String) -> String {
        let trimmedID = rawID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedID.isEmpty else { return "*" }
        let visibleCount = min(4, trimmedID.count)
        return "*\(trimmedID.suffix(visibleCount))"
    }

    private static func listenerEndpointSummary(
        port: UInt16,
        localAddresses: [String],
        scheme: String,
        localhostOnly: Bool = false) -> String
    {
        let loopback = "\(scheme)://127.0.0.1:\(port)"
        if localhostOnly {
            return "127.0.0.1:\(port) (\(loopback))"
        }
        guard !localAddresses.isEmpty else {
            return "0.0.0.0:\(port) (\(loopback))"
        }
        let lan = localAddresses
            .map { "\(scheme)://\($0):\(port)" }
            .joined(separator: ", ")
        return "0.0.0.0:\(port) (\(loopback), \(lan))"
    }

    private struct LocalIPv4Interface: Sendable {
        let name: String
        let address: String
    }

    private static func collectLocalIPv4Interfaces() -> [LocalIPv4Interface] {
        var interfaces: [LocalIPv4Interface] = []
        var pointer: UnsafeMutablePointer<ifaddrs>?

        guard getifaddrs(&pointer) == 0, let first = pointer else {
            return []
        }
        defer { freeifaddrs(pointer) }

        var current: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = current {
            defer { current = entry.pointee.ifa_next }

            let flags = entry.pointee.ifa_flags
            guard (flags & UInt32(IFF_UP)) != 0, (flags & UInt32(IFF_RUNNING)) != 0 else {
                continue
            }
            guard (flags & UInt32(IFF_LOOPBACK)) == 0 else {
                continue
            }
            guard let addressPtr = entry.pointee.ifa_addr else {
                continue
            }
            guard addressPtr.pointee.sa_family == UInt8(AF_INET) else {
                continue
            }

            let interfaceName = String(cString: entry.pointee.ifa_name)
            guard !interfaceName.hasPrefix("lo"), !interfaceName.hasPrefix("utun"),
                  !interfaceName.hasPrefix("awdl"), !interfaceName.hasPrefix("llw")
            else {
                continue
            }

            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let getNameResult = getnameinfo(
                addressPtr,
                socklen_t(addressPtr.pointee.sa_len),
                &host,
                socklen_t(host.count),
                nil,
                0,
                NI_NUMERICHOST)
            guard getNameResult == 0 else {
                continue
            }

            let utf8Bytes = host.map { UInt8(bitPattern: $0) }
            let ipAddress = String(decoding: utf8Bytes.prefix { $0 != 0 }, as: UTF8.self)
            guard !ipAddress.isEmpty else {
                continue
            }

            interfaces.append(
                LocalIPv4Interface(
                    name: interfaceName,
                    address: ipAddress))
        }

        interfaces.sort { lhs, rhs in
            let leftPriority = Self.interfacePriority(lhs.name)
            let rightPriority = Self.interfacePriority(rhs.name)
            if leftPriority != rightPriority {
                return leftPriority < rightPriority
            }
            if lhs.name != rhs.name {
                return lhs.name < rhs.name
            }
            return lhs.address < rhs.address
        }

        var seenAddresses = Set<String>()
        return interfaces.filter { seenAddresses.insert($0.address).inserted }
    }

    private static func interfacePriority(_ name: String) -> Int {
        if name == "en0" {
            return 0
        }
        if name == "en1" {
            return 1
        }
        if name.hasPrefix("en") {
            return 2
        }
        if name.hasPrefix("bridge") {
            return 3
        }
        return 4
    }
}
#endif
