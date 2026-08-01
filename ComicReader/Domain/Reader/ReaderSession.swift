import Foundation

enum ReadingMode: String, CaseIterable, Codable, Equatable, Sendable {
    case continuous
    case singlePage
    case spread
}

enum ReadingDirection: String, CaseIterable, Codable, Equatable, Sendable {
    case leftToRight
    case rightToLeft
}

struct ReaderPage: Equatable, Identifiable, Sendable {
    let id: ImportPageCandidate.ID
    let originalFileName: String
    let displayPixelSize: ImportPixelSize?
    let state: ImportPageState
    let isCover: Bool

    init(
        id: ImportPageCandidate.ID,
        originalFileName: String = "",
        displayPixelSize: ImportPixelSize? = nil,
        state: ImportPageState = .readable,
        isCover: Bool = false
    ) {
        self.id = id
        self.originalFileName = originalFileName
        self.displayPixelSize = displayPixelSize
        self.state = state
        self.isCover = isCover
    }

    var shouldDisplayAloneInSpread: Bool {
        if isCover || state == .corrupted {
            return true
        }

        guard let displayPixelSize,
              displayPixelSize.width > 0,
              displayPixelSize.height > 0 else {
            return true
        }

        return Double(displayPixelSize.width)
            / Double(displayPixelSize.height) >= 1.2
    }
}

struct ReaderChapter: Equatable, Identifiable, Sendable {
    let id: ImportChapterCandidate.ID
    let displayName: String
    let pages: [ReaderPage]

    init(
        id: ImportChapterCandidate.ID,
        displayName: String,
        pages: [ReaderPage]
    ) {
        self.id = id
        self.displayName = displayName
        self.pages = pages
    }
}

struct ReaderComic: Equatable, Sendable {
    let id: ManagedComicID
    let displayName: String
    let cover: ReaderPage?
    let chapters: [ReaderChapter]

    init(
        id: ManagedComicID,
        displayName: String,
        cover: ReaderPage? = nil,
        chapters: [ReaderChapter]
    ) {
        self.id = id
        self.displayName = displayName
        self.cover = cover
        self.chapters = chapters
    }

    init(
        descriptor: ManagedComicDescriptor,
        displayPixelSizesByPageID: [ImportPageCandidate.ID: ImportPixelSize] = [:]
    ) throws {
        var workItemsByID: [ImportPageCandidate.ID: FrozenImportWorkItem] = [:]

        for workItem in descriptor.workItems {
            guard workItemsByID[workItem.id] == nil else {
                throw ReaderComicError.duplicatePageWorkItem(workItem.id)
            }

            workItemsByID[workItem.id] = workItem
        }

        guard let coverWorkItem = workItemsByID[descriptor.coverPageID] else {
            throw ReaderComicError.missingCoverWorkItem(descriptor.coverPageID)
        }

        let chapterPageIDs = Set(descriptor.chapters.flatMap(\.pageIDs))
        let chapters = try descriptor.chapters.map { chapter in
            ReaderChapter(
                id: chapter.id,
                displayName: chapter.displayName,
                pages: try chapter.pageIDs.map { pageID in
                    guard let workItem = workItemsByID[pageID] else {
                        throw ReaderComicError.missingPageWorkItem(pageID)
                    }

                    return ReaderPage(
                        id: workItem.id,
                        originalFileName: workItem.originalFileName,
                        displayPixelSize: displayPixelSizesByPageID[workItem.id]
                            ?? workItem.displayPixelSize,
                        state: workItem.pageState,
                        isCover: workItem.isCover
                    )
                }
            )
        }
        let cover = chapterPageIDs.contains(descriptor.coverPageID)
            ? nil
            : ReaderPage(
                id: coverWorkItem.id,
                originalFileName: coverWorkItem.originalFileName,
                displayPixelSize: displayPixelSizesByPageID[coverWorkItem.id]
                    ?? coverWorkItem.displayPixelSize,
                state: coverWorkItem.pageState,
                isCover: true
            )

        self.init(
            id: descriptor.targetComicID,
            displayName: descriptor.displayName,
            cover: cover,
            chapters: chapters
        )
    }
}

enum ReaderComicError: Error, Equatable, Sendable {
    case duplicatePageWorkItem(ImportPageCandidate.ID)
    case missingCoverWorkItem(ImportPageCandidate.ID)
    case missingPageWorkItem(ImportPageCandidate.ID)
}

enum ReaderPageLocation: Codable, Equatable, Hashable, Sendable {
    static let coverStorageChapterID = "reader:cover"

    case cover(ImportPageCandidate.ID)
    case chapter(ImportChapterCandidate.ID, ImportPageCandidate.ID)

    var chapterID: ImportChapterCandidate.ID? {
        switch self {
        case .cover:
            nil
        case let .chapter(chapterID, _):
            chapterID
        }
    }

    var pageID: ImportPageCandidate.ID {
        switch self {
        case let .cover(pageID), let .chapter(_, pageID):
            pageID
        }
    }

    var storageChapterID: String {
        switch self {
        case .cover:
            Self.coverStorageChapterID
        case let .chapter(chapterID, _):
            chapterID.rawValue
        }
    }

    init?(storageChapterID: String, pageID: String) {
        guard !pageID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }

        let pageID = ImportPageCandidate.ID(rawValue: pageID)

        if storageChapterID == Self.coverStorageChapterID {
            self = .cover(pageID)
            return
        }

        guard !storageChapterID.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).isEmpty else {
            return nil
        }

        self = .chapter(
            ImportChapterCandidate.ID(rawValue: storageChapterID),
            pageID
        )
    }
}

struct ReadingPosition: Codable, Equatable, Sendable {
    static let minimumZoomScale = 0.1
    static let maximumZoomScale = 16.0

    let location: ReaderPageLocation
    let pageOffset: Double
    let zoomScale: Double

    init(
        location: ReaderPageLocation,
        pageOffset: Double = 0,
        zoomScale: Double = 1
    ) {
        self.location = location
        self.pageOffset = Self.normalizedPageOffset(pageOffset)
        self.zoomScale = Self.normalizedZoomScale(zoomScale)
    }

    init?(
        storageChapterID: String,
        pageID: String,
        pageOffset: Double = 0,
        zoomScale: Double = 1
    ) {
        guard let location = ReaderPageLocation(
            storageChapterID: storageChapterID,
            pageID: pageID
        ) else {
            return nil
        }

        self.init(
            location: location,
            pageOffset: pageOffset,
            zoomScale: zoomScale
        )
    }

    var chapterID: ImportChapterCandidate.ID? {
        location.chapterID
    }

    var pageID: ImportPageCandidate.ID {
        location.pageID
    }

    var storageChapterID: String {
        location.storageChapterID
    }

    private static func normalizedPageOffset(_ value: Double) -> Double {
        guard value.isFinite else {
            return 0
        }

        return min(max(value, 0), 1)
    }

    private static func normalizedZoomScale(_ value: Double) -> Double {
        guard value.isFinite else {
            return 1
        }

        return min(max(value, minimumZoomScale), maximumZoomScale)
    }
}

struct ReaderProgress: Equatable, Sendable {
    let comicID: ManagedComicID
    let position: ReadingPosition
    let mode: ReadingMode
    let direction: ReadingDirection
    let isChapterCompleted: Bool
    /// 仅在最终章节完成后为 true，独立封面不能标记整本漫画已读。
    let hasReachedFinalChapterEnd: Bool
}

struct ReaderLayoutCapability: Equatable, Sendable {
    static let spreadCapable = Self(supportsSpread: true)
    static let singlePageOnly = Self(supportsSpread: false)

    let supportsSpread: Bool

    init(supportsSpread: Bool) {
        self.supportsSpread = supportsSpread
    }
}

struct ReaderPresentedPage: Equatable, Identifiable, Sendable {
    let page: ReaderPage
    let location: ReaderPageLocation

    var id: ReaderPageLocation {
        location
    }
}

struct ReaderSpread: Equatable, Sendable {
    let pagesInReadingOrder: [ReaderPresentedPage]
    let leadingPage: ReaderPresentedPage?
    let trailingPage: ReaderPresentedPage?

    init(
        firstPage: ReaderPresentedPage,
        secondPage: ReaderPresentedPage?,
        direction: ReadingDirection
    ) {
        pagesInReadingOrder = [firstPage] + (secondPage.map { [$0] } ?? [])

        switch direction {
        case .leftToRight:
            leadingPage = firstPage
            trailingPage = secondPage
        case .rightToLeft:
            leadingPage = secondPage
            trailingPage = firstPage
        }
    }
}

struct ReaderChapterBoundary: Equatable, Sendable {
    let completedChapterID: ImportChapterCandidate.ID
    let nextChapterID: ImportChapterCandidate.ID
}

enum ReaderPresentationID: Hashable, Sendable {
    case page(ReaderPageLocation)
    case spread([ReaderPageLocation])
    case chapterBoundary(ImportChapterCandidate.ID)
}

struct ReaderPresentation: Equatable, Identifiable, Sendable {
    enum Content: Equatable, Sendable {
        case page(ReaderPresentedPage)
        case spread(ReaderSpread)
        case chapterBoundary(ReaderChapterBoundary)
    }

    let content: Content

    var id: ReaderPresentationID {
        switch content {
        case let .page(page):
            .page(page.location)
        case let .spread(spread):
            .spread(spread.pagesInReadingOrder.map(\.location))
        case let .chapterBoundary(boundary):
            .chapterBoundary(boundary.completedChapterID)
        }
    }

    var locations: [ReaderPageLocation] {
        switch content {
        case let .page(page):
            [page.location]
        case let .spread(spread):
            spread.pagesInReadingOrder.map(\.location)
        case .chapterBoundary:
            []
        }
    }
}

struct ReaderLayout: Equatable, Sendable {
    let requestedMode: ReadingMode
    let effectiveMode: ReadingMode
    let direction: ReadingDirection
    let presentations: [ReaderPresentation]

    init(
        comic: ReaderComic,
        requestedMode: ReadingMode,
        direction: ReadingDirection,
        capability: ReaderLayoutCapability
    ) {
        self.requestedMode = requestedMode
        effectiveMode = requestedMode == .spread && !capability.supportsSpread
            ? .singlePage
            : requestedMode
        self.direction = direction
        presentations = ReaderLayoutPlanner.make(
            for: comic,
            mode: effectiveMode,
            direction: direction
        )
    }

    func presentationIndex(for location: ReaderPageLocation) -> Int? {
        presentations.firstIndex { $0.locations.contains(location) }
    }
}

enum ReaderSessionError: Error, Equatable, Sendable {
    case emptyComic
    case emptyChapter(ImportChapterCandidate.ID)
    case duplicateChapterID(ImportChapterCandidate.ID)
    case duplicatePageID(ImportPageCandidate.ID)
}

struct ReaderSession: Sendable {
    let comic: ReaderComic
    private(set) var readingMode: ReadingMode
    private(set) var readingDirection: ReadingDirection
    private(set) var layoutCapability: ReaderLayoutCapability
    private(set) var position: ReadingPosition
    private(set) var completedChapterIDs: Set<ImportChapterCandidate.ID>

    init(
        comic: ReaderComic,
        readingMode: ReadingMode = .continuous,
        readingDirection: ReadingDirection = .leftToRight,
        layoutCapability: ReaderLayoutCapability = .spreadCapable,
        restoredPosition: ReadingPosition? = nil
    ) throws {
        try Self.validate(comic)

        self.comic = comic
        self.readingMode = readingMode
        self.readingDirection = readingDirection
        self.layoutCapability = layoutCapability
        self.completedChapterIDs = []
        guard let initialPosition = Self.firstPosition(in: comic) else {
            throw ReaderSessionError.emptyComic
        }
        position = restoredPosition.flatMap { position in
            Self.contains(position.location, in: comic) ? position : nil
        } ?? initialPosition
        recordContinuousCompletionIfNeeded()
    }

    var layout: ReaderLayout {
        ReaderLayout(
            comic: comic,
            requestedMode: readingMode,
            direction: readingDirection,
            capability: layoutCapability
        )
    }

    var currentPresentationIndex: Int? {
        layout.presentationIndex(for: position.location)
    }

    var progress: ReaderProgress {
        ReaderProgress(
            comicID: comic.id,
            position: position,
            mode: readingMode,
            direction: readingDirection,
            isChapterCompleted: isCurrentChapterCompleted,
            hasReachedFinalChapterEnd: hasReachedFinalChapterEnd
        )
    }

    mutating func setReadingMode(_ mode: ReadingMode) {
        readingMode = mode
        recordContinuousCompletionIfNeeded()
    }

    mutating func setReadingDirection(_ direction: ReadingDirection) {
        readingDirection = direction
    }

    mutating func setLayoutCapability(_ capability: ReaderLayoutCapability) {
        layoutCapability = capability
    }

    @discardableResult
    mutating func restore(_ position: ReadingPosition) -> Bool {
        guard Self.contains(position.location, in: comic) else {
            return false
        }

        self.position = position
        recordContinuousCompletionIfNeeded()
        return true
    }

    @discardableResult
    mutating func move(
        to location: ReaderPageLocation,
        pageOffset: Double = 0,
        zoomScale: Double = 1
    ) -> Bool {
        restore(
            ReadingPosition(
                location: location,
                pageOffset: pageOffset,
                zoomScale: zoomScale
            )
        )
    }

    @discardableResult
    mutating func markCurrentPresentationCompleted() -> Bool {
        guard layout.effectiveMode != .continuous,
              let chapterID = currentPresentationCompletionChapterID else {
            return false
        }

        return completedChapterIDs.insert(chapterID).inserted
    }

    private var isCurrentChapterCompleted: Bool {
        guard let chapterID = position.chapterID else {
            return false
        }

        return completedChapterIDs.contains(chapterID)
    }

    private var hasReachedFinalChapterEnd: Bool {
        guard let finalChapterID = comic.chapters.last?.id else {
            return false
        }

        return completedChapterIDs.contains(finalChapterID)
    }

    private var currentPresentationCompletionChapterID: ImportChapterCandidate.ID? {
        guard case let .chapter(chapterID, _) = position.location,
              let chapter = comic.chapters.first(where: { $0.id == chapterID }),
              let lastPage = chapter.pages.last,
              let currentPresentationIndex else {
            return nil
        }

        let finalPageLocation = ReaderPageLocation.chapter(chapterID, lastPage.id)
        return layout.presentations[currentPresentationIndex].locations
            .contains(finalPageLocation)
            ? chapterID
            : nil
    }

    private mutating func recordContinuousCompletionIfNeeded() {
        guard readingMode == .continuous,
              case let .chapter(chapterID, pageID) = position.location,
              let chapter = comic.chapters.first(where: { $0.id == chapterID }),
              chapter.pages.last?.id == pageID,
              position.pageOffset >= 1 else {
            return
        }

        completedChapterIDs.insert(chapterID)
    }

    private static func validate(_ comic: ReaderComic) throws {
        guard comic.cover != nil || !comic.chapters.isEmpty else {
            throw ReaderSessionError.emptyComic
        }

        var chapterIDs = Set<ImportChapterCandidate.ID>()
        var pageIDs = Set<ImportPageCandidate.ID>()

        if let cover = comic.cover,
           !pageIDs.insert(cover.id).inserted {
            throw ReaderSessionError.duplicatePageID(cover.id)
        }

        for chapter in comic.chapters {
            guard chapterIDs.insert(chapter.id).inserted else {
                throw ReaderSessionError.duplicateChapterID(chapter.id)
            }

            guard !chapter.pages.isEmpty else {
                throw ReaderSessionError.emptyChapter(chapter.id)
            }

            for page in chapter.pages where !pageIDs.insert(page.id).inserted {
                throw ReaderSessionError.duplicatePageID(page.id)
            }
        }
    }

    private static func contains(
        _ location: ReaderPageLocation,
        in comic: ReaderComic
    ) -> Bool {
        switch location {
        case let .cover(pageID):
            comic.cover?.id == pageID
        case let .chapter(chapterID, pageID):
            comic.chapters.first(where: { $0.id == chapterID })?.pages.contains {
                $0.id == pageID
            } ?? false
        }
    }

    private static func firstPosition(in comic: ReaderComic) -> ReadingPosition? {
        if let cover = comic.cover {
            return ReadingPosition(location: .cover(cover.id))
        }

        for chapter in comic.chapters {
            if let page = chapter.pages.first {
                return ReadingPosition(
                    location: .chapter(chapter.id, page.id)
                )
            }
        }

        return nil
    }
}

private enum ReaderLayoutPlanner {
    static func make(
        for comic: ReaderComic,
        mode: ReadingMode,
        direction: ReadingDirection
    ) -> [ReaderPresentation] {
        switch mode {
        case .continuous:
            continuousPresentations(for: comic)
        case .singlePage:
            singlePagePresentations(for: comic)
        case .spread:
            spreadPresentations(for: comic, direction: direction)
        }
    }

    private static func continuousPresentations(
        for comic: ReaderComic
    ) -> [ReaderPresentation] {
        var presentations = coverPresentation(for: comic).map { [$0] } ?? []

        for chapter in comic.chapters {
            presentations += presentedPages(for: chapter).map {
                ReaderPresentation(content: .page($0))
            }
        }

        return presentations
    }

    private static func singlePagePresentations(
        for comic: ReaderComic
    ) -> [ReaderPresentation] {
        var presentations = coverPresentation(for: comic).map { [$0] } ?? []

        for (index, chapter) in comic.chapters.enumerated() {
            presentations += presentedPages(for: chapter).map {
                ReaderPresentation(content: .page($0))
            }

            if index < comic.chapters.count - 1 {
                presentations.append(chapterBoundary(
                    completed: chapter,
                    next: comic.chapters[index + 1]
                ))
            }
        }

        return presentations
    }

    private static func spreadPresentations(
        for comic: ReaderComic,
        direction: ReadingDirection
    ) -> [ReaderPresentation] {
        var presentations = coverPresentation(for: comic).map { [$0] } ?? []

        for (index, chapter) in comic.chapters.enumerated() {
            presentations += makeSpreads(
                from: presentedPages(for: chapter),
                direction: direction
            )

            if index < comic.chapters.count - 1 {
                presentations.append(chapterBoundary(
                    completed: chapter,
                    next: comic.chapters[index + 1]
                ))
            }
        }

        return presentations
    }

    private static func coverPresentation(
        for comic: ReaderComic
    ) -> ReaderPresentation? {
        guard let cover = comic.cover else {
            return nil
        }

        return ReaderPresentation(
            content: .page(
                ReaderPresentedPage(
                    page: cover,
                    location: .cover(cover.id)
                )
            )
        )
    }

    private static func presentedPages(
        for chapter: ReaderChapter
    ) -> [ReaderPresentedPage] {
        chapter.pages.map {
            ReaderPresentedPage(
                page: $0,
                location: .chapter(chapter.id, $0.id)
            )
        }
    }

    private static func makeSpreads(
        from pages: [ReaderPresentedPage],
        direction: ReadingDirection
    ) -> [ReaderPresentation] {
        var presentations: [ReaderPresentation] = []
        var pendingPage: ReaderPresentedPage?

        for page in pages {
            if page.page.shouldDisplayAloneInSpread {
                if let currentPendingPage = pendingPage {
                    presentations.append(makeSpread(
                        firstPage: currentPendingPage,
                        secondPage: nil,
                        direction: direction
                    ))
                    pendingPage = nil
                }

                presentations.append(ReaderPresentation(content: .page(page)))
                continue
            }

            if let currentPendingPage = pendingPage {
                presentations.append(makeSpread(
                    firstPage: currentPendingPage,
                    secondPage: page,
                    direction: direction
                ))
                pendingPage = nil
            } else {
                pendingPage = page
            }
        }

        if let pendingPage {
            presentations.append(makeSpread(
                firstPage: pendingPage,
                secondPage: nil,
                direction: direction
            ))
        }

        return presentations
    }

    private static func makeSpread(
        firstPage: ReaderPresentedPage,
        secondPage: ReaderPresentedPage?,
        direction: ReadingDirection
    ) -> ReaderPresentation {
        ReaderPresentation(
            content: .spread(
                ReaderSpread(
                    firstPage: firstPage,
                    secondPage: secondPage,
                    direction: direction
                )
            )
        )
    }

    private static func chapterBoundary(
        completed: ReaderChapter,
        next: ReaderChapter
    ) -> ReaderPresentation {
        ReaderPresentation(
            content: .chapterBoundary(
                ReaderChapterBoundary(
                    completedChapterID: completed.id,
                    nextChapterID: next.id
                )
            )
        )
    }
}

private extension FrozenImportWorkItem {
    var displayPixelSize: ImportPixelSize? {
        guard let pixelSize else {
            return nil
        }

        if orientation == .leftMirrored
            || orientation == .right
            || orientation == .rightMirrored
            || orientation == .left {
            return ImportPixelSize(
                width: pixelSize.height,
                height: pixelSize.width
            )
        }

        return pixelSize
    }
}
