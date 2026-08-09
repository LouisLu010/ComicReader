import SwiftUI

@MainActor
struct ReaderContentView: View {
    let layout: ReaderLayout
    let assetResolver: ManagedReaderPageAssetResolver
    let imagePipeline: ReaderImagePipeline
    let sessionController: ReaderSessionController
    let viewportSize: CGSize
    let navigationRequest: ReaderNavigationRequest?
    let onVisiblePresentationChanged: (ReaderPresentationID?) -> Void
    let tapAreas: ReaderTapAreaPreferences
    let controlsAreVisible: Bool
    let isTapInteractionBlocked: Bool
    let onTapAction: (ReaderTapAction) -> Void
    let onContinueChapterBoundary: (ImportChapterCandidate.ID) -> Void
    @Binding var visibleAssetSnapshot: ReaderVisibleAssetSnapshot

    @Environment(\.displayScale) private var displayScale
    @State private var visiblePresentationID: ReaderPresentationID?
    @State private var continuousRestoreRequest: ReaderContinuousRestoreRequest?
    @State private var continuousRestoreGeneration = 0
    @State private var zoomState: ReaderZoomInteractionState
    @GestureState private var gestureMagnification = 1.0
    @GestureState private var gestureTranslation: CGSize = .zero
    @GestureState private var isMagnifying = false

    init(
        layout: ReaderLayout,
        assetResolver: ManagedReaderPageAssetResolver,
        imagePipeline: ReaderImagePipeline,
        sessionController: ReaderSessionController,
        viewportSize: CGSize,
        navigationRequest: ReaderNavigationRequest?,
        onVisiblePresentationChanged: @escaping (
            ReaderPresentationID?
        ) -> Void,
        tapAreas: ReaderTapAreaPreferences,
        controlsAreVisible: Bool,
        isTapInteractionBlocked: Bool,
        onTapAction: @escaping (ReaderTapAction) -> Void,
        onContinueChapterBoundary: @escaping (
            ImportChapterCandidate.ID
        ) -> Void,
        visibleAssetSnapshot: Binding<ReaderVisibleAssetSnapshot>
    ) {
        self.layout = layout
        self.assetResolver = assetResolver
        self.imagePipeline = imagePipeline
        self.sessionController = sessionController
        self.viewportSize = viewportSize
        self.navigationRequest = navigationRequest
        self.onVisiblePresentationChanged = onVisiblePresentationChanged
        self.tapAreas = tapAreas
        self.controlsAreVisible = controlsAreVisible
        self.isTapInteractionBlocked = isTapInteractionBlocked
        self.onTapAction = onTapAction
        self.onContinueChapterBoundary = onContinueChapterBoundary
        _visibleAssetSnapshot = visibleAssetSnapshot

        let restoredPosition = sessionController.session.position
        _zoomState = State(
            initialValue: ReaderZoomInteractionState(
                committedScale: restoredPosition.zoomScale,
                viewportSize: viewportSize,
                contentSize: viewportSize
            )
        )
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
        ZStack(alignment: .topLeading) {
            readerContent
                .contentShape(Rectangle())
                .simultaneousGesture(magnificationGesture)
                .simultaneousGesture(panGesture)
                .simultaneousGesture(tapGesture)

            if controlsAreVisible, activeZoomPresentationID != nil {
                ReaderZoomControls(
                    value: zoomAccessibilityValue,
                    canZoomOut: canZoomOut,
                    canZoomIn: canZoomIn,
                    onZoomOut: { adjustZoom(by: -0.5) },
                    onZoomIn: { adjustZoom(by: 0.5) }
                )
                .padding()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: viewportSize, initial: true) { _, size in
            zoomState.updateGeometry(
                viewportSize: size,
                contentSize: size
            )
        }
        .onChange(of: sessionController.session.position) {
            oldPosition, newPosition in
            synchronizeZoomState(
                from: newPosition,
                resetsOffset: oldPosition.location != newPosition.location
            )
        }
        .onChange(of: displayIdentity, initial: true) { _, _ in
            synchronizeVisiblePresentation()
            scheduleContinuousRestore()
        }
        .onChange(of: navigationRequest) { _, request in
            handleNavigationRequest(request)
        }
        .onChange(
            of: visiblePresentationID,
            initial: true
        ) { _, presentationID in
            onVisiblePresentationChanged(presentationID)
            synchronizePagedVisibleAssets(presentationID)
            handleVisiblePresentation(presentationID)
        }
        .onDisappear {
            visibleAssetSnapshot = .empty
        }
        .task(id: prefetchRequestID) {
            await prefetchAdjacentPages()
        }
    }

    @ViewBuilder
    private var readerContent: some View {
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
                zoomTransform: zoomTransform,
                imageRequestScale: committedImageRequestScale,
                isScrollDisabled: isZoomed,
                onContinueChapterBoundary: onContinueChapterBoundary,
                onViewportPositionChanged: handleContinuousViewportPosition,
                onGeometriesChanged: handleContinuousGeometries,
                onRestoreCompleted: handleContinuousRestoreCompleted
            )
        case .singlePage, .spread:
            ReaderPagedView(
                mode: layout.effectiveMode,
                presentations: layout.pagedDisplayPresentations,
                assetResolver: assetResolver,
                imagePipeline: imagePipeline,
                visiblePresentationID: $visiblePresentationID,
                zoomTransform: zoomTransform,
                imageRequestScale: committedImageRequestScale,
                isScrollDisabled: isZoomed,
                onContinueChapterBoundary: onContinueChapterBoundary
            )
        }
    }

    private var canZoomOut: Bool {
        activeZoomPresentationID != nil
            && zoomState.committedScale
                > ReaderZoomInteractionState.minimumScale
    }

    private var canZoomIn: Bool {
        activeZoomPresentationID != nil
            && zoomState.committedScale
                < ReaderZoomInteractionState.maximumScale
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
            displayScale: displayScale,
            imageScale: CGFloat(committedImageRequestScale)
        )
    }

    private var spreadPagePrefetchTarget: ReaderImageTarget? {
        ReaderImageTargetPolicy.target(
            displaySize: CGSize(
                width: viewportSize.width / 2,
                height: viewportSize.height
            ),
            displayScale: displayScale,
            imageScale: CGFloat(committedImageRequestScale)
        )
    }

    private var renderedZoomState: ReaderZoomInteractionState {
        var state = zoomState
        state.updateMagnification(gestureMagnification)
        state.translate(by: gestureTranslation)
        return state
    }

    private var zoomTransform: ReaderZoomTransform {
        ReaderZoomTransform(
            presentationID: activeZoomPresentationID,
            scale: renderedZoomState.scale,
            offset: renderedZoomState.offset
        )
    }

    private var activeZoomPresentationID: ReaderPresentationID? {
        let presentationID = visiblePresentationID
            ?? layout.presentationID(
                for: sessionController.session.position.location
            )
        guard let presentationID,
              let presentation = layout.presentation(for: presentationID),
              !presentation.locations.isEmpty else {
            return nil
        }

        return presentationID
    }

    private var committedImageRequestScale: Double {
        zoomState.committedScale
    }

    private var isZoomed: Bool {
        activeZoomPresentationID != nil
            && renderedZoomState.scale > 1.000_5
    }

    private var zoomAccessibilityValue: String {
        "\(Int((renderedZoomState.scale * 100).rounded()))%"
    }

    private var prefetchRequestID: ReaderPrefetchRequestID {
        ReaderPrefetchRequestID(
            presentationID: visiblePresentationID,
            fullPageTarget: fullPagePrefetchTarget,
            spreadPageTarget: spreadPagePrefetchTarget
        )
    }

    private func synchronizeVisiblePresentation() {
        if let visiblePresentationID,
           layout.presentation(for: visiblePresentationID) != nil {
            synchronizePagedVisibleAssets(visiblePresentationID)
            return
        }

        visiblePresentationID = layout.presentationID(
            for: sessionController.session.position.location
        ) ?? layout.presentations.first?.id
        synchronizePagedVisibleAssets(visiblePresentationID)
    }

    private func synchronizePagedVisibleAssets(
        _ presentationID: ReaderPresentationID?
    ) {
        guard layout.effectiveMode != .continuous else {
            visibleAssetSnapshot = .empty
            return
        }

        synchronizeZoomGeometry(contentSize: viewportSize)

        visibleAssetSnapshot = ReaderVisibleAssetResolver.resolve(
            presentationIDs: presentationID.map { [$0] } ?? [],
            layout: layout,
            assetResolver: assetResolver
        )
    }

    private func handleContinuousGeometries(
        _ geometries: [ReaderContinuousPageGeometry]
    ) {
        guard layout.effectiveMode == .continuous else {
            return
        }

        visibleAssetSnapshot = ReaderVisibleAssetResolver.resolveContinuous(
            geometries: geometries,
            viewportHeight: Double(viewportSize.height),
            layout: layout,
            assetResolver: assetResolver
        )

        guard let activeZoomPresentationID,
              let geometry = geometries.first(where: {
                  $0.presentationID == activeZoomPresentationID
              }),
              geometry.height.isFinite,
              geometry.height > 0 else {
            return
        }

        synchronizeZoomGeometry(
            contentSize: CGSize(
                width: min(viewportSize.width, 1_400),
                height: CGFloat(geometry.height)
            )
        )
    }

    private func synchronizeZoomGeometry(contentSize: CGSize) {
        guard zoomState.viewportSize != viewportSize
                || zoomState.contentSize != contentSize else {
            return
        }

        zoomState.updateGeometry(
            viewportSize: viewportSize,
            contentSize: contentSize
        )
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

    private func handleNavigationRequest(
        _ request: ReaderNavigationRequest?
    ) {
        guard let request,
              layout.presentation(for: request.presentationID) != nil else {
            return
        }

        visiblePresentationID = request.presentationID
        onVisiblePresentationChanged(request.presentationID)

        if layout.effectiveMode == .continuous {
            scheduleContinuousRestore()
        } else {
            synchronizePagedVisibleAssets(request.presentationID)
        }
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
            synchronizePosition(for: boundary, at: presentationID)
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

    private func synchronizePosition(
        for boundary: ReaderChapterBoundary,
        at presentationID: ReaderPresentationID
    ) {
        guard let boundaryIndex = layout.presentationIndex(
            for: presentationID
        ),
              boundaryIndex > layout.presentations.startIndex,
              let finalLocation = layout.presentations[boundaryIndex - 1]
                  .locations.last,
              finalLocation.chapterID == boundary.completedChapterID,
              sessionController.session.position.location != finalLocation else {
            return
        }

        _ = sessionController.move(to: finalLocation)
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

        let zoomScale = viewportPosition.location == currentPosition.location
            ? currentPosition.zoomScale
            : 1
        _ = sessionController.move(
            to: viewportPosition.location,
            pageOffset: viewportPosition.pageOffset,
            zoomScale: zoomScale
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

    private var magnificationGesture: some Gesture {
        MagnifyGesture()
            .updating($gestureMagnification) { value, state, _ in
                guard activeZoomPresentationID != nil else {
                    return
                }

                state = Double(value.magnification)
            }
            .updating($isMagnifying) { _, state, _ in
                state = true
            }
            .onEnded { value in
                guard activeZoomPresentationID != nil else {
                    return
                }

                zoomState.updateMagnification(
                    Double(value.magnification)
                )
                zoomState.commitMagnification()
                commitZoomScale()
            }
    }

    private var panGesture: some Gesture {
        DragGesture()
            .updating($gestureTranslation) { value, state, _ in
                guard activeZoomPresentationID != nil,
                      zoomState.scale > 1 else {
                    return
                }

                state = value.translation
            }
            .onEnded { value in
                guard activeZoomPresentationID != nil,
                      zoomState.scale > 1 else {
                    return
                }

                zoomState.translate(by: value.translation)
            }
    }

    private var tapGesture: some Gesture {
        SpatialTapGesture(count: 2, coordinateSpace: .local)
            .onEnded { _ in
                guard activeZoomPresentationID != nil else {
                    return
                }

                zoomState.toggleDoubleTapZoom()
                commitZoomScale()
            }
            .exclusively(
                before: SpatialTapGesture(count: 1, coordinateSpace: .local)
            )
            .onEnded { result in
                guard case let .second(tap) = result else {
                    return
                }

                handleSingleTap(at: tap.location)
            }
    }

    private func adjustZoom(by delta: Double) {
        guard activeZoomPresentationID != nil,
              zoomState.adjustCommittedScale(by: delta) else {
            return
        }

        commitZoomScale()
    }

    private func handleSingleTap(at location: CGPoint) {
        guard activeZoomPresentationID != nil,
              location.x.isFinite,
              location.y.isFinite,
              viewportSize.width.isFinite,
              viewportSize.height.isFinite,
              viewportSize.width > 0,
              viewportSize.height > 0,
              (0 ... viewportSize.width).contains(location.x),
              (0 ... viewportSize.height).contains(location.y) else {
            return
        }

        let action = ReaderTapActionPolicy.action(
            horizontalFraction: Double(location.x / viewportSize.width),
            readingMode: layout.effectiveMode,
            readingDirection: layout.direction,
            tapAreas: tapAreas,
            isZoomed: isZoomed || isMagnifying,
            isInteractionBlocked: isTapInteractionBlocked
        )

        guard action != .ignore else {
            return
        }

        onTapAction(action)
    }

    private func synchronizeZoomState(
        from position: ReadingPosition,
        resetsOffset: Bool
    ) {
        if resetsOffset {
            zoomState = ReaderZoomInteractionState(
                committedScale: position.zoomScale,
                viewportSize: viewportSize,
                contentSize: viewportSize
            )
        } else if zoomState.committedScale != position.zoomScale {
            zoomState.setCommittedScale(position.zoomScale)
        }
    }

    private func commitZoomScale() {
        _ = sessionController.setZoomScale(zoomState.committedScale)
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

private struct ReaderZoomControls: View {
    let value: String
    let canZoomOut: Bool
    let canZoomIn: Bool
    let onZoomOut: () -> Void
    let onZoomIn: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onZoomOut) {
                Label("reader.zoom.out", systemImage: "minus.magnifyingglass")
                    .labelStyle(.iconOnly)
            }
            .disabled(!canZoomOut)
            .accessibilityIdentifier("reader.zoom.out")

            Text(verbatim: value)
                .monospacedDigit()
                .frame(minWidth: 48)
                .accessibilityLabel("reader.zoom.value")
                .accessibilityValue(Text(verbatim: value))
                .accessibilityIdentifier("reader.zoom.value")

            Button(action: onZoomIn) {
                Label("reader.zoom.in", systemImage: "plus.magnifyingglass")
                    .labelStyle(.iconOnly)
            }
            .disabled(!canZoomIn)
            .accessibilityIdentifier("reader.zoom.in")
        }
        .buttonStyle(.bordered)
        .padding(8)
        .foregroundStyle(.white)
        .background(.ultraThinMaterial, in: Capsule())
        .accessibilityElement(children: .contain)
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
    let zoomTransform: ReaderZoomTransform
    let imageRequestScale: Double
    let isScrollDisabled: Bool
    let onContinueChapterBoundary: (ImportChapterCandidate.ID) -> Void
    let onViewportPositionChanged: (ReaderContinuousViewportPosition) -> Void
    let onGeometriesChanged: ([ReaderContinuousPageGeometry]) -> Void
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
                        let isActive = zoomTransform.presentationID
                            == presentation.id
                        ReaderZoomPresentationView(
                            scale: isActive ? zoomTransform.scale : 1,
                            offset: isActive ? zoomTransform.offset : .zero
                        ) {
                            ReaderPresentationView(
                                presentation: presentation,
                                style: .continuous,
                                assetResolver: assetResolver,
                                imagePipeline: imagePipeline,
                                imageRequestScale: isActive
                                    ? imageRequestScale
                                    : 1,
                                onContinueChapterBoundary: (
                                    onContinueChapterBoundary
                                )
                            )
                        }
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
                        .zIndex(isActive && zoomTransform.scale > 1 ? 1 : 0)
                    }
                }
                .frame(maxWidth: 1_400)
                .frame(maxWidth: .infinity)
            }
            .coordinateSpace(name: ReaderContinuousCoordinateSpace.name)
            .scrollDisabled(isScrollDisabled)
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
        onGeometriesChanged(Array(geometriesByID.values))
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
    let mode: ReadingMode
    let presentations: [ReaderPresentation]
    let assetResolver: ManagedReaderPageAssetResolver
    let imagePipeline: ReaderImagePipeline
    @Binding var visiblePresentationID: ReaderPresentationID?
    let zoomTransform: ReaderZoomTransform
    let imageRequestScale: Double
    let isScrollDisabled: Bool
    let onContinueChapterBoundary: (ImportChapterCandidate.ID) -> Void

    var body: some View {
        ScrollView(.horizontal) {
            LazyHStack(spacing: 0) {
                ForEach(presentations) { presentation in
                    let isActive = zoomTransform.presentationID
                        == presentation.id
                    ReaderZoomPresentationView(
                        scale: isActive ? zoomTransform.scale : 1,
                        offset: isActive ? zoomTransform.offset : .zero
                    ) {
                        ReaderPresentationView(
                            presentation: presentation,
                            style: .paged,
                            assetResolver: assetResolver,
                            imagePipeline: imagePipeline,
                            imageRequestScale: isActive
                                ? imageRequestScale
                                : 1,
                            onContinueChapterBoundary: (
                                onContinueChapterBoundary
                            )
                        )
                    }
                    .frame(maxHeight: .infinity)
                    .containerRelativeFrame(.horizontal)
                    .id(presentation.id)
                    .zIndex(isActive && zoomTransform.scale > 1 ? 1 : 0)
                }
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.paging)
        .scrollPosition(id: $visiblePresentationID, anchor: .center)
        .scrollDisabled(isScrollDisabled)
        .scrollIndicators(.hidden)
        // 领域层已决定双页的物理左右槽位，避免 Locale 再次反转。
        .environment(\.layoutDirection, .leftToRight)
        .accessibilityIdentifier(
            mode == .spread ? "reader.spread" : "reader.singlePage"
        )
    }

}

private struct ReaderZoomTransform: Equatable {
    let presentationID: ReaderPresentationID?
    let scale: Double
    let offset: CGPoint
}

private struct ReaderZoomPresentationView<Content: View>: View {
    let scale: Double
    let offset: CGPoint
    let content: Content

    init(
        scale: Double,
        offset: CGPoint,
        @ViewBuilder content: () -> Content
    ) {
        self.scale = scale
        self.offset = offset
        self.content = content()
    }

    var body: some View {
        content
            .scaleEffect(CGFloat(scale))
            .offset(x: offset.x, y: offset.y)
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
    let imageRequestScale: Double
    let onContinueChapterBoundary: (ImportChapterCandidate.ID) -> Void

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
                    imagePipeline: imagePipeline,
                    imageRequestScale: imageRequestScale
                )
                ReaderPageSlot(
                    page: spread.trailingPage,
                    accessibilitySortPriority: accessibilityPriority(
                        for: spread.trailingPage,
                        in: spread
                    ),
                    assetResolver: assetResolver,
                    imagePipeline: imagePipeline,
                    imageRequestScale: imageRequestScale
                )
            }
        case let .chapterBoundary(boundary):
            ReaderChapterBoundaryView(
                boundary: boundary,
                onContinue: onContinueChapterBoundary
            )
        }
    }

    @ViewBuilder
    private func pageView(_ page: ReaderPresentedPage) -> some View {
        switch style {
        case .continuous:
            ReaderPageImageView(
                page: page,
                assetResolver: assetResolver,
                imagePipeline: imagePipeline,
                imageRequestScale: imageRequestScale
            )
            .aspectRatio(pageAspectRatio(page.page), contentMode: .fit)
            .frame(maxWidth: .infinity)
        case .paged:
            ReaderPageImageView(
                page: page,
                assetResolver: assetResolver,
                imagePipeline: imagePipeline,
                imageRequestScale: imageRequestScale
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
    let imageRequestScale: Double

    @ViewBuilder
    var body: some View {
        if let page {
            ReaderPageImageView(
                page: page,
                assetResolver: assetResolver,
                imagePipeline: imagePipeline,
                imageRequestScale: imageRequestScale
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
    let onContinue: (ImportChapterCandidate.ID) -> Void

    var body: some View {
        ContentUnavailableView {
            Label(titleKey, systemImage: "checkmark.circle")
        } description: {
            Text(descriptionKey)
        } actions: {
            if let nextChapterID = boundary.nextChapterID {
                Button("reader.chapterBoundary.continue") {
                    onContinue(nextChapterID)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier(
                    "reader.chapterBoundary.continue."
                        + boundary.completedChapterID.rawValue
                )
            }
        }
        .foregroundStyle(.white)
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

    init?(
        generation: Int,
        presentationID: ReaderPresentationID?,
        position: ReadingPosition
    ) {
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
