import Foundation

/// 读取随漫画保存的来源授权记录。任何形式的记录缺失、损坏
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
}
