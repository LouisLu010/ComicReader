import Foundation
import SwiftData
import XCTest
@testable import ComicReader

final class LibraryStateRepositoryTests: XCTestCase {
    func testReadingProgressDefaultsToContinuousLeftToRight() {
        let progress = LibraryReadingProgress(
            chapterID: "chapter-1",
            pageID: "page-1",
            pageOffset: 0,
            zoomScale: 1
        )

        XCTAssertEqual(progress.readingMode, .continuous)
        XCTAssertEqual(progress.readingDirection, .leftToRight)
        XCTAssertEqual(progress.completedChapterIDs, [])
    }

    func testReadingProgressNormalizesCompletedChapterIDs() {
        let progress = LibraryReadingProgress(
            chapterID: "chapter-2",
            pageID: "page-1",
            pageOffset: 0,
            zoomScale: 1,
            completedChapterIDs: [
                " chapter-1 ",
                "chapter-1",
                "\nchapter-2\t",
                "",
                " \n ",
            ]
        )

        XCTAssertEqual(
            progress.completedChapterIDs,
            ["chapter-1", "chapter-2"]
        )
    }

    @MainActor
    func testPreferenceWritesFailSafelyWithoutAConfiguredStore() async {
        let repository = LibraryStateRepository()

        let didSetMode = await repository.setDefaultReadingMode(.spread)
        let didSetDirection = await repository.setDefaultReadingDirection(
            .rightToLeft
        )
        let didSetTap = await repository.setTapZoneAction(
            .disabled,
            isLeftZone: true
        )

        XCTAssertFalse(didSetMode)
        XCTAssertFalse(didSetDirection)
        XCTAssertFalse(didSetTap)
        XCTAssertEqual(repository.status, .unavailable)
        XCTAssertFalse(repository.isWriteAvailable)
        XCTAssertEqual(repository.globalReaderPreferences, .default)
    }

    @MainActor
    func testComicPreferenceWritesRejectUnknownComicWithoutDisablingStore() async throws {
        let repository = await makeRepository(container: try makeContainer())
        let unknownComicID = managedComicID(
            "00000000-0000-0000-0000-000000000422"
        )

        let didSetMode = await repository.setReadingModeOverride(
            .spread,
            for: unknownComicID
        )
        let didSetDirection = await repository.setReadingDirectionOverride(
            .rightToLeft,
            for: unknownComicID
        )

        XCTAssertFalse(didSetMode)
        XCTAssertFalse(didSetDirection)
        XCTAssertEqual(repository.status, .ready)
        XCTAssertTrue(repository.isWriteAvailable)
        XCTAssertEqual(repository.readerOverrides(for: unknownComicID), .none)
    }

    @MainActor
    func testGlobalPreferencesIgnoreRecordsUsingAnotherKey() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        context.insert(
            ComicReaderSchemaV6.StoredReaderGlobalPreferences(
                recordKey: "foreign-preferences",
                defaultReadingModeRawValue: ReadingMode.spread.rawValue,
                defaultReadingDirectionRawValue: (
                    ReadingDirection.rightToLeft.rawValue
                ),
                leftTapActionRawValue: ReaderTapZoneAction.disabled.rawValue,
                rightTapActionRawValue: ReaderTapZoneAction.disabled.rawValue,
                legacyProgressPreferencesBackfillVersion: 1
            )
        )
        try context.save()

        let repository = await makeRepository(container: container)

        XCTAssertEqual(repository.globalReaderPreferences, .default)
        let records = try ModelContext(container).fetch(
            FetchDescriptor<ComicReaderSchemaV6.StoredReaderGlobalPreferences>()
        )
        XCTAssertEqual(
            Set(records.map(\.recordKey)),
            ["foreign-preferences", "reader-global-v1"]
        )
    }

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
    func testConfigurationGenerationRejectsABAStoreCreation() async throws {
        let container = try makeContainer()
        let creationGate = StoreCreationGate()
        defer {
            Task {
                await creationGate.release(0)
                await creationGate.release(1)
            }
        }
        let repository = LibraryStateRepository(
            prepareStoreCreation: { _ in
                await creationGate.suspendInvocation()
            }
        )

        let originalConfiguration = Task { @MainActor in
            await repository.configure(modelContainer: container)
        }
        guard await waitForStoreCreationStart(
            creationGate,
            invocation: 0
        ) else {
            return
        }
        await repository.configure(modelContainer: nil)

        let replacementConfiguration = Task { @MainActor in
            await repository.configure(modelContainer: container)
        }
        guard await waitForStoreCreationStart(
            creationGate,
            invocation: 1
        ) else {
            return
        }

        await creationGate.release(0)
        await originalConfiguration.value
        XCTAssertEqual(repository.status, .loading)
        XCTAssertFalse(repository.isWriteAvailable)

        await creationGate.release(1)
        await replacementConfiguration.value
        XCTAssertEqual(repository.status, .ready)
        XCTAssertTrue(repository.isWriteAvailable)
    }

    @MainActor
    func testContainerSwitchDetachesOldStoreWhileReplacementLoads() async throws {
        let firstContainer = try makeContainer()
        let secondContainer = try makeContainer()
        let creationGate = StoreCreationGate()
        defer {
            Task {
                await creationGate.release(0)
                await creationGate.release(1)
            }
        }
        let repository = LibraryStateRepository(
            prepareStoreCreation: { _ in
                await creationGate.suspendInvocation()
            }
        )
        let comic = catalogItem(
            id: managedComicID("00000000-0000-0000-0000-000000000410"),
            title: "Detached Store Comic",
            importedAt: .distantPast
        )

        let firstConfiguration = Task { @MainActor in
            await repository.configure(modelContainer: firstContainer)
        }
        guard await waitForStoreCreationStart(
            creationGate,
            invocation: 0
        ) else {
            return
        }
        await creationGate.release(0)
        await firstConfiguration.value
        await repository.reconcile(catalogItems: [comic])
        XCTAssertTrue(repository.isWriteAvailable)

        let replacementConfiguration = Task { @MainActor in
            await repository.configure(modelContainer: secondContainer)
        }
        guard await waitForStoreCreationStart(
            creationGate,
            invocation: 1
        ) else {
            return
        }

        let didRecord = await repository.recordProgress(
            LibraryReadingProgress(
                chapterID: "chapter-1",
                pageID: "page-1",
                pageOffset: 0.5,
                zoomScale: 1
            ),
            for: comic.id
        )

        XCTAssertFalse(didRecord)
        XCTAssertEqual(repository.status, .loading)
        XCTAssertFalse(repository.isWriteAvailable)
        XCTAssertEqual(repository.state(for: comic.id), .empty)

        await creationGate.release(1)
        await replacementConfiguration.value
        XCTAssertEqual(repository.status, .ready)
        XCTAssertTrue(repository.isWriteAvailable)

        let firstStoreVerifier = await makeRepository(
            container: firstContainer
        )
        XCTAssertNil(firstStoreVerifier.state(for: comic.id).progress)
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
            FetchDescriptor<ComicReaderSchemaV6.StoredComic>()
        )
        let storedComic = try XCTUnwrap(storedComics.first)
        XCTAssertEqual(storedComic.displayName, "Updated Title")
        XCTAssertEqual(storedComic.chapterCount, 3)
        XCTAssertEqual(storedComic.pageCount, 36)
        XCTAssertTrue(storedComic.isFavorite)
        XCTAssertEqual(
            try context.fetch(
                FetchDescriptor<ComicReaderSchemaV6.StoredReadingProgress>()
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
    func testRecordProgressDoesNotWriteLegacyReaderPreferenceFields() async throws {
        let container = try makeContainer()
        let repository = await makeRepository(container: container)
        let comic = catalogItem(
            id: managedComicID("00000000-0000-0000-0000-000000000416"),
            title: "Reader Preferences Comic",
            importedAt: .distantPast
        )
        await repository.reconcile(catalogItems: [comic])
        let progress = LibraryReadingProgress(
            chapterID: "chapter-2",
            pageID: "page-8",
            pageOffset: 0.75,
            zoomScale: 2,
            readingMode: .spread,
            readingDirection: .rightToLeft,
            updatedAt: Date(timeIntervalSince1970: 200)
        )
        let expectedProgress = LibraryReadingProgress(
            chapterID: progress.chapterID,
            pageID: progress.pageID,
            pageOffset: progress.pageOffset,
            zoomScale: progress.zoomScale,
            updatedAt: progress.updatedAt
        )

        await assertRecords(progress, for: comic.id, using: repository)

        let storedProgress = try XCTUnwrap(
            try ModelContext(container).fetch(
                FetchDescriptor<ComicReaderSchemaV6.StoredReadingProgress>()
            ).first
        )
        XCTAssertEqual(
            storedProgress.readingModeRawValue,
            ReadingMode.continuous.rawValue
        )
        XCTAssertEqual(
            storedProgress.readingDirectionRawValue,
            ReadingDirection.leftToRight.rawValue
        )
        XCTAssertEqual(repository.state(for: comic.id).progress, expectedProgress)

        let restoredRepository = await makeRepository(container: container)
        XCTAssertEqual(
            restoredRepository.state(for: comic.id).progress,
            expectedProgress
        )
    }

    @MainActor
    func testRecordProgressPreservesMigratedLegacyPreferenceFields() async throws {
        let container = try makeContainer()
        let comicID = managedComicID(
            "00000000-0000-0000-0000-000000000423"
        )
        let seedContext = ModelContext(container)
        seedContext.insert(
            ComicReaderSchemaV6.StoredComic(
                comicID: comicID.rawValue,
                displayName: "Legacy Preference Comic",
                sourceRootName: "legacy-preference-source",
                importedAt: .distantPast,
                chapterCount: 2,
                pageCount: 12
            )
        )
        seedContext.insert(
            ComicReaderSchemaV6.StoredReadingProgress(
                comicID: comicID.rawValue,
                chapterID: "chapter-1",
                pageID: "page-1",
                pageOffset: 0,
                zoomScale: 1,
                readingModeRawValue: ReadingMode.spread.rawValue,
                readingDirectionRawValue: ReadingDirection.rightToLeft.rawValue,
                isCompleted: false,
                updatedAt: Date(timeIntervalSince1970: 100)
            )
        )
        try seedContext.save()
        let repository = await makeRepository(container: container)

        let didRecord = await repository.recordProgress(
            LibraryReadingProgress(
                chapterID: "chapter-2",
                pageID: "page-8",
                pageOffset: 0.75,
                zoomScale: 2,
                readingMode: .singlePage,
                readingDirection: .leftToRight,
                updatedAt: Date(timeIntervalSince1970: 200)
            ),
            for: comicID
        )

        XCTAssertTrue(didRecord)
        let storedProgress = try XCTUnwrap(
            try ModelContext(container).fetch(
                FetchDescriptor<ComicReaderSchemaV6.StoredReadingProgress>()
            ).first
        )
        XCTAssertEqual(
            storedProgress.readingModeRawValue,
            ReadingMode.spread.rawValue
        )
        XCTAssertEqual(
            storedProgress.readingDirectionRawValue,
            ReadingDirection.rightToLeft.rawValue
        )
        XCTAssertEqual(
            repository.readerOverrides(for: comicID),
            ComicReaderOverrides(
                readingMode: .spread,
                readingDirection: .rightToLeft
            )
        )
    }

    @MainActor
    func testReaderPreferencesPersistAndResolveOverridesOverGlobalDefaults() async throws {
        let container = try makeContainer()
        let repository = await makeRepository(container: container)
        let comic = catalogItem(
            id: managedComicID("00000000-0000-0000-0000-000000000420"),
            title: "Preference Resolution Comic",
            importedAt: .distantPast
        )
        await repository.reconcile(catalogItems: [comic])

        let didSetMode = await repository.setDefaultReadingMode(.singlePage)
        let didSetDirection = await repository.setDefaultReadingDirection(
            .rightToLeft
        )
        let didSetLeftTap = await repository.setTapZoneAction(
            .disabled,
            isLeftZone: true
        )
        let didSetRightTap = await repository.setTapZoneAction(
            .toggleControls,
            isLeftZone: false
        )

        XCTAssertTrue(didSetMode)
        XCTAssertTrue(didSetDirection)
        XCTAssertTrue(didSetLeftTap)
        XCTAssertTrue(didSetRightTap)
        let expectedGlobal = ReaderGlobalPreferences(
            defaultReadingMode: .singlePage,
            defaultReadingDirection: .rightToLeft,
            tapAreas: ReaderTapAreaPreferences(
                leftAction: .disabled,
                rightAction: .toggleControls
            )
        )
        XCTAssertEqual(repository.globalReaderPreferences, expectedGlobal)
        XCTAssertEqual(repository.readerOverrides(for: comic.id), .none)
        XCTAssertEqual(
            repository.resolvedReaderPreferences(for: comic.id),
            ComicReaderOverrides.none.resolved(using: expectedGlobal)
        )

        let didOverrideMode = await repository.setReadingModeOverride(
            .spread,
            for: comic.id
        )
        let didOverrideDirection = await repository
            .setReadingDirectionOverride(.leftToRight, for: comic.id)

        XCTAssertTrue(didOverrideMode)
        XCTAssertTrue(didOverrideDirection)
        XCTAssertEqual(
            repository.readerOverrides(for: comic.id),
            ComicReaderOverrides(
                readingMode: .spread,
                readingDirection: .leftToRight
            )
        )
        XCTAssertEqual(
            repository.resolvedReaderPreferences(for: comic.id),
            ResolvedReaderPreferences(
                readingMode: .spread,
                readingDirection: .leftToRight,
                tapAreas: expectedGlobal.tapAreas
            )
        )

        let restoredRepository = await makeRepository(container: container)
        XCTAssertEqual(
            restoredRepository.resolvedReaderPreferences(for: comic.id),
            repository.resolvedReaderPreferences(for: comic.id)
        )

        let didClearMode = await restoredRepository.setReadingModeOverride(
            nil,
            for: comic.id
        )
        let didClearDirection = await restoredRepository
            .setReadingDirectionOverride(nil, for: comic.id)

        XCTAssertTrue(didClearMode)
        XCTAssertTrue(didClearDirection)
        XCTAssertEqual(restoredRepository.readerOverrides(for: comic.id), .none)
        XCTAssertEqual(
            restoredRepository.resolvedReaderPreferences(for: comic.id),
            ComicReaderOverrides.none.resolved(using: expectedGlobal)
        )
    }

    @MainActor
    func testReaderPreferencesFallBackForUnknownStoredRawValues() async throws {
        let container = try makeContainer()
        let repository = await makeRepository(container: container)
        let comic = catalogItem(
            id: managedComicID("00000000-0000-0000-0000-000000000421"),
            title: "Future Preference Comic",
            importedAt: .distantPast
        )
        await repository.reconcile(catalogItems: [comic])

        let context = ModelContext(container)
        let globalRecord = try XCTUnwrap(
            try context.fetch(
                FetchDescriptor<
                    ComicReaderSchemaV6.StoredReaderGlobalPreferences
                >()
            ).first
        )
        globalRecord.defaultReadingModeRawValue = "future-mode"
        globalRecord.defaultReadingDirectionRawValue = "future-direction"
        globalRecord.leftTapActionRawValue = "future-left-action"
        globalRecord.rightTapActionRawValue = "future-right-action"
        let comicRecord = try XCTUnwrap(
            try context.fetch(
                FetchDescriptor<ComicReaderSchemaV6.StoredComic>()
            ).first
        )
        comicRecord.readingModeOverrideRawValue = "future-mode"
        comicRecord.readingDirectionOverrideRawValue = "future-direction"
        try context.save()

        let restoredRepository = await makeRepository(container: container)

        XCTAssertEqual(
            restoredRepository.globalReaderPreferences,
            ReaderGlobalPreferences.default
        )
        XCTAssertEqual(restoredRepository.readerOverrides(for: comic.id), .none)
        XCTAssertEqual(
            restoredRepository.resolvedReaderPreferences(for: comic.id),
            ComicReaderOverrides.none.resolved(
                using: ReaderGlobalPreferences.default
            )
        )
    }

    @MainActor
    func testRecordProgressPersistsCompletedChapterIDsInStableOrder() async throws {
        let container = try makeContainer()
        let repository = await makeRepository(container: container)
        let comic = catalogItem(
            id: managedComicID("00000000-0000-0000-0000-000000000418"),
            title: "Completed Chapters Comic",
            importedAt: .distantPast
        )
        await repository.reconcile(catalogItems: [comic])
        let progress = LibraryReadingProgress(
            chapterID: "chapter-3",
            pageID: "page-8",
            pageOffset: 1,
            zoomScale: 1,
            completedChapterIDs: [
                " chapter-3 ",
                "chapter-3",
                "chapter-1",
                "\nchapter-2\t",
                "",
                " \n ",
            ],
            updatedAt: Date(timeIntervalSince1970: 200)
        )

        await assertRecords(progress, for: comic.id, using: repository)

        let storedProgress = try XCTUnwrap(
            try ModelContext(container).fetch(
                FetchDescriptor<ComicReaderSchemaV6.StoredReadingProgress>()
            ).first
        )
        XCTAssertEqual(
            storedProgress.completedChapterIDs,
            ["chapter-1", "chapter-2", "chapter-3"]
        )

        let restoredRepository = await makeRepository(container: container)
        XCTAssertEqual(
            restoredRepository.state(for: comic.id).progress,
            progress
        )
    }

    @MainActor
    func testReloadFallsBackForUnknownReadingPreferenceRawValues() async throws {
        let container = try makeContainer()
        let repository = await makeRepository(container: container)
        let comic = catalogItem(
            id: managedComicID("00000000-0000-0000-0000-000000000417"),
            title: "Future Reader Preferences Comic",
            importedAt: .distantPast
        )
        await repository.reconcile(catalogItems: [comic])

        let timestamp = Date(timeIntervalSince1970: 300)
        let context = ModelContext(container)
        context.insert(
            ComicReaderSchemaV6.StoredReadingProgress(
                comicID: comic.id.rawValue,
                chapterID: "chapter-future",
                pageID: "page-future",
                pageOffset: 0.5,
                zoomScale: 3,
                readingModeRawValue: "future-mode",
                readingDirectionRawValue: "future-direction",
                isCompleted: true,
                updatedAt: timestamp
            )
        )
        try context.save()

        let restoredRepository = await makeRepository(container: container)
        let restoredProgress = try XCTUnwrap(
            restoredRepository.state(for: comic.id).progress
        )
        XCTAssertEqual(restoredProgress.chapterID, "chapter-future")
        XCTAssertEqual(restoredProgress.pageID, "page-future")
        XCTAssertEqual(restoredProgress.pageOffset, 0.5)
        XCTAssertEqual(restoredProgress.zoomScale, 3)
        XCTAssertEqual(restoredProgress.readingMode, .continuous)
        XCTAssertEqual(restoredProgress.readingDirection, .leftToRight)
        XCTAssertTrue(restoredProgress.isCompleted)
        XCTAssertEqual(restoredProgress.updatedAt, timestamp)
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
    func testRecordProgressUsesLastPositionWhenTimestampsMatchAndRetainsCompletion() async throws {
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
            completedChapterIDs: ["chapter-3"],
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
        let expectedProgress = LibraryReadingProgress(
            chapterID: lastProgress.chapterID,
            pageID: lastProgress.pageID,
            pageOffset: lastProgress.pageOffset,
            zoomScale: lastProgress.zoomScale,
            completedChapterIDs: ["chapter-3"],
            isCompleted: true,
            updatedAt: lastProgress.updatedAt
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
        XCTAssertEqual(repository.state(for: comic.id).progress, expectedProgress)

        let restoredRepository = await makeRepository(container: container)
        XCTAssertEqual(
            restoredRepository.state(for: comic.id).progress,
            expectedProgress
        )
    }

    @MainActor
    func testRecordProgressRetainsCompletionWhenNewerSceneWritesIncompletePosition() async throws {
        let container = try makeContainer()
        let completedSceneRepository = await makeRepository(container: container)
        let laterSceneRepository = await makeRepository(container: container)
        let comic = catalogItem(
            id: managedComicID("00000000-0000-0000-0000-000000000414"),
            title: "Completion Merge Comic",
            importedAt: .distantPast
        )
        await completedSceneRepository.reconcile(catalogItems: [comic])
        await laterSceneRepository.reconcile(catalogItems: [comic])
        let completedProgress = LibraryReadingProgress(
            chapterID: "chapter-2",
            pageID: "page-10",
            pageOffset: 1,
            zoomScale: 1,
            completedChapterIDs: ["chapter-2"],
            isCompleted: true,
            updatedAt: Date(timeIntervalSince1970: 100)
        )
        let newerIncompleteProgress = LibraryReadingProgress(
            chapterID: "chapter-1",
            pageID: "page-2",
            pageOffset: 0.5,
            zoomScale: 2,
            updatedAt: Date(timeIntervalSince1970: 200)
        )
        let expectedProgress = LibraryReadingProgress(
            chapterID: newerIncompleteProgress.chapterID,
            pageID: newerIncompleteProgress.pageID,
            pageOffset: newerIncompleteProgress.pageOffset,
            zoomScale: newerIncompleteProgress.zoomScale,
            completedChapterIDs: ["chapter-2"],
            isCompleted: true,
            updatedAt: newerIncompleteProgress.updatedAt
        )

        let didRecordCompletion = await completedSceneRepository.recordProgress(
            completedProgress,
            for: comic.id
        )
        let didRecordNewerPosition = await laterSceneRepository.recordProgress(
            newerIncompleteProgress,
            for: comic.id
        )
        await completedSceneRepository.reload()
        await laterSceneRepository.reload()
        let restoredRepository = await makeRepository(container: container)

        XCTAssertTrue(didRecordCompletion)
        XCTAssertTrue(didRecordNewerPosition)
        XCTAssertEqual(
            completedSceneRepository.state(for: comic.id).progress,
            expectedProgress
        )
        XCTAssertEqual(
            laterSceneRepository.state(for: comic.id).progress,
            expectedProgress
        )
        XCTAssertEqual(
            restoredRepository.state(for: comic.id).progress,
            expectedProgress
        )
    }

    @MainActor
    func testRecordProgressMergesOlderCompletionWithoutOverwritingNewerPosition() async throws {
        let repository = await makeRepository(container: try makeContainer())
        let comic = catalogItem(
            id: managedComicID("00000000-0000-0000-0000-000000000415"),
            title: "Delayed Completion Merge Comic",
            importedAt: .distantPast
        )
        await repository.reconcile(catalogItems: [comic])
        let newerIncompleteProgress = LibraryReadingProgress(
            chapterID: "chapter-1",
            pageID: "page-2",
            pageOffset: 0.5,
            zoomScale: 2,
            completedChapterIDs: ["chapter-1"],
            updatedAt: Date(timeIntervalSince1970: 200)
        )
        let olderCompletedProgress = LibraryReadingProgress(
            chapterID: "chapter-2",
            pageID: "page-10",
            pageOffset: 1,
            zoomScale: 1,
            completedChapterIDs: ["chapter-2"],
            isCompleted: true,
            updatedAt: Date(timeIntervalSince1970: 100)
        )
        let expectedProgress = LibraryReadingProgress(
            chapterID: newerIncompleteProgress.chapterID,
            pageID: newerIncompleteProgress.pageID,
            pageOffset: newerIncompleteProgress.pageOffset,
            zoomScale: newerIncompleteProgress.zoomScale,
            completedChapterIDs: ["chapter-1", "chapter-2"],
            isCompleted: true,
            updatedAt: newerIncompleteProgress.updatedAt
        )

        let didRecordNewerPosition = await repository.recordProgress(
            newerIncompleteProgress,
            for: comic.id
        )
        let didMergeOlderCompletion = await repository.recordProgress(
            olderCompletedProgress,
            for: comic.id
        )

        XCTAssertTrue(didRecordNewerPosition)
        XCTAssertTrue(didMergeOlderCompletion)
        XCTAssertEqual(repository.state(for: comic.id).progress, expectedProgress)
    }

    @MainActor
    func testRecordProgressMergesOlderChapterCompletionWithoutCompletingComic() async throws {
        let container = try makeContainer()
        let seedRepository = await makeRepository(container: container)
        let comic = catalogItem(
            id: managedComicID("00000000-0000-0000-0000-000000000419"),
            title: "Delayed Chapter Completion Comic",
            importedAt: .distantPast
        )
        await seedRepository.reconcile(catalogItems: [comic])
        let newerProgress = LibraryReadingProgress(
            chapterID: "chapter-3",
            pageID: "page-20",
            pageOffset: 0.5,
            zoomScale: 2,
            completedChapterIDs: ["chapter-1"],
            updatedAt: Date(timeIntervalSince1970: 200)
        )
        let olderChapterCompletion = LibraryReadingProgress(
            chapterID: "chapter-2",
            pageID: "page-12",
            pageOffset: 1,
            zoomScale: 1,
            completedChapterIDs: [
                " chapter-2 ",
                "chapter-2",
                " \n ",
            ],
            updatedAt: Date(timeIntervalSince1970: 100)
        )

        let didRecordNewerProgress = await seedRepository.recordProgress(
            newerProgress,
            for: comic.id
        )
        XCTAssertTrue(didRecordNewerProgress)

        let seedContext = ModelContext(container)
        let seededStoredProgress = try XCTUnwrap(
            try seedContext.fetch(
                FetchDescriptor<ComicReaderSchemaV6.StoredReadingProgress>()
            ).first
        )
        seededStoredProgress.completedChapterIDs = [
            " chapter-1 ",
            "chapter-1",
            "",
            " \n ",
        ]
        try seedContext.save()

        let repository = await makeRepository(container: container)
        XCTAssertEqual(
            repository.state(for: comic.id).progress?.completedChapterIDs,
            ["chapter-1"]
        )

        let didMergeOlderCompletion = await repository.recordProgress(
            olderChapterCompletion,
            for: comic.id
        )

        XCTAssertTrue(didMergeOlderCompletion)

        let mergedProgress = try XCTUnwrap(
            repository.state(for: comic.id).progress
        )
        XCTAssertEqual(mergedProgress.chapterID, newerProgress.chapterID)
        XCTAssertEqual(mergedProgress.pageID, newerProgress.pageID)
        XCTAssertEqual(mergedProgress.updatedAt, newerProgress.updatedAt)
        XCTAssertEqual(
            mergedProgress.completedChapterIDs,
            ["chapter-1", "chapter-2"]
        )
        XCTAssertFalse(mergedProgress.isCompleted)

        let mergedStoredProgress = try XCTUnwrap(
            try ModelContext(container).fetch(
                FetchDescriptor<ComicReaderSchemaV6.StoredReadingProgress>()
            ).first
        )
        XCTAssertEqual(
            mergedStoredProgress.completedChapterIDs,
            ["chapter-1", "chapter-2"]
        )
    }

    @MainActor
    func testProgressMergeObservesNewerSaveFromAnotherContext() async throws {
        let container = try makeContainer()
        let firstRepository = await makeRepository(container: container)
        let comic = catalogItem(
            id: managedComicID("00000000-0000-0000-0000-000000000413"),
            title: "Cross Context Comic",
            importedAt: .distantPast
        )
        await firstRepository.reconcile(catalogItems: [comic])
        await assertRecords(
            LibraryReadingProgress(
                chapterID: "chapter-1",
                pageID: "page-1",
                pageOffset: 0,
                zoomScale: 1,
                updatedAt: Date(timeIntervalSince1970: 50)
            ),
            for: comic.id,
            using: firstRepository
        )

        let secondRepository = await makeRepository(container: container)
        let newerProgress = LibraryReadingProgress(
            chapterID: "chapter-2",
            pageID: "page-8",
            pageOffset: 0.8,
            zoomScale: 2,
            isCompleted: true,
            updatedAt: Date(timeIntervalSince1970: 200)
        )
        await assertRecords(
            newerProgress,
            for: comic.id,
            using: secondRepository
        )

        let didRecordStaleProgress = await firstRepository.recordProgress(
            LibraryReadingProgress(
                chapterID: "chapter-1",
                pageID: "page-3",
                pageOffset: 0.3,
                zoomScale: 1,
                updatedAt: Date(timeIntervalSince1970: 100)
            ),
            for: comic.id
        )

        XCTAssertFalse(didRecordStaleProgress)
        XCTAssertEqual(
            firstRepository.state(for: comic.id).progress,
            newerProgress
        )
        let restoredRepository = await makeRepository(container: container)
        XCTAssertEqual(
            restoredRepository.state(for: comic.id).progress,
            newerProgress
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
            FetchDescriptor<ComicReaderSchemaV6.StoredComic>()
        ) {
            seedContext.delete(storedComic)
        }
        try seedContext.save()

        let rebuiltContext = ModelContext(container)
        let rebuiltRepository = await makeRepository(container: container)
        await rebuiltRepository.reconcile(catalogItems: [first, second])
        let rebuiltComics = try rebuiltContext.fetch(
            FetchDescriptor<ComicReaderSchemaV6.StoredComic>()
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
            FetchDescriptor<ComicReaderSchemaV6.StoredComic>()
        )
        XCTAssertEqual(rebuiltRecords.map(\.comicID), [comic.id.rawValue])
        XCTAssertEqual(coordinator.comics.map(\.id), [comic.id])
        XCTAssertEqual(rebuiltRepository.status, .ready)
    }

    // MARK: - Library Search Snapshots

    @MainActor
    func testSortableComicReflectsUserStateForSearch() async throws {
        let container = try makeContainer()
        let repository = await makeRepository(container: container)
        let comic = catalogItem(
            id: managedComicID("00000000-0000-0000-0000-000000000413"),
            title: "Sortable Comic",
            importedAt: Date(timeIntervalSince1970: 500)
        )
        await repository.reconcile(catalogItems: [comic])

        let unread = repository.sortableComic(for: comic)
        XCTAssertEqual(unread.readState, .unread)
        XCTAssertFalse(unread.isFavorite)
        XCTAssertNil(unread.lastReadAt)
        XCTAssertEqual(unread.importedAt, comic.record.importedAt)

        await repository.toggleFavorite(for: comic.id)
        let didRecord = await repository.recordProgress(
            LibraryReadingProgress(
                chapterID: "chapter-1",
                pageID: "page-1",
                pageOffset: 0,
                zoomScale: 1,
                updatedAt: Date(timeIntervalSince1970: 900)
            ),
            for: comic.id
        )
        XCTAssertTrue(didRecord)

        let inProgress = repository.sortableComic(for: comic)
        XCTAssertTrue(inProgress.isFavorite)
        XCTAssertEqual(inProgress.readState, .inProgress)
        XCTAssertEqual(
            inProgress.lastReadAt?.timeIntervalSince1970,
            900
        )
    }

    // MARK: - Custom Shelves

    @MainActor
    func testCreateShelvesAssignsOrderAndNormalizesNames() async throws {
        let repository = await makeRepository(container: try makeContainer())

        let first = await repository.createShelf(named: "  Favorites  ")
        let second = await repository.createShelf(named: "Reading Now")
        let blankShelf = await repository.createShelf(named: "     ")
        XCTAssertNil(blankShelf)

        XCTAssertEqual(first?.displayName, "Favorites")
        XCTAssertEqual(first?.sortOrder, 0)
        XCTAssertEqual(second?.sortOrder, 1)
        let shelfNames = await repository.shelves().map(\.displayName)
        XCTAssertEqual(shelfNames, ["Favorites", "Reading Now"])
    }

    @MainActor
    func testShelfMembershipAddRemoveAndUnknownTargets() async throws {
        let container = try makeContainer()
        let repository = await makeRepository(container: container)
        let comic = catalogItem(
            id: managedComicID("00000000-0000-0000-0000-000000000414"),
            title: "Shelved Comic",
            importedAt: .distantPast
        )
        await repository.reconcile(catalogItems: [comic])
        let shelf = await repository.createShelf(named: "Weekend")
        let shelfID = try XCTUnwrap(shelf?.id)
        let unknownShelfID = ComicShelfID(
            rawValue: UUID(
                uuidString: "00000000-0000-0000-0000-000000000415"
            )!
        )
        let unknownComicID = managedComicID(
            "00000000-0000-0000-0000-000000000416"
        )

        let didAdd = await repository.addComic(comic.id, toShelf: shelfID)
        XCTAssertTrue(didAdd)
        let repeatedAdd = await repository.addComic(comic.id, toShelf: shelfID)
        XCTAssertFalse(repeatedAdd)
        let memberIDs = await repository.comicIDs(inShelf: shelfID)
        XCTAssertEqual(memberIDs, [comic.id])
        let containingShelves = await repository.shelves(containing: comic.id)
        XCTAssertEqual(containingShelves, [shelf])
        let unknownComicAdd = await repository.addComic(
            unknownComicID,
            toShelf: shelfID
        )
        XCTAssertFalse(unknownComicAdd)
        let unknownShelfAdd = await repository.addComic(
            comic.id,
            toShelf: unknownShelfID
        )
        XCTAssertFalse(unknownShelfAdd)

        let didRemove = await repository.removeComic(
            comic.id,
            fromShelf: shelfID
        )
        XCTAssertTrue(didRemove)
        let repeatedRemove = await repository.removeComic(
            comic.id,
            fromShelf: shelfID
        )
        XCTAssertFalse(repeatedRemove)
        XCTAssertEqual(await repository.comicIDs(inShelf: shelfID), [])
        XCTAssertTrue(await repository.shelves(containing: comic.id).isEmpty)
    }

    @MainActor
    func testShelfMembershipKeepsInsertionOrder() async throws {
        let container = try makeContainer()
        let repository = await makeRepository(container: container)
        let first = catalogItem(
            id: managedComicID("00000000-0000-0000-0000-000000000417"),
            title: "First",
            importedAt: .distantPast
        )
        let second = catalogItem(
            id: managedComicID("00000000-0000-0000-0000-000000000418"),
            title: "Second",
            importedAt: .distantPast
        )
        await repository.reconcile(catalogItems: [first, second])
        let shelf = try XCTUnwrap(
            await repository.createShelf(named: "Ordered")
        )

        XCTAssertTrue(await repository.addComic(first.id, toShelf: shelf.id))
        XCTAssertTrue(await repository.addComic(second.id, toShelf: shelf.id))

        let orderedMemberIDs = await repository.comicIDs(inShelf: shelf.id)
        XCTAssertEqual(orderedMemberIDs, [first.id, second.id])
    }

    @MainActor
    func testRenameAndDeleteShelfCleansUpMemberships() async throws {
        let container = try makeContainer()
        let repository = await makeRepository(container: container)
        let comic = catalogItem(
            id: managedComicID("00000000-0000-0000-0000-000000000419"),
            title: "Trash Shelf Comic",
            importedAt: .distantPast
        )
        await repository.reconcile(catalogItems: [comic])
        let shelf = try XCTUnwrap(
            await repository.createShelf(named: "Temporary")
        )
        XCTAssertTrue(await repository.addComic(comic.id, toShelf: shelf.id))

        XCTAssertFalse(await repository.renameShelf(shelf.id, to: "   "))
        XCTAssertTrue(await repository.renameShelf(shelf.id, to: "Renamed"))
        XCTAssertEqual(
            await repository.shelves().first?.displayName,
            "Renamed"
        )

        XCTAssertTrue(await repository.deleteShelf(shelf.id))
        XCTAssertTrue(await repository.shelves().isEmpty)
        XCTAssertTrue(await repository.comicIDs(inShelf: shelf.id).isEmpty)
    }

    @MainActor
    func testShelvesPersistAcrossReconfiguration() async throws {
        let container = try makeContainer()
        let repository = await makeRepository(container: container)
        let shelf = try XCTUnwrap(
            await repository.createShelf(named: "Persistent")
        )

        await repository.configure(modelContainer: nil)
        await repository.configure(modelContainer: container)

        XCTAssertEqual(await repository.shelves(), [shelf])
    }

    // MARK: - Chapter Page Orders

    @MainActor
    func testChapterPageOrderRoundTripsUpdatesAndClears() async throws {
        let container = try makeContainer()
        let repository = await makeRepository(container: container)
        let comic = catalogItem(
            id: managedComicID("00000000-0000-0000-0000-000000000410"),
            title: "Ordered Comic",
            importedAt: .distantPast
        )
        await repository.reconcile(catalogItems: [comic])

        let chapterID = ImportChapterCandidate.ID(rawValue: "chapter-1")
        let naturalIDs = ["p1", "p2", "p3"].map(ImportPageCandidate.ID.init)
        let order = try ChapterPageOrder(
            chapterID: chapterID,
            orderedPageIDs: ["p2", "p3", "p1"].map(
                ImportPageCandidate.ID.init
            ),
            naturalPageIDs: naturalIDs
        )

        let didSave = await repository.setChapterPageOrder(order, for: comic.id)
        XCTAssertTrue(didSave)
        let loadedOrder = await repository.chapterPageOrder(
            chapterID: chapterID,
            for: comic.id
        )
        XCTAssertEqual(loadedOrder, order)

        let updatedOrder = try ChapterPageOrder(
            chapterID: chapterID,
            orderedPageIDs: naturalIDs.reversed(),
            naturalPageIDs: naturalIDs
        )
        let didUpdate = await repository.setChapterPageOrder(
            updatedOrder,
            for: comic.id
        )
        XCTAssertTrue(didUpdate)
        let records = try ModelContext(container).fetch(
            FetchDescriptor<ComicReaderSchemaV6.StoredChapterPageOrder>()
        )
        XCTAssertEqual(records.count, 1)
        let reloadedOrder = await repository.chapterPageOrder(
            chapterID: chapterID,
            for: comic.id
        )
        XCTAssertEqual(reloadedOrder, updatedOrder)

        let didClear = await repository.clearChapterPageOrder(
            chapterID: chapterID,
            for: comic.id
        )
        XCTAssertTrue(didClear)
        let clearedOrder = await repository.chapterPageOrder(
            chapterID: chapterID,
            for: comic.id
        )
        XCTAssertNil(clearedOrder)
        let repeatedClear = await repository.clearChapterPageOrder(
            chapterID: chapterID,
            for: comic.id
        )
        XCTAssertFalse(repeatedClear)
    }

    @MainActor
    func testChapterPageOrderSurvivesReconfiguration() async throws {
        let container = try makeContainer()
        let repository = await makeRepository(container: container)
        let comic = catalogItem(
            id: managedComicID("00000000-0000-0000-0000-000000000411"),
            title: "Persisted Order Comic",
            importedAt: .distantPast
        )
        await repository.reconcile(catalogItems: [comic])

        let chapterID = ImportChapterCandidate.ID(rawValue: "chapter-9")
        let order = ChapterPageOrder.reversed(
            chapterID,
            naturalPageIDs: ["p1", "p2"].map(ImportPageCandidate.ID.init)
        )
        let didSave = await repository.setChapterPageOrder(order, for: comic.id)
        XCTAssertTrue(didSave)

        await repository.configure(modelContainer: nil)
        await repository.configure(modelContainer: container)

        let reloadedOrder = await repository.chapterPageOrder(
            chapterID: chapterID,
            for: comic.id
        )
        XCTAssertEqual(reloadedOrder, order)
    }

    @MainActor
    func testChapterPageOrderRejectsUnknownComic() async throws {
        let repository = await makeRepository(container: try makeContainer())
        let unknownComicID = managedComicID(
            "00000000-0000-0000-0000-000000000412"
        )
        let order = ChapterPageOrder.reversed(
            ImportChapterCandidate.ID(rawValue: "chapter-1"),
            naturalPageIDs: ["p1", "p2"].map(ImportPageCandidate.ID.init)
        )

        let didSave = await repository.setChapterPageOrder(
            order,
            for: unknownComicID
        )
        XCTAssertFalse(didSave)
        XCTAssertTrue(repository.isWriteAvailable)
        XCTAssertEqual(repository.status, .ready)
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

    @MainActor
    private func waitForStoreCreationStart(
        _ gate: StoreCreationGate,
        invocation: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async -> Bool {
        guard await gate.waitUntilStarted(invocation) else {
            // 预先释放迟到的调用，避免失败测试留下永久挂起的任务。
            await gate.release(invocation)
            XCTFail(
                "Timed out waiting for store creation to start.",
                file: file,
                line: line
            )
            return false
        }

        return true
    }
}

private actor StoreCreationGate {
    private var nextInvocation = 0
    private var startedInvocations = Set<Int>()
    private var releaseContinuations: [
        Int: CheckedContinuation<Void, Never>
    ] = [:]
    private var releasedInvocations = Set<Int>()

    func suspendInvocation() async {
        let invocation = nextInvocation
        nextInvocation += 1
        startedInvocations.insert(invocation)

        guard releasedInvocations.remove(invocation) == nil else {
            return
        }

        await withCheckedContinuation { continuation in
            releaseContinuations[invocation] = continuation
        }
    }

    func waitUntilStarted(_ invocation: Int) async -> Bool {
        for _ in 0..<200 {
            if startedInvocations.contains(invocation) {
                return true
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }

        return startedInvocations.contains(invocation)
    }

    func release(_ invocation: Int) {
        if let continuation = releaseContinuations.removeValue(
            forKey: invocation
        ) {
            continuation.resume()
        } else {
            releasedInvocations.insert(invocation)
        }
    }
}
