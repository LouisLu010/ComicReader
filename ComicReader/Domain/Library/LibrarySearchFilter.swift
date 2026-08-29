import Foundation

/// 书库条目的阅读状态；由进度记录推导，供筛选使用。
enum LibraryComicReadState: Equatable, Hashable, Sendable {
    case unread
    case inProgress
    case completed

    static func make(
        hasReadingProgress: Bool,
        isCompleted: Bool
    ) -> Self {
        if isCompleted {
            return .completed
        }
        return hasReadingProgress ? .inProgress : .unread
    }
}

/// 参与搜索与排序的书库条目快照；由仓库层从目录记录和用户
/// 状态组装，搜索本身保持纯函数。
struct LibrarySortableComic: Equatable, Identifiable, Sendable {
    let id: ManagedComicID
    let displayName: String
    let importedAt: Date
    let isFavorite: Bool
    /// 最近一次记录阅读进度的时间；从未阅读为 `nil`。
    let lastReadAt: Date?
    let readState: LibraryComicReadState

    init(
        id: ManagedComicID,
        displayName: String,
        importedAt: Date,
        isFavorite: Bool = false,
        lastReadAt: Date? = nil,
        readState: LibraryComicReadState
    ) {
        self.id = id
        self.displayName = displayName
        self.importedAt = importedAt
        self.isFavorite = isFavorite
        self.lastReadAt = lastReadAt
        self.readState = readState
    }
}

enum LibrarySortOption: String, CaseIterable, Codable, Sendable {
    /// 按显示名的用户感知顺序（数字按数值比较）。
    case title
    /// 最近导入在前。
    case recentlyImported
    /// 最近阅读在前；从未阅读的排在末尾，按显示名排列。
    case recentlyRead
}

enum LibraryReadStateFilter: String, CaseIterable, Codable, Sendable {
    case all
    case unread
    case inProgress
    case completed
}

/// 书库搜索与筛选的用户决策；可序列化以便恢复上次的浏览状态。
struct LibrarySearchFilter: Codable, Equatable, Sendable {
    var searchText: String
    var favoritesOnly: Bool
    var readState: LibraryReadStateFilter
    var sort: LibrarySortOption

    static let `default` = Self(
        searchText: "",
        favoritesOnly: false,
        readState: .all,
        sort: .recentlyImported
    )

    init(
        searchText: String = "",
        favoritesOnly: Bool = false,
        readState: LibraryReadStateFilter = .all,
        sort: LibrarySortOption = .recentlyImported
    ) {
        self.searchText = searchText
        self.favoritesOnly = favoritesOnly
        self.readState = readState
        self.sort = sort
    }

    /// 是否存在任何 narrowing 条件（排序不计入）。
    var hasActiveCriteria: Bool {
        !normalizedSearchText.isEmpty || favoritesOnly || readState != .all
    }

    var normalizedSearchText: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 大小写与变音符号不敏感的包含匹配；空白搜索匹配全部。
    func matches(displayName: String) -> Bool {
        let query = normalizedSearchText.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: .current
        )
        guard !query.isEmpty else {
            return true
        }

        return displayName.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: .current
        )
        .contains(query)
    }
}

enum LibraryCatalogSearchEngine {
    /// 纯函数应用筛选与排序；不改变条目内容，只过滤和排序。
    static func filter(
        _ comics: [LibrarySortableComic],
        using filter: LibrarySearchFilter
    ) -> [LibrarySortableComic] {
        let filtered = comics.filter { comic in
            guard !filter.favoritesOnly || comic.isFavorite else {
                return false
            }
            guard readStateFilterMatches(filter.readState, comic.readState)
            else {
                return false
            }
            return filter.matches(displayName: comic.displayName)
        }

        return sorted(filtered, by: filter.sort)
    }

    private static func readStateFilterMatches(
        _ readStateFilter: LibraryReadStateFilter,
        _ readState: LibraryComicReadState
    ) -> Bool {
        switch readStateFilter {
        case .all:
            return true
        case .unread:
            return readState == .unread
        case .inProgress:
            return readState == .inProgress
        case .completed:
            return readState == .completed
        }
    }

    private static func sorted(
        _ comics: [LibrarySortableComic],
        by sort: LibrarySortOption
    ) -> [LibrarySortableComic] {
        comics.sorted { lhs, rhs in
            switch sort {
            case .title:
                return displayNameOrder(lhs, rhs)
            case .recentlyImported:
                if lhs.importedAt != rhs.importedAt {
                    return lhs.importedAt > rhs.importedAt
                }
                return displayNameOrder(lhs, rhs)
            case .recentlyRead:
                switch (lhs.lastReadAt, rhs.lastReadAt) {
                case (.some(let lhsDate), .some(let rhsDate)):
                    if lhsDate != rhsDate {
                        return lhsDate > rhsDate
                    }
                    return displayNameOrder(lhs, rhs)
                case (.some, .none):
                    return true
                case (.none, .some):
                    return false
                case (.none, .none):
                    return displayNameOrder(lhs, rhs)
                }
            }
        }
    }

    private static func displayNameOrder(
        _ lhs: LibrarySortableComic,
        _ rhs: LibrarySortableComic
    ) -> Bool {
        let comparison = lhs.displayName.localizedStandardCompare(
            rhs.displayName
        )
        if comparison != .orderedSame {
            return comparison == .orderedAscending
        }

        return lhs.id.rawValue.uuidString < rhs.id.rawValue.uuidString
    }
}
