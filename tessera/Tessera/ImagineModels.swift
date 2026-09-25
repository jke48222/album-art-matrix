import Foundation

struct WallImagined: Decodable {
    struct Item: Decodable, Identifiable {
        var id: String
        var prompt: String
        var expanded: String?
        var provider: String?
        var model: String?
        var quality: String?
        var ts: Int?
        var usd: Double?
        var took_s: Double?
        var date: Date? { ts.map { Date(timeIntervalSince1970: Double($0)) } }
    }
    struct Live: Decodable {
        var stage: String
        var prompt: String?
        var partials: Int?
        var of: Int?
        var elapsed: Double?
        var problem: String?
        var done_ago: Double?
    }
    var ready: Bool?
    var provider: String?
    var images: [Item]
    var problem: String?
    var live: Live?
    var busy: Bool?
    var showing_id: String?
    var on_wall: Bool?
    var job_id: String?
    var cooldown_s: Double?

    var isDrawing: Bool { busy == true || live?.stage == "waiting" || live?.stage == "partial" }
    var progressDescription: String {
        if live?.stage == "partial" {
            let count = max(0, live?.partials ?? 0)
            return count == 1 ? "The first image has arrived. More detail is on its way." : "\(count) previews have arrived. Refining the final picture."
        }
        return "Finding the light, colour and shape. The first image will appear as soon as it arrives."
    }

    enum Operation: String { case show, forget }
    struct Reply { var ok: Bool; var error: String? }

    static func imageURL(host: String, id: String) -> URL? {
        guard !host.isEmpty, id.range(of: "^[a-z0-9-]{1,80}$", options: .regularExpression) != nil else { return nil }
        return URL(string: "http://\(host)/imagine/\(id).png")
    }

    static func read(host: String) async -> WallImagined? {
        guard !host.isEmpty, let url = URL(string: "http://\(host)/imagine") else { return nil }
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        req.timeoutInterval = 8
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? JSONDecoder().decode(WallImagined.self, from: data)
    }

    static func create(host: String, prompt: String) async -> Reply {
        await post(host: host, route: "/imagine", payload: ["prompt": prompt, "async": true], success: "accepted")
    }

    static func change(host: String, id: String, operation: Operation) async -> Reply {
        await post(host: host, route: "/imagine/\(operation.rawValue)", payload: ["id": id], success: operation == .show ? "shown" : "forgotten")
    }

    private static func post(host: String, route: String, payload: [String: Any], success: String) async -> Reply {
        guard !host.isEmpty, let url = URL(string: "http://\(host)\(route)") else { return Reply(ok: false, error: "Connect your wall to continue.") }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"; req.timeoutInterval = 15
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: payload)
        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            let acknowledged = success == "forgotten" ? (json[success] as? String) == (payload["id"] as? String) : json[success] as? Bool == true
            if (200...299).contains(code), acknowledged { return Reply(ok: true) }
            return Reply(ok: false, error: json["error"] as? String ?? "The wall did not confirm that action. Check the studio before trying again.")
        } catch {
            return Reply(ok: false, error: route == "/imagine" ? "The connection ended before the wall confirmed. Check the canvas before creating again; a picture may already be in progress." : "The wall didn't answer. Your collection will refresh when it reconnects.")
        }
    }
}
