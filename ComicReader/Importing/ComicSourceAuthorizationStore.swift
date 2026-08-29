import Foundation

enum ComicSourceAuthorizationStoreError: Error, Equatable, Sendable {
    case unsupportedSchema
    case comicIDMismatch
}

/// 读写随漫画保存的来源授权记录。任何形式的记录缺失、损坏
/// 或不兼容都按无授权处理，由调用方回退到用户重新授权。
struct ComicSourceAuthorizationStore: Sendable {
    let layout: ImportStorageLayout

    /// 返回 `nil` 表示该漫画当前没有可用的来源授权。
    func load(
        for comicID: ManagedComicID
    ) -> ComicSourceAuthorization? {
        let authorizationURL = layout.sourceAuthorizationURL(for: comicID)
        guard FileManager.default.fileExists(atPath: authorizationURL.path),
              let data = try? Data(contentsOf: authorizationURL),
              let authorization = try? JSONDecoder().decode(
                ComicSourceAuthorization.self,
                from: data
              ) else {
            return nil
        }

        guard authorization.schemaVersion
                == ComicSourceAuthorization.currentSchemaVersion,
              authorization.comicID == comicID else {
            return nil
        }

        return authorization
    }

    /// 原子写入授权记录；记录不匹配目标漫画或 schema 未知时拒绝。
    func save(
        _ authorization: ComicSourceAuthorization,
        for comicID: ManagedComicID
    ) throws {
        guard authorization.schemaVersion
                == ComicSourceAuthorization.currentSchemaVersion else {
            throw ComicSourceAuthorizationStoreError.unsupportedSchema
        }
        guard authorization.comicID == comicID else {
            throw ComicSourceAuthorizationStoreError.comicIDMismatch
        }

        let authorizationURL = layout.sourceAuthorizationURL(for: comicID)
        try FileManager.default.createDirectory(
            at: authorizationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(authorization).write(
            to: authorizationURL,
            options: .atomic
        )
    }
}

/// 用用户重新选择的目录替换漫画的来源授权。书签身份随之切换，
/// 后续同来源更新扫描以新目录为准；失败时不改动现有授权。
struct ComicSourceReauthorizer: Sendable {
    private let sourceAccess: any ImportSourceAccessing
    private let store: ComicSourceAuthorizationStore

    init(
        sourceAccess: any ImportSourceAccessing = SecurityScopedSourceAccess(),
        store: ComicSourceAuthorizationStore
    ) {
        self.sourceAccess = sourceAccess
        self.store = store
    }

    func reauthorize(
        comicID: ManagedComicID,
        sourceURL: URL,
        now: Date = Date()
    ) throws -> ComicSourceAuthorization {
        let bookmark = try sourceAccess.makeBookmark(for: sourceURL)
        let authorization = ComicSourceAuthorization(
            comicID: comicID,
            sourceRootName: sourceURL.lastPathComponent,
            bookmark: bookmark,
            authorizedAt: now
        )
        try store.save(authorization, for: comicID)
        return authorization
    }
}
