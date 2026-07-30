import SwiftUI

struct SceneRoot: View {
    @State private var router = AppRouter()
    @State private var importCoordinator = FolderImportCoordinator()

    var body: some View {
        AppView(router: router)
            .environment(importCoordinator)
    }
}

#Preview {
    SceneRoot()
}
