import Observation

@Observable
final class AppRouter {
    var selectedSection: LibrarySection? = .all
    var presentedImporter: ImportDestination?
}

enum ImportDestination: String, Identifiable {
    case folders

    var id: String { rawValue }
}
