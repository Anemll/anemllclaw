import SwiftUI

struct DreamStatusPill: View {
    @Environment(DreamModeManager.self) private var dreamManager

    var body: some View {
        VStack {
            Spacer()
            HStack(spacing: 6) {
                Image(systemName: "moon.zzz.fill")
                    .font(.caption2)
                Text(self.label)
                    .font(.system(.caption, design: .rounded).weight(.semibold))
            }
            .foregroundStyle(Color.white.opacity(0.70))
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(
                Capsule()
                    .fill(.ultraThinMaterial)
                    .overlay(
                        Capsule()
                            .stroke(Color.white.opacity(0.10), lineWidth: 1)))
            .padding(.bottom, 40)
        }
    }

    private var label: String {
        if let task = self.dreamManager.currentTaskLabel, !task.isEmpty {
            return task
        }
        return "Dreaming\u{2026}"
    }
}
