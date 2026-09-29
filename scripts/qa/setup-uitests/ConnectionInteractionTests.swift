import XCTest

/// The Connection page (D07) against scripts/qa/serve_setup.py. Every launch
/// passes -connection-reset: the outbox (app group) and the connection
/// history (UserDefaults) outlive the app, and one test's queue or events
/// would otherwise show up in the next.
final class ConnectionInteractionTests: SetupHarnessCase {
    private let reset = ["-connection-reset"]
    /// Writes that change the wall. /nowplaying and /pressing come from the
    /// room behind the sheet and say nothing about this page.
    private let writes: Set<String> = ["/state", "/frame", "/clip", "/display-session", "/display-session/end", "/replay"]

    @MainActor private func headline(_ app: XCUIApplication) -> XCUIElement { element("connection.headline", in: app) }

    @MainActor private func waitUntilConnected(_ app: XCUIApplication, timeout: TimeInterval = 12) {
        XCTAssertTrue(waitForLabel(headline(app), containing: "Connected", timeout: timeout), "The wall never answered")
    }

    private func wallWrites(_ snapshot: [String: Any]) -> [[String: Any]] {
        posts(snapshot).filter { writes.contains($0["path"] as? String ?? "") }
    }

    /// The field's text replaced, typed as an owner would.
    @MainActor private func replace(_ field: XCUIElement, with text: String) {
        field.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.5)).tap()
        let current = field.value as? String ?? ""
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count + 2))
        field.typeText(text)
    }

    /// Types the address and saves it with the keyboard's return key, which
    /// submits the field. There is no keyboard toolbar here, so the return
    /// key is also the only "Done": dismissing the keyboard first would save
    /// and close the editor, and a tap on Save after it would find nothing.
    @MainActor private func saveAddress(_ address: String, in app: XCUIApplication) {
        tap("connection.address.change", in: app)
        let field = app.textFields["connection.address.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        replace(field, with: address)
        field.typeText("\n")
        XCTAssertTrue(field.waitForNonExistence(timeout: 5), "The editor stayed open after saving \(address)")
        XCTAssertTrue(waitForLabel(element("connection.address.value", in: app), containing: address),
                      "The address in use is not \(address)")
    }

    /// Launch at Light, take the wall away, queue a brightness change, then
    /// open Connection from the Settings landing.
    @MainActor private func queueBrightnessWhileAway() async throws -> XCUIApplication {
        let app = try await launch("light", extra: reset)
        // Live once the app pulls frames: it only does that from a wall that answered.
        var snapshot = try await status()
        for _ in 0..<40 where ((snapshot["gets"] as? [String: Int])?["/frame.raw"] ?? 0) == 0 {
            try await Task.sleep(for: .milliseconds(300)); snapshot = try await status()
        }
        _ = try await api("/qa/available", ["enabled": false, "as": "silent"])
        try await Task.sleep(for: .seconds(8))
        let slider = app.sliders.firstMatch
        XCTAssertTrue(slider.waitForExistence(timeout: 5))
        slider.adjust(toNormalizedSliderPosition: 0.3)
        // The POST waits out the app's 3 s timeout before the change is queued.
        try await Task.sleep(for: .seconds(5))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        tap("settings.route.addresses", in: app)
        let row = element("connection.waiting.settings", in: app)
        XCTAssertTrue(row.waitForExistence(timeout: 10), "Nothing is shown waiting")
        XCTAssertTrue(waitForLabel(row, containing: "Brightness"))
        return app
    }

    @MainActor func testConnectionLiveCheckIsReadOnly() async throws {
        let app = try await launch("addresses", extra: reset)
        waitUntilConnected(app)
        let before = try await status()
        let checks = before["check_gets"] as? Int ?? 0
        tap("connection.primary", in: app)
        XCTAssertTrue(waitForLabel(element("connection.step.wall", in: app), containing: " ms", timeout: 15))
        // Loopback needs no Local Network access, and the page says so.
        XCTAssertTrue(waitForLabel(element("connection.step.permission", in: app), containing: "Not needed"))
        XCTAssertTrue(waitForLabel(element("connection.summary", in: app), containing: "Checked"))
        let after = try await status()
        XCTAssertEqual(wallWrites(after).count, wallWrites(before).count, "The check wrote to the wall")
        // Exactly one GET /state carried the check's header.
        XCTAssertEqual(after["check_gets"] as? Int, checks + 1)
        XCTAssertEqual((after["session"] as? [String: Any])?["active"] as? Bool, false)
    }

    @MainActor func testConnectionOfflineQueuesThenDeliversInOrder() async throws {
        let app = try await queueBrightnessWhileAway()
        XCTAssertTrue(waitForLabel(headline(app), containing: "Wall offline", timeout: 5))
        XCTAssertTrue(element("connection.reason", in: app).exists)
        let flipped = (try await status())["requests"] as? [[String: Any]] ?? []
        _ = try await api("/qa/available", ["enabled": true])
        XCTAssertTrue(waitForLabel(element("connection.delivery", in: app), containing: "Sent when the wall came back", timeout: 15))
        let after = try await status()
        let since = Array((after["requests"] as? [[String: Any]] ?? []).dropFirst(flipped.count))
        let delivered = since.filter { $0["path"] as? String == "/state" && $0["served"] as? Bool == true }
        XCTAssertEqual(delivered.count, 1, "\(delivered)")
        XCTAssertEqual(delivered.first?["fields"] as? [String], ["brightness"])
        XCTAssertFalse(element("connection.waiting.settings", in: app).exists)
    }

    @MainActor func testConnectionDiscardKeepsWallUnchanged() async throws {
        let app = try await queueBrightnessWhileAway()
        tap("connection.discard", in: app)
        tap("connection.confirmDiscard", in: app)
        XCTAssertTrue(element("connection.waiting", in: app).waitForNonExistence(timeout: 5))
        let flipped = (try await status())["requests"] as? [[String: Any]] ?? []
        _ = try await api("/qa/available", ["enabled": true])
        waitUntilConnected(app, timeout: 10)
        try await Task.sleep(for: .seconds(5))
        let after = try await status()
        let since = Array((after["requests"] as? [[String: Any]] ?? []).dropFirst(flipped.count))
        XCTAssertFalse(since.contains { $0["path"] as? String == "/state" && ($0["fields"] as? [String] ?? []).contains("brightness") })
        XCTAssertEqual((after["state"] as? [String: Any])?["brightness"] as? Double, 0.4)
        let recent = element("connection.recent", in: app)
        reveal(recent, in: app)
        XCTAssertTrue(recent.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", "Discarded changes that were waiting")).firstMatch.exists)
    }

    @MainActor func testConnectionAddressValidationAndNormalisation() async throws {
        let app = try await launch("addresses", extra: reset, seedHost: true)
        waitUntilConnected(app)
        tap("connection.address.change", in: app)
        let field = app.textFields["connection.address.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        replace(field, with: "http://127.0.0.1:65367/")
        XCTAssertTrue(waitForLabel(element("connection.address.preview", in: app), containing: "This is the address in use."))
        replace(field, with: "bad host!")
        XCTAssertTrue(element("connection.address.problem", in: app).waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["connection.address.save"].isEnabled)
        replace(field, with: "127.0.0.1")
        XCTAssertTrue(waitForLabel(element("connection.address.preview", in: app), containing: "Tessera will use 127.0.0.1:8788."))
        // Saving itself goes through the return key (saveAddress), so this
        // only asks that a good address makes Save available.
        XCTAssertTrue(app.buttons["connection.address.save"].isEnabled)
        // A name iPhone will not let plain HTTP reach is refused before saving.
        replace(field, with: "album-matrix.lan")
        XCTAssertTrue(waitForLabel(element("connection.address.problem", in: app), containing: "iPhone blocks plain connections"))
        XCTAssertFalse(app.buttons["connection.address.save"].isEnabled)
        dismissKeyboard(app)
        tap("connection.address.cancel", in: app)
        XCTAssertTrue(waitForLabel(element("connection.address.value", in: app), containing: "127.0.0.1:65367"))
    }

    @MainActor func testConnectionWrongAddressRecovers() async throws {
        let app = try await launch("addresses", extra: reset, seedHost: true)
        waitUntilConnected(app)
        saveAddress("127.0.0.1:9", in: app)
        // A new address where nothing listens is the preview on this phone,
        // with the reason, not offline since the old wall's last reply. The
        // port refused, so the headline says not ready, as the reason does.
        XCTAssertTrue(waitForLabel(headline(app), containing: "Wall not ready", timeout: 10))
        XCTAssertTrue(waitForLabel(element("connection.status", in: app), containing: "Showing a preview on this phone"))
        XCTAssertTrue(element("connection.reason", in: app).waitForExistence(timeout: 5))
        tap("connection.secondary", in: app)
        XCTAssertTrue(waitForLabel(element("connection.step.wall", in: app), containing: "Not running", timeout: 12))
        let recent = element("connection.recent", in: app)
        XCTAssertFalse(recent.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", "Wall stopped responding")).firstMatch.exists,
                       "A wall that never answered cannot have stopped")
        saveAddress("127.0.0.1:65367", in: app)
        waitUntilConnected(app, timeout: 8)
        reveal(recent, in: app)
        XCTAssertTrue(recent.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", "Address changed")).firstMatch.exists)
    }

    @MainActor func testConnectionGlowUsesIdentifySessionAndEnds() async throws {
        let app = try await launch("addresses", extra: reset)
        waitUntilConnected(app)
        tap("connection.glow", in: app)
        let active = try await waitForSession(active: true, purpose: "identify")
        let frame = active["frame"] as? [String: Any]
        XCTAssertEqual(frame?["uniform"] as? Bool, true)
        XCTAssertEqual(frame?["first_rgb"] as? [Int], [191, 191, 191])
        assertPreserved(active)
        // Five seconds, then the page (or the wall itself) ends it.
        let ended = try await waitForSession(active: false)
        assertPreserved(ended)
        XCTAssertTrue(waitForLabel(app.buttons["connection.glow"], containing: "Make it glow", timeout: 5))
    }

    /// Another phone's display session holds the wall: Make it glow is off
    /// and says why, sends nothing, and comes back when the session ends.
    @MainActor func testConnectionGlowWaitsWhileWallInUse() async throws {
        let app = try await launch("addresses", extra: reset)
        waitUntilConnected(app)
        _ = try await api("/qa/occupy", ["purpose": "panel"])
        let glow = app.buttons["connection.glow"]
        let notice = element("connection.glowProblem", in: app)
        XCTAssertTrue(waitForLabel(notice, containing: "The wall is in use", timeout: 10))
        XCTAssertTrue(waitForLabel(notice, containing: "A panel check is on the wall."))
        XCTAssertFalse(glow.isEnabled, "Make it glow stayed active while the wall was in use")
        let before = posts(try await status(), path: "/display-session").count
        _ = try await api("/display-session/end", ["token": "qa-occupied-by-another-phone"])
        XCTAssertTrue(notice.waitForNonExistence(timeout: 10), "The notice outlived the other session")
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: glow)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 5), .completed, "Make it glow did not come back")
        let after = posts(try await status(), path: "/display-session").count
        XCTAssertEqual(after, before, "A glow was sent while the wall was in use")
    }

    @MainActor func testConnectionPhoneOnlyStopsPollingAndReconnects() async throws {
        let app = try await launch("addresses", extra: reset)
        waitUntilConnected(app)
        tap("connection.phoneOnly", in: app)
        XCTAssertTrue(waitForLabel(headline(app), containing: "Using this phone", timeout: 8))
        // A read already in flight may still land.
        try await Task.sleep(for: .seconds(1.5))
        let before = try await status()
        try await Task.sleep(for: .seconds(5))
        let after = try await status()
        for path in ["/state", "/frame.raw"] {
            XCTAssertEqual((after["gets"] as? [String: Int])?[path], (before["gets"] as? [String: Int])?[path], path)
        }
        XCTAssertFalse(app.buttons["connection.phoneOnly"].exists)
        tap("connection.primary", in: app)
        waitUntilConnected(app, timeout: 10)
    }

    @MainActor func testConnectionLargeTypeKeepsActionOnFirstScreen() async throws {
        let app = try await launch("addresses", extra: reset + ["-UIPreferredContentSizeCategoryName",
                                                               "UICTContentSizeCategoryAccessibilityXXXL"])
        waitUntilConnected(app)
        _ = try await api("/qa/available", ["enabled": false, "as": "silent"])
        let primary = app.buttons["connection.primary"]
        XCTAssertTrue(waitForLabel(primary, containing: "Look for the wall again", timeout: 20))
        // Never scrolled: the way forward is on the first screen.
        XCTAssertTrue(primary.isHittable)
    }

    @MainActor func testConnectionDeniedCheckOffersSettings() async throws {
        // The simulator never denies Local Network access, so this runs the
        // scripted readings through the real page.
        let app = try await launch("addresses", extra: reset + ["-connection-check-fixture", "denied"])
        XCTAssertTrue(waitForLabel(element("connection.step.permission", in: app), containing: "Not allowed", timeout: 15))
        XCTAssertTrue(element("connection.openSettings", in: app).exists)
        XCTAssertTrue(waitForLabel(element("connection.step.wall", in: app), containing: "Not checked"))
        XCTAssertTrue(waitForLabel(element("connection.summary", in: app), containing: "Stopped at step 2."))
    }

    /// The capture hook shows the inline confirm for a seeded queue, and
    /// Keep puts the plain Discard back.
    @MainActor func testConnectionConfirmDiscardHookShowsConfirm() async throws {
        let app = try await launch("addresses", extra: reset + ["-connection-delivery", "partial", "-connection-confirm-discard"])
        waitUntilConnected(app)
        XCTAssertTrue(element("connection.confirmDiscard", in: app).waitForExistence(timeout: 15), "The confirm never showed")
        XCTAssertTrue(element("connection.keep", in: app).exists)
        XCTAssertFalse(element("connection.discard", in: app).exists)
        tap("connection.keep", in: app)
        XCTAssertTrue(element("connection.discard", in: app).waitForExistence(timeout: 5))
        XCTAssertTrue(element("connection.waiting.settings", in: app).exists, "Keep discarded the queue")
    }

    @MainActor func testConnectionCheckStopsWhereItWas() async throws {
        let app = try await launch("addresses", extra: reset + ["-connection-check-fixture", "running"])
        let permission = element("connection.step.permission", in: app)
        // The running row reads "Local network, Checking." and then what it
        // is doing, never "checking" twice.
        XCTAssertTrue(waitForLabel(permission, containing: "Checking", timeout: 15))
        XCTAssertTrue(waitForLabel(app.buttons["connection.secondary"], containing: "Stop"))
        tap("connection.secondary", in: app)
        XCTAssertTrue(waitForLabel(permission, containing: "Not checked"))
        XCTAssertTrue(waitForLabel(element("connection.summary", in: app), containing: "Check stopped before step 2."))
    }
}
