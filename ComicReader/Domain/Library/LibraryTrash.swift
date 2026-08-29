import Foundation

/// 软删除标记：写入库漫画的 metadata 目录，存在即表示该漫画
/// 处于"最近删除"状态；原文件保持原位，可随时恢复。
struct LibraryTrashMarker: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let comicID: ManagedComicID
    let trashedAt: Date

    init(
        schemaVersion: Int = Self.currentSchemaVersion,
        comicID: ManagedComicID,
        trashedAt: Date
    ) {
        self.schemaVersion = schemaVersion
        self.comicID = comicID
        self.trashedAt = trashedAt
    }
}

/// 回收站保留期：软删除 30 天后可被自动清理。
enum LibraryTrashRetention {
    static let dayCount = 30

    static func purgeDate(forTrashedAt trashedAt: Date) -> Date {
        trashedAt.addingTimeInterval(TimeInterval(dayCount) * 86_400)
    }
}

/// 回收站中一部漫画的可展示快照。
struct LibraryTrashedComic: Equatable, Identifiable, Sendable {
    let id: ManagedComicID
    let displayName: String
    let trashedAt: Date

    var purgeAfter: Date {
        LibraryTrashRetention.purgeDate(forTrashedAt: trashedAt)
    }

    func isPurgeDue(now: Date) -> Bool {
        now >= purgeAfter
    }
}

enum LibraryTrashPolicy {
    /// 返回保留期已满、应当被清理的漫画；顺序与传入顺序一致。
    static func purgeDueComicIDs(
        _ trashedComics: [LibraryTrashedComic],
        now: Date
    ) -> [ManagedComicID] {
        trashedComics
            .filter { $0.isPurgeDue(now: now) }
            .map(\.id)
    }
}
