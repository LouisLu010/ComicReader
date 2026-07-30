import SwiftUI

struct SettingsView: View {
    @Environment(LibraryCatalogCoordinator.self) private var libraryCatalog
    @Environment(LibraryStateRepository.self) private var libraryState
    @Environment(LibraryPersistenceController.self) private var persistence

    @State private var isRecoveryConfirmationPresented = false

    var body: some View {
        Form {
            Section("settings.library.section") {
                Button {
                    Task {
                        await libraryCatalog.reloadAndReconcile(
                            with: libraryState
                        )
                    }
                } label: {
                    Label(
                        "settings.library.rebuild",
                        systemImage: "arrow.triangle.2.circlepath"
                    )
                }
                .disabled(
                    persistence.status != .ready
                        || libraryState.status == .unavailable
                        || libraryState.status == .unconfigured
                        || libraryState.status == .loading
                )
                .accessibilityIdentifier("settings.rebuildIndex")

                Text("settings.library.rebuild.description")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                if persistence.status == .recovering {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("settings.library.repairing")
                    }
                    .accessibilityIdentifier("settings.repairingIndex")
                } else if showsRecoveryControls {
                    Button(role: .destructive) {
                        isRecoveryConfirmationPresented = true
                    } label: {
                        Label(
                            "settings.library.repair",
                            systemImage: "externaldrive.badge.exclamationmark"
                        )
                    }
                    .disabled(!persistence.canRecoverFailedIndex)
                    .accessibilityIdentifier("settings.repairIndex")

                    Text("settings.library.repair.description")
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    if persistence.status == .recoveryFailed {
                        Label(
                            "settings.library.repair.failed",
                            systemImage: "exclamationmark.triangle.fill"
                        )
                        .foregroundStyle(.orange)
                    }
                }
            }

            Section("settings.about.section") {
                LabeledContent("settings.about.version", value: "0.1.0")
            }

            Section("settings.privacy.section") {
                Text("settings.privacy.description")
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("settings.title")
        .alert(
            "settings.library.repair.confirm.title",
            isPresented: $isRecoveryConfirmationPresented
        ) {
            Button("common.cancel", role: .cancel) {}
            Button(
                "settings.library.repair.confirm.action",
                role: .destructive
            ) {
                Task {
                    await persistence.recoverFailedIndex()
                }
            }
        } message: {
            Text("settings.library.repair.confirm.message")
        }
    }

    private var showsRecoveryControls: Bool {
        persistence.status == .recoveryRequired
            || persistence.status == .recoveryFailed
    }
}

#Preview {
    NavigationStack {
        SettingsView()
            .environment(LibraryCatalogCoordinator())
            .environment(LibraryStateRepository())
            .environment(
                LibraryPersistenceController(previewModelContainer: nil)
            )
    }
}
