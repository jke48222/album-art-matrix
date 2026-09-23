import Foundation

/// Stable countdown from the wall's snapshot, independent of phone clock changes.
struct NoteCountdown {
    let text: String
    let id: String?
    let seconds: Int
    let receivedUptime: TimeInterval

    init?(status: NoteStatus, uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        guard status.active != false, let text = status.text, !text.isEmpty,
              let remaining = status.seconds_left, remaining > 0 else { return nil }
        self.text = text
        id = status.id
        seconds = remaining
        receivedUptime = uptime
    }

    func remaining(uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Int {
        guard uptime.isFinite else { return 0 }
        return max(0, seconds - Int(max(0, uptime - receivedUptime).rounded(.down)))
    }

    static func duration(_ seconds: Int) -> String {
        let value = max(0, seconds)
        if value >= 3600 { return String(format: "%d:%02d:%02d", value / 3600, value / 60 % 60, value % 60) }
        return String(format: "%d:%02d", value / 60, value % 60)
    }
}

struct AskStatus: Decodable {
    struct Item: Decodable {
        var q: String
        var a: String
        var s: Double?
        var usd: Double?
        var ts: Int?
    }
    var ready: Bool?
    var pending: Bool?
    var model: String?
    var answers: Int?
    var cost_usd: Double?
    var problem: String?
    var workspace_set: Bool?
    var history: [Item]?

    static func read(host: String) async -> AskStatus? {
        try? await MessageAPI.get(host: host, path: "/ask")
    }

    static func ask(host: String, text: String, onWall: Bool) async -> MessageReply {
        await MessageAPI.post(host: host, path: "/ask",
                              body: ["text": text, "reply": onWall ? "wall" : "text"], timeout: 90)
    }
}

struct NoteStatus: Decodable {
    var id: String?
    var text: String?
    var seconds_left: Int?
    var active: Bool?

    static func read(host: String) async -> NoteStatus? {
        try? await MessageAPI.get(host: host, path: "/note")
    }

    static func post(host: String, text: String, minutes: Double) async -> MessageReply {
        guard minutes.isFinite, (0.5...720).contains(minutes), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return MessageReply(error: "Write a message and choose a duration from 1 to 720 minutes.")
        }
        return await MessageAPI.post(host: host, path: "/note", body: ["text": text, "minutes": minutes])
    }

    static func clear(host: String, id: String?) async -> MessageReply {
        guard let id, !id.isEmpty else {
            return MessageReply(error: "Refresh the current note before taking it down.")
        }
        return await MessageAPI.post(host: host, path: "/note", body: ["clear": true, "id": id])
    }
}

struct MessageReply: Decodable {
    var answer: String?
    var shown: Bool?
    var cleared: Bool?
    var error: String?
    var accepted = false

    enum CodingKeys: String, CodingKey { case answer, shown, cleared, error }

    init(error: String) { self.error = error }

    static func decode(_ data: Data, status: Int) -> MessageReply {
        guard var result = try? JSONDecoder().decode(MessageReply.self, from: data) else {
            return MessageReply(error: "The wall sent an unreadable reply. Your draft is safe.")
        }
        result.accepted = (200...299).contains(status) && result.error == nil
        if !result.accepted && result.error == nil { result.error = "The wall couldn't complete that. Try again." }
        return result
    }
}

enum MessageAPI {
    static func request(host: String, path: String, timeout: TimeInterval) throws -> URLRequest {
        guard !host.isEmpty, let url = URL(string: "http://\(host)\(path)"), url.host != nil else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.cachePolicy = .reloadIgnoringLocalCacheData
        return request
    }

    static func get<T: Decodable>(host: String, path: String) async throws -> T {
        let request = try request(host: host, path: path, timeout: 6)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return try JSONDecoder().decode(T.self, from: data)
    }

    static func post(host: String, path: String, body: [String: Any], timeout: TimeInterval = 10) async -> MessageReply {
        do {
            var request = try request(host: host, path: path, timeout: timeout)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (data, response) = try await URLSession.shared.data(for: request)
            return MessageReply.decode(data, status: (response as? HTTPURLResponse)?.statusCode ?? 0)
        } catch {
            return MessageReply(error: "The wall didn't confirm this. Your draft is safe; check the connection before trying again.")
        }
    }
}
