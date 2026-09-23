import SwiftUI

/// The phone's interpretation of the wall's eleven WMO scenes. All artwork is
/// procedural: no network images, repeated video loops, or per-frame random state.
struct WeatherMood {
    let code: Int?
    let day: Bool
    var golden = false

    var wet: Bool { [51, 53, 55, 56, 57, 61, 63, 65, 66, 67, 80, 81, 82, 95, 96, 99].contains(code ?? -1) }
    var snow: Bool { [71, 73, 75, 77, 85, 86].contains(code ?? -1) }
    var fog: Bool { [45, 48].contains(code ?? -1) }
    var storm: Bool { [95, 96, 99].contains(code ?? -1) }
    var clear: Bool { code == 0 || code == 1 }
    var accent: Color { Color(hex: snow ? 0xC6DDE5 : wet ? 0xA7CED4 : day ? 0xF0C384 : 0xB7C8EA) }
    var top: Color { Color(hex: !day ? 0x0C1526 : storm ? 0x222B37 : wet ? 0x263D48 : snow ? 0x445C69 : golden ? 0x344A53 : 0x264D63) }
    var horizon: Color { Color(hex: !day ? 0x3C5265 : wet ? 0x779498 : snow ? 0xBBCBCC : fog ? 0xABB6AF : golden ? 0xEAB17F : 0xA9C6BD) }
    var words: String {
        switch code {
        case 0: day ? "Clear sky" : "Clear night"
        case 1: "Mostly clear"
        case 2: "Partly cloudy"
        case 3: "Overcast"
        case 45, 48: "Fog"
        case 51, 53, 55: "Drizzle"
        case 56, 57, 66, 67: "Freezing rain"
        case 61, 63, 65: "Rain"
        case 71, 73, 75, 77, 85, 86: "Snow"
        case 80, 81, 82: "Showers"
        case 95, 96, 99: "Thunderstorms"
        default: "Conditions unavailable"
        }
    }
    var symbol: String {
        switch code {
        case 0: day ? "sun.max.fill" : "moon.stars.fill"
        case 1, 2: day ? "cloud.sun.fill" : "cloud.moon.fill"
        case 3: "cloud.fill"
        case 45, 48: "cloud.fog.fill"
        case 51, 53, 55: "cloud.drizzle.fill"
        case 56, 57, 66, 67: "cloud.sleet.fill"
        case 61, 63, 65: "cloud.rain.fill"
        case 71, 73, 75, 77, 85, 86: "cloud.snow.fill"
        case 80, 81, 82: "cloud.heavyrain.fill"
        case 95, 96, 99: "cloud.bolt.rain.fill"
        default: "cloud.fill"
        }
    }
}

struct WeatherAtmosphere: View {
    let mood: WeatherMood
    var wind: Double = 8
    var date: Date = .now
    @Environment(\.accessibilityReduceMotion) private var reduced
    @Environment(\.scenePhase) private var phase

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 20, paused: reduced || phase != .active)) { timeline in
            Canvas { ctx, size in
                let t = reduced ? 0 : timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 86400)
                draw(in: &ctx, size: size, time: t)
            }
        }
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }

    private func draw(in ctx: inout GraphicsContext, size: CGSize, time: Double) {
        let w = size.width, h = size.height
        let bounds = Path(CGRect(origin: .zero, size: size))
        ctx.fill(bounds, with: .linearGradient(Gradient(stops: [
            .init(color: mood.top, location: 0),
            .init(color: mood.horizon, location: 0.65),
            .init(color: mood.top, location: 1)
        ]), startPoint: .zero, endPoint: CGPoint(x: 0, y: h)))

        // A luminous horizon, with the brightest point away from the typography.
        let light = CGPoint(x: w * 0.77, y: h * 0.46)
        ctx.fill(bounds, with: .radialGradient(Gradient(colors: [mood.accent.opacity(mood.day ? 0.32 : 0.1), .clear]), center: light, startRadius: 0, endRadius: w * 0.85))
        if !mood.day && [0, 1, 2].contains(mood.code ?? -1) {
            for i in 0..<65 {
                let x = noise(i * 7) * w, y = noise(i * 11 + 4) * h * 0.6
                let r = i % 7 == 0 ? 1.2 : 0.65
                let alpha = 0.3 + 0.35 * (0.5 + 0.5 * sin(time * 0.45 + Double(i)))
                ctx.fill(Path(ellipseIn: CGRect(x: x, y: y, width: r * 2, height: r * 2)), with: .color(Color(hex: 0xE7E9E0).opacity(alpha)))
            }
        }
        if !mood.wet && !mood.snow && mood.code != 3 {
            let r = w * (mood.day ? 0.077 : 0.058)
            ctx.fill(bounds, with: .radialGradient(Gradient(colors: [mood.accent.opacity(0.4), mood.accent.opacity(0.08), .clear]), center: light, startRadius: r, endRadius: r * 5))
            let orb = Path(ellipseIn: CGRect(x: light.x - r, y: light.y - r, width: r * 2, height: r * 2))
            ctx.fill(orb, with: .radialGradient(Gradient(colors: [Color(hex: 0xFFF2D4), mood.accent]), center: CGPoint(x: light.x - r * 0.2, y: light.y - r * 0.3), startRadius: 0, endRadius: r * 1.6))
            if !mood.day {
                // The same lunar epoch as the matrix renderer; terminator follows phase.
                let phase = (date.timeIntervalSince1970 - 947182440).truncatingRemainder(dividingBy: 2551442.88) / 2551442.88
                let cosPhase = cos(phase * .pi * 2)
                ctx.drawLayer { moon in
                    moon.clip(to: orb)
                    for row in stride(from: -r, through: r, by: 0.25) {
                        let half = sqrt(max(0, r * r - row * row))
                        let edge = half * cosPhase
                        let start = phase < 0.5 ? -half : -edge
                        let width = half + edge
                        moon.fill(Path(CGRect(x: light.x + start, y: light.y + row, width: max(0, width), height: 0.35)), with: .color(mood.top.opacity(0.92)))
                    }
                    for i in 0..<12 {
                        let radius = r * (0.07 + noise(i + 55) * 0.12)
                        moon.fill(Path(ellipseIn: CGRect(x: light.x + (noise(i * 3) - 0.5) * r * 1.5, y: light.y + (noise(i * 9) - 0.5) * r * 1.4, width: radius * 2, height: radius * 2)), with: .color(mood.top.opacity(0.13)))
                    }
                }
            }
        }

        // Long, softly scalloped cloud banks. Light comes from the same sun.
        let count = mood.clear ? (mood.code == 0 ? 2 : 3) : 7
        for bank in 0..<count {
            let drift = time * (0.002 + min(wind, 60) * 0.00007) * (bank % 2 == 0 ? 1 : -0.6)
            let cx = ((noise(bank + 40) + drift).truncatingRemainder(dividingBy: 1.7) + 1.7).truncatingRemainder(dividingBy: 1.7) * w - w * 0.35
            let cy = h * (0.21 + noise(bank + 90) * 0.34)
            let spread = w * (mood.clear ? 0.42 : 0.65)
            ctx.drawLayer { cloud in
                cloud.addFilter(.blur(radius: mood.fog ? 17 : 7))
                cloud.opacity = mood.clear ? 0.24 : mood.day ? 0.65 : 0.5
                for puff in 0..<16 {
                    let u = Double(puff) / 15
                    let height = h * (0.025 + noise(bank * 30 + puff) * 0.055) * sin(.pi * (0.08 + u * 0.84))
                    let rect = CGRect(x: cx + (u - 0.5) * spread, y: cy - height * 0.6, width: spread * 0.3, height: height)
                    cloud.fill(Path(ellipseIn: rect), with: .linearGradient(Gradient(colors: [mood.day ? Color(hex: 0xE3D7BF) : Color(hex: 0x8095AD), mood.top.opacity(0.9)]), startPoint: CGPoint(x: 0, y: rect.minY), endPoint: CGPoint(x: 0, y: rect.maxY)))
                }
            }
        }

        // Four ridgelines give the scene depth, down to a dark foreground.
        for layer in 0..<4 {
            var ridge = Path()
            let base = h * (0.64 + Double(layer) * 0.075)
            ridge.move(to: CGPoint(x: -2, y: h))
            for step in 0...100 {
                let x = Double(step) / 100
                let y = terrain(x, layer: layer, base: base, h: h)
                ridge.addLine(to: CGPoint(x: x * w, y: y))
            }
            ridge.addLine(to: CGPoint(x: w + 2, y: h)); ridge.closeSubpath()
            let colors: [Color] = [mood.horizon.mix(with: mood.top, by: 0.55), mood.top.mix(with: Color(hex: 0x1D302C), by: 0.45), Color(hex: mood.snow ? 0x34464A : 0x142723), Color(hex: 0x101C1B)]
            ctx.fill(ridge, with: .linearGradient(Gradient(colors: [colors[layer], Color(hex: 0x0E181A)]), startPoint: CGPoint(x: 0, y: base - 20), endPoint: CGPoint(x: 0, y: h)))
            // Fine contour lines, like the engraved landscape on a record sleeve.
            if layer < 3 {
                for contour in 1...5 {
                    var line = Path()
                    for step in 0...80 {
                        let x = Double(step) / 80
                        let y = terrain(x, layer: layer, base: base, h: h) + Double(contour) * 4
                        if step == 0 { line.move(to: CGPoint(x: x * w, y: y)) }
                        else { line.addLine(to: CGPoint(x: x * w, y: y)) }
                    }
                    ctx.stroke(line, with: .color(mood.accent.opacity(0.035)), lineWidth: 0.6)
                }
            }
        }
        if mood.fog {
            for i in 0..<4 {
                let cy = h * (0.45 + Double(i) * 0.1)
                ctx.drawLayer { fog in
                    fog.addFilter(.blur(radius: 20))
                    let x = sin(time * 0.12 + Double(i)) * w * 0.2
                    fog.fill(Path(ellipseIn: CGRect(x: x - w * 0.2, y: cy, width: w * 1.4, height: h * 0.05)), with: .color(mood.horizon.opacity(0.36)))
                }
            }
        }
        if mood.wet || mood.snow {
            for i in 0..<(mood.snow ? 65 : 90) {
                let depth = 0.4 + noise(i + 77) * 0.6
                let speed = mood.snow ? 0.035 : 0.48
                let y = (noise(i * 7) + time * speed * depth).truncatingRemainder(dividingBy: 1) * h
                let x = (noise(i * 13) * w + sin(time * 0.4 + Double(i)) * (mood.snow ? 12 : 2) + y * min(wind, 40) * 0.008).truncatingRemainder(dividingBy: w)
                if mood.snow {
                    let r = 1.1 + depth
                    ctx.fill(Path(ellipseIn: CGRect(x: x, y: y, width: r, height: r)), with: .color(.white.opacity(depth * 0.75)))
                } else {
                    var drop = Path(); drop.move(to: CGPoint(x: x, y: y))
                    drop.addLine(to: CGPoint(x: x + min(wind, 40) * 0.12, y: y + depth * 14))
                    ctx.stroke(drop, with: .color(Color(hex: 0xD3E6EA).opacity(depth * 0.4)), lineWidth: 0.65)
                }
            }
        }
        // Restrained storm illumination: a slow sheet glow rather than flashes.
        if mood.storm {
            let pulse = pow(max(0, sin(time * 0.35)), 18) * 0.10
            ctx.fill(bounds, with: .radialGradient(Gradient(colors: [.white.opacity(pulse), .clear]), center: CGPoint(x: w * 0.7, y: h * 0.25), startRadius: 0, endRadius: w))
        }
        // A quiet scrim under the small weather labels preserves contrast in daylight.
        ctx.fill(bounds, with: .linearGradient(Gradient(stops: [
            .init(color: .black.opacity(0.28), location: 0),
            .init(color: .clear, location: 0.72)
        ]), startPoint: .zero, endPoint: CGPoint(x: w, y: 0)))
        ctx.fill(bounds, with: .linearGradient(Gradient(stops: [.init(color: .black.opacity(0.26), location: 0), .init(color: .clear, location: 0.45), .init(color: Color(hex: 0x091211).opacity(0.8), location: 1)]), startPoint: .zero, endPoint: CGPoint(x: 0, y: h)))
    }

    private func noise(_ seed: Int) -> Double {
        let n = sin(Double(seed + 1) * 127.1) * 43758.5453
        return n - floor(n)
    }
    private func terrain(_ x: Double, layer: Int, base: Double, h: Double) -> Double {
        let phase = Double(layer) * 1.7
        return base + h * (sin(x * 5.2 + phase) * 0.042 + sin(x * 11.3 + phase * 2) * 0.017 + sin(x * 23 + phase) * 0.004)
    }
}
