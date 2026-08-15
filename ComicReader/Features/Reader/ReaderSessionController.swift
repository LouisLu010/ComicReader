import Foundation
import Observation

@MainActor
protocol ReaderProgressRecording: AnyObject {
    @discardableResult
    func recordProgress(
        _ progress: LibraryReadingProgress,
        for comicID: ManagedComicID
    ) async -> Bool
}

@MainActor
protocol ReaderPreferenceWriting: AnyObject {
    @discardableResult
    func setReadingModeOverride(
        _ readingMode: ReadingMode?,
        for comicID: ManagedComicID
    ) async -> Bool

    @discardableResult
    func setReadingDirectionOverride(
        _ readingDirection: ReadingDirection?,
        for comicID: ManagedComicID
    ) async -> Bool
}

enum ReaderProgressPersistenceState: Equatable, Sendable {
    case idle
    case scheduled
    case saving
    case saved
    case failed
}

@MainActor
@Observable
final class ReaderSessionController {
    private(set) var session: ReaderSession
    private(set) var progressPersistenceState: ReaderProgressPersistenceState
#if DEBUG
    private(set) var panDiagnosticsActionCount = 0
#endif

    @ObservationIgnored private let recorder: (any ReaderProgressRecording)?
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private let debounceNanoseconds: UInt64
    @ObservationIgnored private var pendingProgress: LibraryReadingProgress?
    @ObservationIgnored private var scheduledProgressTask: Task<Void, Never>?
    @ObservationIgnored private var progressScheduleGeneration = 0
    @ObservationIgnored private var isPersistingProgress = false
    @ObservationIgnored private var persistenceWaiters: [
        CheckedContinuation<Void, Never>
    ] = []
    @ObservationIgnored private var lastProgressTimestamp: Date?
    @ObservationIgnored private var preservesComicCompletion: Bool

    init(
        session: ReaderSession,
        recorder: (any ReaderProgressRecording)? = nil,
        persistedProgress: LibraryReadingProgress? = nil,
        now: @escaping @Sendable () -> Date = { Date() },
        debounceNanoseconds: UInt64 = 250_000_000
    ) {
        self.session = session
        self.recorder = recorder
        self.now = now
        self.debounceNanoseconds = debounceNanoseconds
        progressPersistenceState = .idle
        pendingProgress = nil
        preservesComicCompletion = persistedProgress?.isCompleted == true
        lastProgressTimestamp = persistedProgress?.updatedAt

        if recorder != nil,
           Self.requiresInitialProgressBackfill(
               session: session,
               persistedProgress: persistedProgress
           ) {
            queueProgressPersistence()
        }
    }

    @discardableResult
    func restore(_ position: ReadingPosition) -> Bool {
        guard session.restore(position) else {
            return false
        }

        queueProgressPersistence()
        return true
    }

    @discardableResult
    func move(
        to location: ReaderPageLocation,
        pageOffset: Double = 0,
        zoomScale: Double = 1
    ) -> Bool {
        let previousChapterID = session.position.chapterID
        guard session.move(
            to: location,
            pageOffset: pageOffset,
            zoomScale: zoomScale
        ) else {
            return false
        }

        queueProgressPersistence(
            immediately: previousChapterID != session.position.chapterID
        )
        return true
    }

    func setReadingPreferences(
        mode: ReadingMode,
        direction: ReadingDirection
    ) {
        let previousCompletedChapterIDs = session.completedChapterIDs
        session.setReadingPreferences(mode: mode, direction: direction)
        if session.completedChapterIDs != previousCompletedChapterIDs {
            queueProgressPersistence()
        }
    }

    func toggleControls() {
        session.toggleControls()
    }

#if DEBUG
    func recordPanDiagnosticsAction() {
        panDiagnosticsActionCount &+= 1
    }
#endif

    @discardableResult
    func setZoomScale(_ zoomScale: Double) -> Bool {
        guard session.setZoomScale(zoomScale) else {
            return false
        }

        queueProgressPersistence()
        return true
    }

    func setLayoutCapability(_ capability: ReaderLayoutCapability) {
        session.setLayoutCapability(capability)
    }

    @discardableResult
    func finishCurrentPresentation() -> Bool {
        guard session.markCurrentPresentationCompleted() else {
            return false
        }

        queueProgressPersistence()
        return true
    }

    /// 使用章节结束页的稳定标识完成章节，避免快速翻页时依赖当前页位置。
    @discardableResult
    func finishChapterBoundary(_ boundary: ReaderChapterBoundary) -> Bool {
        guard session.markChapterBoundaryCompleted(boundary) else {
            return false
        }

        queueProgressPersistence()
        return true
    }

    /// 连续滚动可能在一次几何更新中完整越过多个短末页。
    @discardableResult
    func finishContinuousChapterEnds(
        _ chapterIDs: Set<ImportChapterCandidate.ID>
    ) -> Bool {
        guard session.markContinuousChaptersCompleted(chapterIDs) else {
            return false
        }

        queueProgressPersistence()
        return true
    }

    @discardableResult
    func flushPendingProgress() async -> Bool {
        cancelScheduledProgressPersistence()

        while isPersistingProgress {
            await waitForInFlightPersistence()
        }

        if pendingProgress == nil {
            return progressPersistenceState == .saved
        }

        return await persistPendingProgress()
    }

    private func queueProgressPersistence(immediately: Bool = false) {
        let readerProgress = session.progress
        preservesComicCompletion = preservesComicCompletion
            || readerProgress.hasReachedFinalChapterEnd
        pendingProgress = ReaderProgressBridge.libraryProgress(
            from: readerProgress,
            preservedComicCompletion: preservesComicCompletion,
            updatedAt: nextProgressTimestamp()
        )
        scheduleProgressPersistence(immediately: immediately)
    }

    private func nextProgressTimestamp() -> Date {
        let currentTimestamp = now()
        let nextTimestamp: Date

        if let lastProgressTimestamp,
           currentTimestamp <= lastProgressTimestamp {
            nextTimestamp = lastProgressTimestamp.addingTimeInterval(0.001)
        } else {
            nextTimestamp = currentTimestamp
        }

        lastProgressTimestamp = nextTimestamp
        return nextTimestamp
    }

    /// 新会话可能从旧版 `isCompleted` 或连续阅读的末页恢复出额外完成状态。
    /// 仅比较有效章节，避免源元数据里的未知章节 ID 导致每次打开都重写。
    private static func requiresInitialProgressBackfill(
        session: ReaderSession,
        persistedProgress: LibraryReadingProgress?
    ) -> Bool {
        guard let persistedProgress else {
            // 首次打开也需要保存可恢复的位置。
            return true
        }

        let validChapterIDs = Set(session.comic.chapters.map(\.id))
        let persistedCompletedChapterIDs = ReaderProgressBridge
            .completedChapterIDs(from: persistedProgress)
            .intersection(validChapterIDs)
        let sessionProgress = session.progress

        return sessionProgress.completedChapterIDs != persistedCompletedChapterIDs
            || sessionProgress.position != ReaderProgressBridge.readingPosition(
                from: persistedProgress
            )
            || sessionProgress.hasReachedFinalChapterEnd
                != persistedProgress.isCompleted
    }

    private func scheduleProgressPersistence(immediately: Bool) {
        cancelScheduledProgressPersistence()
        progressScheduleGeneration += 1
        let generation = progressScheduleGeneration
        let debounceNanoseconds = self.debounceNanoseconds
        progressPersistenceState = .scheduled

        scheduledProgressTask = Task { @MainActor [weak self] in
            if !immediately {
                try? await Task.sleep(nanoseconds: debounceNanoseconds)
            }

            guard !Task.isCancelled,
                  let self,
                  generation == self.progressScheduleGeneration else {
                return
            }

            self.scheduledProgressTask = nil
            _ = await self.persistPendingProgress()
        }
    }

    private func cancelScheduledProgressPersistence() {
        progressScheduleGeneration += 1
        scheduledProgressTask?.cancel()
        scheduledProgressTask = nil
    }

    @discardableResult
    private func persistPendingProgress() async -> Bool {
        guard !isPersistingProgress else {
            return false
        }

        guard let recorder else {
            if pendingProgress != nil {
                progressPersistenceState = .failed
            }
            return false
        }

        isPersistingProgress = true
        defer {
            finishPersistingProgress()
        }

        var didPersist = false

        while let progress = pendingProgress {
            pendingProgress = nil
            progressPersistenceState = .saving
            let accepted = await recorder.recordProgress(
                progress,
                for: session.comic.id
            )

            guard accepted else {
                if pendingProgress == nil {
                    pendingProgress = progress
                }
                progressPersistenceState = .failed
                return false
            }

            didPersist = true
        }

        if didPersist {
            progressPersistenceState = .saved
        }
        return didPersist
    }

    private func waitForInFlightPersistence() async {
        await withCheckedContinuation { continuation in
            persistenceWaiters.append(continuation)
        }
    }

    private func finishPersistingProgress() {
        isPersistingProgress = false
        let waiters = persistenceWaiters
        persistenceWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }
}

extension LibraryStateRepository: ReaderPreferenceWriting, ReaderProgressRecording {}
