import Foundation
import Observation
import os
import SwiftUI

// MARK: - Dream State

enum DreamState: String, Sendable {
    case awake
    case dreaming
    case waking
}

// MARK: - Dream Animation Variants

enum DreamAnimation: String, CaseIterable, Identifiable, Codable, Sendable {
    case flamePulse = "flame_pulse"
    case aurora
    case starfield
    case breathingOrb = "breathing_orb"
    case flurry
    case flurryClassic = "flurry_classic"

    var id: String {
        self.rawValue
    }

    var displayName: String {
        switch self {
        case .flamePulse: "Flame Pulse"
        case .aurora: "Aurora"
        case .starfield: "Starfield"
        case .breathingOrb: "Breathing Orb"
        case .flurry: "Flurry"
        case .flurryClassic: "Flurry Classic"
        }
    }

    var iconName: String {
        switch self {
        case .flamePulse: "flame.fill"
        case .aurora: "sparkles"
        case .starfield: "star.fill"
        case .breathingOrb: "circle.circle"
        case .flurry: "wind"
        case .flurryClassic: "wind.circle"
        }
    }

    @ViewBuilder
    var previewView: some View {
        switch self {
        case .flamePulse: FlamePulseAnimation()
        case .aurora: AuroraAnimation()
        case .starfield: StarfieldAnimation()
        case .breathingOrb: BreathingOrbAnimation()
        case .flurry: FlurryAnimation()
        case .flurryClassic: FlurryClassicAnimation()
        }
    }
}

// MARK: - Dream Mode Manager

@MainActor
@Observable
final class DreamModeManager {
    private static let logger = Logger(
        subsystem: "ai.openclaw.ios", category: "DreamMode")

    private(set) var state: DreamState = .awake
    var enabled: Bool = false
    var idleThresholdSeconds: TimeInterval = 600
    var selectedAnimation: DreamAnimation = .flamePulse
    private(set) var currentTaskLabel: String?

    /// Current dream run UUID (non-nil while dreaming).
    private(set) var runId: String?

    /// Root directory for dream artifacts (relative to workspace).
    let outputRoot: String = "dream"

    /// Pending digest path ready for delivery, set by
    /// `evaluateDigestDelivery`.
    private(set) var pendingDigestPath: String?

    /// Backing store for `dream/state.json`. Set after workspace root
    /// is known (via `configureDeviceServices`).
    var dreamStateStore: DreamStateStore?

    /// Called after dream enters — the runtime sets this to send a
    /// chat.send to the LLM with the dream prompt.
    var onDreamEntered: ((String) -> Void)?

    /// Called after dream exits (wake) — the runtime sets this to
    /// deliver the digest to the main chat session.
    var onDreamExited: (() -> Void)?

    // MARK: - State Transitions

    func enterDream() {
        guard self.state == .awake else {
            Self.logger.debug("enterDream ignored: state=\(self.state.rawValue)")
            return
        }
        let newRunId = UUID().uuidString.lowercased()
        Self.logger.info("entering dream runId=\(newRunId)")
        self.runId = newRunId
        self.state = .dreaming

        self.dreamStateStore?.update { state in
            state.lastRunId = newRunId
            state.lastRunAt = ISO8601DateFormatter()
                .string(from: Date())
            state.pendingDigestPath = "dream/digest.md"
        }

        Self.logger.info("firing onDreamEntered callback runId=\(newRunId)")
        self.onDreamEntered?(newRunId)
    }

    func wake() {
        guard self.state == .dreaming else {
            Self.logger.debug("wake ignored: state=\(self.state.rawValue)")
            return
        }
        Self.logger.info("waking from dream runId=\(self.runId ?? "nil")")
        self.state = .waking
        self.currentTaskLabel = nil
        self.runId = nil
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(600))
            self.state = .awake
            Self.logger.info("firing onDreamExited callback")
            self.onDreamExited?()
        }
    }

    func setTaskLabel(_ label: String?) {
        self.currentTaskLabel = label
    }

    // MARK: - Auto-Trigger

    func evaluateAutoTrigger(idleTracker: UserIdleTracker) {
        let idle = idleTracker.idleSeconds
        guard self.enabled, self.state == .awake else {
            Self.logger.debug(
                "dream auto-trigger skip: enabled=\(self.enabled) state=\(self.state.rawValue)")
            return
        }
        guard idle >= self.idleThresholdSeconds else {
            Self.logger.debug(
                "dream auto-trigger: idle \(Int(idle))s < threshold \(Int(self.idleThresholdSeconds))s")
            return
        }

        // Allow re-triggering whenever idle threshold has elapsed since
        // the last dream started. This means dream repeats every
        // ~idleThresholdSeconds during continuous idle.
        if let store = self.dreamStateStore {
            let state = store.load()
            if let lastRunISO = state.lastRunAt,
               let lastRunDate = ISO8601DateFormatter().date(from: lastRunISO)
            {
                let sinceLast = Date().timeIntervalSince(lastRunDate)
                if sinceLast < self.idleThresholdSeconds {
                    Self.logger.debug(
                        "dream auto-trigger skip: last dream \(Int(sinceLast))s ago < threshold \(Int(self.idleThresholdSeconds))s")
                    return
                }
            }
        } else {
            Self.logger.warning(
                "dream auto-trigger: dreamStateStore is nil — cannot check timing")
        }

        Self.logger.info(
            "dream auto-trigger: entering dream (idle \(Int(idle))s >= threshold \(Int(self.idleThresholdSeconds))s)")
        self.enterDream()

        // Record interaction epoch (still used for digest delivery tracking)
        self.dreamStateStore?.update { state in
            state.lastDreamForInteraction = Self.epochKey(
                for: idleTracker.lastInteractionAt)
        }
    }

    // MARK: - Digest Delivery

    /// Called periodically (e.g. every 30s from RootCanvas).
    /// Sets `pendingDigestPath` when a dream digest is ready for delivery.
    /// Delivers on the next evaluation cycle after dream exits — no idle
    /// time constraint so the digest is sent even if the user hasn't
    /// returned yet.
    func evaluateDigestDelivery(idleTracker: UserIdleTracker) {
        guard self.state == .awake else { return }
        guard let store = self.dreamStateStore else { return }

        let state = store.load()
        guard let pending = state.pendingDigestPath,
              let lastDream = state.lastDreamForInteraction,
              state.deliveredForInteraction != lastDream
        else {
            self.pendingDigestPath = nil
            return
        }

        self.pendingDigestPath = pending
    }

    /// Mark the current digest as delivered so it is not re-sent.
    func markDigestDelivered() {
        self.pendingDigestPath = nil
        self.dreamStateStore?.update { state in
            state.deliveredForInteraction =
                state.lastDreamForInteraction
            state.pendingDigestPath = nil
        }
    }

    // MARK: - Helpers

    static func epochKey(for date: Date) -> String {
        String(Int(date.timeIntervalSince1970))
    }
}
