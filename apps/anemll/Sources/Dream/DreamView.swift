import SwiftUI

struct DreamView: View {
    @Environment(DreamModeManager.self) private var dreamManager

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            self.dreamManager.selectedAnimation.previewView

            DreamStatusPill()
        }
        .contentShape(Rectangle())
        .onTapGesture {
            self.dreamManager.wake()
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Dream Mode active. Tap to wake.")
        .accessibilityAddTraits(.isButton)
    }
}
