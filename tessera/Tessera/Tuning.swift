// Panel tuning: every number that decides what the LEDs actually do.
//
// Hidden, because none of it is a setting in the ordinary sense: these are
// the panel's own physics and the colour maths around it. Unlocked from the
// bottom of Settings.
//
// The wall is at the top of the page, live, because that is the only honest
// way to tune a panel: you turn a number and you watch the light change.
// Notes stay out of the way until a knob is under your thumb. Nothing here
// asks you to press a relaunch button; the ones that are launch flags take
// the panel down and bring it back on their own.
//
// The wall owns the list. This page asks what knobs there are and draws
// whatever comes back, so a knob added to the brain shows up here without
// the app changing.

import SwiftUI

struct Knob: Identifiable {
    let name: String
    let group: String
    let kind: String        // int | float | bool
    let min: Double
    let max: Double
    let step: Double
    let restart: Bool       // the panel goes down and comes back for this one
    let note: String
    var id: String { name }

    /// "low_blue" -> "Low blue"
    var title: String {
        let words = name.replacingOccurrences(of: "_", with: " ")
        return words.prefix(1).uppercased() + words.dropFirst()
    }
}

@MainActor
@Observable
final class TuningStore {
    var knobs: [Knob] = []
    var values: [String: Double] = [:]
    var defaults: [String: Double] = [:]
    var problem: String?
    var busy = false
    /// The wall has taken the panel down to pick up a launch flag. It comes
    /// back on its own; this is only so the page can say so.
    var restartingUntil: Date?

    private var host = ""

    var restarting: Bool {
        guard let until = restartingUntil else { return false }
        return until > Date()
    }

    func load(host: String) async {
        self.host = host
        await call("/tuning", body: nil)
    }

    /// One knob, to the wall. The wall answers with everything it now holds,
    /// so the page shows what the wall took rather than what was asked.
    func send(_ name: String, _ value: Double, isBool: Bool = false) async {
        await call("/tuning", body: [name: isBool ? (value > 0.5) as Any : value])
    }

    func reset() async {
        busy = true
        defer { busy = false }
        await call("/tuning/reset", body: [:])
    }

    /// Every request goes through here: one retry, the wall's own words when
    /// it refuses, and never a bare "not answering" for a wall that answered.
    private func call(_ path: String, body: [String: Any]?) async {
        guard !host.isEmpty, let url = URL(string: "http://\(host)\(path)") else {
            problem = "No address for the wall yet."
            return
        }
        for attempt in 0..<2 {
            var req = URLRequest(url: url)
            req.timeoutInterval = 12
            if let body {
                req.httpMethod = "POST"
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                req.httpBody = try? JSONSerialization.data(withJSONObject: body)
            }
            guard let (data, resp) = try? await URLSession.shared.data(for: req) else {
                if attempt == 0 { continue }
                problem = "The wall is not answering."
                return
            }
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard code == 200, let json else {
                problem = (json?["error"] as? String) ?? "The wall said \(code)."
                return
            }
            take(json)
            return
        }
    }

    private func take(_ json: [String: Any]) {
        if let list = json["knobs"] as? [[String: Any]] {
            knobs = list.compactMap { k in
                guard let name = k["name"] as? String else { return nil }
                return Knob(name: name,
                            group: k["group"] as? String ?? "Other",
                            kind: k["kind"] as? String ?? "float",
                            min: k["min"] as? Double ?? 0,
                            max: k["max"] as? Double ?? 1,
                            step: k["step"] as? Double ?? 0.01,
                            restart: k["restart"] as? Bool ?? false,
                            note: k["note"] as? String ?? "")
            }
        }
        if let v = json["values"] as? [String: Any] { values = numbers(v) }
        if let d = json["defaults"] as? [String: Any] { defaults = numbers(d) }
        if json["restarting"] as? Bool == true {
            restartingUntil = Date().addingTimeInterval(7)
        }
        problem = nil
    }

    private func numbers(_ raw: [String: Any]) -> [String: Double] {
        var out: [String: Double] = [:]
        for (k, v) in raw {
            if let b = v as? Bool { out[k] = b ? 1 : 0 }
            else if let d = v as? Double { out[k] = d }
            else if let i = v as? Int { out[k] = Double(i) }
        }
        return out
    }
}

struct PanelTuningPage: View {
    @Environment(WallSession.self) private var wall
    let accent: Color

    @State private var store = TuningStore()
    /// While a finger is down, the number shown is the finger's.
    @State private var dragging: [String: Double] = [:]
    /// The knob under a thumb: its note is the only one on screen.
    @State private var touching: String?
    @State private var lastSent: [String: Date] = [:]
    @State private var card = "sleeve"

    private let order = ["Panel", "Colour", "Dark end", "Sharpness", "Video"]

    var body: some View {
        SetupPage("Panel tuning", blurb: nil) {
            wallView
            live
            ForEach(groups, id: \.self) { group in
                SetupGroup(group, note: nil) {
                    let inGroup = store.knobs.filter { $0.group == group }
                    ForEach(Array(inGroup.enumerated()), id: \.element.id) { i, knob in
                        if i > 0 { Rule() }
                        row(knob)
                    }
                }
            }
            Problem(text: store.problem)
            SetupGroup("Start over", note: nil) {
                SetupRow(title: "Back to defaults",
                         subtitle: "Every number, including the launch flags.") {
                    ActionPill(title: store.busy ? "Resetting" : "Reset", filled: false) {
                        Task { await store.reset() }
                    }
                    .disabled(store.busy)
                }
            }
        }
        .task { await store.load(host: wall.host) }
    }

    // MARK: The wall, live, at the top of the page

    private var wallView: some View {
        VStack(spacing: 12) {
            ZStack {
                PanelCanvas(px: wall.frame.map { [UInt8]($0) }, duty: 1)
                    .aspectRatio(1, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                if store.restarting {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(.black.opacity(0.72))
                    Text("the panel is coming back")
                        .font(.machine(11)).foregroundStyle(Ink.dim)
                }
            }
            .frame(maxWidth: .infinity)
            .animation(.easeInOut(duration: 0.25), value: store.restarting)

            // Something known to judge against, since a sleeve is a poor
            // ruler for a grey or a primary.
            HStack(spacing: 6) {
                cardKey("Sleeve", "sleeve")
                cardKey("Greys", "greys")
                cardKey("Colours", "colours")
                cardKey("White", "white")
                cardKey("Black", "black")
            }
        }
        .padding(.top, -8)
    }

    private func cardKey(_ label: String, _ id: String) -> some View {
        let on = card == id
        return Button {
            card = id
            show(id)
            Taps.detent(intensity: 0.4)
        } label: {
            Text(label).font(.ui(13, .medium))
                .foregroundStyle(on ? Ink.ground : Ink.ink)
                .lineLimit(1).minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity).frame(height: 34)
                .background(Capsule().fill(on ? AnyShapeStyle(accent) : AnyShapeStyle(Ink.plaster)))
        }
        .buttonStyle(PressStyle(scale: 0.95))
    }

    private func show(_ id: String) {
        switch id {
        case "sleeve": wall.send(["mode": "art"])
        case "white":  wall.pushFlat(r: 255, g: 255, b: 255)
        case "black":  wall.pushFlat(r: 0, g: 0, b: 0)
        case "greys":  wall.pushFrame(Self.greys)
        default:       wall.pushFrame(Self.colours)
        }
    }

    /// Four grey bands and a black strip: what the dark end does, at a glance.
    private static var greys: [UInt8] {
        var px = [UInt8](repeating: 0, count: 64 * 64 * 3)
        for y in 0..<64 {
            let v: UInt8 = y >= 56 ? 0 : [255, 191, 128, 64][Swift.min(3, y / 14)]
            for x in 0..<64 {
                let o = (y * 64 + x) * 3
                px[o] = v; px[o + 1] = v; px[o + 2] = v
            }
        }
        return px
    }

    /// Primaries, secondaries and a white, for judging the gains.
    private static var colours: [UInt8] {
        let bars: [(UInt8, UInt8, UInt8)] = [(255, 0, 0), (0, 255, 0), (0, 0, 255),
                                             (255, 255, 0), (0, 255, 255),
                                             (255, 0, 255), (255, 255, 255),
                                             (128, 128, 128)]
        var px = [UInt8](repeating: 0, count: 64 * 64 * 3)
        for y in 0..<64 {
            let c = bars[Swift.min(bars.count - 1, y / 8)]
            for x in 0..<64 {
                let o = (y * 64 + x) * 3
                px[o] = c.0; px[o + 1] = c.1; px[o + 2] = c.2
            }
        }
        return px
    }

    private var groups: [String] {
        let present = Set(store.knobs.map(\.group))
        return order.filter(present.contains) + present.subtracting(order).sorted()
    }

    // MARK: The wall's own state, which needs no tuning store

    private var live: some View {
        SetupGroup("Live", note: nil) {
            liveRow("Panel brightness", key: "panel_brightness",
                    value: wall.state.panelBrightness, min: 1, max: 254, step: 1,
                    note: "The panel's own cap. Rides on every frame.")
            Rule()
            liveRow("Calibration red", key: "wb_r", value: wall.state.wbR,
                    min: 0.3, max: 3.0, step: 0.01,
                    note: "What the Calibrate pass writes, on top of the gains below.")
            Rule()
            liveRow("Calibration green", key: "wb_g", value: wall.state.wbG,
                    min: 0.3, max: 3.0, step: 0.01, note: nil)
            Rule()
            liveRow("Calibration blue", key: "wb_b", value: wall.state.wbB,
                    min: 0.3, max: 3.0, step: 0.01, note: nil)
        }
    }

    private func liveRow(_ title: String, key: String, value: Double,
                         min lo: Double, max hi: Double, step: Double,
                         note: String?) -> some View {
        let shown = dragging[key] ?? value
        return knobBody(key: key, title: title, restart: false, shown: shown,
                        base: value, min: lo, max: hi, step: step, note: note) { v, live in
            if live { throttled(key) { wall.send([key: v]) } }
            else { wall.send([key: v]) }
        }
    }

    // MARK: A knob the wall described

    @ViewBuilder private func row(_ knob: Knob) -> some View {
        let current = store.values[knob.name] ?? knob.min
        if knob.kind == "bool" {
            VStack(alignment: .leading, spacing: 6) {
                Toggle(isOn: Binding(get: { current > 0.5 }, set: { on in
                    touching = knob.name
                    Task { await store.send(knob.name, on ? 1 : 0, isBool: true) }
                    Taps.detent(intensity: 0.4)
                })) {
                    Text(knob.title).font(.ui(15)).foregroundStyle(Ink.ink)
                }
                .tint(accent)
                if touching == knob.name { noteLine(knob.note) }
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
        } else {
            knobBody(key: knob.name, title: knob.title, restart: knob.restart,
                     shown: dragging[knob.name] ?? current, base: current,
                     min: knob.min, max: knob.max, step: knob.step,
                     note: knob.note) { v, live in
                // A launch flag takes the panel down, so it waits for the
                // finger to come off. Everything else follows the drag.
                if live {
                    guard !knob.restart else { return }
                    throttled(knob.name) { Task { await store.send(knob.name, v) } }
                } else {
                    Task { await store.send(knob.name, v) }
                }
            }
        }
    }

    /// One row: the name, the number, the rail, and the note only while the
    /// thumb is on it.
    private func knobBody(key: String, title: String, restart: Bool,
                          shown: Double, base: Double,
                          min lo: Double, max hi: Double, step: Double,
                          note: String?,
                          set: @escaping (Double, Bool) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(title).font(.ui(15)).foregroundStyle(Ink.ink)
                if restart {
                    Text("panel dips").font(.machine(9)).foregroundStyle(Ink.faint)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .overlay(Capsule().strokeBorder(Ink.hairline, lineWidth: 1))
                }
                Spacer()
                Text(text(shown, step: step)).font(.machine(14)).foregroundStyle(accent)
                if let d = store.defaults[key], abs(d - base) > 1e-6 {
                    Text(text(d, step: step)).font(.machine(11))
                        .foregroundStyle(Ink.faint).strikethrough()
                }
            }
            Slider(value: Binding(get: { shown }, set: { raw in
                let v = (raw / step).rounded() * step
                dragging[key] = v
                set(v, true)
            }), in: lo...hi, step: step) { editing in
                if editing {
                    touching = key
                } else if let v = dragging[key] {
                    set(v, false)
                    dragging[key] = nil
                    Taps.commit()
                }
            }
            .tint(accent)
            if touching == key, let note, !note.isEmpty { noteLine(note) }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    private func noteLine(_ note: String) -> some View {
        Text(note).font(.ui(12)).foregroundStyle(Ink.dim)
            .fixedSize(horizontal: false, vertical: true)
            .transition(.opacity)
    }

    /// The wall redraws a frame per change; a drag would ask for sixty.
    private func throttled(_ key: String, _ go: () -> Void) {
        let now = Date()
        if let last = lastSent[key], now.timeIntervalSince(last) < 0.12 { return }
        lastSent[key] = now
        go()
    }

    private func text(_ v: Double, step: Double) -> String {
        step >= 1 ? String(Int(v.rounded())) : String(format: "%.2f", v)
    }
}
