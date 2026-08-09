import XCTest

final class ComicReaderUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testEmptyLibraryOffersFolderImport() {
        let app = XCUIApplication()
        app.launch()

        XCTAssertTrue(
            app.descendants(matching: .any)["library.empty"]
                .waitForExistence(timeout: 5)
        )
        XCTAssertTrue(
            app.buttons["import.button"]
                .waitForExistence(timeout: 5)
        )
        XCTAssertTrue(
            app.buttons["import.toolbarButton"]
                .waitForExistence(timeout: 5)
        )
        XCTAssertTrue(
            app.descendants(matching: .any)["import.dropTarget"]
                .waitForExistence(timeout: 5)
        )
    }

    func testUnknownFixtureFailsClosed() {
        let app = XCUIApplication()
        app.launchEnvironment["COMICREADER_UI_TEST_FIXTURE"] = (
            "unknown-fixture"
        )
        app.launch()

        let failure = app.descendants(matching: .any)["uiTestFixture.failed"]
        XCTAssertTrue(failure.waitForExistence(timeout: 5))
        XCTAssertTrue(failure.label.contains("Unknown UI test fixture."))
        XCTAssertFalse(
            app.descendants(matching: .any)["library.empty"].exists
        )
    }

    func testSettingsExposeReaderDefaultsAndTapAreaControls() {
        let app = XCUIApplication()
        app.launchArguments += [
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US",
        ]
        app.launch()

        openSettings(in: app)

        for identifier in [
            "settings.reader.defaultMode",
            "settings.reader.defaultDirection",
            "settings.reader.tapArea.left",
            "settings.reader.tapArea.right",
        ] {
            let setting = element(identifier, in: app)
            XCTAssertTrue(waitUntilHittable(setting, timeout: 8))
        }

        let defaultMode = element("settings.reader.defaultMode", in: app)
        defaultMode.tap()
        let singlePage = element(
            "settings.reader.defaultMode.singlePage",
            in: app
        )
        XCTAssertTrue(waitUntilHittable(singlePage))
        singlePage.tap()
        XCTAssertTrue(waitUntilHittable(defaultMode, timeout: 8))
        XCTAssertTrue(waitForValue("Single Page", of: defaultMode))

        let leftTap = element("settings.reader.tapArea.left", in: app)
        leftTap.tap()
        let disabled = element(
            "settings.reader.tapArea.left.disabled",
            in: app
        )
        XCTAssertTrue(waitUntilHittable(disabled))
        disabled.tap()
        XCTAssertTrue(waitUntilHittable(leftTap, timeout: 8))
        XCTAssertTrue(waitForValue("Disabled", of: leftTap))

        app.terminate()
        app.launch()
        openSettings(in: app)
        XCTAssertTrue(
            waitForValue(
                "Single Page",
                of: element("settings.reader.defaultMode", in: app),
                timeout: 8
            )
        )
        XCTAssertTrue(
            waitForValue(
                "Disabled",
                of: element("settings.reader.tapArea.left", in: app),
                timeout: 8
            )
        )
    }

    private func openSettings(in app: XCUIApplication) {
        let settings = element("sidebar.settings", in: app)
        XCTAssertTrue(waitUntilHittable(settings, timeout: 8))
        settings.tap()
    }

    private func element(
        _ identifier: String,
        in app: XCUIApplication
    ) -> XCUIElement {
        app.descendants(matching: .any)[identifier]
    }

    private func waitUntilHittable(
        _ element: XCUIElement,
        timeout: TimeInterval = 5
    ) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(
                format: "exists == true AND hittable == true"
            ),
            object: element
        )
        return XCTWaiter.wait(for: [expectation], timeout: timeout)
            == .completed
    }

    private func waitForValue(
        _ value: String,
        of element: XCUIElement,
        timeout: TimeInterval = 5
    ) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(
                format: "exists == true AND value == %@",
                value
            ),
            object: element
        )
        return XCTWaiter.wait(for: [expectation], timeout: timeout)
            == .completed
    }
}
