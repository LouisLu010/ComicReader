import SwiftUI

struct SceneRoot: View {
    @State private var router = AppRouter()
    @State private var importCoordinator = FolderImportCoordinator()
    @State private var libraryCatalog = LibraryCatalogCoordinator()
    @Environment(ImportJobCoordinator.self) private var importJobs

    var body: some View {
        AppView(router: router)
            .environment(importCoordinator)
            .environment(importJobs)
            .environment(libraryCatalog)
            .task {
                await importJobs.restorePendingJobs()
                await libraryCatalog.reload()
            }
            .task(id: importJobs.completedJobIDs) {
                await libraryCatalog.reload()
            }
    }
}

#Preview {
    SceneRoot()
        .environment(ImportJobCoordinator())
}
