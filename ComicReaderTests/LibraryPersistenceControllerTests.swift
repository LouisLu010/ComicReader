import Foundation
import XCTest
@testable import ComicReader

final class LibraryPersistenceControllerTests: XCTestCase {
    @MainActor
    func testOpenedStoreStartsReadyWithoutRecoveryAction() async throws {
        let container = try ComicReaderModelContainer.makeContainer(
            isStoredInMemoryOnly: true
        )
        let controller = LibraryPersistenceController(
            openResult: .opened(container)
        )

        XCTAssertEqual(controller.status, .ready)
        XCTAssertTrue(controller.modelContainer === container)
        XCTAssertFalse(controller.canRecoverFailedIndex)
        let didRecover = await controller.recoverFailedIndex()
        XCTAssertFalse(didRecover)
    }

    @MainActor
    func testExplicitRecoveryReopensFailedStore() async throws {
        let sandboxURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: sandboxURL) }
        let storeURL = sandboxURL.appendingPathComponent("Library.store")
        try Data("corrupt-store".utf8).write(to: storeURL)

        let controller = LibraryPersistenceController(
            openResult: ComicReaderModelContainer.openDiskContainer(
                storeURL: storeURL
            ),
            reopen: {
                ComicReaderModelContainer.openDiskContainer(
                    storeURL: storeURL
                )
            }
        )

        XCTAssertEqual(controller.status, .recoveryRequired)
        XCTAssertNil(controller.modelContainer)
        XCTAssertTrue(controller.canRecoverFailedIndex)

        let didRecover = await controller.recoverFailedIndex()

        XCTAssertTrue(didRecover)
        XCTAssertEqual(controller.status, .ready)
        XCTAssertNotNil(controller.modelContainer)
        XCTAssertFalse(controller.canRecoverFailedIndex)
    }

    @MainActor
    func testRecoveryFailureKeepsExplicitRetryAvailable() async throws {
        let sandboxURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: sandboxURL) }
        let storeURL = sandboxURL.appendingPathComponent(
            "Unsafe.store",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: storeURL,
            withIntermediateDirectories: true
        )
        let sentinelURL = storeURL.appendingPathComponent("sentinel.txt")
        let sentinelData = Data("keep-me".utf8)
        try sentinelData.write(to: sentinelURL)

        let controller = LibraryPersistenceController(
            openResult: ComicReaderModelContainer.openDiskContainer(
                storeURL: storeURL
            ),
            reopen: {
                ComicReaderModelContainer.openDiskContainer(
                    storeURL: storeURL
                )
            }
        )

        let didRecover = await controller.recoverFailedIndex()

        XCTAssertFalse(didRecover)
        XCTAssertEqual(controller.status, .recoveryFailed)
        XCTAssertNil(controller.modelContainer)
        XCTAssertTrue(controller.canRecoverFailedIndex)
        XCTAssertEqual(try Data(contentsOf: sentinelURL), sentinelData)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true
        )
        return url
    }
}
