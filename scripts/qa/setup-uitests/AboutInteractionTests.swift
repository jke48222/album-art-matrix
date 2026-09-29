import XCTest

/// About and App design (D08), against scripts/qa/serve_setup.py. Neither page
/// writes to the wall, so most tests end by checking that nothing was sent.
/// Tests that change the design or the opening in session use launchUnpinned,
/// because -design and -intro.style on the launch line outrank the app's own
/// writes to UserDefaults.
final class AboutInteractionTests: SetupHarnessCase {
    /// What these pages could have written. The Room home re-sends its
    /// record's pressing by itself (POST /pressing), which is not theirs.
    func pageWrites(_ snapshot: [String: Any]) -> [[String: Any]] {
        posts(snapshot).filter { $0["path"] as? String != "/pressing" }
    }

    /// Waits for an element's accessibility value to contain text.
    @MainActor func waitForValue(_ element: XCUIElement, containing text: String, timeout: TimeInterval = 8) -> Bool {
        let predicate = NSPredicate(format: "value CONTAINS %@", text)
        return XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: element)], timeout: timeout) == .completed
    }

    /// Back to the Settings landing, then closed, so the home underneath is
    /// on screen.
    @MainActor func closeSettings(_ app: XCUIApplication) {
        let back = app.navigationBars.firstMatch.buttons.element(boundBy: 0)
        if back.exists { back.tap() }
        let close = app.buttons["Close settings"]
        XCTAssertTrue(close.waitForExistence(timeout: 8))
        close.tap()
        XCTAssertTrue(close.waitForNonExistence(timeout: 8))
    }

    // MARK: - About

    @MainActor func testAboutShowsVersionAndCopiesAddressWithoutWriting() async throws {
        let app = try await launch("about")
        let version = element("about.version", in: app)
        XCTAssertTrue(version.waitForExistence(timeout: 8))
        // The name and the version are one VoiceOver stop.
        XCTAssertTrue(version.label.hasPrefix("Tessera, version 1.0"), version.label)
        XCTAssertTrue(waitForLabel(element("about.status", in: app), containing: "Connected"))
        XCTAssertTrue(waitForLabel(element("about.wall", in: app), containing: "64 x 64, 4,096 lights"))
        XCTAssertTrue(element("about.wall", in: app).label.contains("One panel"))
        // Copying writes the pasteboard only. It is never read back here,
        // which would raise the paste prompt.
        // The address confirms in its own row, beside the button. The notice
        // under the rows is Copy details' alone.
        tap("about.copyAddress", in: app)
        XCTAssertTrue(waitForLabel(element("about.address", in: app), containing: "Copied"))
        XCTAssertFalse(element("about.notice", in: app).exists)
        tap("about.copyDetails", in: app)
        XCTAssertTrue(waitForLabel(element("about.notice", in: app), containing: "Details copied."))
        let written = pageWrites(try await status())
        XCTAssertTrue(written.isEmpty, String(describing: written))
    }

    /// The capture hook for a phone that never reached a wall: the page is
    /// pinned to its first look, and says so rather than naming a size.
    @MainActor func testNeverConnectedHookSaysNotConnectedYet() async throws {
        let app = try await launch("about", extra: ["-about-state", "never"])
        XCTAssertTrue(waitForLabel(element("about.wall", in: app), containing: "Not connected yet"))
        XCTAssertTrue(waitForLabel(element("about.status", in: app), containing: "Looking for your wall"))
        // Nothing offers to look while the phone is already looking.
        XCTAssertFalse(app.buttons["about.lookAgain"].exists)
        let row = app.buttons["about.tuning"]
        reveal(row, in: app)
        XCTAssertTrue(waitForValue(row, containing: "Waiting for your wall"), String(describing: row.value))
        XCTAssertFalse(row.isEnabled)
        let written = pageWrites(try await status())
        XCTAssertTrue(written.isEmpty, String(describing: written))
    }

    @MainActor func testAboutTuningAsksOnceThenOpensDirectly() async throws {
        let app = try await launch("about", extra: ["-about-reset"])
        tap("about.tuning", in: app)
        XCTAssertTrue(element("about.tuningConfirm", in: app).waitForExistence(timeout: 5))
        XCTAssertFalse(app.navigationBars["Panel tuning"].exists)
        // Not now folds it away again without opening anything.
        tap("about.tuningCancel", in: app)
        XCTAssertTrue(element("about.tuningConfirm", in: app).waitForNonExistence(timeout: 5))
        tap("about.tuning", in: app)
        tap("about.tuningOpen", in: app)
        let tuning = app.navigationBars["Panel tuning"]
        XCTAssertTrue(tuning.waitForExistence(timeout: 8))
        tuning.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.navigationBars["About"].waitForExistence(timeout: 8))
        // Asked once. From now on the row opens the page straight away.
        tap("about.tuning", in: app)
        XCTAssertTrue(tuning.waitForExistence(timeout: 8))
        XCTAssertFalse(element("about.tuningConfirm", in: app).exists)
        let snapshot = try await status()
        for path in ["/tuning", "/tuning/reset", "/tuning/restart"] {
            XCTAssertTrue(posts(snapshot, path: path).isEmpty, path)
        }
    }

    @MainActor func testAboutTuningStatusFollowsTheWall() async throws {
        // Three settings moved: dither, black point and green gain. The row
        // counts as the tuning page does, in the same words.
        var app = try await launch("about", phase: "tuned")
        var row = app.buttons["about.tuning"]
        XCTAssertTrue(row.waitForExistence(timeout: 8))
        reveal(row, in: app)
        XCTAssertTrue(waitForValue(row, containing: "3 settings changed from their defaults"), String(describing: row.value))
        XCTAssertTrue(row.isEnabled)
        app.terminate()

        // A wall without a tuning store answers 503: the row is shut.
        app = try await launch("about", phase: "notuning")
        row = app.buttons["about.tuning"]
        XCTAssertTrue(row.waitForExistence(timeout: 8))
        reveal(row, in: app)
        XCTAssertTrue(waitForValue(row, containing: "Not available on this wall"), String(describing: row.value))
        XCTAssertFalse(row.isEnabled)
        app.terminate()

        // The wall goes away after answering: no count is shown, the row is
        // shut, and the page offers to look again.
        app = try await launch("about")
        row = app.buttons["about.tuning"]
        XCTAssertTrue(row.waitForExistence(timeout: 8))
        XCTAssertTrue(waitForValue(row, containing: "All settings at their defaults"), String(describing: row.value))
        _ = try await api("/qa/available", ["enabled": false, "as": "http"])
        XCTAssertTrue(waitForLabel(element("about.status", in: app), containing: "Offline", timeout: 15))
        reveal(row, in: app)
        XCTAssertTrue(waitForValue(row, containing: "Needs your wall"), String(describing: row.value))
        XCTAssertFalse(row.isEnabled)
        let look = app.buttons["about.lookAgain"]
        reveal(look, in: app)
        XCTAssertTrue(look.exists)
        // This phone has met the wall, so it looks again.
        XCTAssertTrue(look.label.contains("Look for your wall again"), look.label)
        _ = try await api("/qa/available", ["enabled": true])
    }

    /// tuning-slow holds GET /tuning for 3 s, under the page's 4 s timeout.
    /// Launched straight into About, the read started at launch and the
    /// harness's waits (each predicate wait first looks after about a
    /// second) used up the 3 s before the first look, so the page was
    /// already right to say the answer. Opened from the Settings landing,
    /// the read starts with the tap, and the row is read at once.
    @MainActor func testSlowTuningReadShowsReadingThenAnswer() async throws {
        let app = try await launch(nil, phase: "tuning-slow")
        tap("settings.route.about", in: app)
        let row = app.buttons["about.tuning"]
        let deadline = Date().addingTimeInterval(2)
        while !row.exists, Date() < deadline { try await Task.sleep(for: .milliseconds(100)) }
        XCTAssertTrue(row.exists)
        XCTAssertTrue((row.value as? String ?? "").contains("Reading your wall"), String(describing: row.value))
        XCTAssertTrue(row.isEnabled)
        XCTAssertTrue(waitForValue(row, containing: "All settings at their defaults", timeout: 10), String(describing: row.value))
    }

    @MainActor func testOpeningChoicesFollowTheDesign() async throws {
        // -design is fine here: nothing in this test writes it.
        var app = try await launchUnpinned(page: "about", design: "classic")
        for id in ["sting", "sting-room", "none"] {
            XCTAssertTrue(app.buttons["about.opening.\(id)"].waitForExistence(timeout: 8), id)
        }
        XCTAssertFalse(app.buttons["about.opening.film"].exists)
        XCTAssertFalse(app.buttons["about.opening.mark"].exists)
        app.terminate()

        app = try await launchUnpinned(page: "about", design: "ipod")
        let ipodFilm = app.buttons["about.opening.film"]
        XCTAssertTrue(ipodFilm.waitForExistence(timeout: 8))
        XCTAssertTrue(ipodFilm.label.contains("iPod film"), ipodFilm.label)
        XCTAssertFalse(app.buttons["about.opening.mark"].exists)
        app.terminate()

        app = try await launchUnpinned(page: "about", design: "room")
        let roomFilm = app.buttons["about.opening.film"]
        XCTAssertTrue(roomFilm.waitForExistence(timeout: 8))
        XCTAssertTrue(roomFilm.label.contains("Room film"), roomFilm.label)
        XCTAssertTrue(app.buttons["about.opening.mark"].exists)
    }

    @MainActor func testPanelWithAFilmSavedOpensStraightToTheWall() async throws {
        var app = try await launchUnpinned(page: "about", design: "room")
        tap("about.opening.film", in: app)
        app.terminate()
        app = try await launchUnpinned(page: "about", design: "classic")
        let none = app.buttons["about.opening.none"]
        XCTAssertTrue(none.waitForExistence(timeout: 8))
        XCTAssertTrue(none.isSelected)
        let note = element("about.openingNote", in: app)
        reveal(note, in: app)
        XCTAssertTrue(note.label.contains("no film of its own"), note.label)
        XCTAssertFalse(app.buttons["about.playOpening"].exists)
    }

    @MainActor func testPlayOpeningClosesSettingsAndSendsNothing() async throws {
        var app = try await launchUnpinned(page: "about", design: "room")
        tap("about.opening.sting", in: app)
        tap("about.playOpening", in: app)
        XCTAssertTrue(element("opening.sting", in: app).waitForExistence(timeout: 3))
        XCTAssertTrue(app.navigationBars["About"].waitForNonExistence(timeout: 8))
        // The film runs about 5 s and fades for 0.6 s, and the page marks
        // are hidden until it is done.
        XCTAssertTrue(app.buttons["navigation.wall"].waitForExistence(timeout: 12))
        app.terminate()

        // The request is a counter, so nothing is left on after a launch and
        // the next Play plays again.
        app = try await launchUnpinned(page: "about", design: "room")
        let sting = app.buttons["about.opening.sting"]
        XCTAssertTrue(sting.waitForExistence(timeout: 8))
        XCTAssertTrue(sting.isSelected)
        tap("about.playOpening", in: app)
        XCTAssertTrue(element("opening.sting", in: app).waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["navigation.wall"].waitForExistence(timeout: 12))
        let written = pageWrites(try await status())
        XCTAssertTrue(written.isEmpty, String(describing: written))
    }

    @MainActor func testRoomFilmPlaysOnEveryPlayAndAtLaunch() async throws {
        var app = try await launchUnpinned(page: "about", design: "room")
        tap("about.opening.film", in: app)
        tap("about.playOpening", in: app)
        XCTAssertTrue(element("opening.room", in: app).waitForExistence(timeout: 3))
        XCTAssertTrue(element("opening.room", in: app).waitForNonExistence(timeout: 20))
        app.terminate()

        // The old switch latched here: after one film, Play did nothing for
        // good, even across launches.
        app = try await launchUnpinned(page: "about", design: "room")
        tap("about.playOpening", in: app)
        XCTAssertTrue(element("opening.room", in: app).waitForExistence(timeout: 3))
        app.terminate()

        // A cold launch plays the room's film, which depends on the room
        // deciding before WallScreen settles the launch.
        app = try await launchUnpinned(page: "home", design: "room", nointro: false)
        XCTAssertTrue(element("opening.room", in: app).waitForExistence(timeout: 3))
        let written = pageWrites(try await status())
        XCTAssertTrue(written.isEmpty, String(describing: written))
    }

    @MainActor func testReduceMotionKeepsOpeningsOff() async throws {
        var app = try await launchUnpinned(page: "about", design: "room", extra: ["-reduce-motion"])
        tap("about.opening.sting", in: app)
        let play = app.buttons["about.playOpening"]
        reveal(play, in: app)
        XCTAssertTrue(play.exists)
        XCTAssertFalse(play.isEnabled)
        XCTAssertTrue(element("about.reduceMotion", in: app).exists)
        tap("about.opening.film", in: app)
        app.terminate()

        // Cold, with the room's film saved and no -nointro: nothing plays.
        app = try await launchUnpinned(page: "home", design: "room", extra: ["-reduce-motion"], nointro: false)
        XCTAssertTrue(app.buttons["navigation.wall"].waitForExistence(timeout: 8))
        try await Task.sleep(for: .seconds(3))
        XCTAssertFalse(element("opening.room", in: app).exists)
        XCTAssertFalse(element("opening.sting", in: app).exists)
    }

    @MainActor func testSetupAgainOpensFirstRun() async throws {
        let app = try await launch("about")
        tap("about.setup", in: app)
        XCTAssertTrue(app.buttons["onboarding.skip"].waitForExistence(timeout: 10))
        tap("onboarding.skip", in: app)
        XCTAssertTrue(app.buttons["onboarding.skip"].waitForNonExistence(timeout: 8))
        XCTAssertTrue(app.buttons["navigation.wall"].waitForExistence(timeout: 8))
        let sessions = posts(try await status(), path: "/display-session")
        XCTAssertTrue(sessions.isEmpty)
    }

    // MARK: - App design

    /// Room in use before a design test, whatever an earlier run left. Use
    /// is only there when the picked design is not the one in use.
    @MainActor func normaliseToRoom(_ app: XCUIApplication) {
        tap("design.option.room", in: app)
        let use = app.buttons["design.use"]
        // Previews render off the main thread, so Use can take a moment to
        // appear after a launch under load.
        if use.waitForExistence(timeout: 4) { use.tap() }
        XCTAssertTrue(waitForLabel(element("design.state", in: app), containing: "in use"))
    }

    @MainActor func testDesignPreviewCommitsOnlyOnUse() async throws {
        var app = try await launchUnpinned(page: "design")
        normaliseToRoom(app)
        tap("design.option.classic", in: app)
        XCTAssertTrue(waitForLabel(element("design.state", in: app), containing: "preview"))
        XCTAssertTrue(app.buttons["design.use"].isEnabled)
        closeSettings(app)
        XCTAssertFalse(element("home.panel", in: app).exists)
        app.terminate()

        app = try await launchUnpinned(page: "design")
        normaliseToRoom(app)
        tap("design.option.classic", in: app)
        tap("design.use", in: app)
        XCTAssertTrue(element("design.notice", in: app).waitForExistence(timeout: 5))
        XCTAssertTrue(waitForLabel(element("design.state", in: app), containing: "in use"))
        // The button goes once there is nothing left for it to do, and the
        // notice takes its place.
        XCTAssertTrue(app.buttons["design.use"].waitForNonExistence(timeout: 5))
        XCTAssertTrue(element("design.notice", in: app).isHittable)
        closeSettings(app)
        XCTAssertTrue(element("home.panel", in: app).waitForExistence(timeout: 8))
        // A home made after launch does not play a film.
        XCTAssertFalse(element("opening.room", in: app).exists)
        let written = pageWrites(try await status())
        XCTAssertTrue(written.isEmpty, String(describing: written))
        app.terminate()

        app = try await launchUnpinned(page: "design")
        normaliseToRoom(app)
    }

    @MainActor func testDesignChoiceNeedsNoWall() async throws {
        let app = try await launchUnpinned(page: "design", phase: "offline")
        normaliseToRoom(app)
        tap("design.option.ipod", in: app)
        tap("design.use", in: app)
        XCTAssertTrue(element("design.notice", in: app).waitForExistence(timeout: 5))
        let written = pageWrites(try await status())
        XCTAssertTrue(written.isEmpty, String(describing: written))
        normaliseToRoom(app)
    }

    @MainActor func testDesignOptionsSayWhichIsInUse() async throws {
        let app = try await launchUnpinned(page: "design")
        normaliseToRoom(app)
        let room = app.buttons["design.option.room"]
        XCTAssertTrue(room.isSelected)
        XCTAssertEqual(room.value as? String, "In use")
        tap("design.option.ipod", in: app)
        let ipod = app.buttons["design.option.ipod"]
        XCTAssertTrue(ipod.isSelected)
        XCTAssertEqual(ipod.value as? String, "Preview")
        XCTAssertEqual(app.buttons["design.option.room"].value as? String, "In use")
        XCTAssertTrue(app.buttons["design.use"].label.contains("Use iPod"))
    }

    // MARK: - Search

    /// Needs the integration phase's catalog entries (.design, and the new
    /// .about aliases).
    @MainActor func testSettingsSearchFindsDesignAndAbout() async throws {
        let app = try await launch(nil)
        let search = app.textFields["settings.search"]
        XCTAssertTrue(search.waitForExistence(timeout: 8))
        search.tap()
        search.typeText("ipod")
        XCTAssertTrue(app.buttons["settings.route.design"].waitForExistence(timeout: 5))
        app.buttons["Clear search"].tap()
        search.tap()
        search.typeText("tuning")
        XCTAssertTrue(app.buttons["settings.route.about"].waitForExistence(timeout: 5))
    }
}
