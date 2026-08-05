import Foundation
import XCTest
@testable import ComicReader

final class ReaderContinuousPositionResolverTests: XCTestCase {
    func testTallPageOffsetsMatchTopMiddleAndBottomAlignment() throws {
        let page = geometry(index: 0, minY: 0, height: 1_500)

        XCTAssertEqual(
            try resolve([page], viewportHeight: 500).pageOffset,
            0
        )
        XCTAssertEqual(
            try resolve(
                [geometry(index: 0, minY: -500, height: 1_500)],
                viewportHeight: 500
            ).pageOffset,
            0.5
        )
        XCTAssertEqual(
            try resolve(
                [geometry(index: 0, minY: -1_000, height: 1_500)],
                viewportHeight: 500
            ).pageOffset,
            1
        )
    }

    func testOnePointEndpointToleranceSnapsToExactCompletion() throws {
        let result = try resolve(
            [geometry(index: 0, minY: -999.5, height: 1_500)],
            viewportHeight: 500,
            pointTolerance: 1
        )

        XCTAssertEqual(result.pageOffset, 1)
    }

    func testShortPageNormalizesToCompletedOnlyWhenFullyVisible() throws {
        XCTAssertEqual(
            try resolve(
                [geometry(index: 0, minY: 50, height: 300)],
                viewportHeight: 500
            ).pageOffset,
            1
        )
        XCTAssertEqual(
            try resolve(
                [geometry(index: 0, minY: -50, height: 300)],
                viewportHeight: 500,
                pointTolerance: 0
            ).pageOffset,
            0
        )
    }

    func testSelectsPageWithMostVisibleContent() throws {
        let first = geometry(index: 0, minY: -490, height: 500)
        let second = geometry(index: 1, minY: 10, height: 500)

        let result = try resolve(
            [second, first],
            viewportHeight: 500,
            pointTolerance: 0
        )

        XCTAssertEqual(result.location, second.location)
    }

    func testVisiblePreferredLocationWinsDuringRestoration() throws {
        let first = geometry(index: 0, minY: -100, height: 500)
        let second = geometry(index: 1, minY: 400, height: 100)

        let result = try resolve(
            [first, second],
            viewportHeight: 500,
            preferredLocation: second.location,
            pointTolerance: 0
        )

        XCTAssertEqual(result.location, second.location)
    }

    func testFullyVisibleFinalPageWinsAtContentEnd() throws {
        let first = geometry(index: 0, minY: 0, height: 400)
        let final = geometry(index: 1, minY: 400, height: 100)

        let result = try XCTUnwrap(
            ReaderContinuousPositionResolver.resolve(
                geometries: [first, final],
                viewportHeight: 500,
                finalPresentationIndex: 1,
                pointTolerance: 0
            )
        )

        XCTAssertEqual(result.location, final.location)
        XCTAssertEqual(result.pageOffset, 1)
    }

    func testReportsShortIntermediateChapterEndWhenNextPageDominatesViewport() throws {
        let firstChapterID = ImportChapterCandidate.ID(rawValue: "chapter-1")
        let firstLocation = ReaderPageLocation.chapter(
            firstChapterID,
            ImportPageCandidate.ID(rawValue: "page-1")
        )
        let secondLocation = ReaderPageLocation.chapter(
            ImportChapterCandidate.ID(rawValue: "chapter-2"),
            ImportPageCandidate.ID(rawValue: "page-2")
        )
        let result = try XCTUnwrap(
            ReaderContinuousPositionResolver.resolve(
                geometries: [
                    ReaderContinuousPageGeometry(
                        index: 0,
                        presentationID: .page(firstLocation),
                        location: firstLocation,
                        completionChapterID: firstChapterID,
                        minY: 0,
                        height: 120
                    ),
                    ReaderContinuousPageGeometry(
                        index: 1,
                        presentationID: .page(secondLocation),
                        location: secondLocation,
                        minY: 120,
                        height: 1_000
                    ),
                ],
                viewportHeight: 500,
                pointTolerance: 0
            )
        )

        XCTAssertEqual(result.location, secondLocation)
        XCTAssertEqual(result.completedChapterIDs, [firstChapterID])
    }

    func testDoesNotReportChapterEndBeforeItsBottomEntersViewport() throws {
        let chapterID = ImportChapterCandidate.ID(rawValue: "chapter-1")
        let location = ReaderPageLocation.chapter(
            chapterID,
            ImportPageCandidate.ID(rawValue: "page-1")
        )
        let result = try resolve(
            [
                ReaderContinuousPageGeometry(
                    index: 0,
                    presentationID: .page(location),
                    location: location,
                    completionChapterID: chapterID,
                    minY: 450,
                    height: 100
                ),
            ],
            viewportHeight: 500,
            pointTolerance: 0
        )

        XCTAssertTrue(result.completedChapterIDs.isEmpty)
    }

    func testRejectsInvalidViewportAndGeometry() {
        let valid = geometry(index: 0, minY: 0, height: 500)
        let invalid = ReaderContinuousPageGeometry(
            index: 1,
            presentationID: valid.presentationID,
            location: valid.location,
            minY: Double.nan,
            height: Double.infinity
        )

        XCTAssertNil(ReaderContinuousPositionResolver.resolve(
            geometries: [valid],
            viewportHeight: Double.nan
        ))
        XCTAssertNil(ReaderContinuousPositionResolver.resolve(
            geometries: [invalid],
            viewportHeight: 500
        ))
    }

    func testRestoreAnchorClampsAndInvertsTallPageFormula() {
        XCTAssertEqual(
            ReaderContinuousPositionResolver.restoreAnchorY(
                for: Double.nan
            ),
            0
        )
        XCTAssertEqual(
            ReaderContinuousPositionResolver.restoreAnchorY(for: -1),
            0
        )
        XCTAssertEqual(
            ReaderContinuousPositionResolver.restoreAnchorY(for: 2),
            1
        )

        let pageOffset = 0.625
        let pageHeight = 1_300.0
        let viewportHeight = 500.0
        let restoredMinY = -pageOffset * (pageHeight - viewportHeight)
        let result = ReaderContinuousPositionResolver.resolve(
            geometries: [geometry(
                index: 0,
                minY: restoredMinY,
                height: pageHeight
            )],
            viewportHeight: viewportHeight,
            pointTolerance: 0
        )

        XCTAssertEqual(result?.pageOffset, pageOffset)
    }

    func testShortPageRestoreOffsetIsCanonical() {
        XCTAssertEqual(
            ReaderContinuousPositionResolver.normalizedRestoreOffset(
                0.25,
                pageHeight: 400,
                viewportHeight: 500
            ),
            1
        )
        XCTAssertEqual(
            ReaderContinuousPositionResolver.normalizedRestoreOffset(
                0.25,
                pageHeight: 900,
                viewportHeight: 500
            ),
            0.25
        )
    }

    func testFullyVisibleFinalPageCompletesContinuousSession() throws {
        let chapterID = ImportChapterCandidate.ID(rawValue: "chapter")
        let pageID = ImportPageCandidate.ID(rawValue: "page")
        let location = ReaderPageLocation.chapter(chapterID, pageID)
        let viewportPosition = try XCTUnwrap(
            ReaderContinuousPositionResolver.resolve(
                geometries: [
                    ReaderContinuousPageGeometry(
                        index: 0,
                        presentationID: .page(location),
                        location: location,
                        minY: 100,
                        height: 300
                    ),
                ],
                viewportHeight: 500,
                finalPresentationIndex: 0
            )
        )
        var session = try ReaderSession(
            comic: ReaderComic(
                id: ManagedComicID(rawValue: UUID()),
                displayName: "Comic",
                chapters: [
                    ReaderChapter(
                        id: chapterID,
                        displayName: "Chapter",
                        pages: [ReaderPage(id: pageID)]
                    ),
                ]
            )
        )

        XCTAssertTrue(session.move(
            to: viewportPosition.location,
            pageOffset: viewportPosition.pageOffset
        ))
        XCTAssertTrue(session.progress.isChapterCompleted)
        XCTAssertTrue(session.progress.hasReachedFinalChapterEnd)
    }

    private func resolve(
        _ geometries: [ReaderContinuousPageGeometry],
        viewportHeight: Double,
        preferredLocation: ReaderPageLocation? = nil,
        pointTolerance: Double = 1
    ) throws -> ReaderContinuousViewportPosition {
        try XCTUnwrap(ReaderContinuousPositionResolver.resolve(
            geometries: geometries,
            viewportHeight: viewportHeight,
            preferredLocation: preferredLocation,
            pointTolerance: pointTolerance
        ))
    }

    private func geometry(
        index: Int,
        minY: Double,
        height: Double
    ) -> ReaderContinuousPageGeometry {
        let chapterID = ImportChapterCandidate.ID(
            rawValue: "chapter-\(index)"
        )
        let pageID = ImportPageCandidate.ID(rawValue: "page-\(index)")
        let location = ReaderPageLocation.chapter(chapterID, pageID)

        return ReaderContinuousPageGeometry(
            index: index,
            presentationID: .page(location),
            location: location,
            minY: minY,
            height: height
        )
    }
}
