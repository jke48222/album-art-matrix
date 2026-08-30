// The hero. Not a picture of the wall: the wall.
//
// 64x64 RGB888 from /frame.raw, drawn as 4,096 discrete emitters on black,
// each with its own halo. Brightness is a DUTY CYCLE multiplied into every
// emitter, never an alpha over the whole image, which is what makes the
// signature behaviour possible: above roughly 60% duty the halos overlap and
// merge into a continuous picture, and below roughly 30% they separate and
// four thousand individual tiles appear where the picture was. Dimming does
// not fade the wall. It dissolves the picture back into its tesserae.
//
// Rasterised once per (frame, duty step) and cached, so a full-travel drag
// costs at most 25 renders and every step is reused.

import SwiftUI
import UIKit

struct FrameReading {
    /// The frame itself, so the panel can be drawn live at any duty.
    let px: [UInt8]?
    /// Up to three hue-distinct colours the art actually contains, most
    /// present first. This is what lights the room.
    let palette: [Color]
    let lit: Double          // 0...1 before duty; how much light the art has
    let key: String

    var glow: Color { palette.first ?? Ink.tile }
    /// A second light, for the far side of the room. Falls back to the first.
    var glow2: Color { palette.count > 1 ? palette[1] : glow }

    static let dark = FrameReading(px: nil, palette: [], lit: 0, key: "dark")
}

enum FrameRenderer {
    private static var cachedData: Data? = nil
    private static var cached: FrameReading = .dark

    /// Analysis only. The panel is drawn live (see PanelCanvas), so duty is a
    /// continuous parameter rather than a cache key: rasterising per duty step
    /// is what made the brightness drag move in visible jumps.
    static func read(_ data: Data?) -> FrameReading {
        guard let data, data.count == 64 * 64 * 3 else { return .dark }
        // Compare the WHOLE buffer, never Data.hashValue: Foundation hashes
        // only a short prefix of a Data, and any mode whose top rows stay
        // dark (the ticker letters at mid-height) produced identical hashes
        // for every frame — so this cache served the first dark frame
        // forever and the panel looked broken while the model was fine.
        if data == cachedData { return cached }

        var lum = [Float](repeating: 0, count: 64 * 64)
        var total: Float = 0
        var digest: UInt64 = 0xcbf2_9ce4_8422_2325     // FNV-1a, whole frame
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let p = raw.bindMemory(to: UInt8.self)
            for i in 0..<(64 * 64) {
                let o = i * 3
                let l = 0.2126 * Float(p[o]) + 0.7152 * Float(p[o + 1]) + 0.0722 * Float(p[o + 2])
                lum[i] = l
                total += l
                digest = (digest ^ UInt64(p[o])) &* 0x1000_0000_01b3
                digest = (digest ^ UInt64(p[o + 1])) &* 0x1000_0000_01b3
                digest = (digest ^ UInt64(p[o + 2])) &* 0x1000_0000_01b3
            }
        }
        let key = String(digest, radix: 36)
        let lit = min(1.0, pow(Double(total) / Double(64 * 64) / 255.0 * 3.2, 0.8))

        let reading = FrameReading(
            px: [UInt8](data),
            palette: palette(data, lum: lum),
            lit: lit,
            key: key
        )
        cachedData = data
        cached = reading
        return reading
    }

    /// What the room catches: the colours the art actually contains.
    ///
    /// On a photographic sleeve the brightest average is the white highlights,
    /// and a wall of colour would light the room grey, so near-greys are
    /// excluded outright and population is weighted by saturation. Then the
    /// top buckets are filtered for hue distance, so a room lit by two lights
    /// is lit by two different colours rather than one colour twice.
    private static func palette(_ data: Data, lum: [Float]) -> [Color] {
        var buckets: [Int: (n: Float, r: Float, g: Float, b: Float, sat: Float)] = [:]
        buckets.reserveCapacity(256)
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let p = raw.bindMemory(to: UInt8.self)
            for i in 0..<(64 * 64) where lum[i] >= 24 {
                let o = i * 3
                let r = Float(p[o]), g = Float(p[o + 1]), b = Float(p[o + 2])
                let mx = max(r, g, b), mn = min(r, g, b)
                let sat = mx > 0 ? (mx - mn) / mx : 0
                guard sat >= 0.28 else { continue }
                let key = (Int(r) >> 4) << 8 | (Int(g) >> 4) << 4 | (Int(b) >> 4)
                var e = buckets[key] ?? (0, 0, 0, 0, 0)
                e.n += 1; e.r += r; e.g += g; e.b += b; e.sat += sat
                buckets[key] = e
            }
        }

        let ranked = buckets.values
            .map { e -> (score: Float, r: Float, g: Float, b: Float) in
                (e.n * (0.2 + (e.sat / e.n) * 0.8), e.r / e.n, e.g / e.n, e.b / e.n)
            }
            .sorted { $0.score > $1.score }

        var out: [Color] = []
        var hues: [Float] = []
        for c in ranked {
            let h = hue(c.r, c.g, c.b)
            // 40 degrees apart, so the second light is a different colour
            if hues.contains(where: { abs(angleDelta($0, h)) < 40 }) { continue }
            hues.append(h)
            let mx = max(c.r, c.g, c.b, 1)
            let k = (255 / mx) * 0.92
            out.append(Color(red: Double(min(255, c.r * k) / 255),
                             green: Double(min(255, c.g * k) / 255),
                             blue: Double(min(255, c.b * k) / 255)))
            if out.count == 3 { break }
        }
        return out
    }

    private static func hue(_ r: Float, _ g: Float, _ b: Float) -> Float {
        let mx = max(r, g, b), mn = min(r, g, b), d = mx - mn
        guard d > 0 else { return 0 }
        var h: Float
        if mx == r { h = 60 * ((g - b) / d) }
        else if mx == g { h = 60 * (2 + (b - r) / d) }
        else { h = 60 * (4 + (r - g) / d) }
        return h < 0 ? h + 360 : h
    }

    private static func angleDelta(_ a: Float, _ b: Float) -> Float {
        let d = abs(a - b).truncatingRemainder(dividingBy: 360)
        return d > 180 ? 360 - d : d
    }

}

/// The wall, drawn live.
///
/// Brightness is a duty multiplied into every emitter, exactly as before, but
/// now applied while drawing rather than baked into a cached raster. That is
/// what lets the drag be continuous: there is no bucket to quantise to, so the
/// picture dissolves into its tiles smoothly instead of in 4% steps.
struct PanelCanvas: View {
    let px: [UInt8]?
    let duty: Double

    var body: some View {
        Canvas(rendersAsynchronously: false) { ctx, size in
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.black))
            guard let px, px.count == 64 * 64 * 3 else { return }

            let cell = size.width / 64
            let r = cell * 0.34
            let d = max(0.05, min(1.0, duty))
            // Dimming an LED goes warm, not grey.
            let warm = 0.18 * (1 - d)
            let gK = 1 - warm * 0.34
            let bK = 1 - warm
            let unlit = Color(white: 0.055)

            for i in 0..<(64 * 64) {
                let o = i * 3
                let cx = CGFloat(i % 64) * cell + cell / 2
                let cy = CGFloat(i / 64) * cell + cell / 2
                let R = Double(px[o]), G = Double(px[o + 1]), B = Double(px[o + 2])
                let lum = 0.2126 * R + 0.7152 * G + 0.0722 * B

                if lum < 8 {
                    ctx.fill(Path(ellipseIn: CGRect(x: cx - r, y: cy - r,
                                                    width: r * 2, height: r * 2)),
                             with: .color(unlit))
                    continue
                }

                let colour = Color(red: R / 255 * d,
                                   green: G / 255 * d * gK,
                                   blue: B / 255 * d * bK)
                // The halo is what merges neighbours into a picture. Shrink it
                // with duty and the tiles separate.
                let n = CGFloat(lum / 255)
                let hr = r + cell * 0.55 * n * CGFloat(d)
                ctx.fill(
                    Path(ellipseIn: CGRect(x: cx - hr, y: cy - hr, width: hr * 2, height: hr * 2)),
                    with: .color(colour.opacity(0.20 * Double(n) * pow(d, 1.4)))
                )
                ctx.fill(
                    Path(ellipseIn: CGRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2)),
                    with: .color(colour)
                )
            }
        }
        .drawingGroup()
    }
}

// MARK: - The panel

/// The object in the room, and the only brightness control in the app.
///
/// Press anywhere on it and drag vertically: the picture dissolves into its
/// tiles as it dims. A rule across the panel marks the wall's last confirmed
/// brightness and is the entire reset affordance. Pressing and holding without
/// dragging puts the wall to sleep, or wakes it.
///
/// Drag sideways and the panel becomes the day, running backwards. Each step
/// is one sleeve the wall wore, and lifting your finger puts that one back on
/// it. Two axes on one surface is a lot to ask of a control, but it is the
/// right ask here: both gestures are the wall changing what it shows, and
/// neither belongs in a row of buttons underneath it.
struct WallHero: View {
    let reading: FrameReading
    let confirmed: Double            // what the wall last told us
    @Binding var dragging: Double?   // non-nil while the finger is adjusting
    let link: LinkState
    /// Changes when a NEW SLEEVE arrives, not when a new frame does. In an
    /// animated mode the frame changes many times a second and every one of
    /// those is emphatically not an arrival; keying the repaint on the frame
    /// restarted a 500ms blank-and-relight several times a second, which on
    /// the panel reads as flashing black.
    let arrivalKey: String
    /// What the wall has worn, newest first. Empty disables the sideways
    /// gesture entirely rather than making it do nothing, so the panel never
    /// swallows a swipe it has no answer for.
    var history: [WornRun] = []
    var tile: (JournalEntry) -> UIImage? = { _ in nil }
    /// True whenever a finger is on the panel. The pager reads this and steps
    /// aside: a sideways drag here belongs to the wall, not to the page.
    @Binding var touching: Bool
    var onCommit: (Double) -> Void
    var onHold: () -> Void
    var onWear: (JournalEntry) -> Void = { _ in }
    /// A short flick, left or right, is a SONG gesture: previous or next.
    /// The sustained pull is what walks the wall's own history.
    var onFlickPrev: () -> Void = {}
    var onFlickNext: () -> Void = {}

    @State private var startValue: Double? = nil
    @State private var lastDetent: Int = -1
    @State private var holdWork: DispatchWorkItem? = nil
    @State private var moved = false
    @State private var axis: Axis? = nil
    @State private var back: Int = 0              // sleeves behind now

    private enum Axis { case light, back }

    /// How far you have to pull for one more sleeve. A record's width of
    /// travel per record: the first cut moved six sleeves on a flick and
    /// felt like dropping the crate.
    private let stride: CGFloat = 110

    // Arrival: a new sleeve does not cross-dissolve onto a wall of LEDs, it
    // repaints. The outgoing frame is extinguished column by column, then the
    // incoming one is lit in the same order.
    @State private var outgoing: [UInt8]? = nil
    @State private var scan: Double = 1          // 1 = settled
    @State private var scanPhase: ScanPhase = .idle

    private enum ScanPhase { case idle, blanking, lighting }

    private var duty: Double { dragging ?? confirmed }
    private func norm(_ v: Double) -> Double { (v - 0.05) / 0.95 }

    private var scrubbed: WornRun? {
        guard back > 0, back < history.count else { return nil }
        return history[back]
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .bottomLeading) {
                Color.black

                // outgoing frame, being extinguished left to right
                if scanPhase == .blanking, let old = outgoing {
                    PanelCanvas(px: old, duty: duty)
                        .mask(alignment: .trailing) { edge(reveal: 1 - scan, from: .trailing) }
                }

                PanelCanvas(px: reading.px, duty: duty)
                    .mask(alignment: .leading) {
                        scanPhase == .lighting
                            ? edge(reveal: scan, from: .leading)
                            : edge(reveal: 1, from: .leading)
                    }
                    .opacity(scanPhase == .blanking ? 0 : 1)

                // Scrubbed: the sleeve from back then, over the live one.
                if back > 0, let run = scrubbed {
                    ZStack(alignment: .bottomLeading) {
                        if let img = tile(run.entry) {
                            Image(uiImage: img)
                                .interpolation(.none)
                                .resizable()
                                .scaledToFill()
                        } else {
                            Color.black
                        }
                        // Not a caption on a photo: a strip of the same ink
                        // the placard uses, so the panel is still the panel.
                        VStack(alignment: .leading, spacing: 2) {
                            Text(run.entry.title)
                                .font(.displayMid(16))
                                .foregroundStyle(Ink.ink)
                                .lineLimit(1)
                            Text(run.entry.artist)
                                .font(.ui(12))
                                .foregroundStyle(Ink.dim)
                                .lineLimit(1)
                            Text(run.entry.date.formatted(date: .omitted, time: .shortened))
                                .font(.machine(9))
                                .foregroundStyle(Ink.faint)
                                .padding(.top, 2)
                        }
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            LinearGradient(colors: [.clear, Ink.ground.opacity(0.92)],
                                           startPoint: .top, endPoint: .bottom)
                        )
                    }
                    .transition(.opacity)

                    // How far back you are, as ticks: one lit per sleeve, so
                    // the depth of the rewind is a thing you can see.
                    HStack(spacing: 3) {
                        ForEach(0..<min(back, 14), id: \.self) { _ in
                            Rectangle().fill(Ink.ink.opacity(0.75)).frame(width: 2, height: 7)
                        }
                        if back > 14 {
                            Text("+\(back - 14)").font(.machine(8)).foregroundStyle(Ink.dim)
                        }
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .allowsHitTesting(false)
                }

                // Two marks, and they say different things.
                //
                // The dim one is where the wall actually is: it stays put
                // while you drag, so you can always find your way back, and
                // dragging onto it is the whole of the reset affordance.
                Rectangle()
                    .fill(Ink.ink.opacity(0.10))
                    .frame(height: 1)
                    .padding(.bottom, geo.size.height * norm(confirmed))
                    .allowsHitTesting(false)

                // The bright one is the finger. It only exists mid-drag, and
                // it tracks continuously, so the gesture has a position and
                // not just a number.
                if dragging != nil, back == 0 {
                    Rectangle()
                        .fill(Ink.ink)
                        .frame(height: 2)
                        .shadow(color: Ink.ink.opacity(0.5), radius: 4)
                        .padding(.bottom, geo.size.height * norm(duty))
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }

                if dragging != nil, back == 0 {
                    Text("\(Int(duty * 100))%")
                        .font(.machine(11))
                        .foregroundStyle(Ink.ink)
                        .padding(14)
                        .transition(.opacity)
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        if startValue == nil {
                            startValue = confirmed
                            moved = false
                            axis = nil
                            touching = true
                            Taps.warm()          // first detent lands on time
                            scheduleHold()
                        }
                        // Whichever way you commit to first is the gesture.
                        // Deciding once and holding to it is what stops a
                        // slightly diagonal pull from doing both jobs badly.
                        if axis == nil {
                            let dx = abs(g.translation.width), dy = abs(g.translation.height)
                            // an axis is claimed only by clear dominance, so a
                            // diagonal wobble cannot latch the wrong gesture
                            if dy > 8, dy > dx * 1.3 {
                                axis = .light; moved = true; cancelHold()
                            } else if dx > 12, dx > dy * 1.3 {
                                axis = .back; cancelHold(); Taps.warm()
                            }
                        }

                        if axis == .back {
                            // Left goes backwards, the way a tape does; the
                            // deep scrub exists only when there is a past.
                            guard !history.isEmpty else { return }
                            let steps = Int(max(0, -g.translation.width) / stride)
                            let want = min(steps, history.count - 1)
                            if want != back {
                                back = want
                                Taps.detent(intensity: want == 0 ? 0.3 : 0.55)
                            }
                            return
                        }

                        guard moved, let start = startValue else { return }
                        // Relative to touch-down, so grabbing never jumps the wall.
                        let delta = -g.translation.height / max(1, geo.size.height)
                        // 1% resolution so the picture dissolves smoothly; the
                        // detent is a feeling every 5%, not the step size.
                        let stepped = ((start + delta * 0.95) / 0.01).rounded() * 0.01
                        let v = min(1.0, max(0.05, stepped))
                        if v != dragging {
                            dragging = v
                            let d = Int(v * 20)
                            if d != lastDetent {
                                // the control gets quieter as the room darkens
                                Taps.detent(intensity: 0.25 + 0.45 * v)
                                lastDetent = d
                            }
                        }
                    }
                    .onEnded { g in
                        cancelHold()
                        touching = false
                        if axis == .back {
                            let dx = g.translation.width
                            // A flick is FAST and SHORT: real momentum, and
                            // the finger never travelled a full stride. A
                            // slow medium drag is someone peeking at history
                            // and letting go, and skipping their song for it
                            // was the bug that felt so wrong.
                            let fling = abs(g.predictedEndTranslation.width - dx) > 60
                            if back == 0, abs(dx) > 36, abs(dx) < stride, fling {
                                // the phone convention: push the song away to
                                // the left for the NEXT one, pull from the
                                // left for the previous
                                if dx < 0 { onFlickNext() } else { onFlickPrev() }
                                Taps.commit()
                            } else if back > 0, let run = scrubbed {
                                onWear(run.entry)
                                Taps.commit()
                            }
                            // The wall answers in its own time; letting go
                            // here rather than waiting for it keeps the panel
                            // from sitting on a stale sleeve if it does not.
                            withAnimation(Motion.settle) { back = 0 }
                        } else if moved, let v = dragging {
                            onCommit(v)
                            Taps.commit()
                        }
                        startValue = nil
                        moved = false
                        axis = nil
                        dragging = nil
                    }
            )
            .overlay(alignment: .topTrailing) { staleStamp }
            .onChange(of: arrivalKey) { _, _ in arrive() }
            .onAppear { outgoing = reading.px }
            .accessibilityElement()
            .accessibilityLabel("The wall")
            .accessibilityValue("Brightness \(Int(duty * 100)) percent")
            .accessibilityHint("Adjust to dim the wall. Press and hold to put it to sleep. Swipe left to go back through what it has worn.")
            .accessibilityAdjustableAction { dir in
                onCommit(dir == .increment ? min(1.0, confirmed + 0.05) : max(0.05, confirmed - 0.05))
            }
        }
        .aspectRatio(1, contentMode: .fit)
    }

    /// A few columns wide, so it reads as emitters going out in order rather
    /// than a curtain being drawn.
    private func edge(reveal: Double, from side: HorizontalAlignment) -> some View {
        GeometryReader { g in
            let w = g.size.width
            let soft = w * 0.05
            let cut = w * reveal
            Path { p in
                p.addRect(CGRect(
                    x: side == .leading ? 0 : w - cut,
                    y: 0, width: cut, height: g.size.height
                ))
            }
            .fill(.black)
            .blur(radius: soft * 0.5)
        }
    }

    private func arrive() {
        guard !Motion.reduced else {
            outgoing = reading.px
            return
        }
        outgoing = outgoing ?? reading.px
        scanPhase = .blanking
        scan = 0
        withAnimation(.easeIn(duration: 0.18)) { scan = 1 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
            scanPhase = .lighting
            scan = 0
            withAnimation(.easeOut(duration: 0.32)) { scan = 1 }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.32) {
                scanPhase = .idle
                outgoing = reading.px
            }
        }
    }

    private func scheduleHold() {
        let work = DispatchWorkItem {
            guard !moved else { return }
            dragging = nil
            startValue = nil
            onHold()
        }
        holdWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.85, execute: work)
    }

    private func cancelHold() {
        holdWork?.cancel()
        holdWork = nil
    }

    @ViewBuilder private var staleStamp: some View {
        if case .offline(let since) = link {
            Text(since.formatted(date: .omitted, time: .shortened))
                .font(.machine(9))
                .foregroundStyle(Ink.faint)
                .padding(10)
        }
    }
}
