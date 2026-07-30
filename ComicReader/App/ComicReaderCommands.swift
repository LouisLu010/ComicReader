import SwiftUI

struct ComicReaderCommands: Commands {
    @FocusedValue(\.importFoldersAction) private var importFoldersAction

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("import.action") {
                importFoldersAction?()
            }
            .keyboardShortcut("o", modifiers: .command)
            .disabled(importFoldersAction == nil)
        }
    }
}

private struct ImportFoldersActionKey: FocusedValueKey {
    typealias Value = () -> Void
}

extension FocusedValues {
    var importFoldersAction: (() -> Void)? {
        get { self[ImportFoldersActionKey.self] }
        set { self[ImportFoldersActionKey.self] = newValue }
    }
}
