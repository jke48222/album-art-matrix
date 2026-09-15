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

/// Any JSON, for the parts of a game's state that differ game by game.
enum JSONValue: Decodable {
    case string(String), number(Double), bool(Bool), null
    case array([JSONValue]), object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else if let o = try? c.decode([String: JSONValue].self) { self = .object(o) }
        else { self = .null }
    }

    subscript(key: String) -> JSONValue {
        if case .object(let o) = self, let v = o[key] { return v }
        return .null
    }
    subscript(index: Int) -> JSONValue {
        if case .array(let a) = self, index >= 0, index < a.count { return a[index] }
        return .null
    }
    var string: String? { if case .string(let s) = self { return s }; return nil }
    var double: Double? { if case .number(let n) = self { return n }; return nil }
    var int: Int? { double.map { Int($0) } }
    var bool: Bool? { if case .bool(let b) = self { return b }; return nil }
    var array: [JSONValue] { if case .array(let a) = self { return a }; return [] }
    var object: [String: JSONValue] { if case .object(let o) = self { return o }; return [:] }
    var strings: [String] { array.compactMap { $0.string } }
    var ints: [Int] { array.compactMap { $0.int } }
    var isNull: Bool { if case .null = self { return true }; return false }
}

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
        /// The whole state, for the boards: `state["rows"]`, `state["grid"]`.
        var state: JSONValue

        private enum Keys: String, CodingKey { case name, title, players, over, won, winner, message, seq, voice }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Keys.self)
            name = try c.decode(String.self, forKey: .name)
            title = try c.decode(String.self, forKey: .title)
            players = (try? c.decode([String].self, forKey: .players)) ?? []
            over = (try? c.decode(Bool.self, forKey: .over)) ?? false
            won = (try? c.decode(Bool.self, forKey: .won)) ?? false
            winner = try? c.decode(String.self, forKey: .winner)
            message = (try? c.decode(String.self, forKey: .message)) ?? ""
            seq = (try? c.decode(Int.self, forKey: .seq)) ?? 0
            voice = try? c.decode(Bool.self, forKey: .voice)
            state = (try? JSONValue(from: decoder)) ?? .null
        }
    }
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
    @Environment(\.dismiss) private var dismiss
    let accent: Color

    var body: some View {
        NavigationStack {
            GamesSheetBody(accent: accent)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
        }
        .preferredColorScheme(.dark)
    }
}

/// The games: the one that is on, the list to start, the scores. Inside a
/// navigation stack of the caller's, a sheet from the faces or a page from
/// Settings.
struct GamesSheetBody: View {
    @Environment(WallSession.self) private var wall
    let accent: Color
    @AppStorage("games.player") private var player = ""
    @State private var cards: [GameCard] = []
    @State private var status: GameStatus?
    @State private var starting: String?
    @State private var problem: String?
    @State private var editingName = false

    private var me: String { player.trimmingCharacters(in: .whitespaces).isEmpty ? "You" : player.trimmingCharacters(in: .whitespaces) }
    private var columns: [GridItem] { Array(repeating: GridItem(.flexible(), spacing: 10), count: 2) }

    var body: some View {
            ZStack {
                Ink.ground.ignoresSafeArea()
                ScrollView {
                    VStack(spacing: 22) {
                        if let g = status?.game, status?.running == true {
                            NavigationLink {
                                GameScreen(accent: accent, name: g.name, status: $status)
                            } label: {
                                hero(g)
                            }
                            .buttonStyle(PressStyle(scale: 0.985))
                        }
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(alignment: .firstTextBaseline) {
                                Text("Games").font(.display(24)).foregroundStyle(Ink.ink)
                                Spacer()
                                Button { editingName = true } label: {
                                    HStack(spacing: 6) {
                                        Image(systemName: "person").font(.system(size: 12, weight: .semibold))
                                        Text(me).font(.ui(13, .semibold))
                                    }
                                    .foregroundStyle(Ink.dim)
                                    .padding(.horizontal, 10).padding(.vertical, 6)
                                    .background(Capsule().fill(Ink.plaster))
                                }
                                .buttonStyle(PressStyle(scale: 0.95))
                            }
                            if cards.isEmpty {
                                Text("The wall is not answering, or games are off on it.")
                                    .font(.ui(13)).foregroundStyle(Ink.dim)
                            }
                            LazyVGrid(columns: columns, spacing: 10) {
                                ForEach(cards) { card in
                                    Button { start(card) } label: { tile(card) }
                                        .buttonStyle(PressStyle(scale: 0.96))
                                        .disabled(starting != nil)
                                }
                            }
                        }
                        Problem(text: problem ?? status?.error)
                        if let scores = status?.scores, !scores.isEmpty, let g = status?.game {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("\(g.title) so far").font(.ui(13, .semibold)).foregroundStyle(Ink.dim)
                                ForEach(scores.keys.sorted(), id: \.self) { who in
                                    let s = scores[who]!
                                    HStack(spacing: 10) {
                                        Text(who).font(.ui(14)).foregroundStyle(Ink.ink).frame(width: 90, alignment: .leading)
                                        GeometryReader { geo in
                                            ZStack(alignment: .leading) {
                                                Capsule().fill(Ink.plaster)
                                                Capsule().fill(accent).frame(width: max(6, geo.size.width * CGFloat(s.played == 0 ? 0 : Double(s.won) / Double(s.played))))
                                            }
                                        }
                                        .frame(height: 6)
                                        Text("\(s.won)/\(s.played)").font(.machine(12)).foregroundStyle(Ink.dim).frame(width: 44, alignment: .trailing)
                                        Text(s.streak > 1 ? "×\(s.streak)" : "").font(.machine(12)).foregroundStyle(Ink.tile).frame(width: 28, alignment: .trailing)
                                    }
                                }
                            }
                            .padding(16)
                            .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Ink.plaster.opacity(0.6)))
                        }
                    }
                    .padding(.horizontal, 16).padding(.vertical, 18)
                }
            }
            .alert("Your name", isPresented: $editingName) {
                TextField("You", text: $player)
                Button("Done") {}
            } message: { Text("On the scoreboard, and whose turn it is.") }
            .task {
                cards = await GameLink.list(host: wall.host)
                while !Task.isCancelled {
                    if let s = await GameLink.status(host: wall.host) { status = s }
                    try? await Task.sleep(for: .seconds(2))
                }
            }
    }

    /// The game that is on: the wall's own frame, large, and its line.
    private func hero(_ g: GameStatus.Game) -> some View {
        HStack(spacing: 14) {
            PanelCanvas(px: wall.frame.map { [UInt8]($0) }, duty: 1.0)
                .frame(width: 112, height: 112)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            VStack(alignment: .leading, spacing: 6) {
                Text(g.over ? "Over" : "On the wall").font(.ui(11, .semibold)).foregroundStyle(GameMotif.colour(g.name))
                Text(g.title).font(.display(22)).foregroundStyle(Ink.ink)
                Text(g.message).font(.ui(13)).foregroundStyle(Ink.dim).lineLimit(2)
                Text(g.players.joined(separator: ", ")).font(.machine(11)).foregroundStyle(Ink.faint)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").foregroundStyle(Ink.faint)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Ink.plaster))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(GameMotif.colour(g.name).opacity(0.5), lineWidth: 1))
    }

    private func tile(_ card: GameCard) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            GameMotif(name: card.name)
                .frame(height: 64)
                .frame(maxWidth: .infinity)
            Text(card.title).font(.ui(15, .semibold)).foregroundStyle(Ink.ink).lineLimit(1)
            Text(card.blurb).font(.ui(11)).foregroundStyle(Ink.dim).lineLimit(2).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                if card.players[1] > 1 {
                    Image(systemName: "person.2").font(.system(size: 10)).foregroundStyle(Ink.faint)
                }
                if card.voice {
                    Image(systemName: "waveform").font(.system(size: 10)).foregroundStyle(Ink.faint)
                }
                Spacer()
                Text(starting == card.name ? "Starting" : "Play").font(.ui(12, .semibold)).foregroundStyle(GameMotif.colour(card.name))
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Ink.plaster))
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
}

/// A small drawing for each game, in its colour: the board's own shape as
/// a badge, drawn in the panel's spirit (blocks, not lines).
struct GameMotif: View {
    let name: String

    static func colour(_ name: String) -> Color {
        switch name {
        case "wordle": return Color(red: 83 / 255, green: 141 / 255, blue: 78 / 255)
        case "connections": return Color(red: 150 / 255, green: 100 / 255, blue: 190 / 255)
        case "sudoku": return Color(red: 120 / 255, green: 180 / 255, blue: 250 / 255)
        case "spellingbee": return Color(red: 232 / 255, green: 178 / 255, blue: 44 / 255)
        case "letterboxed": return Color(red: 196 / 255, green: 166 / 255, blue: 56 / 255)
        case "strands": return Color(red: 70 / 255, green: 122 / 255, blue: 210 / 255)
        case "crossword": return Color(red: 196 / 255, green: 166 / 255, blue: 56 / 255)
        case "contexto": return Color(red: 78 / 255, green: 150 / 255, blue: 84 / 255)
        case "heardle": return Color(red: 196 / 255, green: 166 / 255, blue: 56 / 255)
        case "sliding", "reveal", "pictionary": return Color(red: 226 / 255, green: 140 / 255, blue: 46 / 255)
        case "twentyq", "quiz": return Color(red: 232 / 255, green: 178 / 255, blue: 44 / 255)
        case "whistlebird": return Color(red: 78 / 255, green: 150 / 255, blue: 84 / 255)
        case "reaction": return Color(red: 78 / 255, green: 150 / 255, blue: 84 / 255)
        case "pong", "snake", "tetris": return Color(red: 74 / 255, green: 196 / 255, blue: 214 / 255)
        default: return Ink.dim
        }
    }

    var body: some View {
        Canvas { ctx, size in
            let c = Self.colour(name)
            let dim = Ink.faint
            func block(_ x: Double, _ y: Double, _ w: Double, _ h: Double, _ col: Color, r: Double = 3) {
                ctx.fill(Path(roundedRect: CGRect(x: x, y: y, width: w, height: h), cornerRadius: r), with: .color(col))
            }
            let W = size.width, H = size.height
            let cx = W / 2, cy = H / 2
            switch name {
            case "wordle":
                let marks: [[Int]] = [[0, 0, 2, 0, 2], [0, 1, 1, 1, 1], [2, 2, 2, 2, 2]]
                for (r, row) in marks.enumerated() {
                    for (k, m) in row.enumerated() {
                        block(cx - 52 + Double(k) * 21, cy - 30 + Double(r) * 21, 17, 17, m == 2 ? c : m == 1 ? Color(red: 196 / 255, green: 166 / 255, blue: 56 / 255) : Ink.sunk)
                    }
                }
            case "connections":
                let cols: [Color] = [Color(red: 196 / 255, green: 166 / 255, blue: 56 / 255), Color(red: 83 / 255, green: 141 / 255, blue: 78 / 255),
                                     Color(red: 70 / 255, green: 122 / 255, blue: 210 / 255), c]
                for (r, col) in cols.enumerated() { block(cx - 48, cy - 30 + Double(r) * 15, 96, 12, col, r: 4) }
            case "sudoku":
                for r in 0..<3 { for k in 0..<3 { block(cx - 30 + Double(k) * 21, cy - 30 + Double(r) * 21, 18, 18, (r + k) % 2 == 0 ? c.opacity(0.9) : Ink.sunk, r: 3) } }
            case "spellingbee":
                for k in 0..<6 {
                    let a = Double(k) * .pi / 3
                    ctx.fill(Path(ellipseIn: CGRect(x: cx + cos(a) * 24 - 9, y: cy + sin(a) * 24 - 9, width: 18, height: 18)), with: .color(Ink.sunk))
                }
                ctx.fill(Path(ellipseIn: CGRect(x: cx - 11, y: cy - 11, width: 22, height: 22)), with: .color(c))
            case "letterboxed":
                ctx.stroke(Path(CGRect(x: cx - 26, y: cy - 26, width: 52, height: 52)), with: .color(dim), lineWidth: 2)
                var p = Path(); p.move(to: CGPoint(x: cx - 26, y: cy - 8)); p.addLine(to: CGPoint(x: cx + 8, y: cy + 26)); p.addLine(to: CGPoint(x: cx + 26, y: cy - 12)); p.addLine(to: CGPoint(x: cx - 10, y: cy - 26))
                ctx.stroke(p, with: .color(c), lineWidth: 3)
            case "strands":
                for r in 0..<3 { for k in 0..<5 { ctx.fill(Path(ellipseIn: CGRect(x: cx - 46 + Double(k) * 21, y: cy - 28 + Double(r) * 21, width: 14, height: 14)), with: .color((r == 1 && k >= 1 && k <= 3) || (r == 0 && k == 4) ? c : Ink.sunk)) } }
            case "crossword":
                for r in 0..<3 { for k in 0..<3 { block(cx - 30 + Double(k) * 21, cy - 30 + Double(r) * 21, 18, 18, (r == 0 && k == 0) || (r == 2 && k == 2) ? Ink.ground : Ink.sunk, r: 3) } }
                block(cx - 9, cy - 30, 18, 18, c, r: 3)
            case "contexto":
                for (k, w) in [70.0, 46.0, 28.0, 12.0].enumerated() { block(cx - 40, cy - 28 + Double(k) * 15, w, 10, k == 3 ? c : Ink.sunk, r: 5) }
            case "heardle":
                for (k, w) in [6.0, 10.0, 16.0, 24.0, 34.0].enumerated() { block(cx - 50 + Double(k) * 21, cy - 8, w, 16, k < 2 ? c : Ink.sunk, r: 5) }
            case "sliding":
                for r in 0..<3 { for k in 0..<3 { if !(r == 2 && k == 2) { block(cx - 30 + Double(k) * 21, cy - 30 + Double(r) * 21, 18, 18, c.opacity(0.4 + 0.2 * Double((r * 3 + k) % 3)), r: 3) } } }
            case "reveal":
                ctx.fill(Path(ellipseIn: CGRect(x: cx - 26, y: cy - 26, width: 52, height: 52)), with: .color(c.opacity(0.25)))
                ctx.fill(Path(ellipseIn: CGRect(x: cx - 16, y: cy - 16, width: 32, height: 32)), with: .color(c.opacity(0.5)))
                ctx.fill(Path(ellipseIn: CGRect(x: cx - 6, y: cy - 6, width: 12, height: 12)), with: .color(c))
            case "twentyq":
                ctx.draw(Text("?").font(.system(size: 44, weight: .black, design: .rounded)).foregroundStyle(c), at: CGPoint(x: cx, y: cy))
            case "pictionary":
                ctx.fill(Path(ellipseIn: CGRect(x: cx - 28, y: cy - 16, width: 40, height: 32)), with: .color(c))
                block(cx + 8, cy - 4, 14, 24, c, r: 4)
            case "quiz":
                ctx.stroke(Path(ellipseIn: CGRect(x: cx - 24, y: cy - 24, width: 48, height: 48)), with: .color(Ink.sunk), lineWidth: 5)
                var p = Path(); p.addArc(center: CGPoint(x: cx, y: cy), radius: 24, startAngle: .degrees(-90), endAngle: .degrees(150), clockwise: false)
                ctx.stroke(p, with: .color(c), style: StrokeStyle(lineWidth: 5, lineCap: .round))
            case "whistlebird":
                block(cx - 40, cy - 30, 10, 26, c, r: 2); block(cx - 40, cy + 12, 10, 18, c, r: 2)
                block(cx + 26, cy - 30, 10, 16, c, r: 2); block(cx + 26, cy + 2, 10, 28, c, r: 2)
                block(cx - 8, cy - 4, 14, 9, Color(red: 196 / 255, green: 166 / 255, blue: 56 / 255), r: 3)
            case "reaction":
                block(cx - 44, cy - 22, 40, 44, Color(red: 0.62, green: 0.14, blue: 0.14), r: 8)
                block(cx + 4, cy - 22, 40, 44, c, r: 8)
            case "pong":
                block(cx - 44, cy - 14, 5, 28, Ink.ink, r: 2); block(cx + 39, cy - 4, 5, 28, Ink.ink, r: 2)
                block(cx - 2, cy - 2, 6, 6, c, r: 1)
                for k in 0..<5 { block(cx - 1, cy - 30 + Double(k) * 13, 2, 6, dim, r: 1) }
            case "snake":
                for k in 0..<6 { block(cx - 40 + Double(k) * 12, cy - 6, 10, 10, c.opacity(0.4 + 0.1 * Double(k)), r: 2) }
                block(cx + 30, cy - 6, 10, 10, c, r: 3)
                ctx.fill(Path(ellipseIn: CGRect(x: cx + 8, y: cy - 26, width: 10, height: 10)), with: .color(Color(red: 200 / 255, green: 66 / 255, blue: 56 / 255)))
            case "tetris":
                let cells = [(0, 2), (1, 2), (2, 2), (1, 1), (4, 2), (4, 1), (5, 2), (5, 1), (3, 0), (3, 1), (3, 2)]
                for (k, cell) in cells.enumerated() { block(cx - 42 + Double(cell.0) * 14, cy - 20 + Double(cell.1) * 14, 12, 12, k < 4 ? c : k < 8 ? Color(red: 196 / 255, green: 166 / 255, blue: 56 / 255) : Ink.sunk, r: 2) }
            default:
                ctx.fill(Path(ellipseIn: CGRect(x: cx - 12, y: cy - 12, width: 24, height: 24)), with: .color(c))
            }
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
                        if !["sliding", "whistlebird", "pictionary", "pong", "snake", "tetris"].contains(g.name) {
                            WallStrip(colour: GameMotif.colour(g.name),
                                      message: g.players.count > 1 ? g.players.joined(separator: ", ") : "The same board, live.")
                                .padding(.horizontal, 16)
                        }
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
        case "sudoku": SudokuBoard(game: g, accent: accent, send: post)
        case "connections": ConnectionsBoard(game: g, accent: accent, send: post)
        case "spellingbee": SpellingBeeBoard(game: g, accent: accent, send: post)
        case "letterboxed": LetterBoxedBoard(game: g, accent: accent, send: post)
        case "strands": StrandsBoard(game: g, accent: accent, send: post)
        case "crossword": CrosswordBoard(game: g, accent: accent, send: post)
        case "contexto": ContextoBoard(game: g, accent: accent)
        case "heardle": HeardleBoard(game: g, accent: accent, send: post)
        case "sliding": SlidingBoard(game: g, accent: accent, send: post)
        case "reaction": ReactionBoard(game: g, accent: accent, send: post)
        case "whistlebird": WhistleBirdBoard(game: g, accent: accent, send: post)
        case "twentyq": TwentyQBoard(game: g, accent: accent, send: post)
        case "quiz": QuizBoard(game: g, accent: accent)
        case "pictionary": PictionaryBoard(game: g, accent: accent)
        case "pong": PongBoard(game: g, accent: accent, send: post)
        case "snake": SnakeBoard(game: g, accent: accent, send: post)
        case "tetris": TetrisBoard(game: g, accent: accent, send: post)
        default: WallBoard()
        }
    }

    /// Games whose whole hand is on their board: no word field under them.
    private var wordless: Set<String> { ["sudoku", "sliding", "reaction", "whistlebird", "twentyq", "pong", "snake", "tetris"] }

    /// A move from a board, straight to the wall; the status comes back.
    private func post(_ move: [String: Any]) {
        let h = wall.host, who = me
        Task {
            if let s = await GameLink.post(host: h, "move", ["player": who, "move": move]) {
                status = s
                problem = s.error
                if s.error == nil { Taps.detent(intensity: 0.3) }
            }
        }
    }

    @ViewBuilder private func hand(_ g: GameStatus.Game) -> some View {
        if wordless.contains(g.name) {
            EmptyView()
        } else {
            wordHand(g)
        }
    }

    @ViewBuilder private func wordHand(_ g: GameStatus.Game) -> some View {
        HStack(spacing: 10) {
            TextField(placeholder(g), text: $typed)
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

    private func placeholder(_ g: GameStatus.Game) -> String {
        switch g.name {
        case "wordle": return "five letters"
        case "spellingbee", "letterboxed", "strands": return "a word"
        case "contexto": return "a word, any word"
        case "heardle": return "the song"
        case "reveal": return "the album or the artist"
        case "pictionary": return "what is it?"
        case "quiz": return "your answer"
        case "connections": return "four words"
        case "crossword": return "clue and answer, like 1A lamp"
        default: return "your move"
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
        var move: [String: Any] = ["guess": word]
        switch game?.name {
        case "connections":
            let words = word.split(whereSeparator: { $0 == "," || $0 == "\n" }).map { $0.trimmingCharacters(in: .whitespaces) }
            move = words.count == 4 ? ["words": words] : ["pick": word]
        case "crossword":
            let bits = word.split(separator: " ", maxSplits: 1).map(String.init)
            move = bits.count == 2 ? ["slot": bits[0].uppercased(), "word": bits[1]] : ["word": word]
        case "quiz": move = ["answer": word]
        case "heardle": move = word == "skip" ? ["skip": true] : ["guess": word]
        default: break
        }
        Task {
            let s = await GameLink.post(host: h, "move", ["player": who, "move": move])
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

/// The wall as it is right now, small, over the phone's own board, so the
/// two are seen to agree.
struct WallStrip: View {
    @Environment(WallSession.self) private var wall
    let colour: Color
    let message: String
    var body: some View {
        HStack(spacing: 12) {
            PanelCanvas(px: wall.frame.map { [UInt8]($0) }, duty: 1.0)
                .frame(width: 64, height: 64)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                Text("On the wall").font(.ui(11, .semibold)).foregroundStyle(colour)
                Text(message).font(.ui(13)).foregroundStyle(Ink.dim).lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Ink.plaster.opacity(0.7)))
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

    private struct Row { var word: String; var marks: String }
    private var rows: [Row] {
        game.state["rows"].array.compactMap { r in
            guard let w = r["word"].string, let m = r["marks"].string else { return nil }
            return Row(word: w, marks: m)
        }
    }

    var body: some View {
        let rows = self.rows
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
                            .frame(width: 56, height: 56)
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
        let keys = game.state["keys"].object.compactMapValues { $0.string }
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
