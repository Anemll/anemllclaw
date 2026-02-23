import SwiftUI

struct FlamePulseAnimation: View {
    @State private var pulse: Bool = false

    var body: some View {
        ZStack {
            // Outer glow ring — slow fade-out expansion
            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            Color.orange.opacity(0.10),
                            Color.clear,
                        ],
                        center: .center,
                        startRadius: 80,
                        endRadius: 260))
                .scaleEffect(self.pulse ? 1.35 : 0.90)
                .opacity(self.pulse ? 0.0 : 0.7)
                .animation(
                    .easeOut(duration: 3.0)
                        .repeatForever(autoreverses: false),
                    value: self.pulse)

            // Middle ring — warm amber pulse
            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            Color(red: 1.0, green: 0.6, blue: 0.1).opacity(0.18),
                            Color.clear,
                        ],
                        center: .center,
                        startRadius: 40,
                        endRadius: 180))
                .scaleEffect(self.pulse ? 1.25 : 0.95)
                .opacity(self.pulse ? 0.0 : 0.8)
                .animation(
                    .easeOut(duration: 2.4)
                        .repeatForever(autoreverses: false)
                        .delay(0.4),
                    value: self.pulse)

            // Core — bright warm center
            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            Color.orange.opacity(0.55),
                            Color(red: 1.0, green: 0.4, blue: 0.05).opacity(0.30),
                            Color.clear,
                        ],
                        center: .center,
                        startRadius: 2,
                        endRadius: 100))
                .frame(width: 160, height: 160)
                .scaleEffect(self.pulse ? 1.10 : 0.92)
                .animation(
                    .easeInOut(duration: 4.0)
                        .repeatForever(autoreverses: true),
                    value: self.pulse)
                .shadow(
                    color: Color.orange.opacity(0.25),
                    radius: 40)

            // Inner ember glow — breathes in opposition
            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            Color(red: 1.0, green: 0.3, blue: 0.0).opacity(0.40),
                            Color.clear,
                        ],
                        center: .center,
                        startRadius: 1,
                        endRadius: 50))
                .frame(width: 70, height: 70)
                .scaleEffect(self.pulse ? 0.85 : 1.12)
                .animation(
                    .easeInOut(duration: 3.2)
                        .repeatForever(autoreverses: true)
                        .delay(0.6),
                    value: self.pulse)
        }
        .onAppear { self.pulse = true }
    }
}
