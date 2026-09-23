import UIKit
import CoreText

@main struct RecordRenderTests {
    static func main() throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let output = URL(fileURLWithPath: CommandLine.arguments[2])
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for font in try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("tessera/Tessera/Fonts"), includingPropertiesForKeys: nil) {
            CTFontManagerRegisterFontsForURL(font as CFURL, .process, nil)
        }
        var checks: [[String: Any]] = []
        func check(_ name: String, _ value: Bool) { checks.append(["name": name, "passed": value]) }
        let colours = [Pressing.RGB(r: 0.04, g: 0.3, b: 0.4), Pressing.RGB(r: 0.95, g: 0.6, b: 0.1), .white]
        for raw in 0...4 {
            let style = LabelStyle(rawValue: raw)!
            for empty in [true, false] {
                let palette = empty ? [] : colours
                let label = RecordLabel.styled(sleeve: nil, title: "Into the Quiet", artist: "The Tessera Sessions", palette: palette,
                                               key: "test-\(raw)-\(empty)", forcedStyle: style)
                check("\(style.title) label renders with \(empty ? "empty" : "full") palette", label.size == CGSize(width: 320, height: 320) && label.pngData() != nil)
                if !empty { try label.pngData()!.write(to: output.appendingPathComponent("label-\(style.title.lowercased()).png")) }
            }
        }
        for kind in Pressing.Kind.allCases {
            let pressing = Pressing.make(key: "tessera|after the rain", palette: colours, hasPicture: false, forced: kind.rawValue)
            for side in [64, 160, 192, 512] {
                let image = RecordDesign.render(pressing, sleeve: nil, size: side)
                check("\(kind) renders at \(side)", image?.size == CGSize(width: side, height: side))
                if kind == .marble, let bytes = image?.pngData() { try bytes.write(to: output.appendingPathComponent("record-\(side).png")) }
            }
        }
        let failed = checks.filter { !($0["passed"] as! Bool) }.count
        let report: [String: Any] = ["passed": checks.count - failed, "failed": failed, "checks": checks]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: output.appendingPathComponent("tests.json"))
        print("Record renders: \(checks.count - failed) passed; \(failed) failed")
        if failed != 0 { exit(1) }
    }
}
