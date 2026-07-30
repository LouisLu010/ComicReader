import SwiftUI

struct LibraryView: View {
    let section: LibrarySection
    let onImport: () -> Void

    @Environment(FolderImportCoordinator.self) private var importCoordinator

    var body: some View {
        Group {
            switch importCoordinator.status {
            case let .preview(manifests):
                ImportManifestDebugView(manifests: manifests)
            case let .scanning(folderNames):
                VStack(spacing: 20) {
                    ImportSelectionBanner(
                        status: .scanning(folderNames: folderNames)
                    )
                    emptyLibrary
                }
                .padding()
            case .idle, .failed:
                VStack(spacing: 20) {
                    if importCoordinator.status == .failed {
                        ImportSelectionBanner(status: .failed)
                    }
                    emptyLibrary
                }
                .padding()
            }
        }
        .navigationTitle(section.title)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(action: onImport) {
                    Label("import.action", systemImage: "folder.badge.plus")
                }
                .accessibilityIdentifier("import.toolbarButton")
            }
        }
    }

    private var emptyLibrary: some View {
        ContentUnavailableView {
            Label(section.title, systemImage: section.systemImage)
        } description: {
            Text("library.empty.description")
        } actions: {
            Button(action: onImport) {
                Label("import.action", systemImage: "folder.badge.plus")
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("import.button")
        }
        .accessibilityIdentifier("library.empty")
    }
}

private struct ImportSelectionBanner: View {
    let status: FolderImportStatus

    var body: some View {
        GroupBox {
            switch status {
            case .idle:
                EmptyView()
            case let .scanning(folderNames):
                VStack(alignment: .leading, spacing: 6) {
                    Label {
                        Text("import.scanning.title")
                    } icon: {
                        ProgressView()
                    }
                    Text(
                        String.localizedStringWithFormat(
                            String(localized: "import.scanning.count"),
                            folderNames.count
                        )
                    )
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            case .preview:
                EmptyView()
            case .failed:
                VStack(alignment: .leading, spacing: 6) {
                    Label("import.failed.title", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text("import.failed.description")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: 620)
    }
}

#Preview("Empty library") {
    NavigationStack {
        LibraryView(section: .all) {}
            .environment(FolderImportCoordinator())
    }
}
