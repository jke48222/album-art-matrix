// The wall's panel layout, as GET /state reports it under "wall".
//
// Foundation only, so the About model tests can compile it with swiftc on
// the Mac. The brain's Wall allows rectangles (width = tile x cols, height =
// tile x rows), so the size is read as two numbers, never as Panel.side
// squared.

import Foundation

struct WallGrid: Equatable {
    var cols: Int
    var rows: Int
    var tile: Int
    var width: Int
    var height: Int

    init(cols: Int, rows: Int, tile: Int, width: Int? = nil, height: Int? = nil) {
        self.cols = cols
        self.rows = rows
        self.tile = tile
        self.width = width ?? tile * cols
        self.height = height ?? tile * rows
    }

    /// `json` is the "wall" object. Nil unless cols, rows and tile are all
    /// positive. An older brain that sends only a width gets no grid, and
    /// the page falls back to Panel.side. Width and height default to
    /// tile x cols and tile x rows when absent.
    init?(json: [String: Any]) {
        guard let cols = json["cols"] as? Int, cols > 0,
              let rows = json["rows"] as? Int, rows > 0,
              let tile = json["tile"] as? Int, tile > 0 else { return nil }
        let width = (json["width"] as? Int).flatMap { $0 > 0 ? $0 : nil }
        let height = (json["height"] as? Int).flatMap { $0 > 0 ? $0 : nil }
        self.init(cols: cols, rows: rows, tile: tile, width: width, height: height)
    }

    var panels: Int { cols * rows }
    var lights: Int { width * height }

    /// "One panel", or "9 panels, 3 x 3".
    var panelsText: String {
        panels == 1 ? "One panel" : "\(panels) panels, \(cols) x \(rows)"
    }

    /// "128 x 64, 8,192 lights".
    func sizeText(locale: Locale = .current) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.locale = locale
        let count = f.string(from: NSNumber(value: lights)) ?? "\(lights)"
        return "\(width) x \(height), \(count) lights"
    }
}
