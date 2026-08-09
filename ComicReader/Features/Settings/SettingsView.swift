import SwiftUI

@MainActor
struct SettingsView: View {
    @Environment(LibraryCatalogCoordinator.self) private var libraryCatalog
    @Environment(LibraryStateRepository.self) private var libraryState
    @Environment(LibraryPersistenceController.self) private var persistence

    @State private var isRecoveryConfirmationPresented = false
    @State private var readerPreferencesDraft = ReaderGlobalPreferences.default
    @State private var isSavingReaderPreferences = false
    @State private var readerPreferenceSaveFailed = false

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
                            .accessibilityIdentifier(
                                "settings.reader.defaultMode.\(mode.rawValue)"
                            )
                    }
                }
                .pickerStyle(.menu)
                .accessibilityIdentifier("settings.reader.defaultMode")
                .accessibilityValue(
                    Text(readerPreferencesDraft.defaultReadingMode.controlTitle)
                )

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
                            .accessibilityIdentifier(
                                "settings.reader.defaultDirection.\(direction.rawValue)"
                            )
                    }
                }
                .pickerStyle(.menu)
                .accessibilityIdentifier("settings.reader.defaultDirection")
                .accessibilityValue(
                    Text(
                        readerPreferencesDraft.defaultReadingDirection
                            .controlTitle
                    )
                )

                Text("settings.reader.defaults.description")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                if readerPreferenceSaveFailed {
                    Label(
                        "settings.reader.saveFailed",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .foregroundStyle(.orange)
                    .accessibilityIdentifier("settings.reader.saveFailed")
                }
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
        .onChange(
            of: libraryState.globalReaderPreferences,
            initial: true
        ) { _, preferences in
            guard !isSavingReaderPreferences else {
                return
            }

            readerPreferencesDraft = preferences
        }
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
        libraryState.status == .ready
            && libraryState.isWriteAvailable
            && !isSavingReaderPreferences
    }

    private var defaultReadingModeBinding: Binding<ReadingMode> {
        Binding(
            get: {
                readerPreferencesDraft.defaultReadingMode
            },
            set: { mode in
                saveReaderPreference(.defaultMode(mode))
            }
        )
    }

    private var defaultReadingDirectionBinding: Binding<ReadingDirection> {
        Binding(
            get: {
                readerPreferencesDraft.defaultReadingDirection
            },
            set: { direction in
                saveReaderPreference(.defaultDirection(direction))
            }
        )
    }

    private func tapZoneBinding(
        isLeftZone: Bool
    ) -> Binding<ReaderTapZoneAction> {
        Binding(
            get: {
                let tapAreas = readerPreferencesDraft.tapAreas
                return isLeftZone
                    ? tapAreas.leftAction
                    : tapAreas.rightAction
            },
            set: { action in
                saveReaderPreference(
                    isLeftZone ? .leftTap(action) : .rightTap(action)
                )
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
                    .accessibilityIdentifier(
                        "\(accessibilityIdentifier).\(action.rawValue)"
                    )
            }
        }
        .pickerStyle(.menu)
        .accessibilityIdentifier(accessibilityIdentifier)
        .accessibilityValue(Text(selection.wrappedValue.controlTitle))
    }

    private func saveReaderPreference(
        _ mutation: ReaderGlobalPreferenceMutation
    ) {
        guard canModifyReaderPreferences else {
            return
        }

        var updatedPreferences = readerPreferencesDraft
        mutation.apply(to: &updatedPreferences)
        guard updatedPreferences != readerPreferencesDraft else {
            return
        }

        readerPreferencesDraft = updatedPreferences
        isSavingReaderPreferences = true
        readerPreferenceSaveFailed = false
        Task { @MainActor in
            let didSave = await mutation.persist(using: libraryState)
            readerPreferencesDraft = libraryState.globalReaderPreferences
            isSavingReaderPreferences = false
            readerPreferenceSaveFailed = !didSave
        }
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

private enum ReaderGlobalPreferenceMutation {
    case defaultMode(ReadingMode)
    case defaultDirection(ReadingDirection)
    case leftTap(ReaderTapZoneAction)
    case rightTap(ReaderTapZoneAction)

    func apply(to preferences: inout ReaderGlobalPreferences) {
        switch self {
        case let .defaultMode(mode):
            preferences.defaultReadingMode = mode
        case let .defaultDirection(direction):
            preferences.defaultReadingDirection = direction
        case let .leftTap(action):
            preferences.tapAreas.leftAction = action
        case let .rightTap(action):
            preferences.tapAreas.rightAction = action
        }
    }

    @MainActor
    func persist(using repository: LibraryStateRepository) async -> Bool {
        switch self {
        case let .defaultMode(mode):
            await repository.setDefaultReadingMode(mode)
        case let .defaultDirection(direction):
            await repository.setDefaultReadingDirection(direction)
        case let .leftTap(action):
            await repository.setTapZoneAction(action, isLeftZone: true)
        case let .rightTap(action):
            await repository.setTapZoneAction(action, isLeftZone: false)
        }
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
