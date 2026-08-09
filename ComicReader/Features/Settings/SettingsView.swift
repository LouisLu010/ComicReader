import SwiftUI

@MainActor
struct SettingsView: View {
    @Environment(LibraryCatalogCoordinator.self) private var libraryCatalog
    @Environment(LibraryStateRepository.self) private var libraryState
    @Environment(LibraryPersistenceController.self) private var persistence

    @State private var isRecoveryConfirmationPresented = false

    var body: some View {
        Form {
            Section("settings.reader.section") {
                Picker(
                    "settings.reader.defaultMode",
                    selection: defaultReadingModeBinding
                ) {
                    ForEach(ReadingMode.allCases, id: \.rawValue) { mode in
                        Text(mode.controlTitle)
                            .tag(mode)
                    }
                }
                .pickerStyle(.menu)
                .accessibilityIdentifier("settings.reader.defaultMode")

                Picker(
                    "settings.reader.defaultDirection",
                    selection: defaultReadingDirectionBinding
                ) {
                    ForEach(
                        ReadingDirection.allCases,
                        id: \.rawValue
                    ) { direction in
                        Text(direction.controlTitle)
                            .tag(direction)
                    }
                }
                .pickerStyle(.menu)
                .accessibilityIdentifier("settings.reader.defaultDirection")

                Text("settings.reader.defaults.description")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .disabled(!canModifyReaderPreferences)

            Section("settings.reader.tapAreas.section") {
                tapActionPicker(
                    "settings.reader.tapArea.left",
                    selection: tapZoneBinding(isLeftZone: true),
                    accessibilityIdentifier: "settings.reader.tapArea.left"
                )
                tapActionPicker(
                    "settings.reader.tapArea.right",
                    selection: tapZoneBinding(isLeftZone: false),
                    accessibilityIdentifier: "settings.reader.tapArea.right"
                )

                Text("settings.reader.tapAreas.description")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .disabled(!canModifyReaderPreferences)

            Section("settings.library.section") {
                Button {
                    Task {
                        await rebuildLibraryIndex()
                    }
                } label: {
                    Label(
                        "settings.library.rebuild",
                        systemImage: "arrow.triangle.2.circlepath"
                    )
                }
                .disabled(!canRebuildLibraryIndex)
                .accessibilityIdentifier("settings.rebuildIndex")

                Text("settings.library.rebuild.description")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                if persistence.status == .opening {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("settings.library.opening")
                    }
                    .accessibilityIdentifier("settings.openingIndex")
                } else if persistence.status == .recovering {
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

    private var canModifyReaderPreferences: Bool {
        libraryState.status == .ready && libraryState.isWriteAvailable
    }

    private var defaultReadingModeBinding: Binding<ReadingMode> {
        Binding(
            get: {
                libraryState.globalReaderPreferences.defaultReadingMode
            },
            set: { mode in
                Task { @MainActor in
                    _ = await libraryState.setDefaultReadingMode(mode)
                }
            }
        )
    }

    private var defaultReadingDirectionBinding: Binding<ReadingDirection> {
        Binding(
            get: {
                libraryState.globalReaderPreferences.defaultReadingDirection
            },
            set: { direction in
                Task { @MainActor in
                    _ = await libraryState.setDefaultReadingDirection(
                        direction
                    )
                }
            }
        )
    }

    private func tapZoneBinding(
        isLeftZone: Bool
    ) -> Binding<ReaderTapZoneAction> {
        Binding(
            get: {
                let tapAreas = libraryState.globalReaderPreferences.tapAreas
                return isLeftZone
                    ? tapAreas.leftAction
                    : tapAreas.rightAction
            },
            set: { action in
                Task { @MainActor in
                    _ = await libraryState.setTapZoneAction(
                        action,
                        isLeftZone: isLeftZone
                    )
                }
            }
        )
    }

    private func tapActionPicker(
        _ title: LocalizedStringKey,
        selection: Binding<ReaderTapZoneAction>,
        accessibilityIdentifier: String
    ) -> some View {
        Picker(title, selection: selection) {
            ForEach(ReaderTapZoneAction.allCases, id: \.rawValue) { action in
                Text(action.controlTitle)
                    .tag(action)
            }
        }
        .pickerStyle(.menu)
        .accessibilityIdentifier(accessibilityIdentifier)
    }

    private var canRebuildLibraryIndex: Bool {
        guard persistence.status == .ready else {
            return false
        }

        return libraryState.status == .ready
            || libraryState.status == .failed
    }

    private func rebuildLibraryIndex() async {
        // 重建是用户明确触发的索引修复，可在 repository.failed 后重试。
        guard await libraryCatalog.reload(),
              !Task.isCancelled,
              canRebuildLibraryIndex else {
            return
        }

        await libraryState.reconcile(catalogItems: libraryCatalog.comics)
    }
}

private extension ReaderTapZoneAction {
    var controlTitle: LocalizedStringKey {
        switch self {
        case .automatic:
            "reader.tapAction.automatic"
        case .previousPage:
            "reader.commands.previousPage"
        case .nextPage:
            "reader.commands.nextPage"
        case .toggleControls:
            "reader.commands.toggleControls"
        case .disabled:
            "reader.tapAction.disabled"
        }
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
