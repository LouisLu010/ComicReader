import XCTest
@testable import ComicReader

@MainActor
final class AppRouterTests: XCTestCase {
    func testDefaultsToAllComicsWithoutPresentedImporter() {
        let router = AppRouter()

        XCTAssertEqual(router.selectedSection, .all)
        XCTAssertNil(router.presentedImporter)
    }

    func testAllSidebarSectionsHaveStableUniqueIdentifiers() {
        let identifiers = LibrarySection.allCases.map(\.id)

        XCTAssertEqual(Set(identifiers).count, identifiers.count)
        XCTAssertEqual(LibrarySection.librarySections.count, 7)
        XCTAssertFalse(LibrarySection.librarySections.contains(.settings))
        XCTAssertTrue(LibrarySection.librarySections.contains(.trash))
    }

    func testRouterStateIsIndependentPerSceneInstance() {
        let firstWindowRouter = AppRouter()
        let secondWindowRouter = AppRouter()

        firstWindowRouter.selectedSection = .favorites
        firstWindowRouter.presentedImporter = .folders

        XCTAssertEqual(secondWindowRouter.selectedSection, .all)
        XCTAssertNil(secondWindowRouter.presentedImporter)
    }
}
