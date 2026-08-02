import Foundation
import XCTest
@testable import ComicReader

final class ReaderProgressBridgeTests: XCTestCase {
    func testReadingPositionReturnsNilWhenLibraryProgressIsMissing() {
        XCTAssertNil(ReaderProgressBridge.readingPosition(from: nil))
    }

    func testReadingPositionRestoresIndependentCoverUsingStableSentinel() throws {
        let pageID = ImportPageCandidate.ID(rawValue: "root-cover")
        let position = try XCTUnwrap(
            ReaderProgressBridge.readingPosition(
                from: LibraryReadingProgress(
                    chapterID: ReaderPageLocation.coverStorageChapterID,
                    pageID: pageID.rawValue,
                    pageOffset: 0.25,
                    zoomScale: 1.5
                )
            )
        )

        XCTAssertEqual(
            position,
            ReadingPosition(
                location: .cover(pageID),
                pageOffset: 0.25,
                zoomScale: 1.5
            )
        )
    }

    func testReadingPositionMapsChapterPageWithoutCatalogValidation() throws {
        let chapterID = ImportChapterCandidate.ID(rawValue: "not-loaded-yet")
        let pageID = ImportPageCandidate.ID(rawValue: "page-99")
        let position = try XCTUnwrap(
            ReaderProgressBridge.readingPosition(
                from: LibraryReadingProgress(
                    chapterID: chapterID.rawValue,
                    pageID: pageID.rawValue,
                    pageOffset: 2,
                    zoomScale: 99
                )
            )
        )

        XCTAssertEqual(
            position,
            ReadingPosition(
                location: .chapter(chapterID, pageID),
                pageOffset: 1,
                zoomScale: 16
            )
        )
    }

    func testLibraryProgressPersistsCoverSentinelAndClampedPositionValues() {
        let pageID = ImportPageCandidate.ID(rawValue: "root-cover")
        let updatedAt = Date(timeIntervalSince1970: 100)
        let progress = ReaderProgressBridge.libraryProgress(
            from: readerProgress(
                position: ReadingPosition(
                    location: .cover(pageID),
                    pageOffset: -1,
                    zoomScale: .infinity
                )
            ),
            preservedComicCompletion: false,
            updatedAt: updatedAt
        )

        XCTAssertEqual(progress.chapterID, ReaderPageLocation.coverStorageChapterID)
        XCTAssertEqual(progress.pageID, pageID.rawValue)
        XCTAssertEqual(progress.pageOffset, 0)
        XCTAssertEqual(progress.zoomScale, 1)
        XCTAssertEqual(progress.readingMode, .continuous)
        XCTAssertEqual(progress.readingDirection, .leftToRight)
        XCTAssertFalse(progress.isCompleted)
        XCTAssertEqual(progress.updatedAt, updatedAt)
    }

    func testLibraryProgressPersistsReadingModeAndDirection() {
        let progress = ReaderProgressBridge.libraryProgress(
            from: readerProgress(
                position: ReadingPosition(
                    location: .chapter(
                        ImportChapterCandidate.ID(rawValue: "chapter-1"),
                        ImportPageCandidate.ID(rawValue: "page-1")
                    )
                ),
                mode: .spread,
                direction: .rightToLeft
            ),
            preservedComicCompletion: false,
            updatedAt: .distantPast
        )

        XCTAssertEqual(progress.readingMode, .spread)
        XCTAssertEqual(progress.readingDirection, .rightToLeft)
    }

    func testLibraryProgressKeepsComicCompletionSticky() {
        let position = ReadingPosition(
            location: .chapter(
                ImportChapterCandidate.ID(rawValue: "chapter-1"),
                ImportPageCandidate.ID(rawValue: "page-1")
            )
        )
        let preservedCompletion = ReaderProgressBridge.libraryProgress(
            from: readerProgress(position: position),
            preservedComicCompletion: true,
            updatedAt: .distantPast
        )
        let reachedFinalChapterEnd = ReaderProgressBridge.libraryProgress(
            from: readerProgress(
                position: position,
                hasReachedFinalChapterEnd: true
            ),
            preservedComicCompletion: false,
            updatedAt: .distantPast
        )
        let incomplete = ReaderProgressBridge.libraryProgress(
            from: readerProgress(position: position),
            preservedComicCompletion: false,
            updatedAt: .distantPast
        )

        XCTAssertTrue(preservedCompletion.isCompleted)
        XCTAssertTrue(reachedFinalChapterEnd.isCompleted)
        XCTAssertFalse(incomplete.isCompleted)
    }

    private func readerProgress(
        position: ReadingPosition,
        mode: ReadingMode = .continuous,
        direction: ReadingDirection = .leftToRight,
        hasReachedFinalChapterEnd: Bool = false
    ) -> ReaderProgress {
        ReaderProgress(
            comicID: ManagedComicID(),
            position: position,
            mode: mode,
            direction: direction,
            isChapterCompleted: false,
            hasReachedFinalChapterEnd: hasReachedFinalChapterEnd
        )
    }
}
