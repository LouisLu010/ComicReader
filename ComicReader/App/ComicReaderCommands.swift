import SwiftUI

struct ComicReaderCommands: Commands {
    @FocusedValue(\.importFoldersCommand) private var importFoldersCommand
    @FocusedValue(\.readerCommandSet) private var readerCommandSet

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("import.action") {
                importFoldersCommand?.perform()
            }
            .keyboardShortcut("o", modifiers: .command)
            .disabled(importFoldersCommand?.isEnabled != true)
        }

        CommandMenu("reader.commands.menu") {
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
}

private struct ImportFoldersCommandKey: FocusedValueKey {
    typealias Value = ImportFoldersCommand
}

private struct ReaderCommandSetKey: FocusedValueKey {
    typealias Value = ReaderCommandSet
}

extension FocusedValues {
    var importFoldersCommand: ImportFoldersCommand? {
        get { self[ImportFoldersCommandKey.self] }
        set { self[ImportFoldersCommandKey.self] = newValue }
    }

    var readerCommandSet: ReaderCommandSet? {
        get { self[ReaderCommandSetKey.self] }
        set { self[ReaderCommandSetKey.self] = newValue }
    }
}
