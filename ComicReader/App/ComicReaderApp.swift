import SwiftData
import SwiftUI

@main
struct ComicReaderApp: App {
    @State private var importJobs = ImportJobCoordinator()
    @State private var libraryState = LibraryStateRepository()
    @State private var persistence = LibraryPersistenceController()

    var body: some Scene {
        WindowGroup {
            ApplicationRoot(modelContainer: persistence.modelContainer)
                .environment(importJobs)
                .environment(libraryState)
                .environment(persistence)
                .task {
                    await persistence.openApplicationStore()
                }
        }
        .commands {
            ComicReaderCommands()
        }
    }
}

private struct ApplicationRoot: View {
    let modelContainer: ModelContainer?

    var body: some View {
        Group {
            if let modelContainer {
                SceneRoot(modelContainer: modelContainer)
                    .modelContainer(modelContainer)
            } else {
                SceneRoot()
            }
        }
    }
}
