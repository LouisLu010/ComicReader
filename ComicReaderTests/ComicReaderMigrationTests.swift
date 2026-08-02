import Foundation
import SwiftData
import XCTest
@testable import ComicReader

final class ComicReaderMigrationTests: XCTestCase {
    func testMigratesV1DiskStoreToV2WithReadingPreferenceDefaults() throws {
        let sandboxURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: sandboxURL) }
        let storeURL = sandboxURL.appendingPathComponent("Migration.store")
        let identifier = UUID()
        let importedAt = Date(timeIntervalSince1970: 1_000)
        let updatedAt = Date(timeIntervalSince1970: 2_000)

        try createV1Store(
            at: storeURL,
            comicID: identifier,
            importedAt: importedAt,
            updatedAt: updatedAt
        )

        let migratedContainer = try ComicReaderModelContainer.makeContainer(
            isStoredInMemoryOnly: false,
            storeURL: storeURL
        )
        let migratedContext = ModelContext(migratedContainer)
        let migratedComics = try migratedContext.fetch(
            FetchDescriptor<ComicReaderSchemaV2.StoredComic>()
        )
        let migratedProgress = try migratedContext.fetch(
            FetchDescriptor<ComicReaderSchemaV2.StoredReadingProgress>()
        )

        let comic = try XCTUnwrap(migratedComics.first)
        XCTAssertEqual(migratedComics.count, 1)
        XCTAssertEqual(comic.comicID, identifier)
        XCTAssertEqual(comic.displayName, "Migrated Comic")
        XCTAssertEqual(comic.sourceRootName, "migrated-source")
        XCTAssertEqual(comic.importedAt, importedAt)
        XCTAssertEqual(comic.chapterCount, 2)
        XCTAssertEqual(comic.pageCount, 24)
        XCTAssertTrue(comic.isFavorite)

        let progress = try XCTUnwrap(migratedProgress.first)
        XCTAssertEqual(migratedProgress.count, 1)
        XCTAssertEqual(progress.comicID, identifier)
        XCTAssertEqual(progress.chapterID, "chapter-2")
        XCTAssertEqual(progress.pageID, "page-12")
        XCTAssertEqual(progress.pageOffset, 0.625)
        XCTAssertEqual(progress.zoomScale, 2.5)
        XCTAssertEqual(progress.readingModeRawValue, "continuous")
        XCTAssertEqual(progress.readingDirectionRawValue, "leftToRight")
        XCTAssertTrue(progress.isCompleted)
        XCTAssertEqual(progress.updatedAt, updatedAt)
    }

    func testCreatesTheVersionedV2ModelContainer() throws {
        let container = try ComicReaderModelContainer.makeContainer(
            isStoredInMemoryOnly: true
        )
        let context = ModelContext(container)
        let identifier = UUID()
        context.insert(
            ComicReaderSchemaV2.StoredComic(
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
            FetchDescriptor<ComicReaderSchemaV2.StoredComic>()
        )

        XCTAssertEqual(storedComics.map(\.comicID), [identifier])
    }

    func testReopensTheVersionedV2DiskStore() throws {
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
                ComicReaderSchemaV2.StoredComic(
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
            FetchDescriptor<ComicReaderSchemaV2.StoredComic>()
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
                ComicReaderSchemaV2.StoredComic(
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
            ComicReaderSchemaV2.StoredComic(
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
            FetchDescriptor<ComicReaderSchemaV2.StoredComic>()
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

    private func createV1Store(
        at storeURL: URL,
        comicID: UUID,
        importedAt: Date,
        updatedAt: Date
    ) throws {
        let schema = Schema(versionedSchema: ComicReaderSchemaV1.self)
        let configuration = ModelConfiguration(
            schema: schema,
            url: storeURL,
            cloudKitDatabase: .none
        )
        let container = try ModelContainer(
            for: schema,
            migrationPlan: nil,
            configurations: [configuration]
        )
        let context = ModelContext(container)
        context.insert(
            ComicReaderSchemaV1.StoredComic(
                comicID: comicID,
                displayName: "Migrated Comic",
                sourceRootName: "migrated-source",
                importedAt: importedAt,
                chapterCount: 2,
                pageCount: 24,
                isFavorite: true
            )
        )
        context.insert(
            ComicReaderSchemaV1.StoredReadingProgress(
                comicID: comicID,
                chapterID: "chapter-2",
                pageID: "page-12",
                pageOffset: 0.625,
                zoomScale: 2.5,
                isCompleted: true,
                updatedAt: updatedAt
            )
        )
        try context.save()
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
