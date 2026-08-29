import Foundation

/// 一次导入完成后随漫画保存的安全作用域书签，是后续同来源
/// 重新扫描的身份依据；记录损坏或缺失时更新流程回退到用户
/// 重新授权。该记录不包含绝对路径，也不并入已管理漫画描述符。
struct ComicSourceAuthorization: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let comicID: ManagedComicID
    let sourceRootName: String
    let bookmark: Data
    let authorizedAt: Date

    init(
        schemaVersion: Int = Self.currentSchemaVersion,
        comicID: ManagedComicID,
        sourceRootName: String,
        bookmark: Data,
        authorizedAt: Date = Date()
    ) {
        self.schemaVersion = schemaVersion
        self.comicID = comicID
        self.sourceRootName = sourceRootName
        self.bookmark = bookmark
        self.authorizedAt = authorizedAt
    }
}
