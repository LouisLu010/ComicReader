import Foundation
import SwiftData
import XCTest
@testable import ComicReader

final class ComicReaderMigrationTests: XCTestCase {
    @MainActor
    func testMigratesV1DiskStoreToLatestSchemaWithDefaults() async throws {
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
            FetchDescriptor<ComicReaderSchemaV4.StoredComic>()
        )
        let migratedProgress = try migratedContext.fetch(
            FetchDescriptor<ComicReaderSchemaV4.StoredReadingProgress>()
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
        XCTAssertEqual(progress.completedChapterIDs, [])
        XCTAssertTrue(progress.isCompleted)
        XCTAssertEqual(progress.updatedAt, updatedAt)

        let repository = LibraryStateRepository()
        await repository.configure(modelContainer: migratedContainer)
        XCTAssertEqual(
            repository.readerOverrides(
                for: ManagedComicID(rawValue: identifier)
            ),
            ComicReaderOverrides(
                readingMode: .continuous,
                readingDirection: .leftToRight
            )
        )
    }

    func testMigratesV2DiskStoreToLatestWithEmptyCompletedChapters() throws {
        let sandboxURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: sandboxURL) }
        let storeURL = sandboxURL.appendingPathComponent("Migration.store")
        let identifier = UUID()
        let importedAt = Date(timeIntervalSince1970: 3_000)
        let updatedAt = Date(timeIntervalSince1970: 4_000)

        try createV2Store(
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
            FetchDescriptor<ComicReaderSchemaV4.StoredComic>()
        )
        let migratedProgress = try migratedContext.fetch(
            FetchDescriptor<ComicReaderSchemaV4.StoredReadingProgress>()
        )
        let comic = try XCTUnwrap(migratedComics.first)
        let progress = try XCTUnwrap(migratedProgress.first)

        XCTAssertEqual(migratedComics.count, 1)
        XCTAssertEqual(comic.comicID, identifier)
        XCTAssertEqual(comic.displayName, "V2 Comic")
        XCTAssertEqual(comic.importedAt, importedAt)
        XCTAssertEqual(migratedProgress.count, 1)
        XCTAssertEqual(progress.comicID, identifier)
        XCTAssertEqual(progress.chapterID, "chapter-3")
        XCTAssertEqual(progress.pageID, "page-18")
        XCTAssertEqual(progress.pageOffset, 0.75)
        XCTAssertEqual(progress.zoomScale, 3)
        XCTAssertEqual(progress.readingModeRawValue, "spread")
        XCTAssertEqual(progress.readingDirectionRawValue, "rightToLeft")
        XCTAssertEqual(progress.completedChapterIDs, [])
        XCTAssertFalse(progress.isCompleted)
        XCTAssertEqual(progress.updatedAt, updatedAt)
    }

    @MainActor
    func testMigratesV3ReaderPreferencesIntoComicOverridesOnlyOnce() async throws {
        let sandboxURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: sandboxURL) }
        let storeURL = sandboxURL.appendingPathComponent("Migration.store")
        let identifier = UUID()
        let comicID = ManagedComicID(rawValue: identifier)

        try createV3Store(
            at: storeURL,
            comicID: identifier,
            readingModeRawValue: ReadingMode.spread.rawValue,
            readingDirectionRawValue: ReadingDirection.rightToLeft.rawValue
        )

        do {
            let migratedContainer = try ComicReaderModelContainer.makeContainer(
                isStoredInMemoryOnly: false,
                storeURL: storeURL
            )
            let migratedContext = ModelContext(migratedContainer)
            let migratedComic = try XCTUnwrap(
                try migratedContext.fetch(
                    FetchDescriptor<ComicReaderSchemaV4.StoredComic>()
                ).first
            )
            XCTAssertNil(migratedComic.readingModeOverrideRawValue)
            XCTAssertNil(migratedComic.readingDirectionOverrideRawValue)
            XCTAssertTrue(
                try migratedContext.fetch(
                    FetchDescriptor<
                        ComicReaderSchemaV4.StoredReaderGlobalPreferences
                    >()
                ).isEmpty
            )

            let repository = LibraryStateRepository()
            await repository.configure(modelContainer: migratedContainer)

            XCTAssertEqual(
                repository.readerOverrides(for: comicID),
                ComicReaderOverrides(
                    readingMode: .spread,
                    readingDirection: .rightToLeft
                )
            )
            let backfilledContext = ModelContext(migratedContainer)
            let preferencesRecord = try XCTUnwrap(
                try backfilledContext.fetch(
                    FetchDescriptor<
                        ComicReaderSchemaV4.StoredReaderGlobalPreferences
                    >()
                ).first
            )
            XCTAssertEqual(
                preferencesRecord.legacyProgressPreferencesBackfillVersion,
                1
            )

            let didClearMode = await repository.setReadingModeOverride(
                nil,
                for: comicID
            )
            let didClearDirection = await repository
                .setReadingDirectionOverride(nil, for: comicID)
            XCTAssertTrue(didClearMode)
            XCTAssertTrue(didClearDirection)
            XCTAssertEqual(repository.readerOverrides(for: comicID), .none)

            let progress = try XCTUnwrap(
                try backfilledContext.fetch(
                    FetchDescriptor<ComicReaderSchemaV4.StoredReadingProgress>()
                ).first
            )
            progress.readingModeRawValue = ReadingMode.continuous.rawValue
            progress.readingDirectionRawValue = (
                ReadingDirection.leftToRight.rawValue
            )
            try backfilledContext.save()
            await repository.configure(modelContainer: nil)
        }

        let reopenedContainer = try ComicReaderModelContainer.makeContainer(
            isStoredInMemoryOnly: false,
            storeURL: storeURL
        )
        let restoredRepository = LibraryStateRepository()
        await restoredRepository.configure(modelContainer: reopenedContainer)

        XCTAssertEqual(
            restoredRepository.readerOverrides(for: comicID),
            .none
        )
        let reopenedContext = ModelContext(reopenedContainer)
        let preferencesRecords = try reopenedContext.fetch(
            FetchDescriptor<
                ComicReaderSchemaV4.StoredReaderGlobalPreferences
            >()
        )
        XCTAssertEqual(preferencesRecords.count, 1)
        XCTAssertEqual(
            preferencesRecords.first?
                .legacyProgressPreferencesBackfillVersion,
            1
        )
    }

    func testCreatesTheVersionedV4ModelContainer() throws {
        let container = try ComicReaderModelContainer.makeContainer(
            isStoredInMemoryOnly: true
        )
        let context = ModelContext(container)
        let identifier = UUID()
        context.insert(
            ComicReaderSchemaV4.StoredComic(
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
            FetchDescriptor<ComicReaderSchemaV4.StoredComic>()
        )

        XCTAssertEqual(storedComics.map(\.comicID), [identifier])
    }

    func testReopensTheVersionedV4DiskStore() throws {
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
                ComicReaderSchemaV4.StoredComic(
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
            FetchDescriptor<ComicReaderSchemaV4.StoredComic>()
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
                ComicReaderSchemaV4.StoredComic(
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
            ComicReaderSchemaV4.StoredComic(
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
            FetchDescriptor<ComicReaderSchemaV4.StoredComic>()
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

    private func createV2Store(
        at storeURL: URL,
        comicID: UUID,
        importedAt: Date,
        updatedAt: Date
    ) throws {
        let schema = Schema(versionedSchema: ComicReaderSchemaV2.self)
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
            ComicReaderSchemaV2.StoredComic(
                comicID: comicID,
                displayName: "V2 Comic",
                sourceRootName: "v2-source",
                importedAt: importedAt,
                chapterCount: 3,
                pageCount: 36
            )
        )
        context.insert(
            ComicReaderSchemaV2.StoredReadingProgress(
                comicID: comicID,
                chapterID: "chapter-3",
                pageID: "page-18",
                pageOffset: 0.75,
                zoomScale: 3,
                readingModeRawValue: "spread",
                readingDirectionRawValue: "rightToLeft",
                isCompleted: false,
                updatedAt: updatedAt
            )
        )
        try context.save()
    }

    private func createV3Store(
        at storeURL: URL,
        comicID: UUID,
        readingModeRawValue: String,
        readingDirectionRawValue: String
    ) throws {
        let schema = Schema(versionedSchema: ComicReaderSchemaV3.self)
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
            ComicReaderSchemaV3.StoredComic(
                comicID: comicID,
                displayName: "V3 Preference Comic",
                sourceRootName: "v3-source",
                importedAt: .distantPast,
                chapterCount: 1,
                pageCount: 12
            )
        )
        context.insert(
            ComicReaderSchemaV3.StoredReadingProgress(
                comicID: comicID,
                chapterID: "chapter-1",
                pageID: "page-4",
                pageOffset: 0.25,
                zoomScale: 1,
                readingModeRawValue: readingModeRawValue,
                readingDirectionRawValue: readingDirectionRawValue,
                isCompleted: false,
                updatedAt: Date(timeIntervalSince1970: 5_000)
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
