// The app-group mailbox the home-screen widget reads: last known track,
// wall mode, and the wall's 64x64 frame as PNG. Whoever knows something
// writes it; the widget renders whatever is here.
import Foundation
import UIKit
import WidgetKit

enum SharedSnapshot {
    static let suite = UserDefaults(suiteName: "group.com.jalenedusei.albumwall")
    private static var lastKey = ""
    private static var lastReload = Date.distantPast
    // Persisted beside framePNG: an in-memory stamp reset on every launch,
    // which let the phone-art fallback overwrite a fresher saved wall frame.
    private static var lastWallFrame: Date {
        get { suite?.object(forKey: "wallFrameAt") as? Date ?? .distantPast }
        set { suite?.set(newValue, forKey: "wallFrameAt") }
    }

    static func write(title: String? = nil, artist: String? = nil,
                      mode: String? = nil, frame: UIImage? = nil,
                      frameIsWall: Bool = false, host: String? = nil,
                      rpm: Double? = nil) {
        guard let d = suite else { return }
        if let host { d.set(host, forKey: "wallHost") }
        if let rpm { d.set(rpm, forKey: "rpm") }
        if let title { d.set(title, forKey: "title") }
        if let artist { d.set(artist, forKey: "artist") }
        if let mode { d.set(mode, forKey: "mode") }
        if let frame {
            // the wall's real pixels outrank the phone-side fallback;
            // fallback only fills in when no wall frame arrived lately
            let wallFresh = Date().timeIntervalSince(lastWallFrame) < 30
            if frameIsWall || !wallFresh {
                if let png = frame.pngData(), png.count < 200_000 {
                    d.set(png, forKey: "framePNG")
                }
                if frameIsWall { lastWallFrame = Date() }
            }
        }
        d.set(Date().timeIntervalSince1970, forKey: "ts")

        // reload when the story changes, or at most once a minute otherwise
        let key = (d.string(forKey: "title") ?? "") + "|"
            + (d.string(forKey: "mode") ?? "")
        if key != lastKey || Date().timeIntervalSince(lastReload) > 60 {
            lastKey = key
            lastReload = Date()
            WidgetCenter.shared.reloadAllTimelines()
        }
    }
}
