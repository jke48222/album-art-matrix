// The sleeve of the song that is on.
//
// For the record's label: the cover itself, not the wall's frame, which
// is a clock or a lamp half the time. It comes from this phone's player
// when the phone is the one playing, and otherwise from the wall's journal,
// which keeps a picture of every sleeve the wall has worn. Nothing on,
// nothing here, and the label stays paper.

import MediaPlayer
import Observation
import UIKit

@MainActor
@Observable
final class SleeveArt {
    private(set) var image: UIImage? = nil
    @ObservationIgnored private var key = ""
    @ObservationIgnored private var fetching = false
    @ObservationIgnored private var cache: [String: UIImage] = [:]

    /// Called once a second and whenever the title changes; cheap unless
    /// the song has.
    func refresh(title: String?, artist: String?, host: String) {
        let t = (title ?? "").trimmingCharacters(in: .whitespaces)
        let m = MPMusicPlayerController.systemMusicPlayer
        let item = m.nowPlayingItem
        // this phone's own song, while it plays
        if m.playbackState == .playing, let item {
            let k = "local:\(item.persistentID)"
            if k != key {
                key = k
                image = item.artwork?.image(at: CGSize(width: 256, height: 256))?.squared(256)
            }
            if image != nil { return }
        }
        // what the wall says it is showing
        if !t.isEmpty {
            let k = "wall:\(t)|\(artist ?? "")"
            if k == key { return }
            key = k
            image = cache[k]
            guard image == nil, !fetching else { return }
            fetching = true
            let a = artist ?? ""
            Task { [weak self] in
                let img = await Self.fetch(title: t, artist: a, host: host)
                await MainActor.run {
                    guard let self else { return }
                    self.fetching = false
                    if self.key == k {
                        self.image = img
                        if let img { self.cache[k] = img }
                    }
                }
            }
            return
        }
        // a song this phone has paused
        if m.playbackState == .paused, let item {
            let k = "local:\(item.persistentID)"
            if k != key {
                key = k
                image = item.artwork?.image(at: CGSize(width: 256, height: 256))?.squared(256)
            }
            return
        }
        if key != "" { key = ""; image = nil }
    }

    private static func fetch(title: String, artist: String, host: String) async -> UIImage? {
        guard let u = URL(string: "http://\(host)/journal?limit=40"),
              let (data, _) = try? await URLSession.shared.data(from: u),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = root["entries"] as? [[String: Any]] else { return nil }
        let newestFirst = raw.sorted { ($0["ts"] as? Int ?? 0) > ($1["ts"] as? Int ?? 0) }
        let match = newestFirst.first { e in
            (e["title"] as? String ?? "").caseInsensitiveCompare(title) == .orderedSame
        } ?? newestFirst.first
        guard let art = match?["art_url"] as? String, let au = URL(string: art),
              let (d, _) = try? await URLSession.shared.data(from: au),
              let src = UIImage(data: d) else { return nil }
        return src.squared(256)
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
