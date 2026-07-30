import Foundation
import XCTest
@testable import ComicReader

final class NaturalFileOrderTests: XCTestCase {
    private let locale = Locale(identifier: "en_US_POSIX")

    func testSortsNumericNamesNaturally() {
        XCTAssertEqual(
            sorted(["page10", "page2", "page1"]),
            ["page1", "page2", "page10"]
        )
        XCTAssertEqual(
            sorted(["第10话", "第2话", "第1话"]),
            ["第1话", "第2话", "第10话"]
        )
    }

    func testUsesLiteralNameAsDeterministicLeadingZeroTieBreaker() {
        XCTAssertEqual(
            sorted(["page10", "page2", "page02"]),
            ["page02", "page2", "page10"]
        )
    }

    func testIgnoresCaseDiacriticsAndWidthForPrimaryComparison() {
        XCTAssertEqual(
            sorted(["ＥＣＬＡＩＲ10", "éclair2", "eclair1"]),
            ["eclair1", "éclair2", "ＥＣＬＡＩＲ10"]
        )
    }

    func testUsesCreationDateBeforeLiteralNameWhenPrimaryNamesMatch() {
        let older = NamedSourceItem(
            name: "Page",
            creationDate: Date(timeIntervalSince1970: 1)
        )
        let newer = NamedSourceItem(
            name: "page",
            creationDate: Date(timeIntervalSince1970: 2)
        )

        XCTAssertTrue(
            NaturalFileOrder.areInIncreasingOrder(
                older,
                newer,
                locale: locale
            )
        )
        XCTAssertFalse(
            NaturalFileOrder.areEquivalent(
                older,
                newer,
                locale: locale
            )
        )
    }

    func testRecognizesExactlyEqualItems() {
        let item = NamedSourceItem(name: "same", creationDate: nil)

        XCTAssertTrue(
            NaturalFileOrder.areEquivalent(item, item, locale: locale)
        )
        XCTAssertFalse(
            NaturalFileOrder.areInIncreasingOrder(item, item, locale: locale)
        )
    }

    func testSortsMissingCreationDatesAfterKnownDatesWithoutCycles() {
        let items = [
            NamedSourceItem(name: "Ａ", creationDate: nil),
            NamedSourceItem(
                name: "a",
                creationDate: Date(timeIntervalSince1970: 2)
            ),
            NamedSourceItem(
                name: "A",
                creationDate: Date(timeIntervalSince1970: 1)
            ),
        ]

        let sortedItems = items.sorted {
            NaturalFileOrder.areInIncreasingOrder(
                $0,
                $1,
                locale: locale
            )
        }

        XCTAssertEqual(
            sortedItems.map(\.creationDate),
            [
                Date(timeIntervalSince1970: 1),
                Date(timeIntervalSince1970: 2),
                nil,
            ]
        )
        XCTAssertFalse(
            NaturalFileOrder.areInIncreasingOrder(
                sortedItems.last!,
                sortedItems.first!,
                locale: locale
            )
        )
    }

    private func sorted(_ names: [String]) -> [String] {
        names
            .map { NamedSourceItem(name: $0, creationDate: nil) }
            .sorted {
                NaturalFileOrder.areInIncreasingOrder(
                    $0,
                    $1,
                    locale: locale
                )
            }
            .map(\.name)
    }
}
