import XCTest

final class ConnectionsInteractionTests: XCTestCase {
    /// test_connections_arcade_ui.py passes its fixture port as
    /// TEST_RUNNER_TESSERA_QA_FIXTURE_PORT, which xcodebuild hands this runner
    /// as TESSERA_QA_FIXTURE_PORT, so suites can run side by side on their own
    /// ports. 65361 is the suite's own port, for a run started from Xcode.
    static let host = "127.0.0.1:" + (ProcessInfo.processInfo.environment["TESSERA_QA_FIXTURE_PORT"] ?? "65361")
    func api(_ path: String, _ body: [String: Any]? = nil) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: "http://" + Self.host + path)!)
        request.timeoutInterval = 8
        if let body { request.httpMethod = "POST"; request.setValue("application/json", forHTTPHeaderField: "Content-Type"); request.httpBody = try JSONSerialization.data(withJSONObject: body) }
        let (data, _) = try await URLSession.shared.data(for: request)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
    @MainActor func launch(_ name: String, phase: String = "ready", apple: String? = nil) async throws -> XCUIApplication {
        _ = try await api("/qa/reset", ["name": name, "phase": phase])
        let app = XCUIApplication(bundleIdentifier: "com.jalenedusei.tessera")
        app.launchArguments = ["-nointro", "-onboarded", "YES", "-intro.sting.migrated", "YES", "-intro.style", "none", "-design", "room", "-wall.host", Self.host, "-reporter.host", "", "-reporter.background", "NO", "-live.enabled", "NO", "-settings", "-settings-page"]
        if ["snake","tetris"].contains(name) { app.launchArguments += ["games", "-game-page", name] }
        else { app.launchArguments += ["services"]; if name != "services" { app.launchArguments += ["-service-page", name] } }
        if let apple { app.launchEnvironment["TESSERA_QA_APPLE_MUSIC"] = apple }
        app.launch(); XCTAssertTrue(app.wait(for: .runningForeground, timeout: 12)); return app
    }
    func phase(_ expected: String) async throws {
        for _ in 0..<70 {
            let s = try await api("/qa/status")
            if (s["game"] as? [String: Any])?["phase"] as? String == expected { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTFail("Game never entered \(expected)")
    }
    @MainActor func tap(_ label: String, in app: XCUIApplication) {
        let button = app.buttons[label]
        XCTAssertTrue(button.waitForExistence(timeout: 10), label)
        for _ in 0..<3 { if button.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(button.isHittable, label); button.tap()
    }
    @MainActor func testSnakeStartsTurnsPausesAndResumes() async throws {
        let app = try await launch("snake")
        tap("Start Snake", in: app); try await phase("playing")
        tap("Turn up", in: app); tap("Turn left", in: app)
        tap("Pause Snake", in: app); try await phase("paused")
        let s = try await api("/qa/status"); let moves = s["qa_moves"] as? [[String: Any]] ?? []
        XCTAssertTrue(moves.contains { $0["dir"] as? String == "up" })
        XCTAssertTrue(moves.contains { $0["dir"] as? String == "left" })
        tap("Resume Snake", in: app); try await phase("playing")
    }
    @MainActor func testTetrisStartsRotatesDropsAndPauses() async throws {
        let app = try await launch("tetris")
        tap("Start Tetris", in: app); try await phase("playing")
        tap("Rotate piece", in: app); tap("Hard drop", in: app)
        tap("Pause Tetris", in: app); try await phase("paused")
        let s = try await api("/qa/status"); let game = s["game"] as? [String: Any] ?? [:]
        XCTAssertGreaterThan(game["pieces_placed"] as? Int ?? 0, 0)
    }
    @MainActor func testLeavingArcadePausesTheRound() async throws {
        _ = try await launch("snake", phase: "playing")
        XCUIDevice.shared.press(.home)
        try await phase("paused")
    }
    @MainActor func testOverviewOpensOneSpotifyDestination() async throws {
        let app = try await launch("services", phase: "connected")
        let link = app.buttons["services.spotify"]
        XCTAssertTrue(link.waitForExistence(timeout: 10)); link.tap()
        XCTAssertTrue(app.navigationBars["Spotify"].waitForExistence(timeout: 8))
    }
    @MainActor func testAppleDeniedExplainsRecovery() async throws {
        let app = try await launch("appleMusic", apple: "denied")
        XCTAssertTrue(app.staticTexts["Permission not granted"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["Open Settings"].exists)
        XCTAssertFalse(app.buttons["Open Settings"].isEnabled)
    }
    @MainActor func testApplePausedStateDoesNotClaimPlaying() async throws {
        let app = try await launch("appleMusic", apple: "paused")
        XCTAssertTrue(app.staticTexts["Prism Studies"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] 'Paused'")).firstMatch.exists)
    }
    @MainActor func testSpotifyRetriesAnOutageInline() async throws {
        let app = try await launch("spotify", phase: "unavailable")
        tap("Check connection again", in: app)
        XCTAssertTrue(app.staticTexts["Connected to this wall"].waitForExistence(timeout: 10))
    }

}
