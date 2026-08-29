// What the lock screen is allowed to know.
//
// A Live Activity gets about four kilobytes per update, and the wall's own
// frames are twelve. So this does not ship a frame: it ships a twelve-by-
// twelve reduction of one, 432 bytes of it, and both the Island and the lock
// screen draw that as tiles. Twelve is the smallest grid where a sleeve is
// still recognisably that sleeve rather than four coloured squares, which is
// the whole point of putting it there.
//
// This file is compiled into both the app and the widget. The two ends have
// to agree byte for byte about this shape or the activity silently stops
// updating, so it lives in one place and is imported twice.

import ActivityKit
import Foundation

struct WallAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        /// 12x12 RGB, row major. Empty when the wall is dark.
        var tiles: Data
        var title: String
        var artist: String
        var mode: String
        /// Where the song is, and when that was true, so the bar can run on
        /// its own between updates instead of stepping once a minute.
        var songAt: Double?
        var songOf: Double?
        var playing: Bool
        var stamped: Date

        var fraction: Double? {
            guard let at = songAt, let of = songOf, of > 1 else { return nil }
            let run = playing ? at + Date().timeIntervalSince(stamped) : at
            return min(1, max(0, run / of))
        }

        /// The colour of a tile, or nil past the end of a short payload.
        func tile(_ i: Int) -> (Double, Double, Double)? {
            let o = i * 3
            guard o + 2 < tiles.count else { return nil }
            return (Double(tiles[o]) / 255, Double(tiles[o + 1]) / 255, Double(tiles[o + 2]) / 255)
        }
    }

    /// Fixed for the life of the activity. The wall's name, so a person with
    /// two of them can tell which one this is.
    var wall: String
}

enum WallTile {
    static let side = 12

    /// A 64x64 frame reduced by box-averaging, not by sampling. Sampling a
    /// sleeve at every fifth pixel picks up whatever happens to be there and
    /// throws away the colour of the record; averaging keeps it.
    static func reduce(_ px: [UInt8]) -> Data {
        guard px.count >= 64 * 64 * 3 else { return Data() }
        var out = [UInt8](repeating: 0, count: side * side * 3)
        let block = 64 / side          // 5, and the last 4 columns fold in
        for ty in 0..<side {
            for tx in 0..<side {
                var r = 0, g = 0, b = 0, n = 0
                let x0 = tx * block, y0 = ty * block
                let x1 = tx == side - 1 ? 64 : x0 + block
                let y1 = ty == side - 1 ? 64 : y0 + block
                for y in y0..<y1 {
                    for x in x0..<x1 {
                        let o = (y * 64 + x) * 3
                        r += Int(px[o]); g += Int(px[o + 1]); b += Int(px[o + 2]); n += 1
                    }
                }
                let o = (ty * side + tx) * 3
                out[o] = UInt8(r / max(1, n))
                out[o + 1] = UInt8(g / max(1, n))
                out[o + 2] = UInt8(b / max(1, n))
            }
        }
        return Data(out)
    }
}
