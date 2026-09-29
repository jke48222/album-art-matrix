import XCTest

/// The Home Screen page (tessera/Tessera/WidgetsPage.swift) and the widget's
/// deep link, against scripts/qa/serve_setup.py. The launch, fixture and
/// wait helpers are SetupHarnessCase's (scripts/qa/setup-uitests/
/// SetupHarness.swift), which test_widgets_ui.py builds into this bundle.
///
/// -widget-snapshot pins a fixture into the app group's snapshot and freezes
/// it, and -widget-now pins the clock, so every preview reads the same on
/// every run. A launch without them releases the pin.
final class WidgetsPageTests: SetupHarnessCase {
    static let now = "1790000000"

    @MainActor private func pinned(_ fixture: String, installed: String = "both", extra: [String] = []) async throws -> XCUIApplication {
        try await launch("widgets", extra: ["-widget-snapshot", fixture, "-widget-now", Self.now,
                                            "-widget-installed", installed] + extra)
    }

    @MainActor private func value(_ id: String, in app: XCUIApplication) -> String {
        let e = element(id, in: app)
        XCTAssertTrue(e.waitForExistence(timeout: 8), id)
        return e.value as? String ?? ""
    }

    @MainActor func testSearchFindsHomeScreen() async throws {
        let app = try await launch(nil)
        let search = app.searchFields["settings.search"].exists ? app.searchFields["settings.search"]
            : element("settings.search", in: app)
        XCTAssertTrue(search.waitForExistence(timeout: 8))
        search.tap()
        search.typeText("widget")
        // A NavigationLink row is not always exposed as a button.
        let route = element("settings.route.widgets", in: app)
        XCTAssertTrue(route.waitForExistence(timeout: 8))
        route.tap()
        XCTAssertTrue(app.navigationBars["Home Screen"].waitForExistence(timeout: 8))
    }

    @MainActor func testCurrentPreview() async throws {
        let app = try await pinned("music")
        XCTAssertTrue(waitForLabel(element("widgets.status", in: app), containing: "On your Home Screen, small and medium"))
        let medium = value("widgets.preview.medium", in: app)
        XCTAssertTrue(medium.contains("Into the Quiet"), medium)
        XCTAssertTrue(medium.contains("On the wall"), medium)
        XCTAssertFalse(element("widgets.offline", in: app).exists)
    }

    @MainActor func testStalePreview() async throws {
        let app = try await pinned("stale")
        XCTAssertTrue(value("widgets.preview.medium", in: app).contains("As of"))
        XCTAssertTrue(value("widgets.preview.small", in: app).contains("As of"))
        let freshness = element("widgets.freshness", in: app)
        reveal(freshness, in: app)
        XCTAssertTrue(freshness.label.contains("from your wall"), freshness.label)
    }

    @MainActor func testPhonePreview() async throws {
        let app = try await pinned("preview")
        XCTAssertTrue(value("widgets.preview.small", in: app).contains("Phone preview"))
        XCTAssertTrue(value("widgets.preview.medium", in: app).contains("Phone preview"))
        let freshness = element("widgets.freshness", in: app)
        reveal(freshness, in: app)
        XCTAssertTrue(freshness.label.contains("from this phone"), freshness.label)
    }

    @MainActor func testMissing() async throws {
        let app = try await pinned("missing")
        let medium = value("widgets.preview.medium", in: app)
        XCTAssertTrue(medium.contains("Open Tessera"), medium)
        for label in ["Album art", "Lamp", "Off"] { XCTAssertFalse(medium.contains(label), label) }
        XCTAssertEqual(keys(in: app), 0)
        // The notice explains the Open Tessera the preview shows, and never
        // promises a phone preview that is not there.
        XCTAssertTrue(element("widgets.missing", in: app).waitForExistence(timeout: 8))
        XCTAssertFalse(element("widgets.standin", in: app).exists)
        let freshness = element("widgets.freshness", in: app)
        reveal(freshness, in: app)
        XCTAssertTrue(freshness.label.contains("Nothing saved yet"), freshness.label)
    }

    @MainActor func testUnreadable() async throws {
        let app = try await pinned("unreadable")
        XCTAssertTrue(value("widgets.preview.medium", in: app).contains("Open Tessera to refresh"))
        XCTAssertTrue(element("widgets.unreadable", in: app).waitForExistence(timeout: 8))
        XCTAssertFalse(element("widgets.standin", in: app).exists)
    }

    /// The frame's digits and the words beside them are one moment, and
    /// the status says when the timer ends, never dating the countdown.
    @MainActor func testTimerAgrees() async throws {
        let app = try await pinned("timer")
        let medium = value("widgets.preview.medium", in: app)
        XCTAssertTrue(medium.contains("4:42 left"), medium)
        XCTAssertTrue(medium.contains("Ends"), medium)
        XCTAssertFalse(medium.contains("As of"), medium)
    }

    /// A dark wall says when, not "On the wall", and the small widget's
    /// label is explained by the caption beside it.
    @MainActor func testDarkWallReadsNow() async throws {
        let app = try await pinned("off")
        let medium = value("widgets.preview.medium", in: app)
        XCTAssertTrue(medium.contains("Lights out"), medium)
        XCTAssertFalse(medium.contains("On the wall"), medium)
        XCTAssertTrue(value("widgets.preview.small", in: app).contains("Lights out"))
    }

    /// Away never says Off beside an unlit Off key.
    @MainActor func testAwayIsDarkNotOff() async throws {
        let app = try await pinned("away")
        let medium = value("widgets.preview.medium", in: app)
        XCTAssertTrue(medium.contains("Dark while you are away"), medium)
        XCTAssertFalse(medium.contains("Off while"), medium)
    }

    /// While a check runs, nothing claims Art is showing.
    @MainActor func testCheckRunning() async throws {
        let app = try await pinned("panel-check")
        let medium = value("widgets.preview.medium", in: app)
        XCTAssertTrue(medium.contains("Panel check"), medium)
        XCTAssertTrue(medium.contains("Check running"), medium)
    }

    /// One state, one name: the notice and the widget's status agree.
    @MainActor func testQueuedNoticeMatchesStatus() async throws {
        let app = try await pinned("queued")
        XCTAssertTrue(element("widgets.queued", in: app).waitForExistence(timeout: 8))
        let medium = value("widgets.preview.medium", in: app)
        XCTAssertTrue(medium.contains("Queued for the wall"), medium)
        // Both sizes date the dimmed picture the same way.
        XCTAssertTrue(medium.contains("As of"), medium)
        XCTAssertTrue(value("widgets.preview.small", in: app).contains("As of"))
        XCTAssertFalse(app.staticTexts["Waiting to send"].exists)
    }

    @MainActor private func keys(in app: XCUIApplication) -> Int {
        app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'widget.key.'")).count
    }

    /// The preview is a picture: its keys are labels, never buttons that
    /// could send a mode (interactive: false), and it takes no taps.
    @MainActor func testKeysAreInert() async throws {
        let app = try await pinned("stale")
        _ = value("widgets.preview.medium", in: app)
        XCTAssertEqual(keys(in: app), 0)
        try await Task.sleep(for: .seconds(1))
        let before = posts(try await status(), path: "/state").count
        element("widgets.preview.medium", in: app).tap()
        try await Task.sleep(for: .seconds(1))
        // Awaited first: XCTAssert's autoclosure cannot hold an async call.
        let after = posts(try await status(), path: "/state").count
        XCTAssertEqual(after, before, "a tap on the preview sent a change")
    }

    /// A guest code on the wall: the app's own session writes the snapshot
    /// through WallFacts, and the preview keeps reading as the face that was
    /// up before. The fixture seeds the clock face.
    @MainActor func testGuestCoverStaysPrivate() async throws {
        let app = try await launch("widgets", extra: ["-widget-installed", "both"])
        let freshness = element("widgets.freshness", in: app)
        XCTAssertTrue(waitForLabel(freshness, containing: "from your wall", timeout: 15), freshness.label)
        let before = value("widgets.preview.medium", in: app)
        XCTAssertTrue(before.hasPrefix("Clock"), before)
        let code = Data(repeating: 250, count: 64 * 64 * 3).base64EncodedString()
        _ = try await api("/display-session", ["token": "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee", "purpose": "guests",
                                               "seconds": 30, "px": code, "patch": [String: Any]()])
        _ = try await waitForSession(active: true, purpose: "guests")
        // Two polls, so the session has been read and written down.
        try await Task.sleep(for: .seconds(5))
        let during = value("widgets.preview.medium", in: app)
        XCTAssertTrue(during.hasPrefix("Clock"), during)
        XCTAssertFalse(during.contains("Your creation"), during)
        for id in ["widgets.preview.medium", "widgets.preview.small", "widgets.freshness"] {
            let e = element(id, in: app)
            let words = ((e.value as? String ?? "") + " " + e.label).lowercased()
            XCTAssertFalse(words.contains("guest"), id)
            XCTAssertFalse(words.contains("wi-fi"), id)
        }
    }

    @MainActor func testOfflineNotice() async throws {
        let app = try await launch("widgets", extra: ["-widget-installed", "both"])
        XCTAssertTrue(waitForLabel(element("widgets.freshness", in: app), containing: "from your wall", timeout: 15))
        _ = try await api("/qa/reset", ["phase": "offline"])
        XCTAssertTrue(element("widgets.offline", in: app).waitForExistence(timeout: 15))
    }

    @MainActor func testNotAdded() async throws {
        let app = try await pinned("music", installed: "none")
        XCTAssertTrue(waitForLabel(element("widgets.status", in: app), containing: "Not on your Home Screen yet"))
        let steps = element("widgets.steps", in: app)
        reveal(steps, in: app)
        XCTAssertTrue(steps.exists)
    }

    @MainActor func testDeepLinkSelectsWall() async throws {
        let app = try await launch("home", extra: ["-archive"])
        let wallPage = app.buttons["navigation.wall"]
        XCTAssertTrue(wallPage.waitForExistence(timeout: 8))
        XCTAssertFalse(wallPage.isSelected)
        app.open(URL(string: "tessera://wall")!)
        let selected = XCTNSPredicateExpectation(predicate: NSPredicate(format: "selected == true"), object: wallPage)
        XCTAssertEqual(XCTWaiter.wait(for: [selected], timeout: 8), .completed)
    }

    /// Best effort: whether opening the app's own link backgrounds it for a
    /// moment is the system's call, and the panel check ends on background.
    /// Asserted through the wall only.
    @MainActor func testDeepLinkKeepsRunningCheck() async throws {
        let app = try await launch("panel", extra: ["-panel-state", "running"])
        _ = try await waitForSession(active: true, purpose: "panel")
        app.open(URL(string: "tessera://wall")!)
        try await Task.sleep(for: .seconds(2))
        let snapshot = try await status()
        XCTAssertEqual((snapshot["session"] as? [String: Any])?["active"] as? Bool, true)
    }

    @MainActor func testAccessibilityLayout() async throws {
        let app = try await pinned("music", extra: ["-UIPreferredContentSizeCategoryName",
                                                    "UICTContentSizeCategoryAccessibilityXXXL"])
        XCTAssertFalse(element("widgets.headline", in: app).exists)
        let steps = element("widgets.steps", in: app)
        let preview = element("widgets.preview.medium", in: app)
        XCTAssertTrue(steps.waitForExistence(timeout: 8))
        XCTAssertTrue(preview.waitForExistence(timeout: 8))
        XCTAssertLessThan(steps.frame.minY, preview.frame.minY)
        XCTAssertTrue((preview.value as? String ?? "").contains("Into the Quiet"))
    }
}
