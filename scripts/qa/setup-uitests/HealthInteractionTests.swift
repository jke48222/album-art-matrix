import XCTest

/// Wall health (D06) against scripts/qa/serve_setup.py, which answers GET
/// /health with the authored presets in scripts/qa/health_fixtures.json.
/// launch() resets the fixture first, so a preset is set in `before`.
/// Run with --only-testing SetupInteractionTests/HealthInteractionTests
/// --output qa/batch-17/health-interactions.json.
final class HealthInteractionTests: SetupHarnessCase {
    private func preset(_ name: String) -> [(String, [String: Any])] { [("/qa/health", ["preset": name])] }

    private func healthReads() async throws -> Int { try await status()["health_reads"] as? Int ?? 0 }

    @MainActor private func verdict(_ app: XCUIApplication) -> XCUIElement { element("health.verdict", in: app) }

    /// Waits for the headline to read exactly `text`.
    @MainActor private func expectVerdict(_ app: XCUIApplication, _ text: String, timeout: TimeInterval = 10,
                                          file: StaticString = #filePath, line: UInt = #line) {
        let headline = verdict(app)
        XCTAssertTrue(headline.waitForExistence(timeout: timeout), "No health.verdict", file: file, line: line)
        let exact = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", text), object: headline)
        XCTAssertEqual(XCTWaiter.wait(for: [exact], timeout: timeout), .completed,
                       "Verdict was \(headline.label), not \(text)", file: file, line: line)
    }

    @MainActor private func expectGone(_ element: XCUIElement, timeout: TimeInterval = 4, file: StaticString = #filePath, line: UInt = #line) {
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [gone], timeout: timeout), .completed, "\(element) is still there", file: file, line: line)
    }

    @MainActor func testHealthSteadyReadsWall() async throws {
        let app = try await launch("health", before: preset("steady"))
        expectVerdict(app, "Running well.")
        XCTAssertTrue(element("health.tile.temperature", in: app).exists)
        XCTAssertTrue(element("health.tile.frames", in: app).exists)
        reveal(app.buttons["health.row.power"], in: app)
        let problems = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'health.problem'"))
        XCTAssertEqual(problems.count, 0)
    }

    @MainActor func testHealthProblemComesFirstWithOthersCollapsed() async throws {
        let app = try await launch("health", before: preset("undervolt"))
        expectVerdict(app, "Low on power.")
        let problem = element("health.problem.power", in: app)
        let temperature = element("health.tile.temperature", in: app)
        XCTAssertTrue(problem.waitForExistence(timeout: 8))
        XCTAssertTrue(temperature.exists)
        XCTAssertLessThan(problem.frame.minY, temperature.frame.minY)
        let others = app.buttons["health.others"]
        reveal(others, in: app)
        XCTAssertFalse(element("health.row.memory", in: app).exists)
        others.tap()
        XCTAssertTrue(element("health.row.memory", in: app).waitForExistence(timeout: 4))
        // A problem is not repeated among the checks that passed.
        XCTAssertFalse(element("health.row.power", in: app).exists)
    }

    @MainActor func testHealthRowExplains() async throws {
        let app = try await launch("health", before: preset("steady"))
        expectVerdict(app, "Running well.")
        tap("health.row.power", in: app)
        let explanation = element("health.explain.power", in: app)
        XCTAssertTrue(explanation.waitForExistence(timeout: 4))
        XCTAssertTrue(explanation.label.contains("It does not measure the panels"), explanation.label)
        tap("health.row.power", in: app)
        expectGone(explanation)
    }

    @MainActor func testHealthCheckNowPicksUpChange() async throws {
        let app = try await launch("health", before: preset("steady"))
        expectVerdict(app, "Running well.")
        let before = try await healthReads()
        _ = try await api("/qa/health", ["preset": "hot"])
        tap("health.check", in: app)
        expectVerdict(app, "Running hot.", timeout: 8)
        let after = try await healthReads()
        XCTAssertGreaterThan(after, before)
    }

    @MainActor func testHealthFailureKeepsLastReading() async throws {
        let app = try await launch("health", before: preset("steady"))
        expectVerdict(app, "Running well.")
        _ = try await api("/qa/health", ["preset": "fail"])
        tap("health.check", in: app)
        expectVerdict(app, "No new reading.", timeout: 8)
        XCTAssertTrue(waitForLabel(element("health.freshness", in: app), containing: "Last reading"))
        XCTAssertTrue(element("health.tile.temperature", in: app).exists)
    }

    /// One failed background poll is a hiccup: the verdict stays and only
    /// the freshness line says the check did not answer.
    @MainActor func testHealthOneFailedPollKeepsVerdict() async throws {
        let app = try await launch("health", before: preset("steady"))
        expectVerdict(app, "Running well.")
        let before = try await healthReads()
        _ = try await api("/qa/health", ["preset": "fail"])
        var reads = before
        for _ in 0..<32 where reads == before {
            try await Task.sleep(for: .milliseconds(500))
            reads = try await healthReads()
        }
        XCTAssertGreaterThan(reads, before, "No background poll within 16 s")
        XCTAssertTrue(waitForLabel(element("health.freshness", in: app), containing: "Could not check"))
        XCTAssertEqual(verdict(app).label, "Running well.")
    }

    /// The wall stops answering while the page is open: the last reading
    /// stays, dimmed, with the way back.
    @MainActor func testHealthOfflineOffersLookAgain() async throws {
        let app = try await launch("health", before: preset("steady"))
        expectVerdict(app, "Running well.")
        _ = try await api("/qa/available", ["enabled": false, "as": "http"])
        expectVerdict(app, "Can’t reach the wall.", timeout: 15)
        let look = app.buttons["health.lookAgain"]
        XCTAssertTrue(look.exists)
        XCTAssertTrue(look.isEnabled)
        XCTAssertTrue(element("health.address", in: app).exists)
        XCTAssertTrue(waitForLabel(element("health.freshness", in: app), containing: "Last reading"))
        XCTAssertTrue(element("health.tile.temperature", in: app).exists)
    }

    /// Every launch starts on the phone and looks for the wall in the
    /// background, so while nothing answers the page offers no look of its own.
    @MainActor func testHealthAutomaticStandInOffersNothing() async throws {
        let app = try await launch("health", phase: "offline")
        expectVerdict(app, "No wall connected.")
        XCTAssertFalse(app.buttons["health.lookAgain"].exists)
        XCTAssertFalse(element("health.tile.temperature", in: app).exists)
    }

    /// Reading is all the page does. Phone music pushes (/nowplaying,
    /// /pressing) and the launch's developer-key seeding (/services) belong
    /// to the session, not to this page, and only writes made while the page
    /// polls are counted.
    @MainActor func testHealthSendsNothingToWall() async throws {
        let app = try await launch("health", before: preset("steady"))
        expectVerdict(app, "Running well.")
        let session = ["/nowplaying", "/pressing", "/services"]
        let start = try await status()
        let before = start["health_reads"] as? Int ?? 0, earlier = posts(start).count
        try await Task.sleep(for: .seconds(25))
        let snapshot = try await status()
        let writes = posts(snapshot).dropFirst(earlier).filter { !session.contains($0["path"] as? String ?? "") }
        XCTAssertTrue(writes.isEmpty, "\(writes)")
        XCTAssertTrue(posts(start).allSatisfy { session.contains($0["path"] as? String ?? "") }, "\(posts(start))")
        XCTAssertGreaterThanOrEqual((snapshot["health_reads"] as? Int ?? 0) - before, 2)
    }

    @MainActor func testHealthRestartsThePanelProgram() async throws {
        let app = try await launch("health", before: preset("panels-off"))
        expectVerdict(app, "Panels not updating.")
        XCTAssertTrue(element("health.problem.panels", in: app).exists)
        tap("health.restartPanels", in: app)
        // The panel program is back: the wall reads steady from here.
        _ = try await api("/qa/health", ["preset": "steady"])
        expectVerdict(app, "Running well.", timeout: 12)
        let snapshot = try await status()
        XCTAssertEqual(posts(snapshot, path: "/tuning/restart").count, 1)
        XCTAssertEqual((snapshot["tuning"] as? [String: Any])?["restarts"] as? Int, 1)
    }

    @MainActor func testHealthRestartThatDoesNotHelpKeepsPlugAdvice() async throws {
        let app = try await launch("health", before: preset("panels-off"))
        expectVerdict(app, "Panels not updating.")
        tap("health.restartPanels", in: app)
        let note = element("health.restartNote", in: app)
        XCTAssertTrue(note.waitForExistence(timeout: 12))
        XCTAssertTrue(note.label.contains("have not picked up yet"), note.label)
        XCTAssertTrue(element("health.problem.panels", in: app).label.contains("at the plug"))
    }

    @MainActor func testSettingsRowUsesHealthVerdict() async throws {
        let app = try await launch(nil, before: preset("hot"))
        let row = app.buttons["settings.route.health"]
        reveal(row, in: app)
        XCTAssertTrue(waitForLabel(row, containing: "Running hot, 82°C", timeout: 12), row.label)
    }

    /// Slow: at most one read may land while the app is in the background.
    @MainActor func testHealthPollingPausesInBackground() async throws {
        let app = try await launch("health", before: preset("steady"))
        expectVerdict(app, "Running well.")
        let before = try await healthReads()
        XCUIDevice.shared.press(.home)
        try await Task.sleep(for: .seconds(25))
        let during = try await healthReads()
        app.activate()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 8))
        XCTAssertLessThanOrEqual(during - before, 1)
    }

    @MainActor func testHealthAccessibilitySize() async throws {
        let app = try await launch("health", extra: ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"],
                                   before: preset("several"))
        expectVerdict(app, "Needs attention.")
        XCTAssertTrue(element("health.problem.power", in: app).waitForExistence(timeout: 8))
        let check = app.buttons["health.check"]
        reveal(check, in: app)
        // The page's ScrollView is not lazy, so the button exists from the
        // start and reveal() stops at once. At AX sizes the hero can push it
        // below the fold, so scroll in steps of a quarter screen, well under
        // the visible height, until it can be tapped. A slow drag held at
        // the end leaves no momentum to carry it past the top.
        for _ in 0..<8 where !check.isHittable {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7))
                .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45)),
                       withVelocity: .slow, thenHoldForDuration: 0.1)
        }
        XCTAssertTrue(check.isHittable)
    }
}
