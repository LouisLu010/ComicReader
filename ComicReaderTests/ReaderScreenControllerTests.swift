import Foundation
import XCTest
@testable import ComicReader

@MainActor
final class ReaderScreenControllerTests: XCTestCase {
    func testLoadRestoresPositionAndUsesResolvedReaderPreferences() async throws {
        let fixture = try makeContent()
        let chapterID = fixture.content.comic.chapters[0].id
        let pageID = fixture.content.comic.chapters[0].pages[1].id
        let progress = LibraryReadingProgress(
            chapterID: chapterID.rawValue,
            pageID: pageID.rawValue,
            pageOffset: 0.4,
            zoomScale: 2.25,
            readingMode: .singlePage,
            readingDirection: .leftToRight,
            completedChapterIDs: [
                chapterID.rawValue,
                "missing-chapter",
            ],
            updatedAt: Date(timeIntervalSince1970: 100)
        )
        let controller = ReaderScreenController(
            comicID: fixture.comicID,
            contentLoader: ImmediateReaderContentLoader(
                content: fixture.content
            ),
            persistedProgress: progress,
            resolvedReaderPreferences: ResolvedReaderPreferences(
                readingMode: .spread,
                readingDirection: .rightToLeft,
                tapAreas: .default
            ),
            initialLayoutCapability: .spreadCapable
        )

        let didLoad = await controller.load()

        XCTAssertTrue(didLoad)
        XCTAssertEqual(controller.state, .ready)
        XCTAssertEqual(controller.content?.comic, fixture.content.comic)
        let session = try XCTUnwrap(controller.sessionController?.session)
        XCTAssertEqual(
            session.position,
            ReadingPosition(
                location: .chapter(chapterID, pageID),
                pageOffset: 0.4,
                zoomScale: 2.25
            )
        )
        XCTAssertEqual(session.readingMode, .spread)
        XCTAssertEqual(session.readingDirection, .rightToLeft)
        XCTAssertEqual(session.completedChapterIDs, [chapterID])
        XCTAssertEqual(session.progress.completedChapterIDs, [chapterID])
        XCTAssertEqual(session.layout.effectiveMode, .spread)
        XCTAssertEqual(controller.layout, session.layout)
    }

    func testInvalidRestoredPositionFallsBackWithoutDroppingPreferences() async throws {
        let fixture = try makeContent()
        let firstChapter = fixture.content.comic.chapters[0]
        let firstPage = firstChapter.pages[0]
        let progress = LibraryReadingProgress(
            chapterID: "missing-chapter",
            pageID: "missing-page",
            pageOffset: 0.8,
            zoomScale: 3,
            readingMode: .singlePage,
            readingDirection: .rightToLeft
        )
        let controller = ReaderScreenController(
            comicID: fixture.comicID,
            contentLoader: ImmediateReaderContentLoader(
                content: fixture.content
            ),
            persistedProgress: progress,
            resolvedReaderPreferences: ResolvedReaderPreferences(
                readingMode: .singlePage,
                readingDirection: .rightToLeft,
                tapAreas: .default
            )
        )

        let didLoad = await controller.load()
        XCTAssertTrue(didLoad)

        let session = try XCTUnwrap(controller.sessionController?.session)
        XCTAssertEqual(
            session.position,
            ReadingPosition(
                location: .chapter(firstChapter.id, firstPage.id)
            )
        )
        XCTAssertEqual(session.readingMode, .singlePage)
        XCTAssertEqual(session.readingDirection, .rightToLeft)
    }

    func testResolvedPreferencesAppliedBeforeLoadAreUsedByNewSession() async throws {
        let fixture = try makeContent()
        let controller = ReaderScreenController(
            comicID: fixture.comicID,
            contentLoader: ImmediateReaderContentLoader(
                content: fixture.content
            ),
            initialLayoutCapability: .spreadCapable
        )
        let preferences = ResolvedReaderPreferences(
            readingMode: .spread,
            readingDirection: .rightToLeft,
            tapAreas: ReaderTapAreaPreferences(
                leftAction: .disabled,
                rightAction: .automatic
            )
        )

        XCTAssertTrue(controller.applyResolvedReaderPreferences(preferences))
        XCTAssertFalse(controller.applyResolvedReaderPreferences(preferences))
        let didLoad = await controller.load()
        XCTAssertTrue(didLoad)

        let session = try XCTUnwrap(controller.sessionController?.session)
        XCTAssertEqual(session.readingMode, .spread)
        XCTAssertEqual(session.readingDirection, .rightToLeft)
        XCTAssertEqual(controller.layout?.effectiveMode, .spread)
        XCTAssertEqual(controller.resolvedReaderPreferences, preferences)
    }

    func testLegacyCompletedComicRestoresFinalChapterAsCompleted() async throws {
        let fixture = try makeContent()
        let finalChapterID = try XCTUnwrap(
            fixture.content.comic.chapters.last?.id
        )
        let restoredPage = fixture.content.comic.chapters[0].pages[0]
        let controller = ReaderScreenController(
            comicID: fixture.comicID,
            contentLoader: ImmediateReaderContentLoader(
                content: fixture.content
            ),
            persistedProgress: LibraryReadingProgress(
                chapterID: finalChapterID.rawValue,
                pageID: restoredPage.id.rawValue,
                pageOffset: 0,
                zoomScale: 1,
                completedChapterIDs: [],
                isCompleted: true
            ),
            initialLayoutCapability: .spreadCapable
        )

        let didLoad = await controller.load()
        XCTAssertTrue(didLoad)

        let session = try XCTUnwrap(controller.sessionController?.session)
        XCTAssertEqual(session.position.pageID, restoredPage.id)
        XCTAssertEqual(session.position.pageOffset, 0)
        XCTAssertEqual(session.completedChapterIDs, [finalChapterID])
        XCTAssertTrue(session.progress.hasReachedFinalChapterEnd)
    }

    func testViewportCapabilityAppliesBeforeAndAfterLoadWithoutMovingPage() async throws {
        let fixture = try makeContent()
        let controller = ReaderScreenController(
            comicID: fixture.comicID,
            contentLoader: ImmediateReaderContentLoader(
                content: fixture.content
            ),
            persistedProgress: LibraryReadingProgress(
                chapterID: fixture.content.comic.chapters[0].id.rawValue,
                pageID: fixture.content.comic.chapters[0].pages[1].id.rawValue,
                pageOffset: 0.3,
                zoomScale: 1.5
            ),
            resolvedReaderPreferences: ResolvedReaderPreferences(
                readingMode: .spread,
                readingDirection: .leftToRight,
                tapAreas: .default
            )
        )
        controller.setViewportSize(CGSize(width: 1_000, height: 700))

        let didLoad = await controller.load()
        XCTAssertTrue(didLoad)
        let wideSession = try XCTUnwrap(controller.sessionController?.session)
        let restoredPosition = wideSession.position
        XCTAssertEqual(wideSession.layout.effectiveMode, .spread)
        XCTAssertEqual(controller.layout?.effectiveMode, .spread)

        controller.setViewportSize(CGSize(width: 600, height: 700))

        let narrowSession = try XCTUnwrap(controller.sessionController?.session)
        XCTAssertEqual(narrowSession.readingMode, .spread)
        XCTAssertEqual(narrowSession.layout.effectiveMode, .singlePage)
        XCTAssertEqual(narrowSession.position, restoredPosition)
        XCTAssertEqual(controller.layout?.effectiveMode, .singlePage)
    }

    func testApplyingResolvedPreferencesRefreshesLayoutWithoutPersistingProgress() async throws {
        let fixture = try makeContent()
        let recorder = ScreenProgressRecorder()
        let chapter = fixture.content.comic.chapters[0]
        let originalPosition = ReadingPosition(
            location: .chapter(chapter.id, chapter.pages[1].id),
            pageOffset: 0.5,
            zoomScale: 1.5
        )
        let controller = ReaderScreenController(
            comicID: fixture.comicID,
            contentLoader: ImmediateReaderContentLoader(
                content: fixture.content
            ),
            progressRecorder: recorder,
            persistedProgress: LibraryReadingProgress(
                chapterID: originalPosition.storageChapterID,
                pageID: originalPosition.pageID.rawValue,
                pageOffset: originalPosition.pageOffset,
                zoomScale: originalPosition.zoomScale
            ),
            initialLayoutCapability: .spreadCapable
        )

        let didLoad = await controller.load()
        XCTAssertTrue(didLoad)
        let preferences = ResolvedReaderPreferences(
            readingMode: .spread,
            readingDirection: .rightToLeft,
            tapAreas: .default
        )

        XCTAssertTrue(controller.applyResolvedReaderPreferences(preferences))
        XCTAssertFalse(controller.applyResolvedReaderPreferences(preferences))

        let updatedSession = try XCTUnwrap(controller.sessionController?.session)
        XCTAssertEqual(updatedSession.position, originalPosition)
        XCTAssertEqual(updatedSession.readingMode, .spread)
        XCTAssertEqual(updatedSession.readingDirection, .rightToLeft)
        XCTAssertEqual(controller.layout?.requestedMode, .spread)
        XCTAssertEqual(controller.layout?.effectiveMode, .spread)
        XCTAssertEqual(controller.layout?.direction, .rightToLeft)
        XCTAssertEqual(
            controller.sessionController?.progressPersistenceState,
            .idle
        )

        let didFlush = await controller.flushPendingProgress()
        XCTAssertFalse(didFlush)
        XCTAssertTrue(recorder.records.isEmpty)

        let layoutBeforeTapChange = controller.layout
        XCTAssertTrue(
            controller.applyResolvedReaderPreferences(
                ResolvedReaderPreferences(
                    readingMode: .spread,
                    readingDirection: .rightToLeft,
                    tapAreas: ReaderTapAreaPreferences(
                        leftAction: .disabled,
                        rightAction: .nextPage
                    )
                )
            )
        )
        XCTAssertEqual(controller.layout, layoutBeforeTapChange)
        XCTAssertEqual(
            controller.resolvedReaderPreferences.tapAreas.leftAction,
            .disabled
        )
    }

    func testChapterBoundaryCompletionUsesExplicitBoundaryAndPersists() async throws {
        let fixture = try makeContent()
        let recorder = ScreenProgressRecorder()
        let controller = ReaderScreenController(
            comicID: fixture.comicID,
            contentLoader: ImmediateReaderContentLoader(
                content: fixture.content
            ),
            progressRecorder: recorder,
            initialLayoutCapability: .spreadCapable
        )
        let didLoad = await controller.load()
        XCTAssertTrue(didLoad)
        XCTAssertTrue(controller.setReadingMode(.singlePage))

        let boundary = try XCTUnwrap(
            controller.layout?.presentations.compactMap {
                presentation -> ReaderChapterBoundary? in
                guard case let .chapterBoundary(boundary) = presentation.content else {
                    return nil
                }

                return boundary
            }.last
        )

        XCTAssertTrue(
            controller.sessionController?.finishChapterBoundary(boundary) == true
        )
        let didFlushProgress = await controller.flushPendingProgress()
        XCTAssertTrue(didFlushProgress)
        XCTAssertEqual(
            recorder.records.last?.progress.completedChapterIDs,
            [boundary.completedChapterID.rawValue]
        )
        XCTAssertTrue(recorder.records.last?.progress.isCompleted ?? false)
    }

    func testPageJumpPublishesRepeatableRequestAndResetsPageDetailState() async throws {
        let fixture = try makeContent()
        let controller = ReaderScreenController(
            comicID: fixture.comicID,
            contentLoader: ImmediateReaderContentLoader(
                content: fixture.content
            )
        )
        let didLoad = await controller.load()
        XCTAssertTrue(didLoad)
        let chapter = fixture.content.comic.chapters[0]
        let secondLocation = ReaderPageLocation.chapter(
            chapter.id,
            chapter.pages[1].id
        )

        XCTAssertEqual(controller.navigationIndex?.pageCount, 2)
        XCTAssertTrue(
            controller.sessionController?.move(
                to: secondLocation,
                pageOffset: 0.75,
                zoomScale: 3
            ) == true
        )

        let missingLocation = ReaderPageLocation.chapter(
            chapter.id,
            ImportPageCandidate.ID(rawValue: "missing")
        )
        XCTAssertFalse(controller.jump(to: missingLocation))
        XCTAssertTrue(controller.jump(to: secondLocation))
        let firstRequest = try XCTUnwrap(controller.navigationRequest)
        XCTAssertEqual(
            controller.sessionController?.session.position,
            ReadingPosition(location: secondLocation)
        )
        XCTAssertEqual(
            firstRequest.presentationID,
            controller.layout?.presentationID(for: secondLocation)
        )

        XCTAssertTrue(controller.jumpToPage(2))
        let repeatedRequest = try XCTUnwrap(controller.navigationRequest)
        XCTAssertGreaterThan(
            repeatedRequest.generation,
            firstRequest.generation
        )
        XCTAssertEqual(
            repeatedRequest.presentationID,
            firstRequest.presentationID
        )

        XCTAssertFalse(controller.jumpToPage(0))
        XCTAssertFalse(controller.jumpToPage(3))
        XCTAssertEqual(controller.navigationRequest, repeatedRequest)
    }

    func testPagedCommandsTraverseChapterBoundaryWithoutInventingPageNumber() async throws {
        let fixture = try makeContent()
        let controller = ReaderScreenController(
            comicID: fixture.comicID,
            contentLoader: ImmediateReaderContentLoader(
                content: fixture.content
            )
        )
        let didLoad = await controller.load()
        XCTAssertTrue(didLoad)
        XCTAssertTrue(controller.setReadingMode(.singlePage))
        let chapter = fixture.content.comic.chapters[0]
        let firstLocation = ReaderPageLocation.chapter(
            chapter.id,
            chapter.pages[0].id
        )
        let secondLocation = ReaderPageLocation.chapter(
            chapter.id,
            chapter.pages[1].id
        )

        XCTAssertEqual(
            controller.visiblePresentationID,
            controller.layout?.presentationID(for: firstLocation)
        )
        XCTAssertFalse(controller.canMoveToPreviousPage)
        XCTAssertTrue(controller.canMoveToNextPage)

        XCTAssertTrue(controller.movePage(.forward))
        XCTAssertEqual(
            controller.sessionController?.session.position.location,
            secondLocation
        )
        XCTAssertEqual(
            controller.visiblePresentationID,
            controller.layout?.presentationID(for: secondLocation)
        )

        XCTAssertTrue(controller.movePage(.forward))
        let boundaryID = ReaderPresentationID.chapterBoundary(chapter.id)
        XCTAssertEqual(controller.visiblePresentationID, boundaryID)
        XCTAssertEqual(controller.navigationRequest?.presentationID, boundaryID)
        XCTAssertEqual(
            controller.sessionController?.session.position.location,
            secondLocation,
            "章节结束页不应伪造 ReadingPosition"
        )
        XCTAssertEqual(controller.navigationIndex?.pageCount, 2)
        XCTAssertFalse(controller.canMoveToNextPage)

        XCTAssertTrue(controller.movePage(.backward))
        XCTAssertEqual(
            controller.visiblePresentationID,
            controller.layout?.presentationID(for: secondLocation)
        )
        XCTAssertEqual(
            controller.sessionController?.session.position.location,
            secondLocation
        )
    }

    func testChapterCommandsUseFirstPageAndRespectEnds() async throws {
        let fixture = try makeContent(chapterPageCounts: [1, 2, 1])
        let controller = ReaderScreenController(
            comicID: fixture.comicID,
            contentLoader: ImmediateReaderContentLoader(
                content: fixture.content
            )
        )
        let didLoad = await controller.load()
        XCTAssertTrue(didLoad)
        let chapters = fixture.content.comic.chapters

        XCTAssertFalse(controller.canMoveToPreviousChapter)
        XCTAssertTrue(controller.canMoveToNextChapter)
        XCTAssertTrue(controller.moveToNextChapter())
        XCTAssertEqual(
            controller.sessionController?.session.position.location,
            ReaderPageLocation.chapter(
                chapters[1].id,
                chapters[1].pages[0].id
            )
        )
        XCTAssertTrue(controller.canMoveToPreviousChapter)
        XCTAssertTrue(controller.canMoveToNextChapter)

        XCTAssertTrue(controller.jumpToChapter(chapters[2].id))
        XCTAssertEqual(
            controller.sessionController?.session.position.location,
            ReaderPageLocation.chapter(
                chapters[2].id,
                chapters[2].pages[0].id
            )
        )
        XCTAssertFalse(controller.canMoveToNextChapter)
        XCTAssertFalse(controller.moveToNextChapter())

        XCTAssertTrue(controller.moveToPreviousChapter())
        XCTAssertEqual(
            controller.sessionController?.session.position.location,
            ReaderPageLocation.chapter(
                chapters[1].id,
                chapters[1].pages[0].id
            )
        )
        XCTAssertFalse(
            controller.jumpToChapter(
                ImportChapterCandidate.ID(rawValue: "missing")
            )
        )
    }

    func testMapsUnavailableAndInvalidContentFailures() async throws {
        let comicID = managedComicID()
        let unavailable = ReaderScreenController(
            comicID: comicID,
            contentLoader: FailingReaderContentLoader(
                error: ReaderContentLoaderError.descriptorNotFound
            )
        )
        let invalid = ReaderScreenController(
            comicID: comicID,
            contentLoader: FailingReaderContentLoader(
                error: ReaderContentLoaderError.invalidDescriptor
            )
        )

        let didLoadUnavailable = await unavailable.load()
        XCTAssertFalse(didLoadUnavailable)
        XCTAssertEqual(unavailable.state, .failed(.unavailable))
        XCTAssertNil(unavailable.content)
        XCTAssertNil(unavailable.sessionController)
        XCTAssertNil(unavailable.layout)

        let didLoadInvalid = await invalid.load()
        XCTAssertFalse(didLoadInvalid)
        XCTAssertEqual(invalid.state, .failed(.invalidContent))
        XCTAssertNil(invalid.content)
        XCTAssertNil(invalid.sessionController)
        XCTAssertNil(invalid.layout)
    }

    func testInvalidComicFromLoaderCannotInstallPartialState() async throws {
        let fixture = try makeContent()
        let invalidContent = LoadedReaderContent(
            comic: ReaderComic(
                id: fixture.comicID,
                displayName: "Empty",
                chapters: []
            ),
            assetResolver: fixture.content.assetResolver
        )
        let controller = ReaderScreenController(
            comicID: fixture.comicID,
            contentLoader: ImmediateReaderContentLoader(
                content: invalidContent
            )
        )

        let didLoad = await controller.load()
        XCTAssertFalse(didLoad)
        XCTAssertEqual(controller.state, .failed(.invalidContent))
        XCTAssertNil(controller.content)
        XCTAssertNil(controller.sessionController)
        XCTAssertNil(controller.layout)
    }

    func testLoaderCannotInstallContentForAnotherComic() async throws {
        let expectedComicID = managedComicID()
        let foreignContent = try makeContent()
        let controller = ReaderScreenController(
            comicID: expectedComicID,
            contentLoader: ImmediateReaderContentLoader(
                content: foreignContent.content
            )
        )

        let didLoad = await controller.load()

        XCTAssertFalse(didLoad)
        XCTAssertEqual(controller.state, .failed(.invalidContent))
        XCTAssertNil(controller.content)
        XCTAssertNil(controller.sessionController)
        XCTAssertNil(controller.layout)
    }

    func testCancellationReturnsToIdleInsteadOfShowingFailure() async throws {
        let fixture = try makeContent()
        let controller = ReaderScreenController(
            comicID: fixture.comicID,
            contentLoader: SleepingReaderContentLoader(
                content: fixture.content
            )
        )
        let loadTask = Task { await controller.load() }
        await Task.yield()

        loadTask.cancel()

        let didLoad = await loadTask.value
        XCTAssertFalse(didLoad)
        XCTAssertEqual(controller.state, .idle)
        XCTAssertNil(controller.content)
        XCTAssertNil(controller.sessionController)
        XCTAssertNil(controller.layout)
    }

    func testLateFirstLoadCannotReplaceNewerSuccessfulLoad() async throws {
        let comicID = managedComicID()
        let first = try makeContent(
            comicID: comicID,
            displayName: "First"
        )
        let second = try makeContent(
            comicID: comicID,
            displayName: "Second"
        )
        let loader = ControlledReaderContentLoader()
        let controller = ReaderScreenController(
            comicID: first.comicID,
            contentLoader: loader
        )

        let firstTask = Task { await controller.load() }
        try await waitForRequestCount(1, in: loader)
        let secondTask = Task { await controller.load() }
        try await waitForRequestCount(2, in: loader)

        await loader.resumeRequest(at: 1, with: second.content)
        let didLoadSecond = await secondTask.value
        XCTAssertTrue(didLoadSecond)
        XCTAssertEqual(controller.content?.comic.displayName, "Second")

        await loader.resumeRequest(at: 0, with: first.content)
        let didLoadFirst = await firstTask.value
        XCTAssertFalse(didLoadFirst)
        XCTAssertEqual(controller.state, .ready)
        XCTAssertEqual(controller.content?.comic.displayName, "Second")
        XCTAssertEqual(
            controller.layout,
            controller.sessionController?.session.layout
        )
    }

    func testControllersKeepSessionsAndImagePipelinesIndependent() async throws {
        let fixture = try makeContent()
        let first = ReaderScreenController(
            comicID: fixture.comicID,
            contentLoader: ImmediateReaderContentLoader(
                content: fixture.content
            )
        )
        let second = ReaderScreenController(
            comicID: fixture.comicID,
            contentLoader: ImmediateReaderContentLoader(
                content: fixture.content
            )
        )

        let didLoadFirst = await first.load()
        let didLoadSecond = await second.load()
        XCTAssertTrue(didLoadFirst)
        XCTAssertTrue(didLoadSecond)
        XCTAssertFalse(first.imagePipeline === second.imagePipeline)

        let chapter = fixture.content.comic.chapters[0]
        XCTAssertTrue(
            first.sessionController?.move(
                to: .chapter(chapter.id, chapter.pages[1].id)
            ) == true
        )
        XCTAssertNotEqual(
            first.sessionController?.session.position,
            second.sessionController?.session.position
        )
    }

    func testRepeatedLoadKeepsReadySessionAndItsCurrentPosition() async throws {
        let fixture = try makeContent()
        let controller = ReaderScreenController(
            comicID: fixture.comicID,
            contentLoader: ImmediateReaderContentLoader(
                content: fixture.content
            )
        )
        let didLoadInitially = await controller.load()
        XCTAssertTrue(didLoadInitially)
        let originalSessionController = try XCTUnwrap(
            controller.sessionController
        )
        let chapter = fixture.content.comic.chapters[0]
        XCTAssertTrue(
            originalSessionController.move(
                to: .chapter(chapter.id, chapter.pages[1].id)
            )
        )

        let didLoadAgain = await controller.load()

        XCTAssertTrue(didLoadAgain)
        let currentSessionController = try XCTUnwrap(
            controller.sessionController
        )
        XCTAssertTrue(originalSessionController === currentSessionController)
        XCTAssertEqual(
            controller.sessionController?.session.position.location,
            .chapter(chapter.id, chapter.pages[1].id)
        )
    }

    func testFlushForwardsPendingProgressToRecorder() async throws {
        let fixture = try makeContent()
        let recorder = ScreenProgressRecorder()
        let controller = ReaderScreenController(
            comicID: fixture.comicID,
            contentLoader: ImmediateReaderContentLoader(
                content: fixture.content
            ),
            progressRecorder: recorder
        )
        let didLoad = await controller.load()
        XCTAssertTrue(didLoad)
        let chapter = fixture.content.comic.chapters[0]
        XCTAssertTrue(
            controller.sessionController?.move(
                to: .chapter(chapter.id, chapter.pages[1].id),
                pageOffset: 0.5,
                zoomScale: 2
            ) == true
        )

        let didFlush = await controller.flushPendingProgress()
        XCTAssertTrue(didFlush)

        XCTAssertEqual(recorder.records.count, 1)
        XCTAssertEqual(recorder.records[0].comicID, fixture.comicID)
        XCTAssertEqual(recorder.records[0].progress.pageID, "page-2")
        XCTAssertEqual(recorder.records[0].progress.pageOffset, 0.5)
        XCTAssertEqual(recorder.records[0].progress.zoomScale, 2)
    }

    private func waitForRequestCount(
        _ expectedCount: Int,
        in loader: ControlledReaderContentLoader
    ) async throws {
        for _ in 0..<200 {
            if await loader.requestCount == expectedCount {
                return
            }
            try await Task.sleep(nanoseconds: 5_000_000)
        }

        XCTFail("Timed out waiting for \(expectedCount) loader requests")
        throw ReaderScreenControllerTestError.loaderRequestTimedOut
    }

    private func makeContent(
        comicID suppliedComicID: ManagedComicID? = nil,
        displayName: String = "Reader Controller Test",
        chapterPageCounts: [Int] = [2]
    ) throws -> (comicID: ManagedComicID, content: LoadedReaderContent) {
        precondition(
            !chapterPageCounts.isEmpty
                && chapterPageCounts.allSatisfy { $0 > 0 }
        )
        let comicID = suppliedComicID ?? managedComicID()
        var workItems: [FrozenImportWorkItem] = []
        var chapters: [FrozenImportChapter] = []
        var nextPageNumber = 1

        for (chapterOffset, pageCount) in chapterPageCounts.enumerated() {
            let chapterNumber = chapterOffset + 1
            let chapterID = ImportChapterCandidate.ID(
                rawValue: "chapter-\(chapterNumber)"
            )
            var pageIDs: [ImportPageCandidate.ID] = []

            for _ in 0..<pageCount {
                let pageID = ImportPageCandidate.ID(
                    rawValue: "page-\(nextPageNumber)"
                )
                nextPageNumber += 1
                pageIDs.append(pageID)
                workItems.append(
                    FrozenImportWorkItem(
                        id: pageID,
                        sourceRelativePath: SourceRelativePath(
                            components: [
                                "outside-source",
                                "Chapter \(chapterNumber)",
                                "\(pageID.rawValue).png",
                            ]
                        ),
                        managedRelativePath: ManagedRelativePath(
                            components: [
                                "original",
                                "Chapter \(chapterNumber)",
                                "\(pageID.rawValue).png",
                            ]
                        ),
                        originalFileName: "\(pageID.rawValue).png",
                        detectedFormat: .png,
                        expectedByteCount: 128,
                        expectedLightweightFingerprint: nil,
                        pixelSize: ImportPixelSize(
                            width: 800,
                            height: 1_200
                        ),
                        orientation: .up,
                        pageState: .readable,
                        isCover: workItems.isEmpty
                    )
                )
            }

            chapters.append(
                FrozenImportChapter(
                    id: chapterID,
                    parentCollectionID: nil,
                    sourceDirectoryPath: SourceRelativePath(
                        components: [
                            "outside-source",
                            "Chapter \(chapterNumber)",
                        ]
                    ),
                    originalName: "Chapter \(chapterNumber)",
                    displayName: "Chapter \(chapterNumber)",
                    role: .directory,
                    pageIDs: pageIDs
                )
            )
        }

        let coverPageID = try XCTUnwrap(workItems.first?.id)
        let plan = FrozenImportPlan(
            id: ImportJobID(rawValue: UUID()),
            revision: ImportPreviewRevision(
                rawValue: "revision-\(displayName)"
            ),
            sourceRootName: "Source",
            displayName: displayName,
            sourceBookmark: Data("outside-bookmark".utf8),
            sortLocaleIdentifier: "en_US_POSIX",
            collections: [],
            chapters: chapters,
            workItems: workItems,
            coverPageID: coverPageID,
            scanIssues: [],
            spaceEstimate: .make(
                contentBytes: Int64(workItems.count * 128),
                fileCount: workItems.count
            )
        )
        let descriptor = ManagedComicDescriptor(
            plan: plan,
            journal: ImportJobJournal(plan: plan, targetComicID: comicID)
        )
        let layout = ImportStorageLayout(
            rootURL: URL(fileURLWithPath: "/tmp/ReaderScreenControllerTests")
        )

        return (
            comicID,
            LoadedReaderContent(
                comic: try ReaderComic(descriptor: descriptor),
                assetResolver: try ManagedReaderPageAssetResolver(
                    descriptor: descriptor,
                    expectedComicID: comicID,
                    layout: layout
                )
            )
        )
    }

    private func managedComicID() -> ManagedComicID {
        ManagedComicID(rawValue: UUID())
    }
}

private enum ReaderScreenControllerTestError: Error {
    case loaderRequestTimedOut
}

private struct ImmediateReaderContentLoader: ReaderContentLoading {
    let content: LoadedReaderContent

    func load(comicID: ManagedComicID) async throws -> LoadedReaderContent {
        content
    }
}

private struct FailingReaderContentLoader: ReaderContentLoading {
    let error: ReaderContentLoaderError

    func load(comicID: ManagedComicID) async throws -> LoadedReaderContent {
        throw error
    }
}

private struct SleepingReaderContentLoader: ReaderContentLoading {
    let content: LoadedReaderContent

    func load(comicID: ManagedComicID) async throws -> LoadedReaderContent {
        try await Task.sleep(nanoseconds: 60_000_000_000)
        return content
    }
}

private actor ControlledReaderContentLoader: ReaderContentLoading {
    private var continuations: [
        CheckedContinuation<LoadedReaderContent, Error>
    ] = []

    var requestCount: Int {
        continuations.count
    }

    func load(comicID: ManagedComicID) async throws -> LoadedReaderContent {
        try Task.checkCancellation()
        return try await withCheckedThrowingContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func resumeRequest(
        at index: Int,
        with content: LoadedReaderContent
    ) {
        continuations[index].resume(returning: content)
    }
}

@MainActor
private final class ScreenProgressRecorder: ReaderProgressRecording {
    struct Record {
        let progress: LibraryReadingProgress
        let comicID: ManagedComicID
    }

    private(set) var records: [Record] = []

    func recordProgress(
        _ progress: LibraryReadingProgress,
        for comicID: ManagedComicID
    ) async -> Bool {
        records.append(Record(progress: progress, comicID: comicID))
        return true
    }
}
