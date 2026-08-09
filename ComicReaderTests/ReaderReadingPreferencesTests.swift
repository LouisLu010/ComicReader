import XCTest
@testable import ComicReader

final class ReaderReadingPreferencesTests: XCTestCase {
    func testComicOverridesTakePriorityOverGlobalDefaults() {
        let global = ReaderGlobalPreferences(
            defaultReadingMode: .continuous,
            defaultReadingDirection: .leftToRight,
            tapAreas: ReaderTapAreaPreferences(
                leftAction: .automatic,
                rightAction: .disabled
            )
        )
        let overrides = ComicReaderOverrides(
            readingMode: .spread,
            readingDirection: .rightToLeft
        )

        XCTAssertEqual(
            overrides.resolved(using: global),
            ResolvedReaderPreferences(
                readingMode: .spread,
                readingDirection: .rightToLeft,
                tapAreas: global.tapAreas
            )
        )
    }

    func testMissingComicOverridesFollowGlobalDefaults() {
        let global = ReaderGlobalPreferences(
            defaultReadingMode: .singlePage,
            defaultReadingDirection: .rightToLeft,
            tapAreas: ReaderTapAreaPreferences(
                leftAction: .nextPage,
                rightAction: .previousPage
            )
        )

        XCTAssertEqual(
            ComicReaderOverrides.none.resolved(using: global),
            ResolvedReaderPreferences(
                readingMode: .singlePage,
                readingDirection: .rightToLeft,
                tapAreas: global.tapAreas
            )
        )
    }
}
