// Evidence for the Home Screen widget, made in the app. Debug builds only.
//
// A widget on the Home Screen runs in a process of its own and cannot be
// screenshotted state by state, so this renders the widget's own views
// (Shared/WallWidgetViews.swift) for every fixture, both sizes, three phone
// classes and five text sizes, and writes PNGs, the fixture frames and a
// manifest to Library/Caches/widget-renders. scripts/qa/render_widgets.py
// collects them and checks them.
//
// The fixtures are also what -widget-snapshot pins into the real store, so
// the Settings page and any widget placed on the simulator's Home Screen show
// the same states. Every fixture that came from a wall is built from a /state
// body through WallFacts, the mapping the app and the widget use, so the
// guest-code fixture tests that mapping rather than restating its answer.

#if DEBUG
import CryptoKit
import SwiftUI
import UIKit
import WidgetKit

struct WidgetFixture {
    let name: String
    let result: WallSnapshot.ReadResult
    /// What the frame is, for the Python side to rebuild and compare:
    /// artwork64, artwork192, lamp64, check64, dark64, clock64, timer64,
    /// timerdone64, weather64 or none.
    let frameSource: String

    static let names = [
        "music", "music-long", "lamp", "music-under-lamp", "weather", "clock", "timer",
        "timer-done", "idle-dark", "away", "off", "panel-check", "connection-check", "guests-cover",
        "stale", "stale-days", "outdated", "queued", "preview", "wall192", "missing", "unreadable",
    ]

    // MARK: Launch hooks

    /// -widget-now <unix> pins the clock, -widget-snapshot <fixture> writes
    /// that fixture into the store and freezes it so neither the app's
    /// session nor the widget paints over it. A fixture pinned without
    /// -widget-now pins the clock at launch, so the picture and the words
    /// beside it describe one moment: a timer's frozen digits and its time
    /// left agree, instead of the countdown running on from the fixture. A
    /// launch without them releases whatever an earlier run pinned.
    static func applyLaunchArguments(_ arguments: [String]) {
        func value(_ flag: String) -> String? {
            guard let i = arguments.firstIndex(of: flag), i + 1 < arguments.count else { return nil }
            return arguments[i + 1]
        }
        let wasFrozen = WallSnapshot.frozen
        let pinned = value("-widget-now").flatMap(Double.init).map { Date(timeIntervalSince1970: $0) }
        WallSnapshot.pinnedNow = pinned ?? (value("-widget-snapshot") != nil ? Date() : nil)
        guard let name = value("-widget-snapshot") else {
            if wasFrozen {
                WallSnapshot.frozen = false
                WidgetCenter.shared.reloadTimelines(ofKind: WallSnapshot.kind)
            }
            return
        }
        guard let fixture = make(name, now: WallSnapshot.now) else {
            print("[widget fixture] unknown fixture \(name)")
            return
        }
        let store = WallSnapshot.Store.shared
        switch fixture.result {
        case .record(let record): store.write(record)
        case .missing: store.debugRemove()
        case .unreadable: store.debugWriteUnreadable()
        }
        WallSnapshot.frozen = true
        WidgetCenter.shared.reloadTimelines(ofKind: WallSnapshot.kind)
    }

    // MARK: Fixtures

    static let song = ["title": "Into the Quiet", "artist": "The Tessera Sessions", "album": "After the Rain"]
    static let longSong = ["title": "Everything Is Beautiful When We Listen Together",
                           "artist": "The Metropolitan Orchestra & the Voices of Tomorrow",
                           "album": "A Collection of Songs for the Long Way Home"]

    /// A /state body with only what the widget reads.
    private static func state(mode: String, display: String? = nil, showing: [String: String] = song,
                              playing: [String: String] = song, extra: [String: Any] = [:]) -> [String: Any] {
        var body: [String: Any] = [
            "mode": mode, "display_mode": display ?? mode,
            "now_showing": showing, "now_playing": playing,
            "display_session": ["active": false],
            "idle_active": NSNull(), "away_active": false,
            "wall": ["width": 64, "height": 64, "tile": 64, "cols": 1, "rows": 1],
        ]
        for (k, v) in extra { body[k] = v }
        return body
    }

    /// A wall's answer turned into a record the way the widget's own read
    /// does it, then aged or relinked as the fixture needs.
    private static func wall(_ json: [String: Any], frame: [UInt8], now: Date, seenAgo: TimeInterval = 30,
                             link: WallSnapshot.Record.Link = .live) -> WallSnapshot.Record {
        let seen = now.addingTimeInterval(-seenAgo)
        var r = WallSnapshot.record(facts: WallFacts(json: json), frame: Data(frame), side: Panel.square(frame.count),
                                    host: "", queued: false, now: seen)
        // Built "at" the moment it was seen, so a timer's end is reckoned
        // from then. Fixtures carry no host, so a widget on the simulator
        // never dials out and paints over them.
        r.link = link
        return r
    }

    static func make(_ name: String, now: Date) -> WidgetFixture? {
        let art = artwork(64)
        let dark = [UInt8](repeating: 0, count: 64 * 64 * 3)
        let lamp = solid(64, (229, 163, 67))
        let check = solid(64, (191, 191, 191))
        func fixture(_ r: WallSnapshot.Record, _ source: String) -> WidgetFixture {
            WidgetFixture(name: name, result: .record(r), frameSource: source)
        }
        switch name {
        case "music":
            return fixture(wall(state(mode: "art"), frame: art, now: now), "artwork64")
        case "music-long":
            return fixture(wall(state(mode: "art", showing: longSong, playing: longSong), frame: art, now: now), "artwork64")
        case "lamp":
            // The last sleeve's title is still in now_showing, and must not
            // name the lamp.
            return fixture(wall(state(mode: "ambient", playing: [:]), frame: lamp, now: now), "lamp64")
        case "music-under-lamp":
            return fixture(wall(state(mode: "ambient"), frame: lamp, now: now), "lamp64")
        // The time and weather faces draw what those faces show, so the
        // evidence pairs "Clock" with digits and "As of 15:12" with the same
        // 15:12 the digits froze at, never with a sleeve.
        case "weather":
            return fixture(wall(state(mode: "weather", showing: [:], playing: [:], extra: ["place": "London"]),
                                frame: weatherFrame(), now: now), "weather64")
        case "clock":
            return fixture(wall(state(mode: "clock", showing: [:], playing: [:]), frame: clockFrame(at: now.addingTimeInterval(-30)),
                                now: now), "clock64")
        case "timer":
            // Seen now, so the frame's 4:42 and the words' "4:42 left" are
            // the same moment. The small widget's "As of" and the medium
            // widget's "Ends" are both reckoned from it.
            return fixture(wall(state(mode: "timer", showing: [:], playing: [:],
                                      extra: ["timer_remaining_s": 282, "timer_state": "counting", "timer_ringing": false]),
                                frame: timerFrame(seconds: 282), now: now, seenAgo: 0), "timer64")
        case "timer-done":
            return fixture(wall(state(mode: "timer", showing: [:], playing: [:],
                                      extra: ["timer_remaining_s": 0, "timer_state": "ringing", "timer_ringing": true]),
                                frame: timerFrame(seconds: 0), now: now), "timerdone64")
        case "idle-dark":
            return fixture(wall(state(mode: "art", display: "off", showing: [:], playing: [:],
                                      extra: ["idle_active": "black"]), frame: dark, now: now), "dark64")
        case "away":
            return fixture(wall(state(mode: "art", display: "off", showing: [:], playing: [:],
                                      extra: ["away_active": true]), frame: dark, now: now), "dark64")
        case "off":
            return fixture(wall(state(mode: "off", showing: [:], playing: [:]), frame: dark, now: now), "dark64")
        case "panel-check":
            return fixture(wall(state(mode: "art", display: "frame",
                                      extra: ["display_session": ["active": true, "purpose": "panel"]]),
                                frame: check, now: now), "check64")
        case "connection-check":
            // The Connection page's glow. "Connection check" holds the
            // widest word of any check title, and is not a song, so it is
            // never cut. From accessibility1 on the 375 and 393 pt phones,
            // and at accessibility2 on 440, that word is wider than the
            // column at the title's full size.
            return fixture(wall(state(mode: "art", display: "frame",
                                      extra: ["display_session": ["active": true, "purpose": "identify"]]),
                                frame: check, now: now), "check64")
        case "guests-cover":
            // What the brain reports during a guest code: display_mode frame,
            // purpose guests, and /frame.raw serving what was up before it.
            return fixture(wall(state(mode: "art", display: "frame",
                                      extra: ["display_session": ["active": true, "purpose": "guests"]]),
                                frame: art, now: now), "artwork64")
        case "stale":
            return fixture(wall(state(mode: "art"), frame: art, now: now, seenAgo: 25 * 60, link: .away), "artwork64")
        case "stale-days":
            return fixture(wall(state(mode: "art"), frame: art, now: now, seenAgo: 3 * 86_400, link: .away), "artwork64")
        case "outdated":
            // Lamp was tapped on the widget and the wall took it. The frame
            // on record is still the sleeve.
            var r = wall(state(mode: "art"), frame: art, now: now, seenAgo: 90)
            r.mode = "ambient"
            r.outdated = true
            return fixture(r, "artwork64")
        case "queued":
            // Off was tapped while the wall was away.
            var r = wall(state(mode: "art"), frame: art, now: now, seenAgo: 20 * 60, link: .away)
            r.mode = "off"
            r.queued = true
            return fixture(r, "artwork64")
        case "preview":
            // The stand-in: this phone's music, drawn on this phone.
            var r = wall(state(mode: "art"), frame: art, now: now, link: .standIn)
            r.source = .phone
            r.seen = nil
            return fixture(r, "artwork64")
        case "wall192":
            var json = state(mode: "art")
            json["wall"] = ["width": 192, "height": 192, "tile": 64, "cols": 3, "rows": 3]
            return fixture(wall(json, frame: artwork(192), now: now), "artwork192")
        case "missing":
            return WidgetFixture(name: name, result: .missing, frameSource: "none")
        case "unreadable":
            return WidgetFixture(name: name, result: .unreadable, frameSource: "none")
        default:
            return nil
        }
    }

    /// scripts/qa/capture_home.py artwork(side), ported line for line.
    /// Python's round() rounds half to even, so this does too, and the two
    /// produce the same bytes (render_widgets.py checks the sha256).
    static func artwork(_ side: Int) -> [UInt8] {
        var px = [UInt8]()
        px.reserveCapacity(side * side * 3)
        for y in 0..<side {
            for x in 0..<side {
                let u = Double(x) / Double(side), v = Double(y) / Double(side)
                let distance = hypot(u - 0.66, v - 0.33)
                let ripple = sin(u * 15 + v * 9) * 3
                let rgb: (Double, Double, Double)
                if distance < 0.235 {
                    rgb = (229 + ripple, 151 + ripple, 65 + ripple)
                } else if v > 0.62 + 0.10 * sin(u * 6.8) {
                    rgb = (17 + ripple, 49 + ripple, 59 + ripple)
                } else if v > 0.49 + 0.055 * sin(u * 9 + 1) {
                    rgb = (33 + ripple, 80 + ripple, 89 + ripple)
                } else {
                    rgb = (184 - 42 * v + ripple, 206 - 40 * v + ripple, 196 - 30 * v + ripple)
                }
                for c in [rgb.0, rgb.1, rgb.2] {
                    px.append(UInt8(max(0, min(255, c.rounded(.toNearestOrEven)))))
                }
            }
        }
        return px
    }

    static func solid(_ side: Int, _ c: (UInt8, UInt8, UInt8)) -> [UInt8] {
        var px = [UInt8]()
        px.reserveCapacity(side * side * 3)
        for _ in 0..<(side * side) { px += [c.0, c.1, c.2] }
        return px
    }

    // MARK: Face frames
    //
    // Integer drawing only, so render_widgets.py builds the same bytes and
    // checks them by sha256. Three by five digits at three pixels a dot.

    private static let glyphs: [Character: [String]] = [
        "0": ["111", "101", "101", "101", "111"], "1": ["010", "110", "010", "010", "111"],
        "2": ["111", "001", "111", "100", "111"], "3": ["111", "001", "111", "001", "111"],
        "4": ["101", "101", "111", "001", "001"], "5": ["111", "100", "111", "001", "111"],
        "6": ["111", "100", "111", "101", "111"], "7": ["111", "001", "001", "001", "001"],
        "8": ["111", "101", "111", "101", "111"], "9": ["111", "101", "111", "001", "111"],
        ":": ["0", "1", "0", "1", "0"], "o": ["111", "101", "111", "000", "000"],
    ]

    /// `text` drawn into a 64 frame, dots `scale` pixels square, one blank
    /// column between glyphs, from (x, y), or centred when x or y is nil.
    private static func draw(_ text: String, into px: inout [UInt8], side: Int, scale: Int,
                             x: Int? = nil, y: Int? = nil, colour c: (UInt8, UInt8, UInt8)) {
        let rows = text.compactMap { glyphs[$0] }
        let units = rows.reduce(0) { $0 + $1[0].count } + max(0, rows.count - 1)
        var left = x ?? (side - units * scale) / 2
        let top = y ?? (side - 5 * scale) / 2
        for glyph in rows {
            for (gy, row) in glyph.enumerated() {
                for (gx, dot) in row.enumerated() where dot == "1" {
                    for dy in 0..<scale {
                        for dx in 0..<scale {
                            let px0 = left + gx * scale + dx, py0 = top + gy * scale + dy
                            guard px0 >= 0, px0 < side, py0 >= 0, py0 < side else { continue }
                            let o = (py0 * side + px0) * 3
                            px[o] = c.0; px[o + 1] = c.1; px[o + 2] = c.2
                        }
                    }
                }
            }
            left += (glyph[0].count + 1) * scale
        }
    }

    /// The clock face at the moment the frame was taken, H:MM on a 24 hour
    /// clock in the harness's time zone.
    static func clockFrame(at date: Date) -> [UInt8] {
        let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
        var px = [UInt8](repeating: 0, count: 64 * 64 * 3)
        draw(String(format: "%d:%02d", parts.hour ?? 0, parts.minute ?? 0), into: &px, side: 64, scale: 3,
             colour: (235, 228, 216))
        return px
    }

    /// The timer face with this much left, M:SS in amber.
    static func timerFrame(seconds: Int) -> [UInt8] {
        var px = [UInt8](repeating: 0, count: 64 * 64 * 3)
        draw(String(format: "%d:%02d", seconds / 60, seconds % 60), into: &px, side: 64, scale: 3,
             colour: (229, 163, 67))
        return px
    }

    /// A sun and a temperature on a night blue ground.
    static func weatherFrame() -> [UInt8] {
        var px = [UInt8]()
        px.reserveCapacity(64 * 64 * 3)
        for y in 0..<64 {
            for x in 0..<64 {
                let dx = x - 20, dy = y - 20
                px += dx * dx + dy * dy <= 90 ? [236, 174, 64] : [10, 18, 34]
            }
        }
        draw("14o", into: &px, side: 64, scale: 3, x: 25, y: 40, colour: (235, 228, 216))
        return px
    }
}

// MARK: - The harness

/// Shown instead of RootView under -widget-render. Renders, writes, and
/// says "Done" when manifest.json, the last file, is on disk.
struct WidgetRenderHarness: View {
    let only: String
    @State private var progress = "Starting"
    @State private var finished = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Widget renders").font(.ui(22, .semibold))
            Text(progress).font(.machine(11)).foregroundStyle(Ink.dim)
                .accessibilityIdentifier("widgets.render.status")
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Ink.ground)
        .foregroundStyle(Ink.ink)
        .task { await run() }
    }

    private struct PhoneClass {
        let name: String
        let screen: CGSize
    }

    /// The table sizes, not measured ones, so every run renders the same.
    /// 375 is the narrowest column the keys and labels must fit.
    private static let classes = [PhoneClass(name: "375", screen: CGSize(width: 375, height: 812)),
                                  PhoneClass(name: "393", screen: CGSize(width: 393, height: 852)),
                                  PhoneClass(name: "440", screen: CGSize(width: 440, height: 956))]
    /// accessibility1 is the first size at which a fixture's title word
    /// ("Connection") outgrows the narrow columns, so it is rendered too.
    private static let types: [(String, DynamicTypeSize)] = [("large", .large), ("xxxLarge", .xxxLarge),
                                                             ("accessibility1", .accessibility1),
                                                             ("accessibility2", .accessibility2),
                                                             ("accessibility5", .accessibility5)]

    @MainActor private func run() async {
        let names = only == "all" ? WidgetFixture.names
            : only.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        let now = WallSnapshot.pinnedNow ?? Date()
        let files = FileManager.default
        let root = files.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("widget-renders")
        try? files.removeItem(at: root)
        try? files.createDirectory(at: root, withIntermediateDirectories: true)

        var renders: [[String: Any]] = []
        var frames: [[String: Any]] = []
        var capped = true
        for (i, name) in names.enumerated() {
            guard let fixture = WidgetFixture.make(name, now: now) else { continue }
            progress = "Rendering \(name), \(i + 1) of \(names.count)"
            await Task.yield()
            let folder = root.appendingPathComponent(name)
            try? files.createDirectory(at: folder, withIntermediateDirectories: true)
            let reading = WidgetReading(result: fixture.result, now: now, liveTimer: false)
            var record: WallSnapshot.Record?
            if case .record(let r) = fixture.result { record = r }

            var frameEntry: [String: Any] = ["fixture": name, "source": fixture.frameSource]
            if let frame = record?.frame, let side = Panel.square(frame) {
                frameEntry["side"] = side
                frameEntry["sha256"] = Self.sha256(frame)
                if let png = Self.framePNG([UInt8](frame), side: side) {
                    try? png.write(to: folder.appendingPathComponent("frame.png"))
                    frameEntry["png"] = "\(name)/frame.png"
                    frameEntry["png_sha256"] = Self.sha256(png)
                }
            }
            frames.append(frameEntry)

            for family in WallWidgetFamily.allCases {
                for phone in Self.classes {
                    let size = WidgetMetrics.size(family: family, screen: phone.screen)
                    var capShas: [String: String] = [:]
                    for (typeName, type) in Self.types {
                        guard let png = Self.render(reading: reading, record: record, family: family,
                                                    size: size, type: type) else { continue }
                        let file = "\(name)/\(family.rawValue)-\(phone.name)-\(typeName).png"
                        try? png.write(to: root.appendingPathComponent(file))
                        let sha = Self.sha256(png)
                        capShas[typeName] = sha
                        let effective = min(type, .accessibility2)
                        var entry: [String: Any] = [
                            "fixture": name, "family": family.rawValue, "class": phone.name,
                            "size_pt": [size.width, size.height], "dynamic_type": typeName,
                            "png": file, "sha256": sha, "frame_sha256": frameEntry["sha256"] ?? NSNull(),
                            "status": reading.status ?? NSNull(), "chip": reading.chip ?? NSNull(),
                            "title": reading.title, "subtitle": reading.subtitle ?? NSNull(),
                            "accessibility": reading.accessibility, "now": now.timeIntervalSince1970,
                        ]
                        entry["keeps_subtitle"] = reading.keepsSubtitle
                        entry["keys_inert"] = reading.keysInert
                        if family == .small, let chip = reading.chip {
                            // The room the widget offers the chip's words, at
                            // the size the chip stops growing at.
                            entry["chip_fits"] = Self.labelFits(chip, width: WidgetType.chipWords(width: size.width),
                                                                type: min(type, WidgetType.chipCap))
                        }
                        if family == .medium {
                            for (key, value) in Self.mediumFits(reading, size: size, type: effective) {
                                entry[key] = value
                            }
                        }
                        renders.append(entry)
                        await Task.yield()
                    }
                    // The views cap type at accessibility2, so AX5 must be
                    // the same picture, byte for byte.
                    if capShas["accessibility5"] != capShas["accessibility2"] { capped = false }
                }
            }
        }

        let manifest: [String: Any] = [
            "now": now.timeIntervalSince1970,
            "timezone": TimeZone.current.identifier,
            "locale": Locale.current.identifier,
            "scale": 3,
            "mask": "The rounded corner is the harness's (22 pt continuous), not the system's.",
            "fixtures": names,
            "frames": frames,
            "renders": renders,
            "ax5_matches_ax2": capped,
        ]
        if let data = try? JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: root.appendingPathComponent("manifest.json"), options: .atomic)
        }
        progress = "Done, \(renders.count) renders"
        finished = true
    }

    @MainActor private static func render(reading: WidgetReading, record: WallSnapshot.Record?,
                                          family: WallWidgetFamily, size: CGSize, type: DynamicTypeSize) -> Data? {
        let frame = record?.frame
        let side = record?.side
        let view = WidgetCanvas(size: size) {
            switch family {
            case .small: WallWidgetSmall(reading: reading, frame: frame, side: side)
            case .medium: WallWidgetMedium(reading: reading, frame: frame, side: side, interactive: true)
            }
        }
        // ImageRenderer's scale does not reach the view's displayScale, and
        // the panel rasters at displayScale, so both are set.
        .environment(\.displayScale, 3)
        .environment(\.dynamicTypeSize, type)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 3
        renderer.proposedSize = ProposedViewSize(size)
        return renderer.uiImage?.pngData()
    }

    // MARK: Fit checks
    //
    // Each check lays the words out with the numbers the view itself uses
    // (WidgetType), so a pass means the view never has to cut them. The
    // labels and keys are checked at the smallest size the view allows
    // them. The medium widget's words are not modelled: the harness
    // measures the view's own MediumWordsBlock for each choice in
    // MediumWordsFit.order, as ViewThatFits measures them, and then checks
    // by pixels that MediumWords drawn in the same room is the block it
    // picked. A word wider than its line would be broken mid-word, which
    // never counts as fitting. labelFits and mediumFits are internal so a
    // standalone simulator tool can run the same checks without the app.

    /// How a text lays out: its height at a width, the lines that makes,
    /// and whether its widest word fits the width.
    private struct TextFit {
        let height: CGFloat
        let lines: Int
        let wordsFit: Bool
    }

    /// kerning for the Martian labels, tracking for the Technor title, as
    /// the views set them. SwiftUI ignores kerning when both are set.
    /// slack is how far the widest word may run past the width and still
    /// fit. The title's step is picked with none, as ViewThatFits picks it.
    @MainActor private static func measure(_ text: String, face: String, size: CGFloat, relativeTo style: Font.TextStyle,
                                           kerning: CGFloat? = nil, tracking: CGFloat? = nil,
                                           width: CGFloat, type: DynamicTypeSize, slack: CGFloat = 0.5) -> TextFit {
        let font = Font.custom(face, size: size, relativeTo: style)
        func laid(_ s: String, width: CGFloat?) -> CGSize {
            var t = Text(s).font(font)
            if let kerning { t = t.kerning(kerning) }
            if let tracking { t = t.tracking(tracking) }
            let view = t
                .fixedSize(horizontal: width == nil, vertical: true)
                .frame(width: width, alignment: .leading)
                .environment(\.dynamicTypeSize, type)
            let r = ImageRenderer(content: view)
            r.scale = 3
            r.proposedSize = ProposedViewSize(width: width, height: nil)
            guard let image = r.cgImage else { return .zero }
            return CGSize(width: CGFloat(image.width) / 3, height: CGFloat(image.height) / 3)
        }
        let line = laid("A", width: nil).height
        let height = laid(text, width: width).height
        let widest = text.split(whereSeparator: \.isWhitespace).map { laid(String($0), width: nil).width }.max() ?? 0
        guard line > 0 else { return TextFit(height: height, lines: .max, wordsFit: false) }
        return TextFit(height: height, lines: Int((height / line).rounded()), wordsFit: widest <= width + slack)
    }

    /// A view's height at a width, as the widget lays it out and as
    /// ViewThatFits(in: .vertical) weighs it: its ideal height there.
    @MainActor private static func height<V: View>(_ view: V, width: CGFloat, type: DynamicTypeSize) -> CGFloat {
        let r = ImageRenderer(content: view.frame(width: width).environment(\.dynamicTypeSize, type))
        r.scale = 3
        r.proposedSize = ProposedViewSize(width: width, height: nil)
        return CGFloat(r.cgImage?.height ?? 0) / 3
    }

    /// A view drawn in exactly the room the widget offers it: its pixels,
    /// to tell which choice it drew, and its height, to tell whether that
    /// choice fits.
    @MainActor private static func drawn<V: View>(_ view: V, width: CGFloat, height: CGFloat,
                                                  type: DynamicTypeSize) -> (png: Data, height: CGFloat)? {
        let r = ImageRenderer(content: view.frame(width: width).environment(\.dynamicTypeSize, type))
        r.scale = 3
        r.proposedSize = ProposedViewSize(width: width, height: height)
        guard let image = r.cgImage, let png = UIImage(cgImage: image).pngData() else { return nil }
        return (png, CGFloat(image.height) / 3)
    }

    /// The chip and the status line: two lines at WidgetType.labelMinScale,
    /// the last thing WidgetLabelText tries.
    @MainActor static func labelFits(_ text: String, width: CGFloat, type: DynamicTypeSize) -> Bool {
        let scale = WidgetType.labelMinScale
        let fit = measure(text.uppercased(), face: WidgetType.labelFace, size: WidgetType.labelSize * scale,
                          relativeTo: .caption2, kerning: 0.6 * scale, width: width, type: type)
        return fit.wordsFit && fit.lines <= WidgetType.labelLines
    }

    /// What WordFitText sets for this text, from its own list of choices:
    /// the whole of it, or the longest whole-word prefix and an ellipsis,
    /// or the whole of it at the first of its steps, that fits `lines`
    /// lines with no word wider than the width. Nil when none does.
    @MainActor static func wordFitChoice(_ text: String, face: String, size: CGFloat, relativeTo style: Font.TextStyle,
                                         tracking: CGFloat? = nil, width: CGFloat, lines: Int, ellipsis: Bool = true,
                                         shortens: Bool = true, telling: Bool = false, steps: [CGFloat] = [1],
                                         type: DynamicTypeSize) -> (text: String, height: CGFloat, lines: Int, step: CGFloat)? {
        let choices = WordFitText.choices(text, ellipsis: ellipsis, shortens: shortens, telling: telling, steps: steps)
        for choice in choices {
            let fit = measure(WordFit.display(choice.text), face: face, size: size * choice.step, relativeTo: style,
                              tracking: tracking.map { $0 * choice.step }, width: width, type: type)
            if fit.wordsFit && fit.lines <= lines { return (choice.text, fit.height, fit.lines, choice.step) }
        }
        return nil
    }

    /// The medium widget's column: the status line and each key's word,
    /// the title's step (the first of WidgetType.titleSizes at which its
    /// widest word fits the column), then the words as the view sets them
    /// in the room the keys leave: which of MediumWordsFit.order it takes,
    /// whether that fits, which title a song ends on, and which subtitle
    /// is shown.
    @MainActor static func mediumFits(_ reading: WidgetReading, size: CGSize, type: DynamicTypeSize) -> [String: Any] {
        // The column beside a square panel, less its padding.
        let column = CGSize(width: size.width - size.height - 28, height: size.height - 28)
        var out: [String: Any] = [:]
        var room = column.height

        if let status = reading.status {
            // Its last choice: two lines, the symbol stepped down with them.
            let symbolWidth = measureWidth(WidgetStatusSymbol(symbol: reading.statusSymbol, step: WidgetType.labelMinScale),
                                           type: type)
            out["status_fits"] = labelFits(status, width: column.width - symbolWidth - WidgetType.symbolGap, type: type)
            out["status_pt"] = Double(height(WidgetStatusLine(text: status, symbol: reading.statusSymbol),
                                             width: column.width, type: type))
        }

        if reading.showsKeys {
            let keyType = min(type, WidgetType.keyCap)
            // Three keys 6 pt apart, each padded 4 pt a side. Semibold, the
            // selected key's face, is the wider of the two. The keys share
            // the first step at which all three words fit.
            let keyWidth = (column.width - 12) / 3 - 8
            func cut(_ step: CGFloat) -> [String] {
                ["Art", "Lamp", "Off"].filter { word in
                    let fit = measure(word, face: WidgetType.keySelectedFace, size: WidgetType.keySize * step,
                                      relativeTo: .caption, width: keyWidth, type: keyType)
                    return !(fit.wordsFit && fit.lines <= 1)
                }
            }
            let scale = WidgetType.keySteps.first { cut($0).isEmpty }
            out["key_fits"] = scale != nil
            out["key_scale"] = scale.map { Double($0) } ?? NSNull()
            if scale == nil { out["key_cut"] = cut(WidgetType.keyMinScale) }
            // The words are offered what the keys and the gap above them
            // leave.
            room -= height(WidgetKeyRow(reading: reading, interactive: false), width: column.width, type: type) + 8
        }
        out["words_room_pt"] = Double(room)

        // The title's size, as the view picks it: the first of its sizes at
        // which its widest word fits the column.
        func title(_ step: CGFloat) -> TextFit {
            measure(WordFit.display(reading.title), face: WidgetType.titleFace, size: WidgetType.titleSize * step,
                    relativeTo: .headline, tracking: -0.3 * step, width: column.width, type: type, slack: 0)
        }
        let step = WidgetType.titleSizes(from: 1).first { title($0).wordsFit }
        out["title_is_song"] = reading.titleIsSong
        out["title_words_fit"] = step != nil
        out["title_scale"] = step.map { Double($0) } ?? NSNull()

        // The words: the first choice whose block, the view's own, fits the
        // room at its ideal height, else the last. That is how
        // ViewThatFits(in: .vertical) picks.
        let order = step.map { MediumWordsFit.order(reading, step: $0, hasSubtitle: reading.hasSubtitle) } ?? [.squeezed]
        let heights = order.map { height(MediumWordsBlock(reading: reading, fit: $0), width: column.width, type: type) }
        let taken = heights.firstIndex { $0 <= room + 0.01 } ?? order.count - 1
        let fit = order[taken]
        out["words_tried"] = taken + 1
        out["words_pt"] = Double(heights[taken])

        // Then the proof: MediumWords drawn in the room is that block, pixel
        // for pixel, and fits it.
        let words = drawn(MediumWords(reading: reading), width: column.width, height: room, type: type)
        let block = drawn(MediumWordsBlock(reading: reading, fit: fit), width: column.width, height: room, type: type)
        out["words_match_view"] = words != nil && words?.png == block?.png
        // A control on the proof: when an earlier choice was passed over,
        // its pixels must differ from what was drawn.
        if taken > 0 {
            let first = drawn(MediumWordsBlock(reading: reading, fit: order[0]), width: column.width, height: room, type: type)
            out["words_proof_discriminates"] = first != nil && first?.png != words?.png
        }
        out["words_fit"] = words.map { $0.height <= room + 0.5 } ?? false
        out["words_drawn_pt"] = words.map { Double($0.height) } ?? NSNull()
        // Drawn in the room, the block keeps its own height: nothing in it
        // was squeezed or cut to make it fit.
        out["words_whole"] = words.map { abs($0.height - heights[taken]) <= 0.5 } ?? false

        // What the chosen block sets, in words.
        let smallest = WidgetType.titleSizes(from: 1).last ?? WidgetType.titleShrinkScale
        func song(_ lines: Int, _ s: CGFloat) -> (text: String, height: CGFloat, lines: Int, step: CGFloat)? {
            wordFitChoice(reading.title, face: WidgetType.titleFace, size: WidgetType.titleSize * s, relativeTo: .headline,
                          tracking: -0.3 * s, width: column.width, lines: lines, type: type)
        }
        /// The subtitle as it is set: its choice, or, when none fits and
        /// the reading keeps it, the whole of its last choice shrunk onto
        /// one line.
        func subtitleShown(face: String, size: CGFloat, relativeTo style: Font.TextStyle, tracking: CGFloat? = nil,
                           telling: Bool, steps: [CGFloat]) -> (text: String, fits: Bool, step: CGFloat)? {
            guard let subtitle = reading.subtitle else { return nil }
            if let choice = wordFitChoice(subtitle, face: face, size: size, relativeTo: style, tracking: tracking,
                                          width: column.width, lines: reading.subtitleLines, ellipsis: !reading.timed,
                                          shortens: reading.subtitleShortens, telling: telling, steps: steps, type: type) {
                return (choice.text, true, choice.step)
            }
            guard reading.keepsSubtitle,
                  let last = WordFitText.choices(subtitle, ellipsis: !reading.timed, shortens: reading.subtitleShortens,
                                                 telling: telling, steps: steps).last else { return nil }
            let scale = last.step * 0.4
            let shrunk = measure(WordFit.display(last.text), face: face, size: size * scale, relativeTo: style,
                                 tracking: tracking.map { $0 * scale }, width: column.width, type: type)
            return (last.text, shrunk.wordsFit && shrunk.lines <= 1, scale)
        }
        let face = reading.timed ? WidgetType.labelFace : WidgetType.subtitleFace
        func plainSubtitle() -> (text: String, fits: Bool, step: CGFloat)? {
            subtitleShown(face: face, size: WidgetType.subtitleSize, relativeTo: .caption, telling: !reading.timed,
                          steps: reading.keepsSubtitle ? WidgetType.subtitleSteps : [1])
        }

        var titleShown: (text: String, height: CGFloat, lines: Int, step: CGFloat)?
        var sub: (text: String, fits: Bool, step: CGFloat)?
        var subLayout: String?
        switch fit {
        case .song(let lines, let s, let withSubtitle):
            titleShown = song(lines, s)
            out["words_layout"] = "song \(lines) line\(lines == 1 ? "" : "s") at \(s)\(withSubtitle ? " with subtitle" : "")"
            if withSubtitle { sub = plainSubtitle() }
            subLayout = sub != nil ? "with title" : "dropped"
        case .natural(let s, let withSubtitle):
            let t = title(s)
            titleShown = (reading.title, t.height, t.lines, s)
            out["words_layout"] = "natural at \(s)\(withSubtitle ? " with subtitle" : "")"
            if withSubtitle { sub = plainSubtitle() }
            subLayout = sub != nil ? "with title" : "dropped"
        case .promoted(let s):
            out["words_layout"] = "subtitle as title at \(s)"
            sub = subtitleShown(face: WidgetType.titleFace, size: WidgetType.titleSize * s, relativeTo: .headline,
                                tracking: -0.3 * s, telling: false, steps: [1])
            subLayout = sub != nil ? "promoted" : "dropped"
        case .squeezed:
            out["words_layout"] = "squeezed"
            if reading.titleIsSong {
                titleShown = song(1, smallest)
            } else {
                let t = measure(WordFit.display(reading.title), face: WidgetType.titleFace,
                                size: WidgetType.titleSize * smallest * 0.4, relativeTo: .headline,
                                tracking: -0.3 * smallest * 0.4, width: column.width, type: type)
                titleShown = t.wordsFit && t.lines <= 1 ? (reading.title, t.height, 1, smallest * 0.4) : nil
            }
            if reading.keepsSubtitle { sub = plainSubtitle() }
            subLayout = sub != nil ? "with title" : "dropped"
        }

        // Whether the view drew a subtitle at all: the block against the
        // same block without one. The words above say which text it is.
        var bare: MediumWordsFit?
        switch fit {
        case .song(let lines, let s, true): bare = .song(lines: lines, step: s, subtitle: false)
        case .natural(let s, true): bare = .natural(step: s, subtitle: false)
        default: bare = nil
        }
        if let bare, reading.subtitle != nil {
            let drawnSubtitle = heights[taken] - height(MediumWordsBlock(reading: reading, fit: bare),
                                                        width: column.width, type: type) > 1
            out["subtitle_drawn"] = drawnSubtitle
            out["subtitle_model_matches"] = drawnSubtitle == (sub != nil)
        }

        if reading.titleIsSong {
            out["title_text"] = titleShown?.text ?? NSNull()
            out["title_lines"] = titleShown?.lines ?? NSNull()
            // The title wins: an artist sits only beside a title that is
            // whole or takes its two lines. A subtitle the reading keeps
            // (a picture's age, a change) is not an artist, and stays.
            if reading.subtitle != nil && !reading.keepsSubtitle && subLayout == "with title" {
                out["title_before_artist"] = titleShown.map { $0.text == reading.title || $0.lines >= WidgetType.songLines } ?? false
            }
        } else {
            // Never cut, and within the room.
            out["title_fits"] = step != nil && titleShown != nil && (out["words_fit"] as? Bool) == true
                && (out["words_whole"] as? Bool) == true
        }
        out["keeps_subtitle"] = reading.keepsSubtitle
        out["timed"] = reading.timed
        out["subtitle_lines_allowed"] = reading.subtitleLines
        if reading.subtitle != nil {
            out["subtitle_layout"] = subLayout ?? "dropped"
            out["subtitle_text"] = sub?.text ?? NSNull()
            out["subtitle_scale"] = sub.map { Double($0.step) } ?? NSNull()
            out["subtitle_fits"] = sub?.fits ?? true
            out["subtitle_whole"] = sub?.text == reading.subtitle
        } else {
            out["subtitle_layout"] = NSNull()
        }
        return out
    }

    @MainActor private static func measureWidth<V: View>(_ view: V, type: DynamicTypeSize) -> CGFloat {
        let r = ImageRenderer(content: view.fixedSize().environment(\.dynamicTypeSize, type))
        r.scale = 3
        return CGFloat(r.cgImage?.width ?? 0) / 3
    }

    /// The frame at 8x for 64 and 3x for 192, nearest neighbour: what the
    /// wall was sent, big enough to see.
    private static func framePNG(_ px: [UInt8], side: Int) -> Data? {
        let k = side <= 64 ? 8 : 3
        let out = side * k
        var rgba = [UInt8](repeating: 255, count: out * out * 4)
        for y in 0..<out {
            for x in 0..<out {
                let s = ((y / k) * side + (x / k)) * 3
                let d = (y * out + x) * 4
                rgba[d] = px[s]; rgba[d + 1] = px[s + 1]; rgba[d + 2] = px[s + 2]
            }
        }
        guard let image = EmitterRaster.image(side: out, rgba: rgba) else { return nil }
        return UIImage(cgImage: image).pngData()
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
#endif
