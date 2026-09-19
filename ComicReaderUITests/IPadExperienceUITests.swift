import XCTest

final class IPadExperienceUITests: XCTestCase {
    private let comicID = "00000000-0000-0000-0000-000000000901"

    override func setUpWithError() throws { continueAfterFailure = false }

    func testPrivacyShieldCoversOpenSheetAfterBackground() {
        let app = launch(fixture: "privacy-locked")
        let unlock = app.buttons["privacy.unlock"]
        XCTAssertTrue(unlock.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(unlock.isHittable)
        let comic = app.buttons["library.comic.\(comicID)"]
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
        XCTAssertTrue(unlock.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(unlock.isHittable)
        // 遮罩窗口隐藏其他窗口的无障碍元素，弹窗内容不可见也不可点。
        XCTAssertFalse(save.exists)
        XCTAssertFalse(save.isHittable)
        unlock.tap()
        XCTAssertTrue(save.waitForExistence(timeout: 10))
    }

    func testReaderDisplaySettingsApplyAndReopen() {
        let app = launch(fixture: "reader-navigation")
        let comic = app.buttons["library.comic.\(comicID)"]
        XCTAssertTrue(comic.waitForExistence(timeout: 10))
        comic.tap()
        app.buttons["library.read"].tap()
        let display = app.buttons["reader.display.open"]
        XCTAssertTrue(display.waitForExistence(timeout: 10))
        display.tap()
        let trim = app.switches["reader.display.trim"]
        XCTAssertTrue(trim.waitForExistence(timeout: 5))
        XCTAssertEqual(trim.value as? String, "0", app.debugDescription)
        tapSwitch(trim)
        XCTAssertTrue(waitForValue("1", of: trim), app.debugDescription)
        let animations = app.switches["reader.display.animations"]
        reveal(animations, in: app)
        XCTAssertEqual(animations.value as? String, "1", app.debugDescription)
        tapSwitch(animations)
        XCTAssertTrue(waitForValue("0", of: animations), app.debugDescription)
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
        let comic = app.buttons["library.comic.\(comicID)"]
        XCTAssertTrue(comic.waitForExistence(timeout: 10))
        comic.tap()
        let read = app.buttons["library.read"]
        reveal(read, in: app)
        read.tap()
        XCTAssertTrue(app.buttons["reader.display.open"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["reader.navigation.nextPage"].exists)
    }

    /// 打开的第二个窗口会随场景恢复；放在本组最后执行，避免污染其他用例。
    func testZComicCanOpenInIndependentWindow() {
        let app = launch(fixture: "reader-navigation")
        let libraryWindow = app.windows["window.library"]
        XCTAssertTrue(libraryWindow.waitForExistence(timeout: 10), app.debugDescription)
        let comic = libraryWindow.buttons["library.comic.\(comicID)"]
        XCTAssertTrue(comic.waitForExistence(timeout: 10))
        comic.tap()
        let open = libraryWindow.buttons["window.openComic"]
        XCTAssertTrue(open.waitForExistence(timeout: 5))
        open.tap()

        let comicWindow = app.windows["window.comic"]
        XCTAssertTrue(comicWindow.waitForExistence(timeout: 15), app.debugDescription)
        let read = comicWindow.buttons["library.read"]
        XCTAssertTrue(read.waitForExistence(timeout: 10), app.debugDescription)
        read.tap()
        XCTAssertTrue(
            comicWindow.buttons["reader.display.open"].waitForExistence(timeout: 10),
            app.debugDescription
        )
        // 原窗口仍停留在详情页，两个窗口的导航互不影响。
        XCTAssertTrue(libraryWindow.buttons["library.read"].exists)
        XCTAssertFalse(libraryWindow.buttons["reader.display.open"].exists)

        let back = comicWindow.navigationBars.buttons.firstMatch
        XCTAssertTrue(back.waitForExistence(timeout: 5))
        back.tap()
        let close = comicWindow.buttons["window.closeComic"]
        XCTAssertTrue(close.waitForExistence(timeout: 10), app.debugDescription)
        close.tap()
        let closed = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: comicWindow
        )
        XCTAssertEqual(XCTWaiter.wait(for: [closed], timeout: 10), .completed, app.debugDescription)
        XCTAssertTrue(libraryWindow.buttons["library.read"].waitForExistence(timeout: 10))
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

    /// Form 中的 Toggle 同时暴露整行和内部开关；点击文字区域不会切换，必须点击开关本身。
    private func tapSwitch(_ row: XCUIElement) {
        let control = row.switches.firstMatch
        if control.exists {
            XCTAssertTrue(control.isHittable)
            control.tap()
        } else {
            XCTAssertTrue(row.isHittable)
            row.tap()
        }
    }

    private func waitForValue(_ value: String, of element: XCUIElement) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == true AND value == %@", value),
            object: element
        )
        return XCTWaiter.wait(for: [expectation], timeout: 5) == .completed
    }
}
