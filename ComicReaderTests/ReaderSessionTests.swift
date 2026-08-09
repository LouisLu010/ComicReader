import Foundation
import XCTest
@testable import ComicReader

final class ReaderSessionTests: XCTestCase {
    func testControlsStartVisibleAndToggleWithinTheSession() throws {
        var session = try makeSession(
            chapters: [
                chapter(
                    makeChapterID("chapter-1"),
                    pages: [page("page-1")]
                ),
            ]
        )

        XCTAssertTrue(session.controlsAreVisible)

        session.toggleControls()
        XCTAssertFalse(session.controlsAreVisible)

        session.toggleControls()
        XCTAssertTrue(session.controlsAreVisible)
    }

    func testContinuousLayoutKeepsLogicalPageOrderWithoutChapterBoundaries() throws {
        let firstChapterID = makeChapterID("chapter-1")
        let secondChapterID = makeChapterID("chapter-2")
        let firstPage = page("page-1")
        let secondPage = page("page-2")
        let thirdPage = page("page-3")
        let session = try makeSession(
            chapters: [
                chapter(firstChapterID, pages: [firstPage, secondPage]),
                chapter(secondChapterID, pages: [thirdPage]),
            ],
            readingMode: .continuous
        )

        XCTAssertEqual(session.layout.effectiveMode, .continuous)
        XCTAssertEqual(
            session.layout.presentations.flatMap(\.locations),
            [
                .chapter(firstChapterID, firstPage.id),
                .chapter(firstChapterID, secondPage.id),
                .chapter(secondChapterID, thirdPage.id),
            ]
        )
        XCTAssertFalse(session.layout.presentations.contains { isBoundary($0) })
        XCTAssertEqual(
            session.layout.chapterCompletionIDsByPresentationID,
            [
                session.layout.presentations[1].id: firstChapterID,
                session.layout.presentations[2].id: secondChapterID,
            ]
        )
    }

    func testSinglePageLayoutInsertsBoundaryAfterEveryChapterIncludingFinal() throws {
        let firstChapterID = makeChapterID("chapter-1")
        let secondChapterID = makeChapterID("chapter-2")
        let firstPage = page("page-1")
        let secondPage = page("page-2")
        let session = try makeSession(
            chapters: [
                chapter(firstChapterID, pages: [firstPage]),
                chapter(secondChapterID, pages: [secondPage]),
            ],
            readingMode: .singlePage
        )
        let presentations = session.layout.presentations

        XCTAssertEqual(presentations.count, 4)
        XCTAssertEqual(singlePage(from: presentations[0])?.location,
                       .chapter(firstChapterID, firstPage.id))
        XCTAssertEqual(
            boundary(from: presentations[1]),
            ReaderChapterBoundary(
                completedChapterID: firstChapterID,
                nextChapterID: secondChapterID
            )
        )
        XCTAssertEqual(singlePage(from: presentations[2])?.location,
                       .chapter(secondChapterID, secondPage.id))
        XCTAssertEqual(
            boundary(from: presentations[3]),
            ReaderChapterBoundary(
                completedChapterID: secondChapterID,
                nextChapterID: nil
            )
        )
        XCTAssertEqual(session.layout.pageCount, 2)
        XCTAssertEqual(
            session.layout.pageNumberByLocation,
            [
                .chapter(firstChapterID, firstPage.id): 1,
                .chapter(secondChapterID, secondPage.id): 2,
            ]
        )
    }

    func testSpreadKeepsEmbeddedCoverAndLandscapePagesStandalone() throws {
        let chapterID = makeChapterID("chapter-1")
        let cover = page("cover", isCover: true)
        let firstPortrait = page("page-1")
        let secondPortrait = page("page-2")
        let landscape = page("landscape", width: 1200, height: 1000)
        let finalPortrait = page("page-3")
        let session = try makeSession(
            chapters: [
                chapter(
                    chapterID,
                    pages: [
                        cover,
                        firstPortrait,
                        secondPortrait,
                        landscape,
                        finalPortrait,
                    ]
                ),
            ],
            readingMode: .spread
        )
        let presentations = session.layout.presentations

        XCTAssertEqual(presentations.count, 5)
        XCTAssertEqual(singlePage(from: presentations[0])?.location,
                       .chapter(chapterID, cover.id))
        XCTAssertEqual(
            spread(from: presentations[1])?.pagesInReadingOrder.map(\.page.id),
            [firstPortrait.id, secondPortrait.id]
        )
        XCTAssertEqual(singlePage(from: presentations[2])?.location,
                       .chapter(chapterID, landscape.id))
        XCTAssertEqual(
            spread(from: presentations[3])?.leadingPage?.page.id,
            finalPortrait.id
        )
        XCTAssertNil(spread(from: presentations[3])?.trailingPage)
        XCTAssertEqual(
            boundary(from: presentations[4]),
            ReaderChapterBoundary(
                completedChapterID: chapterID,
                nextChapterID: nil
            )
        )
    }

    func testSpreadMirrorsPhysicalSlotsForRightToLeftWithoutReversingOrder() throws {
        let chapterID = makeChapterID("chapter-1")
        let firstPage = page("page-1")
        let secondPage = page("page-2")
        let chapter = chapter(chapterID, pages: [firstPage, secondPage])
        let leftToRight = try makeSession(
            chapters: [chapter],
            readingMode: .spread,
            readingDirection: .leftToRight
        )
        let rightToLeft = try makeSession(
            chapters: [chapter],
            readingMode: .spread,
            readingDirection: .rightToLeft
        )
        let leftToRightSpread = try XCTUnwrap(
            spread(from: leftToRight.layout.presentations[0])
        )
        let rightToLeftSpread = try XCTUnwrap(
            spread(from: rightToLeft.layout.presentations[0])
        )

        XCTAssertEqual(
            rightToLeftSpread.pagesInReadingOrder.map(\.page.id),
            [firstPage.id, secondPage.id]
        )
        XCTAssertEqual(leftToRightSpread.leadingPage?.page.id, firstPage.id)
        XCTAssertEqual(leftToRightSpread.trailingPage?.page.id, secondPage.id)
        XCTAssertEqual(rightToLeftSpread.leadingPage?.page.id, secondPage.id)
        XCTAssertEqual(rightToLeftSpread.trailingPage?.page.id, firstPage.id)
    }

    func testRightToLeftOddSpreadUsesTrailingSlotForFinalPage() throws {
        let chapterID = makeChapterID("chapter-1")
        let firstPage = page("page-1")
        let secondPage = page("page-2")
        let finalPage = page("page-3")
        let session = try makeSession(
            chapters: [chapter(chapterID, pages: [
                firstPage,
                secondPage,
                finalPage,
            ])],
            readingMode: .spread,
            readingDirection: .rightToLeft
        )
        let finalSpread = try XCTUnwrap(
            spread(from: session.layout.presentations[1])
        )

        XCTAssertEqual(finalSpread.pagesInReadingOrder.map(\.page.id),
                       [finalPage.id])
        XCTAssertNil(finalSpread.leadingPage)
        XCTAssertEqual(finalSpread.trailingPage?.page.id, finalPage.id)
    }

    func testSpreadResetsPairingAtChapterBoundaries() throws {
        let firstChapterID = makeChapterID("chapter-1")
        let secondChapterID = makeChapterID("chapter-2")
        let firstPage = page("page-1")
        let secondPage = page("page-2")
        let session = try makeSession(
            chapters: [
                chapter(firstChapterID, pages: [firstPage]),
                chapter(secondChapterID, pages: [secondPage]),
            ],
            readingMode: .spread
        )
        let presentations = session.layout.presentations

        XCTAssertEqual(presentations.count, 4)
        XCTAssertEqual(
            spread(from: presentations[0])?.pagesInReadingOrder.map(\.page.id),
            [firstPage.id]
        )
        XCTAssertEqual(
            boundary(from: presentations[1])?.completedChapterID,
            firstChapterID
        )
        XCTAssertEqual(
            spread(from: presentations[2])?.pagesInReadingOrder.map(\.page.id),
            [secondPage.id]
        )
        XCTAssertEqual(
            boundary(from: presentations[3]),
            ReaderChapterBoundary(
                completedChapterID: secondChapterID,
                nextChapterID: nil
            )
        )
    }

    func testStandaloneCoverUsesTypedLocationAndDoesNotShiftChapterContent() throws {
        let chapterID = makeChapterID("chapter-1")
        let cover = page("root-cover", isCover: true)
        let firstPage = page("page-1")
        let secondPage = page("page-2")
        let session = try makeSession(
            chapters: [chapter(chapterID, pages: [firstPage, secondPage])],
            cover: cover,
            readingMode: .spread
        )

        XCTAssertEqual(session.position.location, .cover(cover.id))
        XCTAssertNil(session.position.chapterID)
        XCTAssertEqual(session.position.storageChapterID,
                       ReaderPageLocation.coverStorageChapterID)
        XCTAssertEqual(singlePage(from: session.layout.presentations[0])?.location,
                       .cover(cover.id))
        XCTAssertEqual(
            spread(from: session.layout.presentations[1])?.pagesInReadingOrder.map(\.page.id),
            [firstPage.id, secondPage.id]
        )
    }

    func testDescriptorAdapterKeepsSelectedChapterCoverAtOriginalPosition() throws {
        let chapterID = makeChapterID("chapter-1")
        let firstPageID = makePageID("page-1")
        let coverPageID = makePageID("page-2")
        let finalPageID = makePageID("page-3")
        let descriptor = makeDescriptor(
            coverPageID: coverPageID,
            chapters: [
                FrozenImportChapter(
                    id: chapterID,
                    parentCollectionID: nil,
                    sourceDirectoryPath: .root,
                    originalName: "Chapter 1",
                    displayName: "Chapter 1",
                    role: .directory,
                    pageIDs: [firstPageID, coverPageID, finalPageID]
                ),
            ],
            workItems: [
                workItem(coverPageID, isCover: true),
                workItem(firstPageID),
                workItem(finalPageID),
            ]
        )
        let comic = try ReaderComic(descriptor: descriptor)
        let session = try ReaderSession(comic: comic, readingMode: .spread)

        XCTAssertNil(comic.cover)
        XCTAssertEqual(comic.chapters[0].pages.map(\.id),
                       [firstPageID, coverPageID, finalPageID])
        XCTAssertTrue(comic.chapters[0].pages[1].isCover)
        XCTAssertEqual(
            session.layout.presentations.flatMap(\.locations),
            [
                .chapter(chapterID, firstPageID),
                .chapter(chapterID, coverPageID),
                .chapter(chapterID, finalPageID),
            ]
        )
    }

    func testDescriptorAdapterUsesPersistedDisplaySizeForSpreadPairing() throws {
        let chapterID = makeChapterID("chapter-1")
        let rootCoverID = makePageID("root-cover")
        let firstPageID = makePageID("page-1")
        let secondPageID = makePageID("page-2")
        let descriptor = makeDescriptor(
            coverPageID: rootCoverID,
            chapters: [
                FrozenImportChapter(
                    id: chapterID,
                    parentCollectionID: nil,
                    sourceDirectoryPath: .root,
                    originalName: "Chapter 1",
                    displayName: "Chapter 1",
                    role: .directory,
                    pageIDs: [firstPageID, secondPageID]
                ),
            ],
            workItems: [
                workItem(rootCoverID, isCover: true),
                workItem(
                    firstPageID,
                    pixelSize: ImportPixelSize(width: 1800, height: 1200),
                    orientation: .right
                ),
                workItem(
                    secondPageID,
                    pixelSize: ImportPixelSize(width: 1200, height: 1800)
                ),
            ]
        )
        let comic = try ReaderComic(descriptor: descriptor)
        let session = try ReaderSession(comic: comic, readingMode: .spread)
        let chapterSpread = try XCTUnwrap(
            spread(from: session.layout.presentations[1])
        )

        XCTAssertEqual(comic.cover?.id, rootCoverID)
        XCTAssertEqual(
            comic.chapters[0].pages[0].displayPixelSize,
            ImportPixelSize(width: 1200, height: 1800)
        )
        XCTAssertEqual(session.layout.presentations.count, 3)
        XCTAssertEqual(
            chapterSpread.pagesInReadingOrder.map(\.page.id),
            [firstPageID, secondPageID]
        )
    }

    func testSessionKeepsPositionWhenSpreadCapabilityChanges() throws {
        let chapterID = makeChapterID("chapter-1")
        let firstPage = page("page-1")
        let secondPage = page("page-2")
        let restoredPosition = ReadingPosition(
            location: .chapter(chapterID, secondPage.id),
            pageOffset: 0.25,
            zoomScale: 2
        )
        var session = try makeSession(
            chapters: [chapter(chapterID, pages: [firstPage, secondPage])],
            readingMode: .spread,
            restoredPosition: restoredPosition
        )

        XCTAssertEqual(session.layout.effectiveMode, .spread)
        XCTAssertEqual(session.currentPresentationIndex, 0)

        session.setLayoutCapability(.singlePageOnly)

        XCTAssertEqual(session.readingMode, .spread)
        XCTAssertEqual(session.layout.effectiveMode, .singlePage)
        XCTAssertEqual(session.position, restoredPosition)
        XCTAssertEqual(session.currentPresentationIndex, 1)

        session.setLayoutCapability(.spreadCapable)

        XCTAssertEqual(session.layout.effectiveMode, .spread)
        XCTAssertEqual(session.currentPresentationIndex, 0)
    }

    func testSessionUpdatesModeAndDirectionWithoutChangingPosition() throws {
        let chapterID = makeChapterID("chapter-1")
        let firstPage = page("page-1")
        let secondPage = page("page-2")
        var session = try makeSession(
            chapters: [chapter(chapterID, pages: [firstPage, secondPage])],
            readingMode: .singlePage
        )
        let initialPosition = session.position

        session.setReadingPreferences(
            mode: .spread,
            direction: .rightToLeft
        )

        let firstPresentation = try XCTUnwrap(
            session.layout.presentations.first
        )
        let layoutSpread = try XCTUnwrap(spread(from: firstPresentation))
        XCTAssertEqual(session.position, initialPosition)
        XCTAssertEqual(session.readingMode, .spread)
        XCTAssertEqual(session.readingDirection, .rightToLeft)
        XCTAssertEqual(layoutSpread.leadingPage?.page.id, secondPage.id)
        XCTAssertEqual(layoutSpread.trailingPage?.page.id, firstPage.id)
    }

    func testReadingPositionClampsValuesAndRoundTripsStorageIdentifiers() throws {
        let coverPageID = makePageID("root-cover")
        let coverPosition = ReadingPosition(
            location: .cover(coverPageID),
            pageOffset: -0.5,
            zoomScale: .infinity
        )
        let restoredCover = try XCTUnwrap(
            ReadingPosition(
                storageChapterID: coverPosition.storageChapterID,
                pageID: coverPosition.pageID.rawValue,
                pageOffset: 2,
                zoomScale: 99
            )
        )
        let chapterID = makeChapterID("chapter-1")
        let chapterPageID = makePageID("page-1")
        let chapterPosition = ReadingPosition(
            location: .chapter(chapterID, chapterPageID),
            pageOffset: 0.5,
            zoomScale: 2
        )
        let restoredChapter = try XCTUnwrap(
            ReadingPosition(
                storageChapterID: chapterPosition.storageChapterID,
                pageID: chapterPosition.pageID.rawValue,
                pageOffset: chapterPosition.pageOffset,
                zoomScale: chapterPosition.zoomScale
            )
        )

        XCTAssertEqual(coverPosition.pageOffset, 0)
        XCTAssertEqual(coverPosition.zoomScale, 1)
        XCTAssertEqual(restoredCover.location, .cover(coverPageID))
        XCTAssertEqual(restoredCover.pageOffset, 1)
        XCTAssertEqual(restoredCover.zoomScale, 16)
        XCTAssertEqual(restoredChapter, chapterPosition)
        XCTAssertNil(ReadingPosition(storageChapterID: "", pageID: "page"))
        XCTAssertNil(ReadingPosition(storageChapterID: "chapter", pageID: " "))
    }

    func testSessionUpdatesOnlyZoomScaleAndClampsCommittedValue() throws {
        let chapterID = makeChapterID("chapter-1")
        let firstPage = page("page-1")
        let originalPosition = ReadingPosition(
            location: .chapter(chapterID, firstPage.id),
            pageOffset: 0.375,
            zoomScale: 2
        )
        var session = try makeSession(
            chapters: [chapter(chapterID, pages: [firstPage])],
            restoredPosition: originalPosition
        )
        let originalLayout = session.layout

        XCTAssertTrue(session.setZoomScale(99))
        XCTAssertEqual(session.position.location, originalPosition.location)
        XCTAssertEqual(session.position.pageOffset, originalPosition.pageOffset)
        XCTAssertEqual(session.position.zoomScale, 16)
        XCTAssertEqual(session.layout, originalLayout)
        XCTAssertTrue(session.setZoomScale(.infinity))
        XCTAssertEqual(session.position.zoomScale, 1)
        XCTAssertFalse(session.setZoomScale(.infinity))
    }

    func testRestoreRejectsMismatchedChapterAndPageWithoutChangingPosition() throws {
        let firstChapterID = makeChapterID("chapter-1")
        let secondChapterID = makeChapterID("chapter-2")
        let firstPage = page("page-1")
        let secondPage = page("page-2")
        var session = try makeSession(
            chapters: [
                chapter(firstChapterID, pages: [firstPage]),
                chapter(secondChapterID, pages: [secondPage]),
            ]
        )
        let initialPosition = session.position

        XCTAssertFalse(session.restore(
            ReadingPosition(location: .chapter(firstChapterID, secondPage.id))
        ))
        XCTAssertEqual(session.position, initialPosition)
        XCTAssertTrue(session.move(
            to: .chapter(secondChapterID, secondPage.id),
            pageOffset: 0.25,
            zoomScale: 2
        ))
        XCTAssertEqual(session.position.location,
                       .chapter(secondChapterID, secondPage.id))
        XCTAssertEqual(session.position.pageOffset, 0.25)
        XCTAssertEqual(session.position.zoomScale, 2)
    }

    func testSessionFallsBackToFirstPageForInvalidRestoredPosition() throws {
        let chapterID = makeChapterID("chapter-1")
        let firstPage = page("page-1")
        let session = try makeSession(
            chapters: [chapter(chapterID, pages: [firstPage])],
            restoredPosition: ReadingPosition(
                location: .chapter(
                    makeChapterID("missing-chapter"),
                    makePageID("missing-page")
                ),
                pageOffset: 0.75,
                zoomScale: 3
            )
        )

        XCTAssertEqual(session.position,
                       ReadingPosition(location: .chapter(chapterID, firstPage.id)))
    }

    func testProgressMarksChapterCompletedOnlyAtLastPageEnd() throws {
        let chapterID = makeChapterID("chapter-1")
        let firstPage = page("page-1")
        let lastPage = page("page-2")
        var session = try makeSession(
            chapters: [chapter(chapterID, pages: [firstPage, lastPage])]
        )

        XCTAssertTrue(session.move(
            to: .chapter(chapterID, lastPage.id),
            pageOffset: 0.999,
            zoomScale: 1.5
        ))
        XCTAssertFalse(session.progress.isChapterCompleted)
        XCTAssertTrue(session.move(
            to: .chapter(chapterID, lastPage.id),
            pageOffset: 1,
            zoomScale: 1.5
        ))
        XCTAssertTrue(session.progress.isChapterCompleted)
        XCTAssertEqual(session.progress.mode, .continuous)
        XCTAssertEqual(session.progress.direction, .leftToRight)
    }

    func testContinuousCompletionMergeFiltersUnknownIDsAndRejectsPagedMode() throws {
        let firstChapterID = makeChapterID("chapter-1")
        let finalChapterID = makeChapterID("chapter-2")
        let unknownChapterID = makeChapterID("missing-chapter")
        let chapters = [
            chapter(firstChapterID, pages: [page("page-1")]),
            chapter(finalChapterID, pages: [page("page-2")]),
        ]
        var continuousSession = try makeSession(chapters: chapters)

        XCTAssertTrue(continuousSession.markContinuousChaptersCompleted([
            firstChapterID,
            unknownChapterID,
        ]))
        XCTAssertEqual(
            continuousSession.completedChapterIDs,
            [firstChapterID]
        )
        XCTAssertFalse(continuousSession.progress.hasReachedFinalChapterEnd)
        XCTAssertFalse(continuousSession.markContinuousChaptersCompleted([
            unknownChapterID,
        ]))

        var pagedSession = try makeSession(
            chapters: chapters,
            readingMode: .singlePage
        )
        XCTAssertFalse(pagedSession.markContinuousChaptersCompleted([
            firstChapterID,
        ]))
        XCTAssertTrue(pagedSession.completedChapterIDs.isEmpty)
    }

    func testPagedSessionRecordsCompletionWhenFinalPresentationFinishes() throws {
        let chapterID = makeChapterID("chapter-1")
        let firstPage = page("page-1")
        let middlePage = page("page-2")
        let finalPage = page("page-3")
        var spreadSession = try makeSession(
            chapters: [chapter(chapterID, pages: [
                firstPage,
                middlePage,
                finalPage,
            ])],
            readingMode: .spread
        )

        XCTAssertFalse(spreadSession.markCurrentPresentationCompleted())
        XCTAssertTrue(spreadSession.move(
            to: .chapter(chapterID, finalPage.id)
        ))
        XCTAssertTrue(spreadSession.markCurrentPresentationCompleted())
        XCTAssertTrue(spreadSession.progress.isChapterCompleted)
        XCTAssertFalse(spreadSession.markCurrentPresentationCompleted())

        var singlePageSession = try makeSession(
            chapters: [chapter(chapterID, pages: [firstPage, finalPage])],
            readingMode: .singlePage
        )

        XCTAssertFalse(singlePageSession.markCurrentPresentationCompleted())
        XCTAssertTrue(singlePageSession.move(
            to: .chapter(chapterID, finalPage.id)
        ))
        XCTAssertTrue(singlePageSession.markCurrentPresentationCompleted())
        XCTAssertTrue(singlePageSession.progress.isChapterCompleted)
    }

    func testChapterBoundaryCompletionUsesExplicitBoundaryInsteadOfCurrentPage() throws {
        let firstChapterID = makeChapterID("chapter-1")
        let finalChapterID = makeChapterID("chapter-2")
        let firstPage = page("page-1")
        let finalPage = page("page-2")
        var session = try makeSession(
            chapters: [
                chapter(firstChapterID, pages: [firstPage]),
                chapter(finalChapterID, pages: [finalPage]),
            ],
            readingMode: .singlePage
        )
        let finalBoundary = try XCTUnwrap(
            session.layout.presentations.compactMap { boundary(from: $0) }.last
        )

        XCTAssertEqual(session.position.location, .chapter(firstChapterID, firstPage.id))
        XCTAssertEqual(finalBoundary.completedChapterID, finalChapterID)
        XCTAssertNil(finalBoundary.nextChapterID)

        // 模拟快速跳到结束页：Session 仍停留在前一话的页面。
        XCTAssertTrue(session.markChapterBoundaryCompleted(finalBoundary))
        XCTAssertEqual(session.completedChapterIDs, [finalChapterID])
        XCTAssertTrue(session.progress.hasReachedFinalChapterEnd)
        XCTAssertFalse(session.markChapterBoundaryCompleted(finalBoundary))
    }

    func testChapterBoundaryCompletionRejectsStaleAndContinuousBoundaries() throws {
        let firstChapterID = makeChapterID("chapter-1")
        let secondChapterID = makeChapterID("chapter-2")
        let firstPage = page("page-1")
        let secondPage = page("page-2")
        var pagedSession = try makeSession(
            chapters: [
                chapter(firstChapterID, pages: [firstPage]),
                chapter(secondChapterID, pages: [secondPage]),
            ],
            readingMode: .singlePage
        )
        let firstBoundary = try XCTUnwrap(
            pagedSession.layout.presentations.compactMap {
                boundary(from: $0)
            }.first
        )
        let staleBoundary = ReaderChapterBoundary(
            completedChapterID: firstChapterID,
            nextChapterID: nil
        )

        XCTAssertFalse(pagedSession.markChapterBoundaryCompleted(staleBoundary))
        XCTAssertTrue(pagedSession.markChapterBoundaryCompleted(firstBoundary))

        var continuousSession = try makeSession(
            chapters: [
                chapter(firstChapterID, pages: [firstPage]),
                chapter(secondChapterID, pages: [secondPage]),
            ],
            readingMode: .continuous
        )
        XCTAssertFalse(continuousSession.markChapterBoundaryCompleted(firstBoundary))
        XCTAssertFalse(
            continuousSession.layout.presentations.contains { isBoundary($0) }
        )
    }

    func testLayoutCachesLookupSnapshotAndPagedRightToLeftDisplayOrder() throws {
        let firstChapterID = makeChapterID("chapter-1")
        let secondChapterID = makeChapterID("chapter-2")
        let firstPage = page("page-1")
        let secondPage = page("page-2")
        let thirdPage = page("page-3")
        let chapters = [
            chapter(firstChapterID, pages: [firstPage, secondPage]),
            chapter(secondChapterID, pages: [thirdPage]),
        ]
        let leftToRight = try makeSession(
            chapters: chapters,
            readingMode: .spread,
            readingDirection: .leftToRight
        )
        let rightToLeft = try makeSession(
            chapters: chapters,
            readingMode: .spread,
            readingDirection: .rightToLeft
        )
        let layout = rightToLeft.layout
        let firstLocation = ReaderPageLocation.chapter(firstChapterID, firstPage.id)
        let secondLocation = ReaderPageLocation.chapter(
            firstChapterID,
            secondPage.id
        )
        let thirdLocation = ReaderPageLocation.chapter(
            secondChapterID,
            thirdPage.id
        )
        let firstPresentationID = try XCTUnwrap(
            layout.presentationID(for: firstLocation)
        )

        XCTAssertEqual(
            layout.presentations.map(\.id),
            leftToRight.layout.presentations.map(\.id)
        )
        XCTAssertEqual(layout.presentationsByID[firstPresentationID]?.id,
                       firstPresentationID)
        XCTAssertEqual(layout.presentationIndicesByID[firstPresentationID], 0)
        XCTAssertEqual(layout.presentationIDsByLocation[firstLocation],
                       firstPresentationID)
        XCTAssertEqual(layout.presentationIndicesByLocation[firstLocation], 0)
        XCTAssertEqual(layout.presentation(for: firstPresentationID)?.id,
                       firstPresentationID)
        XCTAssertEqual(layout.presentationIndex(for: firstPresentationID), 0)
        XCTAssertEqual(layout.presentationIndex(for: firstLocation), 0)
        XCTAssertEqual(layout.pageCount, 3)
        XCTAssertEqual(
            layout.pageNumberByLocation,
            [
                firstLocation: 1,
                secondLocation: 2,
                thirdLocation: 3,
            ]
        )
        XCTAssertEqual(layout.pageNumber(for: firstLocation), 1)
        XCTAssertEqual(layout.pageNumber(for: secondLocation), 2)
        XCTAssertEqual(layout.pageNumber(for: thirdLocation), 3)
        XCTAssertEqual(
            layout.pagedDisplayPresentations.map(\.id),
            Array(layout.presentations.map(\.id).reversed())
        )
        XCTAssertEqual(
            layout.pagedDisplayPresentationIndex(for: firstPresentationID),
            layout.presentations.count - 1
        )

        let continuousLayout = try makeSession(
            chapters: chapters,
            readingMode: .continuous,
            readingDirection: .rightToLeft
        ).layout
        XCTAssertEqual(
            continuousLayout.pagedDisplayPresentations.map(\.id),
            continuousLayout.presentations.map(\.id)
        )
    }

    func testSpreadCompletionUsesEffectiveSinglePageLayoutWhenWindowNarrows() throws {
        let chapterID = makeChapterID("chapter-1")
        let firstPage = page("page-1")
        let finalPage = page("page-2")
        var session = try makeSession(
            chapters: [chapter(chapterID, pages: [firstPage, finalPage])],
            readingMode: .spread,
            layoutCapability: .singlePageOnly
        )

        XCTAssertEqual(session.layout.effectiveMode, .singlePage)
        XCTAssertFalse(session.markCurrentPresentationCompleted())
        XCTAssertTrue(session.move(to: .chapter(chapterID, finalPage.id)))
        XCTAssertTrue(session.markCurrentPresentationCompleted())
        XCTAssertTrue(session.progress.isChapterCompleted)
    }

    func testProgressDoesNotReachFinalChapterEndWhenOnlyFirstChapterCompletes() throws {
        let firstChapterID = makeChapterID("chapter-1")
        let finalChapterID = makeChapterID("chapter-2")
        let firstChapterPage = page("page-1")
        let finalChapterPage = page("page-2")
        var session = try makeSession(
            chapters: [
                chapter(firstChapterID, pages: [firstChapterPage]),
                chapter(finalChapterID, pages: [finalChapterPage]),
            ]
        )

        XCTAssertTrue(session.move(
            to: .chapter(firstChapterID, firstChapterPage.id),
            pageOffset: 1
        ))

        XCTAssertTrue(session.progress.isChapterCompleted)
        XCTAssertFalse(session.progress.hasReachedFinalChapterEnd)
    }

    func testContinuousProgressReachesFinalChapterEndAtFinalPageEnd() throws {
        let firstChapterID = makeChapterID("chapter-1")
        let finalChapterID = makeChapterID("chapter-2")
        let firstChapterPage = page("page-1")
        let finalChapterPage = page("page-2")
        var session = try makeSession(
            chapters: [
                chapter(firstChapterID, pages: [firstChapterPage]),
                chapter(finalChapterID, pages: [finalChapterPage]),
            ]
        )

        XCTAssertTrue(session.move(
            to: .chapter(finalChapterID, finalChapterPage.id),
            pageOffset: 0.999
        ))
        XCTAssertFalse(session.progress.hasReachedFinalChapterEnd)

        XCTAssertTrue(session.move(
            to: .chapter(finalChapterID, finalChapterPage.id),
            pageOffset: 1
        ))
        XCTAssertTrue(session.progress.hasReachedFinalChapterEnd)
    }

    func testPagedProgressReachesFinalChapterEndWhenFinalPresentationFinishes() throws {
        let firstChapterID = makeChapterID("chapter-1")
        let finalChapterID = makeChapterID("chapter-2")
        let firstChapterPage = page("page-1")
        let finalChapterFirstPage = page("page-2")
        let finalChapterLastPage = page("page-3")

        for readingMode in [ReadingMode.singlePage, .spread] {
            var session = try makeSession(
                chapters: [
                    chapter(firstChapterID, pages: [firstChapterPage]),
                    chapter(
                        finalChapterID,
                        pages: [finalChapterFirstPage, finalChapterLastPage]
                    ),
                ],
                readingMode: readingMode
            )

            XCTAssertTrue(session.move(
                to: .chapter(finalChapterID, finalChapterLastPage.id)
            ))
            XCTAssertTrue(session.markCurrentPresentationCompleted())
            XCTAssertTrue(session.progress.hasReachedFinalChapterEnd)
        }
    }

    func testRestoredCompletedChapterIDsKeepOnlyChaptersInComic() throws {
        let firstChapterID = makeChapterID("chapter-1")
        let finalChapterID = makeChapterID("chapter-2")
        let unknownChapterID = makeChapterID("missing-chapter")
        let firstPage = page("page-1")
        let finalPage = page("page-2")
        let session = try makeSession(
            chapters: [
                chapter(firstChapterID, pages: [firstPage]),
                chapter(finalChapterID, pages: [finalPage]),
            ],
            restoredCompletedChapterIDs: [
                firstChapterID,
                finalChapterID,
                unknownChapterID,
            ]
        )

        XCTAssertEqual(
            session.completedChapterIDs,
            [firstChapterID, finalChapterID]
        )
        XCTAssertEqual(
            session.progress.completedChapterIDs,
            [firstChapterID, finalChapterID]
        )
        XCTAssertTrue(session.progress.isChapterCompleted)
        XCTAssertTrue(session.progress.hasReachedFinalChapterEnd)
    }

    func testStandaloneCoverDoesNotReachFinalChapterEnd() throws {
        let cover = page("root-cover", isCover: true)
        let session = try makeSession(chapters: [], cover: cover)

        XCTAssertEqual(session.position.location, .cover(cover.id))
        XCTAssertFalse(session.progress.hasReachedFinalChapterEnd)
    }

    func testProgressRetainsFinalChapterEndAfterReturningToEarlierChapter() throws {
        let firstChapterID = makeChapterID("chapter-1")
        let finalChapterID = makeChapterID("chapter-2")
        let firstChapterPage = page("page-1")
        let finalChapterPage = page("page-2")
        var session = try makeSession(
            chapters: [
                chapter(firstChapterID, pages: [firstChapterPage]),
                chapter(finalChapterID, pages: [finalChapterPage]),
            ]
        )

        XCTAssertTrue(session.move(
            to: .chapter(finalChapterID, finalChapterPage.id),
            pageOffset: 1
        ))
        XCTAssertTrue(session.progress.hasReachedFinalChapterEnd)

        XCTAssertTrue(session.move(
            to: .chapter(firstChapterID, firstChapterPage.id)
        ))
        XCTAssertFalse(session.progress.isChapterCompleted)
        XCTAssertTrue(session.progress.hasReachedFinalChapterEnd)
    }

    func testCorruptedPageRemainsAStandaloneStablePlaceholder() throws {
        let chapterID = makeChapterID("chapter-1")
        let firstPage = page("page-1")
        let corruptedPage = page(
            "broken",
            state: .corrupted,
            originalFileName: "broken-page.png"
        )
        let finalPage = page("page-2")
        let session = try makeSession(
            chapters: [chapter(chapterID, pages: [
                firstPage,
                corruptedPage,
                finalPage,
            ])],
            readingMode: .spread
        )
        let presentations = session.layout.presentations

        XCTAssertEqual(presentations.count, 4)
        XCTAssertEqual(
            spread(from: presentations[0])?.pagesInReadingOrder.map(\.page.id),
            [firstPage.id]
        )
        XCTAssertEqual(singlePage(from: presentations[1])?.page.originalFileName,
                       "broken-page.png")
        XCTAssertEqual(
            spread(from: presentations[2])?.pagesInReadingOrder.map(\.page.id),
            [finalPage.id]
        )
        XCTAssertEqual(
            boundary(from: presentations[3])?.completedChapterID,
            chapterID
        )
    }

    func testUnknownDisplaySizeRemainsStandaloneUntilMetadataIsAvailable() throws {
        let chapterID = makeChapterID("chapter-1")
        let unknownSizePage = ReaderPage(id: makePageID("unknown"))
        let knownSizePage = page("known")
        let session = try makeSession(
            chapters: [chapter(chapterID, pages: [
                unknownSizePage,
                knownSizePage,
            ])],
            readingMode: .spread
        )

        XCTAssertEqual(session.layout.presentations.count, 3)
        XCTAssertEqual(singlePage(from: session.layout.presentations[0])?.page.id,
                       unknownSizePage.id)
        XCTAssertEqual(
            spread(from: session.layout.presentations[1])?.pagesInReadingOrder.map(\.page.id),
            [knownSizePage.id]
        )
    }

    func testRejectsEmptyComicAndDuplicatePageIdentifiers() throws {
        let emptyComic = ReaderComic(
            id: comicID(),
            displayName: "Empty",
            chapters: []
        )
        let duplicatePage = page("duplicate")
        let duplicateComic = ReaderComic(
            id: comicID(),
            displayName: "Duplicate",
            chapters: [
                chapter(makeChapterID("chapter-1"), pages: [duplicatePage]),
                chapter(makeChapterID("chapter-2"), pages: [duplicatePage]),
            ]
        )

        XCTAssertThrowsError(try ReaderSession(comic: emptyComic)) { error in
            XCTAssertEqual(error as? ReaderSessionError, .emptyComic)
        }
        XCTAssertThrowsError(try ReaderSession(comic: duplicateComic)) { error in
            XCTAssertEqual(
                error as? ReaderSessionError,
                .duplicatePageID(duplicatePage.id)
            )
        }
    }

    func testRejectsEmptyDuplicateAndCoverCollidingChapterContent() throws {
        let emptyChapterID = makeChapterID("empty-chapter")
        let emptyChapterComic = ReaderComic(
            id: comicID(),
            displayName: "Empty Chapter",
            chapters: [chapter(emptyChapterID, pages: [])]
        )
        let duplicateChapterID = makeChapterID("duplicate-chapter")
        let duplicateChapterComic = ReaderComic(
            id: comicID(),
            displayName: "Duplicate Chapter",
            chapters: [
                chapter(duplicateChapterID, pages: [page("page-1")]),
                chapter(duplicateChapterID, pages: [page("page-2")]),
            ]
        )
        let sharedPage = page("shared-page")
        let coverCollisionComic = ReaderComic(
            id: comicID(),
            displayName: "Cover Collision",
            cover: sharedPage,
            chapters: [
                chapter(makeChapterID("chapter-1"), pages: [sharedPage]),
            ]
        )

        XCTAssertThrowsError(try ReaderSession(comic: emptyChapterComic)) { error in
            XCTAssertEqual(
                error as? ReaderSessionError,
                .emptyChapter(emptyChapterID)
            )
        }
        XCTAssertThrowsError(try ReaderSession(comic: duplicateChapterComic)) { error in
            XCTAssertEqual(
                error as? ReaderSessionError,
                .duplicateChapterID(duplicateChapterID)
            )
        }
        XCTAssertThrowsError(try ReaderSession(comic: coverCollisionComic)) { error in
            XCTAssertEqual(
                error as? ReaderSessionError,
                .duplicatePageID(sharedPage.id)
            )
        }
    }

    func testDescriptorAdapterRejectsMissingReferencedPage() throws {
        let coverPageID = makePageID("cover")
        let missingPageID = makePageID("missing")
        let descriptor = makeDescriptor(
            coverPageID: coverPageID,
            chapters: [
                FrozenImportChapter(
                    id: makeChapterID("chapter-1"),
                    parentCollectionID: nil,
                    sourceDirectoryPath: .root,
                    originalName: "Chapter 1",
                    displayName: "Chapter 1",
                    role: .directory,
                    pageIDs: [missingPageID]
                ),
            ],
            workItems: [workItem(coverPageID, isCover: true)]
        )

        XCTAssertThrowsError(try ReaderComic(descriptor: descriptor)) { error in
            XCTAssertEqual(
                error as? ReaderComicError,
                .missingPageWorkItem(missingPageID)
            )
        }
    }

    func testDescriptorAdapterRejectsMissingCoverAndDuplicateWorkItems() throws {
        let missingCoverID = makePageID("missing-cover")
        let availablePageID = makePageID("available")
        let missingCoverDescriptor = makeDescriptor(
            coverPageID: missingCoverID,
            chapters: [],
            workItems: [workItem(availablePageID)]
        )
        let duplicatePageID = makePageID("duplicate")
        let duplicateWorkItemsDescriptor = makeDescriptor(
            coverPageID: duplicatePageID,
            chapters: [],
            workItems: [
                workItem(duplicatePageID, isCover: true),
                workItem(duplicatePageID, isCover: true),
            ]
        )

        XCTAssertThrowsError(
            try ReaderComic(descriptor: missingCoverDescriptor)
        ) { error in
            XCTAssertEqual(
                error as? ReaderComicError,
                .missingCoverWorkItem(missingCoverID)
            )
        }
        XCTAssertThrowsError(
            try ReaderComic(descriptor: duplicateWorkItemsDescriptor)
        ) { error in
            XCTAssertEqual(
                error as? ReaderComicError,
                .duplicatePageWorkItem(duplicatePageID)
            )
        }
    }

    private func makeSession(
        chapters: [ReaderChapter],
        cover: ReaderPage? = nil,
        readingMode: ReadingMode = .continuous,
        readingDirection: ReadingDirection = .leftToRight,
        layoutCapability: ReaderLayoutCapability = .spreadCapable,
        restoredPosition: ReadingPosition? = nil,
        restoredCompletedChapterIDs: Set<ImportChapterCandidate.ID> = []
    ) throws -> ReaderSession {
        try ReaderSession(
            comic: ReaderComic(
                id: comicID(),
                displayName: "Reader Test Comic",
                cover: cover,
                chapters: chapters
            ),
            readingMode: readingMode,
            readingDirection: readingDirection,
            layoutCapability: layoutCapability,
            restoredPosition: restoredPosition,
            restoredCompletedChapterIDs: restoredCompletedChapterIDs
        )
    }

    private func comicID() -> ManagedComicID {
        ManagedComicID(
            rawValue: UUID(
                uuidString: "00000000-0000-0000-0000-000000000701"
            )!
        )
    }

    private func makeChapterID(_ rawValue: String) -> ImportChapterCandidate.ID {
        ImportChapterCandidate.ID(rawValue: rawValue)
    }

    private func makePageID(_ rawValue: String) -> ImportPageCandidate.ID {
        ImportPageCandidate.ID(rawValue: rawValue)
    }

    private func chapter(
        _ id: ImportChapterCandidate.ID,
        pages: [ReaderPage]
    ) -> ReaderChapter {
        ReaderChapter(id: id, displayName: id.rawValue, pages: pages)
    }

    private func page(
        _ rawValue: String,
        width: Int = 1200,
        height: Int = 1800,
        state: ImportPageState = .readable,
        isCover: Bool = false,
        originalFileName: String = ""
    ) -> ReaderPage {
        ReaderPage(
            id: makePageID(rawValue),
            originalFileName: originalFileName,
            displayPixelSize: ImportPixelSize(width: width, height: height),
            state: state,
            isCover: isCover
        )
    }

    private func makeDescriptor(
        coverPageID: ImportPageCandidate.ID,
        chapters: [FrozenImportChapter],
        workItems: [FrozenImportWorkItem]
    ) -> ManagedComicDescriptor {
        let plan = FrozenImportPlan(
            id: ImportJobID(
                rawValue: UUID(
                    uuidString: "00000000-0000-0000-0000-000000000702"
                )!
            ),
            revision: ImportPreviewRevision(rawValue: "reader-test-revision"),
            sourceRootName: "Reader Test Source",
            displayName: "Reader Test Comic",
            sourceBookmark: Data(),
            sortLocaleIdentifier: "en_US_POSIX",
            collections: [],
            chapters: chapters,
            workItems: workItems,
            coverPageID: coverPageID,
            scanIssues: [],
            spaceEstimate: .make(contentBytes: 1, fileCount: workItems.count)
        )
        let journal = ImportJobJournal(plan: plan, targetComicID: comicID())

        return ManagedComicDescriptor(plan: plan, journal: journal)
    }

    private func workItem(
        _ id: ImportPageCandidate.ID,
        isCover: Bool = false,
        pixelSize: ImportPixelSize? = nil,
        orientation: ImportImageOrientation? = nil
    ) -> FrozenImportWorkItem {
        FrozenImportWorkItem(
            id: id,
            sourceRelativePath: SourceRelativePath(
                components: ["Chapter 1", "\(id.rawValue).png"]
            ),
            managedRelativePath: ManagedRelativePath(
                components: ["original", "Chapter 1", "\(id.rawValue).png"]
            ),
            originalFileName: "\(id.rawValue).png",
            detectedFormat: .png,
            expectedByteCount: 1,
            expectedLightweightFingerprint: nil,
            pixelSize: pixelSize,
            orientation: orientation,
            pageState: .readable,
            isCover: isCover
        )
    }

    private func singlePage(
        from presentation: ReaderPresentation
    ) -> ReaderPresentedPage? {
        guard case let .page(page) = presentation.content else {
            return nil
        }

        return page
    }

    private func spread(from presentation: ReaderPresentation) -> ReaderSpread? {
        guard case let .spread(spread) = presentation.content else {
            return nil
        }

        return spread
    }

    private func boundary(
        from presentation: ReaderPresentation
    ) -> ReaderChapterBoundary? {
        guard case let .chapterBoundary(boundary) = presentation.content else {
            return nil
        }

        return boundary
    }

    private func isBoundary(_ presentation: ReaderPresentation) -> Bool {
        if case .chapterBoundary = presentation.content {
            return true
        }

        return false
    }
}
