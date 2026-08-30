import SwiftUI

/// 书架管理：列出用户自建书架，支持新建、重命名与删除；
/// 点按某个书架进入其内容视图。
struct LibraryShelvesView: View {
    let onSelectShelf: (ComicShelfID) -> Void

    @Environment(LibraryStateRepository.self) private var libraryState
    @State private var isCreatePresented = false
    @State private var newShelfName = ""
    @State private var renamingShelf: ComicShelf?

    var body: some View {
        Group {
            if libraryState.shelves.isEmpty {
                ContentUnavailableView {
                    Label("library.shelves.title", systemImage: "square.stack")
                } description: {
                    Text("library.shelves.empty.description")
                } actions: {
                    Button {
                        isCreatePresented = true
                    } label: {
                        Label("library.shelves.create", systemImage: "plus")
                    }
                    .accessibilityIdentifier("library.shelves.create")
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 48)
                .accessibilityIdentifier("library.shelves.empty")
            } else {
                List {
                    ForEach(libraryState.shelves) { shelf in
                        Button {
                            onSelectShelf(shelf.id)
                        } label: {
                            HStack {
                                Text(shelf.displayName)
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .accessibilityIdentifier(
                            "library.shelves.shelf.\(shelf.id.rawValue.uuidString)"
                        )
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                Task {
                                    _ = await libraryState.deleteShelf(shelf.id)
                                }
                            } label: {
                                Label("library.shelves.delete", systemImage: "trash")
                            }
                            Button {
                                renamingShelf = shelf
                                newShelfName = shelf.displayName
                            } label: {
                                Label("library.shelves.rename", systemImage: "pencil")
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("library.section.shelves")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    isCreatePresented = true
                } label: {
                    Label("library.shelves.create", systemImage: "plus")
                }
                .accessibilityIdentifier("library.shelves.create")
            }
        }
        .alert(
            "library.shelves.create.title",
            isPresented: $isCreatePresented
        ) {
            TextField("library.shelves.create.placeholder", text: $newShelfName)
            Button("library.shelves.save") {
                Task {
                    _ = await libraryState.createShelf(named: newShelfName)
                    newShelfName = ""
                }
            }
            Button("common.cancel", role: .cancel) {
                newShelfName = ""
            }
        }
        .alert(
            "library.shelves.rename.title",
            isPresented: Binding(
                get: { renamingShelf != nil },
                set: { if !$0 { renamingShelf = nil } }
            )
        ) {
            TextField("library.shelves.create.placeholder", text: $newShelfName)
            Button("library.shelves.save") {
                Task {
                    if let renamingShelf {
                        _ = await libraryState.renameShelf(
                            renamingShelf.id,
                            to: newShelfName
                        )
                    }
                    newShelfName = ""
                }
            }
            Button("common.cancel", role: .cancel) {
                newShelfName = ""
                renamingShelf = nil
            }
        }
    }
}
