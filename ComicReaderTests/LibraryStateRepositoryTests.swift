import Foundation
import SwiftData
import XCTest
@testable import ComicReader

final class LibraryStateRepositoryTests: XCTestCase {
    @MainActor
    func testConcurrentConfigurationKeepsSharedRepositoryReady() async throws {
        let container = try makeContainer()
        let repository = LibraryStateRepository()
        let configurationTasks = (0..<4).map { _ in
            Task { @MainActor in
                await repository.configure(modelContainer: container)
            }
        }

        for task in configurationTasks {
            await task.value
        }

        let comic = catalogItem(
            id: managedComicID("00000000-0000-0000-0000-000000000400"),
            title: "Shared State",
            importedAt: .distantPast
        )
        await repository.reconcile(catalogItems: [comic])
        await repository.toggleFavorite(for: comic.id)

        XCTAssertEqual(repository.status, .ready)
        XCTAssertTrue(repository.state(for: comic.id).isFavorite)
    }

    @MainActor
    func testReconcileUpdatesCatalogWithoutOverwritingUserState() async throws {
        let container = try makeContainer()
        let repository = await makeRepository(container: container)
        let comicID = managedComicID("00000000-0000-0000-0000-000000000401")
        let original = catalogItem(
            id: comicID,
            title: "Original Title",
            importedAt: Date(timeIntervalSince1970: 10),
            chapterCount: 2,
            pageCount: 24
        )

        await repository.reconcile(catalogItems: [original])
        await repository.toggleFavorite(for: comicID)
        let progress = LibraryReadingProgress(
            chapterID: "chapter-1",
            pageID: "page-2",
            pageOffset: 0.25,
            zoomScale: 1.5,
            updatedAt: Date(timeIntervalSince1970: 20)
        )
        await assertRecords(progress, for: comicID, using: repository)
        let updatedProgress = LibraryReadingProgress(
            chapterID: "chapter-1",
            pageID: "page-3",
            pageOffset: 0.75,
            zoomScale: 2,
            updatedAt: Date(timeIntervalSince1970: 25)
        )
        await assertRecords(updatedProgress, for: comicID, using: repository)

        let updated = catalogItem(
            id: comicID,
            title: "Updated Title",
            importedAt: Date(timeIntervalSince1970: 30),
            chapterCount: 3,
            pageCount: 36
        )
        await repository.reconcile(catalogItems: [updated])

        XCTAssertEqual(repository.status, .ready)
        XCTAssertEqual(
            repository.state(for: comicID),
            LibraryComicUserState(isFavorite: true, progress: updatedProgress)
        )

        let context = ModelContext(container)
        let storedComics = try context.fetch(
            FetchDescriptor<ComicReaderSchemaV1.StoredComic>()
        )
        let storedComic = try XCTUnwrap(storedComics.first)
        XCTAssertEqual(storedComic.displayName, "Updated Title")
        XCTAssertEqual(storedComic.chapterCount, 3)
        XCTAssertEqual(storedComic.pageCount, 36)
        XCTAssertTrue(storedComic.isFavorite)
        XCTAssertEqual(
            try context.fetch(
                FetchDescriptor<ComicReaderSchemaV1.StoredReadingProgress>()
            ).count,
            1
        )

        let restoredRepository = await makeRepository(container: container)
        XCTAssertEqual(restoredRepository.state(for: comicID).isFavorite, true)
        XCTAssertEqual(
            restoredRepository.state(for: comicID).progress,
            updatedProgress
        )
        await restoredRepository.configure(modelContainer: nil)
        XCTAssertEqual(restoredRepository.status, .unavailable)
        XCTAssertEqual(restoredRepository.state(for: comicID), .empty)
        await restoredRepository.configure(modelContainer: container)
        XCTAssertEqual(restoredRepository.state(for: comicID).isFavorite, true)
    }

    @MainActor
    func testSectionQueriesUseFavoriteAndLatestReadingProgress() async throws {
        let repository = await makeRepository(container: try makeContainer())
        let first = catalogItem(
            id: managedComicID("00000000-0000-0000-0000-000000000402"),
            title: "First",
            importedAt: .distantPast
        )
        let second = catalogItem(
            id: managedComicID("00000000-0000-0000-0000-000000000403"),
            title: "Second",
            importedAt: .distantPast
        )
        let third = catalogItem(
            id: managedComicID("00000000-0000-0000-0000-000000000404"),
            title: "Third",
            importedAt: .distantPast
        )
        let catalogItems = [third, second, first]
        await repository.reconcile(catalogItems: catalogItems)
        await repository.toggleFavorite(for: second.id)
        await repository.toggleFavorite(for: second.id)
        XCTAssertFalse(repository.state(for: second.id).isFavorite)
        await repository.toggleFavorite(for: second.id)
        await repository.toggleFavorite(for: third.id)
        await assertRecords(
            LibraryReadingProgress(
                chapterID: "chapter-1",
                pageID: "page-1",
                pageOffset: 0,
                zoomScale: 1,
                updatedAt: Date(timeIntervalSince1970: 50)
            ),
            for: second.id,
            using: repository
        )
        await assertRecords(
            LibraryReadingProgress(
                chapterID: "chapter-1",
                pageID: "page-1",
                pageOffset: 0,
                zoomScale: 1,
                updatedAt: Date(timeIntervalSince1970: 100)
            ),
            for: first.id,
            using: repository
        )
        await assertRecords(
            LibraryReadingProgress(
                chapterID: "chapter-2",
                pageID: "page-1",
                pageOffset: 0.5,
                zoomScale: 1,
                isCompleted: true,
                updatedAt: Date(timeIntervalSince1970: 200)
            ),
            for: third.id,
            using: repository
        )

        XCTAssertEqual(
            repository.favoriteComics(in: catalogItems).map(\.id),
            [third.id, second.id]
        )
        XCTAssertEqual(
            repository.continueReadingComics(in: catalogItems).map(\.id),
            [first.id, second.id]
        )
        XCTAssertEqual(
            repository.unreadComics(in: catalogItems).map(\.id),
            [second.id, first.id]
        )
    }

    @MainActor
    func testRecordProgressRejectsInvalidValuesAndClampsValidValues() async throws {
        let repository = await makeRepository(container: try makeContainer())
        let comic = catalogItem(
            id: managedComicID("00000000-0000-0000-0000-000000000405"),
            title: "Progress Comic",
            importedAt: .distantPast
        )
        await repository.reconcile(catalogItems: [comic])

        let unknownComicResult = await repository.recordProgress(
            LibraryReadingProgress(
                chapterID: "chapter-1",
                pageID: "page-1",
                pageOffset: 0,
                zoomScale: 1
            ),
            for: managedComicID("00000000-0000-0000-0000-000000000499")
        )
        XCTAssertFalse(unknownComicResult)
        let invalidProgressResult = await repository.recordProgress(
            LibraryReadingProgress(
                chapterID: " ",
                pageID: "page-1",
                pageOffset: 0,
                zoomScale: 1
            ),
            for: comic.id
        )
        XCTAssertFalse(invalidProgressResult)

        await assertRecords(
            LibraryReadingProgress(
                chapterID: "chapter-1",
                pageID: "page-1",
                pageOffset: -1,
                zoomScale: 0
            ),
            for: comic.id,
            using: repository
        )
        let progress = try XCTUnwrap(repository.state(for: comic.id).progress)
        XCTAssertEqual(progress.pageOffset, 0)
        XCTAssertEqual(progress.zoomScale, 0.1)

        await assertRecords(
            LibraryReadingProgress(
                chapterID: "chapter-1",
                pageID: "page-2",
                pageOffset: .nan,
                zoomScale: .infinity
            ),
            for: comic.id,
            using: repository
        )
        let nonFiniteProgress = try XCTUnwrap(
            repository.state(for: comic.id).progress
        )
        XCTAssertEqual(nonFiniteProgress.pageOffset, 0)
        XCTAssertEqual(nonFiniteProgress.zoomScale, 1)

        await assertRecords(
            LibraryReadingProgress(
                chapterID: "chapter-1",
                pageID: "page-3",
                pageOffset: 2,
                zoomScale: 99
            ),
            for: comic.id,
            using: repository
        )
        let upperBoundProgress = try XCTUnwrap(
            repository.state(for: comic.id).progress
        )
        XCTAssertEqual(upperBoundProgress.pageOffset, 1)
        XCTAssertEqual(upperBoundProgress.zoomScale, 16)
    }

    @MainActor
    func testRecordProgressRejectsOlderEventAndRestoresNewestState() async throws {
        let sandboxURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: sandboxURL,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: sandboxURL) }
        let storeURL = sandboxURL.appendingPathComponent("Progress.store")
        let comic = catalogItem(
            id: managedComicID("00000000-0000-0000-0000-000000000411"),
            title: "Last Write Wins Comic",
            importedAt: .distantPast
        )
        let newerProgress = LibraryReadingProgress(
            chapterID: "chapter-2",
            pageID: "page-8",
            pageOffset: 0.75,
            zoomScale: 2,
            isCompleted: true,
            updatedAt: Date(timeIntervalSince1970: 200)
        )
        let olderProgress = LibraryReadingProgress(
            chapterID: "chapter-1",
            pageID: "page-2",
            pageOffset: 0.25,
            zoomScale: 1,
            updatedAt: Date(timeIntervalSince1970: 100)
        )

        do {
            let container = try ComicReaderModelContainer.makeContainer(
                isStoredInMemoryOnly: false,
                storeURL: storeURL
            )
            let repository = await makeRepository(container: container)
            await repository.reconcile(catalogItems: [comic])

            let didRecordNewerProgress = await repository.recordProgress(
                newerProgress,
                for: comic.id
            )
            let didRecordOlderProgress = await repository.recordProgress(
                olderProgress,
                for: comic.id
            )
            XCTAssertTrue(didRecordNewerProgress)
            XCTAssertFalse(didRecordOlderProgress)
            XCTAssertEqual(
                repository.state(for: comic.id).progress,
                newerProgress
            )
        }

        let restoredContainer = try ComicReaderModelContainer.makeContainer(
            isStoredInMemoryOnly: false,
            storeURL: storeURL
        )
        let restoredRepository = await makeRepository(
            container: restoredContainer
        )
        XCTAssertEqual(
            restoredRepository.state(for: comic.id).progress,
            newerProgress
        )
    }

    @MainActor
    func testRecordProgressUsesLastWriteWhenTimestampsMatch() async throws {
        let container = try makeContainer()
        let repository = await makeRepository(container: container)
        let comic = catalogItem(
            id: managedComicID("00000000-0000-0000-0000-000000000412"),
            title: "Equal Timestamp Comic",
            importedAt: .distantPast
        )
        await repository.reconcile(catalogItems: [comic])
        let timestamp = Date(timeIntervalSince1970: 300)
        let firstProgress = LibraryReadingProgress(
            chapterID: "chapter-3",
            pageID: "page-10",
            pageOffset: 1,
            zoomScale: 3,
            isCompleted: true,
            updatedAt: timestamp
        )
        let lastProgress = LibraryReadingProgress(
            chapterID: "chapter-2",
            pageID: "page-4",
            pageOffset: 0.5,
            zoomScale: 1.5,
            updatedAt: timestamp
        )

        let didRecordFirstProgress = await repository.recordProgress(
            firstProgress,
            for: comic.id
        )
        let didRecordLastProgress = await repository.recordProgress(
            lastProgress,
            for: comic.id
        )
        XCTAssertTrue(didRecordFirstProgress)
        XCTAssertTrue(didRecordLastProgress)
        XCTAssertEqual(repository.state(for: comic.id).progress, lastProgress)

        let restoredRepository = await makeRepository(container: container)
        XCTAssertEqual(
            restoredRepository.state(for: comic.id).progress,
            lastProgress
        )
    }

    @MainActor
    func testReconcileDoesNotDiscardStateForTemporarilyMissingCatalogItems() async throws {
        let repository = await makeRepository(container: try makeContainer())
        let retained = catalogItem(
            id: managedComicID("00000000-0000-0000-0000-000000000406"),
            title: "Retained",
            importedAt: .distantPast
        )
        let visible = catalogItem(
            id: managedComicID("00000000-0000-0000-0000-000000000407"),
            title: "Visible",
            importedAt: .distantPast
        )
        await repository.reconcile(catalogItems: [retained, visible])
        await repository.toggleFavorite(for: retained.id)

        await repository.reconcile(catalogItems: [visible])

        XCTAssertTrue(repository.state(for: retained.id).isFavorite)
        XCTAssertEqual(repository.favoriteComics(in: [visible]), [])
    }

    @MainActor
    func testRebuildsAnEmptyDatabaseIndexFromCatalogItems() async throws {
        let container = try makeContainer()
        let first = catalogItem(
            id: managedComicID("00000000-0000-0000-0000-000000000408"),
            title: "First Rebuilt Comic",
            importedAt: Date(timeIntervalSince1970: 10)
        )
        let second = catalogItem(
            id: managedComicID("00000000-0000-0000-0000-000000000409"),
            title: "Second Rebuilt Comic",
            importedAt: Date(timeIntervalSince1970: 20)
        )
        let seedContext = ModelContext(container)
        let seedRepository = await makeRepository(container: container)
        await seedRepository.reconcile(catalogItems: [first, second])
        for storedComic in try seedContext.fetch(
            FetchDescriptor<ComicReaderSchemaV1.StoredComic>()
        ) {
            seedContext.delete(storedComic)
        }
        try seedContext.save()

        let rebuiltContext = ModelContext(container)
        let rebuiltRepository = await makeRepository(container: container)
        await rebuiltRepository.reconcile(catalogItems: [first, second])
        let rebuiltComics = try rebuiltContext.fetch(
            FetchDescriptor<ComicReaderSchemaV1.StoredComic>()
        )

        XCTAssertEqual(
            Set(rebuiltComics.map(\.comicID)),
            Set([first.id.rawValue, second.id.rawValue])
        )
        XCTAssertEqual(rebuiltRepository.status, .ready)
    }

    @MainActor
    func testRebuildsDeletedDiskIndexFromInternalCatalog() async throws {
        let sandboxURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: sandboxURL,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: sandboxURL) }

        let layout = ImportStorageLayout(
            rootURL: sandboxURL.appendingPathComponent(
                "ManagedLibrary",
                isDirectory: true
            )
        )
        let comic = catalogItem(
            id: managedComicID("00000000-0000-0000-0000-000000000410"),
            title: "Disk Rebuilt Comic",
            importedAt: Date(timeIntervalSince1970: 40)
        )
        try write(comic.record, to: layout.libraryCatalogURL(for: comic.id))

        let indexDirectoryURL = sandboxURL.appendingPathComponent(
            "Index",
            isDirectory: true
        )
        let storeURL = indexDirectoryURL.appendingPathComponent("Library.store")
        try FileManager.default.createDirectory(
            at: indexDirectoryURL,
            withIntermediateDirectories: true
        )
        do {
            let seedContainer = try ComicReaderModelContainer.makeContainer(
                isStoredInMemoryOnly: false,
                storeURL: storeURL
            )
            let seedRepository = await makeRepository(
                container: seedContainer
            )
            await seedRepository.reconcile(catalogItems: [comic])
            XCTAssertEqual(seedRepository.status, .ready)
        }

        try FileManager.default.removeItem(at: indexDirectoryURL)
        try FileManager.default.createDirectory(
            at: indexDirectoryURL,
            withIntermediateDirectories: true
        )

        let rebuiltContainer = try ComicReaderModelContainer.makeContainer(
            isStoredInMemoryOnly: false,
            storeURL: storeURL
        )
        let rebuiltRepository = await makeRepository(
            container: rebuiltContainer
        )
        let coordinator = LibraryCatalogCoordinator(
            loader: FileSystemLibraryCatalogLoader(layout: layout),
            layout: layout
        )
        await coordinator.reloadAndReconcile(with: rebuiltRepository)

        let rebuiltRecords = try ModelContext(rebuiltContainer).fetch(
            FetchDescriptor<ComicReaderSchemaV1.StoredComic>()
        )
        XCTAssertEqual(rebuiltRecords.map(\.comicID), [comic.id.rawValue])
        XCTAssertEqual(coordinator.comics.map(\.id), [comic.id])
        XCTAssertEqual(rebuiltRepository.status, .ready)
    }

    private func makeContainer() throws -> ModelContainer {
        try ComicReaderModelContainer.makeContainer(isStoredInMemoryOnly: true)
    }

    @MainActor
    private func makeRepository(
        container: ModelContainer
    ) async -> LibraryStateRepository {
        let repository = LibraryStateRepository()
        await repository.configure(modelContainer: container)
        return repository
    }

    @MainActor
    private func assertRecords(
        _ progress: LibraryReadingProgress,
        for comicID: ManagedComicID,
        using repository: LibraryStateRepository,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let didRecord = await repository.recordProgress(
            progress,
            for: comicID
        )
        XCTAssertTrue(didRecord, file: file, line: line)
    }

    private func write<Value: Encodable>(
        _ value: Value,
        to url: URL
    ) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(value).write(to: url, options: .atomic)
    }

    private func catalogItem(
        id: ManagedComicID,
        title: String,
        importedAt: Date,
        chapterCount: Int = 1,
        pageCount: Int = 12
    ) -> LibraryCatalogItem {
        LibraryCatalogItem(
            record: LibraryCatalogRecord(
                id: id,
                displayName: title,
                sourceRootName: "source",
                importedAt: importedAt,
                chapterCount: chapterCount,
                pageCount: pageCount,
                contentTree: [
                    LibraryCatalogTreeNode(
                        id: "chapter-\(id.rawValue.uuidString)",
                        kind: .chapter,
                        title: "Chapter 1",
                        pageCount: pageCount
                    ),
                ]
            ),
            thumbnailAvailable: false
        )
    }

    private func managedComicID(_ value: String) -> ManagedComicID {
        ManagedComicID(rawValue: UUID(uuidString: value)!)
    }
}
