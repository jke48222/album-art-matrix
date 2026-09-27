import XCTest

final class DeviceInteractionTests: XCTestCase {
    func api(_ path: String, _ body: [String: Any]? = nil) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:65365" + path)!)
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
        app.launchArguments = ["-nointro", "-onboarded", "YES", "-intro.sting.migrated", "YES", "-intro.style", "none", "-design", "room", "-wall.host", "127.0.0.1:65365", "-reporter.host", "", "-reporter.background", "NO", "-live.enabled", "NO", "-settings", "-settings-page", "services", "-service-page", page]
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
    @MainActor func testImagesSwitchClearsKeyWithoutGenerating() async throws {
        let app=try await launch("images")
        tap("images.provider.google",in:app);tap("images.confirmSwitch",in:app)
        XCTAssertTrue(app.staticTexts["images.notice"].waitForExistence(timeout:8))
        let account=try await service("images")
        XCTAssertEqual(account["provider"] as? String,"google");XCTAssertEqual(account["ready"] as? Bool,false)
        let status=try await api("/qa/status");let requests=status["requests"] as? [[String:Any]] ?? []
        XCTAssertFalse(requests.contains { ($0["path"] as? String)=="/imagine" })
    }
    @MainActor func testImagesKeyRemainsSecure() async throws {
        let app=try await launch("images",phase:"unlinked")
        let key=app.secureTextFields["images.key"];reveal(key,in:app);key.tap();key.typeText("bad")
        XCTAssertFalse(app.buttons["images.save"].isEnabled)
    }
    @MainActor func testPosterLookupDoesNotChangeWallMode() async throws {
        let app=try await launch("posters")
        let field=app.textFields["posters.title"];reveal(field,in:app);field.tap();field.typeText("Unknown film\n")
        let result=app.descendants(matching:.any)["posters.noMatch"].firstMatch
        reveal(result,in:app)
        XCTAssertTrue(app.descendants(matching:.any)["posters.noMatch"].firstMatch.waitForExistence(timeout:8))
        let status=try await api("/qa/status")
        XCTAssertEqual((status["state"] as? [String:Any])?["mode"] as? String,"art")
    }
    @MainActor func testMacDisconnectPersists() async throws {
        let app=try await launch("mac");tap("mac.disconnect",in:app);tap("mac.confirmDisconnect",in:app)
        XCTAssertTrue(app.staticTexts["Mac disconnected."].waitForExistence(timeout:8))
        XCUIDevice.shared.press(.home);app.activate();try await Task.sleep(for:.seconds(1))
        let account=try await service("mac");XCTAssertEqual(account["endpoint"] as? String,"")
    }
    @MainActor func testMacInvalidAddressCannotSave() async throws {
        let app=try await launch("mac",phase:"unlinked")
        let field=app.textFields["mac.address"];reveal(field,in:app);field.tap();field.typeText("http://user:secret@mac/path")
        XCTAssertFalse(app.buttons["mac.save"].isEnabled)
    }
    @MainActor func testAirPlayFailedRenameKeepsDraft() async throws {
        let app=try await launch("airplay");tap("airplay.editName",in:app)
        let field=app.textFields["airplay.name"];reveal(field,in:app);field.tap()
        let old=field.value as? String ?? "";field.typeText(String(repeating:XCUIKeyboardKey.delete.rawValue,count:old.count)+"Studio wall")
        app.swipeUp();_ = try await api("/qa/reject",[:]);tap("airplay.saveName",in:app)
        XCTAssertTrue(app.otherElements["airplay.problem"].waitForExistence(timeout:8) || app.staticTexts["airplay.problem"].exists)
        XCTAssertEqual(field.value as? String,"Studio wall")
        let account=try await service("airplay");XCTAssertEqual((account["receiver"] as? [String:Any])?["name"] as? String,"Tessera")
    }
    @MainActor func testAirPlayExternalCannotBeRenamed() async throws {
        let app=try await launch("airplay",phase:"external")
        let external=app.descendants(matching:.any)["airplay.external"].firstMatch;reveal(external,in:app)
        XCTAssertTrue(external.exists)
        XCTAssertFalse(app.buttons["airplay.editName"].exists)
    }
    @MainActor func testHomeKitCodeShowsAndHides() async throws {
        let app=try await launch("homekit");tap("homekit.showCode",in:app)
        XCTAssertTrue(app.staticTexts["Setup code is on the wall."].waitForExistence(timeout:8))
        tap("homekit.showCode",in:app)
        XCTAssertTrue(app.staticTexts["The wall has returned to its previous view."].waitForExistence(timeout:8))
        let status=try await api("/qa/status");XCTAssertEqual((status["homekit"] as? [String:Any])?["showing_code"] as? Bool,false)
    }
    @MainActor func testHomeKitPairedHidesSetupCode() async throws {
        let app=try await launch("homekit",phase:"paired")
        let paired=app.descendants(matching:.any)["homekit.paired"].firstMatch;reveal(paired,in:app)
        XCTAssertTrue(paired.exists)
        XCTAssertFalse(app.staticTexts["homekit.code"].exists)
        XCTAssertFalse(app.buttons["homekit.showCode"].exists)
    }
}
