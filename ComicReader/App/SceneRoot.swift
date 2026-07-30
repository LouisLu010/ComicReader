import SwiftData
import SwiftUI

struct SceneRoot: View {
    let modelContainer: ModelContainer?

    @State private var router = AppRouter()
    @State private var importCoordinator = FolderImportCoordinator()
    @State private var libraryCatalog = LibraryCatalogCoordinator()
    @State private var didLoadLibrary = false
    @Environment(ImportJobCoordinator.self) private var importJobs
    @Environment(LibraryStateRepository.self) private var libraryState

    init(modelContainer: ModelContainer? = nil) {
        self.modelContainer = modelContainer
    }

    var body: some View {
        AppView(router: router)
            .environment(importCoordinator)
            .environment(importJobs)
            .environment(libraryCatalog)
            .task {
                await libraryState.configure(modelContainer: modelContainer)
                await importJobs.restorePendingJobs()
                didLoadLibrary = true
                await libraryCatalog.reloadAndReconcile(with: libraryState)
            }
            .task(id: importJobs.completedJobIDs) {
                guard didLoadLibrary else {
                    return
                }

                await libraryCatalog.reloadAndReconcile(with: libraryState)
            }
    }
}

#Preview {
    SceneRoot()
        .environment(ImportJobCoordinator())
        .environment(LibraryStateRepository())
        .environment(
            LibraryPersistenceController(previewModelContainer: nil)
        )
}
