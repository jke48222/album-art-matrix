// Panel tuning: every number that decides what the LEDs actually do.
//
// Hidden, because none of it is a setting in the ordinary sense: these are
// the panel's own physics and the colour maths around it, and a wrong one
// makes the wall worse in ways that are hard to undo by eye. Unlocked from
// the bottom of Settings.
//
// The wall owns the list. This page asks it what knobs there are, what they
// mean and what they range over, and draws whatever comes back, so a knob
// added to the brain shows up here without the app changing.

import SwiftUI

struct Knob: Identifiable {
    let name: String
    let group: String
    let kind: String        // int | float | bool
    let min: Double
    let max: Double
    let step: Double
    let restart: Bool       // the renderer has to come back for this one
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
    var pendingRestart = false
    var problem: String?
    var busy = false

    private var host = ""

    func load(host: String) async {
        self.host = host
        guard let url = URL(string: "http://\(host)/tuning"),
              let (data, resp) = try? await URLSession.shared.data(from: url),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else {
            problem = "The wall is not answering."
            return
        }
        take(json)
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
        if json["restart"] as? Bool == true { pendingRestart = true }
        problem = nil
    }

    private func numbers(_ raw: [String: Any]) -> [String: Double] {
        var out: [String: Double] = [:]
        for (k, v) in raw {
            if let d = v as? Double { out[k] = d }
            else if let b = v as? Bool { out[k] = b ? 1 : 0 }
            else if let i = v as? Int { out[k] = Double(i) }
        }
        return out
    }

    /// One knob, to the wall. The wall answers with everything, so the page
    /// always shows what the wall actually took rather than what was asked.
    func send(_ name: String, _ value: Double, isBool: Bool = false) async {
        guard let url = URL(string: "http://\(host)/tuning") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 8
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(
            withJSONObject: [name: isBool ? (value > 0.5) as Any : value])
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else {
            problem = "The wall is not answering."
            return
        }
        take(json)
    }

    func reset() async {
        busy = true
        defer { busy = false }
        await post("/tuning/reset")
    }

    func restartRenderer() async {
        busy = true
        defer { busy = false }
        await post("/tuning/restart")
        pendingRestart = false
    }

    private func post(_ path: String) async {
        guard let url = URL(string: "http://\(host)\(path)") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 15
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = "{}".data(using: .utf8)
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else {
            problem = "The wall is not answering."
            return
        }
        take(json)
    }
}

struct PanelTuningPage: View {
    @Environment(WallSession.self) private var wall
    let accent: Color
    @State private var store = TuningStore()
    /// While a finger is down, the number shown is the finger's.
    @State private var dragging: [String: Double] = [:]

    private let order = ["Panel", "Colour", "Dark end", "Sharpness", "Video"]

    var body: some View {
        SetupPage("Panel tuning",
                  blurb: "The panel's own physics, and the colour maths around it. Everything here changes what the LEDs do. The wall keeps what you set.") {
            live
            ForEach(groups, id: \.self) { group in
                SetupGroup(group, note: groupNote(group)) {
                    let inGroup = store.knobs.filter { $0.group == group }
                    ForEach(Array(inGroup.enumerated()), id: \.element.id) { i, knob in
                        if i > 0 { Rule() }
                        row(knob)
                    }
                }
            }
            if store.pendingRestart {
                SetupGroup("Waiting on the renderer", note: "Bit depth, dithering, the row settle, the map rate and the panel type are launch flags. The renderer has to come back for them.") {
                    SetupRow(title: "Relaunch the renderer", subtitle: "The wall goes dark for a moment.") {
                        ActionPill(title: store.busy ? "Going" : "Relaunch") {
                            Task { await store.restartRenderer() }
                        }
                        .disabled(store.busy)
                    }
                }
            }
            Problem(text: store.problem)
            SetupGroup("Start over", note: "Back to the numbers the wall shipped with, including the launch flags.") {
                SetupRow(title: "Back to defaults", subtitle: nil) {
                    ActionPill(title: store.busy ? "Resetting" : "Reset", filled: false) {
                        Task {
                            await store.reset()
                            await store.restartRenderer()
                        }
                    }
                    .disabled(store.busy)
                }
            }
        }
        .task { await store.load(host: wall.host) }
    }

    private var groups: [String] {
        let present = Set(store.knobs.map(\.group))
        return order.filter(present.contains) + present.subtracting(order).sorted()
    }

    private func groupNote(_ group: String) -> String? {
        switch group {
        case "Panel": return "Launch flags. Changing one needs the renderer back."
        case "Colour": return "Per-channel gains, applied in linear light before the frame is re-encoded."
        case "Dark end": return "Where the panel stops holding a level steadily, and what to do about it."
        case "Video": return nil
        default: return nil
        }
    }

    // MARK: The live ones, which live in the wall's state rather than its tuning

    private var live: some View {
        SetupGroup("Live", note: "These take effect on the next frame, with no relaunch. The three multipliers are what the Calibrate pass writes.") {
            liveRow("Panel brightness", key: "panel_brightness",
                    value: wall.state.panelBrightness, min: 1, max: 254, step: 1,
                    note: "The panel's own cap. Rides on every frame.")
            Rule()
            liveRow("Calibration red", key: "wb_r", value: wall.state.wbR,
                    min: 0.3, max: 3.0, step: 0.01, note: nil)
            Rule()
            liveRow("Calibration green", key: "wb_g", value: wall.state.wbG,
                    min: 0.3, max: 3.0, step: 0.01, note: nil)
            Rule()
            liveRow("Calibration blue", key: "wb_b", value: wall.state.wbB,
                    min: 0.3, max: 3.0, step: 0.01, note: "Multiplied onto the gains above. The colour is capped at 1.0 where it is applied, so nothing clips.")
        }
        .padding(.top, -12)
    }

    private func liveRow(_ title: String, key: String, value: Double,
                         min lo: Double, max hi: Double, step: Double,
                         note: String?) -> some View {
        let shown = dragging[key] ?? value
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title).font(.ui(15)).foregroundStyle(Ink.ink)
                Spacer()
                Text(text(shown, step: step)).font(.machine(13)).foregroundStyle(accent)
            }
            Slider(value: Binding(get: { shown },
                                  set: { dragging[key] = ($0 / step).rounded() * step }),
                   in: lo...hi, step: step) { editing in
                if !editing, let v = dragging[key] {
                    wall.send([key: v])
                    dragging[key] = nil
                    Taps.commit()
                }
            }
            .tint(accent)
            if let note {
                Text(note).font(.ui(12)).foregroundStyle(Ink.faint)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: A knob the wall described

    @ViewBuilder private func row(_ knob: Knob) -> some View {
        let current = store.values[knob.name] ?? knob.min
        if knob.kind == "bool" {
            VStack(alignment: .leading, spacing: 6) {
                Toggle(isOn: Binding(get: { current > 0.5 },
                                     set: { on in
                    Task { await store.send(knob.name, on ? 1 : 0, isBool: true) }
                    Taps.detent(intensity: 0.4)
                })) {
                    Text(knob.title).font(.ui(15)).foregroundStyle(Ink.ink)
                }
                .tint(accent)
                note(knob)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        } else {
            let shown = dragging[knob.name] ?? current
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text(knob.title).font(.ui(15)).foregroundStyle(Ink.ink)
                    if knob.restart {
                        Text("relaunch").font(.machine(9)).foregroundStyle(Ink.faint)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .overlay(Capsule().strokeBorder(Ink.hairline, lineWidth: 1))
                    }
                    Spacer()
                    Text(text(shown, step: knob.step))
                        .font(.machine(13)).foregroundStyle(accent)
                    if let d = store.defaults[knob.name], abs(d - current) > 1e-6 {
                        Text(text(d, step: knob.step))
                            .font(.machine(11)).foregroundStyle(Ink.faint)
                            .strikethrough()
                    }
                }
                Slider(value: Binding(get: { shown },
                                      set: { dragging[knob.name] = ($0 / knob.step).rounded() * knob.step }),
                       in: knob.min...knob.max, step: knob.step) { editing in
                    if !editing, let v = dragging[knob.name] {
                        Task { await store.send(knob.name, v) }
                        dragging[knob.name] = nil
                        Taps.commit()
                    }
                }
                .tint(accent)
                note(knob)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
    }

    private func note(_ knob: Knob) -> some View {
        Text(knob.note).font(.ui(12)).foregroundStyle(Ink.faint)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func text(_ v: Double, step: Double) -> String {
        step >= 1 ? String(Int(v.rounded())) : String(format: "%.2f", v)
    }
}
