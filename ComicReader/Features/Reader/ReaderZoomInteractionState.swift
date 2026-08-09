import CoreGraphics

struct ReaderZoomInteractionState: Equatable, Sendable {
    static let minimumScale = ReadingPosition.minimumZoomScale
    static let maximumScale = ReadingPosition.maximumZoomScale
    static let doubleTapScale = 2.0

    private(set) var committedScale: Double
    private(set) var transientMagnification: Double
    private(set) var viewportSize: CGSize
    private(set) var contentSize: CGSize

    private var committedOffset: CGPoint

    init(
        committedScale: Double = 1,
        offset: CGPoint = .zero,
        viewportSize: CGSize = .zero,
        contentSize: CGSize = .zero
    ) {
        self.committedScale = Self.normalizedScale(committedScale)
        transientMagnification = 1
        self.viewportSize = Self.normalizedSize(viewportSize)
        self.contentSize = Self.normalizedSize(contentSize)
        committedOffset = Self.normalizedPoint(offset)
        committedOffset = Self.clampedOffset(
            committedOffset,
            scale: self.committedScale,
            viewportSize: self.viewportSize,
            contentSize: self.contentSize
        )
    }

    var scale: Double {
        Self.effectiveScale(
            committedScale: committedScale,
            magnification: transientMagnification
        )
    }

    var offset: CGPoint {
        Self.clampedOffset(
            committedOffset,
            scale: scale,
            viewportSize: viewportSize,
            contentSize: contentSize
        )
    }

    mutating func setCommittedScale(_ scale: Double) {
        committedScale = Self.normalizedScale(scale)
        transientMagnification = 1
        committedOffset = Self.clampedOffset(
            committedOffset,
            scale: committedScale,
            viewportSize: viewportSize,
            contentSize: contentSize
        )
    }

    @discardableResult
    mutating func adjustCommittedScale(by delta: Double) -> Bool {
        guard delta.isFinite, delta != 0 else {
            return false
        }

        let targetScale = Self.normalizedScale(committedScale + delta)
        guard targetScale != committedScale else {
            return false
        }

        setCommittedScale(targetScale)
        return true
    }

    mutating func updateMagnification(_ magnification: Double) {
        transientMagnification = Self.normalizedMagnification(magnification)
    }

    mutating func commitMagnification() {
        let resolvedScale = scale
        let resolvedOffset = offset

        committedScale = resolvedScale
        transientMagnification = 1
        committedOffset = resolvedOffset
    }

    mutating func cancelMagnification() {
        transientMagnification = 1
        committedOffset = Self.clampedOffset(
            committedOffset,
            scale: committedScale,
            viewportSize: viewportSize,
            contentSize: contentSize
        )
    }

    mutating func setOffset(_ offset: CGPoint) {
        committedOffset = Self.clampedOffset(
            Self.normalizedPoint(offset),
            scale: scale,
            viewportSize: viewportSize,
            contentSize: contentSize
        )
    }

    mutating func translate(by translation: CGSize) {
        guard translation.width.isFinite,
              translation.height.isFinite else {
            return
        }

        setOffset(CGPoint(
            x: Self.addingFinite(offset.x, translation.width),
            y: Self.addingFinite(offset.y, translation.height)
        ))
    }

    mutating func updateGeometry(
        viewportSize: CGSize,
        contentSize: CGSize
    ) {
        let previousOffset = offset
        self.viewportSize = Self.normalizedSize(viewportSize)
        self.contentSize = Self.normalizedSize(contentSize)
        committedOffset = Self.clampedOffset(
            previousOffset,
            scale: scale,
            viewportSize: self.viewportSize,
            contentSize: self.contentSize
        )
    }

    mutating func toggleDoubleTapZoom() {
        let resolvedOffset = offset
        let targetScale = scale > 1 ? 1 : Self.doubleTapScale

        committedScale = targetScale
        transientMagnification = 1
        committedOffset = Self.clampedOffset(
            resolvedOffset,
            scale: targetScale,
            viewportSize: viewportSize,
            contentSize: contentSize
        )
    }

    private static func normalizedScale(_ scale: Double) -> Double {
        guard scale.isFinite else {
            return 1
        }

        return min(max(scale, minimumScale), maximumScale)
    }

    private static func normalizedMagnification(
        _ magnification: Double
    ) -> Double {
        guard magnification.isFinite, magnification > 0 else {
            return 1
        }

        return magnification
    }

    private static func effectiveScale(
        committedScale: Double,
        magnification: Double
    ) -> Double {
        if committedScale >= maximumScale / magnification {
            return maximumScale
        }

        return normalizedScale(committedScale * magnification)
    }

    private static func normalizedSize(_ size: CGSize) -> CGSize {
        guard size.width.isFinite,
              size.height.isFinite,
              size.width > 0,
              size.height > 0 else {
            return .zero
        }

        return size
    }

    private static func normalizedPoint(_ point: CGPoint) -> CGPoint {
        guard point.x.isFinite, point.y.isFinite else {
            return .zero
        }

        return point
    }

    private static func addingFinite(
        _ lhs: CGFloat,
        _ rhs: CGFloat
    ) -> CGFloat {
        if rhs > 0, lhs > CGFloat.greatestFiniteMagnitude - rhs {
            return CGFloat.greatestFiniteMagnitude
        }
        if rhs < 0, lhs < -CGFloat.greatestFiniteMagnitude - rhs {
            return -CGFloat.greatestFiniteMagnitude
        }

        return lhs + rhs
    }

    private static func clampedOffset(
        _ offset: CGPoint,
        scale: Double,
        viewportSize: CGSize,
        contentSize: CGSize
    ) -> CGPoint {
        guard scale > 1,
              viewportSize != .zero,
              contentSize != .zero else {
            return .zero
        }

        let maximumX = maximumOffset(
            contentDimension: contentSize.width,
            viewportDimension: viewportSize.width,
            scale: scale
        )
        let maximumY = maximumOffset(
            contentDimension: contentSize.height,
            viewportDimension: viewportSize.height,
            scale: scale
        )

        return CGPoint(
            x: min(max(offset.x, -maximumX), maximumX),
            y: min(max(offset.y, -maximumY), maximumY)
        )
    }

    private static func maximumOffset(
        contentDimension: CGFloat,
        viewportDimension: CGFloat,
        scale: Double
    ) -> CGFloat {
        let scale = CGFloat(scale)
        let visibleContentDimension = viewportDimension / scale

        guard contentDimension > visibleContentDimension else {
            return 0
        }

        let excessContent = contentDimension - visibleContentDimension
        let halfScale = scale / 2

        if halfScale <= 1 {
            return excessContent * halfScale
        }
        if excessContent >= CGFloat.greatestFiniteMagnitude / halfScale {
            return CGFloat.greatestFiniteMagnitude
        }

        return excessContent * halfScale
    }
}
