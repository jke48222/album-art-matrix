// Games on the wall.
//
// The wall is the board and this phone is the hand. The sheet lists the
// games the wall knows (GET /game/list); a game's screen shows the same
// board the wall shows, drawn natively where it can be, takes moves by
// touch or by voice, and polls GET /game once a second, redrawing only when
// the wall's sequence number moves. Speech is this phone's own recogniser,
// primed with the game's words, so "crane" arrives as crane and not as
// "crayon"; the wall's ears do the same job when the app is closed.

import SwiftUI
import Speech
import AVFoundation

// MARK: - What the wall says about a game

struct GameStatus: Decodable {
    struct Game: Decodable {
        var name: String
        var title: String
        var players: [String]
        var over: Bool
        var won: Bool
        var winner: String?
        var message: String
        var seq: Int
        var voice: Bool?
        // Wordle
        var rows: [WordleRow]?
        var keys: [String: String]?
        var guesses_left: Int?
        var turn: String?
        var answer: String?
    }
    struct WordleRow: Decodable { var word: String; var marks: String }
    struct Score: Decodable { var played: Int; var won: Int; var streak: Int; var best: Int }
    var running: Bool
    var seq: Int
    var game: Game?
    var scores: [String: Score]?
    var voice_words: [String]?
    var error: String?
}

struct GameCard: Decodable, Identifiable {
    var name: String
    var title: String
    var blurb: String
    var players: [Int]
    var voice: Bool
    var id: String { name }
}

struct GameList: Decodable {
    var games: [GameCard]
}

enum GameLink {
    static func list(host: String) async -> [GameCard] {
        guard !host.isEmpty, let url = URL(string: "http://\(host)/game/list") else { return [] }
        var req = URLRequest(url: url); req.timeoutInterval = 6
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let list = try? JSONDecoder().decode(GameList.self, from: data) else { return [] }
        return list.games
    }

    static func status(host: String) async -> GameStatus? {
        guard !host.isEmpty, let url = URL(string: "http://\(host)/game") else { return nil }
        var req = URLRequest(url: url); req.timeoutInterval = 6
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? JSONDecoder().decode(GameStatus.self, from: data)
    }

    /// POST /game/<action>; the wall answers with the status either way.
    static func post(host: String, _ action: String, _ body: [String: Any]) async -> GameStatus? {
        guard !host.isEmpty, let url = URL(string: "http://\(host)/game/\(action)") else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 10
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        guard let (data, _) = try? await URLSession.shared.data(for: req) else { return nil }
        return try? JSONDecoder().decode(GameStatus.self, from: data)
    }
}

// MARK: - The phone's ear, primed with the game's words

@Observable
final class SpeechMove {
    var listening = false
    var heard = ""
    var problem: String?
    var available: Bool { SFSpeechRecognizer(locale: .current)?.isAvailable ?? false }

    private var engine: AVAudioEngine?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var settle: Task<Void, Never>?
    private var onFinal: ((String) -> Void)?

    func start(words: [String], onFinal: @escaping (String) -> Void) {
        guard !listening else { return }
        self.onFinal = onFinal
        SFSpeechRecognizer.requestAuthorization { auth in
            DispatchQueue.main.async {
                guard auth == .authorized else { self.problem = "Speech recognition is not allowed for Tessera."; return }
                AVAudioApplication.requestRecordPermission { ok in
                    DispatchQueue.main.async {
                        guard ok else { self.problem = "The microphone is not allowed for Tessera."; return }
                        self.begin(words: words)
                    }
                }
            }
        }
    }

    private func begin(words: [String]) {
        guard let recognizer = SFSpeechRecognizer(locale: .current), recognizer.isAvailable else {
            problem = "Speech recognition is not available right now."; return
        }
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
            try session.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            problem = "The microphone could not be opened."; return
        }
        let engine = AVAudioEngine()
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.contextualStrings = Array(words.prefix(3000))
        if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = false }
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in request.append(buffer) }
        engine.prepare()
        do { try engine.start() } catch { problem = "The microphone could not start."; return }
        self.engine = engine
        self.request = request
        heard = ""
        problem = nil
        listening = true
        Taps.detent(intensity: 0.5)
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            if let result {
                let text = result.bestTranscription.formattedString
                DispatchQueue.main.async {
                    self.heard = text
                    // a pause after the words is the end of the move
                    self.settle?.cancel()
                    self.settle = Task { [weak self] in
                        try? await Task.sleep(for: .seconds(1.1))
                        guard let self, !Task.isCancelled else { return }
                        self.finish(text)
                    }
                }
                if result.isFinal { DispatchQueue.main.async { self.finish(text) } }
            }
            if error != nil { DispatchQueue.main.async { self.stop() } }
        }
        // nothing said at all: give up after eight seconds
        settle = Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            guard let self, !Task.isCancelled else { return }
            self.stop()
        }
    }

    private func finish(_ text: String) {
        guard listening else { return }
        stop()
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty { onFinal?(t) }
    }

    func stop() {
        settle?.cancel(); settle = nil
        task?.cancel(); task = nil
        request?.endAudio(); request = nil
        engine?.stop(); engine?.inputNode.removeTap(onBus: 0); engine = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        listening = false
    }
}

// MARK: - The sheet: the games, and the one that is on

struct GamesSheet: View {
    @Environment(WallSession.self) private var wall
    @Environment(\.dismiss) private var dismiss
    let accent: Color
    @AppStorage("games.player") private var player = ""
    @State private var cards: [GameCard] = []
    @State private var status: GameStatus?
    @State private var starting: String?
    @State private var problem: String?

    private var me: String { player.trimmingCharacters(in: .whitespaces).isEmpty ? "You" : player.trimmingCharacters(in: .whitespaces) }

    var body: some View {
        NavigationStack {
            ZStack {
                Ink.ground.ignoresSafeArea()
                ScrollView {
                    VStack(spacing: 18) {
                        if let g = status?.game, status?.running == true {
                            SetupGroup("On the wall now", note: g.message) {
                                NavigationLink {
                                    GameScreen(accent: accent, name: g.name, status: $status)
                                } label: {
                                    SetupRow(title: g.title, subtitle: g.players.joined(separator: ", ")) {
                                        StateValue(g.over ? "Over" : "Playing", done: !g.over)
                                    }
                                }
                                .buttonStyle(PressStyle(scale: 0.99))
                                Rule()
                                SetupRow(title: "Put it down", subtitle: "The wall goes back to what it was doing.") {
                                    ActionPill(title: "End", filled: false) { end() }
                                }
                            }
                        }
                        SetupGroup("Your name", note: "On the scoreboard, and whose turn it is.") {
                            KeyField(placeholder: "You", text: $player)
                        }
                        SetupGroup("Games", note: cards.isEmpty ? "The wall is not answering, or games are off on it." : "Tap one to start it on the wall.") {
                            ForEach(Array(cards.enumerated()), id: \.element.id) { i, card in
                                if i > 0 { Rule() }
                                SetupRow(title: card.title, subtitle: card.blurb) {
                                    ActionPill(title: starting == card.name ? "Starting" : "Play", filled: true) { start(card) }
                                }
                            }
                        }
                        Problem(text: problem ?? status?.error)
                        if let scores = status?.scores, !scores.isEmpty, let g = status?.game {
                            SetupGroup("\(g.title) scores", note: nil) {
                                ForEach(Array(scores.keys.sorted().enumerated()), id: \.element) { i, who in
                                    if i > 0 { Rule() }
                                    let s = scores[who]!
                                    SetupRow(title: who, subtitle: "\(s.won) of \(s.played), streak \(s.streak), best \(s.best)") { EmptyView() }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 16).padding(.vertical, 18)
                }
            }
            .navigationTitle("Games")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
            .task {
                cards = await GameLink.list(host: wall.host)
                while !Task.isCancelled {
                    if let s = await GameLink.status(host: wall.host) { status = s }
                    try? await Task.sleep(for: .seconds(2))
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private func start(_ card: GameCard) {
        guard starting == nil else { return }
        starting = card.name
        let h = wall.host, who = me
        Task {
            let s = await GameLink.post(host: h, "start", ["name": card.name, "players": [who]])
            if let s, s.error == nil { status = s; problem = nil; Taps.commit() }
            else { problem = s?.error ?? "The wall could not start it." }
            starting = nil
        }
    }

    private func end() {
        let h = wall.host
        Task {
            if let s = await GameLink.post(host: h, "end", [:]) { status = s }
            Taps.detent(intensity: 0.4)
        }
    }
}

// MARK: - One game: the board, the hand, the ear

struct GameScreen: View {
    @Environment(WallSession.self) private var wall
    let accent: Color
    let name: String
    @Binding var status: GameStatus?
    @AppStorage("games.player") private var player = ""
    @State private var typed = ""
    @State private var speech = SpeechMove()
    @State private var problem: String?
    @State private var sending = false
    @FocusState private var typing: Bool

    private var me: String { player.trimmingCharacters(in: .whitespaces).isEmpty ? "You" : player.trimmingCharacters(in: .whitespaces) }
    private var game: GameStatus.Game? { status?.game }

    var body: some View {
        ZStack {
            Ink.ground.ignoresSafeArea()
            ScrollView {
                VStack(spacing: 16) {
                    if let g = game {
                        board(g)
                            .padding(.horizontal, 24)
                        Text(g.message)
                            .font(.ui(15, .medium)).foregroundStyle(g.over ? (g.won ? Ink.moss : Ink.tile) : Ink.ink)
                            .multilineTextAlignment(.center)
                        if !g.over {
                            hand(g)
                        } else {
                            ActionPill(title: "Play again", filled: true) { again(g) }
                        }
                        if let p = problem ?? speech.problem {
                            Text(p).font(.ui(12)).foregroundStyle(Ink.signal).multilineTextAlignment(.center)
                        }
                    } else {
                        Text("Nothing on the wall.").font(.ui(15)).foregroundStyle(Ink.dim).padding(.top, 40)
                    }
                }
                .padding(.vertical, 20)
            }
        }
        .navigationTitle(game?.title ?? "Game")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            while !Task.isCancelled {
                if let s = await GameLink.status(host: wall.host) { status = s }
                try? await Task.sleep(for: .seconds(1))
            }
        }
        .onDisappear { speech.stop() }
    }

    @ViewBuilder private func board(_ g: GameStatus.Game) -> some View {
        switch g.name {
        case "wordle": WordleBoard(game: g, typed: typed, accent: accent)
        default: WallBoard()
        }
    }

    @ViewBuilder private func hand(_ g: GameStatus.Game) -> some View {
        HStack(spacing: 10) {
            TextField(g.name == "wordle" ? "five letters" : "your move", text: $typed)
                .font(.machine(17))
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .focused($typing)
                .onSubmit { send() }
                .padding(.horizontal, 14).frame(minHeight: 48)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Ink.plaster))
            ActionPill(title: sending ? "Sending" : "Send", filled: true) { send() }
            if g.voice ?? true {
                Button {
                    if speech.listening { speech.stop() } else { listen() }
                } label: {
                    Image(systemName: speech.listening ? "waveform" : "mic")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(speech.listening ? Ink.ground : Ink.ink)
                        .frame(width: 48, height: 48)
                        .background(Circle().fill(speech.listening ? accent : Ink.plaster))
                }
                .buttonStyle(PressStyle(scale: 0.94))
            }
        }
        .padding(.horizontal, 16)
        if speech.listening {
            Text(speech.heard.isEmpty ? "Listening." : speech.heard)
                .font(.ui(13)).foregroundStyle(Ink.dim)
        }
    }

    private func listen() {
        problem = nil
        speech.start(words: status?.voice_words ?? []) { text in
            let h = wall.host, who = me
            Task {
                if let s = await GameLink.post(host: h, "hear", ["text": text, "player": who]) {
                    status = s
                    problem = s.error
                    if s.error == nil { Taps.commit() }
                }
            }
        }
    }

    private func send() {
        let word = typed.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !word.isEmpty, !sending else { return }
        sending = true
        let h = wall.host, who = me
        Task {
            let s = await GameLink.post(host: h, "move", ["player": who, "move": ["guess": word]])
            if let s {
                status = s
                problem = s.error
                if s.error == nil { typed = ""; Taps.commit() } else { Taps.detent(intensity: 0.3) }
            } else {
                problem = "The wall is not answering."
            }
            sending = false
        }
    }

    private func again(_ g: GameStatus.Game) {
        let h = wall.host, who = me
        Task {
            if let s = await GameLink.post(host: h, "start", ["name": g.name, "players": g.players.isEmpty ? [who] : g.players]) {
                status = s
                Taps.commit()
            }
        }
    }
}

/// The wall's own frame, for a game with no native board on the phone yet.
struct WallBoard: View {
    @Environment(WallSession.self) private var wall
    var body: some View {
        PanelCanvas(px: wall.frame.map { [UInt8]($0) }, duty: 1.0)
            .aspectRatio(1, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

// MARK: - Wordle, drawn natively

struct WordleBoard: View {
    let game: GameStatus.Game
    let typed: String
    let accent: Color

    private func colour(_ m: Character) -> Color {
        switch m {
        case "g": return Color(red: 83 / 255, green: 141 / 255, blue: 78 / 255)
        case "y": return Color(red: 181 / 255, green: 159 / 255, blue: 59 / 255)
        default: return Color(red: 58 / 255, green: 58 / 255, blue: 60 / 255)
        }
    }

    var body: some View {
        let rows = game.rows ?? []
        let current = Array(typed.uppercased().prefix(5))
        VStack(spacing: 6) {
            ForEach(0..<6, id: \.self) { r in
                HStack(spacing: 6) {
                    ForEach(0..<5, id: \.self) { c in
                        let filled = r < rows.count
                        let letter: String = filled ? String(Array(rows[r].word.uppercased())[c])
                            : (r == rows.count && c < current.count ? String(current[c]) : "")
                        let mark: Character? = filled ? Array(rows[r].marks)[c] : nil
                        Text(letter)
                            .font(.system(size: 26, weight: .bold, design: .rounded))
                            .foregroundStyle(Ink.ink)
                            .frame(maxWidth: .infinity)
                            .aspectRatio(1, contentMode: .fit)
                            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(mark.map(colour) ?? Ink.plaster))
                            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(mark == nil ? Ink.hairline : .clear, lineWidth: 1))
                    }
                }
            }
            keyboard
                .padding(.top, 10)
        }
    }

    private var keyboard: some View {
        let keys = game.keys ?? [:]
        return VStack(spacing: 5) {
            ForEach(["QWERTYUIOP", "ASDFGHJKL", "ZXCVBNM"], id: \.self) { row in
                HStack(spacing: 4) {
                    ForEach(Array(row), id: \.self) { ch in
                        let m = keys[String(ch).lowercased()]
                        Text(String(ch))
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .foregroundStyle(m == nil ? Ink.dim : Ink.ink)
                            .frame(maxWidth: .infinity, minHeight: 30)
                            .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(m.flatMap { $0.first }.map(colour) ?? Ink.sunk))
                    }
                }
            }
        }
    }
}
