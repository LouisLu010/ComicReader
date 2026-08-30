import SwiftUI

/// 详情页的书架成员操作：列出用户书架，点按切换该漫画的
/// 加入/移出状态；环境读取全部收敛在本子视图内。
struct ComicShelfMembershipAction: View {
    let comicID: ManagedComicID

    @Environment(LibraryStateRepository.self) private var libraryState
    @State private var shelves: [ComicShelf] = []
    @State private var memberShelfIDs = Set<ComicShelfID>()

    var body: some View {
        Group {
            if shelves.isEmpty {
                Label("library.shelves.empty", systemImage: "square.stack")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                Menu {
                    ForEach(shelves) { shelf in
                        Button {
                            Task {
                                await toggle(shelf)
                            }
                        } label: {
                            Label {
                                Text(shelf.displayName)
                            } icon: {
                                Image(
                                    systemName: memberShelfIDs.contains(shelf.id)
                                        ? "checkmark" : "circle"
                                )
                            }
                        }
                        .accessibilityIdentifier(
                            "library.shelves.toggle.\(shelf.displayName)"
                        )
                    }
                } label: {
                    Label("library.shelves.menu", systemImage: "square.stack")
                }
                .accessibilityIdentifier("library.shelves.menu")
            }
        }
        .padding(.top, 8)
        .task {
            await reload()
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
}
