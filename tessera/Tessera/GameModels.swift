import Foundation

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
    var int: Int? { guard let n = double, n.isFinite, n >= Double(Int.min), n < Double(Int.max) else { return nil }; return Int(n) }
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
    var session_id: String?
    var on_wall: Bool?
    var starting: String?

    private enum CodingKeys: String, CodingKey { case running, seq, game, scores, voice_words, error, session_id, on_wall, starting }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        running = try c.decode(Bool.self, forKey: .running)
        seq = try c.decode(Int.self, forKey: .seq)
        game = try c.decodeIfPresent(Game.self, forKey: .game)
        scores = try c.decodeIfPresent([String: Score].self, forKey: .scores)
        voice_words = try c.decodeIfPresent([String].self, forKey: .voice_words)
        error = try c.decodeIfPresent(String.self, forKey: .error)
        session_id = try c.decodeIfPresent(String.self, forKey: .session_id)
        on_wall = try c.decodeIfPresent(Bool.self, forKey: .on_wall)
        starting = try c.decodeIfPresent(String.self, forKey: .starting)
        guard running == (game != nil), seq >= 0 else {
            throw DecodingError.dataCorruptedError(forKey: .running, in: c, debugDescription: "Inconsistent game status")
        }
    }
}

struct GameCard: Decodable, Identifiable {
    var name: String
    var title: String
    var blurb: String
    var players: [Int]
    var voice: Bool
    var id: String { name }
    var minimumPlayers: Int { max(1, players.first ?? 1) }
    var maximumPlayers: Int { max(minimumPlayers, players.last ?? 1) }
    var category: String {
        switch name {
        case "heardle", "reveal": return "Music"
        case "pong", "snake", "tetris", "whistlebird", "reaction", "sliding": return "Arcade"
        case "twentyq", "pictionary", "quiz": return "Together"
        default: return "Puzzles"
        }
    }
    var playerLabel: String { maximumPlayers == 1 ? "Solo" : "\(minimumPlayers) to \(maximumPlayers) players" }

}

struct GameList: Decodable {
    var games: [GameCard]
    /// Set, with no games, when the wall has games switched off.
    var problem: String?
}

enum GameLink {
    enum Failure: LocalizedError {
        case message(String)
        /// The wall answered, but its games feature is switched off.
        case gamesOff
        var errorDescription: String? {
            switch self {
            case .message(let text): return text
            case .gamesOff: return "Games are off on this wall."
            }
        }
    }
    static func request(host: String, action: String, body: [String: Any]? = nil, timeout: TimeInterval? = nil) async throws -> Data {
        guard !host.isEmpty, let url = URL(string: "http://\(host)/game\(action)") else {
            throw Failure.message("Connect to your wall to play.")
        }
        var req = URLRequest(url: url); req.timeoutInterval = timeout ?? (body == nil ? 6 : 30)
        req.cachePolicy = .reloadIgnoringLocalCacheData
        if let body {
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw Failure.message("The wall sent an unreadable reply.") }
        guard (200...299).contains(http.statusCode) else {
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            throw Failure.message(json?["error"] as? String ?? "The wall couldn't complete this request.")
        }
        return data
    }
    static func catalogue(host: String) async throws -> [GameCard] {
        let list = try JSONDecoder().decode(GameList.self, from: await request(host: host, action: "/list"))
        // An empty list with a problem is a readable answer, not a failure to
        // read: the hub says games are off instead of "no games available".
        if list.games.isEmpty, list.problem != nil { throw Failure.gamesOff }
        let cards = list.games
        guard Set(cards.map(\.name)).count == cards.count,
              cards.allSatisfy({ !$0.name.isEmpty && !$0.title.isEmpty && $0.players.count == 2 && $0.players[0] >= 1 && $0.players[1] >= $0.players[0] && $0.players[1] <= 24 }) else {
            throw Failure.message("The wall sent an unreadable games list.")
        }
        return cards
    }
    static func list(host: String) async -> [GameCard] { (try? await catalogue(host: host)) ?? [] }
    static func status(host: String) async -> GameStatus? {
        guard let data = try? await request(host: host, action: "") else { return nil }
        return try? JSONDecoder().decode(GameStatus.self, from: data)
    }
    static func perform(host: String, _ action: String, _ body: [String: Any], timeout: TimeInterval = 30) async throws -> GameStatus {
        let result = try JSONDecoder().decode(GameStatus.self, from: await request(host: host, action: "/" + action, body: body, timeout: timeout))
        if let error = result.error { throw Failure.message(error) }
        return result
    }
    static func post(host: String, _ action: String, _ body: [String: Any]) async -> GameStatus? {
        try? await perform(host: host, action, body)
    }
}

/// Coalesces continuous controls while one network acknowledgement is pending.
struct GameSteeringBuffer {
    /// A phone-only key a board adds to the position where a drag, slider or
    /// button press ends. GameScreen removes it before the move leaves the
    /// phone, since the wall accepts only the position itself.
    static let finalKey = "phone_final"
    private var latest: (y: Double, at: TimeInterval, session: String?, final: Bool)?
    mutating func offer(_ y: Double, session: String?, final: Bool = false, now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        guard y.isFinite else { return }
        latest = (max(0, min(1, y)), now, session, final)
    }
    mutating func clear() { latest = nil }
    mutating func take(session: String?, now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Double? {
        defer { latest = nil }
        // A mid-drag sample goes stale because a newer one replaces it. The
        // final one never does: the board keeps showing it as its target, so
        // it is sent however long the previous reply took.
        guard let latest, latest.session == session,
              now >= latest.at, latest.final || now - latest.at < 0.35 else { return nil }
        return latest.y
    }
}
