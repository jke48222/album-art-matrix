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
        let failed=checks.filter { !($0["passed"] as! Bool) }.count
        let report:[String:Any] = ["passed":checks.count-failed,"failed":failed,"checks":checks]
        try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:CommandLine.arguments[1]))
        print("Studio: \(checks.count-failed) passed; \(failed) failed")
        if failed > 0 { exit(1) }
    }
}
