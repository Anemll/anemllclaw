import SwiftUI

struct StarfieldAnimation: View {
    private static let starCount = 80

    @State private var stars: [Star] = Self.generateStars()

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1.0 / 15.0)) { timeline in
            Canvas { context, size in
                let now = timeline.date.timeIntervalSinceReferenceDate
                for star in self.stars {
                    let x = (star.x + CGFloat(now) * star.speed * 8)
                        .truncatingRemainder(dividingBy: size.width)
                    let adjustedX = x < 0 ? x + size.width : x
                    let y = star.y * size.height

                    let twinkle = 0.4 + 0.6
                        * abs(sin(now * star.twinkleRate + star.twinkleOffset))
                    let radius = star.radius * CGFloat(twinkle)

                    let rect = CGRect(
                        x: adjustedX - radius,
                        y: y - radius,
                        width: radius * 2,
                        height: radius * 2)

                    context.opacity = star.brightness * twinkle
                    context.fill(
                        Circle().path(in: rect),
                        with: .color(.white))
                }
            }
        }
    }

    private static func generateStars() -> [Star] {
        (0..<self.starCount).map { _ in
            Star(
                x: CGFloat.random(in: 0...500),
                y: CGFloat.random(in: 0...1),
                radius: CGFloat.random(in: 0.5...2.5),
                brightness: Double.random(in: 0.3...1.0),
                speed: CGFloat.random(in: 0.3...2.0),
                twinkleRate: Double.random(in: 0.5...2.5),
                twinkleOffset: Double.random(in: 0 ... .pi * 2))
        }
    }
}

private struct Star {
    let x: CGFloat
    let y: CGFloat
    let radius: CGFloat
    let brightness: Double
    let speed: CGFloat
    let twinkleRate: Double
    let twinkleOffset: Double
}
