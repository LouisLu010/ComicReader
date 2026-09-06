import Foundation
import SwiftUI

/// 每次打开均有独立窗口身份，同一本漫画也可在两个窗口各自导航。
struct ComicWindowRequest: Codable, Hashable, Sendable {
    let comicID: UUID
    let instanceID: UUID

    init(comicID: UUID, instanceID: UUID = UUID()) {
        self.comicID = comicID
        self.instanceID = instanceID
    }
}

struct ComicWindowContent: View {
    let request: ComicWindowRequest
    @Environment(LibraryCatalogCoordinator.self) private var catalog

    var body: some View {
        NavigationStack {
            if let comic = catalog.comics.first(where: { $0.id.rawValue == request.comicID }) {
                ComicDetailView(comic: comic, thumbnailURL: catalog.thumbnailURL(for: comic))
            } else if catalog.state == .idle || catalog.state == .loading {
                ProgressView("library.loading")
            } else {
                ContentUnavailableView {
                    Label("window.comic.unavailable", systemImage: "book.closed")
                } description: {
                    EmptyView()
                } actions: {
                    Button("common.retry") { Task { await catalog.reload() } }
                }
            }
        }
        .accessibilityIdentifier("window.comic")
    }
}
