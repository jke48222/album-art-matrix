// The wall's features, each in its own place on the phone: a question for
// the wall and its answers, a note on the panel, a cover or a video by
// name, a song from the words you remember, the voice, HomeKit, the
// record shelf, and teaching the wall a song. Every page talks to the
// wall over its control port and shows what the wall says.

import SwiftUI

// MARK: - Ask the wall

struct AskPage: View {
    @Environment(WallSession.self) private var wall
    let accent: Color
    @State private var question = ""
    @State private var busy = false
    @State private var answer: String?
    @State private var problem: String?
    @State private var onWall = true
    @State private var status: AskStatus?

    private var typed: String { question.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var ready: Bool { status?.ready == true }

    var body: some View {
        SetupPage("Ask the wall",
                  blurb: "Anything: what played at dinner, how long until sunset, what this record is about. The words go to Claude with the wall's own state. Out loud, say the wake word first; from here, just type.") {
            SetupGroup("Your question", note: ready ? "About a cent an answer." : "Needs the Claude key, under Services.") {
                KeyField(placeholder: "What played last night?", text: $question)
                Rule()
                SetupRow(title: "Show the answer on the wall", subtitle: "The line opens into it, as if asked out loud.") {
                    Toggle("", isOn: $onWall).labelsHidden().tint(accent)
                }
                Rule()
                SaveLine(title: busy ? "Asking" : "Ask", enabled: ready && !typed.isEmpty && !busy, busy: busy,
                         done: nil, accent: accent) { ask() }
            }
            .padding(.top, -12)
            Problem(text: problem ?? status?.problem)
            if let a = answer {
                VStack(alignment: .leading, spacing: 8) {
                    Text("The wall says").font(.ui(11, .semibold)).foregroundStyle(accent)
                    Text(a).font(.display(20)).foregroundStyle(Ink.ink).fixedSize(horizontal: false, vertical: true)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: Round.sheet, style: .continuous).fill(Ink.plaster))
            }
            if let h = status?.history, !h.isEmpty {
                SetupGroup("Asked lately", note: "Out loud or from here, the last dozen.") {
                    ForEach(Array(h.enumerated()), id: \.offset) { i, item in
                        if i > 0 { Rule() }
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.q).font(.ui(13)).foregroundStyle(Ink.dim)
                            Text(item.a).font(.ui(15)).foregroundStyle(Ink.ink).fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.horizontal, 16).padding(.vertical, 10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
        .task {
            while !Task.isCancelled {
                if let s = await AskStatus.read(host: wall.host) { status = s }
                try? await Task.sleep(for: .seconds(6))
            }
        }
    }

    private func ask() {
        guard ready, !typed.isEmpty, !busy else { return }
        busy = true
        problem = nil
        let h = wall.host, q = typed, show = onWall
        Task {
            let (a, why) = await AskStatus.ask(host: h, text: q, onWall: show)
            answer = a
            problem = why
            if a != nil { question = ""; Taps.commit() }
            if let s = await AskStatus.read(host: h) { status = s }
            busy = false
        }
    }
}

struct AskStatus: Decodable {
    struct Item: Decodable { var q: String; var a: String; var s: Double?; var usd: Double?; var ts: Int? }
    var ready: Bool?
    var model: String?
    var answers: Int?
    var cost_usd: Double?
    var problem: String?
    var workspace_set: Bool?
    var history: [Item]?

    static func read(host: String) async -> AskStatus? {
        guard !host.isEmpty, let url = URL(string: "http://\(host)/ask") else { return nil }
        var req = URLRequest(url: url); req.timeoutInterval = 6
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? JSONDecoder().decode(AskStatus.self, from: data)
    }

    static func ask(host: String, text: String, onWall: Bool) async -> (String?, String?) {
        guard !host.isEmpty, let url = URL(string: "http://\(host)/ask") else { return (nil, "No wall.") }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 90
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["text": text, "reply": onWall ? "wall" : "text"])
        guard let (data, resp) = try? await URLSession.shared.data(for: req) else { return (nil, "The wall is not answering.") }
        let json = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        if (resp as? HTTPURLResponse)?.statusCode == 200, let a = json["answer"] as? String { return (a, nil) }
        return (nil, json["error"] as? String ?? "The wall could not answer.")
    }
}

// MARK: - A note on the panel

struct NotePage: View {
    @Environment(WallSession.self) private var wall
    let accent: Color
    @State private var text = ""
    @State private var minutes: Double = 30
    @State private var busy = false
    @State private var problem: String?
    @State private var current: NoteStatus?

    private var typed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        SetupPage("Notes",
                  blurb: "Words on the panel for a while: back at seven, dinner is in the oven, happy birthday. The wall goes back to what it was doing when the time is up. A Siri Shortcut can leave one too (docs/ASK.md).") {
            if let c = current, let t = c.text, let left = c.seconds_left, left > 0 {
                HStack(spacing: 12) {
                    PanelCanvas(px: wall.frame.map { [UInt8]($0) }, duty: 1.0)
                        .frame(width: 72, height: 72)
                        .clipShape(RoundedRectangle(cornerRadius: Round.control, style: .continuous))
                    VStack(alignment: .leading, spacing: 4) {
                        Text("On the panel").font(.ui(11, .semibold)).foregroundStyle(accent)
                        Text(t).font(.ui(15, .semibold)).foregroundStyle(Ink.ink).lineLimit(2)
                        Text("\(left / 60) min \(left % 60) s left").font(.machine(11)).foregroundStyle(Ink.dim)
                    }
                    Spacer(minLength: 0)
                    ActionPill(title: "Take down", filled: false) { take(down: true) }
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: Round.sheet, style: .continuous).fill(Ink.plaster))
            }
            SetupGroup("The words", note: "Runs across the panel until the time is up.") {
                KeyField(placeholder: "Back at seven", text: $text)
                Rule()
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("\(Int(minutes))").font(.display(30)).foregroundStyle(accent).contentTransition(.numericText())
                    Text("minutes").font(.ui(14)).foregroundStyle(Ink.dim)
                    Spacer()
                }
                .padding(.horizontal, 16).padding(.top, 10)
                Slider(value: $minutes, in: 1...240, step: 1).tint(accent).padding(.horizontal, 16).padding(.bottom, 8)
                Rule()
                SaveLine(title: busy ? "Putting up" : "Put it on the wall", enabled: !typed.isEmpty && !busy, busy: busy,
                         done: nil, accent: accent) { take(down: false) }
            }
            Problem(text: problem)
        }
        .task {
            while !Task.isCancelled {
                if let c = await NoteStatus.read(host: wall.host) { current = c }
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    private func take(down: Bool) {
        guard !busy else { return }
        busy = true
        let h = wall.host, words = down ? "" : typed, mins = down ? 0.02 : minutes
        Task {
            let ok = await NoteStatus.post(host: h, text: down ? " " : words, minutes: mins)
            problem = ok ? nil : "The wall did not take it."
            if ok && !down { text = ""; Taps.commit() }
            if let c = await NoteStatus.read(host: h) { current = c }
            busy = false
        }
    }
}

struct NoteStatus: Decodable {
    var text: String?
    var seconds_left: Int?

    static func read(host: String) async -> NoteStatus? {
        guard !host.isEmpty, let url = URL(string: "http://\(host)/note") else { return nil }
        var req = URLRequest(url: url); req.timeoutInterval = 6
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? JSONDecoder().decode(NoteStatus.self, from: data)
    }

    static func post(host: String, text: String, minutes: Double) async -> Bool {
        guard !host.isEmpty, let url = URL(string: "http://\(host)/note") else { return false }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 10
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["text": text, "minutes": minutes])
        guard let (_, resp) = try? await URLSession.shared.data(for: req) else { return false }
        return (resp as? HTTPURLResponse)?.statusCode == 200
    }
}

// MARK: - Show me, play me

struct ShowPage: View {
    @Environment(WallSession.self) private var wall
    let accent: Color
    @State private var cover = ""
    @State private var video = ""
    @State private var busy: String?
    @State private var problem: String?
    @State private var last: ShowResult?

    var body: some View {
        SetupPage("Show me",
                  blurb: "A cover by name goes up on the wall for ten minutes; a video by name plays on it with this phone as the speaker. Out loud: \"show me the Blonde cover\", \"play the Gameboy video\".") {
            SetupGroup("A cover", note: "Found on iTunes: an album, or a song's album.") {
                KeyField(placeholder: "the Blonde cover", text: $cover)
                Rule()
                SaveLine(title: busy == "show" ? "Finding" : "Show it", enabled: !cover.trimmingCharacters(in: .whitespaces).isEmpty && busy == nil,
                         busy: busy == "show", done: nil, accent: accent) { send("show", cover) }
            }
            .padding(.top, -12)
            SetupGroup("A video", note: "Found by name; the phone plays the sound.") {
                KeyField(placeholder: "the Gameboy video", text: $video)
                Rule()
                SaveLine(title: busy == "play" ? "Finding" : "Play it", enabled: !video.trimmingCharacters(in: .whitespaces).isEmpty && busy == nil,
                         busy: busy == "play", done: nil, accent: accent) { send("play", video) }
            }
            Problem(text: problem)
            if let l = last {
                HStack(spacing: 12) {
                    if let art = l.art_url, let url = URL(string: art) {
                        AsyncImage(url: url) { img in img.resizable().interpolation(.medium) } placeholder: { RoundedRectangle(cornerRadius: Round.control).fill(Ink.plaster) }
                            .frame(width: 72, height: 72)
                            .clipShape(RoundedRectangle(cornerRadius: Round.control, style: .continuous))
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(l.what == "play" ? "Playing" : "On the wall").font(.ui(11, .semibold)).foregroundStyle(accent)
                        Text(l.title ?? l.album ?? "").font(.ui(15, .semibold)).foregroundStyle(Ink.ink).lineLimit(2)
                        Text(l.artist ?? l.author ?? "").font(.ui(12)).foregroundStyle(Ink.dim).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: Round.sheet, style: .continuous).fill(Ink.plaster))
            }
        }
        .task {
            if let r = await ShowResult.last(host: wall.host) { last = r }
        }
    }

    private func send(_ what: String, _ query: String) {
        guard busy == nil else { return }
        busy = what
        problem = nil
        let h = wall.host, q = query.trimmingCharacters(in: .whitespaces)
        Task {
            let (r, why) = await ShowResult.post(host: h, what: what, query: q)
            if let r { last = r; Taps.commit(); if what == "show" { cover = "" } else { video = "" } }
            problem = why
            busy = nil
        }
    }
}

struct ShowResult: Decodable {
    var what: String?
    var title: String?
    var artist: String?
    var album: String?
    var author: String?
    var art_url: String?
    var confidence: Double?

    static func last(host: String) async -> ShowResult? {
        guard !host.isEmpty, let url = URL(string: "http://\(host)/show") else { return nil }
        var req = URLRequest(url: url); req.timeoutInterval = 6
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let d = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let l = d["last"] as? [String: Any], let bytes = try? JSONSerialization.data(withJSONObject: l) else { return nil }
        return try? JSONDecoder().decode(ShowResult.self, from: bytes)
    }

    static func post(host: String, what: String, query: String) async -> (ShowResult?, String?) {
        guard !host.isEmpty, let url = URL(string: "http://\(host)/\(what)") else { return (nil, "No wall.") }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 60
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["query": query])
        guard let (data, resp) = try? await URLSession.shared.data(for: req) else { return (nil, "The wall is not answering.") }
        if (resp as? HTTPURLResponse)?.statusCode == 200 {
            var r = (try? JSONDecoder().decode(ShowResult.self, from: data)) ?? ShowResult()
            r.what = what
            return (r, nil)
        }
        let json = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        return (nil, json["error"] as? String ?? "The wall could not find that.")
    }
}

// MARK: - The earworm finder

struct EarwormPage: View {
    @Environment(WallSession.self) private var wall
    let accent: Color
    @State private var words = ""
    @State private var busy = false
    @State private var problem: String?
    @State private var found: Earworm?

    var body: some View {
        SetupPage("Earworm",
                  blurb: "The song you cannot place: type the words you remember, or hum a description of it, and Claude names it. The sleeve goes up on the wall with the name along its foot.") {
            SetupGroup("What you remember", note: "Lyrics, a description, half a chorus. Needs the Claude key.") {
                KeyField(placeholder: "we could be heroes, just for one day", text: $words)
                Rule()
                SaveLine(title: busy ? "Thinking" : "Name it", enabled: !words.trimmingCharacters(in: .whitespaces).isEmpty && !busy,
                         busy: busy, done: nil, accent: accent) { find() }
            }
            .padding(.top, -12)
            Problem(text: problem)
            if let f = found {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 12) {
                        if let art = f.art_url, let url = URL(string: art) {
                            AsyncImage(url: url) { img in img.resizable().interpolation(.medium) } placeholder: { RoundedRectangle(cornerRadius: Round.control).fill(Ink.sunk) }
                                .frame(width: 84, height: 84)
                                .clipShape(RoundedRectangle(cornerRadius: Round.card, style: .continuous))
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            Text(f.confidence.map { $0 >= 0.7 ? "Fairly sure" : "A guess" } ?? "").font(.ui(11, .semibold)).foregroundStyle(accent)
                            Text(f.title ?? "").font(.display(20)).foregroundStyle(Ink.ink).lineLimit(2)
                            Text(f.artist ?? "").font(.ui(14)).foregroundStyle(Ink.dim)
                        }
                        Spacer(minLength: 0)
                    }
                    if let alts = f.alternatives, !alts.isEmpty {
                        Text("Or maybe").font(.ui(11, .semibold)).foregroundStyle(Ink.dim)
                        ForEach(Array(alts.enumerated()), id: \.offset) { _, a in
                            Text("\(a.title), \(a.artist)").font(.ui(13)).foregroundStyle(Ink.ink)
                        }
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: Round.sheet, style: .continuous).fill(Ink.plaster))
            }
        }
    }

    private func find() {
        guard !busy else { return }
        busy = true
        problem = nil
        let h = wall.host, w = words.trimmingCharacters(in: .whitespaces)
        Task {
            let (r, why) = await Earworm.post(host: h, words: w)
            found = r
            problem = why
            if r != nil { Taps.commit() }
            busy = false
        }
    }
}

struct Earworm: Decodable {
    struct Alt: Decodable { var title: String; var artist: String }
    var title: String?
    var artist: String?
    var confidence: Double?
    var alternatives: [Alt]?
    var art_url: String?
    var shown: Bool?

    static func post(host: String, words: String) async -> (Earworm?, String?) {
        guard !host.isEmpty, let url = URL(string: "http://\(host)/earworm") else { return (nil, "No wall.") }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 60
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["words": words])
        guard let (data, resp) = try? await URLSession.shared.data(for: req) else { return (nil, "The wall is not answering.") }
        if (resp as? HTTPURLResponse)?.statusCode == 200 { return (try? JSONDecoder().decode(Earworm.self, from: data), nil) }
        let json = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        return (nil, json["error"] as? String ?? "The wall could not place it.")
    }
}

// MARK: - The voice

struct VoicePage: View {
    @Environment(WallSession.self) private var wall
    let accent: Color
    @State private var status: VoiceStatus?
    @State private var said = ""
    @State private var busy = false
    @State private var problem: String?
    @State private var threshold: Double = 0.5
    @State private var editingThreshold = false
    @State private var holdThresholdUntil = Date.distantPast

    var body: some View {
        SetupPage("Voice",
                  blurb: "Say the wake word and the wall collapses to a line and listens; the line follows your voice. A command (off, clock, lyrics, brighter, a timer, show me a cover, a game's move) is done on the wall; anything else is a question for Claude, answered on the panel. The wake word and speech run on the Pi; nothing leaves the house until a question does.") {
            SetupGroup("Now", note: nil) {
                SetupRow(title: "The wall", subtitle: stateLine) {
                    StateValue(status?.state?.capitalized ?? "Off", done: status?.on == true)
                }
                Rule()
                SetupRow(title: "Listen now", subtitle: "As if the wake word came.") {
                    ActionPill(title: "Listen", filled: true) { wake() }
                }
                Rule()
                SetupRow(title: "Speech", subtitle: (status?.speech?.model.map { "Whisper \($0)" } ?? "Whisper")
                         + (status?.speech?.loaded == true ? ", loaded" : ", loads on first use")
                         + (status?.speech?.last_s.map { String(format: ", %.1f s last time", $0) } ?? "")) { EmptyView() }
            }
            .padding(.top, -12)
            SetupGroup("Wake word", note: nil) {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(status?.wake?.label ?? "None").font(.display(28)).foregroundStyle(Ink.ink)
                        Spacer()
                        if status?.wake_loading != nil {
                            Text("Switching").font(.ui(12)).foregroundStyle(Ink.dim)
                        } else if let f = status?.wake?.fires, f > 0 {
                            Text("heard \(f)x").font(.machine(11)).foregroundStyle(Ink.faint)
                        }
                    }
                    WakeMeter(accent: accent, threshold: $threshold,
                              onEditing: { editingThreshold = $0 }, onCommit: { sendThreshold() })
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Sensitivity").font(.ui(13)).foregroundStyle(Ink.dim)
                            Spacer()
                            if let d = status?.wake?.default_threshold, abs(threshold - d) > 0.02 {
                                Button("Default") {
                                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { threshold = d }
                                    sendThreshold()
                                }
                                .font(.ui(12, .semibold)).foregroundStyle(accent)
                                .padding(.trailing, 8)
                            }
                            Text(sensitivityWord).font(.ui(13, .semibold)).foregroundStyle(Ink.ink)
                        }
                        Text("Drag the white mark. Further left and it wakes more easily, and by mistake more often.")
                            .font(.ui(11)).foregroundStyle(Ink.faint)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.horizontal, 16).padding(.vertical, 14)
                ForEach(status?.wake_choices ?? [], id: \.name) { c in
                    Rule()
                    wakeRow(c)
                }
                Rule()
                NavigationLink {
                    WakeEnrollPage(accent: accent)
                } label: {
                    SetupRow(title: "Make your own", subtitle: "Say a phrase of your own to the wall six times. It learns your voice.") {
                        Image(systemName: "plus.circle").font(.system(size: 18)).foregroundStyle(accent)
                    }
                }
                .buttonStyle(PressStyle(scale: 0.99))
            }
            Problem(text: status?.wake_problem)
            SetupGroup("Say it from here", note: "Words as if spoken to the wall, without the microphone.") {
                KeyField(placeholder: "show the clock", text: $said)
                Rule()
                SaveLine(title: busy ? "Saying" : "Say", enabled: !said.trimmingCharacters(in: .whitespaces).isEmpty && !busy,
                         busy: busy, done: nil, accent: accent) { say() }
            }
            Problem(text: problem ?? status?.problem)
            SetupGroup("Last heard", note: "Each wake word keeps its own sensitivity; Tuning, Voice shows the one in use.") {
                SetupRow(title: status?.last_text ?? "Nothing yet", subtitle: status?.last_command ?? status?.last_answer ?? "") { EmptyView() }
            }
        }
        .task {
            while !Task.isCancelled {
                if let s = await VoiceStatus.read(host: wall.host) {
                    status = s
                    if !editingThreshold, Date() >= holdThresholdUntil, let th = s.wake?.threshold { threshold = th }
                }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private var sensitivityWord: String {
        let d = threshold - (status?.wake?.default_threshold ?? 0.5)
        return d < -0.07 ? "High" : d > 0.07 ? "Low" : "Medium"
    }

    private func wakeRow(_ c: VoiceStatus.Choice) -> some View {
        let on = c.name == status?.wake?.model
        let sub: String = c.kind == "own"
            ? "Yours" + (c.quality.map { $0 == "good" ? ", clear of ordinary talk" : $0 == "fair" ? ", fairly clear of talk" : ", close to ordinary talk" } ?? "")
            : "Built in"
        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(c.label).font(.ui(15, on ? .semibold : .regular)).foregroundStyle(Ink.ink)
                Text(sub).font(.ui(12)).foregroundStyle(Ink.dim)
            }
            Spacer()
            if on {
                Image(systemName: "checkmark").font(.system(size: 15, weight: .semibold)).foregroundStyle(accent)
            } else if status?.wake_loading == c.name {
                ProgressView().tint(accent)
            } else if c.kind == "own" {
                ActionPill(title: "Forget", filled: false) { forget(c.name) }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 11)
        .contentShape(Rectangle())
        .onTapGesture { if !on { choose(c.name) } }
    }

    private func choose(_ name: String) {
        let h = wall.host
        Taps.detent(intensity: 0.5)
        Task {
            _ = await VoiceStatus.send(host: h, path: "/voice/wakeword", body: ["name": name])
            for _ in 0..<12 {
                try? await Task.sleep(for: .milliseconds(500))
                if let s = await VoiceStatus.read(host: h) {
                    status = s
                    if s.wake_loading == nil { break }
                }
            }
        }
    }

    private func forget(_ name: String) {
        let h = wall.host
        Task {
            _ = await VoiceStatus.send(host: h, path: "/voice/wakeword/forget", body: ["name": name])
            if let s = await VoiceStatus.read(host: h) { status = s }
            Taps.commit()
        }
    }

    private func sendThreshold() {
        holdThresholdUntil = Date().addingTimeInterval(3)        // the wall takes a moment; do not snap back
        let h = wall.host, th = (threshold * 100).rounded() / 100
        Task { _ = await VoiceStatus.send(host: h, path: "/voice/wakeword", body: ["threshold": th]) }
    }

    private var stateLine: String {
        switch status?.state {
        case "listening": return "Listening to you."
        case "thinking": return "Working out what you said."
        case "answering": return "Answering on the panel."
        case "missed": return "Did not catch that."
        case "idle": return "Waiting for the wake word."
        default: return status?.on == false ? "The voice is off on this wall." : ""
        }
    }

    private func wake() {
        let h = wall.host
        Task { _ = await VoiceStatus.post(host: h, path: "/voice/wake", body: [:]); Taps.detent(intensity: 0.5) }
    }

    private func say() {
        guard !busy else { return }
        busy = true
        let h = wall.host, t = said.trimmingCharacters(in: .whitespaces)
        Task {
            let ok = await VoiceStatus.post(host: h, path: "/voice/say", body: ["text": t])
            problem = ok ? nil : "The wall did not take it."
            if ok { said = ""; Taps.commit() }
            busy = false
        }
    }
}

struct VoiceStatus: Decodable {
    struct Wake: Decodable {
        var model: String?; var label: String?; var kind: String?; var loaded: Bool?
        var threshold: Double?; var default_threshold: Double?; var peak: Double?; var fires: Int?
        var quality: String?; var problem: String?
    }
    struct Choice: Decodable { var name: String; var label: String; var kind: String; var quality: String? }
    var wake_choices: [Choice]?
    var wake_loading: String?
    var wake_problem: String?
    var enroll: EnrollState?
    struct Speech: Decodable { var model: String?; var loaded: Bool?; var last_s: Double?; var problem: String? }
    var on: Bool?
    var state: String?
    var wakes: Int?
    var last_text: String?
    var last_command: String?
    var last_answer: String?
    var wake: Wake?
    var speech: Speech?
    var problem: String?

    static func read(host: String) async -> VoiceStatus? {
        guard !host.isEmpty, let url = URL(string: "http://\(host)/voice") else { return nil }
        var req = URLRequest(url: url); req.timeoutInterval = 6
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? JSONDecoder().decode(VoiceStatus.self, from: data)
    }

    /// POST with the wall's answer: the status code and the JSON.
    static func send(host: String, path: String, body: [String: Any]) async -> (Int, [String: Any]) {
        guard !host.isEmpty, let url = URL(string: "http://\(host)\(path)") else { return (0, [:]) }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 20
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        guard let (data, resp) = try? await URLSession.shared.data(for: req) else { return (0, [:]) }
        let json = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        return ((resp as? HTTPURLResponse)?.statusCode ?? 0, json)
    }

    static func post(host: String, path: String, body: [String: Any]) async -> Bool {
        guard !host.isEmpty, let url = URL(string: "http://\(host)\(path)") else { return false }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 20
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        guard let (_, resp) = try? await URLSession.shared.data(for: req) else { return false }
        return (resp as? HTTPURLResponse)?.statusCode == 200
    }
}

// MARK: - HomeKit

struct HomeKitPage: View {
    @Environment(WallSession.self) private var wall
    let accent: Color
    @State private var status: HomeKitStatus?
    @State private var busy = false

    var body: some View {
        SetupPage("HomeKit",
                  blurb: "The wall in the Home app, and so on Siri, the Watch and in Control Centre: a light (on, off, brightness, a colour for the lamp face), a television whose inputs are the faces and whose remote plays the games, and two sensors, sound in the room and music on the wall, for automations.") {
            SetupGroup("Pairing", note: status?.paired == true
                       ? "Paired. To pair again from scratch, remove the bridge in Home, then delete homekit.state on the Pi."
                       : "Open Home, add an accessory, and scan the code the wall shows on its panel. Say Add Anyway if Home calls it uncertified.") {
                SetupRow(title: status?.name ?? "Wall", subtitle: status?.paired == true ? "In your home." : "Not paired yet.") {
                    StateValue(status?.paired == true ? "Paired" : "Set up", done: status?.paired == true)
                }
                Rule()
                SetupRow(title: "Setup code", subtitle: status?.code ?? "") {
                    ActionPill(title: status?.showing_code == true ? "On the panel" : "Show on the panel", filled: status?.showing_code != true) { showCode() }
                }
            }
            .padding(.top, -12)
            if let faces = status?.faces, !faces.isEmpty {
                SetupGroup("The remote", note: "In Control Centre's remote, the arrows step through the faces, play and pause switch the wall off and on, info runs what is playing across the panel, the volume keys are the light. While a game is on, the arrows and select play it and back puts it down.") {
                    ForEach(Array(faces.enumerated()), id: \.offset) { i, f in
                        if i > 0 { Rule() }
                        SetupRow(title: f.name, subtitle: "Input \(f.id)") {
                            StateValue(wall.state.mode == f.mode ? "On the wall" : "", done: wall.state.mode == f.mode)
                        }
                    }
                }
            }
            if let e = status?.error { Problem(text: e) }
        }
        .task {
            while !Task.isCancelled {
                if let s = await HomeKitStatus.read(host: wall.host) { status = s }
                try? await Task.sleep(for: .seconds(4))
            }
        }
    }

    private func showCode() {
        guard !busy else { return }
        busy = true
        let h = wall.host
        Task {
            _ = await VoiceStatus.post(host: h, path: "/homekit/show", body: [:])
            Taps.commit()
            if let s = await HomeKitStatus.read(host: h) { status = s }
            busy = false
        }
    }
}

struct HomeKitStatus: Decodable {
    struct Face: Decodable { var id: Int; var name: String; var mode: String }
    var enabled: Bool?
    var ready: Bool?
    var error: String?
    var name: String?
    var paired: Bool?
    var code: String?
    var showing_code: Bool?
    var faces: [Face]?

    static func read(host: String) async -> HomeKitStatus? {
        guard !host.isEmpty, let url = URL(string: "http://\(host)/homekit") else { return nil }
        var req = URLRequest(url: url); req.timeoutInterval = 6
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? JSONDecoder().decode(HomeKitStatus.self, from: data)
    }
}

// MARK: - The shelf, as covers

struct ShelfPage: View {
    @Environment(WallSession.self) private var wall
    @Environment(\.openURL) private var openURL
    let accent: Color
    @State private var shelf: ShelfList?
    private var columns: [GridItem] { Array(repeating: GridItem(.flexible(), spacing: 10), count: 3) }

    private var releases: [ShelfList.Release] {
        (shelf?.releases ?? []).sorted { a, b in
            if a.plays != b.plays { return a.plays > b.plays }
            return (a.added ?? "") > (b.added ?? "")
        }
    }

    var body: some View {
        SetupPage("The shelf",
                  blurb: "Your records, as the wall knows them from Discogs. A streamed song from an album here gets a small record in the corner of its sleeve; when one of these plays, the pressing shows under the song. Set up under Services, Discogs.") {
            if releases.isEmpty {
                SetupGroup("Nothing here yet", note: "Add your Discogs username and token under Services, Discogs, and the wall reads your collection.") { EmptyView() }
                    .padding(.top, -12)
            } else {
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(releases, id: \.release_id) { r in
                        VStack(alignment: .leading, spacing: 6) {
                            AsyncImage(url: URL(string: r.cover ?? "")) { phase in
                                if let img = phase.image { img.resizable().interpolation(.medium).aspectRatio(1, contentMode: .fill) }
                                else { RoundedRectangle(cornerRadius: Round.control).fill(Ink.plaster).aspectRatio(1, contentMode: .fit) }
                            }
                            .clipShape(RoundedRectangle(cornerRadius: Round.control, style: .continuous))
                            Text(r.title).font(.ui(12, .semibold)).foregroundStyle(Ink.ink).lineLimit(1)
                            Text([r.artists.first ?? "", r.year.map(String.init) ?? ""].filter { !$0.isEmpty }.joined(separator: " · "))
                                .font(.ui(11)).foregroundStyle(Ink.dim).lineLimit(1)
                            if r.plays > 0 {
                                Text(r.plays == 1 ? "played once" : "played \(r.plays)x").font(.machine(10)).foregroundStyle(accent)
                            }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { if let u = URL(string: r.url) { openURL(u) } }
                    }
                }
                .padding(.top, -6)
            }
        }
        .task {
            if let list = await ShelfList.read(host: wall.host) { shelf = list }
        }
    }
}

// MARK: - Teach the wall a song

struct TeachPage: View {
    @Environment(WallSession.self) private var wall
    let accent: Color
    @State private var title = ""
    @State private var artist = ""
    @State private var busy = false
    @State private var problem: String?
    @State private var done: String?
    @State private var taught: TaughtList?
    @State private var forgetting: String?

    var body: some View {
        SetupPage("Teach the wall",
                  blurb: "The wall's own song library, asked before Shazam. It learns a song's preview when another source names it and the ear keeps missing it, learns the room's own hearing of a song after fifteen loud seconds, and learns any song you name here from its preview.") {
            SetupGroup("By name", note: "The song's preview is fetched from iTunes and fingerprinted on the wall.") {
                KeyField(placeholder: "Song title", text: $title)
                Rule()
                KeyField(placeholder: "Artist", text: $artist)
                Rule()
                SaveLine(title: busy ? "Learning" : "Teach it", enabled: !title.trimmingCharacters(in: .whitespaces).isEmpty && !artist.trimmingCharacters(in: .whitespaces).isEmpty && !busy,
                         busy: busy, done: done, accent: accent) { learn() }
            }
            .padding(.top, -12)
            Problem(text: problem)
            SetupGroup("Known", note: taughtNote) {
                ForEach(Array((taught?.songs ?? []).enumerated()), id: \.element.id) { i, song in
                    if i > 0 { Rule() }
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(song.title).font(.ui(15)).foregroundStyle(Ink.ink).lineLimit(1)
                            Text(song.artist + "  ·  " + how(song)).font(.ui(12)).foregroundStyle(Ink.dim).lineLimit(1)
                        }
                        Spacer(minLength: 8)
                        ActionPill(title: forgetting == song.id ? "Forgetting" : "Forget", filled: false) { forget(song.id) }
                    }
                    .padding(.horizontal, 16).padding(.vertical, 9)
                }
            }
        }
        .task {
            while !Task.isCancelled {
                if let list = await TaughtList.read(host: wall.host) { taught = list }
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    private var taughtNote: String {
        guard let t = taught, !t.songs.isEmpty else { return "None yet." }
        return "\(t.songs.count) song\(t.songs.count == 1 ? "" : "s"), \(t.landmarks ?? 0) landmarks."
    }

    private func how(_ song: TaughtList.Song) -> String {
        let ways = song.how.map { $0 == "preview" ? "preview" : $0 == "ear" ? "the room" : "by name" }
        var line = "from " + ways.joined(separator: " and ")
        if song.matched > 0 { line += ", named \(song.matched)x" }
        return line
    }

    private func learn() {
        guard !busy else { return }
        busy = true
        problem = nil
        let h = wall.host, t = title.trimmingCharacters(in: .whitespaces), a = artist.trimmingCharacters(in: .whitespaces)
        Task {
            let (ok, why) = await TaughtList.learn(host: h, title: t, artist: a)
            problem = why
            if ok { done = "Learnt \(t)"; title = ""; artist = ""; Taps.commit() }
            if let list = await TaughtList.read(host: h) { taught = list }
            busy = false
        }
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
}

extension TaughtList {
    static func learn(host: String, title: String, artist: String) async -> (Bool, String?) {
        guard !host.isEmpty, let url = URL(string: "http://\(host)/teach/learn") else { return (false, "No wall.") }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 90
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["title": title, "artist": artist])
        guard let (data, resp) = try? await URLSession.shared.data(for: req) else { return (false, "The wall is not answering.") }
        if (resp as? HTTPURLResponse)?.statusCode == 200 { return (true, nil) }
        let json = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        return (false, json["error"] as? String ?? "The wall could not learn it.")
    }
}


// MARK: - The wake word: the live meter, and teaching one of your own

struct EnrollState: Decodable, Equatable {
    var phrase: String
    var stage: String
    var takes: Int
    var samples: Int
    var rejected: Int?
    var message: String
    var event: String?
    var event_ago: Double?
    var talk_left: Double?
    var talk_s: Double?
    var level_over: Double?
    var recording: Bool?
    var quality: String?
    var separation: Double?
    var name: String?
    var problem: String?
}

struct VoiceMeter: Decodable {
    var state: String?
    var label: String?
    var score: Double?
    var peak: Double?
    var threshold: Double?
    var fires: Int?
    var last_fire_ago: Double?
    var level_over: Double?
    var enroll: EnrollState?

    static func read(host: String) async -> VoiceMeter? {
        guard !host.isEmpty, let url = URL(string: "http://\(host)/voice/meter") else { return nil }
        var req = URLRequest(url: url); req.timeoutInterval = 3
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? JSONDecoder().decode(VoiceMeter.self, from: data)
    }
}

/// How sure the wall is as you say the wake word: the live score, its
/// recent peak behind it, and the mark it has to pass.
/// How sure the wall is as you say the wake word: the live score, its
/// recent peak behind it, and the white mark it has to pass. The mark is
/// the sensitivity control: drag it along the bar.
struct WakeMeter: View {
    @Environment(WallSession.self) private var wall
    let accent: Color
    @Binding var threshold: Double
    var onEditing: (Bool) -> Void = { _ in }
    var onCommit: () -> Void = {}
    @State private var meter: VoiceMeter?
    @State private var lastFires = -1
    @State private var heardAt: Date?
    @State private var glow = 0.0
    @State private var dragging = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            GeometryReader { geo in
                let w = geo.size.width
                ZStack(alignment: .leading) {
                    Capsule().fill(Ink.sunk).frame(height: 16)
                    Capsule().fill(accent.opacity(0.28))
                        .frame(width: max(8, w * CGFloat(min(1, meter?.peak ?? 0))), height: 16)
                    Capsule().fill(accent)
                        .frame(width: max(8, w * CGFloat(min(1, meter?.score ?? 0))), height: 16)
                    Capsule().stroke(accent, lineWidth: 2).frame(height: 16).opacity(glow)
                    RoundedRectangle(cornerRadius: 2).fill(Ink.ink)
                        .frame(width: dragging ? 6 : 4, height: dragging ? 34 : 26)
                        .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
                        .offset(x: w * CGFloat(threshold) - (dragging ? 3 : 2))
                        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: dragging)
                }
                .frame(width: w, height: 36)
                .contentShape(Rectangle())
                .animation(.easeOut(duration: 0.18), value: meter?.score ?? 0)
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { g in
                            if !dragging {
                                dragging = true
                                onEditing(true)
                            }
                            let t = (min(0.95, max(0.3, Double(g.location.x / max(1, w)))) * 100).rounded() / 100
                            if Int(t * 20) != Int(threshold * 20) { Taps.detent(intensity: 0.35) }
                            threshold = t
                        }
                        .onEnded { _ in
                            dragging = false
                            onEditing(false)
                            onCommit()
                        }
                )
            }
            .frame(height: 36)
            HStack {
                Text(line).font(.ui(13, .medium)).foregroundStyle(heard ? accent : Ink.dim)
                Spacer()
                if let over = meter?.level_over {
                    Text(over >= 9 ? "hearing you" : "quiet").font(.machine(10)).foregroundStyle(Ink.faint)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Wake word sensitivity")
        .accessibilityValue("Mark at \(Int((threshold * 100).rounded())). \(line)")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: threshold = max(0.3, threshold - 0.05)      // more sensitive: the mark moves left
            case .decrement: threshold = min(0.95, threshold + 0.05)
            @unknown default: break
            }
            onCommit()
        }
        .task {
            while !Task.isCancelled {
                if let m = await VoiceMeter.read(host: wall.host) {
                    let fires = m.fires ?? 0
                    if lastFires >= 0, fires > lastFires {
                        heardAt = Date()
                        withAnimation(.easeIn(duration: 0.08)) { glow = 1 }
                        Taps.commit()
                        Task {
                            try? await Task.sleep(for: .milliseconds(150))
                            withAnimation(.easeOut(duration: 1.3)) { glow = 0 }
                        }
                    }
                    lastFires = fires
                    meter = m
                }
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
    }

    private var heard: Bool { heardAt.map { Date().timeIntervalSince($0) < 2.5 } ?? false }

    private var line: String {
        if heard { return "Heard it." }
        guard let m = meter else { return "Say it and watch the bar." }
        switch m.state {
        case "listening": return "Listening to you."
        case "thinking", "answering": return "Answering."
        case "enrolling": return "Learning a new wake word."
        default: return "Say it and watch the bar."
        }
    }
}

struct WakeEnrollPage: View {
    @Environment(WallSession.self) private var wall
    @Environment(\.dismiss) private var dismiss
    let accent: Color
    @State private var phrase = ""
    @State private var enroll: EnrollState?
    @State private var problem: String?
    @State private var starting = false
    @State private var watching = false

    private var typed: String { phrase.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var active: Bool { ["takes", "talk", "building"].contains(enroll?.stage ?? "") }

    var body: some View {
        SetupPage("Your own wake word",
                  blurb: "Any short phrase: Hey Wall, Okay Tessera, Wake up. Stand where you usually talk to the wall and say it six times, pausing after each; every take lights a dot on the wall. Then talk normally for ten seconds, so it learns what is not the phrase. It learns the voices it hears, so anyone who will use it can say a take or two.") {
            if active, let e = enroll {
                progressCard(e).padding(.top, -12)
            } else if let e = enroll, e.stage == "done" {
                doneCard(e).padding(.top, -12)
            } else {
                SetupGroup("The phrase", note: "Two or three words work best: something you would not say by accident.") {
                    KeyField(placeholder: "Hey Wall", text: $phrase)
                    Rule()
                    SaveLine(title: starting ? "Starting" : "Start", enabled: typed.count >= 3 && !starting,
                             busy: starting, done: nil, accent: accent) { start() }
                }
                .padding(.top, -12)
                if let e = enroll, e.stage == "failed" {
                    Problem(text: e.problem.map { "Could not learn it: \($0)" } ?? "Could not learn it. Try again.")
                }
                if let e = enroll, e.stage == "cancelled", e.event == "idle" {
                    Problem(text: e.message)
                }
            }
            Problem(text: problem)
        }
        .task {
            while !Task.isCancelled {
                if watching {
                    if let m = await VoiceMeter.read(host: wall.host), let e = m.enroll {
                        enroll = e
                    } else if let s = await VoiceStatus.read(host: wall.host), let e = s.enroll {
                        enroll = e
                        if !["takes", "talk", "building"].contains(e.stage) { watching = false }
                    }
                }
                try? await Task.sleep(for: .milliseconds(watching ? 250 : 800))
            }
        }
    }

    private func progressCard(_ e: EnrollState) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("\u{201C}\(e.phrase)\u{201D}").font(.display(30)).foregroundStyle(Ink.ink)
            HStack(spacing: 10) {
                ForEach(0..<e.samples, id: \.self) { i in
                    let lit = i < e.takes
                    let current = i == e.takes && e.stage == "takes"
                    let fresh = lit && i == e.takes - 1 && (e.event_ago ?? 9) < 0.6
                    Circle()
                        .fill(lit ? accent : Ink.sunk)
                        .overlay(Circle().stroke(current ? accent : .clear, lineWidth: 2))
                        .frame(width: 22, height: 22)
                        .scaleEffect(fresh ? 1.25 : 1.0)
                        .animation(.spring(response: 0.3, dampingFraction: 0.5), value: e.takes)
                }
            }
            Text(e.message)
                .font(.ui(17, .medium))
                .foregroundStyle(["short", "long"].contains(e.event ?? "") && (e.event_ago ?? 9) < 2 ? Ink.signal : Ink.ink)
                .fixedSize(horizontal: false, vertical: true)
            if e.stage == "takes" {
                levelBar(e.level_over, recording: e.recording ?? false)
            } else if e.stage == "talk" {
                talkRing(e)
            } else {
                HStack(spacing: 10) {
                    ProgressView().tint(accent)
                    Text("Learning your phrase from the takes.").font(.ui(13)).foregroundStyle(Ink.dim)
                }
            }
            if e.stage != "building" {
                ActionPill(title: "Stop", filled: false) { cancel() }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Round.hero, style: .continuous).fill(Ink.plaster))
    }

    private func levelBar(_ over: Double?, recording: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Ink.sunk)
                    Capsule().fill(recording ? accent : Ink.dim)
                        .frame(width: max(6, geo.size.width * CGFloat(min(1, max(0, (over ?? 0) / 30)))))
                        .animation(.easeOut(duration: 0.15), value: over ?? 0)
                    Rectangle().fill(Ink.ink.opacity(0.6)).frame(width: 2).offset(x: geo.size.width * 9 / 30)
                }
            }
            .frame(height: 10)
            Text(recording ? "Hearing a take." : "Past the mark, the wall hears you.")
                .font(.ui(11)).foregroundStyle(Ink.faint)
        }
    }

    private func talkRing(_ e: EnrollState) -> some View {
        let total = e.talk_s ?? 10
        let left = e.talk_left ?? total
        return HStack(spacing: 14) {
            ZStack {
                Circle().stroke(Ink.sunk, lineWidth: 6)
                Circle().trim(from: 0, to: CGFloat(1 - left / max(1, total)))
                    .stroke(accent, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 0.25), value: left)
                Text("\(Int(left.rounded(.up)))").font(.display(20)).foregroundStyle(Ink.ink)
            }
            .frame(width: 64, height: 64)
            Text("Talk about anything: the weather, dinner, what is playing.")
                .font(.ui(13)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func doneCard(_ e: EnrollState) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "checkmark.circle.fill").font(.system(size: 28)).foregroundStyle(accent)
                Text("Learnt").font(.display(26)).foregroundStyle(Ink.ink)
            }
            Text("\u{201C}\(e.phrase)\u{201D} is the wake word now.").font(.ui(16, .medium)).foregroundStyle(Ink.ink)
            Text(qualityLine(e.quality)).font(.ui(13)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                ActionPill(title: "Done", filled: true) { dismiss() }
                ActionPill(title: "Teach it again", filled: false) {
                    phrase = e.phrase
                    enroll = nil
                    watching = false
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Round.hero, style: .continuous).fill(Ink.plaster))
    }

    private func qualityLine(_ q: String?) -> String {
        switch q {
        case "good": return "It stands well apart from ordinary talk. Say it and watch the meter on the Voice page."
        case "fair": return "It stands apart from talk, though not by much. If it wakes by mistake, move the sensitivity mark right, or teach a longer phrase."
        default: return "It sounds a lot like ordinary talk to the wall. A longer or less common phrase will work better."
        }
    }

    private func start() {
        guard typed.count >= 3, !starting else { return }
        starting = true
        problem = nil
        let h = wall.host, p = typed
        Task {
            let (code, json) = await VoiceStatus.send(host: h, path: "/voice/enroll", body: ["phrase": p, "samples": 6])
            if code == 200 {
                if let e = json["enroll"] as? [String: Any], let d = try? JSONSerialization.data(withJSONObject: e),
                   let st = try? JSONDecoder().decode(EnrollState.self, from: d) {
                    enroll = st
                }
                watching = true
                Taps.commit()
            } else {
                problem = json["error"] as? String ?? "The wall could not start listening."
            }
            starting = false
        }
    }

    private func cancel() {
        let h = wall.host
        Task {
            _ = await VoiceStatus.send(host: h, path: "/voice/enroll/cancel", body: [:])
            enroll = nil
            watching = false
        }
    }
}
