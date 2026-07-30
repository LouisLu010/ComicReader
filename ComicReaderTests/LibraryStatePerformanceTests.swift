import Foundation
import XCTest
@testable import ComicReader

final class LibraryStatePerformanceTests: XCTestCase {
    @MainActor
    func testIndexesAndQueries1000ComicsWithinBudget() async throws {
        let container = try ComicReaderModelContainer.makeContainer(
            isStoredInMemoryOnly: true
        )
        let repository = LibraryStateRepository()
        await repository.configure(modelContainer: container)
        let catalogItems = (0..<1_000).map(makeCatalogItem)
        let clock = ContinuousClock()
        let startedAt = clock.now

        await repository.reconcile(catalogItems: catalogItems)
        let unreadCount = repository.unreadComics(in: catalogItems).count
        let favoriteCount = repository.favoriteComics(in: catalogItems).count
        let continueReadingCount = repository.continueReadingComics(
            in: catalogItems
        ).count

        let elapsed = startedAt.duration(to: clock.now)
        XCTAssertEqual(repository.status, .ready)
        XCTAssertEqual(repository.statesByComicID.count, 1_000)
        XCTAssertEqual(unreadCount, 1_000)
        XCTAssertEqual(favoriteCount, 0)
        XCTAssertEqual(continueReadingCount, 0)
        XCTAssertLessThan(
            elapsed,
            .seconds(10),
            "Indexing 1,000 comics exceeded the initial CI budget: \(elapsed)"
        )
    }

    private func makeCatalogItem(_ index: Int) -> LibraryCatalogItem {
        let rawIdentifier = String(
            format: "00000000-0000-0000-0000-%012d",
            index + 1
        )
        let comicID = ManagedComicID(
            rawValue: UUID(uuidString: rawIdentifier)!
        )
        return LibraryCatalogItem(
            record: LibraryCatalogRecord(
                id: comicID,
                displayName: "Comic \(index + 1)",
                sourceRootName: "source-\(index + 1)",
                importedAt: Date(timeIntervalSince1970: TimeInterval(index)),
                chapterCount: 1,
                pageCount: 12,
                contentTree: []
            ),
            thumbnailAvailable: false
        )
    }
}
