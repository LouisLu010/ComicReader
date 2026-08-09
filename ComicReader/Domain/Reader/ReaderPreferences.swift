import Foundation

enum ReaderTapZoneAction: String, CaseIterable, Codable, Equatable, Sendable {
    /// 根据当前阅读方向保留默认的物理左右翻页行为。
    case automatic
    case previousPage
    case nextPage
    case toggleControls
    case disabled
}

struct ReaderTapAreaPreferences: Equatable, Sendable {
    static let `default` = Self(
        leftAction: .automatic,
        rightAction: .automatic
    )

    var leftAction: ReaderTapZoneAction
    var rightAction: ReaderTapZoneAction
}

struct ReaderGlobalPreferences: Equatable, Sendable {
    static let `default` = Self(
        defaultReadingMode: .continuous,
        defaultReadingDirection: .leftToRight,
        tapAreas: .default
    )

    var defaultReadingMode: ReadingMode
    var defaultReadingDirection: ReadingDirection
    var tapAreas: ReaderTapAreaPreferences
}

struct ComicReaderOverrides: Equatable, Sendable {
    static let none = Self(
        readingMode: nil,
        readingDirection: nil
    )

    var readingMode: ReadingMode?
    var readingDirection: ReadingDirection?

    func resolved(
        using global: ReaderGlobalPreferences
    ) -> ResolvedReaderPreferences {
        ResolvedReaderPreferences(
            readingMode: readingMode ?? global.defaultReadingMode,
            readingDirection: readingDirection ?? global.defaultReadingDirection,
            tapAreas: global.tapAreas
        )
    }
}

struct ResolvedReaderPreferences: Equatable, Sendable {
    static let `default` = Self(
        readingMode: ReaderGlobalPreferences.default.defaultReadingMode,
        readingDirection: ReaderGlobalPreferences.default.defaultReadingDirection,
        tapAreas: ReaderGlobalPreferences.default.tapAreas
    )

    let readingMode: ReadingMode
    let readingDirection: ReadingDirection
    let tapAreas: ReaderTapAreaPreferences
}
