import Foundation

struct ReaderContinuousPageGeometry: Equatable, Sendable {
    let index: Int
    let presentationID: ReaderPresentationID
    let location: ReaderPageLocation
    let completionChapterID: ImportChapterCandidate.ID?
    let minY: Double
    let height: Double

    init(
        index: Int,
        presentationID: ReaderPresentationID,
        location: ReaderPageLocation,
        completionChapterID: ImportChapterCandidate.ID? = nil,
        minY: Double,
        height: Double
    ) {
        self.index = index
        self.presentationID = presentationID
        self.location = location
        self.completionChapterID = completionChapterID
        self.minY = minY
        self.height = height
    }

    var maxY: Double {
        minY + height
    }
}

struct ReaderContinuousViewportPosition: Equatable, Sendable {
    let presentationID: ReaderPresentationID
    let location: ReaderPageLocation
    let pageOffset: Double
    let completedChapterIDs: Set<ImportChapterCandidate.ID>
}

enum ReaderContinuousPositionResolver {
    static func resolve(
        geometries: [ReaderContinuousPageGeometry],
        viewportHeight: Double,
        preferredLocation: ReaderPageLocation? = nil,
        finalPresentationIndex: Int? = nil,
        pointTolerance: Double = 1
    ) -> ReaderContinuousViewportPosition? {
        guard viewportHeight.isFinite,
              viewportHeight > 0,
              pointTolerance.isFinite,
              pointTolerance >= 0 else {
            return nil
        }

        let validGeometries = geometries
            .filter { geometry in
                geometry.minY.isFinite
                    && geometry.height.isFinite
                    && geometry.height > 0
                    && geometry.maxY > -pointTolerance
                    && geometry.minY < viewportHeight + pointTolerance
            }
            .sorted { lhs, rhs in
                if lhs.index == rhs.index {
                    return lhs.minY < rhs.minY
                }
                return lhs.index < rhs.index
            }

        guard !validGeometries.isEmpty else {
            return nil
        }

        let preferredGeometry = validGeometries.first { geometry in
            geometry.location == preferredLocation
        }
        let completedFinalGeometry = finalPresentationIndex.flatMap { index in
            validGeometries.first { geometry in
                geometry.index == index
                    && geometry.maxY <= viewportHeight + pointTolerance
            }
        }
        let maximumVisibleHeight = validGeometries.reduce(0) {
            max(
                $0,
                visibleHeight(
                    of: $1,
                    viewportHeight: viewportHeight
                )
            )
        }
        let candidates = validGeometries.filter { geometry in
            abs(
                visibleHeight(of: geometry, viewportHeight: viewportHeight)
                    - maximumVisibleHeight
            ) <= pointTolerance
        }
        let geometry = preferredGeometry
            ?? completedFinalGeometry
            ?? candidates[0]
        let completedChapterIDs = Set(
            validGeometries.compactMap { geometry in
                guard geometry.maxY <= viewportHeight + pointTolerance else {
                    return nil
                }

                return geometry.completionChapterID
            }
        )

        return ReaderContinuousViewportPosition(
            presentationID: geometry.presentationID,
            location: geometry.location,
            pageOffset: pageOffset(
                for: geometry,
                viewportHeight: viewportHeight,
                pointTolerance: pointTolerance
            ),
            completedChapterIDs: completedChapterIDs
        )
    }

    static func restoreAnchorY(for pageOffset: Double) -> Double {
        guard pageOffset.isFinite else {
            return 0
        }

        return min(max(pageOffset, 0), 1)
    }

    static func normalizedRestoreOffset(
        _ pageOffset: Double,
        pageHeight: Double,
        viewportHeight: Double,
        pointTolerance: Double = 1
    ) -> Double {
        guard pageHeight.isFinite,
              viewportHeight.isFinite,
              pointTolerance.isFinite,
              pageHeight > 0,
              viewportHeight > 0,
              pointTolerance >= 0 else {
            return 0
        }

        if pageHeight <= viewportHeight + pointTolerance {
            return 1
        }

        return restoreAnchorY(for: pageOffset)
    }

    private static func pageOffset(
        for geometry: ReaderContinuousPageGeometry,
        viewportHeight: Double,
        pointTolerance: Double
    ) -> Double {
        if geometry.height <= viewportHeight + pointTolerance {
            let isFullyVisible = geometry.minY >= -pointTolerance
                && geometry.maxY <= viewportHeight + pointTolerance
            return isFullyVisible ? 1 : 0
        }

        let scrollableDistance = geometry.height - viewportHeight
        let rawOffset = min(
            max(-geometry.minY / scrollableDistance, 0),
            1
        )
        let normalizedTolerance = min(
            pointTolerance / scrollableDistance,
            1
        )

        if rawOffset <= normalizedTolerance {
            return 0
        }
        if rawOffset >= 1 - normalizedTolerance {
            return 1
        }

        return rawOffset
    }

    private static func visibleHeight(
        of geometry: ReaderContinuousPageGeometry,
        viewportHeight: Double
    ) -> Double {
        max(
            min(geometry.maxY, viewportHeight) - max(geometry.minY, 0),
            0
        )
    }
}
