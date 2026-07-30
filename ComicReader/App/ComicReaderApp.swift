import SwiftUI

@main
struct ComicReaderApp: App {
    @State private var importJobs = ImportJobCoordinator()

    var body: some Scene {
        WindowGroup {
            SceneRoot()
                .environment(importJobs)
        }
        .commands {
            ComicReaderCommands()
        }
    }
}
