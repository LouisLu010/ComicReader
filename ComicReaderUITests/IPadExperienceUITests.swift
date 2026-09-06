import XCTest

final class IPadExperienceUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    func testPrivacyShieldCoversOpenSheetAfterBackground() {
        let app = launch(fixture: "privacy-locked")
        let unlock = app.buttons["privacy.unlock"]
        XCTAssertTrue(unlock.waitForExistence(timeout: 10))
        let comic = app.buttons["library.comic.00000000-0000-0000-0000-000000000901"]
        XCTAssertFalse(comic.exists)
        unlock.tap()
        XCTAssertTrue(comic.waitForExistence(timeout: 10))
        comic.tap()
        let edit = app.buttons["library.metadata.edit"]
        reveal(edit, in: app)
        edit.tap()
        let save = app.buttons["library.metadata.save"]
        XCTAssertTrue(save.waitForExistence(timeout: 5))
        XCUIDevice.shared.press(.home)
        app.activate()
        XCTAssertTrue(unlock.waitForExistence(timeout: 10))
        XCTAssertFalse(save.isHittable)
        unlock.tap()
        XCTAssertTrue(save.waitForExistence(timeout: 10))
    }

    func testReaderDisplaySettingsApplyAndReopen() {
        let app = launch(fixture: "reader-navigation")
        let comic = app.buttons["library.comic.00000000-0000-0000-0000-000000000901"]
        XCTAssertTrue(comic.waitForExistence(timeout: 10))
        comic.tap()
        app.buttons["library.read"].tap()
        let display = app.buttons["reader.display.open"]
        XCTAssertTrue(display.waitForExistence(timeout: 10))
        display.tap()
        let trim = app.switches["reader.display.trim"]
        XCTAssertTrue(trim.waitForExistence(timeout: 5))
        trim.tap()
        let animations = app.switches["reader.display.animations"]
        reveal(animations, in: app)
        animations.tap()
        app.buttons["reader.display.done"].tap()
        XCTAssertTrue(display.waitForExistence(timeout: 5))
        display.tap()
        XCTAssertTrue(trim.waitForExistence(timeout: 5))
        XCTAssertEqual(trim.value as? String, "1")
        reveal(animations, in: app)
        XCTAssertEqual(animations.value as? String, "0")
    }

    func testLargestDynamicTypeKeepsDetailReadingActionReachable() {
        let app = launch(fixture: "reader-navigation", largeText: true)
        let comic = app.buttons["library.comic.00000000-0000-0000-0000-000000000901"]
        XCTAssertTrue(comic.waitForExistence(timeout: 10))
        comic.tap()
        let read = app.buttons["library.read"]
        reveal(read, in: app)
        read.tap()
        XCTAssertTrue(app.buttons["reader.display.open"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["reader.navigation.nextPage"].exists)
    }

    func testComicCanOpenInIndependentWindow() {
        let app = launch(fixture: "reader-navigation")
        let comic = app.buttons["library.comic.00000000-0000-0000-0000-000000000901"]
        XCTAssertTrue(comic.waitForExistence(timeout: 10))
        comic.tap()
        let open = app.buttons["window.openComic"]
        XCTAssertTrue(open.waitForExistence(timeout: 5))
        open.tap()
        XCTAssertTrue(app.descendants(matching: .any)["window.comic"].firstMatch.waitForExistence(timeout: 15))
    }

    private func launch(fixture: String, largeText: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["COMICREADER_UI_TEST_FIXTURE"] = fixture
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        if largeText {
            app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        }
        app.launch()
        return app
    }

    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<8 {
            if element.exists && element.isHittable { return }
            app.swipeUp()
        }
        XCTAssertTrue(element.isHittable)
    }
}
