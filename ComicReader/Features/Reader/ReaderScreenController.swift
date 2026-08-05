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

@MainActor
@Observable
final class ReaderScreenController {
    let comicID: ManagedComicID
    private(set) var state: ReaderScreenLoadState
    private(set) var content: LoadedReaderContent?
    private(set) var sessionController: ReaderSessionController?
    private(set) var layout: ReaderLayout?

    @ObservationIgnored let imagePipeline: ReaderImagePipeline
    @ObservationIgnored private let contentLoader: any ReaderContentLoading
    @ObservationIgnored private let progressRecorder: (
        any ReaderProgressRecording
    )?
    @ObservationIgnored private let persistedProgress: LibraryReadingProgress?
    @ObservationIgnored private let sessionBuilder = ReaderSessionBuilder()
    @ObservationIgnored private var layoutCapability: ReaderLayoutCapability
    @ObservationIgnored private var loadGeneration = 0

    init(
        comicID: ManagedComicID,
        contentLoader: any ReaderContentLoading,
        progressRecorder: (any ReaderProgressRecording)? = nil,
        persistedProgress: LibraryReadingProgress? = nil,
        imagePipeline: ReaderImagePipeline = ReaderImagePipeline(),
        initialLayoutCapability: ReaderLayoutCapability = .singlePageOnly
    ) {
        self.comicID = comicID
        self.contentLoader = contentLoader
        self.progressRecorder = progressRecorder
        self.persistedProgress = persistedProgress
        self.imagePipeline = imagePipeline
        layoutCapability = initialLayoutCapability
        state = .idle
        layout = nil
    }

    @discardableResult
    func load() async -> Bool {
        if state == .ready,
           content != nil,
           sessionController != nil,
           layout != nil {
            return true
        }

        loadGeneration += 1
        let generation = loadGeneration
        state = .loading
        content = nil
        sessionController = nil
        layout = nil

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
                layoutCapability: layoutCapability
            )
            try Task.checkCancellation()
            guard generation == loadGeneration else {
                return false
            }

            // 窗口可能在后台构建 Session 时改变尺寸，安装前再应用最新能力。
            session.setLayoutCapability(layoutCapability)
            let sessionController = ReaderSessionController(
                session: session,
                recorder: progressRecorder,
                persistedProgress: persistedProgress
            )
            content = loadedContent
            self.sessionController = sessionController
            layout = sessionController.session.layout
            state = .ready
            return true
        } catch is CancellationError {
            guard generation == loadGeneration else {
                return false
            }

            content = nil
            sessionController = nil
            layout = nil
            state = .idle
            return false
        } catch {
            guard generation == loadGeneration else {
                return false
            }

            content = nil
            sessionController = nil
            layout = nil
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
        layout = sessionController?.session.layout
    }

    func setViewportSize(
        _ size: CGSize,
        policy: ReaderViewportPolicy = ReaderViewportPolicy()
    ) {
        setLayoutCapability(policy.capability(for: size))
    }

    /// 保持当前页面位置，仅更新用户选择的阅读布局偏好。
    /// `ReaderSessionController` 会合并并节流对应的进度持久化。
    @discardableResult
    func setReadingMode(_ mode: ReadingMode) -> Bool {
        guard let sessionController,
              sessionController.session.readingMode != mode else {
            return false
        }

        sessionController.setReadingMode(mode)
        layout = sessionController.session.layout
        return true
    }

    /// 保持当前页面位置，仅更新用户选择的阅读方向。
    /// `ReaderSessionController` 会合并并节流对应的进度持久化。
    @discardableResult
    func setReadingDirection(_ direction: ReadingDirection) -> Bool {
        guard let sessionController,
              sessionController.session.readingDirection != direction else {
            return false
        }

        sessionController.setReadingDirection(direction)
        layout = sessionController.session.layout
        return true
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
}

private actor ReaderSessionBuilder {
    func makeSession(
        comic: ReaderComic,
        persistedProgress: LibraryReadingProgress?,
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
            readingMode: persistedProgress?.readingMode ?? .continuous,
            readingDirection: persistedProgress?.readingDirection
                ?? .leftToRight,
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
