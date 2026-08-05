import Foundation
import XCTest
@testable import ComicReader

final class ReaderNavigationIndexTests: XCTestCase {
    func testBuildsBidirectionalPagesAndChapterDestinationsWithCover() throws {
        let cover = page("cover", isCover: true)
        let chapterOne = chapter("chapter-1", pages: [
            page("page-1"),
            page("page-2"),
        ])
        let chapterTwo = chapter("chapter-2", pages: [page("page-3")])
        let comic = makeComic(
            cover: cover,
            chapters: [chapterOne, chapterTwo]
        )
        let layout = makeLayout(
            comic: comic,
            mode: .singlePage,
            direction: .leftToRight
        )
        let index = try XCTUnwrap(
            ReaderNavigationIndex(comic: comic, layout: layout)
        )
        let coverLocation = ReaderPageLocation.cover(cover.id)
        let firstLocation = location(chapterOne, pageIndex: 0)
        let secondLocation = location(chapterOne, pageIndex: 1)
        let thirdLocation = location(chapterTwo, pageIndex: 0)

        XCTAssertEqual(index.pageCount, 4)
        XCTAssertEqual(
            index.pageNumberByLocation,
            [
                coverLocation: 1,
                firstLocation: 2,
                secondLocation: 3,
                thirdLocation: 4,
            ]
        )
        XCTAssertEqual(
            index.locationByPageNumber,
            [
                1: coverLocation,
                2: firstLocation,
                3: secondLocation,
                4: thirdLocation,
            ]
        )
        XCTAssertEqual(index.pageNumber(for: secondLocation), 3)
        XCTAssertEqual(index.location(forPageNumber: 4), thirdLocation)
        XCTAssertEqual(
            index.chapterDestinations,
            [
                ReaderChapterDestination(
                    chapterID: chapterOne.id,
                    displayName: chapterOne.displayName,
                    firstLocation: firstLocation
                ),
                ReaderChapterDestination(
                    chapterID: chapterTwo.id,
                    displayName: chapterTwo.displayName,
                    firstLocation: thirdLocation
                ),
            ]
        )
        XCTAssertEqual(
            index.chapterDestination(for: chapterTwo.id)?.firstLocation,
            thirdLocation
        )

        let boundaryCount = layout.presentations.reduce(into: 0) {
            if case .chapterBoundary = $1.content {
                $0 += 1
            }
        }
        XCTAssertEqual(boundaryCount, 2)
        XCTAssertEqual(
            index.pageNumberByLocation.count,
            layout.pageCount,
            "章节结束页不应占用逻辑页码"
        )
    }

    func testLogicalPageNavigationSkipsBoundariesAndCrossesChapters() throws {
        let cover = page("cover", isCover: true)
        let chapterOne = chapter("chapter-1", pages: [
            page("page-1"),
            page("page-2"),
        ])
        let chapterTwo = chapter("chapter-2", pages: [page("page-3")])
        let comic = makeComic(
            cover: cover,
            chapters: [chapterOne, chapterTwo]
        )
        let index = try XCTUnwrap(
            ReaderNavigationIndex(
                comic: comic,
                layout: makeLayout(
                    comic: comic,
                    mode: .singlePage,
                    direction: .leftToRight
                )
            )
        )
        let coverLocation = ReaderPageLocation.cover(cover.id)
        let firstLocation = location(chapterOne, pageIndex: 0)
        let secondLocation = location(chapterOne, pageIndex: 1)
        let thirdLocation = location(chapterTwo, pageIndex: 0)

        XCTAssertNil(index.previousLocation(from: coverLocation))
        XCTAssertEqual(index.nextLocation(from: coverLocation), firstLocation)
        XCTAssertEqual(
            index.location(from: firstLocation, moving: .backward),
            coverLocation
        )
        XCTAssertEqual(
            index.location(from: secondLocation, moving: .forward),
            thirdLocation
        )
        XCTAssertEqual(index.previousLocation(from: thirdLocation), secondLocation)
        XCTAssertNil(index.nextLocation(from: thirdLocation))
    }

    func testRightToLeftKeepsLogicalPageOrderAndMirrorsArrowPolicy() throws {
        let chapter = chapter("chapter-1", pages: [
            page("page-1"),
            page("page-2"),
        ])
        let comic = makeComic(chapters: [chapter])
        let leftToRightLayout = makeLayout(
            comic: comic,
            mode: .singlePage,
            direction: .leftToRight
        )
        let rightToLeftLayout = makeLayout(
            comic: comic,
            mode: .singlePage,
            direction: .rightToLeft
        )
        let leftToRightIndex = try XCTUnwrap(
            ReaderNavigationIndex(comic: comic, layout: leftToRightLayout)
        )
        let rightToLeftIndex = try XCTUnwrap(
            ReaderNavigationIndex(comic: comic, layout: rightToLeftLayout)
        )

        XCTAssertEqual(
            rightToLeftIndex.pageNumberByLocation,
            leftToRightIndex.pageNumberByLocation
        )
        XCTAssertNotEqual(
            rightToLeftLayout.pagedDisplayPresentations.map(\.id),
            leftToRightLayout.pagedDisplayPresentations.map(\.id)
        )
        XCTAssertEqual(
            ReaderKeyboardNavigationPolicy.logicalStep(
                for: .left,
                readingDirection: .leftToRight
            ),
            .backward
        )
        XCTAssertEqual(
            ReaderKeyboardNavigationPolicy.logicalStep(
                for: .right,
                readingDirection: .leftToRight
            ),
            .forward
        )
        XCTAssertEqual(
            ReaderKeyboardNavigationPolicy.logicalStep(
                for: .left,
                readingDirection: .rightToLeft
            ),
            .forward
        )
        XCTAssertEqual(
            ReaderKeyboardNavigationPolicy.logicalStep(
                for: .right,
                readingDirection: .rightToLeft
            ),
            .backward
        )
    }

    func testOddRightToLeftSpreadIndexesEachPageIndependently() throws {
        let chapter = chapter("chapter-1", pages: [
            page("page-1"),
            page("page-2"),
            page("page-3"),
        ])
        let comic = makeComic(chapters: [chapter])
        let layout = makeLayout(
            comic: comic,
            mode: .spread,
            direction: .rightToLeft
        )
        let index = try XCTUnwrap(
            ReaderNavigationIndex(comic: comic, layout: layout)
        )
        let firstLocation = location(chapter, pageIndex: 0)
        let secondLocation = location(chapter, pageIndex: 1)
        let thirdLocation = location(chapter, pageIndex: 2)

        XCTAssertEqual(layout.presentations.count, 3)
        XCTAssertEqual(index.pageCount, 3)
        XCTAssertEqual(index.pageNumber(for: firstLocation), 1)
        XCTAssertEqual(index.pageNumber(for: secondLocation), 2)
        XCTAssertEqual(index.pageNumber(for: thirdLocation), 3)
        XCTAssertEqual(index.location(forPageNumber: 2), secondLocation)
        XCTAssertEqual(index.nextLocation(from: secondLocation), thirdLocation)
    }

    func testChapterNavigationHandlesCoverEndsAndUnknownLocations() throws {
        let cover = page("cover", isCover: true)
        let chapterOne = chapter("chapter-1", pages: [page("page-1")])
        let chapterTwo = chapter("chapter-2", pages: [page("page-2")])
        let comic = makeComic(
            cover: cover,
            chapters: [chapterOne, chapterTwo]
        )
        let index = try XCTUnwrap(
            ReaderNavigationIndex(
                comic: comic,
                layout: makeLayout(
                    comic: comic,
                    mode: .continuous,
                    direction: .leftToRight
                )
            )
        )
        let coverLocation = ReaderPageLocation.cover(cover.id)
        let firstLocation = location(chapterOne, pageIndex: 0)
        let secondLocation = location(chapterTwo, pageIndex: 0)
        let unknownLocation = ReaderPageLocation.chapter(
            chapterOne.id,
            pageID("unknown")
        )

        XCTAssertNil(index.previousChapterLocation(from: coverLocation))
        XCTAssertEqual(
            index.nextChapterLocation(from: coverLocation),
            firstLocation
        )
        XCTAssertNil(index.previousChapterLocation(from: firstLocation))
        XCTAssertEqual(
            index.nextChapterLocation(from: firstLocation),
            secondLocation
        )
        XCTAssertEqual(
            index.previousChapterLocation(from: secondLocation),
            firstLocation
        )
        XCTAssertNil(index.nextChapterLocation(from: secondLocation))
        XCTAssertNil(index.previousChapterLocation(from: unknownLocation))
        XCTAssertNil(index.nextChapterLocation(from: unknownLocation))
        XCTAssertNil(index.chapterDestination(for: chapterID("unknown")))
    }

    func testCoverOnlyComicHasNoChapterDestination() throws {
        let cover = page("cover", isCover: true)
        let comic = makeComic(cover: cover, chapters: [])
        let coverLocation = ReaderPageLocation.cover(cover.id)
        let index = try XCTUnwrap(
            ReaderNavigationIndex(
                comic: comic,
                layout: makeLayout(
                    comic: comic,
                    mode: .spread,
                    direction: .rightToLeft
                )
            )
        )

        XCTAssertEqual(index.pageCount, 1)
        XCTAssertTrue(index.chapterDestinations.isEmpty)
        XCTAssertNil(index.previousChapterLocation(from: coverLocation))
        XCTAssertNil(index.nextChapterLocation(from: coverLocation))
    }

    func testRejectsInvalidPageNumbersAndDuplicateLogicalLocations() throws {
        let chapter = chapter("chapter-1", pages: [page("page-1")])
        let comic = makeComic(chapters: [chapter])
        let index = try XCTUnwrap(
            ReaderNavigationIndex(
                comic: comic,
                layout: makeLayout(
                    comic: comic,
                    mode: .singlePage,
                    direction: .leftToRight
                )
            )
        )
        let unknownLocation = ReaderPageLocation.chapter(
            chapter.id,
            pageID("unknown")
        )

        for invalidPageNumber in [Int.min, -1, 0, 2, Int.max] {
            XCTAssertNil(index.location(forPageNumber: invalidPageNumber))
        }
        XCTAssertNil(index.pageNumber(for: unknownLocation))
        XCTAssertNil(index.previousLocation(from: unknownLocation))
        XCTAssertNil(index.nextLocation(from: unknownLocation))

        let duplicatePage = page("duplicate")
        let duplicateComic = makeComic(chapters: [
            ReaderChapter(
                id: chapterID("duplicate-chapter"),
                displayName: "Duplicate Chapter",
                pages: [duplicatePage, duplicatePage]
            ),
        ])
        let duplicateLayout = makeLayout(
            comic: duplicateComic,
            mode: .singlePage,
            direction: .leftToRight
        )

        XCTAssertNil(
            ReaderNavigationIndex(
                comic: duplicateComic,
                layout: duplicateLayout
            )
        )
    }

    private func makeComic(
        cover: ReaderPage? = nil,
        chapters: [ReaderChapter]
    ) -> ReaderComic {
        ReaderComic(
            id: ManagedComicID(
                rawValue: UUID(
                    uuidString: "00000000-0000-0000-0000-000000000711"
                )!
            ),
            displayName: "Navigation Comic",
            cover: cover,
            chapters: chapters
        )
    }

    private func makeLayout(
        comic: ReaderComic,
        mode: ReadingMode,
        direction: ReadingDirection
    ) -> ReaderLayout {
        ReaderLayout(
            comic: comic,
            requestedMode: mode,
            direction: direction,
            capability: .spreadCapable
        )
    }

    private func chapter(
        _ rawValue: String,
        pages: [ReaderPage]
    ) -> ReaderChapter {
        ReaderChapter(
            id: chapterID(rawValue),
            displayName: "Chapter \(rawValue)",
            pages: pages
        )
    }

    private func page(
        _ rawValue: String,
        isCover: Bool = false
    ) -> ReaderPage {
        ReaderPage(
            id: pageID(rawValue),
            displayPixelSize: ImportPixelSize(width: 1_200, height: 1_800),
            isCover: isCover
        )
    }

    private func location(
        _ chapter: ReaderChapter,
        pageIndex: Int
    ) -> ReaderPageLocation {
        .chapter(chapter.id, chapter.pages[pageIndex].id)
    }

    private func chapterID(
        _ rawValue: String
    ) -> ImportChapterCandidate.ID {
        ImportChapterCandidate.ID(rawValue: rawValue)
    }

    private func pageID(_ rawValue: String) -> ImportPageCandidate.ID {
        ImportPageCandidate.ID(rawValue: rawValue)
    }
}
