import CoreGraphics
import Observation

enum ReaderScreenLoadState: Equatable, Sendable {
    case idle
    case loading
    case ready
    case failed(ReaderScreenLoadFailure)
}

enum ReaderScreenLoadFailure: Equatable, Sendable {
    case unavailable
    case invalidContent
}

struct ReaderNavigationRequest: Equatable, Sendable {
    let generation: UInt64
    let presentationID: ReaderPresentationID
}

private enum ReaderScreenControllerError: Error {
    case invalidNavigationIndex
}

@MainActor
@Observable
final class ReaderScreenController {
    let comicID: ManagedComicID
    private(set) var state: ReaderScreenLoadState
    private(set) var content: LoadedReaderContent?
    private(set) var sessionController: ReaderSessionController?
    private(set) var layout: ReaderLayout?
    private(set) var navigationIndex: ReaderNavigationIndex?
    private(set) var visiblePresentationID: ReaderPresentationID?
    private(set) var navigationRequest: ReaderNavigationRequest?
    private(set) var resolvedReaderPreferences: ResolvedReaderPreferences

    @ObservationIgnored let imagePipeline: ReaderImagePipeline
    @ObservationIgnored private let contentLoader: any ReaderContentLoading
    @ObservationIgnored private let progressRecorder: (
        any ReaderProgressRecording
    )?
    @ObservationIgnored private let persistedProgress: LibraryReadingProgress?
    @ObservationIgnored private let sessionBuilder = ReaderSessionBuilder()
    @ObservationIgnored private var layoutCapability: ReaderLayoutCapability
    @ObservationIgnored private var loadGeneration = 0
    @ObservationIgnored private var navigationGeneration: UInt64 = 0

    init(
        comicID: ManagedComicID,
        contentLoader: any ReaderContentLoading,
        progressRecorder: (any ReaderProgressRecording)? = nil,
        persistedProgress: LibraryReadingProgress? = nil,
        resolvedReaderPreferences: ResolvedReaderPreferences = .default,
        imagePipeline: ReaderImagePipeline = ReaderImagePipeline(),
        initialLayoutCapability: ReaderLayoutCapability = .singlePageOnly
    ) {
        self.comicID = comicID
        self.contentLoader = contentLoader
        self.progressRecorder = progressRecorder
        self.persistedProgress = persistedProgress
        self.resolvedReaderPreferences = resolvedReaderPreferences
        self.imagePipeline = imagePipeline
        layoutCapability = initialLayoutCapability
        state = .idle
        layout = nil
        navigationIndex = nil
        visiblePresentationID = nil
        navigationRequest = nil
    }

    @discardableResult
    func load() async -> Bool {
        if state == .ready,
           content != nil,
           sessionController != nil,
           layout != nil,
           navigationIndex != nil {
            return true
        }

        loadGeneration += 1
        let generation = loadGeneration
        state = .loading
        content = nil
        sessionController = nil
        layout = nil
        navigationIndex = nil
        visiblePresentationID = nil
        navigationRequest = nil

        do {
            try Task.checkCancellation()
            let loadedContent = try await contentLoader.load(
                comicID: comicID
            )
            try Task.checkCancellation()
            guard generation == loadGeneration else {
                return false
            }
            guard loadedContent.comic.id == comicID else {
                throw ReaderContentLoaderError.comicIDMismatch(
                    expected: comicID,
                    actual: loadedContent.comic.id
                )
            }

            var session = try await sessionBuilder.makeSession(
                comic: loadedContent.comic,
                persistedProgress: persistedProgress,
                resolvedReaderPreferences: resolvedReaderPreferences,
                layoutCapability: layoutCapability
            )
            try Task.checkCancellation()
            guard generation == loadGeneration else {
                return false
            }

            // 窗口可能在后台构建 Session 时改变尺寸，安装前再应用最新能力。
            session.setLayoutCapability(layoutCapability)
            session.setReadingPreferences(
                mode: resolvedReaderPreferences.readingMode,
                direction: resolvedReaderPreferences.readingDirection
            )
            let sessionController = ReaderSessionController(
                session: session,
                recorder: progressRecorder,
                persistedProgress: persistedProgress
            )
            let layout = sessionController.session.layout
            guard let navigationIndex = ReaderNavigationIndex(
                comic: loadedContent.comic,
                layout: layout
            ) else {
                throw ReaderScreenControllerError.invalidNavigationIndex
            }
            content = loadedContent
            self.sessionController = sessionController
            self.layout = layout
            self.navigationIndex = navigationIndex
            visiblePresentationID = layout.presentationID(
                for: sessionController.session.position.location
            )
            state = .ready
            return true
        } catch is CancellationError {
            guard generation == loadGeneration else {
                return false
            }

            content = nil
            sessionController = nil
            layout = nil
            navigationIndex = nil
            visiblePresentationID = nil
            navigationRequest = nil
            state = .idle
            return false
        } catch {
            guard generation == loadGeneration else {
                return false
            }

            content = nil
            sessionController = nil
            layout = nil
            navigationIndex = nil
            visiblePresentationID = nil
            navigationRequest = nil
            state = .failed(Self.loadFailure(for: error))
            return false
        }
    }

    func setLayoutCapability(_ capability: ReaderLayoutCapability) {
        guard capability != layoutCapability else {
            return
        }

        layoutCapability = capability
        sessionController?.setLayoutCapability(capability)
        refreshNavigationState()
    }

    func setViewportSize(
        _ size: CGSize,
        policy: ReaderViewportPolicy = ReaderViewportPolicy()
    ) {
        setLayoutCapability(policy.capability(for: size))
    }

    /// 保持当前页面位置，将偏好仓库解析出的最终值应用到活动会话。
    @discardableResult
    func applyResolvedReaderPreferences(
        _ preferences: ResolvedReaderPreferences
    ) -> Bool {
        guard resolvedReaderPreferences != preferences else {
            return false
        }

        let layoutPreferencesChanged = (
            resolvedReaderPreferences.readingMode != preferences.readingMode
                || resolvedReaderPreferences.readingDirection
                    != preferences.readingDirection
        )
        resolvedReaderPreferences = preferences

        guard layoutPreferencesChanged, let sessionController else {
            return true
        }

        sessionController.setReadingPreferences(
            mode: preferences.readingMode,
            direction: preferences.readingDirection
        )
        refreshNavigationState()
        return true
    }

    /// 供内部测试与预览使用；产品 UI 应先写入单本覆盖，再应用解析值。
    @discardableResult
    func setReadingMode(_ mode: ReadingMode) -> Bool {
        applyResolvedReaderPreferences(
            ResolvedReaderPreferences(
                readingMode: mode,
                readingDirection: resolvedReaderPreferences.readingDirection,
                tapAreas: resolvedReaderPreferences.tapAreas
            )
        )
    }

    /// 供内部测试与预览使用；产品 UI 应先写入单本覆盖，再应用解析值。
    @discardableResult
    func setReadingDirection(_ direction: ReadingDirection) -> Bool {
        applyResolvedReaderPreferences(
            ResolvedReaderPreferences(
                readingMode: resolvedReaderPreferences.readingMode,
                readingDirection: direction,
                tapAreas: resolvedReaderPreferences.tapAreas
            )
        )
    }

    func setVisiblePresentationID(_ presentationID: ReaderPresentationID?) {
        guard let presentationID else {
            if visiblePresentationID != nil {
                visiblePresentationID = nil
            }
            return
        }

        guard visiblePresentationID != presentationID,
              layout?.presentation(for: presentationID) != nil else {
            return
        }

        visiblePresentationID = presentationID
    }

    var canMoveToPreviousPage: Bool {
        adjacentPresentationID(moving: .backward) != nil
    }

    var canMoveToNextPage: Bool {
        adjacentPresentationID(moving: .forward) != nil
    }

    var canMoveToPreviousChapter: Bool {
        previousChapterLocation() != nil
    }

    var canMoveToNextChapter: Bool {
        nextChapterLocation() != nil
    }

    @discardableResult
    func movePage(_ step: ReaderLogicalPageStep) -> Bool {
        guard let presentationID = adjacentPresentationID(moving: step) else {
            return false
        }

        return navigate(to: presentationID)
    }

    @discardableResult
    func jumpToPage(_ pageNumber: Int) -> Bool {
        guard let location = navigationIndex?.location(
            forPageNumber: pageNumber
        ) else {
            return false
        }

        return navigate(to: location)
    }

    /// 将阅读器跳转到具体逻辑页，并发布可被分页与连续布局共同消费的请求。
    @discardableResult
    func jump(to location: ReaderPageLocation) -> Bool {
        navigate(to: location)
    }

    @discardableResult
    func jumpToChapter(_ chapterID: ImportChapterCandidate.ID) -> Bool {
        guard let location = navigationIndex?.chapterDestination(
            for: chapterID
        )?.firstLocation else {
            return false
        }

        return navigate(to: location)
    }

    @discardableResult
    func moveToPreviousChapter() -> Bool {
        guard let location = previousChapterLocation() else {
            return false
        }

        return navigate(to: location)
    }

    @discardableResult
    func moveToNextChapter() -> Bool {
        guard let location = nextChapterLocation() else {
            return false
        }

        return navigate(to: location)
    }

    @discardableResult
    func flushPendingProgress() async -> Bool {
        guard let sessionController else {
            return false
        }

        return await sessionController.flushPendingProgress()
    }

    private static func loadFailure(
        for error: Error
    ) -> ReaderScreenLoadFailure {
        if error is ReaderScreenControllerError {
            return .invalidContent
        }

        guard let loaderError = error as? ReaderContentLoaderError else {
            return error is ReaderSessionError
                ? .invalidContent
                : .unavailable
        }

        switch loaderError {
        case .descriptorNotFound, .descriptorUnreadable:
            return .unavailable
        case .descriptorIsDirectory,
             .descriptorIsSymbolicLink,
             .invalidDescriptor,
             .unsupportedDescriptorSchema,
             .comicIDMismatch,
             .invalidComic,
             .invalidAssets:
            return .invalidContent
        }
    }

    private func refreshNavigationState() {
        guard let content, let sessionController else {
            layout = nil
            navigationIndex = nil
            visiblePresentationID = nil
            return
        }

        let previousVisiblePresentationID = visiblePresentationID
        let updatedLayout = sessionController.session.layout
        layout = updatedLayout
        navigationIndex = ReaderNavigationIndex(
            comic: content.comic,
            layout: updatedLayout
        )
        visiblePresentationID = previousVisiblePresentationID.flatMap {
            updatedLayout.presentation(for: $0) == nil ? nil : $0
        } ?? updatedLayout.presentationID(
            for: sessionController.session.position.location
        )
    }

    private func adjacentPresentationID(
        moving step: ReaderLogicalPageStep
    ) -> ReaderPresentationID? {
        guard let layout,
              let currentPresentationID = resolvedVisiblePresentationID,
              let currentIndex = layout.presentationIndex(
                  for: currentPresentationID
              ) else {
            return nil
        }

        let targetIndex: Int
        switch step {
        case .backward:
            targetIndex = currentIndex - 1
        case .forward:
            targetIndex = currentIndex + 1
        }

        guard layout.presentations.indices.contains(targetIndex) else {
            return nil
        }

        return layout.presentations[targetIndex].id
    }

    private var resolvedVisiblePresentationID: ReaderPresentationID? {
        if let visiblePresentationID,
           layout?.presentation(for: visiblePresentationID) != nil {
            return visiblePresentationID
        }

        guard let layout, let sessionController else {
            return nil
        }

        return layout.presentationID(
            for: sessionController.session.position.location
        )
    }

    private func previousChapterLocation() -> ReaderPageLocation? {
        guard let navigationIndex,
              let location = navigationAnchorLocation else {
            return nil
        }

        return navigationIndex.previousChapterLocation(from: location)
    }

    private func nextChapterLocation() -> ReaderPageLocation? {
        guard let navigationIndex,
              let location = navigationAnchorLocation else {
            return nil
        }

        return navigationIndex.nextChapterLocation(from: location)
    }

    private var navigationAnchorLocation: ReaderPageLocation? {
        guard let layout,
              let sessionController,
              let presentationID = resolvedVisiblePresentationID,
              let presentation = layout.presentation(
                  for: presentationID
              ) else {
            return nil
        }

        let sessionLocation = sessionController.session.position.location
        switch presentation.content {
        case .chapterBoundary:
            return sessionLocation
        case .page, .spread:
            return presentation.locations.contains(sessionLocation)
                ? sessionLocation
                : presentation.locations.first
        }
    }

    private func navigate(to presentationID: ReaderPresentationID) -> Bool {
        guard let layout,
              let presentation = layout.presentation(
                  for: presentationID
              ) else {
            return false
        }

        switch presentation.content {
        case .chapterBoundary:
            publishNavigationRequest(to: presentationID)
            return true
        case .page, .spread:
            guard let location = presentation.locations.first else {
                return false
            }

            return navigate(to: location)
        }
    }

    private func navigate(to location: ReaderPageLocation) -> Bool {
        guard let layout,
              let sessionController,
              let presentationID = layout.presentationID(for: location),
              sessionController.move(to: location) else {
            return false
        }

        publishNavigationRequest(to: presentationID)
        return true
    }

    private func publishNavigationRequest(
        to presentationID: ReaderPresentationID
    ) {
        navigationGeneration &+= 1
        visiblePresentationID = presentationID
        navigationRequest = ReaderNavigationRequest(
            generation: navigationGeneration,
            presentationID: presentationID
        )
    }
}

private actor ReaderSessionBuilder {
    func makeSession(
        comic: ReaderComic,
        persistedProgress: LibraryReadingProgress?,
        resolvedReaderPreferences: ResolvedReaderPreferences,
        layoutCapability: ReaderLayoutCapability
    ) throws -> ReaderSession {
        try Task.checkCancellation()
        var restoredCompletedChapterIDs = ReaderProgressBridge
            .completedChapterIDs(from: persistedProgress)

        // V1/V2 只存储整本漫画完成状态；恢复时把它保守地映射到最终话。
        if persistedProgress?.isCompleted == true,
           let finalChapterID = comic.chapters.last?.id {
            restoredCompletedChapterIDs.insert(finalChapterID)
        }

        let session = try ReaderSession(
            comic: comic,
            readingMode: resolvedReaderPreferences.readingMode,
            readingDirection: resolvedReaderPreferences.readingDirection,
            layoutCapability: layoutCapability,
            restoredPosition: ReaderProgressBridge.readingPosition(
                from: persistedProgress
            ),
            restoredCompletedChapterIDs: restoredCompletedChapterIDs
        )
        try Task.checkCancellation()
        return session
    }
}
