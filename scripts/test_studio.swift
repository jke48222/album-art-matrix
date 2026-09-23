import Foundation

@main struct StudioTests {
    @MainActor static func main() throws {
        var checks: [[String:Any]] = []
        func check(_ name: String, _ condition: Bool) { checks.append(["name":name,"passed":condition]) }
        let original = Panel.side
        defer { Panel.learn(original) }
        for side in [64,192] {
            Panel.learn(side)
            let canvas = WallCanvas()
            canvas.checkpoint()
            canvas.sweep(from:(0,0),to:(Double(side-1),Double(side-1)),rgb:(255,64,32),radius:0)
            check("\(side) stroke reaches bottom right",canvas.px.suffix(3) == [255,64,32])
            check("\(side) fast diagonal has no gaps",(0..<side).allSatisfy { canvas.px[($0*side+$0)*3] == 255 })
            let drawing = canvas.px, beforeUndo = canvas.revision
            canvas.undo(); check("\(side) undo restores blank and invalidates render",canvas.isEmpty && canvas.revision > beforeUndo)
            canvas.redo(); check("\(side) redo restores exact pixels",canvas.px == drawing)
            canvas.checkpoint(); canvas.clear(); canvas.undo()
            check("\(side) clear is reversible",canvas.px == drawing)
            let oldRevision=canvas.revision
            canvas.fill(x:-1,y:side,rgb:(1,2,3))
            check("\(side) out of bounds fill is safe",canvas.revision == oldRevision)
            canvas.sweep(from:(.nan,0),to:(.infinity,0),rgb:(0,0,0),radius:0)
            check("\(side) invalid touch is ignored",canvas.px == drawing)
            canvas.clear(); canvas.checkpoint(); canvas.fill(x:side-1,y:side-1,rgb:(20,40,60))
            check("\(side) fill reaches all pixels",stride(from:0,to:canvas.px.count,by:3).allSatisfy { canvas.px[$0] == 20 && canvas.px[$0+2] == 60 })
            canvas.undo(); check("\(side) fill is reversible",canvas.isEmpty)
            Panel.learn(side == 64 ? 192 : 64)
            canvas.clear(); check("\(side) open document keeps its size after reconnect",canvas.px.count == side*side*3)
            canvas.load([UInt8](repeating:200,count:64*64*3)); check("\(side) import resamples into document size",canvas.px.count == side*side*3 && canvas.px.allSatisfy {$0 == 200})
        }
        for side in [64, 192, 512] {
            let blank = [UInt8](repeating: 0, count: side * side * 3)
            let layout = LetteringLayout(text: "MAKE\nLIGHT", side: side, size: 2)
            let pixels = layout.render(over: blank, rgb: (255, 255, 255), colors: [(255, 0, 0)])
            check("\(side) lettering fits requested size", layout.fits && layout.scale == 2 * max(1, side / 64))
            check("\(side) lettering preserves manual line break", layout.lines == ["MAKE", "LIGHT"])
            check("\(side) lettering frame is exact native dimensions", pixels.count == side * side * 3)
            check("\(side) per glyph ink is kept", stride(from: 0, to: pixels.count, by: 3).contains { pixels[$0] == 255 && pixels[$0+1] == 0 })
            check("\(side) other letters use base ink", stride(from: 0, to: pixels.count, by: 3).contains { pixels[$0] == 255 && pixels[$0+1] == 255 })
            let top = LetteringLayout(text: "A", side: side, size: 2, horizontal: 0, vertical: 0)
            let bottom = LetteringLayout(text: "A", side: side, size: 2, horizontal: 1, vertical: 1)
            check("\(side) placement reaches both margins", top.originY == top.margin && bottom.originY + bottom.height == side-bottom.margin)
            check("\(side) alignment changes actual pixels", top.render(over: blank, rgb:(1,2,3)) != bottom.render(over: blank, rgb:(1,2,3)))
            check("\(side) invalid placement is finite", LetteringLayout(text: "A", side: side, size: 99, horizontal:.infinity, vertical:.nan).horizontal == 0.5)
            let empty = LetteringLayout(text: " \n ", side: side, size: 1)
            check("\(side) empty lettering preserves art", empty.render(over: blank, rgb:(255,255,255)) == blank)
        }
        check("World glyph resources are loaded", PixelFont.cell("É")?.dy == -1)
        for side in [64,192] {
            for word in ["É", "Ç", "À"] {
                let top = LetteringLayout(text:word,side:side,size:4,vertical:0)
                let bottom = LetteringLayout(text:word,side:side,size:4,vertical:1)
                let pixelsA = top.render(over:[],rgb:(255,255,255))
                let pixelsB = bottom.render(over:[],rgb:(255,255,255))
                check("\(side) \(word) accents and descenders survive placement", pixelsA.filter {$0 > 0}.count == pixelsB.filter {$0 > 0}.count && top.fits && bottom.fits)
                let glyph = PixelFont.cell(Character(word))!
                let expected = glyph.rows.reduce(0) {$0 + $1.nonzeroBitCount} * top.scale * top.scale * 3
                check("\(side) \(word) never clips a glyph pixel", pixelsA.filter {$0 > 0}.count == expected)
            }
        }
        let tooMuch = LetteringLayout(text: String(repeating: "W", count: 96), side: 64, size: 4)
        let base = [UInt8](repeating: 31, count: 64*64*3)
        check("Overflow reports a fit error", !tooMuch.fits)
        check("Overflow preserves background instead of clipping words", tooMuch.render(over:base,rgb:(255,255,255)) == base)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = MadeStore(directory: dir)
        store.load(); check("New collection is empty", store.made.isEmpty && store.error == nil)
        let first = [UInt8](repeating: 90, count: 64*64*3)
        let second = [UInt8](repeating: 190, count: 64*64*3)
        let still = store.keep([first],title:"Still")!
        let animated = store.keep([first,second],fps:8,title:"Motion")!
        check("Saved clip keeps its identity", animated.animated && animated.frameCount == 2 && animated.duration == 0.25)
        check("Gallery uses exact first frame", animated.px == first)
        let fresh = MadeStore(directory:dir); fresh.load()
        check("Both documents survive app restart", fresh.made.count == 2)
        check("Animation restores all frames and speed", fresh.content(animated)?.frames == [first,second] && fresh.content(animated)?.fps == 8)
        check("Still restores exact bytes", fresh.content(still)?.frames == [first])
        fresh.remove(animated); check("Delete removes only selected creation", fresh.made.map(\.id) == [still.id])
        fresh.undoRemove(); check("Delete is reversible with animation intact", fresh.content(animated)?.frames == [first,second])
        check("Mixed frame dimensions are rejected", fresh.keep([first,[1,2,3]]) == nil)
        check("Animation rate beyond wall capability is rejected", fresh.keep([first,second],fps:30) == nil)
        check("Nonfinite animation speed is rejected", fresh.keep([first,second],fps:.nan) == nil)
        check("Failed saves leave collection unchanged", fresh.made.count == 2)
        try Data(first).write(to:dir.appendingPathComponent("1234567890-legacy"))
        fresh.load(); check("Legacy drawings remain available", fresh.made.contains { $0.id == "1234567890-legacy" && !$0.animated })
        let payload = dir.appendingPathComponent(animated.id).appendingPathComponent("frames.rgb")
        try Data([1,2,3]).write(to:payload)
        check("Corrupted content fails visibly", fresh.content(animated) == nil && fresh.error != nil)
        fresh.load(); check("Corrupt document does not hide healthy creations", fresh.made.count == 2 && fresh.error != nil)
        let failed=checks.filter { !($0["passed"] as! Bool) }.count
        let report:[String:Any] = ["passed":checks.count-failed,"failed":failed,"checks":checks]
        try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:CommandLine.arguments[1]))
        print("Studio: \(checks.count-failed) passed; \(failed) failed")
        if failed > 0 { exit(1) }
    }
}
