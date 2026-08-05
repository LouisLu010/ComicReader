import Foundation

enum ReaderLogicalPageStep: Equatable, Sendable {
    case backward
    case forward
}

enum ReaderKeyboardArrow: Equatable, Sendable {
    case left
    case right
}

enum ReaderKeyboardNavigationPolicy {
    static func logicalStep(
        for arrow: ReaderKeyboardArrow,
        readingDirection: ReadingDirection
    ) -> ReaderLogicalPageStep {
        switch (arrow, readingDirection) {
        case (.left, .leftToRight), (.right, .rightToLeft):
            .backward
        case (.right, .leftToRight), (.left, .rightToLeft):
            .forward
        }
    }
}

struct ReaderChapterDestination: Equatable, Identifiable, Sendable {
    let chapterID: ImportChapterCandidate.ID
    let displayName: String
    let firstLocation: ReaderPageLocation

    var id: ImportChapterCandidate.ID {
        chapterID
    }
}

struct ReaderNavigationIndex: Equatable, Sendable {
    let pageCount: Int
    let pageNumberByLocation: [ReaderPageLocation: Int]
    let locationByPageNumber: [Int: ReaderPageLocation]
    let chapterDestinations: [ReaderChapterDestination]

    private let chapterDestinationIndexByID: [
        ImportChapterCandidate.ID: Int
    ]

    /// 仅在 comic 与 layout 描述同一份、页码连续且双向唯一时构建索引。
    init?(comic: ReaderComic, layout: ReaderLayout) {
        let comicLocations = Self.logicalLocations(in: comic)
        let layoutLocations = layout.presentations.flatMap(\.locations)

        guard layout.pageCount >= 0,
              comicLocations == layoutLocations,
              comicLocations.count == layout.pageCount,
              layout.pageNumberByLocation.count == layout.pageCount else {
            return nil
        }

        var pageNumberByLocation: [ReaderPageLocation: Int] = [:]
        pageNumberByLocation.reserveCapacity(layout.pageCount)
        var locationByPageNumber: [Int: ReaderPageLocation] = [:]
        locationByPageNumber.reserveCapacity(layout.pageCount)

        for (offset, location) in comicLocations.enumerated() {
            let pageNumber = offset + 1
            guard layout.pageNumberByLocation[location] == pageNumber,
                  pageNumberByLocation[location] == nil,
                  locationByPageNumber[pageNumber] == nil else {
                return nil
            }

            pageNumberByLocation[location] = pageNumber
            locationByPageNumber[pageNumber] = location
        }

        var chapterDestinations: [ReaderChapterDestination] = []
        chapterDestinations.reserveCapacity(comic.chapters.count)
        var chapterDestinationIndexByID: [
            ImportChapterCandidate.ID: Int
        ] = [:]
        chapterDestinationIndexByID.reserveCapacity(comic.chapters.count)

        for chapter in comic.chapters {
            guard chapterDestinationIndexByID[chapter.id] == nil else {
                return nil
            }

            guard let firstPage = chapter.pages.first else {
                continue
            }

            let firstLocation = ReaderPageLocation.chapter(
                chapter.id,
                firstPage.id
            )
            guard pageNumberByLocation[firstLocation] != nil else {
                return nil
            }

            chapterDestinationIndexByID[chapter.id] = (
                chapterDestinations.count
            )
            chapterDestinations.append(
                ReaderChapterDestination(
                    chapterID: chapter.id,
                    displayName: chapter.displayName,
                    firstLocation: firstLocation
                )
            )
        }

        pageCount = layout.pageCount
        self.pageNumberByLocation = pageNumberByLocation
        self.locationByPageNumber = locationByPageNumber
        self.chapterDestinations = chapterDestinations
        self.chapterDestinationIndexByID = chapterDestinationIndexByID
    }

    func pageNumber(for location: ReaderPageLocation) -> Int? {
        pageNumberByLocation[location]
    }

    func location(forPageNumber pageNumber: Int) -> ReaderPageLocation? {
        guard pageNumber >= 1, pageNumber <= pageCount else {
            return nil
        }

        return locationByPageNumber[pageNumber]
    }

    func location(
        from location: ReaderPageLocation,
        moving step: ReaderLogicalPageStep
    ) -> ReaderPageLocation? {
        guard let pageNumber = pageNumberByLocation[location] else {
            return nil
        }

        switch step {
        case .backward:
            guard pageNumber > 1 else {
                return nil
            }

            return locationByPageNumber[pageNumber - 1]
        case .forward:
            guard pageNumber < pageCount else {
                return nil
            }

            return locationByPageNumber[pageNumber + 1]
        }
    }

    func previousLocation(
        from location: ReaderPageLocation
    ) -> ReaderPageLocation? {
        self.location(from: location, moving: .backward)
    }

    func nextLocation(
        from location: ReaderPageLocation
    ) -> ReaderPageLocation? {
        self.location(from: location, moving: .forward)
    }

    func chapterDestination(
        for chapterID: ImportChapterCandidate.ID
    ) -> ReaderChapterDestination? {
        guard let index = chapterDestinationIndexByID[chapterID] else {
            return nil
        }

        return chapterDestinations[index]
    }

    func previousChapterLocation(
        from location: ReaderPageLocation
    ) -> ReaderPageLocation? {
        guard case let .chapter(chapterID, _) = location,
              pageNumberByLocation[location] != nil,
              let index = chapterDestinationIndexByID[chapterID],
              index > chapterDestinations.startIndex else {
            return nil
        }

        return chapterDestinations[index - 1].firstLocation
    }

    func nextChapterLocation(
        from location: ReaderPageLocation
    ) -> ReaderPageLocation? {
        switch location {
        case .cover:
            guard pageNumberByLocation[location] != nil else {
                return nil
            }

            return chapterDestinations.first?.firstLocation
        case let .chapter(chapterID, _):
            guard pageNumberByLocation[location] != nil,
                  let index = chapterDestinationIndexByID[chapterID] else {
                return nil
            }

            let nextIndex = index + 1
            guard nextIndex < chapterDestinations.endIndex else {
                return nil
            }

            return chapterDestinations[nextIndex].firstLocation
        }
    }

    private static func logicalLocations(
        in comic: ReaderComic
    ) -> [ReaderPageLocation] {
        var locations: [ReaderPageLocation] = []
        let chapterPageCount = comic.chapters.reduce(into: 0) {
            $0 += $1.pages.count
        }
        locations.reserveCapacity(
            chapterPageCount + (comic.cover == nil ? 0 : 1)
        )

        if let cover = comic.cover {
            locations.append(.cover(cover.id))
        }

        for chapter in comic.chapters {
            locations += chapter.pages.map {
                .chapter(chapter.id, $0.id)
            }
        }

        return locations
    }
}
