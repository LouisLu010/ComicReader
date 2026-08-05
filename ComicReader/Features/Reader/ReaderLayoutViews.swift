import SwiftUI

@MainActor
struct ReaderContentView: View {
    let layout: ReaderLayout
    let assetResolver: ManagedReaderPageAssetResolver
    let imagePipeline: ReaderImagePipeline
    let sessionController: ReaderSessionController
    let viewportSize: CGSize

    @Environment(\.displayScale) private var displayScale
    @State private var visiblePresentationID: ReaderPresentationID?
    @State private var continuousRestoreRequest: ReaderContinuousRestoreRequest?
    @State private var continuousRestoreGeneration = 0

    init(
        layout: ReaderLayout,
        assetResolver: ManagedReaderPageAssetResolver,
        imagePipeline: ReaderImagePipeline,
        sessionController: ReaderSessionController,
        viewportSize: CGSize
    ) {
        self.layout = layout
        self.assetResolver = assetResolver
        self.imagePipeline = imagePipeline
        self.sessionController = sessionController
        self.viewportSize = viewportSize

        let restoredPosition = sessionController.session.position
        let initialPresentationID = layout.presentationID(
            for: restoredPosition.location
        ) ?? layout.presentations.first?.id
        _visiblePresentationID = State(initialValue: initialPresentationID)
        _continuousRestoreRequest = State(
            initialValue: layout.effectiveMode == .continuous
                ? ReaderContinuousRestoreRequest(
                    generation: 0,
                    presentationID: initialPresentationID,
                    position: restoredPosition
                )
                : nil
        )
    }

    var body: some View {
        Group {
            switch layout.effectiveMode {
            case .continuous:
                ReaderContinuousView(
                    presentations: layout.presentations,
                    chapterCompletionIDsByPresentationID: (
                        layout.chapterCompletionIDsByPresentationID
                    ),
                    assetResolver: assetResolver,
                    imagePipeline: imagePipeline,
                    viewportHeight: viewportSize.height,
                    displayScale: displayScale,
                    restoreRequest: continuousRestoreRequest,
                    onViewportPositionChanged: handleContinuousViewportPosition,
                    onRestoreCompleted: handleContinuousRestoreCompleted
                )
            case .singlePage, .spread:
                ReaderPagedView(
                    presentations: layout.pagedDisplayPresentations,
                    assetResolver: assetResolver,
                    imagePipeline: imagePipeline,
                    visiblePresentationID: $visiblePresentationID
                )
            }
        }
        .onChange(of: displayIdentity, initial: true) { _, _ in
            synchronizeVisiblePresentation()
            scheduleContinuousRestore()
        }
        .onChange(of: visiblePresentationID) { _, presentationID in
            handleVisiblePresentation(presentationID)
        }
        .task(id: prefetchRequestID) {
            await prefetchAdjacentPages()
        }
    }

    private var layoutIdentity: ReaderLayoutDisplayIdentity {
        ReaderLayoutDisplayIdentity(
            effectiveMode: layout.effectiveMode,
            direction: layout.direction,
            presentationCount: layout.presentations.count
        )
    }

    private var displayIdentity: ReaderDisplayIdentity {
        ReaderDisplayIdentity(
            layout: layoutIdentity,
            viewportWidth: viewportSize.width,
            viewportHeight: viewportSize.height,
            displayScale: displayScale
        )
    }

    private var fullPagePrefetchTarget: ReaderImageTarget? {
        ReaderImageTargetPolicy.target(
            displaySize: viewportSize,
            displayScale: displayScale
        )
    }

    private var spreadPagePrefetchTarget: ReaderImageTarget? {
        ReaderImageTargetPolicy.target(
            displaySize: CGSize(
                width: viewportSize.width / 2,
                height: viewportSize.height
            ),
            displayScale: displayScale
        )
    }

    private var prefetchRequestID: ReaderPrefetchRequestID {
        ReaderPrefetchRequestID(
            presentationID: visiblePresentationID,
            fullPageTarget: fullPagePrefetchTarget,
            spreadPageTarget: spreadPagePrefetchTarget
        )
    }

    private func synchronizeVisiblePresentation() {
        visiblePresentationID = layout.presentationID(
            for: sessionController.session.position.location
        ) ?? layout.presentations.first?.id
    }

    private func scheduleContinuousRestore() {
        guard layout.effectiveMode == .continuous,
              let presentationID = layout.presentationID(
                for: sessionController.session.position.location
              ) else {
            continuousRestoreRequest = nil
            return
        }

        continuousRestoreGeneration &+= 1
        continuousRestoreRequest = ReaderContinuousRestoreRequest(
            generation: continuousRestoreGeneration,
            presentationID: presentationID,
            position: sessionController.session.position
        )
    }

    private func handleVisiblePresentation(
        _ presentationID: ReaderPresentationID?
    ) {
        guard layout.effectiveMode != .continuous else {
            return
        }

        guard let presentationID,
              let presentation = layout.presentation(
                for: presentationID
              ) else {
            return
        }

        if case let .chapterBoundary(boundary) = presentation.content {
            _ = sessionController.finishChapterBoundary(boundary)
            return
        }

        let currentLocation = sessionController.session.position.location
        guard !presentation.locations.contains(currentLocation),
              let location = presentation.locations.first else {
            return
        }

        _ = sessionController.move(to: location)
    }

    private func handleContinuousViewportPosition(
        _ viewportPosition: ReaderContinuousViewportPosition
    ) {
        _ = sessionController.finishContinuousChapterEnds(
            viewportPosition.completedChapterIDs
        )
        visiblePresentationID = viewportPosition.presentationID
        let currentPosition = sessionController.session.position
        guard viewportPosition.location != currentPosition.location
                || abs(
                    viewportPosition.pageOffset - currentPosition.pageOffset
                ) >= 0.000_5 else {
            return
        }

        _ = sessionController.move(
            to: viewportPosition.location,
            pageOffset: viewportPosition.pageOffset,
            zoomScale: currentPosition.zoomScale
        )
    }

    private func handleContinuousRestoreCompleted(
        _ viewportPosition: ReaderContinuousViewportPosition,
        request: ReaderContinuousRestoreRequest
    ) {
        guard continuousRestoreRequest?.generation == request.generation else {
            return
        }

        continuousRestoreRequest = nil
        handleContinuousViewportPosition(viewportPosition)
    }

    private func prefetchAdjacentPages() async {
        guard let visiblePresentationID,
              let visibleIndex = layout.presentationIndex(
                  for: visiblePresentationID
              ) else {
            return
        }

        var assetsByTarget: [ReaderImageTarget: [ReaderPageAsset]] = [:]
        for index in [visibleIndex + 1, visibleIndex - 1]
            where layout.presentations.indices.contains(index) {
            let presentation = layout.presentations[index]
            guard let target = prefetchTarget(for: presentation) else {
                continue
            }

            for location in presentation.locations {
                if let asset = try? assetResolver.asset(
                    for: location.pageID
                ) {
                    assetsByTarget[target, default: []].append(asset)
                }
            }
        }

        guard !assetsByTarget.isEmpty, !Task.isCancelled else {
            return
        }

        for (target, assets) in assetsByTarget {
            guard !Task.isCancelled else {
                return
            }

            await imagePipeline.prefetch(assets, target: target)
        }
    }

    private func prefetchTarget(
        for presentation: ReaderPresentation
    ) -> ReaderImageTarget? {
        switch presentation.content {
        case .page:
            fullPagePrefetchTarget
        case .spread:
            spreadPagePrefetchTarget
        case .chapterBoundary:
            nil
        }
    }
}

private struct ReaderContinuousView: View {
    let presentations: [ReaderPresentation]
    let chapterCompletionIDsByPresentationID: [
        ReaderPresentationID: ImportChapterCandidate.ID
    ]
    let assetResolver: ManagedReaderPageAssetResolver
    let imagePipeline: ReaderImagePipeline
    let viewportHeight: CGFloat
    let displayScale: CGFloat
    let restoreRequest: ReaderContinuousRestoreRequest?
    let onViewportPositionChanged: (ReaderContinuousViewportPosition) -> Void
    let onRestoreCompleted: (
        ReaderContinuousViewportPosition,
        ReaderContinuousRestoreRequest
    ) -> Void

    var body: some View {
        ScrollViewReader { scrollProxy in
            ScrollView(.vertical) {
                LazyVStack(spacing: 0) {
                    ForEach(presentations.indices, id: \.self) { index in
                        let presentation = presentations[index]
                        ReaderPresentationView(
                            presentation: presentation,
                            style: .continuous,
                            assetResolver: assetResolver,
                            imagePipeline: imagePipeline
                        )
                        .background {
                            ReaderContinuousGeometryReporter(
                                index: index,
                                presentation: presentation,
                                completionChapterID: (
                                    chapterCompletionIDsByPresentationID[
                                        presentation.id
                                    ]
                                )
                            )
                        }
                        .id(presentation.id)
                    }
                }
                .frame(maxWidth: 1_400)
                .frame(maxWidth: .infinity)
            }
            .coordinateSpace(name: ReaderContinuousCoordinateSpace.name)
            .scrollIndicators(.hidden)
            .task(id: restoreRequest) {
                await restorePosition(using: scrollProxy)
            }
            .onPreferenceChange(
                ReaderContinuousGeometryPreferenceKey.self,
                perform: handleGeometryChange
            )
        }
        .accessibilityIdentifier("reader.continuous")
    }

    private var pointTolerance: Double {
        guard displayScale.isFinite, displayScale > 0 else {
            return 1
        }

        return 1 / Double(displayScale)
    }

    private func restorePosition(using proxy: ScrollViewProxy) async {
        guard let restoreRequest else {
            return
        }

        await Task.yield()
        guard !Task.isCancelled else {
            return
        }

        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            proxy.scrollTo(
                restoreRequest.presentationID,
                anchor: UnitPoint(
                    x: 0.5,
                    y: CGFloat(
                        ReaderContinuousPositionResolver.restoreAnchorY(
                            for: restoreRequest.pageOffset
                        )
                    )
                )
            )
        }
    }

    private func handleGeometryChange(
        _ geometriesByID: [
            ReaderPresentationID: ReaderContinuousPageGeometry
        ]
    ) {
        guard let viewportPosition = ReaderContinuousPositionResolver.resolve(
            geometries: Array(geometriesByID.values),
            viewportHeight: Double(viewportHeight),
            preferredLocation: restoreRequest?.location,
            finalPresentationIndex: presentations.indices.last,
            pointTolerance: pointTolerance
        ) else {
            return
        }

        guard let restoreRequest else {
            onViewportPositionChanged(viewportPosition)
            return
        }

        guard viewportPosition.location == restoreRequest.location,
              let geometry = geometriesByID[
                restoreRequest.presentationID
              ] else {
            return
        }

        let expectedOffset = ReaderContinuousPositionResolver
            .normalizedRestoreOffset(
                restoreRequest.pageOffset,
                pageHeight: geometry.height,
                viewportHeight: Double(viewportHeight),
                pointTolerance: pointTolerance
            )
        let scrollableDistance = max(
            geometry.height - Double(viewportHeight),
            1
        )
        let offsetTolerance = max(
            pointTolerance / scrollableDistance,
            0.001
        )
        guard abs(viewportPosition.pageOffset - expectedOffset)
                <= offsetTolerance else {
            return
        }

        onRestoreCompleted(viewportPosition, restoreRequest)
    }
}

private struct ReaderPagedView: View {
    let presentations: [ReaderPresentation]
    let assetResolver: ManagedReaderPageAssetResolver
    let imagePipeline: ReaderImagePipeline
    @Binding var visiblePresentationID: ReaderPresentationID?

    var body: some View {
        ScrollView(.horizontal) {
            LazyHStack(spacing: 0) {
                ForEach(presentations) { presentation in
                    ReaderPresentationView(
                        presentation: presentation,
                        style: .paged,
                        assetResolver: assetResolver,
                        imagePipeline: imagePipeline
                    )
                    .frame(maxHeight: .infinity)
                    .containerRelativeFrame(.horizontal)
                    .id(presentation.id)
                }
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.paging)
        .scrollPosition(id: $visiblePresentationID, anchor: .center)
        .scrollIndicators(.hidden)
        // 领域层已决定双页的物理左右槽位，避免 Locale 再次反转。
        .environment(\.layoutDirection, .leftToRight)
        .accessibilityIdentifier("reader.paged")
    }

}

private struct ReaderPresentationView: View {
    enum Style {
        case continuous
        case paged
    }

    let presentation: ReaderPresentation
    let style: Style
    let assetResolver: ManagedReaderPageAssetResolver
    let imagePipeline: ReaderImagePipeline

    @ViewBuilder
    var body: some View {
        switch presentation.content {
        case let .page(page):
            pageView(page)
        case let .spread(spread):
            HStack(spacing: 0) {
                ReaderPageSlot(
                    page: spread.leadingPage,
                    accessibilitySortPriority: accessibilityPriority(
                        for: spread.leadingPage,
                        in: spread
                    ),
                    assetResolver: assetResolver,
                    imagePipeline: imagePipeline
                )
                ReaderPageSlot(
                    page: spread.trailingPage,
                    accessibilitySortPriority: accessibilityPriority(
                        for: spread.trailingPage,
                        in: spread
                    ),
                    assetResolver: assetResolver,
                    imagePipeline: imagePipeline
                )
            }
        case let .chapterBoundary(boundary):
            ReaderChapterBoundaryView(boundary: boundary)
        }
    }

    @ViewBuilder
    private func pageView(_ page: ReaderPresentedPage) -> some View {
        switch style {
        case .continuous:
            ReaderPageImageView(
                page: page,
                assetResolver: assetResolver,
                imagePipeline: imagePipeline
            )
            .aspectRatio(pageAspectRatio(page.page), contentMode: .fit)
            .frame(maxWidth: .infinity)
        case .paged:
            ReaderPageImageView(
                page: page,
                assetResolver: assetResolver,
                imagePipeline: imagePipeline
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func pageAspectRatio(_ page: ReaderPage) -> CGFloat {
        guard let pixelSize = page.displayPixelSize,
              pixelSize.width > 0,
              pixelSize.height > 0 else {
            return 0.7
        }

        return CGFloat(pixelSize.width) / CGFloat(pixelSize.height)
    }

    private func accessibilityPriority(
        for page: ReaderPresentedPage?,
        in spread: ReaderSpread
    ) -> Double {
        guard let page,
              let logicalIndex = spread.pagesInReadingOrder.firstIndex(
                where: { $0.location == page.location }
              ) else {
            return 0
        }

        return Double(spread.pagesInReadingOrder.count - logicalIndex)
    }
}

private struct ReaderPageSlot: View {
    let page: ReaderPresentedPage?
    let accessibilitySortPriority: Double
    let assetResolver: ManagedReaderPageAssetResolver
    let imagePipeline: ReaderImagePipeline

    @ViewBuilder
    var body: some View {
        if let page {
            ReaderPageImageView(
                page: page,
                assetResolver: assetResolver,
                imagePipeline: imagePipeline
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilitySortPriority(accessibilitySortPriority)
        } else {
            Color.clear
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityHidden(true)
        }
    }
}

private struct ReaderChapterBoundaryView: View {
    let boundary: ReaderChapterBoundary

    var body: some View {
        ContentUnavailableView {
            Label(titleKey, systemImage: "checkmark.circle")
        } description: {
            Text(descriptionKey)
        }
        .foregroundStyle(.white)
        .accessibilityIdentifier("reader.chapterBoundary")
    }

    private var titleKey: LocalizedStringKey {
        boundary.nextChapterID == nil
            ? "reader.comic.finished"
            : "reader.chapter.finished"
    }

    private var descriptionKey: LocalizedStringKey {
        boundary.nextChapterID == nil
            ? "reader.comic.end"
            : "reader.chapter.continue"
    }
}

private struct ReaderLayoutDisplayIdentity: Equatable {
    let effectiveMode: ReadingMode
    let direction: ReadingDirection
    let presentationCount: Int
}

private struct ReaderDisplayIdentity: Equatable {
    let layout: ReaderLayoutDisplayIdentity
    let viewportWidth: CGFloat
    let viewportHeight: CGFloat
    let displayScale: CGFloat
}

private struct ReaderContinuousRestoreRequest: Equatable, Hashable {
    let generation: Int
    let presentationID: ReaderPresentationID
    let location: ReaderPageLocation
    let pageOffset: Double

    init(
        generation: Int,
        presentationID: ReaderPresentationID?,
        position: ReadingPosition
    )? {
        guard let presentationID else {
            return nil
        }

        self.generation = generation
        self.presentationID = presentationID
        location = position.location
        pageOffset = position.pageOffset
    }
}

private enum ReaderContinuousCoordinateSpace {
    static let name = "reader.continuous.viewport"
}

private struct ReaderContinuousGeometryPreferenceKey: PreferenceKey {
    static let defaultValue: [
        ReaderPresentationID: ReaderContinuousPageGeometry
    ] = [:]

    static func reduce(
        value: inout [
            ReaderPresentationID: ReaderContinuousPageGeometry
        ],
        nextValue: () -> [
            ReaderPresentationID: ReaderContinuousPageGeometry
        ]
    ) {
        value.merge(nextValue(), uniquingKeysWith: { _, newValue in
            newValue
        })
    }
}

private struct ReaderContinuousGeometryReporter: View {
    let index: Int
    let presentation: ReaderPresentation
    let completionChapterID: ImportChapterCandidate.ID?

    var body: some View {
        GeometryReader { proxy in
            Color.clear.preference(
                key: ReaderContinuousGeometryPreferenceKey.self,
                value: geometry(proxy: proxy).map {
                    [presentation.id: $0]
                } ?? [:]
            )
        }
    }

    private func geometry(
        proxy: GeometryProxy
    ) -> ReaderContinuousPageGeometry? {
        guard let location = presentation.locations.first else {
            return nil
        }

        let frame = proxy.frame(
            in: .named(ReaderContinuousCoordinateSpace.name)
        )
        return ReaderContinuousPageGeometry(
            index: index,
            presentationID: presentation.id,
            location: location,
            completionChapterID: completionChapterID,
            minY: Double(frame.minY),
            height: Double(frame.height)
        )
    }
}

private struct ReaderPrefetchRequestID: Equatable, Hashable {
    let presentationID: ReaderPresentationID?
    let fullPageTarget: ReaderImageTarget?
    let spreadPageTarget: ReaderImageTarget?
}
