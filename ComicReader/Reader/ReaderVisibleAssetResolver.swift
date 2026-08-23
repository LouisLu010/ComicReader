import Foundation

struct ReaderVisibleAssetSnapshot: Equatable, Sendable {
    static let empty = Self(
        presentationIDs: [],
        pageIDs: [],
        assetIdentities: []
    )

    let presentationIDs: [ReaderPresentationID]
    let pageIDs: Set<ImportPageCandidate.ID>
    let assetIdentities: Set<ReaderPageAssetIdentity>
}

enum ReaderVisibleAssetResolver {
    static func resolve(
        presentationIDs: [ReaderPresentationID],
        layout: ReaderLayout,
        assetResolver: any ReaderPageAssetResolving
    ) -> ReaderVisibleAssetSnapshot {
        let canonicalPresentationIDs = layout.canonicalPresentationIDs(
            presentationIDs
        )
        var pageIDs: Set<ImportPageCandidate.ID> = []
        var resolvablePageIDs: [ImportPageCandidate.ID] = []

        for presentationID in canonicalPresentationIDs {
            guard let presentation = layout.presentation(
                for: presentationID
            ) else {
                continue
            }

            for presentedPage in pages(in: presentation) {
                let pageID = presentedPage.location.pageID
                guard pageIDs.insert(pageID).inserted,
                      presentedPage.page.state == .readable else {
                    continue
                }

                resolvablePageIDs.append(pageID)
            }
        }

        var assetIdentities: Set<ReaderPageAssetIdentity> = []
        assetIdentities.reserveCapacity(resolvablePageIDs.count)

        for pageID in resolvablePageIDs {
            guard let asset = try? assetResolver.asset(for: pageID) else {
                continue
            }

            assetIdentities.insert(asset.identity)
        }

        return ReaderVisibleAssetSnapshot(
            presentationIDs: canonicalPresentationIDs,
            pageIDs: pageIDs,
            assetIdentities: assetIdentities
        )
    }

    static func resolveContinuous(
        geometries: [ReaderContinuousPageGeometry],
        viewportHeight: Double,
        layout: ReaderLayout,
        assetResolver: any ReaderPageAssetResolving,
        pointTolerance: Double = 0
    ) -> ReaderVisibleAssetSnapshot {
        guard viewportHeight.isFinite,
              viewportHeight > 0,
              pointTolerance.isFinite,
              pointTolerance >= 0 else {
            return .empty
        }

        let visiblePresentationIDs = geometries.compactMap { geometry in
            isVisible(
                geometry,
                viewportHeight: viewportHeight,
                pointTolerance: pointTolerance
            ) ? geometry.presentationID : nil
        }

        return resolve(
            presentationIDs: visiblePresentationIDs,
            layout: layout,
            assetResolver: assetResolver
        )
    }

    private static func pages(
        in presentation: ReaderPresentation
    ) -> [ReaderPresentedPage] {
        switch presentation.content {
        case let .page(page):
            [page]
        case let .spread(spread):
            spread.pagesInReadingOrder
        case .chapterBoundary:
            []
        }
    }

    private static func isVisible(
        _ geometry: ReaderContinuousPageGeometry,
        viewportHeight: Double,
        pointTolerance: Double
    ) -> Bool {
        guard geometry.minY.isFinite,
              geometry.height.isFinite,
              geometry.height > 0,
              geometry.maxY.isFinite else {
            return false
        }

        let intersectionHeight = min(geometry.maxY, viewportHeight)
            - max(geometry.minY, 0)

        // 先要求真实正交集；容差只能消除 viewport 边缘的亚像素抖动，
        // 不能把完全离屏的 presentation 扩进可见集合。
        guard intersectionHeight.isFinite,
              intersectionHeight > 0 else {
            return false
        }

        let crossesViewportEdge = geometry.minY < 0
            || geometry.maxY > viewportHeight
        return !crossesViewportEdge || intersectionHeight > pointTolerance
    }
}
