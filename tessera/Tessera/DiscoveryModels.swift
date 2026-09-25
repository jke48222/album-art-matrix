import Foundation

enum DiscoveryScope: String, CaseIterable, Identifiable {
    case picture, cover, video
    var id: String { rawValue }
    var title: String {
        switch self { case .picture: "Picture"; case .cover: "Cover"; case .video: "Video" }
    }
    var symbol: String {
        switch self { case .picture: "photo"; case .cover: "opticaldisc"; case .video: "play.rectangle" }
    }
    var placeholder: String {
        switch self {
        case .picture: "A place, a painting, a small wonder…"
        case .cover: "An album or song, and the artist…"
        case .video: "The video you have in mind…"
        }
    }
    var example: String {
        switch self { case .picture: "Saturn's rings"; case .cover: "Kind of Blue by Miles Davis"; case .video: "NASA Earth from space" }
    }
}

protocol DiscoveryReply: Decodable {
    var isUsable: Bool { get }
}

struct ShowResult: DiscoveryReply, Identifiable {
    var id: String?
    var what: String?
    var kind: String?
    var title: String?
    var artist: String?
    var album: String?
    var credit: String?
    var source: String?
    var art_url: String?
    var url: String?
    var preview_png: String?
    var preview_size: Int?
    var shown: Bool?
    var playing: Bool?
    var active: Bool?
    var seconds_left: Int?

    var heading: String { title?.nilIfDiscoveryEmpty ?? album?.nilIfDiscoveryEmpty ?? "Your discovery" }
    var byline: String { credit?.nilIfDiscoveryEmpty ?? artist?.nilIfDiscoveryEmpty ?? source?.nilIfDiscoveryEmpty ?? "" }
    var isVideo: Bool { what == "play" || kind == "video" }
    var isUsable: Bool { (title?.nilIfDiscoveryEmpty != nil || album?.nilIfDiscoveryEmpty != nil) && (shown != nil || playing != nil) }
    var receipt: String {
        if active == true { return isVideo ? "Playing on the wall" : "Showing on the wall" }
        if shown == true || playing == true { return "Previously sent to the wall" }
        return "Found for you"
    }
}

struct DiscoveryStatus: Decodable {
    var last: ShowResult?
    var pending: Bool?
    var problem: String?
    var picture_provider: String?
    var video_available: Bool?
}

struct Earworm: DiscoveryReply, Identifiable {
    struct Alt: Decodable, Identifiable {
        var title: String
        var artist: String
        var id: String { title + "|" + artist }
    }
    var id: String?
    var title: String?
    var artist: String?
    var album: String?
    var confidence: Double?
    var alternatives: [Alt]?
    var art_url: String?
    var preview_png: String?
    var preview_size: Int?
    var shown: Bool?
    var active: Bool?
    var words: String?
    var isUsable: Bool { title?.nilIfDiscoveryEmpty != nil && artist?.nilIfDiscoveryEmpty != nil }
    var confidenceLabel: String {
        guard let confidence, confidence.isFinite else { return "A possible match" }
        return confidence >= 0.85 ? "A strong possibility" : confidence >= 0.65 ? "A likely match" : "A possibility to explore"
    }
    var shareText: String { [title, artist].compactMap { $0?.nilIfDiscoveryEmpty }.joined(separator: " — ") }
}

struct EarwormStatus: Decodable {
    var last: Earworm?
    var ready: Bool?
    var pending: Bool?
    var problem: String?
}

enum DiscoveryAPI {
    struct Problem: Decodable { var error: String? }
    static func read<T: Decodable>(_ path: String, host: String) async -> T? {
        try? await MessageAPI.get(host: host, path: path)
    }
    static func send<T: DiscoveryReply>(_ path: String, host: String, body: [String: Any]) async -> (T?, String?) {
        do {
            var request = try MessageAPI.request(host: host, path: path, timeout: 100)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (data, response) = try await URLSession.shared.data(for: request)
            let problem = try? JSONDecoder().decode(Problem.self, from: data)
            guard (response as? HTTPURLResponse)?.statusCode == 200, problem?.error == nil else {
                return (nil, problem?.error ?? "The wall couldn't finish that search. Try a more specific name.")
            }
            guard let result = try? JSONDecoder().decode(T.self, from: data), result.isUsable else {
                return (nil, "The wall returned an unreadable result. Refresh before trying again.")
            }
            return (result, nil)
        } catch {
            return (nil, "The wall didn't confirm this request. Your words are safe. Check the connection and refresh before trying again.")
        }
    }
}

private extension String {
    var nilIfDiscoveryEmpty: String? { trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : self }
}
