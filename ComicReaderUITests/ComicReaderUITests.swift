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

        let settings = app.descendants(matching: .any)["sidebar.settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 8))
        settings.tap()

        for identifier in [
            "settings.reader.defaultMode",
            "settings.reader.defaultDirection",
            "settings.reader.tapArea.left",
            "settings.reader.tapArea.right",
        ] {
            XCTAssertTrue(
                app.descendants(matching: .any)[identifier]
                    .waitForExistence(timeout: 5),
                "Missing reader setting: \(identifier)"
            )
        }
    }
}
