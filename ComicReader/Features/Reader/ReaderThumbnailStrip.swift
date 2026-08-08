import SwiftUI

@MainActor
struct ReaderThumbnailStrip: View {
    let layout: ReaderLayout
    let assetResolver: ManagedReaderPageAssetResolver
    let imagePipeline: ReaderImagePipeline
    let selectedPresentationID: ReaderPresentationID?
    let selectedLocation: ReaderPageLocation
    let reloadGeneration: UInt64
    let onSelect: (ReaderPageLocation) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            VStack(alignment: .leading, spacing: 6) {
                Text("reader.navigation.thumbnails")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                ScrollView(.horizontal) {
                    LazyHStack(spacing: 8) {
                        ForEach(
                            ReaderThumbnailPresentationResolver.presentations(
                                for: layout
                            )
                        ) { presentation in
                            thumbnails(for: presentation)
                        }
                    }
                    .padding(.horizontal, 10)
                }
                .scrollIndicators(.hidden)
                // 领域层已排好 RTL 分页的物理顺序，避免 Locale 再次镜像。
                .environment(\.layoutDirection, .leftToRight)
                .frame(height: 102)
                .onChange(of: scrollRequest, initial: true) {
                    _, request in
                    withAnimation(.easeInOut(duration: 0.2)) {
                        proxy.scrollTo(
                            request.selectedLocation,
                            anchor: .center
                        )
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .foregroundStyle(.white)
            .background(
                .ultraThinMaterial,
                in: RoundedRectangle(cornerRadius: 16)
            )
            .padding(.horizontal)
        }
        .accessibilityIdentifier("reader.navigation.thumbnails")
    }

    @ViewBuilder
    private func thumbnails(for presentation: ReaderPresentation) -> some View {
        ForEach(
            ReaderThumbnailPresentationResolver.pages(for: presentation)
        ) { page in
            ReaderThumbnailButton(
                page: page,
                pageNumber: layout.pageNumber(for: page.location),
                totalPageCount: layout.pageCount,
                isSelected: isSelected(page),
                assetResolver: assetResolver,
                imagePipeline: imagePipeline,
                reloadGeneration: reloadGeneration,
                onSelect: onSelect
            )
        }
    }

    private func isSelected(_ page: ReaderPresentedPage) -> Bool {
        layout.presentationID(for: page.location) == selectedPresentationID
            || page.location == selectedLocation
    }

    private var scrollRequest: ReaderThumbnailScrollRequest {
        ReaderThumbnailScrollRequest(
            displayIdentity: ReaderThumbnailPresentationResolver
                .displayIdentity(for: layout),
            selectedLocation: selectedLocation
        )
    }
}

@MainActor
private struct ReaderThumbnailButton: View {
    let page: ReaderPresentedPage
    let pageNumber: Int?
    let totalPageCount: Int
    let isSelected: Bool
    let assetResolver: ManagedReaderPageAssetResolver
    let imagePipeline: ReaderImagePipeline
    let reloadGeneration: UInt64
    let onSelect: (ReaderPageLocation) -> Void

    var body: some View {
        Button {
            onSelect(page.location)
        } label: {
            ReaderPageImageView(
                page: page,
                assetResolver: assetResolver,
                imagePipeline: imagePipeline,
                imagePriority: .utility,
                reloadGeneration: reloadGeneration,
                accessibilityIdentifierPrefix: "reader.thumbnail"
            )
            .environment(
                \.readerViewportVisiblePageIDs,
                [page.page.id]
            )
            .frame(width: 64, height: 90)
            .background(.black.opacity(0.45))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .stroke(
                        isSelected
                            ? Color.accentColor
                            : Color.white.opacity(0.25),
                        lineWidth: isSelected ? 3 : 1
                    )
            }
            .accessibilityHidden(true)
        }
        .buttonStyle(.plain)
        .contentShape(RoundedRectangle(cornerRadius: 6))
        .accessibilityLabel(Text(accessibilityLabel))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier(
            "reader.thumbnail.\(page.page.id.rawValue)"
        )
        .id(page.location)
    }

    private var accessibilityLabel: String {
        guard let pageNumber else {
            return page.page.originalFileName
        }

        return String.localizedStringWithFormat(
            String(localized: "reader.progress.page"),
            pageNumber,
            totalPageCount
        )
    }
}

struct ReaderThumbnailDisplayIdentity: Equatable {
    let effectiveMode: ReadingMode
    let direction: ReadingDirection
    let presentationIDs: [ReaderPresentationID]
}

enum ReaderThumbnailPresentationResolver {
    static func presentations(for layout: ReaderLayout) -> [ReaderPresentation] {
        layout.effectiveMode == .continuous
            || layout.direction == .leftToRight
            ? layout.presentations
            : layout.pagedDisplayPresentations
    }

    static func pages(for presentation: ReaderPresentation) -> [ReaderPresentedPage] {
        switch presentation.content {
        case let .page(page):
            [page]
        case let .spread(spread):
            [spread.leadingPage, spread.trailingPage].compactMap { $0 }
        case .chapterBoundary:
            []
        }
    }

    static func displayIdentity(
        for layout: ReaderLayout
    ) -> ReaderThumbnailDisplayIdentity {
        ReaderThumbnailDisplayIdentity(
            effectiveMode: layout.effectiveMode,
            direction: layout.direction,
            presentationIDs: presentations(for: layout).map(\.id)
        )
    }
}

private struct ReaderThumbnailScrollRequest: Equatable {
    let displayIdentity: ReaderThumbnailDisplayIdentity
    let selectedLocation: ReaderPageLocation
}
