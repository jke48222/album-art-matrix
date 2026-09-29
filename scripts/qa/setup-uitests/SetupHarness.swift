import XCTest

/// What every native interaction test against scripts/qa/serve_setup.py
/// shares: the fixture's API, launching the installed app at a page, and the
/// small waits and taps the pages need. Every file in this folder builds into
/// one bundle, so each unit's tests subclass this rather than
/// SetupInteractionTests, whose own tests would otherwise run again under
/// every subclass. This class has no tests, so XCTest runs none for it.
class SetupHarnessCase: XCTestCase {
    /// The fixture's address. test_setup_ui.py and test_widgets_ui.py set
    /// TEST_RUNNER_TESSERA_QA_FIXTURE_PORT, which xcodebuild hands this runner
    /// as TESSERA_QA_FIXTURE_PORT, so the two suites (or two shards of one)
    /// can run side by side on their own ports. 65367 is the setup suite's
    /// own port, for a run started from Xcode without the script.
    static let fixture = "127.0.0.1:" + (ProcessInfo.processInfo.environment["TESSERA_QA_FIXTURE_PORT"] ?? "65367")

    /// A fixture call that must answer 200. GET without a body, POST with one.
    func api(_ path: String, _ body: [String: Any]? = nil) async throws -> [String: Any] {
        let (status, json) = try await fetch(path, body)
        XCTAssertEqual(status, 200, path)
        return json
    }

    /// The same call, with whatever status it answers, for routes a test
    /// expects to fail (a 409, a 500 health preset). A body that is not a JSON
    /// object comes back empty.
    func fetch(_ path: String, _ body: [String: Any]? = nil) async throws -> (Int, [String: Any]) {
        var request = URLRequest(url: URL(string: "http://\(Self.fixture)" + path)!)
        request.timeoutInterval = 8
        if let body {
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, json)
    }

    /// GET /qa/status: state, session, requests, gets, health_reads, tuning.
    func status() async throws -> [String: Any] {
        try await api("/qa/status")
    }

    /// The wall writes the fixture recorded, optionally only one path and
    /// only those the wall actually took (served), not ones sent while away.
    func posts(_ snapshot: [String: Any], path: String? = nil, servedOnly: Bool = false) -> [[String: Any]] {
        (snapshot["requests"] as? [[String: Any]] ?? []).filter {
            (path == nil || $0["path"] as? String == path) && (!servedOnly || $0["served"] as? Bool == true)
        }
    }

    /// Launch arguments every test starts from. The wall host and the design
    /// and opening are pinned here unless a test asks otherwise, because an
    /// argument outranks anything the app writes to UserDefaults in session.
    private func base(seedHost: Bool, pins: [String], nointro: Bool) -> [String] {
        var arguments = nointro ? ["-nointro"] : []
        arguments += ["-onboarded", "YES", "-intro.sting.migrated", "YES"]
        arguments += pins
        // -seed-wall-host writes the address into UserDefaults before the
        // session starts, so a test can change it from the page. -wall.host
        // would keep answering the launch value.
        arguments += seedHost ? ["-seed-wall-host", Self.fixture] : ["-wall.host", Self.fixture]
        // Every launch starts with an empty queue and no link history, so a
        // queue one test seeded is never delivered in the next one.
        arguments += ["-reporter.host", "", "-reporter.background", "NO", "-live.enabled", "NO", "-guests-reset", "-connection-reset"]
        return arguments
    }

    private func route(_ page: String?) -> [String] {
        switch page {
        case nil: return ["-settings"]
        case "home": return []
        case "onboarding": return ["-onboarding-step", "welcome"]
        case "pictures": return ["-settings", "-settings-page", "services", "-service-page", "pictures"]
        case let page?: return ["-settings", "-settings-page", page]
        }
    }

    /// Reset the fixture to phase, make the calls in before (for example
    /// ("/qa/health", ["preset": "hot"])), then launch the app at page.
    /// page nil opens the Settings landing, "home" the app with no sheet,
    /// anything else that Settings page. extra is appended last, so page hooks
    /// such as -health-fixture or -about-page tuning go there.
    @MainActor func launch(_ page: String?, phase: String = "connected", fixture: String? = nil,
                           extra: [String] = [], before: [(String, [String: Any])] = [],
                           seedHost: Bool = false) async throws -> XCUIApplication {
        try await start(page, phase: phase, fixture: fixture, extra: extra, before: before,
                        seedHost: seedHost, pins: ["-intro.style", "none", "-design", "room"], nointro: true)
    }

    /// The same launch without -intro.style, and without -design unless one
    /// is given, for tests that change either in session and then relaunch.
    /// nointro false plays the opening, for tests that watch it.
    @MainActor func launchUnpinned(page: String?, design: String? = nil, phase: String = "connected",
                                   extra: [String] = [], before: [(String, [String: Any])] = [],
                                   nointro: Bool = true) async throws -> XCUIApplication {
        try await start(page, phase: phase, fixture: nil, extra: extra, before: before, seedHost: false,
                        pins: design.map { ["-design", $0] } ?? [], nointro: nointro)
    }

    @MainActor private func start(_ page: String?, phase: String, fixture: String?, extra: [String],
                                  before: [(String, [String: Any])], seedHost: Bool, pins: [String],
                                  nointro: Bool) async throws -> XCUIApplication {
        _ = try await api("/qa/reset", ["phase": phase])
        for (path, body) in before { _ = try await api(path, body) }
        let app = XCUIApplication(bundleIdentifier: "com.jalenedusei.tessera")
        app.launchArguments = base(seedHost: seedHost, pins: pins, nointro: nointro) + route(page)
        if let fixture { app.launchArguments += ["-guests-fixture", fixture] }
        app.launchArguments += extra
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 12))
        if page == "onboarding" {
            XCTAssertTrue(app.buttons["onboarding.usePhone"].waitForExistence(timeout: 12))
        } else if page != "home" {
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

    /// Waits for an element's label to contain text. False on timeout.
    @MainActor func waitForLabel(_ element: XCUIElement, containing text: String, timeout: TimeInterval = 8) -> Bool {
        let predicate = NSPredicate(format: "label CONTAINS %@", text)
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    @MainActor func dismissKeyboard(_ app: XCUIApplication) {
        if app.toolbars.buttons["Done"].exists { app.toolbars.buttons["Done"].tap() }
        else if app.keyboards.buttons["Done"].exists { app.keyboards.buttons["Done"].tap() }
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
}
