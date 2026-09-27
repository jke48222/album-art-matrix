import XCTest

final class GameInteractionTests: XCTestCase {
    let fixture = "http://127.0.0.1:65357"

    func api(_ path: String, _ body: [String: Any]? = nil) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: fixture + path)!)
        request.timeoutInterval = 8
        if let body {
            request.httpMethod = "POST"; request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, _) = try await URLSession.shared.data(for: request)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
    @MainActor func launch(_ name: String, phase: String = "playing", failArtwork: Bool = false) async throws -> XCUIApplication {
        _ = try await api("/qa/reset", ["name": name, "phase": phase])
        if failArtwork { _ = try await api("/qa/fail-artwork", [:]) }
        let app = XCUIApplication(bundleIdentifier: "com.jalenedusei.tessera")
        app.launchArguments = ["-nointro", "-onboarded", "YES", "-intro.sting.migrated", "YES", "-intro.style", "none", "-design", "room", "-wall.host", "127.0.0.1:65357", "-reporter.host", "", "-reporter.background", "NO", "-live.enabled", "NO", "-settings", "-settings-page", "games", "-game-page", name]
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 12))
        return app
    }
    func receivedMove() async throws -> [String: Any] {
        for _ in 0..<40 {
            let state = try await api("/qa/status")
            if let moves = state["qa_moves"] as? [[String: Any]], !moves.isEmpty { return state }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTFail("No move reached the production game")
        return [:]
    }
    @MainActor func testContextoRetainsRejectedDraftAndWinsOnRetry() async throws {
        let app = try await launch("contexto")
        let field = app.descendants(matching: .any).matching(identifier: "Your Contexto guess").firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10)); XCTAssertTrue(field.isHittable)
        field.tap(); field.typeText("guitar")
        _ = try await api("/qa/fail-next", [:])
        let enter = app.buttons.matching(identifier: "Enter").firstMatch
        XCTAssertTrue(enter.isHittable); enter.tap()
        let error = app.staticTexts["The wall refused this test move. Try again."]
        XCTAssertTrue(error.waitForExistence(timeout: 5))
        XCTAssertEqual(field.value as? String, "guitar")
        enter.tap()
        let state = try await receivedMove()
        XCTAssertEqual((state["game"] as? [String: Any])?["won"] as? Bool, true)
        XCTAssertTrue(app.staticTexts["Nicely played."].waitForExistence(timeout: 5))
    }
    @MainActor func testSlidingLegalTileSendsRealMove() async throws {
        let app = try await launch("sliding")
        let tiles = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Tile '"))
        XCTAssertTrue(tiles.firstMatch.waitForExistence(timeout: 10))
        let legal = try XCTUnwrap(tiles.allElementsBoundByIndex.first { $0.isEnabled && $0.isHittable })
        legal.tap()
        let state = try await receivedMove()
        XCTAssertEqual((state["game"] as? [String: Any])?["moves"] as? Int, 2)
    }
    @MainActor func testRevealInputIsReachableAndFindsArtwork() async throws {
        let app = try await launch("reveal")
        let field = app.descendants(matching: .any).matching(identifier: "Your guess").firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10)); XCTAssertTrue(field.isHittable)
        field.tap(); field.typeText("Prism Studies")
        let send = app.buttons["Send guess"]
        XCTAssertTrue(send.isHittable); send.tap()
        let state = try await receivedMove()
        XCTAssertEqual((state["game"] as? [String: Any])?["won"] as? Bool, true)
        XCTAssertTrue(app.staticTexts["You knew it."].waitForExistence(timeout: 5))
    }
    @MainActor func testReactionGreenTapRecordsTime() async throws {
        let app = try await launch("reaction", phase: "green")
        let target = app.buttons["Now. Tap the target"]
        XCTAssertTrue(target.waitForExistence(timeout: 10)); XCTAssertTrue(target.isHittable)
        target.tap()
        let state = try await receivedMove()
        let game = try XCTUnwrap(state["game"] as? [String: Any])
        XCTAssertEqual(game["last_ms"] as? Int, 100)
        XCTAssertEqual(game["last_kind"] as? String, "hit")
    }
    @MainActor func testReactionEarlyTapIsDistinctFromAHit() async throws {
        let app = try await launch("reaction", phase: "red")
        let target = app.buttons["Wait. Tapping now is an early start"]
        XCTAssertTrue(target.waitForExistence(timeout: 10)); target.tap()
        let state = try await receivedMove()
        XCTAssertEqual((state["game"] as? [String: Any])?["last_kind"] as? String, "false_start")
    }
    @MainActor func testWhistleBirdStartsAndSteersWithTouch() async throws {
        let app = try await launch("whistlebird", phase: "ready")
        let start = app.buttons["Start with touch"]
        XCTAssertTrue(start.waitForExistence(timeout: 10)); XCTAssertTrue(start.isHittable)
        start.tap()
        let climb = app.buttons["Climb"]
        XCTAssertTrue(climb.waitForExistence(timeout: 5)); XCTAssertTrue(climb.isHittable)
        climb.tap()
        for _ in 0..<30 {
            let state = try await api("/qa/status")
            if let moves = state["qa_moves"] as? [[String: Any]], moves.contains(where: { $0["y"] != nil }) {
                XCTAssertEqual((state["game"] as? [String: Any])?["phase"] as? String, "flying")
                XCTAssertLessThan(try XCTUnwrap((state["game"] as? [String: Any])?["target"] as? Double), 0.5)
                return
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTFail("Touch steering did not reach the flight")
    }

    @MainActor func testSlidingRecoversAfterRepeatedArtworkFailures() async throws {
        let app = try await launch("sliding", failArtwork: true)
        let tiles = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Tile '"))
        XCTAssertTrue(tiles.firstMatch.waitForExistence(timeout: 15))
        let legal = try XCTUnwrap(tiles.allElementsBoundByIndex.first { $0.isEnabled && $0.isHittable })
        legal.tap()
        let state = try await receivedMove()
        XCTAssertEqual((state["game"] as? [String: Any])?["moves"] as? Int, 2)
    }

}
