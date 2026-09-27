import XCTest

final class SetupInteractionTests: XCTestCase {
    func api(_ path: String, _ body: [String: Any]? = nil) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:65367" + path)!)
        request.timeoutInterval = 8
        if let body {
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @MainActor func launch(_ page: String, phase: String = "connected", fixture: String? = nil) async throws -> XCUIApplication {
        _ = try await api("/qa/reset", ["phase": phase])
        let app = XCUIApplication(bundleIdentifier: "com.jalenedusei.tessera")
        app.launchArguments = ["-nointro", "-onboarded", "YES", "-intro.sting.migrated", "YES", "-intro.style", "none", "-design", "room", "-wall.host", "127.0.0.1:65367", "-reporter.host", "", "-reporter.background", "NO", "-live.enabled", "NO", "-guests-reset"]
        if page == "onboarding" {
            app.launchArguments += ["-onboarding-step", "welcome"]
        } else if page == "pictures" {
            app.launchArguments += ["-settings", "-settings-page", "services", "-service-page", "pictures"]
        } else {
            app.launchArguments += ["-settings", "-settings-page", page]
        }
        if let fixture { app.launchArguments += ["-guests-fixture", fixture] }
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 12))
        if page == "onboarding" {
            XCTAssertTrue(app.buttons["onboarding.usePhone"].waitForExistence(timeout: 12))
        } else {
            XCTAssertTrue(app.navigationBars.firstMatch.waitForExistence(timeout: 12))
        }
        return app
    }

    @MainActor func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<9 {
            if element.exists { return }
            app.swipeUp()
        }
        XCTAssertTrue(element.exists, element.debugDescription)
    }

    @MainActor func tap(_ id: String, in app: XCUIApplication) {
        let element = app.buttons[id]
        _ = element.waitForExistence(timeout: 8)
        reveal(element, in: app)
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: 8), .completed, "Button did not become ready: \(id)")
        element.tap()
    }

    @MainActor func element(_ id: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)[id].firstMatch
    }

    @MainActor func dismissKeyboard(_ app: XCUIApplication) {
        if app.toolbars.buttons["Done"].exists { app.toolbars.buttons["Done"].tap() }
        else if app.keyboards.buttons["Done"].exists { app.keyboards.buttons["Done"].tap() }
    }

    @MainActor func enterNetwork(in app: XCUIApplication, password: String) {
        let ssid = app.textFields["guests.ssid"]
        reveal(ssid, in: app); ssid.tap(); ssid.typeText("Tessera guest")
        let secret = app.secureTextFields["guests.password"]
        reveal(secret, in: app); secret.tap(); secret.typeText(password)
        dismissKeyboard(app)
    }

    func waitForSession(active: Bool, purpose: String? = nil) async throws -> [String: Any] {
        var snapshot = [String: Any]()
        for _ in 0..<40 {
            snapshot = try await api("/qa/status")
            let session = snapshot["session"] as? [String: Any] ?? [:]
            if session["active"] as? Bool == active && (purpose == nil || session["purpose"] as? String == purpose) { return snapshot }
            try await Task.sleep(for: .milliseconds(200))
        }
        XCTFail("The temporary display did not reach the expected confirmed state")
        return snapshot
    }

    func assertPreserved(_ snapshot: [String: Any], mode: String = "clock", file: StaticString = #filePath, line: UInt = #line) {
        let state = snapshot["state"] as? [String: Any] ?? [:]
        let initial = snapshot["initial"] as? [String: Any] ?? [:]
        XCTAssertEqual(state["mode"] as? String, mode, file: file, line: line)
        for key in ["brightness", "wb_r", "wb_g", "wb_b"] {
            XCTAssertEqual(state[key] as? Double, initial[key] as? Double, key, file: file, line: line)
        }
        XCTAssertEqual(state["finish"] as? String, "poster", file: file, line: line)
    }

    @MainActor func testGuestPasswordIsSecureAndInvalidInputCannotShow() async throws {
        let app = try await launch("guests")
        enterNetwork(in: app, password: "short")
        XCTAssertTrue(app.secureTextFields["guests.password"].exists)
        XCTAssertFalse(app.textFields["guests.password"].exists)
        XCTAssertFalse(app.buttons["guests.show"].isEnabled)
        let snapshot = try await api("/qa/status")
        XCTAssertFalse((snapshot["requests"] as? [[String: Any]] ?? []).contains { $0["path"] as? String == "/display-session" })
    }

    @MainActor func testGuestCodeShowsAndHidesWithoutChangingSavedMode() async throws {
        let app = try await launch("guests", fixture: "wifi")
        tap("guests.show", in: app)
        let active = try await waitForSession(active: true, purpose: "guests")
        assertPreserved(active)
        XCTAssertTrue(element("guests.showing", in: app).waitForExistence(timeout: 8))
        tap("guests.hide", in: app)
        let ended = try await waitForSession(active: false)
        assertPreserved(ended)
        XCTAssertTrue(element("guests.notice", in: app).waitForExistence(timeout: 8))
    }

    @MainActor func testGuestPasswordIsForgottenWhenAppBackgrounds() async throws {
        let app = try await launch("guests")
        enterNetwork(in: app, password: "A good evening")
        XCTAssertTrue(app.buttons["guests.show"].isEnabled)
        XCUIDevice.shared.press(.home)
        app.activate()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 8))
        try await Task.sleep(for: .seconds(1))
        XCTAssertFalse(app.buttons["guests.show"].isEnabled)
        let secret = app.secureTextFields["guests.password"]
        reveal(secret, in: app)
        XCTAssertEqual(secret.value as? String, "Password for this network")
        let snapshot = try await api("/qa/status")
        assertPreserved(snapshot)
    }

    @MainActor func testGuestFailedShowDoesNotClaimSuccess() async throws {
        let app = try await launch("guests", fixture: "wifi")
        _ = try await api("/qa/reject", [:])
        tap("guests.show", in: app)
        XCTAssertTrue(element("guests.problem", in: app).waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["guests.hide"].exists)
        let snapshot = try await api("/qa/status")
        XCTAssertEqual((snapshot["session"] as? [String: Any])?["active"] as? Bool, false)
        assertPreserved(snapshot)
    }

    @MainActor func testPanelPatternChangeAndEndPreservePreviousView() async throws {
        let app = try await launch("panel")
        let untouched = try await api("/qa/status")
        XCTAssertEqual((untouched["session"] as? [String: Any])?["active"] as? Bool, false)
        tap("panel.start", in: app)
        _ = try await waitForSession(active: true, purpose: "panel")
        tap("panel.pattern.red", in: app)
        var snapshot = try await api("/qa/status")
        for _ in 0..<25 {
            if (snapshot["frame"] as? [String: Any])?["first_rgb"] as? [Int] == [191, 0, 0] { break }
            try await Task.sleep(for: .milliseconds(200)); snapshot = try await api("/qa/status")
        }
        XCTAssertEqual((snapshot["frame"] as? [String: Any])?["first_rgb"] as? [Int], [191, 0, 0])
        assertPreserved(snapshot)
        tap("panel.end", in: app)
        assertPreserved(try await waitForSession(active: false))
    }

    @MainActor func testPanelInterruptedSessionDoesNotRestoreOverNewMode() async throws {
        let app = try await launch("panel")
        tap("panel.start", in: app)
        _ = try await waitForSession(active: true, purpose: "panel")
        _ = try await api("/qa/interrupt", [:])
        // The page polls every 2 s and swaps Finish for Start when the wall
        // has already ended the check. Either way, nothing may be restored.
        if !app.buttons["panel.start"].waitForExistence(timeout: 6), app.buttons["panel.end"].exists { tap("panel.end", in: app) }
        let snapshot = try await waitForSession(active: false)
        assertPreserved(snapshot, mode: "ambient")
    }

    @MainActor func testCalibrationOnlyStartsOnActionAndCancelPreservesGains() async throws {
        let app = try await launch("colour")
        let untouched = try await api("/qa/status")
        XCTAssertEqual((untouched["session"] as? [String: Any])?["active"] as? Bool, false)
        XCTAssertFalse((untouched["requests"] as? [[String: Any]] ?? []).contains { $0["path"] as? String == "/display-session" })
        tap("colour.measure", in: app)
        XCTAssertTrue(app.buttons["calibration.start"].waitForExistence(timeout: 8))
        let intro = try await api("/qa/status")
        XCTAssertEqual((intro["session"] as? [String: Any])?["active"] as? Bool, false)
        XCTAssertFalse((intro["requests"] as? [[String: Any]] ?? []).contains { $0["path"] as? String == "/display-session" })
        tap("calibration.start", in: app)
        let measuring = try await waitForSession(active: true, purpose: "calibration")
        assertPreserved(measuring)
        tap("calibration.cancel", in: app)
        assertPreserved(try await waitForSession(active: false))
    }

    @MainActor func testCalibrationRefusedStartPreservesPreviousView() async throws {
        let app = try await launch("colour")
        _ = try await api("/qa/reject", [:])
        tap("colour.measure", in: app)
        tap("calibration.start", in: app)
        XCTAssertTrue(element("calibration.problem", in: app).waitForExistence(timeout: 10))
        let snapshot = try await api("/qa/status")
        XCTAssertEqual((snapshot["session"] as? [String: Any])?["active"] as? Bool, false)
        assertPreserved(snapshot)
        tap("calibration.cancel", in: app)
    }

    @MainActor func testPicturesKeyIsSecureAndMalformedKeyCannotSave() async throws {
        let app = try await launch("pictures", phase: "unlinked")
        let manage = element("pictures.manage", in: app)
        reveal(manage, in: app); manage.tap()
        let key = app.secureTextFields["pictures.key"]
        reveal(key, in: app); key.tap(); key.typeText("bad")
        let engine = app.textFields["pictures.engine"]
        reveal(engine, in: app); engine.tap(); engine.typeText("qa_engine_12345")
        dismissKeyboard(app)
        XCTAssertFalse(app.buttons["pictures.save"].isEnabled)
        XCTAssertFalse(app.textFields["pictures.key"].exists)
        let snapshot = try await api("/qa/status")
        XCTAssertEqual(((snapshot["services"] as? [String: Any])?["google"] as? [String: Any])?["key_set"] as? Bool, false)
    }

    @MainActor func testPicturesRemoveGoogleKeepsWebFallback() async throws {
        let app = try await launch("pictures")
        let manage = element("pictures.manage", in: app)
        reveal(manage, in: app); manage.tap()
        tap("pictures.remove", in: app)
        tap("pictures.confirmRemove", in: app)
        XCTAssertTrue(element("pictures.notice", in: app).waitForExistence(timeout: 10))
        let snapshot = try await api("/qa/status")
        let google = (snapshot["services"] as? [String: Any])?["google"] as? [String: Any]
        XCTAssertEqual(google?["key_set"] as? Bool, false)
        XCTAssertEqual(google?["cx_set"] as? Bool, false)
        XCTAssertEqual(google?["provider"] as? String, "web")
        assertPreserved(snapshot)
    }

    @MainActor func testOnboardingCanContinueOnThisPhone() async throws {
        let app = try await launch("onboarding")
        tap("onboarding.usePhone", in: app)
        tap("onboarding.usePhone", in: app)
        tap("onboarding.continue", in: app)
        let sun = app.switches["onboarding.sun"]
        reveal(sun, in: app)
        XCTAssertFalse(sun.isEnabled)
        XCTAssertTrue(app.staticTexts["ON THIS PHONE"].exists)
        tap("onboarding.continue", in: app)
        tap("onboarding.open", in: app)
        XCTAssertTrue(app.buttons["onboarding.open"].waitForNonExistence(timeout: 8))
        let snapshot = try await api("/qa/status")
        XCTAssertFalse((snapshot["requests"] as? [[String: Any]] ?? []).contains { $0["path"] as? String == "/display-session" })
        assertPreserved(snapshot)
    }

    @MainActor func testOnboardingCanBeFinishedLater() async throws {
        let app = try await launch("onboarding")
        tap("onboarding.skip", in: app)
        XCTAssertTrue(app.buttons["onboarding.skip"].waitForNonExistence(timeout: 8))
        let snapshot = try await api("/qa/status")
        assertPreserved(snapshot)
    }
}
