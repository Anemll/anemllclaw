import Foundation

public enum GatewayAgentRunStatus: String, Codable, Sendable {
    case queued
    case running
    case completed
    case failed
    case aborted
}

public struct GatewayAgentRunStep: Sendable, Codable {
    public let type: String?
    public let prompt: String?
    public let tool: GatewayAgentToolSpec?

    public init(type: String? = nil, prompt: String? = nil, tool: GatewayAgentToolSpec? = nil) {
        self.type = type
        self.prompt = prompt
        self.tool = tool
    }
}

public struct GatewayAgentToolSpec: Sendable, Codable {
    public let command: String
    public let params: GatewayJSONValue?

    public init(command: String, params: GatewayJSONValue? = nil) {
        self.command = command
        self.params = params
    }
}

public struct GatewayAgentRunSnapshot: Sendable, Codable, Equatable {
    public let runId: String
    public let sessionKey: String
    public var status: GatewayAgentRunStatus
    public let goal: String
    public let startedAtMs: Int64
    public var updatedAtMs: Int64
    public var stepsCompleted: Int
    public let totalSteps: Int
    public var currentStep: String?
    public var output: String?
    public var error: String?
}

public actor GatewayAgentRuntime {
    private struct StoredRun {
        var snapshot: GatewayAgentRunSnapshot
        var cancelRequested: Bool
    }

    private let sessionStore: GatewaySessionStore
    private let memoryStore: GatewaySQLiteMemoryStore
    private let llmProvider: (any GatewayLocalLLMProvider)?
    private let hostLabel: String
    private let enableLocalSafeTools: Bool
    private let enableLocalFileTools: Bool
    private let enableLocalDeviceTools: Bool
    private let deviceToolBridge: (any GatewayDeviceToolBridge)?
    private let telegramConfig: GatewayLocalTelegramConfig
    private let workspaceRoot: URL?
    private let urlSession: URLSession

    private var runs: [String: StoredRun] = [:]
    private var tasks: [String: Task<Void, Never>] = [:]

    public init(
        sessionStore: GatewaySessionStore,
        memoryStore: GatewaySQLiteMemoryStore,
        llmProvider: (any GatewayLocalLLMProvider)?,
        hostLabel: String,
        enableLocalSafeTools: Bool,
        enableLocalFileTools: Bool,
        enableLocalDeviceTools: Bool = false,
        deviceToolBridge: (any GatewayDeviceToolBridge)? = nil,
        telegramConfig: GatewayLocalTelegramConfig = .disabled,
        workspaceRoot: URL?,
        session: URLSession = URLSession(configuration: .ephemeral))
    {
        self.sessionStore = sessionStore
        self.memoryStore = memoryStore
        self.llmProvider = llmProvider
        self.hostLabel = hostLabel
        self.enableLocalSafeTools = enableLocalSafeTools
        self.enableLocalFileTools = enableLocalFileTools
        self.enableLocalDeviceTools = enableLocalDeviceTools
        self.deviceToolBridge = deviceToolBridge
        self.telegramConfig = telegramConfig
        self.workspaceRoot = workspaceRoot
        self.urlSession = session
    }

    public func startRun(
        runID requestedRunID: String?,
        sessionKey rawSessionKey: String?,
        goal: String,
        maxSteps: Int?,
        steps: [GatewayAgentRunStep]?,
        nowMs: Int64) -> GatewayAgentRunSnapshot
    {
        let sessionKey = Self.normalizedSessionKey(rawSessionKey)
        let normalizedGoal = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        let runID = Self.normalizedRunID(requestedRunID, fallback: UUID().uuidString)
        let requestedSteps = self.sanitizedSteps(steps, fallbackGoal: normalizedGoal, maxSteps: maxSteps)
        let statusNow = GatewayAgentRunStatus.queued
        let now = nowMs
        let initialSnapshot = GatewayAgentRunSnapshot(
            runId: runID,
            sessionKey: sessionKey,
            status: statusNow,
            goal: normalizedGoal,
            startedAtMs: now,
            updatedAtMs: now,
            stepsCompleted: 0,
            totalSteps: requestedSteps.count,
            currentStep: "queued",
            output: nil,
            error: nil)

        self.runs[runID] = StoredRun(snapshot: initialSnapshot, cancelRequested: false)
        let task = Task { [weak self] in
            guard let self else { return }
            await self.execute(runID: runID, sessionKey: sessionKey, steps: requestedSteps, nowMs: now)
        }
        self.tasks[runID] = task
        return initialSnapshot
    }

    public func runStatus(_ runID: String) -> GatewayAgentRunSnapshot? {
        self.runs[runID].map(\.snapshot)
    }

    public func abortRun(_ runID: String, nowMs: Int64) -> Bool {
        guard var stored = self.runs[runID] else {
            return false
        }
        if stored.snapshot.status == .completed
            || stored.snapshot.status == .failed
            || stored.snapshot.status == .aborted
        {
            return false
        }
        stored.cancelRequested = true
        stored.snapshot = GatewayAgentRunSnapshot(
            runId: stored.snapshot.runId,
            sessionKey: stored.snapshot.sessionKey,
            status: .aborted,
            goal: stored.snapshot.goal,
            startedAtMs: stored.snapshot.startedAtMs,
            updatedAtMs: nowMs,
            stepsCompleted: stored.snapshot.stepsCompleted,
            totalSteps: stored.snapshot.totalSteps,
            currentStep: "aborted",
            output: stored.snapshot.output,
            error: "aborted by request")
        self.runs[runID] = stored
        self.tasks[runID]?.cancel()
        return true
    }

    private func execute(runID: String, sessionKey: String, steps: [GatewayAgentRunStep], nowMs: Int64) async {
        defer {
            self.tasks[runID] = nil
        }
        self.update(runID: runID, updater: { state in
            state.status = .running
            state.currentStep = "starting"
            state.updatedAtMs = GatewayCore.currentTimestampMs()
        })

        guard self.runs[runID] != nil else {
            return
        }
        guard !steps.isEmpty else {
            self.fail(runID: runID, nowMs: nowMs, message: "agent run has no steps")
            return
        }

        let runIDCapture = runID
        let sessionKeyCapture = sessionKey
        let memoryStore = self.memoryStore
        let provider = self.llmProvider
        let hostLabel = self.hostLabel
        let safeToolsEnabled = self.enableLocalSafeTools
        let fileToolsEnabled = self.enableLocalFileTools
        let deviceToolsEnabled = self.enableLocalDeviceTools
        let deviceBridge = self.deviceToolBridge
        let telegramConfig = self.telegramConfig
        let workspaceRoot = self.workspaceRoot
        let urlSession = self.urlSession
        let runGoal = self.runs[runID]?.snapshot.goal ?? ""

        do {
            if !runGoal.isEmpty {
                _ = try await self.sessionStore.runQueued(sessionKey: sessionKeyCapture) {
                    _ = try await memoryStore.appendTurn(
                        sessionKey: sessionKeyCapture,
                        role: "user",
                        text: "agent goal: \(runGoal)",
                        timestampMs: GatewayCore.currentTimestampMs(),
                        runID: runIDCapture)
                    return true
                }
            }

            for stepIndex in steps.indices {
                try Task.checkCancellation()
                if self.isCancelled(runID: runIDCapture) {
                    throw CancellationError()
                }
                let zeroBased = stepIndex
                let step = steps[zeroBased]
                let stepType = step.type?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? "llm"
                self.update(runID: runIDCapture, updater: { state in
                    state.currentStep = stepType
                    state.stepsCompleted = zeroBased
                    state.updatedAtMs = GatewayCore.currentTimestampMs()
                })

                if stepType == "tool" {
                    guard let tool = step.tool else {
                        throw NSError(
                            domain: "GatewayAgentRuntime",
                            code: 1,
                            userInfo: [NSLocalizedDescriptionKey: "tool step missing tool specification"])
                    }
                    let toolResult = await GatewayLocalTooling.execute(
                        command: tool.command,
                        params: tool.params,
                        hostLabel: hostLabel,
                        workspaceRoot: workspaceRoot,
                        urlSession: urlSession,
                        telegramConfig: telegramConfig,
                        enableLocalSafeTools: safeToolsEnabled,
                        enableLocalFileTools: fileToolsEnabled,
                        enableLocalDeviceTools: deviceToolsEnabled,
                        deviceToolBridge: deviceBridge)
                    if let toolError = toolResult.error {
                        throw NSError(
                            domain: "GatewayAgentRuntime",
                            code: 1,
                            userInfo: [NSLocalizedDescriptionKey: "tool execution failed: \(toolError)"])
                    }
                    let toolPayload = (try? toolResult.payload.jsonString()) ?? "tool response"
                    _ = try await self.sessionStore.runQueued(sessionKey: sessionKeyCapture) {
                        _ = try await memoryStore.appendTurn(
                            sessionKey: sessionKeyCapture,
                            role: "assistant",
                            text: "tool[\(tool.command)]: \(toolPayload)",
                            timestampMs: GatewayCore.currentTimestampMs(),
                            runID: runIDCapture)
                        return true
                    }
                    self.update(runID: runIDCapture, updater: { state in
                        state.output = "tool[\(tool.command)] ok"
                        state.stepsCompleted = zeroBased + 1
                    })
                    continue
                }

                guard let provider else {
                    throw NSError(
                        domain: "GatewayAgentRuntime",
                        code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "local LLM not configured"])
                }
                let prompt = step.prompt?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "Please continue"
                let responseText = try await self.sessionStore.runQueued(sessionKey: sessionKeyCapture) {
                    let history = try await memoryStore.history(sessionKey: sessionKeyCapture, limit: 128)
                    var messages = history.map { GatewayLocalLLMMessage(role: $0.role, text: $0.text) }
                    messages.append(.init(role: "user", text: "agent step \(zeroBased + 1): \(prompt)"))
                    let response = try await provider.complete(
                        GatewayLocalLLMRequest(messages: messages, thinkingLevel: "low"))
                    _ = try await memoryStore.appendTurn(
                        sessionKey: sessionKeyCapture,
                        role: "assistant",
                        text: response.text,
                        timestampMs: GatewayCore.currentTimestampMs(),
                        runID: runIDCapture)
                    return response.text
                }
                self.update(runID: runIDCapture, updater: { state in
                    state.output = responseText
                    state.stepsCompleted = zeroBased + 1
                })
            }

            let finalNow = GatewayCore.currentTimestampMs()
            if self.isCancelled(runID: runID) {
                self.abort(runID: runIDCapture, nowMs: finalNow, message: "aborted")
            } else {
                self.complete(runID: runIDCapture, nowMs: finalNow)
            }
        } catch is CancellationError {
            self.abort(runID: runID, nowMs: GatewayCore.currentTimestampMs(), message: "aborted")
        } catch {
            self.fail(
                runID: runID,
                nowMs: GatewayCore.currentTimestampMs(),
                message: error.localizedDescription)
        }
    }

    private func sanitizedSteps(
        _ rawSteps: [GatewayAgentRunStep]?,
        fallbackGoal: String,
        maxSteps: Int?) -> [GatewayAgentRunStep]
    {
        if let rawSteps, !rawSteps.isEmpty {
            let clampedMax = max(1, min(maxSteps ?? rawSteps.count, 32))
            return Array(rawSteps.prefix(clampedMax))
        }
        return [
            GatewayAgentRunStep(
                type: "llm",
                prompt: fallbackGoal.isEmpty ? "You are a TVOS local agent." : fallbackGoal,
                tool: nil),
        ]
    }

    private func complete(runID: String, nowMs: Int64) {
        if var run = self.runs[runID] {
            run.snapshot = GatewayAgentRunSnapshot(
                runId: run.snapshot.runId,
                sessionKey: run.snapshot.sessionKey,
                status: .completed,
                goal: run.snapshot.goal,
                startedAtMs: run.snapshot.startedAtMs,
                updatedAtMs: nowMs,
                stepsCompleted: run.snapshot.stepsCompleted,
                totalSteps: run.snapshot.totalSteps,
                currentStep: run.snapshot.currentStep,
                output: run.snapshot.output,
                error: nil)
            self.runs[runID] = run
        }
    }

    private func abort(runID: String, nowMs: Int64, message: String) {
        if var run = self.runs[runID] {
            run.snapshot = GatewayAgentRunSnapshot(
                runId: run.snapshot.runId,
                sessionKey: run.snapshot.sessionKey,
                status: .aborted,
                goal: run.snapshot.goal,
                startedAtMs: run.snapshot.startedAtMs,
                updatedAtMs: nowMs,
                stepsCompleted: run.snapshot.stepsCompleted,
                totalSteps: run.snapshot.totalSteps,
                currentStep: "aborted",
                output: run.snapshot.output,
                error: message)
            self.runs[runID] = run
        }
    }

    private func fail(runID: String, nowMs: Int64, message: String) {
        if var run = self.runs[runID] {
            run.snapshot = GatewayAgentRunSnapshot(
                runId: run.snapshot.runId,
                sessionKey: run.snapshot.sessionKey,
                status: .failed,
                goal: run.snapshot.goal,
                startedAtMs: run.snapshot.startedAtMs,
                updatedAtMs: nowMs,
                stepsCompleted: run.snapshot.stepsCompleted,
                totalSteps: run.snapshot.totalSteps,
                currentStep: "failed",
                output: run.snapshot.output,
                error: message)
            self.runs[runID] = run
        }
    }

    private func isCancelled(runID: String) -> Bool {
        self.runs[runID]?.cancelRequested == true || self.tasks[runID]?.isCancelled == true
    }

    private func update(runID: String, updater: (inout GatewayAgentRunSnapshot) -> Void) {
        if var run = self.runs[runID] {
            var snapshot = run.snapshot
            updater(&snapshot)
            run.snapshot = snapshot
            self.runs[runID] = run
        }
    }

    private static func normalizedSessionKey(_ raw: String?) -> String {
        let trimmed = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "main" : trimmed
    }

    private static func normalizedRunID(_ raw: String?, fallback: String) -> String {
        let trimmed = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : trimmed
    }
}
