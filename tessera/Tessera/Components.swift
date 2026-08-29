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
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 7),
                                     count: options.count > 4 ? 3 : options.count),
                      spacing: 7) {
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
                    .buttonStyle(PressStyle(scale: 0.95))
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
        guard let img = EmitterTile.render(processed, cell: 3, duty: duty)
        else { return nil }
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
        case .offline, .standIn: Ink.faint
        }
    }
    private var text: Color {
        switch link {
        case .live: Ink.moss
        case .searching: Ink.dim
        case .offline, .standIn: Ink.faint
        }
    }
    private var label: String {
        switch link {
        case .live: "live"
        case .searching: "looking"
        case .offline: "away"
        case .standIn: "no wall yet"
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
        case .searching: "Looking for your wall."
        case .offline: "Showing the last thing your wall had."
        case .standIn: "Nothing playing."
        }
    }
}


// MARK: - Lamp colours

/// The two threads every lamp effect is built from. Solid uses the first,
/// the patterns and fades use both, and rainbow ignores them and says so.
/// While the album is lending its colours these show what it lent and are
/// not editable, because editing them would do nothing.
struct LampInks: View {
    let color: String
    let color2: String
    let matchArt: Bool
    let effect: String
    let accent: Color
    var onPick: (String, String) -> Void      // key, "#rrggbb"

    @State private var a: Color = .orange
    @State private var b: Color = .red

    private var ignoresColour: Bool { effect == "rainbow" }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(label)
                .font(.ui(12, .medium))
                .foregroundStyle(Ink.dim)

            HStack(spacing: 14) {
                if matchArt || ignoresColour {
                    // read-only: what the effect is actually using
                    dot(Color(wallHex: color) ?? accent)
                    dot(Color(wallHex: color2) ?? accent)
                } else {
                    picker($a) { onPick("color", Self.hex($0)) }
                    picker($b) { onPick("color2", Self.hex($0)) }
                }
                Spacer()
            }
        }
        .onAppear {
            a = Color(wallHex: color) ?? .orange
            b = Color(wallHex: color2) ?? .red
        }
        .onChange(of: color) { _, v in a = Color(wallHex: v) ?? a }
        .onChange(of: color2) { _, v in b = Color(wallHex: v) ?? b }
    }

    private var label: String {
        if ignoresColour { return "colour · rainbow makes its own" }
        return matchArt ? "colour · from the album" : "colour"
    }

    private func dot(_ c: Color) -> some View {
        Circle()
            .fill(c)
            .frame(width: 30, height: 30)
            .overlay { Circle().strokeBorder(Ink.hairline, lineWidth: 1) }
            .opacity(0.75)
    }

    private func picker(_ binding: Binding<Color>, _ commit: @escaping (Color) -> Void) -> some View {
        ColorPicker(selection: binding, supportsOpacity: false) { EmptyView() }
            .labelsHidden()
            .scaleEffect(1.15)
            .frame(width: 30, height: 30)
            .onChange(of: binding.wrappedValue) { _, c in
                Taps.detent(intensity: 0.5)
                commit(c)
            }
    }

    static func hex(_ c: Color) -> String {
        var r: CGFloat = 0, g: CGFloat = 0, bl: CGFloat = 0, al: CGFloat = 0
        UIColor(c).getRed(&r, green: &g, blue: &bl, alpha: &al)
        return String(format: "#%02x%02x%02x",
                      Int(max(0, min(255, r * 255))),
                      Int(max(0, min(255, g * 255))),
                      Int(max(0, min(255, bl * 255))))
    }
}


// MARK: - Ticker

/// What the wall should letter, in the wall's own font. Typing here is
/// typing on the wall: it letters this itself rather than being handed a
/// picture of it, which is what makes it scroll.
struct TickerRow: View {
    let text: String
    let loop: Bool
    let accent: Color
    var onSet: (String, Any) -> Void

    @State private var draft = ""
    @FocusState private var typing: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                TextField("say something", text: $draft)
                    .font(.machine(14))
                    .foregroundStyle(Ink.ink)
                    .autocorrectionDisabled()
                    .focused($typing)
                    .submitLabel(.send)
                    .padding(.vertical, 12).padding(.horizontal, 14)
                    .background(Ink.sunk)
                    .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(Ink.hairline, lineWidth: 1) }
                    .onSubmit { send() }

                Button("Send") { send() }
                    .buttonStyle(PressStyle(scale: 0.96))
                    .font(.ui(14, .semibold))
                    .foregroundStyle(draft.isEmpty ? Ink.faint : accent)
                    .disabled(draft.isEmpty)
            }

            PillRow(
                label: "when it reaches the end",
                options: [("loop", true), ("back to art", false)],
                selected: loop,
                accent: accent
            ) { onSet("ticker_loop", $0) }
        }
        .onAppear { if draft.isEmpty { draft = text } }
    }

    private func send() {
        guard !draft.isEmpty else { return }
        Taps.commit()
        typing = false
        onSet("ticker_text", draft)
    }
}


// MARK: - Timer

/// The kitchen timer, from the clock's context row. Four durations cover
/// nearly every real use; anything fussier belongs to Siri, which takes any
/// number of minutes by voice.
struct WallTimerRow: View {
    let remaining: Int?
    let total: Int?
    let accent: Color
    var onSet: (Double) -> Void

    var body: some View {
        if let remaining {
            HStack(spacing: 14) {
                // The wall is the display; this is just the handle.
                Text(clock(remaining))
                    .font(.machine(22))
                    .foregroundStyle(remaining == 0 ? accent : Ink.ink)
                    .contentTransition(.numericText(countsDown: true))
                    .animation(.linear(duration: 0.3), value: remaining)
                if let total, total > 0, remaining > 0 {
                    DrainRule(fraction: Double(remaining) / Double(total), accent: accent)
                }
                Spacer()
                Button(remaining == 0 ? "Done" : "Cancel") {
                    Taps.commit()
                    onSet(0)
                }
                .buttonStyle(PressStyle(scale: 0.96))
                .font(.ui(14, .medium))
                .foregroundStyle(accent)
            }
        } else {
            VStack(alignment: .leading, spacing: 10) {
                Text("count something down")
                    .font(.ui(12, .medium))
                    .foregroundStyle(Ink.dim)
                HStack(spacing: 8) {
                    ForEach([1.0, 5, 10, 25], id: \.self) { m in
                        Button {
                            Taps.commit()
                            onSet(m)
                        } label: {
                            Text("\(Int(m))m")
                                .font(.machine(13))
                                .foregroundStyle(Ink.ink)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 10)
                                .background(Ink.sunk)
                                .overlay {
                                    RoundedRectangle(cornerRadius: 8)
                                        .strokeBorder(Ink.hairline, lineWidth: 1)
                                }
                        }
                        .buttonStyle(PressStyle(scale: 0.95))
                    }
                }
            }
        }
    }

    private func clock(_ s: Int) -> String {
        String(format: "%02d:%02d", s / 60, s % 60)
    }
}

/// The same draining border the wall draws, flattened to a line.
private struct DrainRule: View {
    let fraction: Double
    let accent: Color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(accent.opacity(0.18))
                Capsule().fill(accent)
                    .frame(width: max(2, geo.size.width * fraction))
            }
        }
        .frame(width: 64, height: 3)
    }
}
