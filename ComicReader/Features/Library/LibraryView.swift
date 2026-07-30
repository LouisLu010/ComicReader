import SwiftUI

struct LibraryView: View {
    let section: LibrarySection
    let onImport: () -> Void

    @Environment(FolderImportCoordinator.self) private var importCoordinator

    var body: some View {
        VStack(spacing: 20) {
            if importCoordinator.status != .idle {
                ImportSelectionBanner(status: importCoordinator.status)
            }

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
        .padding()
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
}

private struct ImportSelectionBanner: View {
    let status: FolderImportStatus

    var body: some View {
        GroupBox {
            switch status {
            case .idle:
                EmptyView()
            case let .selected(names):
                VStack(alignment: .leading, spacing: 6) {
                    Label("import.selection.title", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text(
                        String.localizedStringWithFormat(
                            String(localized: "import.selection.count"),
                            names.count
                        )
                    )
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
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
