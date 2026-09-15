// The wall's ears, as a page.
//
// Built from the object. The object is a microphone in a room, so the page
// is a level meter first: the room's loudness, live, with the quiet floor
// marked on it and the gate as a mark you drag along the same rail, above
// the floor and below the music. Under it, in words, what the ear is doing
// and what it heard, with where in the song the record is. The numbers that
// decide how it listens come last; they are the wall's own tuning knobs, so
// the wall describes them and the page draws what it is told.

import SwiftUI

struct HearingPage: View {
    @Environment(WallSession.self) private var wall
    let accent: Color
    @Binding var services: WallServices?

    @State private var store = TuningStore()
    /// While a finger is down, the number shown is the finger's.
    @State private var dragging: [String: Double] = [:]
    /// The knob under a thumb: its note is the only one on screen.
    @State private var touching: String?
    @State private var lastSent: [String: Date] = [:]
    /// The wall's own song library, read from /teach while the page is up.
    @State private var taught: TaughtList?
    @State private var forgetting: String?

    private var ears: WallServices.Hearing? { services?.hearing }

    private let blurb = "A microphone on the wall, read all the time. When the room is louder than the gate, the last few seconds are named by Shazam: a record, the TV, a speaker on any app. No account and no key."

    var body: some View {
        SetupPage("The wall's ears", blurb: blurb) {
            SetupGroup("The room", note: roomNote) {
                RoomMeter(level: ears?.level_db, floor: ears?.floor_db,
                          gate: dragging["room_gate"] ?? gateValue,
                          open: ears?.gate_open == true, accent: accent) { db, live in
                    setGate(db, live: live)
                }
                Rule()
                stateRow
                if let heard = ears?.heard {
                    Rule()
                    heardRow(heard)
                } else if let faint = ears?.pending {
                    Rule()
                    pastRow(faint, lead: "Heard faintly",
                            detail: "No catalogue record behind it, so it waits to be heard again before it goes on the wall."
                                + (faint.heard_s.map { " First heard \(ago($0))." } ?? ""))
                } else if let last = ears?.last_heard {
                    Rule()
                    pastRow(last, lead: "Last on the wall", detail: lastDetail(last))
                }
            }
            .padding(.top, -12)

            if let recent = ears?.recent, !recent.isEmpty {
                SetupGroup("Named lately", note: nil) {
                    ForEach(Array(recent.enumerated()), id: \.offset) { i, r in
                        if i > 0 { Rule() }
                        recentRow(r)
                    }
                }
            }

            SetupGroup("The switch", note: "Two knocks on the frame, alone, turn the wall off and bring it back. A whistle bending up is on, bending down is off. The microphone hears both through the board; every candidate is written to the wall's log with its numbers.") {
                toggle("knock")
                Rule()
                knob("knock_sensitivity")
                Rule()
                toggle("whistle")
                if let k = ears?.knock {
                    Rule()
                    fact("Heard", switchLine(k))
                }
            }

            SetupGroup("Taught songs", note: taughtNote) {
                toggle("teach")
                Rule()
                toggle("teach_by_ear")
                Rule()
                knob("teach_match_score")
                if let learning = ears?.teacher?.learning {
                    Rule()
                    fact("Learning now", learning)
                }
                if let songs = taught?.songs, !songs.isEmpty {
                    ForEach(songs, id: \.id) { song in
                        Rule()
                        taughtRow(song)
                    }
                }
            }

            SetupGroup("Microphone", note: "Gain is the microphone's own. Auto gain off keeps the meter and the gate honest; with it on, a quiet room is slowly turned up.") {
                toggle("hearing")
                Rule()
                fact("Microphone", ears?.mic ?? "None found yet", warn: ears?.mic == nil)
                Rule()
                knob("mic_gain")
                Rule()
                toggle("mic_auto_gain")
            }

            SetupGroup("Timing", note: "All seconds. Every miss makes the next clip longer on its own, up to twelve seconds, which is what a TV over the music needs.") {
                knob("listen_for")
                Rule()
                knob("listen_again_every")
                Rule()
                knob("quiet_before_letting_go")
                Rule()
                knob("retry_after_miss")
                Rule()
                knob("keep_through_noise")
            }

            Problem(text: store.problem ?? ears?.problem)
        }
        .task { await store.load(host: wall.host) }
        .task {
            // The meter is live only while this page is up.
            while !Task.isCancelled {
                if let fresh = await WallServices.read(host: wall.host) { services = fresh }
                try? await Task.sleep(for: .milliseconds(600))
            }
        }
        .task {
            // the library changes when a song is learnt or forgotten: rarely
            while !Task.isCancelled {
                if let list = await TaughtList.read(host: wall.host) { taught = list }
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    // MARK: The switch and the taught songs

    private func switchLine(_ k: WallServices.Hearing.Knock) -> String {
        var parts: [String] = []
        if let d = k.knocks?.doubles, d > 0 { parts.append(d == 1 ? "one double knock" : "\(d) double knocks") }
        if let c = k.knocks?.candidates, c > 0 { parts.append("\(c) knock\(c == 1 ? "" : "s")") }
        if let w = k.whistles?.count, w > 0 { parts.append("\(w) whistle\(w == 1 ? "" : "s")") }
        return parts.isEmpty ? "Nothing yet" : parts.joined(separator: ", ")
    }

    private var taughtNote: String {
        guard let t = taught else { return "Songs the wall knows on its own, asked before Shazam." }
        if t.songs.isEmpty {
            return "None yet. The wall learns a song's preview when another source names it and the ear keeps missing it, and learns the room's own hearing of a song after fifteen loud seconds."
        }
        let n = t.songs.count
        return "\(n) song\(n == 1 ? "" : "s"), \(t.landmarks ?? 0) landmarks, asked before Shazam."
    }

    private func taughtRow(_ song: TaughtList.Song) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(song.title).font(.ui(15)).foregroundStyle(Ink.ink).lineLimit(1)
                Text(song.artist + "  ·  " + howLine(song)).font(.ui(12)).foregroundStyle(Ink.dim).lineLimit(1)
            }
            Spacer(minLength: 8)
            ActionPill(title: forgetting == song.id ? "Forgetting" : "Forget", filled: false) {
                forget(song.id)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 9)
    }

    private func howLine(_ song: TaughtList.Song) -> String {
        let how = song.how.map { $0 == "preview" ? "preview" : $0 == "ear" ? "the room" : "by name" }
        var line = "from " + how.joined(separator: " and ")
        if song.matched > 0 { line += ", named \(song.matched)x" }
        return line
    }

    private func forget(_ id: String) {
        guard forgetting == nil else { return }
        forgetting = id
        let h = wall.host
        Task {
            _ = await TaughtList.forget(host: h, id: id)
            if let list = await TaughtList.read(host: h) { taught = list }
            forgetting = nil
            Taps.commit()
        }
    }

    // MARK: The room

    private var gateValue: Double {
        store.values["room_gate"] ?? ears?.gate_db ?? -52
    }

    private var roomNote: String {
        var s = "Drag the mark to set the gate: above the quiet floor, below the music."
        if let l = ears?.level_db, let f = ears?.floor_db {
            s += String(format: " The room reads %.0f dB now; its quiet floor lately is %.0f.", l, f)
        }
        return s
    }

    private func setGate(_ db: Double, live: Bool) {
        let v = db.rounded()
        if live {
            dragging["room_gate"] = v
            throttled("room_gate") { Task { await store.send("room_gate", v) } }
        } else {
            dragging["room_gate"] = nil
            Task { await store.send("room_gate", v) }
            Taps.commit()
        }
    }

    private var stateRow: some View {
        HStack(spacing: 10) {
            Circle().fill(stateColor).frame(width: 8, height: 8)
            Text(stateWords)
                .font(.ui(15)).foregroundStyle(Ink.ink)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            if let a = ears?.attempts, let m = ears?.matches, a > 0 {
                Text("named \(m) of \(a)").font(.machine(12)).foregroundStyle(Ink.faint)
                    .accessibilityLabel("\(m) named out of \(a) asked")
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 13)
        .frame(minHeight: 56)
    }

    private var stateWords: String {
        guard let h = ears else { return "The wall is not answering." }
        if !h.on { return "Off." }
        let w = Int(h.window_s ?? 6)
        switch h.state {
        case "no_tools": return "The wall is missing its listening tools."
        case "no_mic": return "No microphone on the wall."
        case "quiet": return "Quiet. Nothing above the gate."
        case "listening":
            if let l = h.loud_s, l < w { return "Listening, \(l) s of \(w)." }
            if let m = h.misses, m > 0 {
                return "Nothing named after \(m) \(m == 1 ? "try" : "tries"). Next clip \(w) s."
            }
            return "Listening."
        case "asking": return "Asking Shazam about the last \(w) s."
        case "heard": return "Heard. Checking again as it goes."
        case "faint": return "Heard something faintly. Listening for it again."
        default: return h.state
        }
    }

    private var stateColor: Color {
        guard let h = ears, h.on else { return Ink.faint }
        if let p = h.problem, !p.isEmpty { return Ink.signal }
        switch h.state {
        case "heard": return Ink.moss
        case "listening", "asking", "faint": return Ink.tile
        default: return Ink.faint
        }
    }

    // MARK: What it heard before

    private func pastRow(_ p: WallServices.Hearing.Past, lead: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(lead.uppercased()).font(.machine(10)).foregroundStyle(Ink.faint).kerning(0.8)
            Text(p.title).font(.ui(16)).foregroundStyle(Ink.ink).lineLimit(2)
            Text(p.album.isEmpty || p.album == "?" ? p.artist : "\(p.artist), \(p.album)")
                .font(.ui(13)).foregroundStyle(Ink.dim).lineLimit(1)
            Text(detail).font(.ui(12)).foregroundStyle(Ink.dim)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16).padding(.vertical, 13)
    }

    private func lastDetail(_ p: WallServices.Hearing.Past) -> String {
        var s = p.named_s.map { "Named \(ago($0))." } ?? ""
        if let e = p.ended_s {
            s += " Let go \(ago(e))" + (p.why.map { ": \($0)." } ?? ".")
        }
        return s
    }

    private func recentRow(_ r: WallServices.Hearing.Past) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(r.title).font(.ui(15)).foregroundStyle(Ink.ink).lineLimit(1)
                Text(r.artist).font(.ui(12)).foregroundStyle(Ink.dim).lineLimit(1)
            }
            Spacer(minLength: 8)
            Text((r.ago_s.map { ago($0) } ?? "") + ((r.times ?? 1) > 1 ? "  x\(r.times!)" : ""))
                .font(.machine(11)).foregroundStyle(Ink.faint)
        }
        .padding(.horizontal, 16).padding(.vertical, 11)
    }

    private func ago(_ s: Int) -> String {
        if s < 60 { return "\(s) s ago" }
        if s < 3600 { return "\(s / 60) min ago" }
        return "\(s / 3600) h ago"
    }

    private func heardRow(_ h: WallServices.Hearing.Heard) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(h.title).font(.ui(16)).foregroundStyle(Ink.ink).lineLimit(2)
            Text(h.album.isEmpty || h.album == "?" ? h.artist : "\(h.artist), \(h.album)")
                .font(.ui(13)).foregroundStyle(Ink.dim).lineLimit(1)
            HStack(spacing: 12) {
                if let at = h.at_s {
                    Text(clock(at) + (h.length_s.map { " of " + clock($0) } ?? "") + " in")
                        .font(.machine(12)).foregroundStyle(accent)
                }
                if let s = ears?.heard_s {
                    Text("named \(s) s ago").font(.machine(12)).foregroundStyle(Ink.faint)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16).padding(.vertical, 13)
    }

    private func clock(_ s: Int) -> String { String(format: "%d:%02d", s / 60, s % 60) }

    private func fact(_ name: String, _ value: String, warn: Bool = false) -> some View {
        SetupRow(title: name, subtitle: nil) {
            Text(value).font(.ui(14)).foregroundStyle(warn ? Ink.signal : Ink.dim)
                .multilineTextAlignment(.trailing)
        }
    }

    // MARK: The wall's own knobs, drawn as the wall describes them

    private func spec(_ name: String) -> Knob? {
        store.knobs.first { $0.name == name }
    }

    @ViewBuilder private func toggle(_ name: String) -> some View {
        if let k = spec(name) {
            let current = store.values[name] ?? 0
            VStack(alignment: .leading, spacing: 6) {
                Toggle(isOn: Binding(get: { current > 0.5 }, set: { on in
                    touching = name
                    Task { await store.send(name, on ? 1 : 0, isBool: true) }
                    Taps.detent(intensity: 0.4)
                })) {
                    Text(k.title).font(.ui(15)).foregroundStyle(Ink.ink)
                }
                .tint(accent)
                if touching == name { noteLine(k.note) }
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
        }
    }

    @ViewBuilder private func knob(_ name: String) -> some View {
        if let k = spec(name) {
            let current = store.values[name] ?? k.min
            let shown = dragging[name] ?? current
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text(k.title).font(.ui(15)).foregroundStyle(Ink.ink)
                    Spacer()
                    Text(text(shown, step: k.step)).font(.machine(14)).foregroundStyle(accent)
                    if let d = store.defaults[name], abs(d - current) > 1e-6 {
                        Text(text(d, step: k.step)).font(.machine(11))
                            .foregroundStyle(Ink.faint).strikethrough()
                    }
                }
                Slider(value: Binding(get: { shown }, set: { raw in
                    let v = (raw / k.step).rounded() * k.step
                    dragging[name] = v
                    throttled(name) { Task { await store.send(name, v) } }
                }), in: k.min...k.max, step: k.step) { editing in
                    if editing {
                        touching = name
                    } else if let v = dragging[name] {
                        Task { await store.send(name, v) }
                        dragging[name] = nil
                        Taps.commit()
                    }
                }
                .tint(accent)
                if touching == name, !k.note.isEmpty { noteLine(k.note) }
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
        }
    }

    private func noteLine(_ note: String) -> some View {
        Text(note).font(.ui(12)).foregroundStyle(Ink.dim)
            .fixedSize(horizontal: false, vertical: true)
            .transition(.opacity)
    }

    /// The wall applies a knob per change; a drag would ask for sixty.
    private func throttled(_ key: String, _ go: () -> Void) {
        let now = Date()
        if let last = lastSent[key], now.timeIntervalSince(last) < 0.12 { return }
        lastSent[key] = now
        go()
    }

    private func text(_ v: Double, step: Double) -> String {
        step >= 1 ? String(Int(v.rounded())) : String(format: "%.1f", v)
    }
}

// MARK: - The meter

/// The room's loudness on a rail from -80 to -20 dB: the live level as the
/// filled part, the quiet floor as a thin tick, the gate as a mark that is
/// dragged. Left of the gate the rail is asleep; right of it, awake.
private struct RoomMeter: View {
    let level: Double?
    let floor: Double?
    let gate: Double
    let open: Bool
    let accent: Color
    var onGate: (Double, Bool) -> Void

    private let lo = -80.0
    private let hi = -20.0

    private func x(_ db: Double, _ w: CGFloat) -> CGFloat {
        CGFloat((Swift.min(hi, Swift.max(lo, db)) - lo) / (hi - lo)) * w
    }

    private func db(at px: CGFloat, _ w: CGFloat) -> Double {
        lo + Double(Swift.min(Swift.max(0, px), w) / w) * (hi - lo)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text("Room").font(.ui(15)).foregroundStyle(Ink.ink)
                Spacer()
                Text(level.map { String(format: "%.0f dB", $0) } ?? "no reading")
                    .font(.machine(14)).foregroundStyle(open ? accent : Ink.dim)
            }
            GeometryReader { geo in
                let w = geo.size.width
                ZStack(alignment: .leading) {
                    Capsule().fill(Ink.sunk).frame(height: 10)
                    Capsule().fill(Ink.plaster)
                        .frame(width: Swift.max(0, x(gate, w)), height: 10)
                    if let level {
                        Capsule().fill(open ? accent : Ink.dim)
                            .frame(width: Swift.max(6, x(level, w)), height: 10)
                            .animation(.linear(duration: 0.5), value: level)
                    }
                    if let floor {
                        Rectangle().fill(Ink.faint)
                            .frame(width: 1.5, height: 20)
                            .offset(x: x(floor, w) - 0.75)
                    }
                    RoundedRectangle(cornerRadius: 1.5).fill(Ink.ink)
                        .frame(width: 3, height: 28)
                        .offset(x: x(gate, w) - 1.5)
                        .shadow(color: .black.opacity(0.7), radius: 2)
                }
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { g in onGate(db(at: g.location.x, w), true) }
                        .onEnded { g in onGate(db(at: g.location.x, w), false) }
                )
            }
            .frame(height: 44)
            .accessibilityElement()
            .accessibilityLabel("Room gate")
            .accessibilityValue(String(format: "%.0f dB", gate))
            .accessibilityAdjustableAction { dir in
                onGate(gate + (dir == .increment ? 1 : -1), false)
            }
            HStack {
                Text(floor.map { String(format: "quiet floor %.0f", $0) } ?? "quiet floor")
                    .font(.machine(11)).foregroundStyle(Ink.faint)
                Spacer()
                Text(String(format: "gate %.0f", gate))
                    .font(.machine(11)).foregroundStyle(Ink.ink)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 13)
    }
}


// MARK: - The wall's own song library, as /teach describes it

struct TaughtList: Decodable {
    struct Song: Decodable {
        var id: String
        var title: String
        var artist: String
        var album: String?
        var how: [String]
        var matched: Int
        var last_matched: Int?
        var landmarks: Int?
    }
    var enabled: Bool?
    var landmarks: Int?
    var songs: [Song]

    static func read(host: String) async -> TaughtList? {
        guard !host.isEmpty, let url = URL(string: "http://\(host)/teach") else { return nil }
        var req = URLRequest(url: url)
        req.timeoutInterval = 6
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? JSONDecoder().decode(TaughtList.self, from: data)
    }

    static func forget(host: String, id: String) async -> Bool {
        guard !host.isEmpty, let url = URL(string: "http://\(host)/teach/forget") else { return false }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 6
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["id": id])
        guard let (_, resp) = try? await URLSession.shared.data(for: req) else { return false }
        return (resp as? HTTPURLResponse)?.statusCode == 200
    }
}
