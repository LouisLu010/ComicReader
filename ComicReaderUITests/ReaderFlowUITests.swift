import CoreGraphics
import XCTest

final class ReaderFlowUITests: XCTestCase {
    private let comicID = "00000000-0000-0000-0000-000000000901"

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testReaderNavigationFromFixtureUsesThumbnailSliderAndChapterList() {
        let app = launchReaderFixture()
        let slider = element("reader.navigation.pageSlider", in: app)
        XCTAssertTrue(slider.waitForExistence(timeout: 5))

        let thumbnail = app.buttons[
            "reader.thumbnail.ui-chapter-one-page-two"
        ]
        XCTAssertTrue(waitUntilHittable(thumbnail))
        thumbnail.tap()
        XCTAssertTrue(
            element(
                "reader.page.image.ui-chapter-one-page-two",
                in: app
            ).waitForExistence(timeout: 8)
        )

        slider.adjust(toNormalizedSliderPosition: 1)
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
        XCTAssertTrue(
            element(
                "reader.page.image.ui-chapter-two-page-one",
                in: app
            ).waitForExistence(timeout: 8)
        )
    }

    func testReaderFixtureSelectsReadingModes() {
        let app = launchReaderFixture()
        let chapterOnePageTwo = app.buttons[
            "reader.thumbnail.ui-chapter-one-page-two"
        ]
        XCTAssertTrue(waitUntilHittable(chapterOnePageTwo))
        chapterOnePageTwo.tap()
        XCTAssertTrue(
            element(
                "reader.page.image.ui-chapter-one-page-two",
                in: app
            ).waitForExistence(timeout: 8)
        )

        selectMode(.singlePage, in: app)
        XCTAssertTrue(
            element(
                "reader.page.image.ui-chapter-one-page-two",
                in: app
            ).waitForExistence(timeout: 8)
        )

        selectMode(.continuous, in: app)
        XCTAssertTrue(
            element(
                "reader.page.image.ui-chapter-one-page-two",
                in: app
            ).waitForExistence(timeout: 8)
        )

        selectMode(.spread, in: app)
        XCTAssertTrue(
            element(
                "reader.page.image.ui-chapter-one-page-two",
                in: app
            ).waitForExistence(timeout: 8)
        )

        let landscapePage = app.buttons[
            "reader.thumbnail.ui-chapter-two-page-one"
        ]
        XCTAssertTrue(waitUntilHittable(landscapePage))
        landscapePage.tap()
        XCTAssertTrue(
            element("reader.page.image.ui-chapter-two-page-one", in: app)
                .waitForExistence(timeout: 8)
        )
    }

    func testReaderTapAreasNavigateAndMirrorRightToLeft() {
        let app = launchReaderFixture()
        selectMode(.singlePage, in: app)
        XCTAssertTrue(waitForCurrentPage("1/5", in: app))

        let cover = pageImage("ui-cover", in: app)
        XCTAssertTrue(cover.waitForExistence(timeout: 5))
        tap(horizontalOffset: 0.9, on: cover)
        XCTAssertTrue(waitForCurrentPage("2/5", in: app))

        selectDirection(.rightToLeft, in: app)
        let firstChapterPage = pageImage("ui-chapter-one-page-one", in: app)
        XCTAssertTrue(firstChapterPage.waitForExistence(timeout: 5))
        tap(horizontalOffset: 0.1, on: firstChapterPage)
        XCTAssertTrue(waitForCurrentPage("3/5", in: app))
    }

    func testReaderTapAreasToggleControls() {
        let app = launchReaderFixture()
        let cover = pageImage("ui-cover", in: app)
        let menu = app.buttons["reader.controls.menu"]
        let reveal = app.buttons["reader.controls.reveal"]

        XCTAssertTrue(cover.waitForExistence(timeout: 5))
        XCTAssertTrue(waitUntilHittable(menu))

        tap(horizontalOffset: 0.5, on: cover)
        XCTAssertFalse(menu.waitForExistence(timeout: 2))
        XCTAssertFalse(element("reader.progress", in: app).exists)
        XCTAssertTrue(waitUntilHittable(reveal))

        reveal.tap()
        XCTAssertTrue(waitUntilHittable(menu))
        XCTAssertTrue(element("reader.progress", in: app).waitForExistence(timeout: 5))
    }

    func testReaderDoubleTapZoomDoesNotNavigate() {
        let app = launchReaderFixture()
        selectMode(.singlePage, in: app)
        XCTAssertTrue(waitForCurrentPage("1/5", in: app))

        let cover = pageImage("ui-cover", in: app)
        XCTAssertTrue(cover.waitForExistence(timeout: 5))
        doubleTap(horizontalOffset: 0.9, on: cover)

        XCTAssertTrue(waitForCurrentPage("1/5", in: app))

        tap(horizontalOffset: 0.9, on: cover)
        XCTAssertTrue(waitForCurrentPage("1/5", in: app))
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
        return app
    }

    private func selectMode(_ mode: Mode, in app: XCUIApplication) {
        let menu = app.buttons["reader.controls.menu"]
        XCTAssertTrue(waitUntilHittable(menu))
        menu.tap()

        let option = element(mode.accessibilityIdentifier, in: app)
        XCTAssertTrue(waitUntilHittable(option))
        option.tap()
    }

    private func selectDirection(
        _ direction: ReadingDirectionOption,
        in app: XCUIApplication
    ) {
        let menu = app.buttons["reader.controls.menu"]
        XCTAssertTrue(waitUntilHittable(menu))
        menu.tap()

        let option = element(direction.accessibilityIdentifier, in: app)
        XCTAssertTrue(waitUntilHittable(option))
        option.tap()
    }

    private func pageImage(
        _ pageID: String,
        in app: XCUIApplication
    ) -> XCUIElement {
        element("reader.page.image.\(pageID)", in: app)
    }

    private func tap(horizontalOffset: CGFloat, on element: XCUIElement) {
        element.coordinate(
            withNormalizedOffset: CGVector(dx: horizontalOffset, dy: 0.5)
        ).tap()
    }

    private func doubleTap(
        horizontalOffset: CGFloat,
        on element: XCUIElement
    ) {
        element.coordinate(
            withNormalizedOffset: CGVector(dx: horizontalOffset, dy: 0.5)
        ).doubleTap()
    }

    private func waitForCurrentPage(
        _ page: String,
        in app: XCUIApplication
    ) -> Bool {
        waitForValue(
            page,
            of: element("reader.navigation.currentPage", in: app)
        )
    }

    private func waitForValue(
        _ value: String,
        of element: XCUIElement,
        timeout: TimeInterval = 5
    ) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == true AND value == %@", value),
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

    var accessibilityIdentifier: String {
        switch self {
        case .continuous:
            "reader.controls.mode.continuous"
        case .singlePage:
            "reader.controls.mode.singlePage"
        case .spread:
            "reader.controls.mode.spread"
        }
    }
}

private enum ReadingDirectionOption {
    case rightToLeft

    var accessibilityIdentifier: String {
        switch self {
        case .rightToLeft:
            "reader.controls.direction.rightToLeft"
        }
    }
}
