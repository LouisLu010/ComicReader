import Foundation
import XCTest
@testable import ComicReader

@MainActor
final class FolderImportCoordinatorTests: XCTestCase {
    func testSuccessfulSelectionUsesNaturalNameOrdering() {
        let coordinator = FolderImportCoordinator()
        let urls = [
            URL(fileURLWithPath: "/tmp/chapter10"),
            URL(fileURLWithPath: "/tmp/chapter2"),
        ]

        coordinator.handle(.success(urls))

        XCTAssertEqual(
            coordinator.status,
            .selected(names: ["chapter2", "chapter10"])
        )
    }

    func testEmptySelectionFailsGracefully() {
        let coordinator = FolderImportCoordinator()

        coordinator.handle(.success([]))

        XCTAssertEqual(coordinator.status, .failed)
    }

    func testResetClearsPreviousSelection() {
        let coordinator = FolderImportCoordinator()
        coordinator.handle(.success([URL(fileURLWithPath: "/tmp/comic")]))

        coordinator.reset()

        XCTAssertEqual(coordinator.status, .idle)
    }
}
