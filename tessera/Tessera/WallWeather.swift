import Foundation

/// What GET /weather says.
struct WallWeather: Decodable {
    struct Now: Decodable {
        var temp: Double?
        var feels: Double?
        var code: Int?
        var is_day: Bool?
        var wind_kmh: Double?
        var cloud: Double?
        var precip_mm: Double?
        var high: Double?
        var low: Double?
        var sunrise: Double?
        var sunset: Double?
    }
    struct Hour: Decodable {
        var t: Double?
        var temp: Double?
        var code: Int?
        var is_day: Bool?
    }
    var place: String?
    var units: String?
    var utc_offset_s: Int?
    var age_s: Int?
    var stale: Bool?
    var refreshing: Bool?
    var scene: String?
    var problem: String?
    var now: Now?
    var hours: [Hour]?

    static func read(host: String, refresh: Bool = false) async -> WallWeather? {
        guard !host.isEmpty, let url = URL(string: "http://\(host)/weather") else { return nil }
        if refresh {
            var refreshRequest = URLRequest(url: url.appendingPathComponent("refresh"))
            refreshRequest.httpMethod = "POST"
            refreshRequest.httpBody = Data("{}".utf8)
            refreshRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
            refreshRequest.timeoutInterval = 6
            _ = try? await URLSession.shared.data(for: refreshRequest)
            guard !Task.isCancelled else { return nil }
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = 6
        req.cachePolicy = .reloadIgnoringLocalCacheData
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? JSONDecoder().decode(WallWeather.self, from: data)
    }

    static func setPlace(host: String, query: String) async -> (Bool, String?) {
        guard !host.isEmpty, let url = URL(string: "http://\(host)/weather/place") else { return (false, "The wall is not answering.") }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 25
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["query": query])
        guard let (data, resp) = try? await URLSession.shared.data(for: req) else { return (false, "The wall is not answering.") }
        if (resp as? HTTPURLResponse)?.statusCode == 200 { return (true, nil) }
        if let d = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let e = d["error"] as? String { return (false, e) }
        return (false, "The wall could not find that place.")
    }
}
