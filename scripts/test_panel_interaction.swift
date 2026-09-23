import Foundation

@main
struct PanelInteractionTests {
    static func main() throws {
        var checks: [[String: Any]] = []
        func check(_ name: String, _ condition: @autoclosure () -> Bool) {
            let passed = condition()
            checks.append(["name": name, "passed": passed])
            if !passed { fputs("FAIL: \(name)\n", stderr) }
        }
        func near(_ value: Double?, _ expected: Double) -> Bool {
            value.map { abs($0 - expected) < 0.000_001 } ?? false
        }

        var gesture = PanelInteraction()
        check("idle cannot hold", !gesture.canHold)
        check("idle release does not send", gesture.end(dx: 100) == nil)

        gesture.begin(brightness: 0.5)
        check("touch begins pending", gesture.phase == .pending)
        check("stationary touch can hold", gesture.canHold)
        check("touch down does not change brightness", gesture.value == nil)
        check("small movement has no brightness", gesture.update(dx: 2, dy: -3, height: 400) == nil)
        check("small movement preserves hold", gesture.canHold)
        check("tap sends no command", gesture.end(dx: 2) == nil)
        check("release resets phase", gesture.phase == .idle)

        gesture.begin(brightness: 0.5)
        check("vertical drag resolves brightness", near(gesture.update(dx: 1, dy: -76, height: 400), 0.68))
        check("brightness locks axis", gesture.phase == .brightness)
        check("brightness cancels hold", !gesture.canHold)
        _ = gesture.update(dx: 200, dy: -76, height: 400)
        check("later horizontal motion does not switch axis", gesture.phase == .brightness)
        if case .brightness(let value) = gesture.end(dx: 200) {
            check("brightness release commits exact value", near(value, 0.68))
        } else {
            check("brightness release commits exact value", false)
        }
        check("committed gesture clears value", gesture.value == nil)

        gesture.begin(brightness: 0.5)
        check("brightness clamps to maximum", near(gesture.update(dx: 0, dy: -1_000, height: 400), 1))
        check("brightness clamps to minimum", near(gesture.update(dx: 0, dy: 1_000, height: 400), 0.05))
        gesture.cancel()

        gesture.begin(brightness: -3)
        check("invalid low start is clamped", near(gesture.update(dx: 0, dy: -40, height: 400), 0.15))
        gesture.cancel()
        gesture.begin(brightness: 3)
        check("invalid high start is clamped", near(gesture.update(dx: 0, dy: 40, height: 400), 0.91))
        gesture.cancel()
        gesture.begin(brightness: 0.5)
        check("zero-height geometry stays finite", near(gesture.update(dx: 0, dy: -10, height: 0), 1))
        gesture.cancel()

        gesture.begin(brightness: 0.5)
        _ = gesture.update(dx: -20, dy: 1, height: 400)
        check("horizontal gesture resolves song", gesture.phase == .song)
        check("song gesture does not change brightness", gesture.value == nil)
        check("short song gesture does not skip", gesture.end(dx: -44) == nil)
        gesture.begin(brightness: 0.5)
        _ = gesture.update(dx: -50, dy: 2, height: 400)
        check("left flick skips next", gesture.end(dx: -50) == .next)
        gesture.begin(brightness: 0.5)
        _ = gesture.update(dx: 50, dy: 2, height: 400)
        check("right flick skips previous", gesture.end(dx: 50) == .previous)

        gesture.begin(brightness: 0.5)
        _ = gesture.update(dx: 9, dy: 9, height: 400)
        check("diagonal movement cancels long press", !gesture.canHold)
        check("diagonal movement does not choose an axis", gesture.phase == .pending)
        check("diagonal movement cannot fire hold", !gesture.hold())
        check("diagonal release sends nothing", gesture.end(dx: 9) == nil)

        gesture.begin(brightness: 0.5)
        check("stationary hold fires once", gesture.hold())
        check("held phase is explicit", gesture.phase == .held)
        check("held gesture cannot fire twice", !gesture.hold())
        gesture.begin(brightness: 0.2)
        check("repeated touch begin preserves held phase", gesture.phase == .held)
        check("repeated touch begin cannot rearm hold", !gesture.hold())
        check("motion after hold cannot dim", gesture.update(dx: 0, dy: -80, height: 400) == nil)
        check("motion after hold cannot choose song", gesture.update(dx: -80, dy: 0, height: 400) == nil)
        check("held release sends no second action", gesture.end(dx: -80) == nil)

        gesture.begin(brightness: 0.5)
        _ = gesture.update(dx: 0, dy: -40, height: 400)
        gesture.cancel()
        check("interruption clears phase", gesture.phase == .idle)
        check("interruption clears transient brightness", gesture.value == nil)
        check("interruption cancels hold", !gesture.canHold)
        check("release after cancellation does not commit", gesture.end(dx: -100) == nil)
        gesture.begin(brightness: 0.8)
        check("new gesture after cancellation has clean state", gesture.phase == .pending && gesture.value == nil && gesture.canHold)
        gesture.begin(brightness: 0.2)
        check("repeated begin preserves initial brightness", near(gesture.update(dx: 0, dy: -40, height: 400), 0.9))
        gesture.cancel()

        gesture.begin(brightness: .nan)
        check("nonfinite start cannot poison rendered brightness", near(gesture.update(dx: 0, dy: 40, height: 400), 0.91))
        gesture.cancel()

        let failed = checks.filter { ($0["passed"] as? Bool) != true }.count
        let result: [String: Any] = ["suite": "PanelInteraction", "passed": checks.count - failed,
                                     "failed": failed, "checks": checks]
        let json = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
        FileHandle.standardOutput.write(json)
        FileHandle.standardOutput.write(Data([10]))
        if failed > 0 { exit(1) }
    }
}
