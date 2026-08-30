import Foundation

/// 用户自建书架的稳定标识。
struct ComicShelfID: Codable, Hashable, Sendable {
    let rawValue: UUID

    init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

/// 用户自建书架；漫画通过成员关系加入书架，一部漫画可同时
/// 属于多个书架。
struct ComicShelf: Equatable, Identifiable, Sendable {
    let id: ComicShelfID
    var displayName: String
    /// 书架在侧边栏中的顺序，从 0 开始。
    var sortOrder: Int
    let createdAt: Date

    init(
        id: ComicShelfID = ComicShelfID(),
        displayName: String,
        sortOrder: Int = 0,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.displayName = displayName
        self.sortOrder = sortOrder
        self.createdAt = createdAt
    }

    /// 创建/改名共用的名称校验：去除首尾空白后不得为空。
    static func normalizedName(_ rawName: String) -> String? {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }
}
