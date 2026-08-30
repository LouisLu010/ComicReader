import Observation

@Observable
final class AppRouter {
    var selectedSection: LibrarySection? = .all
    /// 书架分区中当前选中的书架；仅 `selectedSection == .shelves` 时生效。
    var selectedShelfID: ComicShelfID?
    var presentedImporter: ImportDestination?
}

enum ImportDestination: String, Identifiable {
    case folders

    var id: String { rawValue }
}
