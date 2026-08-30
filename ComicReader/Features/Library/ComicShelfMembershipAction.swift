import SwiftUI

/// 详情页的书架成员操作：打开成员管理面板，可新建书架（自动
/// 加入）并切换该漫画在各书架中的成员身份；环境读取全部收敛
/// 在本子视图内。
struct ComicShelfMembershipAction: View {
    let comicID: ManagedComicID

    @State private var isSheetPresented = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                isSheetPresented = true
            } label: {
                Label("library.shelves.menu", systemImage: "square.stack")
            }
            .accessibilityIdentifier("library.shelves.menu")
        }
        .padding(.top, 8)
        .sheet(isPresented: $isSheetPresented) {
            LibraryShelfMembershipSheet(comicID: comicID)
        }
    }
}

/// 书架成员管理面板：切换漫画的成员身份，并可新建书架（新
/// 建后自动加入）。
private struct LibraryShelfMembershipSheet: View {
    let comicID: ManagedComicID

    @Environment(\.dismiss) private var dismiss
    @Environment(LibraryStateRepository.self) private var libraryState
    @State private var shelves: [ComicShelf] = []
    @State private var memberShelfIDs = Set<ComicShelfID>()
    @State private var newShelfName = ""

    var body: some View {
        NavigationStack {
            List {
                Section("library.shelves.menu") {
                    if shelves.isEmpty {
                        Text("library.shelves.empty.description")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(shelves) { shelf in
                            Button {
                                Task {
                                    await toggle(shelf)
                                }
                            } label: {
                                HStack {
                                    Text(shelf.displayName)
                                    Spacer()
                                    Image(
                                        systemName: memberShelfIDs.contains(
                                            shelf.id
                                        ) ? "checkmark" : "circle"
                                    )
                                }
                            }
                            .accessibilityIdentifier(
                                "library.shelf.row.\(shelf.displayName)"
                            )
                        }
                    }
                }

                Section("library.shelves.create.title") {
                    TextField(
                        "library.shelves.create.placeholder",
                        text: $newShelfName
                    )
                    .accessibilityIdentifier("library.shelves.create.field")

                    Button("library.shelves.add") {
                        Task {
                            await createAndJoin()
                        }
                    }
                    .disabled(
                        ComicShelf.normalizedName(newShelfName) == nil
                    )
                    .accessibilityIdentifier("library.shelves.add")
                }
            }
            .navigationTitle("library.shelves.menu")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("common.ok") {
                        dismiss()
                    }
                    .accessibilityIdentifier("library.shelves.done")
                }
            }
            .task {
                await reload()
            }
        }
    }

    private func reload() async {
        shelves = await libraryState.shelves()
        let containing = await libraryState.shelves(containing: comicID)
        memberShelfIDs = Set(containing.map(\.id))
    }

    private func toggle(_ shelf: ComicShelf) async {
        if memberShelfIDs.contains(shelf.id) {
            _ = await libraryState.removeComic(comicID, fromShelf: shelf.id)
        } else {
            _ = await libraryState.addComic(comicID, toShelf: shelf.id)
        }

        await reload()
    }

    /// 新建书架并加入；同名书架已存在时直接加入该书架。
    private func createAndJoin() async {
        guard let name = ComicShelf.normalizedName(newShelfName) else {
            return
        }

        let targetShelf: ComicShelf
        if let existing = shelves.first(where: { $0.displayName == name }) {
            targetShelf = existing
        } else if let created = await libraryState.createShelf(named: name) {
            targetShelf = created
        } else {
            return
        }

        _ = await libraryState.addComic(comicID, toShelf: targetShelf.id)
        newShelfName = ""
        await reload()
    }
}
