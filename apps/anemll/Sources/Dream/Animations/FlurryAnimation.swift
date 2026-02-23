import SwiftUI

// MARK: - Flurry Animation (inspired by Apple's Flurry screensaver)

struct FlurryAnimation: View {
    @State private var seeds = FlurrySeedBank()

    var body: some View {
        TimelineView(
            .periodic(from: .now, by: 1.0 / 24.0))
        { timeline in
            Canvas { context, size in
                let now = timeline.date
                    .timeIntervalSinceReferenceDate
                self.seeds.draw(
                    in: &context,
                    size: size,
                    time: now)
            }
        }
    }
}

// MARK: - Seed bank (immutable after init)

private struct FlurrySeedBank {
    let streams: [FlurryStream]

    static let streamCount = 3
    static let particlesPerStream = 120

    init() {
        self.streams = (0..<Self.streamCount).map { i in
            FlurryStream(
                baseHue: Double(i)
                    / Double(Self.streamCount),
                seeds: (0..<Self.particlesPerStream)
                    .map { _ in FlurryParticleSeed() })
        }
    }

    func draw(
        in context: inout GraphicsContext,
        size: CGSize,
        time: Double)
    {
        let w = Double(size.width)
        let h = Double(size.height)

        for stream in self.streams {
            stream.draw(
                in: &context,
                w: w, h: h,
                time: time)
        }
    }
}

// MARK: - Stream (one emitter path + its particles)

private struct FlurryStream {
    let baseHue: Double
    let seeds: [FlurryParticleSeed]

    // Emitter orbit parameters (deterministic from baseHue)
    let orbitRadiusX: Double
    let orbitRadiusY: Double
    let orbitSpeedX: Double
    let orbitSpeedY: Double
    let phaseX: Double
    let phaseY: Double
    let hueSpeed: Double

    init(
        baseHue: Double,
        seeds: [FlurryParticleSeed])
    {
        self.baseHue = baseHue
        self.seeds = seeds

        // Use baseHue to deterministically vary orbits
        let h = baseHue * .pi * 2
        self.orbitRadiusX = 0.18 + 0.08 * cos(h * 3.7)
        self.orbitRadiusY = 0.15 + 0.06 * sin(h * 2.3)
        self.orbitSpeedX = 0.12 + 0.06 * sin(h * 5.1)
        self.orbitSpeedY = 0.10 + 0.05 * cos(h * 4.3)
        self.phaseX = h
        self.phaseY = h + .pi * 0.7
        self.hueSpeed = 0.03 + 0.01 * sin(h)
    }

    func emitterPosition(at time: Double)
        -> (x: Double, y: Double)
    {
        let ex = 0.5 + self.orbitRadiusX
            * sin(time * self.orbitSpeedX + self.phaseX)
        let ey = 0.5 + self.orbitRadiusY
            * cos(time * self.orbitSpeedY + self.phaseY)
        return (ex, ey)
    }

    func currentHue(at time: Double) -> Double {
        (self.baseHue + time * self.hueSpeed)
            .truncatingRemainder(dividingBy: 1.0)
    }

    func draw(
        in context: inout GraphicsContext,
        w: Double,
        h: Double,
        time: Double)
    {
        let cycleDuration = 4.0
        let count = Double(self.seeds.count)

        for (i, seed) in self.seeds.enumerated() {
            let stagger = Double(i) / count
                * cycleDuration
            let particleTime = (time + stagger)
                .truncatingRemainder(
                    dividingBy: cycleDuration)
            let progress = particleTime / cycleDuration

            let birthTime = time - particleTime
            let emPos = self.emitterPosition(
                at: birthTime)

            let angle = seed.angle
            let speed = seed.speed
            let drift = particleTime * speed

            let px = (emPos.x + cos(angle) * drift) * w
            let py = (emPos.y + sin(angle) * drift) * h

            let fadeIn = min(progress / 0.08, 1.0)
            let fadeOut = 1.0 - smoothstep(
                progress, edge0: 0.4, edge1: 1.0)
            let alpha = fadeIn * fadeOut * seed.brightness
                * 0.55

            guard alpha > 0.005 else { continue }

            let radius = (6.0 + progress * 18.0)
                * seed.sizeScale

            let hue = self.currentHue(at: birthTime)
                + seed.hueOffset
            let adjustedHue = hue.truncatingRemainder(
                dividingBy: 1.0)
            let safeHue = adjustedHue < 0
                ? adjustedHue + 1.0 : adjustedHue
            let saturation = 0.75
                + (1.0 - progress) * 0.25
            let brightness = 0.5
                + (1.0 - progress) * 0.5

            let color = Color(
                hue: safeHue,
                saturation: saturation,
                brightness: brightness)

            let rect = CGRect(
                x: px - radius,
                y: py - radius,
                width: radius * 2,
                height: radius * 2)

            context.opacity = alpha
            context.fill(
                Ellipse().path(in: rect),
                with: .color(color))
        }
    }
}

// MARK: - Particle seed (random but immutable)

private struct FlurryParticleSeed {
    let angle: Double
    let speed: Double
    let hueOffset: Double
    let brightness: Double
    let sizeScale: Double

    init() {
        self.angle = Double.random(
            in: 0 ... .pi * 2)
        self.speed = Double.random(
            in: 0.03...0.12)
        self.hueOffset = Double.random(
            in: -0.06...0.06)
        self.brightness = Double.random(
            in: 0.4...1.0)
        self.sizeScale = Double.random(
            in: 0.6...1.4)
    }
}

// MARK: - Helpers

private func smoothstep(
    _ x: Double,
    edge0: Double,
    edge1: Double)
    -> Double
{
    let t = max(0, min(1, (x - edge0) / (edge1 - edge0)))
    return t * t * (3 - 2 * t)
}
