import Foundation

@main
struct IPodWheelTests {
    static func main() throws {
        var checks: [[String: Any]] = []
        func check(_ name: String, _ condition: @autoclosure () -> Bool) {
            let passed = condition()
            checks.append(["name": name, "passed": passed])
            if !passed { fputs("FAIL: \(name)\n", stderr) }
        }
        func point(_ degrees: Double) -> (x: Double, y: Double) {
            let radians = degrees * .pi / 180
            return (100 * cos(radians), 100 * sin(radians))
        }
        var wheel = IPodWheelInteraction()
        check("idle cannot sleep", !wheel.hold())
        check("idle movement produces no detents", wheel.move(x: 100, y: 0) == 0)
        check("touch outside the ring is rejected", !wheel.begin(x: 117, y: 0))
        check("nonfinite touch is rejected", !wheel.begin(x: .nan, y: 0))
        check("center touch begins", wheel.begin(x: 0, y: 0))
        check("center touch cannot sleep", !wheel.canHold)
        check("center tap selects", wheel.end(x: 0, y: 0, cancelled: false) == .center)
        check("release clears tracking", !wheel.isActive)

        for (x, y, sector) in [(0.0, -100.0, IPodWheelInteraction.Sector.top),
                               (100.0, 0.0, .right), (0.0, 100.0, .bottom), (-100.0, 0.0, .left)] {
            wheel.begin(x: x, y: y)
            check("\(sector) tap keeps its command", wheel.end(x: x, y: y, cancelled: false) == sector)
        }
        wheel.begin(x: 0, y: 100)
        check("bottom press can sleep", wheel.canHold)
        check("hold fires once", wheel.hold())
        check("hold cannot fire again", !wheel.hold())
        check("another began cannot restart a held press", !wheel.begin(x: 0, y: 100))
        check("held finger movement cannot rotate", wheel.move(x: 100, y: 0) == 0)
        check("held release does not also play", wheel.end(x: 100, y: 0, cancelled: false) == nil)
        check("hold is cleared on release", !wheel.held)

        wheel.begin(x: 0, y: 100)
        _ = wheel.move(x: 10, y: 100)
        check("movement disarms sleep", !wheel.canHold)
        check("moved press cannot fire delayed hold", !wheel.hold())
        check("drag release cannot also play", wheel.end(x: 10, y: 100, cancelled: false) == nil)

        wheel.begin(x: 100, y: 0)
        let clockwise = point(34)
        check("clockwise motion produces two detents", wheel.move(x: clockwise.x, y: clockwise.y) == 2)
        check("stationary movement produces no duplicate detents", wheel.move(x: clockwise.x, y: clockwise.y) == 0)
        check("rotation release cannot skip a song", wheel.end(x: clockwise.x, y: clockwise.y, cancelled: false) == nil)
        wheel.begin(x: 100, y: 0)
        let counterclockwise = point(-34)
        check("counterclockwise motion produces two negative detents", wheel.move(x: counterclockwise.x, y: counterclockwise.y) == -2)
        wheel.cancel()
        check("cancellation clears tracking", !wheel.isActive)
        check("cancellation clears previous sector", wheel.startSector == nil)
        check("cancelled release sends no command", wheel.end(x: 100, y: 0, cancelled: false) == nil)

        let start = point(170), wrap = point(-168)
        wheel.begin(x: start.x, y: start.y)
        check("crossing the angle seam advances one detent", wheel.move(x: wrap.x, y: wrap.y) == 1)
        wheel.cancel()
        wheel.begin(x: wrap.x, y: wrap.y)
        check("crossing back through the seam reverses one detent", wheel.move(x: start.x, y: start.y) == -1)
        wheel.cancel()

        wheel.begin(x: 0, y: 0)
        check("center drag cannot become wheel rotation", wheel.move(x: 100, y: 0) == 0)
        check("center-origin circular move still does not rotate", wheel.move(x: 0, y: 100) == 0)
        check("center drag cannot become a tap", wheel.end(x: 0, y: 0, cancelled: false) == nil)
        wheel.begin(x: 100, y: 0)
        check("entering the center produces no detents", wheel.move(x: 0, y: 0) == 0)
        check("crossing the center does not jump twelve detents", wheel.move(x: -100, y: 0) == 0)
        wheel.cancel()
        wheel.begin(x: 100, y: 0)
        check("moving far outside the ring produces no detents", wheel.move(x: 500, y: 500) == 0)
        check("returning to the ring does not jump", wheel.move(x: 0, y: 100) == 0)
        wheel.cancel()

        wheel.begin(x: 0, y: 100)
        check("system cancellation never plays", wheel.end(x: 0, y: 100, cancelled: true) == nil)
        check("cancelled hold cannot fire later", !wheel.hold())
        wheel.begin(x: 0, y: -100)
        check("missing move events cannot turn a distant release into a tap", wheel.end(x: 50, y: -100, cancelled: false) == nil)
        wheel.begin(x: 100, y: 0)
        check("nonfinite move is ignored", wheel.move(x: .infinity, y: 0) == 0)
        check("nonfinite release never acts", wheel.end(x: .nan, y: 0, cancelled: false) == nil)

        let failed = checks.filter { ($0["passed"] as? Bool) != true }.count
        let result: [String: Any] = ["suite": "IPodWheelInteraction", "passed": checks.count - failed,
                                     "failed": failed, "checks": checks]
        let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
        print(String(decoding: data, as: UTF8.self))
        if failed > 0 { exit(1) }
    }
}
