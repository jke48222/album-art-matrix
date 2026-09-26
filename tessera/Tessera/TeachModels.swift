import Foundation

/// The wall is the authority for library membership and each completed operation.
struct TaughtList: Decodable {
    struct Song: Decodable, Identifiable {
        var id: String
        var title: String
        var artist: String
        var album: String?
        var art_url: String?
        var how: [String]
        var added: Int?
        var matched: Int
        var last_matched: Int?
        var landmarks: Int?

        var sources: String {
            how.map { switch $0 { case "ear": "This room"; case "preview": "Preview"; case "told": "By name"; default: "Learned" } }
                .joined(separator: " · ")
        }
        func matches(_ query: String) -> Bool {
            let haystack = "\(title) \(artist) \(album ?? "")".folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            return query.split(whereSeparator: \.isWhitespace).allSatisfy {
                haystack.contains(String($0).folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current))
            }
        }
    }
    struct Recognition: Decodable {
        var id: String
        var title: String
        var artist: String
        var score: Int
        var at: Int?
    }
    struct Teacher: Decodable {
        struct Receipt: Decodable { var id: String; var title: String; var artist: String; var at: Int? }
        var by_ear: Bool?
        var learning: String?
        var problem: String?
        var last_learned: Receipt?
    }
    var enabled: Bool?
    var landmarks: Int?
    var min_score: Int?
    var songs: [Song]
    var last_match: Recognition?
    var teacher: Teacher?
    var problem: String?

    static func read(host: String) async -> TaughtList? {
        guard !host.isEmpty, let url = URL(string: "http://\(host)/teach") else { return nil }
        var req = URLRequest(url: url); req.timeoutInterval = 6; req.cachePolicy = .reloadIgnoringLocalCacheData
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }

    static func learn(host: String, title: String, artist: String) async -> (Bool, String?) {
        await mutation(host: host, path: "/teach/learn", body: ["title": title, "artist": artist], timeout: 90)
    }
    static func forget(host: String, id: String) async -> Bool {
        await forgetReply(host: host, id: id).0
    }
    static func forgetReply(host: String, id: String) async -> (Bool, String?) {
        await mutation(host: host, path: "/teach/forget", body: ["id": id], timeout: 12)
    }
    private static func mutation(host: String, path: String, body: [String: String], timeout: Double) async -> (Bool, String?) {
        guard !host.isEmpty, let url = URL(string: "http://\(host)\(path)") else { return (false, "Connect to your wall to change its library.") }
        var req = URLRequest(url: url); req.httpMethod = "POST"; req.timeoutInterval = timeout
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONEncoder().encode(body)
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
                return (false, json?["error"] as? String ?? "The wall couldn't finish. Your library is unchanged.")
            }
            // A successful HTTP response is not enough: require the operation's receipt.
            let confirmed = path.hasSuffix("/forget") ? json?["forgot"] as? Bool == true : json?["learnt"] is [String: Any]
            return (confirmed, confirmed ? nil : "The wall hasn't confirmed this change. Refresh before trying again.")
        } catch {
            return (false, "The reply didn't arrive. Refresh the library before trying again; the wall may have finished.")
        }
    }
}
