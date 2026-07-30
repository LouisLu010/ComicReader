import Foundation
import SwiftData
import XCTest
@testable import ComicReader

final class ComicReaderMigrationTests: XCTestCase {
    func testCreatesTheVersionedV1ModelContainer() throws {
        let container = try ComicReaderModelContainer.makeContainer(
            isStoredInMemoryOnly: true
        )
        let context = ModelContext(container)
        let identifier = UUID()
        context.insert(
            ComicReaderSchemaV1.StoredComic(
                comicID: identifier,
                displayName: "Schema Comic",
                sourceRootName: "schema-source",
                importedAt: .distantPast,
                chapterCount: 1,
                pageCount: 1
            )
        )
        try context.save()

        let storedComics = try context.fetch(
            FetchDescriptor<ComicReaderSchemaV1.StoredComic>()
        )

        XCTAssertEqual(storedComics.map(\.comicID), [identifier])
    }

    func testReopensTheVersionedV1DiskStore() throws {
        let sandboxURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: sandboxURL) }
        let storeURL = sandboxURL.appendingPathComponent("Migration.store")
        let identifier = UUID()

        do {
            let container = try ComicReaderModelContainer.makeContainer(
                isStoredInMemoryOnly: false,
                storeURL: storeURL
            )
            let context = ModelContext(container)
            context.insert(
                ComicReaderSchemaV1.StoredComic(
                    comicID: identifier,
                    displayName: "Reopened Comic",
                    sourceRootName: "reopened-source",
                    importedAt: .distantPast,
                    chapterCount: 2,
                    pageCount: 24
                )
            )
            try context.save()
        }

        let reopenedContainer = try ComicReaderModelContainer.makeContainer(
            isStoredInMemoryOnly: false,
            storeURL: storeURL
        )
        let reopenedContext = ModelContext(reopenedContainer)
        let reopenedComics = try reopenedContext.fetch(
            FetchDescriptor<ComicReaderSchemaV1.StoredComic>()
        )

        XCTAssertEqual(reopenedComics.map(\.comicID), [identifier])
        XCTAssertEqual(reopenedComics.first?.displayName, "Reopened Comic")
    }

    func testFailedDiskOpenPreservesStoreUntilExplicitRecovery() throws {
        let sandboxURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: sandboxURL) }

        let indexDirectoryURL = sandboxURL.appendingPathComponent(
            "Index",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: indexDirectoryURL,
            withIntermediateDirectories: true
        )
        let storeURL = indexDirectoryURL.appendingPathComponent("Library.store")
        do {
            let container = try ComicReaderModelContainer.makeContainer(
                isStoredInMemoryOnly: false,
                storeURL: storeURL
            )
            let context = ModelContext(container)
            context.insert(
                ComicReaderSchemaV1.StoredComic(
                    comicID: UUID(),
                    displayName: "Soon Corrupted Comic",
                    sourceRootName: "corrupt-source",
                    importedAt: .distantPast,
                    chapterCount: 1,
                    pageCount: 1
                )
            )
            try context.save()
        }
        let sidecarURLs = ["-wal", "-shm", "-journal"].map { suffix in
            URL(fileURLWithPath: storeURL.path + suffix)
        }
        for sidecarURL in sidecarURLs
        where FileManager.default.fileExists(atPath: sidecarURL.path) {
            try FileManager.default.removeItem(at: sidecarURL)
        }
        let corruptStoreData = Data("not-a-sqlite-store".utf8)
        try corruptStoreData.write(to: storeURL)
        let neighboringIndexURL = indexDirectoryURL.appendingPathComponent(
            "Library.store-backup"
        )
        let neighboringIndexData = Data("neighbor-sentinel".utf8)
        try neighboringIndexData.write(to: neighboringIndexURL)

        let catalogURL = sandboxURL
            .appendingPathComponent("ManagedLibrary", isDirectory: true)
            .appendingPathComponent("library-catalog.json")
        try FileManager.default.createDirectory(
            at: catalogURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let catalogData = Data("catalog-sentinel".utf8)
        try catalogData.write(to: catalogURL)

        let sourceURL = sandboxURL
            .appendingPathComponent("Source", isDirectory: true)
            .appendingPathComponent("page.jpg")
        try FileManager.default.createDirectory(
            at: sourceURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let sourceData = Data("source-sentinel".utf8)
        try sourceData.write(to: sourceURL)

        let failedOpen = ComicReaderModelContainer.openDiskContainer(
            storeURL: storeURL
        )
        let recovery = try XCTUnwrap(recovery(from: failedOpen))

        XCTAssertEqual(try Data(contentsOf: storeURL), corruptStoreData)

        for sidecarURL in sidecarURLs {
            try Data("sidecar".utf8).write(to: sidecarURL)
        }

        let report = try ComicReaderModelContainer.deleteFailedStoreIndex(
            recovery
        )

        XCTAssertEqual(report.removedFileCount, 4)
        XCTAssertFalse(FileManager.default.fileExists(atPath: storeURL.path))
        for sidecarURL in sidecarURLs {
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: sidecarURL.path)
            )
        }
        XCTAssertEqual(try Data(contentsOf: catalogURL), catalogData)
        XCTAssertEqual(try Data(contentsOf: sourceURL), sourceData)
        XCTAssertEqual(
            try Data(contentsOf: neighboringIndexURL),
            neighboringIndexData
        )

        let repeatedReport = try ComicReaderModelContainer
            .deleteFailedStoreIndex(recovery)
        XCTAssertEqual(repeatedReport.removedFileCount, 0)

        let recoveredOpen = ComicReaderModelContainer.openDiskContainer(
            storeURL: storeURL
        )
        let recoveredContainer = try XCTUnwrap(container(from: recoveredOpen))
        let context = ModelContext(recoveredContainer)
        let identifier = UUID()
        context.insert(
            ComicReaderSchemaV1.StoredComic(
                comicID: identifier,
                displayName: "Recovered Comic",
                sourceRootName: "recovered-source",
                importedAt: .distantPast,
                chapterCount: 1,
                pageCount: 12
            )
        )
        try context.save()

        let recoveredComics = try context.fetch(
            FetchDescriptor<ComicReaderSchemaV1.StoredComic>()
        )
        XCTAssertEqual(recoveredComics.map(\.comicID), [identifier])
    }

    func testExplicitRecoveryRefusesToDeleteAStoreDirectory() throws {
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
        let sentinelData = Data("must-remain".utf8)
        try sentinelData.write(to: sentinelURL)

        let failedOpen = ComicReaderModelContainer.openDiskContainer(
            storeURL: storeURL
        )
        let recovery = try XCTUnwrap(recovery(from: failedOpen))

        XCTAssertThrowsError(
            try ComicReaderModelContainer.deleteFailedStoreIndex(recovery)
        ) { error in
            XCTAssertEqual(
                error as? ComicReaderModelStoreRecoveryError,
                .unsafeStoreEntry
            )
        }
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

    private func recovery(
        from result: ComicReaderModelContainerOpenResult
    ) -> ComicReaderModelStoreRecovery? {
        guard case let .recoveryRequired(recovery) = result else {
            return nil
        }
        return recovery
    }

    private func container(
        from result: ComicReaderModelContainerOpenResult
    ) -> ModelContainer? {
        guard case let .opened(container) = result else {
            return nil
        }
        return container
    }
}
