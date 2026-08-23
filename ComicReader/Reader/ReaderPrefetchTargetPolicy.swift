import CoreGraphics

struct ReaderPrefetchTargets: Equatable, Hashable, Sendable {
    let fullPage: ReaderImageTarget?
    let spreadPage: ReaderImageTarget?
}

enum ReaderPrefetchTargetPolicy {
    static func targets(
        viewportSize: CGSize,
        displayScale: CGFloat
    ) -> ReaderPrefetchTargets {
        ReaderPrefetchTargets(
            fullPage: ReaderImageTargetPolicy.target(
                displaySize: viewportSize,
                displayScale: displayScale
            ),
            spreadPage: ReaderImageTargetPolicy.target(
                displaySize: CGSize(
                    width: viewportSize.width / 2,
                    height: viewportSize.height
                ),
                displayScale: displayScale
            )
        )
    }
}
