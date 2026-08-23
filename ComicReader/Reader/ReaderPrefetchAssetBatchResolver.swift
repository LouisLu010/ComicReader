import Foundation

struct ReaderPrefetchAssetBatch: Equatable, Sendable {
    let target: ReaderImageTarget
    let assets: [ReaderPageAsset]
}

enum ReaderPrefetchAssetBatchResolver {
    static func resolve(
        plan: ReaderPrefetchPlan,
        layout: ReaderLayout,
        assetResolver: any ReaderPageAssetResolving,
        targets: ReaderPrefetchTargets
    ) -> [ReaderPrefetchAssetBatch] {
        var batches: [ReaderPrefetchAssetBatch] = []
        var pendingTarget: ReaderImageTarget?
        var pendingAssets: [ReaderPageAsset] = []
        var seenRequests: Set<AssetRequestKey> = []

        for presentationID in plan.presentationIDs {
            guard let presentation = layout.presentation(
                for: presentationID
            ),
            let target = prefetchTarget(
                for: presentation,
                targets: targets
            ) else {
                continue
            }

            var presentationAssets: [ReaderPageAsset] = []
            for pageID in readablePageIDs(in: presentation) {
                guard let asset = try? assetResolver.asset(for: pageID),
                      seenRequests.insert(
                          AssetRequestKey(
                              identity: asset.identity,
                              target: target
                          )
                      ).inserted else {
                    continue
                }

                presentationAssets.append(asset)
            }

            guard !presentationAssets.isEmpty else {
                continue
            }

            if pendingTarget == target {
                pendingAssets.append(contentsOf: presentationAssets)
                continue
            }

            if let pendingTarget, !pendingAssets.isEmpty {
                batches.append(
                    ReaderPrefetchAssetBatch(
                        target: pendingTarget,
                        assets: pendingAssets
                    )
                )
            }
            pendingTarget = target
            pendingAssets = presentationAssets
        }

        if let pendingTarget, !pendingAssets.isEmpty {
            batches.append(
                ReaderPrefetchAssetBatch(
                    target: pendingTarget,
                    assets: pendingAssets
                )
            )
        }

        return batches
    }

    private static func prefetchTarget(
        for presentation: ReaderPresentation,
        targets: ReaderPrefetchTargets
    ) -> ReaderImageTarget? {
        switch presentation.content {
        case .page:
            return targets.fullPage
        case .spread:
            return targets.spreadPage
        case .chapterBoundary:
            return nil
        }
    }

    private static func readablePageIDs(
        in presentation: ReaderPresentation
    ) -> [ImportPageCandidate.ID] {
        switch presentation.content {
        case let .page(page):
            return page.page.state == .readable ? [page.page.id] : []
        case let .spread(spread):
            return spread.pagesInReadingOrder.compactMap { page in
                page.page.state == .readable ? page.page.id : nil
            }
        case .chapterBoundary:
            return []
        }
    }
}

private extension ReaderPrefetchAssetBatchResolver {
    struct AssetRequestKey: Hashable {
        let identity: ReaderPageAssetIdentity
        let target: ReaderImageTarget
    }
}
