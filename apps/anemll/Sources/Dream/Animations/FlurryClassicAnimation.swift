import SwiftUI

// MARK: - Flurry Classic (wide glowing ribbons through a bright nexus)

struct FlurryClassicAnimation: View {
    @State private var ribbons = ClassicRibbonBank()

    var body: some View {
        TimelineView(
            .periodic(from: .now, by: 1.0 / 30.0))
        { timeline in
            Canvas(rendersAsynchronously: true) {
                context, size in
                let now = timeline.date
                    .timeIntervalSinceReferenceDate
                self.ribbons.draw(
                    in: &context,
                    size: size,
                    time: now)
            }
        }
    }
}

// MARK: - Ribbon bank

private struct ClassicRibbonBank {
    let ribbons: [ClassicRibbon]

    init() {
        // 4 ribbons with distinct base hues
        // matching the reference: magenta, red/orange,
        // green/teal, gold/yellow
        let hues: [Double] = [
            0.85, // magenta-pink
            0.02, // red-orange
            0.40, // green-teal
            0.12, // gold-yellow
        ]
        self.ribbons = hues.enumerated().map { i, h in
            ClassicRibbon(
                index: i, total: hues.count, baseHue: h)
        }
    }

    func draw(
        in context: inout GraphicsContext,
        size: CGSize,
        time: Double)
    {
        // Draw all ribbons
        for ribbon in self.ribbons {
            ribbon.draw(
                in: &context,
                size: size,
                time: time)
        }

        // Bright nexus glow at center
        self.drawNexus(
            in: &context, size: size, time: time)
    }

    private func drawNexus(
        in context: inout GraphicsContext,
        size: CGSize,
        time: Double)
    {
        let cx = size.width * 0.5
        let cy = size.height * 0.5

        // Outer glow
        let outerR = 40.0
        let outerRect = CGRect(
            x: cx - outerR, y: cy - outerR,
            width: outerR * 2, height: outerR * 2)
        context.opacity = 0.15
        context.fill(
            Circle().path(in: outerRect),
            with: .radialGradient(
                Gradient(colors: [
                    .white,
                    Color.white.opacity(0),
                ]),
                center: CGPoint(x: cx, y: cy),
                startRadius: 0,
                endRadius: outerR))

        // Inner bright core
        let innerR = 12.0
        let innerRect = CGRect(
            x: cx - innerR, y: cy - innerR,
            width: innerR * 2, height: innerR * 2)
        let pulse = 0.5
            + 0.5 * sin(time * 1.2)
        context.opacity = 0.4 + pulse * 0.3
        context.fill(
            Circle().path(in: innerRect),
            with: .radialGradient(
                Gradient(colors: [
                    .white,
                    Color(
                        hue: 0.85,
                        saturation: 0.3,
                        brightness: 1.0)
                        .opacity(0.5),
                    Color.clear,
                ]),
                center: CGPoint(x: cx, y: cy),
                startRadius: 0,
                endRadius: innerR))
    }
}

// MARK: - Single ribbon

private struct ClassicRibbon {
    let baseHue: Double
    let hueSpeed: Double

    // Lissajous orbit (ribbon sweeps through center)
    let freqA: Double
    let freqB: Double
    let phaseA: Double
    let phaseB: Double
    let ampA: Double
    let ampB: Double

    // Secondary wobble
    let freqC: Double
    let freqD: Double
    let phaseC: Double
    let phaseD: Double

    init(index: Int, total: Int, baseHue: Double) {
        self.baseHue = baseHue
        let seed = Double(index) * 1.618033988

        // Frequencies chosen so ribbons pass through
        // center periodically (Lissajous ratios ~2:3)
        self.freqA = 0.08 + 0.03 * sin(seed * 3.7)
        self.freqB = 0.12 + 0.04 * cos(seed * 2.1)
        self.phaseA = seed * 2.3
        self.phaseB = seed * 3.9 + .pi * 0.3

        // Amplitude: ribbons span most of the screen
        self.ampA = 0.38 + 0.06 * sin(seed * 5.1)
        self.ampB = 0.32 + 0.05 * cos(seed * 4.7)

        // Secondary detail
        self.freqC = 0.23 + 0.08 * cos(seed * 6.3)
        self.freqD = 0.19 + 0.06 * sin(seed * 7.1)
        self.phaseC = seed * 1.7
        self.phaseD = seed * 4.1

        self.hueSpeed = 0.008 + 0.004 * sin(seed * 2.9)
    }

    private func ribbonPos(
        at t: Double) -> (x: Double, y: Double)
    {
        let x = 0.5
            + self.ampA * sin(
                t * self.freqA + self.phaseA)
            + 0.06 * sin(
                t * self.freqC + self.phaseC)
        let y = 0.5
            + self.ampB * sin(
                t * self.freqB + self.phaseB)
            + 0.05 * sin(
                t * self.freqD + self.phaseD)
        return (x, y)
    }

    func draw(
        in context: inout GraphicsContext,
        size: CGSize,
        time: Double)
    {
        let w = size.width
        let h = size.height
        let segments = 80
        let trailDuration = 4.0

        // Build the ribbon path by sampling backwards
        var path = Path()
        var first = true

        for i in 0...segments {
            let frac = Double(i) / Double(segments)
            let sampleTime = time - frac * trailDuration
            let pos = self.ribbonPos(at: sampleTime)
            let pt = CGPoint(
                x: pos.x * w, y: pos.y * h)

            if first {
                path.move(to: pt)
                first = false
            } else {
                path.addLine(to: pt)
            }
        }

        // Draw multiple passes at different widths
        // to simulate soft gaussian glow
        let layers: [(width: Double, alpha: Double)] = [
            (60.0, 0.03), // outermost soft glow
            (40.0, 0.05),
            (24.0, 0.08),
            (14.0, 0.12),
            (8.0, 0.18), // inner bright core
            (4.0, 0.25), // brightest center line
        ]

        let hue = (self.baseHue + time * self.hueSpeed)
            .truncatingRemainder(dividingBy: 1.0)
        let safeHue = hue < 0 ? hue + 1.0 : hue

        for layer in layers {
            let sat = layer.width > 20
                ? 0.6 : 0.85
            let bri = layer.width > 20
                ? 0.7 : 1.0
            let color = Color(
                hue: safeHue,
                saturation: sat,
                brightness: bri)

            context.opacity = layer.alpha
            context.stroke(
                path,
                with: .color(color),
                style: StrokeStyle(
                    lineWidth: layer.width,
                    lineCap: .round,
                    lineJoin: .round))
        }

        // Fade the tail: overdraw black over the
        // last portion to create fade-out
        self.drawTailFade(
            in: &context,
            size: size,
            time: time,
            segments: segments,
            trailDuration: trailDuration)
    }

    private func drawTailFade(
        in context: inout GraphicsContext,
        size: CGSize,
        time: Double,
        segments: Int,
        trailDuration: Double)
    {
        let w = size.width
        let h = size.height
        let fadeStart = 0.5 // start fading at 50%
        let fadeSegments = Int(
            Double(segments) * (1.0 - fadeStart))

        for i in 0..<fadeSegments {
            let baseFrac = fadeStart
                + Double(i) / Double(segments)
            let nextFrac = fadeStart
                + Double(i + 1) / Double(segments)

            let t0 = time - baseFrac * trailDuration
            let t1 = time - nextFrac * trailDuration
            let p0 = self.ribbonPos(at: t0)
            let p1 = self.ribbonPos(at: t1)

            var seg = Path()
            seg.move(to: CGPoint(
                x: p0.x * w, y: p0.y * h))
            seg.addLine(to: CGPoint(
                x: p1.x * w, y: p1.y * h))

            // Fade from transparent to opaque black
            let fadeProgress = (baseFrac - fadeStart)
                / (1.0 - fadeStart)
            let blackAlpha = fadeProgress * fadeProgress

            context.opacity = blackAlpha
            context.stroke(
                seg,
                with: .color(.black),
                style: StrokeStyle(
                    lineWidth: 65.0,
                    lineCap: .round,
                    lineJoin: .round))
        }
    }
}
