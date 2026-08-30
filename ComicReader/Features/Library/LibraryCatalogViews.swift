import SwiftUI
import UIKit

struct LibraryComicGrid: View {
    let title: LocalizedStringKey
    let comics: [LibraryCatalogItem]
    let thumbnailURL: (LibraryCatalogItem) -> URL?

    @Environment(LibraryStateRepository.self) private var libraryState

    private let columns = [
        GridItem(.adaptive(minimum: 164, maximum: 220), spacing: 18),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: "books.vertical")
                .font(.headline)

            LazyVGrid(columns: columns, alignment: .leading, spacing: 22) {
                ForEach(comics) { comic in
                    NavigationLink {
                        ComicDetailView(
                            comic: comic,
                            thumbnailURL: thumbnailURL(comic)
                        )
                    } label: {
                        LibraryComicCard(
                            comic: comic,
                            thumbnailURL: thumbnailURL(comic),
                            userState: libraryState.state(for: comic.id)
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier(
                        "library.comic.\(comic.id.rawValue.uuidString)"
                    )
                }
            }
        }
        .accessibilityIdentifier("library.grid")
    }
}

struct ComicDetailView: View {
    let comic: LibraryCatalogItem
    let thumbnailURL: URL?

    @Environment(LibraryStateRepository.self) private var libraryState
    @Environment(LibraryCatalogCoordinator.self) private var libraryCatalog
    @Environment(LibraryTrashCoordinator.self) private var libraryTrash
    @Environment(\.readerFeatureServices) private var readerFeatureServices
    @Environment(\.dismiss) private var dismiss
    @State private var isTrashConfirmationPresented = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                readingEntry
                details
                contentTree
                dangerZone
            }
            .frame(maxWidth: 720, alignment: .leading)
            .padding()
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .navigationTitle(comic.record.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task {
                        await libraryState.toggleFavorite(for: comic.id)
                    }
                } label: {
                    Label(
                        favoriteActionTitle,
                        systemImage: favoriteSymbolName
                    )
                }
                .disabled(!libraryState.canModifyState(for: comic.id))
                .accessibilityIdentifier("library.favorite")
            }

        }
        .alert(
            "library.detail.trash.confirm",
            isPresented: $isTrashConfirmationPresented
        ) {
            Button("library.detail.trash.confirm.action", role: .destructive) {
                Task {
                    await trashComic()
                }
            }
            .accessibilityIdentifier("library.detail.trash.confirm.action")
        } message: {
            Text("library.detail.trash.confirm.message")
        }
        .accessibilityIdentifier("library.detail")
    }

    private func trashComic() async {
        let didTrash = await libraryTrash.trashComic(for: comic.id)
        guard didTrash else {
            return
        }

        await libraryCatalog.reload()
        dismiss()
    }

    private var dangerZone: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button(role: .destructive) {
                isTrashConfirmationPresented = true
            } label: {
                Label("library.detail.trash", systemImage: "trash")
            }
            .accessibilityIdentifier("library.detail.trash")
        }
        .padding(.top, 8)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 20) {
            LibraryCoverThumbnail(url: thumbnailURL, cornerRadius: 18)
                .frame(width: 164, height: 230)

            VStack(alignment: .leading, spacing: 12) {
                Text(comic.record.displayName)
                    .font(.largeTitle.weight(.bold))
                    .multilineTextAlignment(.leading)

                Text(
                    String.localizedStringWithFormat(
                        String(localized: "library.detail.summary"),
                        comic.record.chapterCount,
                        comic.record.pageCount
                    )
                )
                .font(.headline)
                .foregroundStyle(.secondary)

                Label {
                    Text(comic.record.importedAt, style: .date)
                } icon: {
                    Image(systemName: "clock")
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)
        }
    }

    private var details: some View {
        GroupBox("library.detail.metadata") {
            VStack(alignment: .leading, spacing: 10) {
                LabeledContent(
                    "library.detail.chapters",
                    value: comic.record.chapterCount.formatted()
                )
                LabeledContent(
                    "library.detail.pages",
                    value: comic.record.pageCount.formatted()
                )
                LabeledContent {
                    Text(thumbnailStatusKey)
                } label: {
                    Text("library.detail.thumbnail")
                }
                LabeledContent {
                    Text(favoriteStatusKey)
                } label: {
                    Text("library.detail.favorite")
                }
            }
        }
    }

    @ViewBuilder
    private var readingEntry: some View {
        if let readerFeatureServices {
            NavigationLink {
                ReaderScreen(
                    comicID: comic.id,
                    title: comic.record.displayName,
                    contentLoader: readerFeatureServices.contentLoader,
                    progressRecorder: libraryState,
                    persistedProgress: readingProgress,
                    readerOverrides: libraryState.readerOverrides(
                        for: comic.id
                    ),
                    resolvedReaderPreferences: libraryState
                        .resolvedReaderPreferences(for: comic.id),
                    canModifyReaderPreferences: (
                        libraryState.canModifyState(for: comic.id)
                            && libraryState.isWriteAvailable
                    ),
                    preferencesWriter: libraryState
                )
            } label: {
                Label(readingActionTitle, systemImage: "book.pages")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .accessibilityIdentifier("library.read")
        } else {
            Label(
                "library.read.unavailable",
                systemImage: "exclamationmark.triangle"
            )
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier("library.read.unavailable")
        }
    }

    private var contentTree: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("library.detail.contents", systemImage: "point.3.connected.trianglepath.dotted")
                .font(.headline)

            if comic.record.contentTree.isEmpty {
                ContentUnavailableView {
                    Label(
                        "library.detail.contents.empty.title",
                        systemImage: "rectangle.stack.badge.questionmark"
                    )
                } description: {
                    Text("library.detail.contents.empty.description")
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
            } else {
                LibraryContentTree(nodes: comic.record.contentTree)
            }
        }
    }

    private var thumbnailStatusKey: LocalizedStringKey {
        comic.thumbnailAvailable
            ? "library.detail.thumbnail.available"
            : "library.detail.thumbnail.unavailable"
    }

    private var favoriteActionTitle: LocalizedStringKey {
        libraryState.state(for: comic.id).isFavorite
            ? "library.favorite.remove"
            : "library.favorite.add"
    }

    private var readingProgress: LibraryReadingProgress? {
        libraryState.state(for: comic.id).progress
    }

    private var readingActionTitle: LocalizedStringKey {
        readingProgress == nil
            ? "library.read.start"
            : "library.read.continue"
    }

    private var favoriteStatusKey: LocalizedStringKey {
        libraryState.state(for: comic.id).isFavorite
            ? "library.favorite.status.added"
            : "library.favorite.status.none"
    }

    private var favoriteSymbolName: String {
        libraryState.state(for: comic.id).isFavorite
            ? "heart.fill"
            : "heart"
    }
}

private struct LibraryComicCard: View {
    let comic: LibraryCatalogItem
    let thumbnailURL: URL?
    let userState: LibraryComicUserState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            LibraryCoverThumbnail(url: thumbnailURL, cornerRadius: 14)
                .frame(maxWidth: .infinity)
                .aspectRatio(0.71, contentMode: .fit)

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(comic.record.displayName)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)

                Spacer(minLength: 0)

                if userState.isFavorite {
                    Image(systemName: "heart.fill")
                        .foregroundStyle(.red)
                        .accessibilityHidden(true)
                }
            }

            Text(
                String.localizedStringWithFormat(
                    String(localized: "library.grid.summary"),
                    comic.record.chapterCount,
                    comic.record.pageCount
                )
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityValue(Text(favoriteStatusKey))
    }

    private var favoriteStatusKey: LocalizedStringKey {
        userState.isFavorite
            ? "library.favorite.status.added"
            : "library.favorite.status.none"
    }
}

private struct LibraryCoverThumbnail: View {
    let url: URL?
    let cornerRadius: CGFloat

    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                ZStack {
                    LinearGradient(
                        colors: [.orange.opacity(0.82), .red.opacity(0.74)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )

                    Image(systemName: "books.vertical.fill")
                        .font(.system(size: 34, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.92))
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(.white.opacity(0.22), lineWidth: 1)
        }
        .task(id: url) {
            guard let url else {
                image = nil
                return
            }

            image = await LibraryThumbnailLoader.shared.image(at: url)
        }
    }
}

private struct LibraryContentTree: View {
    let nodes: [LibraryCatalogTreeNode]

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 8) {
            ForEach(nodes) { node in
                HStack(spacing: 10) {
                    Image(systemName: symbol(for: node.kind))
                        .foregroundStyle(color(for: node.kind))
                        .frame(width: 20)

                    Text(node.title)
                        .font(node.kind == .collection ? .headline : .body)

                    Spacer(minLength: 8)

                    if node.kind == .chapter {
                        Text(
                            String.localizedStringWithFormat(
                                String(localized: "library.detail.pageCount"),
                                node.pageCount
                            )
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
                .padding(.leading, CGFloat(min(node.depth, 12)) * 18)
            }
        }
    }

    private func symbol(for kind: LibraryCatalogTreeNode.Kind) -> String {
        switch kind {
        case .collection:
            "folder.fill"
        case .chapter:
            "doc.richtext"
        }
    }

    private func color(for kind: LibraryCatalogTreeNode.Kind) -> Color {
        switch kind {
        case .collection:
            .orange
        case .chapter:
            .accentColor
        }
    }
}

private actor LibraryThumbnailLoader {
    static let shared = LibraryThumbnailLoader()

    func image(at url: URL) -> UIImage? {
        UIImage(contentsOfFile: url.path)
    }
}
