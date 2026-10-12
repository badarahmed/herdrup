import XCTest

/// Focused launch/credential tests for the stock-Herder app. These never connect
/// to SSH or opt into a legacy screenshot harness or server-side capability.
final class CoreUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    func testLaunchExposesCoreHostsAndIgnoresLegacyFeatureHarness() {
        let app = XCUIApplication()
        app.launchEnvironment["HERDR_SCREENSHOT_MOCK"] = "gram"
        app.launch()
        XCTAssertTrue(app.navigationBars["Herdr Core"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["Add SSH host"].exists)
        assertExtrasAbsent(app)
    }

    func testHostEntryRequiresAddressUserAndChosenSecret() {
        let app = XCUIApplication()
        app.launch()
        app.buttons["Add SSH host"].tap()
        XCTAssertTrue(app.navigationBars["Add host"].waitForExistence(timeout: 5))
        let save = app.buttons["host-save-connect"]
        XCTAssertFalse(save.isEnabled)
        enter("core-test.invalid", into: app.textFields["host-host"])
        enter("tester", into: app.textFields["host-user"])
        XCTAssertFalse(save.isEnabled, "Key authentication must require a private key")
        app.segmentedControls["host-auth"].buttons["Password"].tap()
        XCTAssertFalse(save.isEnabled, "Password authentication must require a password")
        enter("local-test-secret", into: app.secureTextFields["host-password"])
        XCTAssertTrue(save.isEnabled)
        assertExtrasAbsent(app)
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.navigationBars["Herdr Core"].waitForExistence(timeout: 5))
    }

    func testSaveHostWithoutConnectingPersistsAndCanBeRemoved() {
        let app = XCUIApplication()
        let nickname = "Core UITest \(UUID().uuidString.prefix(8))"
        // SwiftUI exposes a host's name/address as its Button label, rather
        // than guaranteeing separate StaticText children for the label.
        let hostRow = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'core-host-' AND label CONTAINS %@", nickname)).firstMatch
        addTeardownBlock {
            app.terminate()
            app.launch()
            if hostRow.waitForExistence(timeout: 2) {
                hostRow.press(forDuration: 1)
                if app.buttons["Remove host"].waitForExistence(timeout: 2) {
                    app.buttons["Remove host"].tap()
                }
            }
        }
        app.launch()
        app.buttons["Add SSH host"].tap()
        XCTAssertTrue(app.navigationBars["Add host"].waitForExistence(timeout: 5))
        enter(nickname, into: app.textFields["host-nickname"])
        enter("core-test.invalid:2222", into: app.textFields["host-host"])
        enter("tester", into: app.textFields["host-user"])
        app.segmentedControls["host-auth"].buttons["Password"].tap()
        enter("local-test-secret", into: app.secureTextFields["host-password"])
        if !app.buttons["host-save-only"].isHittable { app.scrollViews.firstMatch.swipeUp() }
        app.buttons["host-save-only"].tap()
        XCTAssertTrue(app.navigationBars["Herdr Core"].waitForExistence(timeout: 5), "Successful save must dismiss the host editor")
        XCTAssertTrue(hostRow.waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Connecting over SSH…"].exists)
        app.terminate()
        app.launch()
        XCTAssertTrue(hostRow.waitForExistence(timeout: 5), "Saved hosts must survive relaunch")
        XCTAssertFalse(app.staticTexts["local-test-secret"].exists, "The saved secret must never be displayed")
        hostRow.press(forDuration: 1)
        let remove = app.buttons["Remove host"]
        XCTAssertTrue(remove.waitForExistence(timeout: 3))
        remove.tap()
        XCTAssertTrue(hostRow.waitForNonExistence(timeout: 5))
    }

    private func enter(_ value: String, into field: XCUIElement) {
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText(value)
    }

    private func assertExtrasAbsent(_ app: XCUIApplication) {
        for label in ["Gram", "Guest access", "Accept invite", "Pair host", "Accounts", "Archive", "Tip jar", "Support", "Settings"] {
            XCTAssertFalse(app.buttons[label].exists, "Non-core feature \(label) must not be reachable")
        }
    }
}
