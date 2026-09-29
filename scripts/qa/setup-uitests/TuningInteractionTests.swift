import CryptoKit
import XCTest

/// Panel tuning (D09) against scripts/qa/serve_setup.py: test patterns go on
/// the wall through a temporary display and never change the saved mode,
/// launch flags are sent once and lock until the panel is back, refused
/// writes show the wall's value, and the reset keeps True colour.
final class TuningInteractionTests: SetupHarnessCase {
    /// About, then the tuning page through -about-page tuning (which also
    /// sets tuning.unlocked). Waits for the page, and for the knobs unless
    /// the phase has none.
    @MainActor func openTuning(phase: String = "connected", extra: [String] = [],
                               before: [(String, [String: Any])] = [], knobs: Bool = true) async throws -> XCUIApplication {
        let app = try await launch("about", phase: phase, extra: ["-about-page", "tuning"] + extra, before: before)
        XCTAssertTrue(app.navigationBars["Panel tuning"].waitForExistence(timeout: 12), "Panel tuning did not open")
        if knobs { XCTAssertTrue(element("tuning.group.Panel", in: app).waitForExistence(timeout: 12), "The knobs were not read") }
        return app
    }

    /// Scrolls until the element sits inside the window, below the pinned
    /// strip (which covers the top 56 pt once the preview has scrolled away),
    /// for drags, which XCUITest does not scroll to, and for taps that must
    /// not land on the strip.
    @MainActor func bringIntoView(_ target: XCUIElement, in app: XCUIApplication) {
        XCTAssertTrue(target.waitForExistence(timeout: 8), target.debugDescription)
        let window = app.windows.firstMatch.frame
        var previous: CGRect?
        // Up to 24 swipes of about 370 pt: with every row changed the page
        // runs to about 5,600 pt, and Return to defaults sits at its foot.
        for _ in 0..<24 {
            let frame = target.frame
            if frame.minY > window.minY + 180 && frame.maxY < window.maxY - 90 { return }
            // The page has ended: its last controls (Return to defaults and
            // its confirmation) stop about 80 pt above the bottom and never
            // clear the 90 pt margin. A target the last swipe did not move
            // counts once it is wholly inside the window, below the strip.
            if frame == previous && frame.minY > window.minY + 180 && frame.maxY < window.maxY { return }
            previous = frame
            // Swipes start in the page margin, off every control. A
            // vertical swipe on a rail is left to the scroll anyway.
            let from = app.coordinate(withNormalizedOffset: CGVector(dx: 0.03, dy: 0.5))
            let to = from.withOffset(CGVector(dx: 0, dy: frame.midY > window.midY ? -220 : 220))
            from.press(forDuration: 0.05, thenDragTo: to)
        }
        XCTFail("Could not scroll \(target.identifier) into view")
    }

    func tuningPosts(_ snapshot: [String: Any], fields: [String]? = nil) -> [[String: Any]] {
        posts(snapshot, path: "/tuning").filter { fields == nil || $0["fields"] as? [String] == fields }
    }

    func tuningValue(_ snapshot: [String: Any], _ name: String) -> Double? {
        ((snapshot["tuning"] as? [String: Any])?["values"] as? [String: Any])?[name] as? Double
    }

    /// The first number in an accessibility value such as "12 out of 255".
    func leadingNumber(_ value: Any?) -> Double? {
        guard let text = value as? String else { return nil }
        return Double(text.split(separator: " ").first.map(String.init) ?? "")
    }

    /// Dark steps at 64, built here because the test bundle cannot import
    /// the app's TuningPatterns. The same rule: eight columns of 8 to 64.
    func darkStepsSHA(side: Int = 64) -> String {
        var pixels = [UInt8](repeating: 0, count: side * side * 3)
        let levels: [UInt8] = [8, 16, 24, 32, 40, 48, 56, 64]
        for y in 0..<side {
            for x in 0..<side {
                let level = levels[min(7, (x * 64 / side) / 8)]
                let i = (y * side + x) * 3
                pixels[i] = level; pixels[i + 1] = level; pixels[i + 2] = level
            }
        }
        return SHA256.hash(data: Data(pixels)).map { String(format: "%02x", $0) }.joined()
    }

    /// Polls the fixture until a condition holds, up to about 8 s.
    func eventually(_ what: String, _ condition: @escaping ([String: Any]) -> Bool) async throws -> [String: Any] {
        var snapshot = try await status()
        for _ in 0..<40 {
            if condition(snapshot) { return snapshot }
            try await Task.sleep(for: .milliseconds(200))
            snapshot = try await status()
        }
        XCTFail(what)
        return snapshot
    }

    // MARK: Test patterns

    @MainActor func testTuningPatternShowsAndEndsWithoutChangingSavedMode() async throws {
        let app = try await openTuning()
        tap("tuning.pattern.darkSteps", in: app)
        let active = try await waitForSession(active: true, purpose: "tuning")
        let showing = try await eventually("The wall is not showing Dark steps") {
            ($0["frame"] as? [String: Any])?["sha256"] as? String == self.darkStepsSHA()
        }
        assertPreserved(active)
        assertPreserved(showing)
        XCTAssertTrue(waitForLabel(element("tuning.patternState", in: app), containing: "ON THE WALL"))
        tap("tuning.pattern.wall", in: app)
        assertPreserved(try await waitForSession(active: false))
    }

    @MainActor func testTuningLeavingPageEndsPattern() async throws {
        let app = try await openTuning()
        tap("tuning.pattern.grid", in: app)
        _ = try await waitForSession(active: true, purpose: "tuning")
        app.navigationBars["Panel tuning"].buttons.element(boundBy: 0).tap()
        let ended = try await waitForSession(active: false)
        assertPreserved(ended)
    }

    @MainActor func testTuningPatternRefusedWhileOccupied() async throws {
        let app = try await openTuning(before: [("/qa/occupy", ["purpose": "panel"])])
        let occupied = element("tuning.occupied", in: app)
        XCTAssertTrue(occupied.waitForExistence(timeout: 10))
        XCTAssertTrue(waitForLabel(occupied, containing: "A panel check is on the wall."))
        for pattern in ["wall", "greys", "darkSteps", "darkColours", "bars", "grid"] {
            XCTAssertFalse(app.buttons["tuning.pattern.\(pattern)"].isEnabled, pattern)
        }
        let snapshot = try await status()
        XCTAssertTrue(posts(snapshot, path: "/display-session").isEmpty)
    }

    // MARK: Launch flags

    @MainActor func testTuningRestartKnobSendsOnlyOnRelease() async throws {
        let app = try await openTuning()
        let rail = element("tuning.knob.bit_depth", in: app)
        bringIntoView(rail, in: app)
        // Across several steps, with a pause before letting go.
        let start = rail.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.3))
        let end = rail.coordinate(withNormalizedOffset: CGVector(dx: 0.45, dy: 0.3))
        start.press(forDuration: 0.1, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.4)
        _ = try await eventually("No write after the release") { !self.tuningPosts($0).isEmpty }
        try await Task.sleep(for: .seconds(1))
        let settled = try await status()
        XCTAssertEqual(tuningPosts(settled).count, 1, "\(tuningPosts(settled))")
        XCTAssertEqual(tuningPosts(settled, fields: ["bit_depth"]).count, 1)
        XCTAssertNotEqual(tuningValue(settled, "bit_depth"), 64)
        // On the Picture tab the preview's cover says it, not the status.
        XCTAssertTrue(waitForLabel(element("tuning.preview", in: app), containing: "The panel is restarting"))
        _ = try await api("/qa/renderer", ["state": "running"])
        XCTAssertTrue(waitForLabel(element("tuning.status", in: app), containing: "Panel back with the new setting", timeout: 6))
    }

    @MainActor func testTuningRestartKnobsLockedWhileRestarting() async throws {
        let app = try await openTuning(extra: ["-tuning-send", "bit_depth=48"])
        XCTAssertTrue(waitForLabel(element("tuning.preview", in: app), containing: "The panel is restarting", timeout: 10))
        let addressing = app.buttons["tuning.knob.panel_type.3"]
        let dithering = app.switches["tuning.knob.temporal_dither"]
        XCTAssertTrue(addressing.waitForExistence(timeout: 5))
        XCTAssertFalse(addressing.isEnabled)
        XCTAssertFalse(dithering.isEnabled)
        XCTAssertTrue(element("tuning.knob.gain_r", in: app).isEnabled, "A live knob stays enabled")
        _ = try await api("/qa/renderer", ["state": "running"])
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: addressing)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 6), .completed)
        XCTAssertTrue(dithering.isEnabled)
    }

    /// XCUITest on iOS has no increment or decrement, so -tuning-adjust
    /// takes the rail's VoiceOver path three times, 150 ms apart. 64 is the
    /// top of 4 to 64, so the three steps go down.
    @MainActor func testTuningVoiceOverIncrementCommitsOnce() async throws {
        let app = try await openTuning(extra: ["-tuning-adjust", "bit_depth=-3"])
        XCTAssertTrue(element("tuning.knob.bit_depth", in: app).waitForExistence(timeout: 8))
        _ = try await eventually("No write after the adjustments") { !self.tuningPosts($0).isEmpty }
        try await Task.sleep(for: .seconds(1.5))
        let settled = try await status()
        XCTAssertEqual(tuningPosts(settled).count, 1, "\(tuningPosts(settled))")
        XCTAssertEqual(tuningValue(settled, "bit_depth"), 52)
    }

    @MainActor func testTuningScrollOverRailSendsNothing() async throws {
        let app = try await openTuning()
        let rail = element("tuning.knob.bit_depth", in: app)
        bringIntoView(rail, in: app)
        let start = rail.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 6, dy: -260)))
        try await Task.sleep(for: .seconds(1.5))
        let snapshot = try await status()
        XCTAssertTrue(tuningPosts(snapshot).isEmpty)
    }

    @MainActor func testTuningStalledOffersRestart() async throws {
        let app = try await openTuning(before: [("/qa/renderer", ["state": "stalled"])])
        let restart = app.buttons["tuning.restart"]
        XCTAssertTrue(restart.waitForExistence(timeout: 10))
        tap("tuning.restart", in: app)
        _ = try await eventually("Restart the panel was not sent") { !self.posts($0, path: "/tuning/restart").isEmpty }
        XCTAssertTrue(waitForLabel(element("tuning.preview", in: app), containing: "The panel is restarting"))
    }

    /// The wall's frame is the brain's picture, which carries on, so the
    /// preview is dimmed to match the dark panel, and the status does not
    /// repeat the notice.
    @MainActor func testTuningStoppedPreviewIsDark() async throws {
        let app = try await openTuning(before: [("/qa/renderer", ["state": "stopped"])])
        XCTAssertTrue(element("tuning.stopped", in: app).waitForExistence(timeout: 10))
        XCTAssertTrue(waitForLabel(element("tuning.preview", in: app), containing: "The panel is dark"))
        XCTAssertFalse(element("tuning.status", in: app).exists, "The status repeated the notice")
    }

    @MainActor func testTuningStalledPutsBackOnlyTheLastSetting() async throws {
        let app = try await openTuning(extra: ["-tuning-send", "bit_depth=48"])
        XCTAssertTrue(waitForLabel(element("tuning.preview", in: app), containing: "The panel is restarting", timeout: 10))
        _ = try await api("/qa/renderer", ["state": "stalled"])
        let revert = app.buttons["tuning.revert"]
        XCTAssertTrue(revert.waitForExistence(timeout: 8))
        XCTAssertTrue(revert.label.contains("64 planes"), revert.label)
        tap("tuning.revert", in: app)
        let snapshot = try await eventually("The last setting was not put back") { self.tuningValue($0, "bit_depth") == 64 }
        let writes = tuningPosts(snapshot)
        XCTAssertEqual(writes.last?["fields"] as? [String], ["bit_depth"])
        XCTAssertEqual((snapshot["tuning"] as? [String: Any])?["panel_brightness"] as? Int, 160, "The ceiling is never part of a remedy")
    }

    // MARK: Writes

    @MainActor func testTuningLiveKnobFollowsDrag() async throws {
        let app = try await openTuning()
        let rail = element("tuning.knob.black_point", in: app)
        bringIntoView(rail, in: app)
        let start = rail.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.3))
        let end = rail.coordinate(withNormalizedOffset: CGVector(dx: 0.55, dy: 0.3))
        start.press(forDuration: 0.1, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.6)
        _ = try await eventually("No write while dragging") { !self.tuningPosts($0, fields: ["black_point"]).isEmpty }
        try await Task.sleep(for: .seconds(1.5))
        let settled = try await status()
        XCTAssertFalse(tuningPosts(settled, fields: ["black_point"]).isEmpty)
        let shown = leadingNumber(rail.value)
        XCTAssertNotNil(shown)
        XCTAssertEqual(shown, tuningValue(settled, "black_point"))
        XCTAssertNotEqual(shown, 0)
    }

    @MainActor func testTuningRefusedWriteShowsWallValue() async throws {
        let app = try await openTuning()
        let toggle = app.switches["tuning.knob.temporal_dither"]
        bringIntoView(toggle, in: app)
        XCTAssertEqual(toggle.value as? String, "1")
        _ = try await api("/qa/reject", ["enabled": true])
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        let problem = element("tuning.knob.temporal_dither.problem", in: app)
        XCTAssertTrue(problem.waitForExistence(timeout: 10))
        XCTAssertTrue(waitForLabel(problem, containing: "The wall did not accept this value. It is still using the one shown."))
        let back = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == '1'"), object: toggle)
        XCTAssertEqual(XCTWaiter.wait(for: [back], timeout: 6), .completed, "The switch did not return to the wall's value")
    }

    @MainActor func testTuningUseDefaultSendsDefault() async throws {
        let app = try await openTuning(phase: "tuning-changed")
        let (_, tuning) = try await fetch("/tuning")
        let shipped = (tuning["defaults"] as? [String: Any])?["black_point"] as? Double
        bringIntoView(app.buttons["tuning.knob.black_point.default"], in: app)
        tap("tuning.knob.black_point.default", in: app)
        let snapshot = try await eventually("Use default was not sent") { !self.tuningPosts($0, fields: ["black_point"]).isEmpty }
        let settled = try await eventually("The wall did not take the default") { self.tuningValue($0, "black_point") == shipped }
        XCTAssertEqual(tuningPosts(snapshot, fields: ["black_point"]).count, 1)
        XCTAssertEqual(tuningValue(settled, "black_point"), shipped)
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: app.buttons["tuning.knob.black_point.default"])
        XCTAssertEqual(XCTWaiter.wait(for: [gone], timeout: 6), .completed, "The Default line stayed")
    }

    @MainActor func testTuningResetNeedsConfirmationAndKeepsTrueColour() async throws {
        let app = try await openTuning(phase: "tuning-changed")
        bringIntoView(app.buttons["tuning.reset"], in: app)
        tap("tuning.reset", in: app)
        XCTAssertTrue(app.buttons["tuning.reset.confirm"].waitForExistence(timeout: 5))
        bringIntoView(app.buttons["tuning.reset.confirm"], in: app)
        // tuning-changed leaves spatial dither and row settle time at their
        // defaults, so the question names neither: it names only values
        // that a reset changes.
        let question = element("tuning.reset.question", in: app).label
        XCTAssertTrue(question.contains("Return every panel and listening setting to its default?"), question)
        XCTAssertFalse(question.contains("Row settle time") || question.contains("Spatial dither"), question)
        XCTAssertEqual(app.buttons["tuning.reset.confirm"].label, "Return to defaults", "One name for the action")
        let untouched = try await status()
        XCTAssertTrue(posts(untouched, path: "/tuning/reset").isEmpty, "Return to defaults alone sent a reset")
        tap("tuning.reset.confirm", in: app)
        let snapshot = try await eventually("The reset was not sent") { !self.posts($0, path: "/tuning/reset").isEmpty }
        let settled = try await eventually("The wall did not reset") { self.tuningValue($0, "bit_depth") == 64 }
        let state = settled["state"] as? [String: Any] ?? [:]
        XCTAssertEqual(state["wb_r"] as? Double, 0.92)
        XCTAssertEqual(state["wb_g"] as? Double, 0.87)
        XCTAssertEqual(state["wb_b"] as? Double, 0.8)
        XCTAssertEqual((settled["tuning"] as? [String: Any])?["panel_brightness"] as? Int, 160)
        XCTAssertEqual(posts(snapshot, path: "/tuning/reset").count, 1)
        XCTAssertTrue(element("tuning.reset.notice", in: app).waitForExistence(timeout: 6))
    }

    // MARK: States

    @MainActor func testTuningOfflineDisablesEverything() async throws {
        let app = try await openTuning()
        _ = try await api("/qa/available", ["enabled": false, "as": "http"])
        XCTAssertTrue(element("tuning.offline", in: app).waitForExistence(timeout: 12))
        // The notice says offline, so the status adds only when the values were read.
        XCTAssertTrue(waitForLabel(element("tuning.status", in: app), containing: "Last read"))
        // Nothing can be changed, so the page does not ask for a change.
        XCTAssertTrue(waitForLabel(element("tuning.intro", in: app), containing: "How the LEDs draw every picture."))
        XCTAssertFalse(element("tuning.knob.bit_depth", in: app).isEnabled)
        XCTAssertFalse(element("tuning.knob.black_point", in: app).isEnabled)
        XCTAssertFalse(app.switches["tuning.knob.temporal_dither"].isEnabled)
        XCTAssertFalse(app.buttons["tuning.knob.panel_type.3"].isEnabled)
        XCTAssertFalse(app.buttons["tuning.reset"].isEnabled)
        for pattern in ["greys", "darkSteps", "grid"] { XCTAssertFalse(app.buttons["tuning.pattern.\(pattern)"].isEnabled, pattern) }
        let snapshot = try await status()
        XCTAssertTrue(posts(snapshot).filter { ($0["path"] as? String ?? "").hasPrefix("/tuning") || $0["path"] as? String == "/display-session" }.isEmpty)
    }

    @MainActor func testTuningUnsupportedExplainsItself() async throws {
        let app = try await openTuning(phase: "tuning-unsupported", knobs: false)
        let notice = element("tuning.unsupported", in: app)
        XCTAssertTrue(notice.waitForExistence(timeout: 10))
        XCTAssertTrue(waitForLabel(notice, containing: "This wall’s software does not offer panel tuning."))
        XCTAssertFalse(element("tuning.status", in: app).exists, "The status repeated the notice")
        XCTAssertFalse(element("tuning.group.Panel", in: app).exists)
        XCTAssertFalse(element("tuning.group.Colour", in: app).exists)
        XCTAssertTrue(app.buttons["tuning.pattern.darkSteps"].isEnabled, "Patterns still work")
    }

    @MainActor func testTuningReadErrorOffersReadAgain() async throws {
        let app = try await openTuning(phase: "tuning-failing", knobs: false)
        XCTAssertTrue(element("tuning.readError", in: app).waitForExistence(timeout: 12))
        XCTAssertTrue(app.buttons["tuning.retry"].exists)
        XCTAssertFalse(element("tuning.group.Panel", in: app).exists)
    }

    @MainActor func testTuningInactiveNearestColour() async throws {
        let app = try await openTuning()
        let nearest = app.switches["tuning.knob.nearest_colour"]
        bringIntoView(nearest, in: app)
        XCTAssertFalse(nearest.isEnabled)
        XCTAssertTrue(app.staticTexts["Not used while time dithering is on, which does the same job over time."].exists)
    }

    @MainActor func testTuningListeningTabHasNoPatterns() async throws {
        let app = try await openTuning()
        tap("tuning.tab.listening", in: app)
        XCTAssertTrue(element("tuning.group.Hearing", in: app).waitForExistence(timeout: 5))
        XCTAssertTrue(app.navigationBars["Microphone tuning"].waitForExistence(timeout: 5), "The title follows the tab")
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'tuning.pattern.'")).count, 0)
        XCTAssertFalse(element("tuning.group.Panel", in: app).exists)
        tap("tuning.hearingLink", in: app)
        XCTAssertTrue(app.navigationBars["Hearing"].waitForExistence(timeout: 8))
    }

    @MainActor func testTuningNoCalibrationSliders() async throws {
        let app = try await openTuning()
        for name in ["Calibration red", "Calibration green", "Calibration blue"] {
            XCTAssertFalse(app.descendants(matching: .any)[name].exists, name)
        }
        let measured = element("tuning.measured", in: app)
        bringIntoView(measured, in: app)
        XCTAssertTrue(measured.label.contains("red 0.92, green 0.87, blue 0.80"), measured.label)
    }
}
