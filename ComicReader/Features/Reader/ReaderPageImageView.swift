import CoreGraphics
import SwiftUI

@MainActor
struct ReaderPageImageView: View {
    let presentedPage: ReaderPresentedPage
    let assetResolver: ManagedReaderPageAssetResolver
    let imagePipeline: ReaderImagePipeline
    let imageRequestScale: Double
    let imagePriority: TaskPriority
    let reloadGeneration: UInt64
    let accessibilityIdentifierPrefix: String

    @Environment(\.displayScale) private var displayScale
    @Environment(\.readerDisplayPreferences) private var displayPreferences
    @Environment(\.readerViewportVisiblePageIDs)
    private var viewportVisiblePageIDs

    @State private var lifecycle = ReaderPageImageLifecycle()
    @State private var activeRequestID: RequestID?
    @State private var renderedImage: CGImage?
    @State private var renderedLocation: ReaderPageLocation?
    @State private var failedRequestID: RequestID?

    init(
        page: ReaderPresentedPage,
        assetResolver: ManagedReaderPageAssetResolver,
        imagePipeline: ReaderImagePipeline,
        imageRequestScale: Double = 1,
        imagePriority: TaskPriority = .userInitiated,
        reloadGeneration: UInt64 = 0,
        accessibilityIdentifierPrefix: String = "reader.page"
    ) {
        presentedPage = page
        self.assetResolver = assetResolver
        self.imagePipeline = imagePipeline
        self.imageRequestScale = imageRequestScale
        self.imagePriority = imagePriority
        self.reloadGeneration = reloadGeneration
        self.accessibilityIdentifierPrefix = accessibilityIdentifierPrefix
    }

    var body: some View {
        GeometryReader { geometry in
            let requestID = RequestID(
                location: presentedPage.location,
                target: ReaderImageTargetPolicy.target(
                    displaySize: geometry.size,
                    displayScale: displayScale,
                    imageScale: CGFloat(imageRequestScale)
                ),
                lifecycleGeneration: lifecycle.generation,
                reloadGeneration: reloadGeneration,
                trimsWhitespace: displayPreferences.trimsWhitespace,
                quarterTurns: displayPreferences.quarterTurns
            )

            content
                .frame(
                    maxWidth: .infinity,
                    maxHeight: .infinity
                )
                .task(id: requestID) {
                    await loadImage(for: requestID)
                }
                .onChange(of: isViewportVisible, initial: true) {
                    _, isVisible in
                    synchronizeVisibility(isVisible)
                }
                .onDisappear {
                    lifecycle.didDisappear()
                    releaseRenderedState()
                }
                .preference(
                    key: ReaderRenderedAspectRatioKey.self,
                    value: renderedImage.map { CGFloat($0.width) / CGFloat($0.height) }
                )
        }
    }

    private var isViewportVisible: Bool {
        viewportVisiblePageIDs.contains(presentedPage.page.id)
    }

    @ViewBuilder
    private var content: some View {
        if presentedPage.page.state == .corrupted {
            unavailablePlaceholder
        } else if let renderedImage,
                  renderedLocation == presentedPage.location {
            Image(
                renderedImage,
                scale: 1,
                orientation: .up,
                label: Text(presentedPage.page.originalFileName)
            )
            .resizable()
            .scaledToFit()
            .accessibilityIdentifier(
                "\(accessibilityIdentifierPrefix).image.\(presentedPage.page.id.rawValue)"
            )
        } else if failedRequestID?.location == presentedPage.location {
            unavailablePlaceholder
        } else {
            ProgressView()
                .accessibilityLabel(Text("reader.page.loading"))
                .accessibilityValue(
                    Text(verbatim: presentedPage.page.originalFileName)
                )
                .accessibilityIdentifier(
                    "\(accessibilityIdentifierPrefix).loading.\(presentedPage.page.id.rawValue)"
                )
        }
    }

    private var unavailablePlaceholder: some View {
        VStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .font(.title)
                .accessibilityHidden(true)

            Text("reader.page.unavailable")
                .font(.headline)

            Text(verbatim: presentedPage.page.originalFileName)
                .font(.caption)
                .multilineTextAlignment(.center)
                .lineLimit(2)
        }
        .foregroundStyle(.secondary)
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.secondary.opacity(0.08))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(
            "\(accessibilityIdentifierPrefix).error.\(presentedPage.page.id.rawValue)"
        )
    }

    private func loadImage(for requestID: RequestID) async {
        guard lifecycle.accepts(
            generation: requestID.lifecycleGeneration
        ) else {
            return
        }

        if activeRequestID?.trimsWhitespace != requestID.trimsWhitespace
            || activeRequestID?.quarterTurns != requestID.quarterTurns {
            renderedImage = nil
            renderedLocation = nil
        }
        activeRequestID = requestID
        failedRequestID = nil

        guard presentedPage.page.state == .readable,
              let target = requestID.target else {
            if presentedPage.page.state == .corrupted {
                markUnavailable(for: requestID)
            }
            return
        }

        if renderedLocation != requestID.location {
            renderedImage = nil
            renderedLocation = nil
        }

        do {
            try Task.checkCancellation()
            let asset = try assetResolver.asset(
                for: presentedPage.page.id
            )
            let previewTarget = Self.previewTarget(for: target)
            let preview = try await imagePipeline.image(
                for: asset,
                target: previewTarget,
                priority: imagePriority
            )
            try Task.checkCancellation()
            guard acceptsResult(for: requestID) else {
                return
            }

            if renderedImage == nil
                || renderedLocation != requestID.location {
                let processed = try await ReaderImageAppearanceProcessor.shared.process(
                    preview.image, trimsWhitespace: requestID.trimsWhitespace,
                    quarterTurns: requestID.quarterTurns
                )
                try Task.checkCancellation()
                guard acceptsResult(for: requestID) else { return }
                renderedImage = processed
                renderedLocation = requestID.location
            }

            guard previewTarget != target else {
                return
            }

            let fullImage = try await imagePipeline.image(
                for: asset,
                target: target,
                priority: imagePriority
            )
            try Task.checkCancellation()
            guard acceptsResult(for: requestID) else {
                return
            }

            let processed = try await ReaderImageAppearanceProcessor.shared.process(
                fullImage.image, trimsWhitespace: requestID.trimsWhitespace,
                quarterTurns: requestID.quarterTurns
            )
            try Task.checkCancellation()
            guard acceptsResult(for: requestID) else { return }
            renderedImage = processed
            renderedLocation = requestID.location
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else {
                return
            }

            markUnavailable(for: requestID)
        }
    }

    private func markUnavailable(for requestID: RequestID) {
        guard acceptsResult(for: requestID) else {
            return
        }

        if renderedImage == nil
            || renderedLocation != requestID.location {
            renderedImage = nil
            renderedLocation = nil
            failedRequestID = requestID
        }
    }

    private func acceptsResult(for requestID: RequestID) -> Bool {
        activeRequestID == requestID
            && lifecycle.accepts(
                generation: requestID.lifecycleGeneration
            )
    }

    private func releaseRenderedState() {
        activeRequestID = nil
        renderedImage = nil
        renderedLocation = nil
        failedRequestID = nil
    }

    private func synchronizeVisibility(_ isVisible: Bool) {
        if isVisible {
            lifecycle.didAppear()
        } else {
            lifecycle.didDisappear()
            releaseRenderedState()
        }
    }

    private static func previewTarget(
        for target: ReaderImageTarget
    ) -> ReaderImageTarget {
        (try? ReaderImageTarget(
            maximumPixelSize: min(512, target.maximumPixelSize)
        )) ?? target
    }

    private struct RequestID: Hashable {
        let location: ReaderPageLocation
        let target: ReaderImageTarget?
        let lifecycleGeneration: UInt64
        let reloadGeneration: UInt64
        let trimsWhitespace: Bool
        let quarterTurns: Int
    }
}

struct ReaderRenderedAspectRatioKey: PreferenceKey {
    static let defaultValue: CGFloat? = nil
    static func reduce(value: inout CGFloat?, nextValue: () -> CGFloat?) {
        value = nextValue() ?? value
    }
}
