import SwiftUI

struct AuroraAnimation: View {
    @State private var phase: CGFloat = 0

    var body: some View {
        ZStack {
            // Layer 1 — deep blue/purple base
            LinearGradient(
                colors: [
                    Color(red: 0.05, green: 0.02, blue: 0.20),
                    Color(red: 0.0, green: 0.10, blue: 0.30),
                    Color(red: 0.02, green: 0.05, blue: 0.15),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing)
                .ignoresSafeArea()

            // Layer 2 — green/teal aurora band
            Ellipse()
                .fill(
                    LinearGradient(
                        colors: [
                            Color.clear,
                            Color(red: 0.0, green: 0.8, blue: 0.5).opacity(0.20),
                            Color(red: 0.0, green: 0.6, blue: 0.7).opacity(0.15),
                            Color.clear,
                        ],
                        startPoint: .leading,
                        endPoint: .trailing))
                .frame(width: 600, height: 200)
                .rotationEffect(.degrees(Double(self.phase) * 12 - 15))
                .offset(y: -80 + sin(Double(self.phase) * .pi * 2) * 30)
                .blur(radius: 30)
                .animation(
                    .linear(duration: 10)
                        .repeatForever(autoreverses: true),
                    value: self.phase)

            // Layer 3 — pink/magenta aurora accent
            Ellipse()
                .fill(
                    LinearGradient(
                        colors: [
                            Color.clear,
                            Color(red: 0.6, green: 0.1, blue: 0.5).opacity(0.14),
                            Color(red: 0.8, green: 0.2, blue: 0.6).opacity(0.10),
                            Color.clear,
                        ],
                        startPoint: .leading,
                        endPoint: .trailing))
                .frame(width: 500, height: 160)
                .rotationEffect(.degrees(Double(self.phase) * -8 + 10))
                .offset(y: -40 + cos(Double(self.phase) * .pi * 2) * 25)
                .blur(radius: 25)
                .animation(
                    .linear(duration: 14)
                        .repeatForever(autoreverses: true)
                        .delay(1.5),
                    value: self.phase)

            // Layer 4 — faint cyan shimmer
            Ellipse()
                .fill(
                    Color(red: 0.0, green: 0.9, blue: 1.0).opacity(0.08))
                .frame(width: 400, height: 120)
                .rotationEffect(.degrees(Double(self.phase) * 6))
                .offset(y: -120 + sin(Double(self.phase) * .pi * 1.5) * 20)
                .blur(radius: 35)
                .animation(
                    .linear(duration: 18)
                        .repeatForever(autoreverses: true)
                        .delay(3),
                    value: self.phase)
        }
        .onAppear { self.phase = 1 }
    }
}
