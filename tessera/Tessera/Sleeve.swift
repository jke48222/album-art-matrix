// Artwork belongs to a song, never to the wall's current visual mode.
import MediaPlayer
import Observation
import UIKit

@MainActor
@Observable
final class SleeveArt {
    private(set) var image: UIImage?
    private(set) var songKey = ""
    private(set) var title = ""
    private(set) var artist = ""
    private(set) var album = ""
    private(set) var revision = 0
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var requestID = UUID()
    @ObservationIgnored private var pending = false
    @ObservationIgnored private var retryAfter = Date.distantPast
    @ObservationIgnored private var sourceHost = ""
    @ObservationIgnored private var cache: [String: UIImage] = [:]
    @ObservationIgnored private let load: (String, String, String) async -> UIImage?

    /// What a pressing is kept under: the album, so every song on it gets
    /// the same record; the song itself when the album is not known.
    var albumKey: String {
        album.isEmpty ? songKey : SleeveMatch.normalized(artist) + "|" + SleeveMatch.normalized(album)
    }

    init(load: ((String, String, String) async -> UIImage?)? = nil) {
        self.load = load ?? { await Self.fetch(title: $0, artist: $1, host: $2) }
    }

    func refresh(title: String?, artist: String?, album: String? = nil, host: String) {
        let wallTitle = (title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let wallArtist = artist ?? ""
        let player = MPMusicPlayerController.systemMusicPlayer
        let item = player.nowPlayingItem
        // A different Apple Music item can linger while another service plays.
        let matchesWall = item.map { SleeveMatch.same($0.title ?? "", wallTitle) && SleeveMatch.same($0.artist ?? "", wallArtist) } ?? false
        if let item, (player.playbackState == .playing || player.playbackState == .paused),
           wallTitle.isEmpty || matchesWall {
            // the artwork is decoded only when the sleeve has none yet: this
            // runs once a second, and a decode a second is a decode too many
            update(title: item.title ?? "", artist: item.artist ?? "", album: item.albumTitle ?? album ?? "", host: host,
                   localImage: item.artwork?.image(at: CGSize(width: 512, height: 512)))
        } else {
            update(title: wallTitle, artist: wallArtist, album: album ?? "", host: host)
        }
    }

    /// Separate from the player read so changes and delayed responses can be tested.
    func update(title: String, artist: String, album: String = "", host: String,
                localImage: @autoclosure () -> UIImage? = nil) {
        let k = title.isEmpty ? "" : SleeveMatch.key(title: title, artist: artist)
        if k != songKey || host != sourceHost {
            task?.cancel(); requestID = UUID(); pending = false; retryAfter = .distantPast
            songKey = k; sourceHost = host
            self.title = title; self.artist = artist; self.album = album
            image = cache[k]; revision += 1
        }
        // an album arriving after its song is news too: the pressing is kept
        // by album, so the record has to be looked up again
        if !album.isEmpty, album != self.album { self.album = album; revision += 1 }
        guard !k.isEmpty else { return }
        if image == nil, let localImage = localImage() {
            task?.cancel(); requestID = UUID(); pending = false
            image = localImage.squared(512); cache[k] = image; revision += 1
        }
        guard image == nil, !pending, Date() >= retryAfter else { return }
        pending = true
        let id = UUID(); requestID = id
        let loader = load
        task = Task { [weak self] in
            let result = await loader(title, artist, host)
            guard !Task.isCancelled, let self, self.requestID == id, self.songKey == k else { return }
            self.pending = false
            if let result {
                if self.cache.count >= 48 { self.cache.removeAll(keepingCapacity: true) }
                self.image = result; self.cache[k] = result; self.revision += 1
            } else {
                self.retryAfter = Date().addingTimeInterval(5)
            }
        }
    }

    private static func fetch(title: String, artist: String, host: String) async -> UIImage? {
        guard let url = URL(string: "http://\(host)/journal?limit=40") else { return nil }
        func data(_ url: URL) async -> Data? {
            guard let (data, response) = try? await URLSession.shared.data(for: URLRequest(url: url, timeoutInterval: 8)),
                  let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return nil }
            return data
        }
        guard let bytes = await data(url), !Task.isCancelled,
              let root = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              let entries = root["entries"] as? [[String: Any]],
              let match = SleeveMatch.entry(in: entries, title: title, artist: artist),
              let art = match["art_url"] as? String, let artURL = URL(string: art),
              let bytes = await data(artURL), !Task.isCancelled, let image = UIImage(data: bytes) else { return nil }
        return image.squared(512)
    }
}

enum SleeveMatch {
    static func normalized(_ s: String) -> String {
        s.precomposedStringWithCanonicalMapping.lowercased()
            .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
    static func same(_ a: String, _ b: String) -> Bool { normalized(a) == normalized(b) }
    static func key(title: String, artist: String) -> String { normalized(artist) + "|" + normalized(title) }
    static func entry(in entries: [[String: Any]], title: String, artist: String) -> [String: Any]? {
        entries.filter {
            same($0["title"] as? String ?? "", title) && same($0["artist"] as? String ?? "", artist)
        }.max { ($0["ts"] as? Double ?? 0) < ($1["ts"] as? Double ?? 0) }
    }
}

extension UIImage {
    /// The middle square, at a size that suits a label.
    func squared(_ side: CGFloat) -> UIImage {
        let s = min(size.width, size.height)
        let crop = CGRect(x: (size.width - s) / 2, y: (size.height - s) / 2, width: s, height: s)
        let fmt = UIGraphicsImageRendererFormat.default()
        fmt.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: fmt).image { _ in
            let k = side / s
            draw(in: CGRect(x: -crop.origin.x * k, y: -crop.origin.y * k, width: size.width * k, height: size.height * k))
        }
    }
}
