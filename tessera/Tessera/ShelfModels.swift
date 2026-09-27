import Foundation

enum ShelfOrder: String, CaseIterable, Identifiable {
    case recent, artist, title, year, played
    var id: String { rawValue }
    var title: String {
        switch self {
        case .recent: "Recently added"
        case .artist: "Artist"
        case .title: "Record title"
        case .year: "Release year"
        case .played: "Most on the wall"
        }
    }
}

struct ShelfList: Decodable {
    struct Release: Decodable, Identifiable, Hashable {
        var release_id: Int
        var title: String
        var artists: [String]
        var year: Int?
        var label: String?
        var catno: String?
        var formats: [String]?
        var descriptions: [String]?
        var cover: String?
        var country: String?
        var url: String
        var plays: Int
        var added: String?
        var copies: Int?
        var id: Int { release_id }
        var copyCount: Int { max(1, copies ?? 1) }
        var artistLine: String { artists.joined(separator: ", ") }
        var formatLine: String {
            ((formats ?? []) + (descriptions ?? [])).filter { !$0.isEmpty }.joined(separator: ", ")
        }
        var discogsURL: URL? {
            guard release_id > 0 else { return nil }
            return URL(string: "https://www.discogs.com/release/\(release_id)")
        }
        var coverURL: URL? {
            guard let cover, let url = URL(string: cover), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return nil }
            return url
        }
        var searchText: String {
            ShelfList.normalized(([title, artistLine, label ?? "", catno ?? "", country ?? "", year.map(String.init) ?? ""] + (formats ?? [])).joined(separator: " "))
        }
    }
    var releases: [Release]
    var user: String?
    var token_set: Bool?
    var synced_at: Double?
    var syncing: Bool?
    var problem: String?
    var sync_id: String?
    var completed_sync_id: String?

    var configured: Bool { token_set == true && !(user?.isEmpty ?? true) }
    /// A wall with the shelf feature off answers {"releases": [], "problem": ...}
    /// only. A running shelf always reports token_set, true or false.
    var available: Bool { token_set != nil }
    var uniqueReleases: [Release] {
        var seen = Set<Int>()
        return releases.filter { $0.id > 0 && seen.insert($0.id).inserted }
    }
    var copyCount: Int { uniqueReleases.reduce(0) { $0 + $1.copyCount } }
    var artistCount: Int { Set(uniqueReleases.flatMap(\.artists).map(Self.normalized)).count }
    func isStale(at now: Date = Date()) -> Bool {
        guard let synced_at, synced_at.isFinite, synced_at > 0 else { return true }
        return now.timeIntervalSince1970 - synced_at >= 6 * 3600 + 60
    }
    static func normalized(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }
    func visible(query: String, order: ShelfOrder) -> [Release] {
        let words = Self.normalized(query).split(whereSeparator: \.isWhitespace).map(String.init)
        return uniqueReleases.filter { release in words.allSatisfy { release.searchText.contains($0) } }.sorted { a, b in
            switch order {
            case .recent:
                if a.added != b.added { return (a.added ?? "") > (b.added ?? "") }
            case .played:
                if a.plays != b.plays { return a.plays > b.plays }
            case .artist:
                let result = a.artistLine.localizedStandardCompare(b.artistLine)
                if result != .orderedSame { return result == .orderedAscending }
            case .year:
                if a.year != b.year { return (a.year ?? 0) > (b.year ?? 0) }
            case .title: break
            }
            let result = a.title.localizedStandardCompare(b.title)
            return result == .orderedSame ? a.id < b.id : result == .orderedAscending
        }
    }
    static func read(host: String) async -> ShelfList? { try? await fetch(host: host) }
    static func fetch(host: String) async throws -> ShelfList {
        try JSONDecoder().decode(ShelfList.self, from: await request(host: host, path: "/shelf", post: false))
    }
    static func sync(host: String) async -> Bool { (try? await requestSync(host: host)) != nil }
    static func requestSync(host: String) async throws -> ShelfSyncReceipt {
        let receipt = try JSONDecoder().decode(ShelfSyncReceipt.self, from: await request(host: host, path: "/shelf/sync", post: true))
        guard receipt.accepted == true, let id = receipt.sync_id, !id.isEmpty else {
            throw ShelfRequestError.message("The wall didn’t confirm this read. Refresh and try again.")
        }
        return receipt
    }
    private static func request(host: String, path: String, post: Bool) async throws -> Data {
        guard !host.isEmpty, let url = URL(string: "http://\(host)\(path)"), url.host != nil else {
            throw ShelfRequestError.message("Connect to your wall to read the shelf.")
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.cachePolicy = .reloadIgnoringLocalCacheData
        if post {
            request.httpMethod = "POST"
            request.httpBody = Data("{}".utf8)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200 else {
            let error = try? JSONDecoder().decode(ShelfServerError.self, from: data)
            throw ShelfRequestError.message(error?.error ?? "The wall couldn’t read your collection. Try again.")
        }
        return data
    }
}

struct ShelfSyncReceipt: Decodable { var accepted: Bool?; var sync_id: String? }
private struct ShelfServerError: Decodable { var error: String? }
enum ShelfRequestError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case let .message(text) = self { return text }; return nil }
}
