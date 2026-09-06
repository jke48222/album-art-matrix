// What the share sheet leaves for the app, and what the app does with it.
//
// A link needs nothing more from the app than to be open: the wall is
// already fetching, and the app plays the sound when the wall says ready.
// A video from the library is the app's job: make a small square picture
// of it, send that up, and play the sound from the original here.

import AVFoundation
import Foundation

enum VideoHandoff {
    struct Pending: Equatable {
        var kind: String          // "link" or "file"
        var url: String?
        var path: String?
        var title: String?
        var sound: Bool
    }

    private static var defaults: UserDefaults? { UserDefaults(suiteName: WallSnapshot.group) }
    private static let key = "video.pending"

    /// The original video of the one on the wall now, for its sound.
    static var localSound: (key: String, url: URL)?
    /// A picture is being made or sent: the sound must wait for it.
    static var inProgress = false
    /// What arrived through the app's own door: a link from the share
    /// sheet, or a video opened in Tessera. The page takes it from here.
    static var arrived: Pending?

    /// A video opened in Tessera from somewhere else: Files, an AirDropped
    /// clip, a document. True when it was something for the wall. (Links no
    /// longer arrive this way: the share sheet hands them to the wall
    /// itself, because iOS will not let it open this app.)
    static func accept(_ url: URL) -> Bool {
        guard url.isFileURL else { return false }
        arrived = Pending(kind: "file", url: nil, path: url.path,
                          title: url.deletingPathExtension().lastPathComponent, sound: true)
        return true
    }

    static func read() -> Pending? {
        guard let data = defaults?.data(forKey: key),
              let j = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let kind = j["kind"] as? String else { return nil }
        return Pending(kind: kind, url: j["url"] as? String, path: j["path"] as? String,
                       title: j["title"] as? String, sound: j["sound"] as? Bool ?? true)
    }

    static func clear() {
        defaults?.removeObject(forKey: key)
    }

    /// A video the share sheet kept: the small picture, sent up, the
    /// original kept here for its sound. Progress is 0 to 1 for the
    /// picture-making, then the upload; the words say which.
    static func send(file: URL, title: String?, host: String,
                     progress: @escaping @Sendable (String, Double) -> Void) async throws -> String {
        progress("Making the picture", 0)
        let small = try await VideoPicture.make(from: file) { p in progress("Making the picture", p) }
        defer { try? FileManager.default.removeItem(at: small) }
        progress("Sending it to the wall", 0)
        var c = URLComponents(string: "http://\(host)/video/upload")!
        c.queryItems = [.init(name: "title", value: title ?? "From your library"),
                        .init(name: "clock", value: "phone")]
        guard let url = c.url else { throw Failure.wall("bad wall address") }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 180
        req.setValue("video/mp4", forHTTPHeaderField: "Content-Type")
        let (data, resp) = try await URLSession.shared.upload(for: req, fromFile: small)
        guard let http = resp as? HTTPURLResponse else { throw Failure.wall("no answer") }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard http.statusCode == 200 else {
            throw Failure.wall(json?["error"] as? String ?? "the wall said \(http.statusCode)")
        }
        progress("On the wall", 1)
        // the wall names the video by the path it kept; the sound follows that name
        let wallKey = ((json?["video"] as? [String: Any])?["url"] as? String) ?? ""
        localSound = (wallKey, file)
        return wallKey
    }

    enum Failure: LocalizedError {
        case wall(String)
        var errorDescription: String? {
            switch self { case .wall(let s): return "The wall did not take it: \(s)." }
        }
    }
}
