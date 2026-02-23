import Foundation
import Observation

@MainActor
@Observable
final class UserIdleTracker {
    private(set) var lastInteractionAt = Date()

    var idleSeconds: TimeInterval {
        Date().timeIntervalSince(self.lastInteractionAt)
    }

    func recordInteraction() {
        self.lastInteractionAt = Date()
    }
}
