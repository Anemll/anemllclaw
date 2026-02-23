import SwiftUI

struct BreathingOrbAnimation: View {
    @State private var pulse: Bool = false

    var body: some View {
        ZStack {
            // Outer ring — slow expansion
            Circle()
                .stroke(Color.cyan.opacity(0.18), lineWidth: 2)
                .frame(width: 300, height: 300)
                .scaleEffect(self.pulse ? 1.30 : 0.98)
                .opacity(self.pulse ? 0.0 : 0.8)
                .animation(
                    .easeOut(duration: 2.2)
                        .repeatForever(autoreverses: false),
                    value: self.pulse)

            // Second ring — staggered
            Circle()
                .stroke(Color.cyan.opacity(0.12), lineWidth: 2)
                .frame(width: 300, height: 300)
                .scaleEffect(self.pulse ? 1.50 : 1.02)
                .opacity(self.pulse ? 0.0 : 0.6)
                .animation(
                    .easeOut(duration: 2.8)
                        .repeatForever(autoreverses: false)
                        .delay(0.3),
                    value: self.pulse)

            // Core orb — breathes in/out
            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            Color.cyan.opacity(0.60),
                            Color(red: 0.2, green: 0.5, blue: 0.8).opacity(0.35),
                            Color.black.opacity(0.50),
                        ],
                        center: .center,
                        startRadius: 1,
                        endRadius: 100))
                .frame(width: 180, height: 180)
                .scaleEffect(self.pulse ? 1.15 : 0.85)
                .animation(
                    .easeInOut(duration: 4.0)
                        .repeatForever(autoreverses: true),
                    value: self.pulse)
                .shadow(
                    color: Color.cyan.opacity(0.30),
                    radius: 30)
                .overlay(
                    Circle()
                        .stroke(Color.cyan.opacity(0.25), lineWidth: 1)
                        .frame(width: 180, height: 180)
                        .scaleEffect(self.pulse ? 1.15 : 0.85)
                        .animation(
                            .easeInOut(duration: 4.0)
                                .repeatForever(autoreverses: true),
                            value: self.pulse))
        }
        .onAppear { self.pulse = true }
    }
}
