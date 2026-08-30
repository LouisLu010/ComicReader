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

    func testLibrarySearchFiltersAndRestoresComics() {
        let app = XCUIApplication()
        app.launchEnvironment["COMICREADER_UI_TEST_FIXTURE"] = (
            "reader-navigation"
        )
        app.launchArguments += [
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US",
        ]
        app.launch()

        let comicButton = app.buttons[
            "library.comic.00000000-0000-0000-0000-000000000901"
        ]
        XCTAssertTrue(comicButton.waitForExistence(timeout: 10))

        let searchField = app.searchFields.firstMatch
        XCTAssertTrue(searchField.waitForExistence(timeout: 5))
        searchField.tap()
        searchField.typeText("zzz")

        let comicDisappeared = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: comicButton
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [comicDisappeared], timeout: 5),
            .completed
        )

        searchField.typeText(
            String(repeating: XCUIKeyboardKey.delete.rawValue, count: 3)
        )
        XCTAssertTrue(comicButton.waitForExistence(timeout: 5))
    }

    func testTrashFlowRestoresComicFromSidebar() {
        let app = XCUIApplication()
        app.launchEnvironment["COMICREADER_UI_TEST_FIXTURE"] = (
            "reader-navigation"
        )
        app.launchArguments += [
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US",
        ]
        app.launch()

        let comicIdentifier = (
            "library.comic.00000000-0000-0000-0000-000000000901"
        )
        let comicButton = app.buttons[comicIdentifier]
        XCTAssertTrue(comicButton.waitForExistence(timeout: 10))
        comicButton.tap()

        let trashButton = app.buttons["library.detail.trash"]
        XCTAssertTrue(trashButton.waitForExistence(timeout: 5))
        trashButton.tap()

        let comicDisappeared = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: comicButton
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [comicDisappeared], timeout: 5),
            .completed
        )

        let sidebarTrash = hittableSidebarItem("sidebar.trash", in: app)
        XCTAssertTrue(sidebarTrash.waitForExistence(timeout: 5))
        sidebarTrash.tap()
        let trashRow = app.descendants(matching: .any)[
            "library.trash.comic.00000000-0000-0000-0000-000000000901"
        ].firstMatch
        let rowAppeared = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == true"),
            object: trashRow
        )
        if XCTWaiter.wait(for: [rowAppeared], timeout: 5) != .completed {
            let emptyState = app.descendants(matching: .any)[
                "library.trash.empty"
            ].firstMatch
            let grid = app.descendants(matching: .any)["library.grid"].firstMatch
            XCTFail(
                "trash row missing; emptyState=\(emptyState.exists); "
                    + "grid=\(grid.exists); "
                    + "rows=\(libraryTrashRowCount(app))"
            )
            return
        }

        let restoreButton = app.descendants(matching: .any)[
            "library.trash.restore.00000000-0000-0000-0000-000000000901"
        ].firstMatch
        XCTAssertTrue(restoreButton.waitForExistence(timeout: 5))
        restoreButton.tap()

        hittableSidebarItem("sidebar.all", in: app).tap()
        XCTAssertTrue(comicButton.waitForExistence(timeout: 10))
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
            let setting = app.buttons[identifier]
            XCTAssertTrue(waitUntilHittable(setting, timeout: 8))
        }

        let defaultMode = app.buttons["settings.reader.defaultMode"]
        defaultMode.tap()
        let singlePage = app.buttons["settings.reader.defaultMode.singlePage"]
        XCTAssertTrue(waitUntilHittable(singlePage))
        singlePage.tap()
        XCTAssertTrue(waitUntilHittable(defaultMode, timeout: 8))
        XCTAssertTrue(waitForValue("Single Page", of: defaultMode))

        let leftTap = app.buttons["settings.reader.tapArea.left"]
        leftTap.tap()
        let disabled = app.buttons["settings.reader.tapArea.left.disabled"]
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
                of: app.buttons["settings.reader.defaultMode"],
                timeout: 8
            )
        )
        XCTAssertTrue(
            waitForValue(
                "Disabled",
                of: app.buttons["settings.reader.tapArea.left"],
                timeout: 8
            )
        )
    }

    private func openSettings(in app: XCUIApplication) {
        let settings = app.buttons["app.settings"]
        XCTAssertTrue(waitUntilHittable(settings, timeout: 8))
        settings.tap()
    }

    /// 侧边栏可能在折叠状态启动；展开后同一分区可能同时存在
    /// 多个可访问元素，只取可点击的那个。
    @discardableResult
    private func hittableSidebarItem(
        _ identifier: String,
        in app: XCUIApplication
    ) -> XCUIElement {
        let query = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == %@", identifier))
        if let hittable = query.allElementsBoundByIndex.first(where: {
            $0.isHittable
        }) {
            return hittable
        }

        // 模拟器可能以折叠侧边栏启动，先展开再重新查找。
        app.buttons["ToggleSidebar"].tap()
        if let hittable = query.allElementsBoundByIndex.first(where: {
            $0.isHittable
        }) {
            return hittable
        }

        return query.firstMatch
    }

    private func libraryTrashRowCount(_ app: XCUIApplication) -> Int {
        app.descendants(matching: .any)
            .matching(NSPredicate(
                format: "identifier BEGINSWITH 'library.trash.comic.'"
            ))
            .count
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
