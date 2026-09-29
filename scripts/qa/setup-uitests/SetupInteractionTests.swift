import XCTest

/// Setup, calibration, panel check, guests and pictures. The shared launch,
/// fixture and tap helpers are SetupHarnessCase's (SetupHarness.swift).
final class SetupInteractionTests: SetupHarnessCase {
    @MainActor func enterNetwork(in app: XCUIApplication, password: String) {
        let ssid = app.textFields["guests.ssid"]
        reveal(ssid, in: app); ssid.tap(); ssid.typeText("Tessera guest")
        let secret = app.secureTextFields["guests.password"]
        reveal(secret, in: app); secret.tap(); secret.typeText(password)
        dismissKeyboard(app)
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
