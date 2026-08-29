import Foundation

enum ReadingMode: String, CaseIterable, Codable, Equatable, Hashable, Sendable {
    case continuous
    case singlePage
    case spread
}

enum ReadingDirection: String, CaseIterable, Codable, Equatable, Hashable, Sendable {
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
        displayPixelSizesByPageID: [ImportPageCandidate.ID: ImportPixelSize] = [:],
        pageOrdersByChapterID: [
            ImportChapterCandidate.ID: [ImportPageCandidate.ID]
        ] = [:]
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
            let naturalPageIDs = chapter.pageIDs
            let orderedPageIDs = pageOrdersByChapterID[chapter.id].map {
                ChapterPageOrder(
                    chapterID: chapter.id,
                    orderedPageIDs: $0
                )
                .applied(to: naturalPageIDs)
            } ?? naturalPageIDs

            return ReaderChapter(
                id: chapter.id,
                displayName: chapter.displayName,
                pages: try orderedPageIDs.map { pageID in
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
    let completedChapterIDs: Set<ImportChapterCandidate.ID>
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
    /// `nil` 表示这是整本漫画的最后一话。
    let nextChapterID: ImportChapterCandidate.ID?
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
    /// 逻辑阅读顺序；RTL 不会改变此数组。
    let presentations: [ReaderPresentation]
    /// 由同一份逻辑 presentation 快照构建，供视图层 O(1) 查询。
    let presentationsByID: [ReaderPresentationID: ReaderPresentation]
    let presentationIndicesByID: [ReaderPresentationID: Int]
    let presentationIDsByLocation: [
        ReaderPageLocation: ReaderPresentationID
    ]
    let presentationIndicesByLocation: [ReaderPageLocation: Int]
    /// 每话末页所在的 presentation；连续模式据此独立判断章节完成。
    let chapterCompletionIDsByPresentationID: [
        ReaderPresentationID: ImportChapterCandidate.ID
    ]
    /// 按逻辑阅读顺序从 1 开始编号；章节结束页不占页码。
    let pageNumberByLocation: [ReaderPageLocation: Int]
    let pageCount: Int
    /// 分页容器的物理展示顺序；仅 RTL 分页模式会反转逻辑顺序。
    let pagedDisplayPresentations: [ReaderPresentation]
    let pagedDisplayPresentationIndicesByID: [ReaderPresentationID: Int]

    init(
        comic: ReaderComic,
        requestedMode: ReadingMode,
        direction: ReadingDirection,
        capability: ReaderLayoutCapability
    ) {
        let resolvedEffectiveMode = requestedMode == .spread
            && !capability.supportsSpread
            ? .singlePage
            : requestedMode
        let logicalPresentations = ReaderLayoutPlanner.make(
            for: comic,
            mode: resolvedEffectiveMode,
            direction: direction
        )

        var presentationsByID: [ReaderPresentationID: ReaderPresentation] = [:]
        var presentationIndicesByID: [ReaderPresentationID: Int] = [:]
        var presentationIDsByLocation: [
            ReaderPageLocation: ReaderPresentationID
        ] = [:]
        var presentationIndicesByLocation: [ReaderPageLocation: Int] = [:]
        var chapterCompletionIDsByLocation: [
            ReaderPageLocation: ImportChapterCandidate.ID
        ] = [:]
        var chapterCompletionIDsByPresentationID: [
            ReaderPresentationID: ImportChapterCandidate.ID
        ] = [:]
        var pageNumberByLocation: [ReaderPageLocation: Int] = [:]
        var nextPageNumber = 1

        for chapter in comic.chapters {
            guard let finalPage = chapter.pages.last else {
                continue
            }

            chapterCompletionIDsByLocation[
                .chapter(chapter.id, finalPage.id)
            ] = chapter.id
        }

        for (index, presentation) in logicalPresentations.enumerated() {
            let presentationID = presentation.id
            presentationsByID[presentationID] = presentation
            presentationIndicesByID[presentationID] = index

            for location in presentation.locations {
                presentationIDsByLocation[location] = presentationID
                presentationIndicesByLocation[location] = index
                if let chapterID = chapterCompletionIDsByLocation[location] {
                    chapterCompletionIDsByPresentationID[presentationID] = (
                        chapterID
                    )
                }
                pageNumberByLocation[location] = nextPageNumber
                nextPageNumber += 1
            }
        }

        let pagedDisplayPresentations = resolvedEffectiveMode == .continuous
            || direction == .leftToRight
            ? logicalPresentations
            : Array(logicalPresentations.reversed())

        var pagedDisplayPresentationIndicesByID: [ReaderPresentationID: Int] = [:]
        for (index, presentation) in pagedDisplayPresentations.enumerated() {
            pagedDisplayPresentationIndicesByID[presentation.id] = index
        }

        self.requestedMode = requestedMode
        effectiveMode = resolvedEffectiveMode
        self.direction = direction
        presentations = logicalPresentations
        self.presentationsByID = presentationsByID
        self.presentationIndicesByID = presentationIndicesByID
        self.presentationIDsByLocation = presentationIDsByLocation
        self.presentationIndicesByLocation = presentationIndicesByLocation
        self.chapterCompletionIDsByPresentationID = (
            chapterCompletionIDsByPresentationID
        )
        self.pageNumberByLocation = pageNumberByLocation
        pageCount = nextPageNumber - 1
        self.pagedDisplayPresentations = pagedDisplayPresentations
        self.pagedDisplayPresentationIndicesByID = (
            pagedDisplayPresentationIndicesByID
        )
    }

    func presentation(
        for presentationID: ReaderPresentationID
    ) -> ReaderPresentation? {
        presentationsByID[presentationID]
    }

    func presentationID(
        for location: ReaderPageLocation
    ) -> ReaderPresentationID? {
        presentationIDsByLocation[location]
    }

    func presentationIndex(
        for presentationID: ReaderPresentationID
    ) -> Int? {
        presentationIndicesByID[presentationID]
    }

    func presentationIndex(for location: ReaderPageLocation) -> Int? {
        presentationIndicesByLocation[location]
    }

    func pageNumber(for location: ReaderPageLocation) -> Int? {
        pageNumberByLocation[location]
    }

    func pagedDisplayPresentationIndex(
        for presentationID: ReaderPresentationID
    ) -> Int? {
        pagedDisplayPresentationIndicesByID[presentationID]
    }

    func canonicalPresentationIDs(
        _ presentationIDs: [ReaderPresentationID]
    ) -> [ReaderPresentationID] {
        Set(
            presentationIDs.compactMap { presentationID in
                presentationIndicesByID[presentationID]
            }
        )
        .sorted()
        .map { presentations[$0].id }
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
    private(set) var layout: ReaderLayout
    private(set) var position: ReadingPosition
    private(set) var controlsAreVisible: Bool
    private(set) var completedChapterIDs: Set<ImportChapterCandidate.ID>
    private let chapterIDs: Set<ImportChapterCandidate.ID>

    init(
        comic: ReaderComic,
        readingMode: ReadingMode = .continuous,
        readingDirection: ReadingDirection = .leftToRight,
        layoutCapability: ReaderLayoutCapability = .spreadCapable,
        restoredPosition: ReadingPosition? = nil,
        restoredCompletedChapterIDs: Set<ImportChapterCandidate.ID> = []
    ) throws {
        try Self.validate(comic)

        self.comic = comic
        self.readingMode = readingMode
        self.readingDirection = readingDirection
        self.layoutCapability = layoutCapability
        layout = ReaderLayout(
            comic: comic,
            requestedMode: readingMode,
            direction: readingDirection,
            capability: layoutCapability
        )
        let validChapterIDs = Set(comic.chapters.map(\.id))
        chapterIDs = validChapterIDs
        completedChapterIDs = restoredCompletedChapterIDs.intersection(
            validChapterIDs
        )
        guard let initialPosition = Self.firstPosition(in: comic) else {
            throw ReaderSessionError.emptyComic
        }
        position = restoredPosition.flatMap { position in
            Self.contains(position.location, in: comic) ? position : nil
        } ?? initialPosition
        controlsAreVisible = true
        recordContinuousCompletionIfNeeded()
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
            hasReachedFinalChapterEnd: hasReachedFinalChapterEnd,
            completedChapterIDs: completedChapterIDs
        )
    }

    mutating func setReadingMode(_ mode: ReadingMode) {
        setReadingPreferences(
            mode: mode,
            direction: readingDirection
        )
    }

    mutating func setReadingDirection(_ direction: ReadingDirection) {
        setReadingPreferences(
            mode: readingMode,
            direction: direction
        )
    }

    mutating func setReadingPreferences(
        mode: ReadingMode,
        direction: ReadingDirection
    ) {
        guard readingMode != mode || readingDirection != direction else {
            return
        }

        readingMode = mode
        readingDirection = direction
        rebuildLayout()
        recordContinuousCompletionIfNeeded()
    }

    mutating func toggleControls() {
        controlsAreVisible.toggle()
    }

    mutating func setLayoutCapability(_ capability: ReaderLayoutCapability) {
        guard layoutCapability != capability else {
            return
        }

        layoutCapability = capability
        rebuildLayout()
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

    /// 仅提交当前页面的缩放状态，保留稳定位置与页面内偏移。
    @discardableResult
    mutating func setZoomScale(_ zoomScale: Double) -> Bool {
        let updatedPosition = ReadingPosition(
            location: position.location,
            pageOffset: position.pageOffset,
            zoomScale: zoomScale
        )
        guard updatedPosition.zoomScale != position.zoomScale else {
            return false
        }

        position = updatedPosition
        return true
    }

    @discardableResult
    mutating func markCurrentPresentationCompleted() -> Bool {
        guard layout.effectiveMode != .continuous,
              let chapterID = currentPresentationCompletionChapterID else {
            return false
        }

        return completedChapterIDs.insert(chapterID).inserted
    }

    /// 完成当前已展示的章节结束页。该命令只信任传入 boundary 的稳定 ID，
    /// 不读取当前页面位置，因此快速跳至结束页时也不会误判章节。
    @discardableResult
    mutating func markChapterBoundaryCompleted(
        _ boundary: ReaderChapterBoundary
    ) -> Bool {
        let currentLayout = layout
        guard currentLayout.effectiveMode != .continuous,
              let presentation = currentLayout.presentation(
                for: .chapterBoundary(boundary.completedChapterID)
              ),
              case let .chapterBoundary(expectedBoundary) = presentation.content,
              expectedBoundary == boundary else {
            return false
        }

        return completedChapterIDs.insert(boundary.completedChapterID).inserted
    }

    /// 连续模式的可见性采样可同时越过多个短末页；只合并当前漫画中的话。
    @discardableResult
    mutating func markContinuousChaptersCompleted(
        _ reachedChapterIDs: Set<ImportChapterCandidate.ID>
    ) -> Bool {
        guard layout.effectiveMode == .continuous else {
            return false
        }

        let newlyCompletedChapterIDs = reachedChapterIDs
            .intersection(chapterIDs)
            .subtracting(completedChapterIDs)
        guard !newlyCompletedChapterIDs.isEmpty else {
            return false
        }

        completedChapterIDs.formUnion(newlyCompletedChapterIDs)
        return true
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

        _ = markContinuousChaptersCompleted([chapterID])
    }

    private mutating func rebuildLayout() {
        layout = ReaderLayout(
            comic: comic,
            requestedMode: readingMode,
            direction: readingDirection,
            capability: layoutCapability
        )
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

            presentations.append(chapterBoundary(
                completed: chapter,
                next: index + 1 < comic.chapters.count
                    ? comic.chapters[index + 1]
                    : nil
            ))
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

            presentations.append(chapterBoundary(
                completed: chapter,
                next: index + 1 < comic.chapters.count
                    ? comic.chapters[index + 1]
                    : nil
            ))
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
        next: ReaderChapter?
    ) -> ReaderPresentation {
        ReaderPresentation(
            content: .chapterBoundary(
                ReaderChapterBoundary(
                    completedChapterID: completed.id,
                    nextChapterID: next?.id
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
