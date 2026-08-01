import SwiftUI

struct ComicReaderCommands: Commands {
    @FocusedValue(\.importFoldersCommand) private var importFoldersCommand

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("import.action") {
                importFoldersCommand?.perform()
            }
            .keyboardShortcut("o", modifiers: .command)
            .disabled(importFoldersCommand?.isEnabled != true)
        }
    }
}

struct ImportFoldersCommand {
    let isEnabled: Bool
    let perform: () -> Void
}

private struct ImportFoldersCommandKey: FocusedValueKey {
    typealias Value = ImportFoldersCommand
}

extension FocusedValues {
    var importFoldersCommand: ImportFoldersCommand? {
        get { self[ImportFoldersCommandKey.self] }
        set { self[ImportFoldersCommandKey.self] = newValue }
    }
}
