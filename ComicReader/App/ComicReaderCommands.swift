import SwiftUI

struct ComicReaderCommands: Commands {
    @Environment(\.openWindow) private var openWindow
    @FocusedValue(\.importFoldersCommand) private var importFoldersCommand
    @FocusedValue(\.readerCommandSet) private var readerCommandSet
    @FocusedValue(\.librarySearchCommand) private var librarySearchCommand
    @FocusedValue(\.librarySettingsCommand) private var librarySettingsCommand
    @FocusedValue(\.privacyLockCommand) private var privacyLockCommand

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("window.new") { openWindow(id: "library") }
                .keyboardShortcut("n", modifiers: .command)
        }
        CommandGroup(after: .newItem) {
            Button("import.action") {
                importFoldersCommand?.perform()
            }
            .keyboardShortcut("o", modifiers: .command)
            .disabled(importFoldersCommand?.isEnabled != true)
        }

        CommandMenu("app.commands.menu") {
            Button("library.search.prompt") { librarySearchCommand?.performIfEnabled() }
                .keyboardShortcut("f", modifiers: .command)
                .disabled(librarySearchCommand?.isEnabled != true)
            Button("settings.title") { librarySettingsCommand?.performIfEnabled() }
                .keyboardShortcut(",", modifiers: .command)
                .disabled(librarySettingsCommand?.isEnabled != true)
            Button("privacy.lockNow") { privacyLockCommand?.performIfEnabled() }
                .keyboardShortcut("l", modifiers: [.command, .control])
                .disabled(privacyLockCommand?.isEnabled != true)
        }

        CommandMenu("reader.commands.menu") {
            Button("reader.commands.nextPage") {
                readerCommandSet?.nextPage.performIfEnabled()
            }
            .keyboardShortcut(.space, modifiers: [])
            .disabled(readerCommandSet?.nextPage.isEnabled != true)
            Button("reader.commands.previousPage") {
                readerCommandSet?.previousPage.performIfEnabled()
            }
            .keyboardShortcut(previousPageKey, modifiers: [])
            .disabled(readerCommandSet?.previousPage.isEnabled != true)

            Button("reader.commands.nextPage") {
                readerCommandSet?.nextPage.performIfEnabled()
            }
            .keyboardShortcut(nextPageKey, modifiers: [])
            .disabled(readerCommandSet?.nextPage.isEnabled != true)

            Button("reader.commands.toggleControls") {
                readerCommandSet?.toggleControls.performIfEnabled()
            }
            .keyboardShortcut("h", modifiers: .command)
            .disabled(readerCommandSet?.toggleControls.isEnabled != true)

            Divider()

            Button("reader.navigation.previousChapter") {
                readerCommandSet?.previousChapter.performIfEnabled()
            }
            .keyboardShortcut(previousPageKey, modifiers: .option)
            .disabled(readerCommandSet?.previousChapter.isEnabled != true)

            Button("reader.navigation.nextChapter") {
                readerCommandSet?.nextChapter.performIfEnabled()
            }
            .keyboardShortcut(nextPageKey, modifiers: .option)
            .disabled(readerCommandSet?.nextChapter.isEnabled != true)

            Button("reader.navigation.chapters") {
                readerCommandSet?.showChapterList.performIfEnabled()
            }
            .keyboardShortcut("l", modifiers: .command)
            .disabled(readerCommandSet?.showChapterList.isEnabled != true)

            Divider()
            Button("reader.zoom.in") { readerCommandSet?.zoomIn.performIfEnabled() }
                .keyboardShortcut("+", modifiers: .command)
                .disabled(readerCommandSet?.zoomIn.isEnabled != true)
            Button("reader.zoom.out") { readerCommandSet?.zoomOut.performIfEnabled() }
                .keyboardShortcut("-", modifiers: .command)
                .disabled(readerCommandSet?.zoomOut.isEnabled != true)
            Button("reader.display.title") { readerCommandSet?.displaySettings.performIfEnabled() }
                .keyboardShortcut("d", modifiers: [.command, .shift])
                .disabled(readerCommandSet?.displaySettings.isEnabled != true)
        }
    }

    private var previousPageKey: KeyEquivalent {
        keyEquivalent(for: .backward)
    }

    private var nextPageKey: KeyEquivalent {
        keyEquivalent(for: .forward)
    }

    private func keyEquivalent(
        for step: ReaderLogicalPageStep
    ) -> KeyEquivalent {
        let direction = readerCommandSet?.readingDirection ?? .leftToRight
        return ReaderKeyboardNavigationPolicy.logicalStep(
            for: .left,
            readingDirection: direction
        ) == step ? .leftArrow : .rightArrow
    }
}

struct ImportFoldersCommand {
    let isEnabled: Bool
    let perform: () -> Void
}

struct ReaderCommandAction {
    let isEnabled: Bool
    let perform: () -> Void

    func performIfEnabled() {
        guard isEnabled else {
            return
        }

        perform()
    }
}

struct ReaderCommandSet {
    let readingDirection: ReadingDirection
    let previousPage: ReaderCommandAction
    let nextPage: ReaderCommandAction
    let previousChapter: ReaderCommandAction
    let nextChapter: ReaderCommandAction
    let showChapterList: ReaderCommandAction
    let toggleControls: ReaderCommandAction
    let zoomIn: ReaderCommandAction
    let zoomOut: ReaderCommandAction
    let displaySettings: ReaderCommandAction
}

private struct ImportFoldersCommandKey: FocusedValueKey {
    typealias Value = ImportFoldersCommand
}

private struct ReaderCommandSetKey: FocusedValueKey {
    typealias Value = ReaderCommandSet
}

private struct LibrarySearchCommandKey: FocusedValueKey { typealias Value = ReaderCommandAction }
private struct LibrarySettingsCommandKey: FocusedValueKey { typealias Value = ReaderCommandAction }
private struct PrivacyLockCommandKey: FocusedValueKey { typealias Value = ReaderCommandAction }

extension FocusedValues {
    var librarySearchCommand: ReaderCommandAction? {
        get { self[LibrarySearchCommandKey.self] }
        set { self[LibrarySearchCommandKey.self] = newValue }
    }
    var librarySettingsCommand: ReaderCommandAction? {
        get { self[LibrarySettingsCommandKey.self] }
        set { self[LibrarySettingsCommandKey.self] = newValue }
    }
    var privacyLockCommand: ReaderCommandAction? {
        get { self[PrivacyLockCommandKey.self] }
        set { self[PrivacyLockCommandKey.self] = newValue }
    }
    var importFoldersCommand: ImportFoldersCommand? {
        get { self[ImportFoldersCommandKey.self] }
        set { self[ImportFoldersCommandKey.self] = newValue }
    }

    var readerCommandSet: ReaderCommandSet? {
        get { self[ReaderCommandSetKey.self] }
        set { self[ReaderCommandSetKey.self] = newValue }
    }
}
