import XCTest

final class ReaderFlowUITests: XCTestCase {
    private let comicID = "00000000-0000-0000-0000-000000000901"

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testReaderNavigationFromFixtureUsesThumbnailSliderAndChapterList() {
        let app = launchReaderFixture()
        let slider = app.sliders["reader.navigation.pageSlider"]
        let pageDescription = element(
            "reader.navigation.pageDescription",
            in: app
        )

        XCTAssertTrue(waitForLabel("Page 1 of 5", on: pageDescription))

        let thumbnail = app.buttons[
            "reader.thumbnail.ui-chapter-one-page-two"
        ]
        XCTAssertTrue(waitUntilHittable(thumbnail))
        thumbnail.tap()
        XCTAssertTrue(waitForLabel("Page 3 of 5", on: pageDescription))
        XCTAssertTrue(
            element(
                "reader.page.image.ui-chapter-one-page-two",
                in: app
            ).waitForExistence(timeout: 8)
        )

        slider.adjust(toNormalizedSliderPosition: 1)
        XCTAssertTrue(waitForLabel("Page 5 of 5", on: pageDescription))
        XCTAssertTrue(
            element(
                "reader.page.image.ui-chapter-two-page-two",
                in: app
            ).waitForExistence(timeout: 8)
        )

        let chapterButton = app.buttons["reader.navigation.chapters"]
        XCTAssertTrue(waitUntilHittable(chapterButton))
        chapterButton.tap()
        XCTAssertTrue(
            element("reader.navigation.chapterList", in: app)
                .waitForExistence(timeout: 5)
        )

        let chapterTwoButton = app.buttons[
            "reader.navigation.chapter.ui-chapter-two"
        ]
        XCTAssertTrue(waitUntilHittable(chapterTwoButton))
        chapterTwoButton.tap()
        XCTAssertTrue(waitForLabel("Page 4 of 5", on: pageDescription))
        XCTAssertTrue(
            element(
                "reader.page.image.ui-chapter-two-page-one",
                in: app
            ).waitForExistence(timeout: 8)
        )
    }

    func testReaderFixtureChangesReadingModes() {
        let app = launchReaderFixture()
        let pageDescription = element(
            "reader.navigation.pageDescription",
            in: app
        )
        let chapterOnePageTwo = app.buttons[
            "reader.thumbnail.ui-chapter-one-page-two"
        ]
        XCTAssertTrue(waitUntilHittable(chapterOnePageTwo))
        chapterOnePageTwo.tap()
        XCTAssertTrue(waitForLabel("Page 3 of 5", on: pageDescription))

        selectMode(.singlePage, in: app)
        XCTAssertTrue(
            element("reader.singlePage", in: app)
                .waitForExistence(timeout: 5)
        )
        XCTAssertTrue(waitForLabel("Page 3 of 5", on: pageDescription))

        selectMode(.continuous, in: app)
        XCTAssertTrue(
            element("reader.continuous", in: app).waitForExistence(timeout: 5)
        )
        XCTAssertTrue(waitForLabel("Page 3 of 5", on: pageDescription))

        selectMode(.spread, in: app)
        XCTAssertTrue(
            element("reader.spread", in: app).waitForExistence(timeout: 5)
        )
        XCTAssertTrue(waitForLabel("Page 3 of 5", on: pageDescription))

        let landscapePage = app.buttons[
            "reader.thumbnail.ui-chapter-two-page-one"
        ]
        XCTAssertTrue(waitUntilHittable(landscapePage))
        landscapePage.tap()
        XCTAssertTrue(waitForLabel("Page 4 of 5", on: pageDescription))
        XCTAssertTrue(
            element("reader.page.image.ui-chapter-two-page-one", in: app)
                .waitForExistence(timeout: 8)
        )
    }

    private func launchReaderFixture() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["COMICREADER_UI_TEST_FIXTURE"] = (
            "reader-navigation"
        )
        app.launchArguments += [
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US",
        ]
        app.launch()

        let comic = app.buttons["library.comic.\(comicID)"]
        XCTAssertTrue(waitUntilHittable(comic, timeout: 10))
        comic.tap()

        let readButton = app.buttons["library.read"]
        XCTAssertTrue(waitUntilHittable(readButton))
        readButton.tap()
        XCTAssertTrue(
            element("reader.screen", in: app).waitForExistence(timeout: 8)
        )
        XCTAssertTrue(
            element("reader.page.image.ui-cover", in: app)
                .waitForExistence(timeout: 10)
        )
        XCTAssertTrue(
            waitForLabel(
                "Page 1 of 5",
                on: element("reader.navigation.pageDescription", in: app)
            )
        )

        return app
    }

    private func selectMode(_ mode: Mode, in app: XCUIApplication) {
        let menu = app.buttons["reader.controls.menu"]
        XCTAssertTrue(waitUntilHittable(menu))
        menu.tap()

        let option = app.buttons
            .matching(NSPredicate(format: "label == %@", mode.buttonLabel))
            .firstMatch
        XCTAssertTrue(waitUntilHittable(option))
        option.tap()
    }

    private func waitForLabel(
        _ label: String,
        on element: XCUIElement,
        timeout: TimeInterval = 8
    ) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@", label),
            object: element
        )
        return XCTWaiter.wait(for: [expectation], timeout: timeout)
            == .completed
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

    private func element(
        _ identifier: String,
        in app: XCUIApplication
    ) -> XCUIElement {
        app.descendants(matching: .any)[identifier]
    }
}

private enum Mode {
    case continuous
    case singlePage
    case spread

    var buttonLabel: String {
        switch self {
        case .continuous:
            "Continuous"
        case .singlePage:
            "Single Page"
        case .spread:
            "Two-Page Spread"
        }
    }
}
