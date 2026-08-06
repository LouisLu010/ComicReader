import Foundation
import XCTest
@testable import ComicReader

final class ReaderThumbnailPresentationResolverTests: XCTestCase {
    func testRightToLeftPagedSpreadsUseRenderedPhysicalOrder() {
        let chapter = ReaderChapter(
            id: chapterID("chapter-1"),
            displayName: "Chapter 1",
            pages: [
                page("page-1"),
                page("page-2"),
                page("page-3"),
                page("page-4"),
            ]
        )
        let layout = makeLayout(
            chapters: [chapter],
            mode: .spread,
            direction: .rightToLeft
        )

        XCTAssertEqual(
            thumbnailPageIDs(for: layout),
            ["page-4", "page-3", "page-2", "page-1"]
        )
    }

    func testContinuousThumbnailsKeepLogicalOrderInRightToLeftMode() {
        let chapter = ReaderChapter(
            id: chapterID("chapter-1"),
            displayName: "Chapter 1",
            pages: [page("page-1"), page("page-2"), page("page-3")]
        )
        let layout = makeLayout(
            chapters: [chapter],
            mode: .continuous,
            direction: .rightToLeft
        )

        XCTAssertEqual(
            thumbnailPageIDs(for: layout),
            ["page-1", "page-2", "page-3"]
        )
    }

    func testDisplayIdentityChangesWhenPagedDirectionChanges() {
        let chapter = ReaderChapter(
            id: chapterID("chapter-1"),
            displayName: "Chapter 1",
            pages: [page("page-1"), page("page-2")]
        )
        let leftToRight = makeLayout(
            chapters: [chapter],
            mode: .singlePage,
            direction: .leftToRight
        )
        let rightToLeft = makeLayout(
            chapters: [chapter],
            mode: .singlePage,
            direction: .rightToLeft
        )

        XCTAssertNotEqual(
            ReaderThumbnailPresentationResolver.displayIdentity(
                for: leftToRight
            ),
            ReaderThumbnailPresentationResolver.displayIdentity(
                for: rightToLeft
            )
        )
    }

    private func thumbnailPageIDs(for layout: ReaderLayout) -> [String] {
        ReaderThumbnailPresentationResolver.presentations(for: layout)
            .flatMap {
                ReaderThumbnailPresentationResolver.pages(for: $0)
            }
            .map { $0.page.id.rawValue }
    }

    private func makeLayout(
        chapters: [ReaderChapter],
        mode: ReadingMode,
        direction: ReadingDirection
    ) -> ReaderLayout {
        ReaderLayout(
            comic: ReaderComic(
                id: ManagedComicID(
                    rawValue: UUID(
                        uuidString: "00000000-0000-0000-0000-000000000911"
                    )!
                ),
                displayName: "Thumbnail Comic",
                chapters: chapters
            ),
            requestedMode: mode,
            direction: direction,
            capability: .spreadCapable
        )
    }

    private func page(_ rawValue: String) -> ReaderPage {
        ReaderPage(
            id: ImportPageCandidate.ID(rawValue: rawValue),
            displayPixelSize: ImportPixelSize(width: 1_200, height: 1_800)
        )
    }

    private func chapterID(_ rawValue: String) -> ImportChapterCandidate.ID {
        ImportChapterCandidate.ID(rawValue: rawValue)
    }
}
