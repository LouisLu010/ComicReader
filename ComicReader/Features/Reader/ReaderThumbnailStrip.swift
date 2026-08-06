import SwiftUI

@MainActor
struct ReaderThumbnailStrip: View {
    let layout: ReaderLayout
    let assetResolver: ManagedReaderPageAssetResolver
    let imagePipeline: ReaderImagePipeline
    let selectedPresentationID: ReaderPresentationID?
    let selectedLocation: ReaderPageLocation
    let onSelect: (ReaderPageLocation) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            VStack(alignment: .leading, spacing: 6) {
                Text("reader.navigation.thumbnails")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                ScrollView(.horizontal) {
                    LazyHStack(spacing: 8) {
                        ForEach(thumbnailPresentations) { presentation in
                            thumbnails(for: presentation)
                        }
                    }
                    .padding(.horizontal, 10)
                }
                .scrollIndicators(.hidden)
                .frame(height: 102)
                .onChange(of: selectedLocation, initial: true) {
                    _, location in
                    withAnimation(.easeInOut(duration: 0.2)) {
                        proxy.scrollTo(location, anchor: .center)
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
        switch presentation.content {
        case let .page(page):
            ReaderThumbnailButton(
                page: page,
                pageNumber: layout.pageNumber(for: page.location),
                totalPageCount: layout.pageCount,
                isSelected: isSelected(page),
                assetResolver: assetResolver,
                imagePipeline: imagePipeline,
                onSelect: onSelect
            )
        case let .spread(spread):
            ForEach(spread.pagesInReadingOrder) { page in
                ReaderThumbnailButton(
                    page: page,
                    pageNumber: layout.pageNumber(for: page.location),
                    totalPageCount: layout.pageCount,
                    isSelected: isSelected(page),
                    assetResolver: assetResolver,
                    imagePipeline: imagePipeline,
                    onSelect: onSelect
                )
            }
        case .chapterBoundary:
            EmptyView()
        }
    }

    private func isSelected(_ page: ReaderPresentedPage) -> Bool {
        layout.presentationID(for: page.location) == selectedPresentationID
            || page.location == selectedLocation
    }

    private var thumbnailPresentations: [ReaderPresentation] {
        layout.effectiveMode == .continuous
            || layout.direction == .leftToRight
            ? layout.presentations
            : layout.pagedDisplayPresentations
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
    let onSelect: (ReaderPageLocation) -> Void

    var body: some View {
        Button {
            onSelect(page.location)
        } label: {
            ReaderPageImageView(
                page: page,
                assetResolver: assetResolver,
                imagePipeline: imagePipeline
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
                        isSelected ? Color.tint : .white.opacity(0.25),
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
