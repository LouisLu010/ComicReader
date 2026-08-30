import SwiftUI

/// 单个书架的内容网格；成员按加入顺序展示。
struct LibraryShelfContentView: View {
    let shelfID: ComicShelfID

    @Environment(LibraryStateRepository.self) private var libraryState
    @Environment(LibraryCatalogCoordinator.self) private var libraryCatalog
    @State private var comics: [LibraryCatalogItem] = []

    private var shelf: ComicShelf? {
        libraryState.shelves.first { $0.id == shelfID }
    }

    var body: some View {
        Group {
            if comics.isEmpty {
                ContentUnavailableView {
                    Label(
                        shelf?.displayName ?? "",
                        systemImage: "square.stack"
                    )
                } description: {
                    Text("library.shelf.empty.description")
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 48)
                .accessibilityIdentifier("library.shelf.empty")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 20) {
                        LibraryComicGrid(
                            title: LocalizedStringKey(
                                shelf?.displayName ?? ""
                            ),
                            comics: comics,
                            thumbnailURL: { comic in
                                libraryCatalog.thumbnailURL(for: comic)
                            }
                        )
                    }
                    .frame(maxWidth: 820, alignment: .leading)
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .center)
                }
            }
        }
        .navigationTitle(Text(verbatim: shelf?.displayName ?? ""))
        .task(id: shelfID) {
            await reload()
        }
        .refreshable {
            await reload()
        }
    }

    private func reload() async {
        let memberIDs = await libraryState.comicIDs(inShelf: shelfID)
        let itemsByID = Dictionary(
            uniqueKeysWithValues: libraryCatalog.comics.map { ($0.id, $0) }
        )
        comics = memberIDs.compactMap { itemsByID[$0] }
    }
}
