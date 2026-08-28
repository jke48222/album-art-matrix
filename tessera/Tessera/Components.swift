// Tessera's instruments. Standard bones, custom skin: system gestures and
// accessibility underneath, the wall's language on top.
//
// Rule this file follows: a control's shape reports what kind of question it
// asks. Modes are circular because they are states of one object. Speed is a
// ticker because rpm is a physical rate. Finish is three thumbnails because
// choosing a finish should be looking, not reading a word. Only the ambient
// effect is a row of capsules, and it is the one that earns it.

import SwiftUI
import UIKit

// MARK: - Pills

struct PillRow<T: Hashable>: View {
    let label: String
    let options: [(String, T)]
    let selected: T
    let accent: Color
    var onPick: (T) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(label)
                .font(.ui(12, .medium))
                .foregroundStyle(Ink.dim)
            HStack(spacing: 7) {
                ForEach(options, id: \.1) { (title, value) in
                    let active = value == selected
                    Button {
                        guard !active else { return }
                        Taps.detent()
                        onPick(value)
                    } label: {
                        Text(title)
                            .font(.ui(12, .medium))
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                            .foregroundStyle(active ? Ink.ground : Ink.dim)
                            .padding(.vertical, 9)
                            .frame(maxWidth: .infinity)
                            .background { Capsule().fill(active ? accent : Color.clear) }
                            .overlay { Capsule().strokeBorder(active ? .clear : Ink.hairline, lineWidth: 1) }
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(active ? [.isButton, .isSelected] : .isButton)
                }
            }
            .animation(Motion.settle, value: selected)
        }
    }
}

// MARK: - Speed

/// rpm is a physical rate, so it reads as one: the value in machine type,
/// the three real turntable speeds as detents on a rail.
struct SpeedTicker: View {
    let rpm: Double
    let accent: Color
    var onPick: (Double) -> Void

    private let speeds: [(String, Double)] = [("7.5", 7.5), ("33⅓", 33.33), ("45", 45.0)]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(label)
                    .font(.machine(26))
                    .foregroundStyle(accent)
                    .contentTransition(.numericText())
                Text("rpm")
                    .font(.machine(10))
                    .foregroundStyle(Ink.faint)
            }
            HStack(spacing: 0) {
                ForEach(speeds, id: \.1) { (title, value) in
                    let active = abs(value - rpm) < 0.01
                    Button {
                        guard !active else { return }
                        Taps.detent(intensity: 0.6)
                        onPick(value)
                    } label: {
                        VStack(spacing: 7) {
                            Rectangle()
                                .fill(active ? accent : Ink.hairline)
                                .frame(width: active ? 2 : 1, height: active ? 18 : 11)
                            Text(title)
                                .font(.machine(10))
                                .foregroundStyle(active ? Ink.ink : Ink.faint)
                        }
                        .frame(maxWidth: .infinity)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(title) rpm")
                    .accessibilityAddTraits(active ? [.isButton, .isSelected] : .isButton)
                }
            }
            .animation(Motion.settle, value: rpm)
        }
    }

    private var label: String {
        rpm == 33.33 ? "33⅓" : (rpm == rpm.rounded() ? String(Int(rpm)) : String(format: "%.1f", rpm))
    }
}

// MARK: - Finish

/// Three thumbnails of the frame actually on the wall, each through one
/// finish. Choosing is looking.
///
/// `poster` is the wall's own math exactly (3 bits per channel). `dither` is
/// Floyd-Steinberg to a fixed 3-3-2 palette, which is the same algorithm as
/// the wall's but not its adaptive 16-colour palette, so read this thumbnail
/// as a preview of the character, not a pixel-exact proof.
struct FinishRow: View {
    let frame: Data?
    let duty: Double
    let selected: String
    let accent: Color
    var onPick: (String) -> Void

    private let finishes = [("clean", "Clean"), ("dither", "Dither"), ("poster", "Poster")]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("finish")
                .font(.ui(12, .medium))
                .foregroundStyle(Ink.dim)
            HStack(spacing: 10) {
                ForEach(finishes, id: \.0) { (id, title) in
                    let active = id == selected
                    Button {
                        guard !active else { return }
                        Taps.detent(intensity: 0.6)
                        onPick(id)
                    } label: {
                        VStack(spacing: 8) {
                            FinishThumb(frame: frame, finish: id, duty: duty)
                                .aspectRatio(1, contentMode: .fit)
                                .overlay {
                                    Rectangle().strokeBorder(active ? accent : Ink.hairline,
                                                             lineWidth: active ? 1.5 : 1)
                                }
                            Text(title)
                                .font(.ui(12, .medium))
                                .foregroundStyle(active ? Ink.ink : Ink.faint)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(title)
                    .accessibilityAddTraits(active ? [.isButton, .isSelected] : .isButton)
                }
            }
            .animation(Motion.settle, value: selected)
        }
    }
}

private struct FinishThumb: View {
    let frame: Data?
    let finish: String
    let duty: Double

    var body: some View {
        if let img = Finishes.thumb(frame, finish: finish, duty: duty) {
            Image(uiImage: img).interpolation(.high).resizable()
        } else {
            Rectangle().fill(Color.black)
        }
    }
}

enum Finishes {
    private static var cache: [String: UIImage] = [:]

    static func thumb(_ data: Data?, finish: String, duty: Double) -> UIImage? {
        guard let data, data.count == 64 * 64 * 3 else { return nil }
        let key = "\(data.hashValue):\(finish):\(Int(duty * 10))"
        if let hit = cache[key] { return hit }
        let processed = apply(data, finish: finish)
        guard let img = raster(processed, duty: duty) else { return nil }
        if cache.count > 24 { cache.removeAll() }
        cache[key] = img
        return img
    }

    private static func apply(_ data: Data, finish: String) -> [UInt8] {
        var px = [UInt8](data)
        switch finish {
        case "poster":
            // 3 bits per channel, the wall's own posterize.
            for i in 0..<px.count { px[i] = px[i] & 0xE0 }
        case "dither":
            // Floyd-Steinberg onto a 3-3-2 palette.
            var buf = px.map { Float($0) }
            for y in 0..<64 {
                for x in 0..<64 {
                    let i = (y * 64 + x) * 3
                    for c in 0..<3 {
                        let old = buf[i + c]
                        let levels: Float = c == 2 ? 3 : 7
                        let quant = (old / 255 * levels).rounded() / levels * 255
                        buf[i + c] = quant
                        let err = old - quant
                        func spread(_ dx: Int, _ dy: Int, _ f: Float) {
                            let nx = x + dx, ny = y + dy
                            guard nx >= 0, nx < 64, ny < 64 else { return }
                            buf[(ny * 64 + nx) * 3 + c] += err * f
                        }
                        spread(1, 0, 7.0 / 16); spread(-1, 1, 3.0 / 16)
                        spread(0, 1, 5.0 / 16); spread(1, 1, 1.0 / 16)
                    }
                }
            }
            for i in 0..<px.count { px[i] = UInt8(max(0, min(255, buf[i]))) }
        default:
            break
        }
        return px
    }

    /// Small emitter render, same language as the hero at thumbnail size.
    private static func raster(_ px: [UInt8], duty: Double) -> UIImage? {
        let cell: CGFloat = 3
        let side: CGFloat = 64 * cell
        let fmt = UIGraphicsImageRendererFormat.default()
        fmt.scale = 1
        fmt.opaque = true
        let d = CGFloat(max(0.05, min(1.0, duty)))
        return UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: fmt).image { rctx in
            let ctx = rctx.cgContext
            ctx.setFillColor(UIColor.black.cgColor)
            ctx.fill(CGRect(x: 0, y: 0, width: side, height: side))
            let r = cell * 0.36
            for i in 0..<(64 * 64) {
                let o = i * 3
                guard px[o] > 6 || px[o + 1] > 6 || px[o + 2] > 6 else { continue }
                let cx = CGFloat(i % 64) * cell + cell / 2
                let cy = CGFloat(i / 64) * cell + cell / 2
                ctx.setFillColor(UIColor(red: CGFloat(px[o]) / 255 * d,
                                         green: CGFloat(px[o + 1]) / 255 * d,
                                         blue: CGFloat(px[o + 2]) / 255 * d,
                                         alpha: 1).cgColor)
                ctx.fillEllipse(in: CGRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2))
            }
        }
    }
}

// MARK: - Link chip

struct LinkChip: View {
    let link: LinkState
    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(dot).frame(width: 5, height: 5)
            Text(label)
                .font(.machine(10))
                .textCase(.uppercase)
                .foregroundStyle(text)
        }
        .accessibilityElement(children: .combine)
    }

    private var dot: Color {
        switch link {
        case .live: Ink.moss
        case .searching: Ink.tile
        case .offline: Ink.faint
        }
    }
    private var text: Color {
        switch link {
        case .live: Ink.moss
        case .searching: Ink.dim
        case .offline: Ink.faint
        }
    }
    private var label: String {
        switch link {
        case .live: "live"
        case .searching: "finding"
        case .offline: "offline"
        }
    }
}

// MARK: - Placard

/// What the wall is wearing. The title is the loudest thing on the screen
/// after the panel, and it takes the panel's light like everything else.
struct Placard: View {
    let state: WallState
    let link: LinkState
    var litInk: Color = Ink.ink
    var litDim: Color = Ink.dim

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let title = state.title, !title.isEmpty {
                Text(title)
                    .font(.display(29))
                    .foregroundStyle(litInk)
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
                    .fixedSize(horizontal: false, vertical: true)
                Text(artistLine)
                    .font(.ui(15, .medium))
                    .foregroundStyle(litDim)
                    .lineLimit(2)
            } else {
                Text(silence)
                    .font(.displayMid(19))
                    .foregroundStyle(litInk)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let left = state.sleepRemaining, left > 0 {
                Text("sleeping in \(left / 60)m \(left % 60)s")
                    .font(.machine(10))
                    .foregroundStyle(Ink.faint)
                    .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(Motion.settle, value: state.title)
    }

    private var artistLine: String {
        let a = state.artist ?? ""
        let al = state.album ?? ""
        return al.isEmpty || al == a ? a : "\(a) · \(al)"
    }

    private var silence: String {
        switch link {
        case .live: state.mode == "off" ? "Asleep." : "Nothing playing."
        case .searching: "Looking for the wall."
        case .offline: "The wall is not answering."
        }
    }
}
