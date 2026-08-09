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
        XCTAssertTrue(waitForCurrentPage("3/5", in: app))

        slider.adjust(toNormalizedSliderPosition: 1)
        XCTAssertTrue(waitForCurrentPage("5/5", in: app))

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
        XCTAssertTrue(waitForCurrentPage("4/5", in: app))
    }

    func testReaderFixtureSelectsReadingModes() {
        let app = launchReaderFixture()
        let chapterOnePageTwo = app.buttons[
            "reader.thumbnail.ui-chapter-one-page-two"
        ]
        XCTAssertTrue(waitUntilHittable(chapterOnePageTwo))
        chapterOnePageTwo.tap()
        XCTAssertTrue(waitForCurrentPage("3/5", in: app))

        selectMode(.singlePage, in: app)
        XCTAssertTrue(waitForCurrentPage("3/5", in: app))

        selectMode(.continuous, in: app)
        XCTAssertTrue(waitForCurrentPage("3/5", in: app))

        selectMode(.spread, in: app)
        XCTAssertTrue(waitForCurrentPage("3/5", in: app))

        let landscapePage = app.buttons[
            "reader.thumbnail.ui-chapter-two-page-one"
        ]
        XCTAssertTrue(waitUntilHittable(landscapePage))
        landscapePage.tap()
        XCTAssertTrue(waitForCurrentPage("4/5", in: app))
    }

    func testReaderTapAreasNavigateAndMirrorRightToLeft() {
        let app = launchReaderFixture()
        selectMode(.singlePage, in: app)
        XCTAssertTrue(waitForCurrentPage("1/5", in: app))

        let tapSurface = singlePageSurface(in: app)
        tap(horizontalOffset: 0.9, on: tapSurface)
        XCTAssertTrue(waitForCurrentPage("2/5", in: app))

        selectDirection(.rightToLeft, in: app)
        tap(horizontalOffset: 0.1, on: tapSurface)
        XCTAssertTrue(waitForCurrentPage("3/5", in: app))
    }

    func testReaderTapAreasToggleControls() {
        let app = launchReaderFixture()
        selectMode(.singlePage, in: app)
        XCTAssertTrue(waitForCurrentPage("1/5", in: app))
        let tapSurface = singlePageSurface(in: app)
        let menu = app.buttons["reader.controls.menu"]
        let reveal = app.buttons["reader.controls.reveal"]

        XCTAssertTrue(waitUntilHittable(menu))

        tap(horizontalOffset: 0.5, on: tapSurface)
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

        let tapSurface = singlePageSurface(in: app)
        doubleTap(horizontalOffset: 0.9, on: tapSurface)

        XCTAssertTrue(waitForCurrentPage("1/5", in: app))

        tap(horizontalOffset: 0.9, on: tapSurface)
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
        XCTAssertTrue(waitForCurrentPage("1/5", in: app))
        return app
    }

    private func selectMode(_ mode: Mode, in app: XCUIApplication) {
        let menu = app.buttons["reader.controls.menu"]
        XCTAssertTrue(waitUntilHittable(menu))
        menu.tap()

        let option = element(mode.accessibilityIdentifier, in: app)
        XCTAssertTrue(waitUntilHittable(option))
        option.tap()

        XCTAssertTrue(waitUntilHittable(menu))
        menu.tap()
        let selectedOption = element(mode.accessibilityIdentifier, in: app)
        XCTAssertTrue(waitUntilSelected(selectedOption))
        selectedOption.tap()
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

        XCTAssertTrue(waitUntilHittable(menu))
        menu.tap()
        let selectedOption = element(
            direction.accessibilityIdentifier,
            in: app
        )
        XCTAssertTrue(waitUntilSelected(selectedOption))
        selectedOption.tap()
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

    private func waitUntilSelected(
        _ element: XCUIElement,
        timeout: TimeInterval = 8
    ) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                element.exists && element.isSelected
            },
            object: element
        )
        return XCTWaiter.wait(for: [expectation], timeout: timeout)
            == .completed
    }

    private func singlePageSurface(in app: XCUIApplication) -> XCUIElement {
        let surfaces = app.scrollViews.matching(identifier: "reader.singlePage")
        let surface = surfaces.element
        XCTAssertTrue(surface.waitForExistence(timeout: 8))
        XCTAssertEqual(surfaces.count, 1)
        return surface
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
