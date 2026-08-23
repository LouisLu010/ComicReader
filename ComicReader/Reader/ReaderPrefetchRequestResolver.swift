import CoreGraphics

struct ReaderPrefetchRequest: Equatable, Hashable, Sendable {
    static let empty = Self(
        plan: .empty,
        targets: ReaderPrefetchTargets(
            fullPage: nil,
            spreadPage: nil
        )
    )

    let plan: ReaderPrefetchPlan
    let targets: ReaderPrefetchTargets
}

enum ReaderPrefetchRequestResolver {
    static func resolve(
        snapshot: ReaderVisibleAssetSnapshot,
        layout: ReaderLayout,
        motion: ReaderPrefetchMotion,
        windowCapability: ReaderLayoutCapability,
        memoryState: ReaderPrefetchMemoryState,
        viewportSize: CGSize,
        displayScale: CGFloat
    ) -> ReaderPrefetchRequest {
        let plan = ReaderPrefetchPolicy.plan(
            visiblePresentationIDs: snapshot.presentationIDs,
            in: layout,
            motion: motion,
            windowCapability: windowCapability,
            memoryState: memoryState
        )
        guard plan != .empty else {
            return .empty
        }

        let targets = ReaderPrefetchTargetPolicy.targets(
            viewportSize: viewportSize,
            displayScale: displayScale
        )
        guard targets.fullPage != nil || targets.spreadPage != nil else {
            return .empty
        }

        return ReaderPrefetchRequest(
            plan: plan,
            targets: targets
        )
    }
}
