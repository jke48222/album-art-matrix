import XCTest

final class ConnectionsInteractionTests: XCTestCase {
    func api(_ path: String, _ body: [String: Any]? = nil) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:65363" + path)!)
        request.timeoutInterval = 8
        if let body {
            request.httpMethod = "POST"; request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, _) = try await URLSession.shared.data(for: request)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
    @MainActor func launch(_ page: String, phase: String = "connected") async throws -> XCUIApplication {
        _ = try await api("/qa/reset", ["phase": phase])
        let app = XCUIApplication(bundleIdentifier: "com.jalenedusei.tessera")
        app.launchArguments = ["-nointro", "-onboarded", "YES", "-intro.sting.migrated", "YES", "-intro.style", "none", "-design", "room", "-wall.host", "127.0.0.1:65363", "-reporter.host", "", "-reporter.background", "NO", "-live.enabled", "NO", "-settings", "-settings-page", "services", "-service-page", page]
        app.launch(); XCTAssertTrue(app.wait(for: .runningForeground, timeout: 12))
        XCTAssertTrue(app.navigationBars.firstMatch.waitForExistence(timeout: 12))
        return app
    }
    @MainActor func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<8 {
            if element.exists {
                // UIKit scrolls a known element into view on tap. Avoid sending
                // repeated swipes past a field while the keyboard is dismissing.
                return
            }
            app.swipeUp()
        }
        XCTAssertTrue(element.exists, element.debugDescription)
    }
    @MainActor func tap(_ id: String, in app: XCUIApplication) {
        let element = app.buttons[id]
        _ = element.waitForExistence(timeout: 8)
        reveal(element, in: app); element.tap()
    }
    func service(_ name: String) async throws -> [String: Any] {
        let response = try await api("/qa/status")
        return ((response["services"] as? [String: Any])?[name] as? [String: Any]) ?? [:]
    }
    @MainActor func testLastfmDisconnectStaysDisconnected() async throws {
        let app = try await launch("lastfm")
        tap("lastfm.disconnect", in: app)
        tap("lastfm.keepConnected", in: app)
        var account = try await service("lastfm"); XCTAssertEqual(account["user"] as? String, "tessera_studies")
        tap("lastfm.disconnect", in: app); tap("lastfm.confirmDisconnect", in: app)
        XCTAssertTrue(app.staticTexts["This wall has stopped following your Last.fm profile."].waitForExistence(timeout: 8))
        account = try await service("lastfm"); XCTAssertEqual(account["user"] as? String, "")
        XCTAssertEqual(account["key_set"] as? Bool, true)
        XCUIDevice.shared.press(.home); app.activate()
        try await Task.sleep(for: .seconds(2))
        account = try await service("lastfm"); XCTAssertEqual(account["user"] as? String, "")
    }
    @MainActor func testLastfmKeyIsSecureAndSaveCanRecover() async throws {
        let app = try await launch("lastfm", phase: "unlinked")
        let username = app.textFields["lastfm.username"]
        XCTAssertTrue(username.waitForExistence(timeout: 10)); reveal(username, in: app); username.tap(); username.typeText("test-listener")
        let key = app.secureTextFields["lastfm.apiKey"]
        reveal(key, in: app); key.tap(); key.typeText("1234567890abcdef1234567890abcdef")
        app.toolbars.buttons["Done"].firstMatch.exists ? app.toolbars.buttons["Done"].firstMatch.tap() : app.swipeUp()
        _ = try await api("/qa/reject", [:])
        tap("lastfm.save", in: app)
        XCTAssertTrue(app.staticTexts["lastfm.problem"].waitForExistence(timeout: 8))
        let account = try await service("lastfm"); XCTAssertEqual(account["key_set"] as? Bool, false)
        XCTAssertTrue(key.exists)
    }
    @MainActor func testListenBrainzWriterDisconnectKeepsReader() async throws {
        let app = try await launch("listenbrainz")
        tap("listenbrainz.unlinkWrite", in: app); tap("listenbrainz.confirmDisconnect", in: app)
        XCTAssertTrue(app.staticTexts["Writing disconnected."].waitForExistence(timeout: 8))
        let account = try await service("listenbrainz")
        XCTAssertEqual(account["token_set"] as? Bool, false)
        XCTAssertEqual(account["user"] as? String, "tessera_studies")
    }
    @MainActor func testListenBrainzPausedCountDoesNotAdvance() async throws {
        let app = try await launch("listenbrainz", phase: "paused")
        let meter = app.otherElements["listenbrainz.countedTime"]
        XCTAssertTrue(meter.waitForExistence(timeout: 10))
        let before = meter.label
        XCTAssertTrue(app.staticTexts["listenbrainz.countingState"].label.contains("paused"))
        try await Task.sleep(for: .seconds(3))
        XCTAssertEqual(meter.label, before)
    }
    @MainActor func testListenBrainzTokenIsSecureAndInvalidTokenCannotSave() async throws {
        let app = try await launch("listenbrainz", phase: "unlinked")
        tap("listenbrainz.writeSetup", in: app)
        let token = app.secureTextFields["listenbrainz.token"]
        reveal(token, in: app); token.tap(); token.typeText("not-a-token")
        XCTAssertFalse(app.buttons["listenbrainz.saveToken"].isEnabled)
        let account = try await service("listenbrainz")
        XCTAssertEqual(account["token_set"] as? Bool, false)
    }
    @MainActor func testOtherPlayerUsesCanonicalLastfmSetup() async throws {
        let app = try await launch("otherPlayers")
        tap("otherPlayers.deezer", in: app)
        tap("otherPlayers.setup", in: app)
        XCTAssertTrue(app.navigationBars["Last.fm"].waitForExistence(timeout: 8))
        XCTAssertFalse(app.sheets.firstMatch.exists)
    }
    @MainActor func testClaudeKeyRemovalIsExplicit() async throws {
        let app = try await launch("claude")
        tap("claude.manage", in: app)
        XCTAssertTrue(app.secureTextFields["claude.key"].waitForExistence(timeout: 8))
        tap("claude.remove", in: app); tap("claude.confirmRemove", in: app)
        XCTAssertTrue(app.staticTexts["API key removed from this wall"].waitForExistence(timeout: 8))
        let account = try await service("claude"); XCTAssertEqual(account["key_set"] as? Bool, false)
    }
    @MainActor func testDiscogsSyncWaitsForReceipt() async throws {
        let app = try await launch("discogs")
        tap("discogs.sync", in: app)
        XCTAssertTrue(app.staticTexts["Collection read by your wall"].waitForExistence(timeout: 12))
        let account = try await service("discogs"); XCTAssertEqual(account["completed_sync_id"] as? String, "qa-read")
    }
    @MainActor func testDiscogsDisconnectPreservesLocalCollection() async throws {
        let app = try await launch("discogs")
        tap("discogs.manage", in: app); tap("discogs.remove", in: app); tap("discogs.confirmRemove", in: app)
        XCTAssertTrue(app.staticTexts["Discogs disconnected. Your local collection is still here."].waitForExistence(timeout: 8))
        let account = try await service("discogs")
        XCTAssertEqual(account["token_set"] as? Bool, false); XCTAssertEqual(account["releases"] as? Int, 163)
    }
}
