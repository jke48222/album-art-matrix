// What the app and the widget both know about the wall.
//
// DUPLICATED, deliberately: an identical copy lives in TesseraWidgets/. The
// project uses file-system synchronized groups, where sharing one file
// between two targets means membership exceptions that break the moment a
// file is added. This file is small, has no dependencies, and changes rarely.
// If you edit one copy, edit the other.

import Foundation
import UIKit

enum WallSnapshot {
    static let group = "group.com.jalenedusei.tessera"

    private static var defaults: UserDefaults? { UserDefaults(suiteName: group) }

    /// The app writes what it knows; the widget reads it and says when.
    /// An empty host means "no wall answered this" — it never erases the
    /// address of a wall that did, so the widget can still dial it.
    static func write(px: [UInt8]?, title: String?, artist: String?, mode: String, host: String) {
        guard let d = defaults else { return }
        if let px, Panel.square(px.count) != nil { d.set(Data(px), forKey: "frame") }
        d.set(title, forKey: "title")
        d.set(artist, forKey: "artist")
        d.set(mode, forKey: "mode")
        if !host.isEmpty { d.set(host, forKey: "host") }
        d.set(Date(), forKey: "updated")
    }

    static func read() -> (px: [UInt8]?, title: String?, artist: String?, mode: String, host: String, updated: Date?) {
        guard let d = defaults else { return (nil, nil, nil, "art", "", nil) }
        let data = d.data(forKey: "frame")
        return (
            data.map { [UInt8]($0) },
            d.string(forKey: "title"),
            d.string(forKey: "artist"),
            d.string(forKey: "mode") ?? "art",
            d.string(forKey: "host") ?? "",
            d.object(forKey: "updated") as? Date
        )
    }

    /// The wall, drawn the way the app draws it: emitters on black, the unlit
    /// ones still present. A widget of a wall should look like the wall.
    static func render(_ px: [UInt8], cell wanted: CGFloat = 6) -> UIImage? {
        guard let n = Panel.square(px.count) else { return nil }
        // A widget is a small picture. Nine panels at six points an emitter
        // would be a 1,152 pixel raster and 36,864 ellipse fills on the
        // widget's timeline, so the emitter shrinks as the wall grows and
        // the picture stays the size a widget needs.
        let cell = max(1, min(wanted, (768 / CGFloat(n)).rounded(.down)))
        let side = CGFloat(n) * cell
        let fmt = UIGraphicsImageRendererFormat.default()
        fmt.scale = 1
        fmt.opaque = true
        return UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: fmt).image { rctx in
            let ctx = rctx.cgContext
            ctx.setFillColor(UIColor.black.cgColor)
            ctx.fill(CGRect(x: 0, y: 0, width: side, height: side))
            let r = cell * 0.35
            let unlit = UIColor(white: 0.055, alpha: 1).cgColor
            for i in 0..<(n * n) {
                let o = i * 3
                let cx = CGFloat(i % n) * cell + cell / 2
                let cy = CGFloat(i / n) * cell + cell / 2
                let box = CGRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2)
                if px[o] < 8 && px[o + 1] < 8 && px[o + 2] < 8 {
                    ctx.setFillColor(unlit)
                } else {
                    ctx.setFillColor(UIColor(red: CGFloat(px[o]) / 255,
                                             green: CGFloat(px[o + 1]) / 255,
                                             blue: CGFloat(px[o + 2]) / 255,
                                             alpha: 1).cgColor)
                }
                ctx.fillEllipse(in: box)
            }
        }
    }

    /// The widget tries the wall itself before falling back to what the app
    /// last wrote. An extension's local-network access can be denied without
    /// a prompt, so this failing is normal and must not look like an error.
    static func fetchLive(host: String) async -> (px: [UInt8], title: String?, artist: String?, mode: String)? {
        guard !host.isEmpty,
              let stateURL = URL(string: "http://\(host)/state"),
              // A widget asks for a small copy: the wall boxes it down for us
              // rather than sending nine panels of pixels to a picture this
              // size. A wall that predates the parameter ignores it.
              let frameURL = URL(string: "http://\(host)/frame.raw?side=64") else { return nil }
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 4
        let session = URLSession(configuration: cfg)

        guard let (fd, fr) = try? await session.data(from: frameURL),
              (fr as? HTTPURLResponse)?.statusCode == 200,
              Panel.square(fd.count) != nil else { return nil }

        var title: String?, artist: String?, mode = "art"
        if let (sd, _) = try? await session.data(from: stateURL),
           let json = try? JSONSerialization.jsonObject(with: sd) as? [String: Any] {
            mode = json["mode"] as? String ?? "art"
            if let now = json["now_showing"] as? [String: Any] {
                title = now["title"] as? String
                artist = now["artist"] as? String
            }
        }
        return ([UInt8](fd), title, artist, mode)
    }
}
