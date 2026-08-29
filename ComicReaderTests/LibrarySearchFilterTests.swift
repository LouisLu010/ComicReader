import Foundation
import XCTest
@testable import ComicReader

final class LibrarySearchFilterTests: XCTestCase {
    private let comicID = ManagedComicID(
        rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000601")!
    )

    private func makeComic(
        _ name: String,
        importedAt: Date = Date(timeIntervalSince1970: 100),
        isFavorite: Bool = false,
        lastReadAt: Date? = nil,
        readState: LibraryComicReadState = .unread
    ) -> LibrarySortableComic {
        LibrarySortableComic(
            id: comicID,
            displayName: name,
            importedAt: importedAt,
            isFavorite: isFavorite,
            lastReadAt: lastReadAt,
            readState: readState
        )
    }

    func testDefaultFilterKeepsEverythingInRecentImportOrder() {
        let comics = [
            makeComic("B", importedAt: Date(timeIntervalSince1970: 1)),
            makeComic("A", importedAt: Date(timeIntervalSince1970: 2)),
            makeComic("C", importedAt: Date(timeIntervalSince1970: 3)),
        ]

        let result = LibraryCatalogSearchEngine.filter(
            comics,
            using: .default
        )

        XCTAssertEqual(result.map(\.displayName), ["C", "A", "B"])
        XCTAssertFalse(LibrarySearchFilter.default.hasActiveCriteria)
    }

    func testSearchMatchesCaseAndDiacriticInsensitively() {
        let comics = [
            makeComic("Café 東京"),
            makeComic("cafe girl"),
            makeComic("拜訪 CAFFÉ"),
            makeComic(" unrelated "),
        ]

        let result = LibraryCatalogSearchEngine.filter(
            comics,
            using: LibrarySearchFilter(searchText: "  cafe  ")
        )

        // "cafe" 匹配 Café / cafe / CAFFÉ（去变音、忽略大小写），
        // 不匹配完全无关的名字。
        XCTAssertEqual(result.count, 3)
        XCTAssertTrue(LibrarySearchFilter(searchText: " cafe ").hasActiveCriteria)
    }

    func testWhitespaceOnlySearchMatchesAll() {
        let comics = [makeComic("A"), makeComic("B")]
        let filter = LibrarySearchFilter(searchText: "   \n\t ")

        XCTAssertEqual(
            LibraryCatalogSearchEngine.filter(comics, using: filter).count,
            2
        )
        XCTAssertFalse(filter.hasActiveCriteria)
    }

    func testFavoritesOnlyFilter() {
        let comics = [
            makeComic("Favorite", isFavorite: true),
            makeComic("Plain"),
        ]

        let result = LibraryCatalogSearchEngine.filter(
            comics,
            using: LibrarySearchFilter(favoritesOnly: true)
        )

        XCTAssertEqual(result.map(\.displayName), ["Favorite"])
    }

    func testReadStateFilters() {
        let comics = [
            makeComic("Unread", readState: .unread),
            makeComic(
                "InProgress",
                lastReadAt: Date(timeIntervalSince1970: 1),
                readState: .inProgress
            ),
            makeComic(
                "Completed",
                lastReadAt: Date(timeIntervalSince1970: 2),
                readState: .completed
            ),
        ]

        func names(_ readState: LibraryReadStateFilter) -> [String] {
            LibraryCatalogSearchEngine.filter(
                comics,
                using: LibrarySearchFilter(readState: readState)
            ).map(\.displayName)
        }

        XCTAssertEqual(names(.unread), ["Unread"])
        XCTAssertEqual(names(.inProgress), ["InProgress"])
        XCTAssertEqual(names(.completed), ["Completed"])
        XCTAssertEqual(names(.all).count, 3)
    }

    func testReadStateDerivation() {
        XCTAssertEqual(
            LibraryComicReadState.make(
                hasReadingProgress: false,
                isCompleted: false
            ),
            .unread
        )
        XCTAssertEqual(
            LibraryComicReadState.make(
                hasReadingProgress: true,
                isCompleted: false
            ),
            .inProgress
        )
        XCTAssertEqual(
            LibraryComicReadState.make(
                hasReadingProgress: false,
                isCompleted: true
            ),
            .completed
        )
    }

    func testTitleSortUsesUserPerceivedNumericOrder() {
        let comics = [
            makeComic("第12话"),
            makeComic("第2话"),
            makeComic("Alpha"),
        ]

        let result = LibraryCatalogSearchEngine.filter(
            comics,
            using: LibrarySearchFilter(sort: .title)
        )

        XCTAssertEqual(
            result.map(\.displayName),
            ["Alpha", "第2话", "第12话"]
        )
    }

    func testRecentlyImportedSortBreaksTiesByDisplayName() {
        let comics = [
            makeComic("Beta", importedAt: Date(timeIntervalSince1970: 10)),
            makeComic("delta", importedAt: Date(timeIntervalSince1970: 10)),
            makeComic("Alpha", importedAt: Date(timeIntervalSince1970: 20)),
        ]

        let result = LibraryCatalogSearchEngine.filter(
            comics,
            using: LibrarySearchFilter(sort: .recentlyImported)
        )

        XCTAssertEqual(
            result.map(\.displayName),
            ["Alpha", "Beta", "delta"]
        )
    }

    func testRecentlyReadSortPutsNeverReadLast() {
        let early = Date(timeIntervalSince1970: 1)
        let late = Date(timeIntervalSince1970: 2)
        let comics = [
            makeComic("NeverRead"),
            makeComic("OldRead", lastReadAt: early, readState: .inProgress),
            makeComic("NeverRead2"),
            makeComic(
                "NewRead",
                lastReadAt: late,
                readState: .inProgress
            ),
        ]

        let result = LibraryCatalogSearchEngine.filter(
            comics,
            using: LibrarySearchFilter(sort: .recentlyRead)
        )

        XCTAssertEqual(
            result.map(\.displayName),
            ["NewRead", "OldRead", "NeverRead", "NeverRead2"]
        )
    }

    func testRecentlyReadSortBreaksTiesByDisplayName() {
        let sameTime = Date(timeIntervalSince1970: 5)
        let comics = [
            makeComic("Zulu", lastReadAt: sameTime),
            makeComic("alpha", lastReadAt: sameTime),
        ]

        let result = LibraryCatalogSearchEngine.filter(
            comics,
            using: LibrarySearchFilter(sort: .recentlyRead)
        )

        XCTAssertEqual(result.map(\.displayName), ["alpha", "Zulu"])
    }

    func testCombinedCriteriaApplyTogether() {
        let comics = [
            makeComic(
                "Favorite Progress",
                isFavorite: true,
                lastReadAt: Date(timeIntervalSince1970: 1),
                readState: .inProgress
            ),
            makeComic("Favorite Unread", isFavorite: true),
            makeComic(
                "Plain Progress",
                lastReadAt: Date(timeIntervalSince1970: 2),
                readState: .inProgress
            ),
        ]

        let result = LibraryCatalogSearchEngine.filter(
            comics,
            using: LibrarySearchFilter(
                searchText: "progress",
                favoritesOnly: true,
                readState: .inProgress
            )
        )

        XCTAssertEqual(result.map(\.displayName), ["Favorite Progress"])
    }

    func testFilterCodableRoundTrip() throws {
        let filter = LibrarySearchFilter(
            searchText: "海賊王",
            favoritesOnly: true,
            readState: .completed,
            sort: .title
        )

        let data = try JSONEncoder().encode(filter)
        let decoded = try JSONDecoder().decode(
            LibrarySearchFilter.self,
            from: data
        )

        XCTAssertEqual(decoded, filter)
    }

    func testIdenticalDisplayNamesBreakTiesByStableID() {
        let secondID = ManagedComicID(
            rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000602")!
        )
        let first = makeComic("Same Name")
        let second = LibrarySortableComic(
            id: secondID,
            displayName: "Same Name",
            importedAt: .distantPast,
            readState: .unread
        )

        let result = LibraryCatalogSearchEngine.filter(
            [second, first],
            using: LibrarySearchFilter(sort: .title)
        )

        XCTAssertEqual(
            result.map(\.id.rawValue.uuidString),
            [
                comicID.rawValue.uuidString,
                secondID.rawValue.uuidString,
            ]
        )
    }
}
