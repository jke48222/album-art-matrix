// How big the wall is, in LEDs.
//
// Everything used to say 64, in about thirty places, because there was one
// panel. Nine panels make it 192, and a bench panel makes it 64 again, so the
// number is asked for rather than assumed: the wall states its own size in
// /state and the app takes it from there. Frames that arrive are measured
// (any square RGB payload is read at its own size, so a stand-in at 64 and a
// wall at 192 both draw), and frames the app MAKES are made at Panel.side.
//
// The last known size is remembered in the app group, so a cold launch away
// from home builds its canvases at the size the wall actually is instead of
// showing a 64 pixel doodle to a 192 pixel wall.

import Foundation

enum Panel {
    /// The nine panel wall, and the single panel it was before it.
    static let wall = 192
    static let bench = 64

    private static let key = "wall.side"

    /// The wall's side in LEDs.
    private(set) static var side: Int = {
        let d = UserDefaults(suiteName: "group.com.jalenedusei.tessera") ?? .standard
        let saved = d.integer(forKey: key)
        return isSane(saved) ? saved : wall
    }()

    static var pixels: Int { side * side }
    static var bytes: Int { pixels * 3 }

    /// What the wall said in /state. Ignored unless it is a size a HUB75 wall
    /// can actually be, so a garbled answer never resizes every canvas.
    static func learn(_ width: Int) {
        guard isSane(width), width != side else { return }
        side = width
        let d = UserDefaults(suiteName: "group.com.jalenedusei.tessera") ?? .standard
        d.set(width, forKey: key)
    }

    private static func isSane(_ n: Int) -> Bool { n >= 32 && n <= 512 && n % 16 == 0 }

    /// The side of a square RGB888 payload, if it is one. This is how frames
    /// coming FROM the wall are read: by measurement, not by expectation.
    static func square(_ count: Int) -> Int? {
        guard count > 0, count % 3 == 0 else { return nil }
        let px = count / 3
        let s = Int(Double(px).squareRoot().rounded())
        return s * s == px && s >= 16 ? s : nil
    }

    static func square(_ data: Data?) -> Int? {
        guard let data else { return nil }
        return square(data.count)
    }

    /// A frame of nothing, at the wall's size.
    static func blank(_ value: UInt8 = 0) -> [UInt8] {
        [UInt8](repeating: value, count: bytes)
    }

    /// "4,096" for one panel, "36,864" for the wall. Copy that names the
    /// number of lights asks for it rather than carrying a stale one.
    static var lights: String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        return f.string(from: NSNumber(value: pixels)) ?? "\(pixels)"
    }
}
