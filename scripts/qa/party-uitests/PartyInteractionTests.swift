import XCTest

final class PartyInteractionTests: XCTestCase {
    let fixture = "http://127.0.0.1:65359"
    func api(_ path: String, _ body: [String: Any]? = nil) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: fixture + path)!)
        request.timeoutInterval = 8
        if let body { request.httpMethod = "POST"; request.setValue("application/json", forHTTPHeaderField: "Content-Type"); request.httpBody = try JSONSerialization.data(withJSONObject: body) }
        let (data, _) = try await URLSession.shared.data(for: request)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
    @MainActor func launch(_ name: String, phase: String = "playing") async throws -> XCUIApplication {
        _ = try await api("/qa/reset", ["name": name, "phase": phase])
        let app = XCUIApplication(bundleIdentifier: "com.jalenedusei.tessera")
        app.launchArguments = ["-nointro", "-onboarded", "YES", "-intro.sting.migrated", "YES", "-intro.style", "none", "-design", "room", "-wall.host", "127.0.0.1:65359", "-reporter.host", "", "-reporter.background", "NO", "-live.enabled", "NO", "-settings", "-settings-page", "games", "-game-page", name]
        app.launch(); XCTAssertTrue(app.wait(for: .runningForeground, timeout: 12)); return app
    }
    func received(_ key: String) async throws -> [String: Any] {
        for _ in 0..<60 {
            let state = try await api("/qa/status")
            if let moves = state["qa_moves"] as? [[String: Any]], moves.contains(where: { $0[key] != nil }) { return state }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTFail("No \(key) move reached the production game"); return [:]
    }
    @MainActor func testHeardleKeepsRejectedDraftAndRevealsTrack() async throws {
        let app = try await launch("heardle")
        let field = app.descendants(matching: .any).matching(identifier: "Song title").firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10)); XCTAssertTrue(field.isHittable)
        field.tap(); field.typeText("Prism Studies")
        _ = try await api("/qa/fail-next", [:])
        let send = app.buttons["Send guess"]; XCTAssertTrue(send.isHittable); send.tap()
        XCTAssertTrue(app.staticTexts["The wall refused this test move. Try again."].waitForExistence(timeout: 5))
        XCTAssertEqual(field.value as? String, "Prism Studies"); send.tap()
        let state = try await received("guess")
        XCTAssertEqual((state["game"] as? [String: Any])?["won"] as? Bool, true)
    }
    @MainActor func testHeardleClipStopsAtItsAudioBoundary() async throws {
        let app = try await launch("heardle", phase: "ready")
        let play = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Play 1 second'")).firstMatch
        XCTAssertTrue(play.waitForExistence(timeout: 10)); XCTAssertTrue(play.isHittable); play.tap()
        _ = try await received("played")
        for _ in 0..<80 {
            let state = try await api("/qa/status")
            let moves = state["qa_moves"] as? [[String: Any]] ?? []
            if moves.contains(where: { $0["played"] as? Bool == false }) {
                XCTAssertTrue(moves.contains(where: { $0["played"] as? Bool == true }))
                XCTAssertEqual((state["game"] as? [String: Any])?["playing"] as? Bool, false)
                return
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTFail("Clip did not report its bounded stop. " + app.debugDescription)
    }
    @MainActor func testTwentyQuestionsSendsTheVisibleQuestionToken() async throws {
        let app = try await launch("twentyq")
        let before = try await api("/qa/status")
        let token = (before["game"] as? [String: Any])?["question_id"] as? String
        let yes = app.buttons["Answer yes"]; XCTAssertTrue(yes.waitForExistence(timeout: 10)); XCTAssertTrue(yes.isHittable); yes.tap()
        let state = try await received("answer")
        let move = (state["qa_moves"] as? [[String: Any]])?.first
        XCTAssertEqual(move?["question_id"] as? String, token)
        XCTAssertEqual(((state["game"] as? [String: Any])?["history"] as? [[String: Any]])?.count, 3)
    }
    @MainActor func testPubQuizAnswerIsReachableAndScoresOnce() async throws {
        let app = try await launch("quiz")
        let field = app.descendants(matching: .any).matching(identifier: "Your quiz answer").firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10)); XCTAssertTrue(field.isHittable); field.tap(); field.typeText("33")
        let send = app.buttons["Submit answer"]; XCTAssertTrue(send.isHittable); send.tap()
        let state = try await received("answer")
        let game = try XCTUnwrap(state["game"] as? [String: Any])
        XCTAssertEqual(game["phase"] as? String, "answer")
        XCTAssertEqual((game["scores"] as? [String: Int])?["You"], 1)
    }
    @MainActor func testPictionaryGuessRevealsDrawing() async throws {
        let app = try await launch("pictionary")
        let field = app.descendants(matching: .any).matching(identifier: "Your Pictionary guess").firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10)); XCTAssertTrue(field.isHittable); field.tap(); field.typeText("lighthouse")
        let enter = app.buttons["Enter"]; XCTAssertTrue(enter.isHittable); enter.tap()
        let state = try await received("guess")
        XCTAssertEqual((state["game"] as? [String: Any])?["won"] as? Bool, true)
    }
    @MainActor func testPongServesSteersAndPauses() async throws {
        let app = try await launch("pong", phase: "ready")
        let serve = app.buttons["Serve"]; XCTAssertTrue(serve.waitForExistence(timeout: 10)); XCTAssertTrue(serve.isHittable); serve.tap()
        _ = try await received("serve")
        let up = app.buttons["Paddle up"]; XCTAssertTrue(up.waitForExistence(timeout: 5)); XCTAssertTrue(up.isHittable); up.tap()
        let steered = try await received("paddle")
        XCTAssertLessThan(try XCTUnwrap(((steered["game"] as? [String: Any])?["paddles"] as? [Double])?.first), 0.5)
        let pause = app.buttons["Pause rally"]
        if !pause.isHittable { app.swipeUp() }
        XCTAssertTrue(pause.isHittable); pause.tap()
        let stopped = try await received("pause")
        XCTAssertEqual((stopped["game"] as? [String: Any])?["phase"] as? String, "paused")
    }
    @MainActor func testTwentyQuestionsRetriesWithoutLosingTheRound() async throws {
        let app = try await launch("twentyq", phase: "error")
        let retry = app.buttons["Try next question again"]
        XCTAssertTrue(retry.waitForExistence(timeout: 10)); retry.tap()
        _ = try await received("retry")
        XCTAssertTrue(app.buttons["Answer yes"].waitForExistence(timeout: 8))
        let state = try await api("/qa/status")
        XCTAssertEqual((state["game"] as? [String: Any])?["phase"] as? String, "question")
        XCTAssertEqual((state["game"] as? [String: Any])?["over"] as? Bool, false)
    }
    @MainActor func testPictionaryRetriesItsDrawingInline() async throws {
        let app = try await launch("pictionary", phase: "error")
        let retry = app.buttons["Try drawing again"]
        XCTAssertTrue(retry.waitForExistence(timeout: 10)); retry.tap()
        _ = try await received("retry")
        let field = app.descendants(matching: .any).matching(identifier: "Your Pictionary guess").firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 8))
        let state = try await api("/qa/status")
        XCTAssertEqual((state["game"] as? [String: Any])?["picture_ready"] as? Bool, true)
        XCTAssertEqual((state["game"] as? [String: Any])?["over"] as? Bool, false)
    }

    @MainActor func testPongDuplicateServeDoesNotBlockSubsequentControls() async throws {
        let app = try await launch("pong", phase: "ready")
        let serve = app.buttons["Serve"]
        XCTAssertTrue(serve.waitForExistence(timeout: 10))
        _ = try await api("/qa/delay-next", [:])
        serve.doubleTap()
        _ = try await received("serve")
        let up = app.buttons["Paddle up"]
        XCTAssertTrue(up.waitForExistence(timeout: 5)); up.tap()
        let state = try await received("paddle")
        let moves = state["qa_moves"] as? [[String: Any]] ?? []
        XCTAssertEqual(moves.filter { $0["serve"] as? Bool == true }.count, 1)
        XCTAssertLessThan(try XCTUnwrap(((state["game"] as? [String: Any])?["paddles"] as? [Double])?.first), 0.5)
    }

}
