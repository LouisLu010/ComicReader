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

    func setReadingMode(_ mode: ReadingMode) {
        session.setReadingMode(mode)
        queueProgressPersistence()
    }

    func setReadingDirection(_ direction: ReadingDirection) {
        session.setReadingDirection(direction)
        queueProgressPersistence()
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

extension LibraryStateRepository: ReaderProgressRecording {}
