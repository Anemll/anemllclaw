import Foundation
import Observation
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

    // MARK: - State Transitions

    func enterDream() {
        guard self.state == .awake else { return }
        let newRunId = UUID().uuidString.lowercased()
        self.runId = newRunId
        self.state = .dreaming

        self.dreamStateStore?.update { state in
            state.lastRunId = newRunId
            state.lastRunAt = ISO8601DateFormatter()
                .string(from: Date())
            state.pendingDigestPath = "dream/digest.md"
        }
    }

    func wake() {
        guard self.state == .dreaming else { return }
        self.state = .waking
        self.currentTaskLabel = nil
        self.runId = nil
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(600))
            self.state = .awake
        }
    }

    func setTaskLabel(_ label: String?) {
        self.currentTaskLabel = label
    }

    // MARK: - Auto-Trigger with Cooldown

    func evaluateAutoTrigger(idleTracker: UserIdleTracker) {
        guard self.enabled, self.state == .awake else { return }
        guard idleTracker.idleSeconds >= self.idleThresholdSeconds
        else { return }

        if let store = self.dreamStateStore {
            let state = store.load()

            // Cooldown: do not re-enter if still within cooldown window
            if let cooldownStr = state.cooldownUntil {
                let formatter = ISO8601DateFormatter()
                if let cooldownDate = formatter.date(
                    from: cooldownStr),
                    Date() < cooldownDate
                {
                    return
                }
            }

            // Already dreamed for this interaction epoch
            let key = Self.epochKey(
                for: idleTracker.lastInteractionAt)
            if state.lastDreamForInteraction == key {
                return
            }
        }

        self.enterDream()

        // Record interaction epoch + set 4-hour cooldown
        self.dreamStateStore?.update { state in
            state.lastDreamForInteraction = Self.epochKey(
                for: idleTracker.lastInteractionAt)
            state.cooldownUntil = ISO8601DateFormatter()
                .string(
                    from: Date()
                        .addingTimeInterval(4 * 3600))
        }
    }

    // MARK: - Digest Delivery

    /// Called periodically (e.g. every 30s from RootCanvas).
    /// Sets `pendingDigestPath` when the user has returned from idle
    /// and a dream digest is ready for delivery via the next heartbeat.
    func evaluateDigestDelivery(idleTracker: UserIdleTracker) {
        guard self.state == .awake else { return }
        guard let store = self.dreamStateStore else { return }

        // Only deliver if user recently returned (idle < 5 min)
        guard idleTracker.idleSeconds < 300 else {
            self.pendingDigestPath = nil
            return
        }

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
