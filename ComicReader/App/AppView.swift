import SwiftUI
import UniformTypeIdentifiers

struct AppView: View {
    @Bindable var router: AppRouter
    @Environment(FolderImportCoordinator.self) private var importCoordinator

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detail
        }
        .navigationSplitViewStyle(.balanced)
        .fileImporter(
            isPresented: importerBinding,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: true,
            onCompletion: importCoordinator.handle
        )
        .focusedSceneValue(\.importFoldersAction) {
            router.presentedImporter = .folders
        }
    }

    private var sidebar: some View {
        List(selection: $router.selectedSection) {
            Section("library.sidebar") {
                ForEach(LibrarySection.librarySections) { section in
                    Label(section.title, systemImage: section.systemImage)
                        .tag(Optional(section))
                        .accessibilityIdentifier("sidebar.\(section.id)")
                }
            }

            Section {
                Label(LibrarySection.settings.title, systemImage: LibrarySection.settings.systemImage)
                    .tag(Optional(LibrarySection.settings))
                    .accessibilityIdentifier("sidebar.settings")
            }
        }
        .navigationTitle("app.name")
    }

    @ViewBuilder
    private var detail: some View {
        switch router.selectedSection ?? .all {
        case .settings:
            SettingsView()
        case let section:
            LibraryView(section: section) {
                router.presentedImporter = .folders
            }
        }
    }

    private var importerBinding: Binding<Bool> {
        Binding(
            get: { router.presentedImporter != nil },
            set: { isPresented in
                if !isPresented {
                    router.presentedImporter = nil
                }
            }
        )
    }
}

#Preview {
    AppView(router: AppRouter())
        .environment(FolderImportCoordinator())
}
