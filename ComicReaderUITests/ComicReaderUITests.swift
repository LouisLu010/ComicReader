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
}
