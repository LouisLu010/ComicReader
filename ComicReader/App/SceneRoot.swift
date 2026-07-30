import SwiftUI

struct SceneRoot: View {
    @State private var router = AppRouter()
    @State private var importCoordinator = FolderImportCoordinator()
    @Environment(ImportJobCoordinator.self) private var importJobs

    var body: some View {
        AppView(router: router)
            .environment(importCoordinator)
            .environment(importJobs)
            .task {
                await importJobs.restorePendingJobs()
            }
    }
}

#Preview {
    SceneRoot()
        .environment(ImportJobCoordinator())
}
