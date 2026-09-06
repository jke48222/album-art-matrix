import UIKit

@main
struct Proof {
    @MainActor static func main() async throws {
        let out = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let chat = UIImage(contentsOfFile: out.appendingPathComponent("chat-cover.jpg").path)!
        var checks = [String]()
        func check(_ ok: Bool, _ message: String) { precondition(ok, message); checks.append(message) }
        let palette = Pressing.palette(of: chat)
        check(palette.contains { $0.b > $0.r * 2 }, "CHAT cover contains blue")
        check(!palette.contains { $0.r > $0.b * 1.5 && $0.r > 0.4 }, "CHAT palette has no invented orange or red")
        check(Pressing.make(key: "missing", palette: [], hasPicture: false).colours[0] == .black, "Missing artwork is neutral")
        let curated = Pressing.make(key: "girlset|chat", palette: palette, hasPicture: true, title: "CHAT", artist: "GIRLSET")
        check(curated.kind == .electric, "CHAT selects its curated pressing without a debug override")
        check(Pressing.make(key: "other|chat", palette: palette, hasPicture: true, title: "CHAT", artist: "Other").colours != curated.colours, "CHAT preset does not apply to another artist")
        check(SleeveMatch.entry(in: [["title":"CHAT", "artist":"Other", "ts":3.0], ["title":"Else", "artist":"GIRLSET", "ts":4.0]], title:"CHAT", artist:"GIRLSET") == nil, "Journal never substitutes another song or artist")
        let e = SleeveMatch.entry(in: [["title":"CHAT", "artist":"GIRLSET", "ts":1.0], ["title":" chat ", "artist":"girlset", "ts":2.0]], title:"CHAT", artist:"GIRLSET")
        check(e?["ts"] as? Double == 2, "Journal uses newest exact title and artist match")

        var continuations: [String: CheckedContinuation<UIImage?, Never>] = [:]
        let sleeve = SleeveArt(load: { title, _, _ in
            await withCheckedContinuation { continuations[title] = $0 }
        })
        sleeve.update(title: "A", artist: "Artist", host: "wall")
        while continuations["A"] == nil { await Task.yield() }
        sleeve.update(title: "B", artist: "Artist", host: "wall")
        while continuations["B"] == nil { await Task.yield() }
        continuations["B"]?.resume(returning: chat)
        while sleeve.image == nil { await Task.yield() }
        continuations["A"]?.resume(returning: UIImage())
        for _ in 0..<20 { await Task.yield() }
        check(sleeve.title == "B" && sleeve.image === chat, "Delayed response for previous track cannot replace current artwork")
        sleeve.update(title: "", artist: "", host: "wall")
        check(sleeve.image == nil && sleeve.songKey.isEmpty, "Removing the song clears its artwork")

        var renderTimes = [String: Double]()
        for kind in Pressing.Kind.allCases {
            let p = Pressing.make(key: "girlset|chat", palette: palette, hasPicture: true, title: "CHAT", artist: "GIRLSET", forced: kind.rawValue)
            let start = Date()
            let image = RecordDesign.render(p, sleeve: chat)!
            renderTimes[String(describing: kind)] = Date().timeIntervalSince(start)
            try image.pngData()!.write(to: out.appendingPathComponent("\(kind)-texture.png"))
            let label = RecordLabel.label(sleeve: chat, title: "CHAT", artist: "GIRLSET", tone: palette.first, key: "proof")
            let fmt = UIGraphicsImageRendererFormat(); fmt.scale = 1
            let proof = UIGraphicsImageRenderer(size: CGSize(width: 640, height: 640), format: fmt).image { rc in
                UIColor(white: 0.90, alpha: 1).setFill(); rc.fill(CGRect(x:0,y:0,width:640,height:640))
                image.draw(in: CGRect(x:32,y:32,width:576,height:576))
                let diameter = CGFloat(RecordDesign.label) * 576
                label.draw(in: CGRect(x:320-diameter/2,y:320-diameter/2,width:diameter,height:diameter))
            }
            try proof.pngData()!.write(to: out.appendingPathComponent("\(kind).png"))
            if kind == .electric {
                let second = RecordDesign.render(p, sleeve: chat)!
                check(image.pngData() == second.pngData(), "Same track produces identical pigment and splatter")
            }
        }
        try JSONSerialization.data(withJSONObject: ["passed":checks, "renderSeconds":renderTimes], options:[.prettyPrinted,.sortedKeys])
            .write(to: out.appendingPathComponent("results.json"))
        print("PASS: \(checks.count) record and artwork checks")
    }
}
