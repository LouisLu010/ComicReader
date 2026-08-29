import Foundation
import XCTest
@testable import ComicReader

final class ChapterPageOrderTests: XCTestCase {
    private let chapterID = ImportChapterCandidate.ID(rawValue: "chapter-1")

    func testAcceptsAnyPermutationOfChapterPages() throws {
        let naturalIDs = ["p1", "p2", "p3"].map(ImportPageCandidate.ID.init)

        let order = try ChapterPageOrder(
            chapterID: chapterID,
            orderedPageIDs: naturalIDs.reversed(),
            naturalPageIDs: naturalIDs
        )

        XCTAssertEqual(order.orderedPageIDs, naturalIDs.reversed())
    }

    func testRejectsEmptyDuplicateAndForeignPages() {
        let naturalIDs = ["p1", "p2"].map(ImportPageCandidate.ID.init)

        XCTAssertThrowsError(
            try ChapterPageOrder(
                chapterID: chapterID,
                orderedPageIDs: [],
                naturalPageIDs: naturalIDs
            )
        ) { error in
            XCTAssertEqual(error as? ChapterPageOrderError, .emptyPages)
        }

        let duplicate = [
            ImportPageCandidate.ID(rawValue: "p1"),
            ImportPageCandidate.ID(rawValue: "p1"),
        ]
        XCTAssertThrowsError(
            try ChapterPageOrder(
                chapterID: chapterID,
                orderedPageIDs: duplicate,
                naturalPageIDs: naturalIDs
            )
        ) { error in
            XCTAssertEqual(
                error as? ChapterPageOrderError,
                .notAPermutation
            )
        }

        let foreign = [
            ImportPageCandidate.ID(rawValue: "p1"),
            ImportPageCandidate.ID(rawValue: "p9"),
        ]
        XCTAssertThrowsError(
            try ChapterPageOrder(
                chapterID: chapterID,
                orderedPageIDs: foreign,
                naturalPageIDs: naturalIDs
            )
        ) { error in
            XCTAssertEqual(
                error as? ChapterPageOrderError,
                .notAPermutation
            )
        }
    }

    func testReversedOrderReversesNaturalPageIDs() {
        let naturalIDs = ["p1", "p2", "p3"].map(ImportPageCandidate.ID.init)

        let order = ChapterPageOrder.reversed(
            chapterID,
            naturalPageIDs: naturalIDs
        )

        XCTAssertEqual(order.orderedPageIDs, naturalIDs.reversed())
    }

    func testRedundantOrderMatchesNaturalOrder() throws {
        let naturalIDs = ["p1", "p2"].map(ImportPageCandidate.ID.init)
        let natural = try ChapterPageOrder(
            chapterID: chapterID,
            orderedPageIDs: naturalIDs,
            naturalPageIDs: naturalIDs
        )
        let shuffled = try ChapterPageOrder(
            chapterID: chapterID,
            orderedPageIDs: naturalIDs.reversed(),
            naturalPageIDs: naturalIDs
        )

        XCTAssertTrue(natural.isRedundant(for: naturalIDs))
        XCTAssertFalse(shuffled.isRedundant(for: naturalIDs))
    }

    func testAppliedOrderKeepsKnownPagesAndAppendsNewcomers() throws {
        let originalNaturalIDs = ["p1", "p2", "p3"].map(
            ImportPageCandidate.ID.init
        )
        let order = try ChapterPageOrder(
            chapterID: chapterID,
            orderedPageIDs: ["p3", "p1", "p2"].map(
                ImportPageCandidate.ID.init
            ),
            naturalPageIDs: originalNaturalIDs
        )

        // 替换话之后第二页消失、新增第四页：保留可匹配的页序，
        // 消失页剔除，新页按自然顺序追加。
        let updatedNaturalIDs = ["p1", "p3", "p4"].map(
            ImportPageCandidate.ID.init
        )
        XCTAssertEqual(
            order.applied(to: updatedNaturalIDs),
            ["p3", "p1", "p4"].map(ImportPageCandidate.ID.init)
        )
    }
}
