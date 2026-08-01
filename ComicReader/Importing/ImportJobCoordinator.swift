import Foundation
import Observation

protocol ImportJobManaging: Sendable {
    func enqueue(
        _ draft: ImportPreviewDraft,
        sourceBookmark: Data,
        targetComicID: ManagedComicID
    ) async throws -> ImportJobSnapshot
    func run(_ jobID: ImportJobID) async throws -> ImportJobSnapshot
    func snapshot(for jobID: ImportJobID) async throws -> ImportJobSnapshot
    func cancel(_ jobID: ImportJobID) async throws -> ImportJobSnapshot
    func resume(_ jobID: ImportJobID) async throws -> ImportJobSnapshot
    func storedJobSnapshots() async throws -> [ImportJobSnapshot]
    func restorePendingJobs() async throws -> [ImportJobSnapshot]
}

struct RecoverableImportJobManager: ImportJobManaging {
    private let engine: RecoverableImportEngine

    init(engine: RecoverableImportEngine) {
        self.engine = engine
    }

    func enqueue(
        _ draft: ImportPreviewDraft,
        sourceBookmark: Data,
        targetComicID: ManagedComicID
    ) async throws -> ImportJobSnapshot {
        try await engine.enqueue(
            draft,
            sourceBookmark: sourceBookmark,
            targetComicID: targetComicID
        )
    }

    func cancel(_ jobID: ImportJobID) async throws -> ImportJobSnapshot {
        try await engine.cancel(jobID)
    }

    func run(_ jobID: ImportJobID) async throws -> ImportJobSnapshot {
        try await engine.run(jobID)
    }

    func snapshot(for jobID: ImportJobID) async throws -> ImportJobSnapshot {
        try await engine.snapshot(for: jobID)
    }

    func resume(_ jobID: ImportJobID) async throws -> ImportJobSnapshot {
        try await engine.resume(jobID)
    }

    func storedJobSnapshots() async throws -> [ImportJobSnapshot] {
        try await engine.storedJobSnapshots()
    }

    func restorePendingJobs() async throws -> [ImportJobSnapshot] {
        try await engine.restorePendingJobs()
    }
}

enum ImportJobWorkflowNotice: String, Equatable, Identifiable, Sendable {
    case storageUnavailable
    case libraryReadOnly
    case couldNotStart
    case couldNotContinue

    var id: String {
        rawValue
    }
}

@MainActor
@Observable
final class ImportJobCoordinator {
    private(set) var jobs: [ImportJobSnapshot] = []
    private(set) var isRestoring = false
    private(set) var notice: ImportJobWorkflowNotice?
    private(set) var allowsLibraryWrites: Bool

    @ObservationIgnored private var jobManager: (any ImportJobManaging)?
    private var activeJobIDs = Set<ImportJobID>()
    @ObservationIgnored private var hasRestoredPendingJobs = false
    @ObservationIgnored private var shouldRetryRestoreWhenWritable = false
    @ObservationIgnored private var progressTasks: [
        ImportJobID: Task<Void, Never>
    ] = [:]
    @ObservationIgnored private var observationTokens: [ImportJobID: UUID] = [:]
    @ObservationIgnored private var pendingSourceBookmarks = Set<Data>()
    @ObservationIgnored private var sourceBookmarksByJobID: [ImportJobID: Data] = [:]
    /// 已进入 Manager 的操作允许收尾到安全检查点；generation 只阻止后续写链路。
    @ObservationIgnored private var libraryWriteGeneration = 0

    init(
        jobManager: any ImportJobManaging,
        allowsLibraryWrites: Bool = true
    ) {
        self.jobManager = jobManager
        self.allowsLibraryWrites = allowsLibraryWrites
    }

    init() {
        allowsLibraryWrites = false
        do {
            let layout = try JSONImportJobStore.applicationSupportLayout()
            jobManager = RecoverableImportJobManager(
                engine: RecoverableImportEngine(layout: layout)
            )
            notice = nil
        } catch {
            jobManager = nil
            notice = .storageUnavailable
        }
    }

    func startImport(
        draft: ImportPreviewDraft,
        sourceBookmark: Data
    ) async -> ImportJobID? {
        guard allowsLibraryWrites else {
            notice = .libraryReadOnly
            return nil
        }
        let writeGeneration = libraryWriteGeneration

        guard let jobManager else {
            notice = .storageUnavailable
            return nil
        }

        guard !sourceBookmarksByJobID.values.contains(sourceBookmark),
              pendingSourceBookmarks.insert(sourceBookmark).inserted else {
            notice = .couldNotStart
            return nil
        }
        defer {
            pendingSourceBookmarks.remove(sourceBookmark)
        }

        do {
            let snapshot = try await jobManager.enqueue(
                draft,
                sourceBookmark: sourceBookmark,
                targetComicID: ManagedComicID()
            )
            guard isLibraryWriteAllowed(writeGeneration) else {
                sourceBookmarksByJobID[snapshot.id] = sourceBookmark
                upsert(snapshot)
                publishInvalidatedWriteNotice(
                    writeGeneration: writeGeneration,
                    fallback: .couldNotStart
                )
                return snapshot.id
            }

            sourceBookmarksByJobID[snapshot.id] = sourceBookmark
            upsert(snapshot)
            activeJobIDs.insert(snapshot.id)
            startObserving(
                snapshot.id,
                writeGeneration: writeGeneration
            )

            Task { @MainActor [weak self] in
                await self?.runExistingJob(
                    snapshot.id,
                    resuming: false,
                    writeGeneration: writeGeneration
                )
            }

            return snapshot.id
        } catch {
            if isLibraryWriteAllowed(writeGeneration) {
                notice = .couldNotStart
            } else {
                publishInvalidatedWriteNotice(
                    writeGeneration: writeGeneration,
                    fallback: .couldNotStart
                )
            }
            return nil
        }
    }

    func cancel(_ jobID: ImportJobID) {
        guard allowsLibraryWrites else {
            notice = .libraryReadOnly
            return
        }
        let writeGeneration = libraryWriteGeneration

        guard let jobManager else {
            notice = .storageUnavailable
            return
        }

        Task { @MainActor [weak self] in
            guard let self else {
                return
            }
            guard isLibraryWriteAllowed(writeGeneration) else {
                publishInvalidatedWriteNotice(
                    writeGeneration: writeGeneration,
                    fallback: .couldNotContinue
                )
                return
            }

            do {
                let snapshot = try await jobManager.cancel(jobID)
                upsert(snapshot)
                guard isLibraryWriteAllowed(writeGeneration) else {
                    publishInvalidatedWriteNotice(
                        writeGeneration: writeGeneration,
                        fallback: .couldNotContinue
                    )
                    return
                }
            } catch {
                guard isLibraryWriteAllowed(writeGeneration) else {
                    publishInvalidatedWriteNotice(
                        writeGeneration: writeGeneration,
                        fallback: .couldNotContinue
                    )
                    return
                }

                await refreshSnapshot(
                    jobID,
                    writeGeneration: writeGeneration
                )
                if isLibraryWriteAllowed(writeGeneration) {
                    notice = .couldNotContinue
                }
            }
        }
    }

    func resume(_ jobID: ImportJobID) {
        guard allowsLibraryWrites else {
            notice = .libraryReadOnly
            return
        }
        let writeGeneration = libraryWriteGeneration

        guard jobManager != nil, !activeJobIDs.contains(jobID) else {
            return
        }

        let shouldResume = job(for: jobID)?.state.phase == .paused
        activeJobIDs.insert(jobID)
        startObserving(jobID, writeGeneration: writeGeneration)

        Task { @MainActor [weak self] in
            guard let self else {
                return
            }

            await runExistingJob(
                jobID,
                resuming: shouldResume,
                writeGeneration: writeGeneration
            )
        }
    }

    func restorePendingJobs() async {
        guard allowsLibraryWrites else {
            notice = .libraryReadOnly
            return
        }
        let writeGeneration = libraryWriteGeneration

        guard !hasRestoredPendingJobs, !Task.isCancelled else {
            return
        }
        guard !isRestoring else {
            shouldRetryRestoreWhenWritable = true
            return
        }

        guard let jobManager else {
            notice = .storageUnavailable
            return
        }

        isRestoring = true
        var automaticallyRestoredJobIDs = Set<ImportJobID>()
        defer {
            isRestoring = false
            for jobID in automaticallyRestoredJobIDs {
                activeJobIDs.remove(jobID)
                stopObserving(jobID)
            }
            let shouldRetry = shouldRetryRestoreWhenWritable
                && allowsLibraryWrites
                && !hasRestoredPendingJobs
            if hasRestoredPendingJobs || shouldRetry {
                shouldRetryRestoreWhenWritable = false
            }
            if shouldRetry {
                Task { @MainActor [weak self] in
                    await self?.restorePendingJobs()
                }
            }
        }

        do {
            let storedSnapshots = try await jobManager.storedJobSnapshots()
            if isLibraryWriteAllowed(writeGeneration)
                || !allowsLibraryWrites {
                for snapshot in storedSnapshots {
                    upsert(snapshot)
                }
            }
            guard !Task.isCancelled,
                  isLibraryWriteAllowed(writeGeneration) else {
                if !isLibraryWriteAllowed(writeGeneration) {
                    shouldRetryRestoreWhenWritable = true
                }
                if !Task.isCancelled {
                    publishInvalidatedWriteNotice(
                        writeGeneration: writeGeneration,
                        fallback: .couldNotContinue
                    )
                }
                return
            }

            automaticallyRestoredJobIDs = Set(
                storedSnapshots
                    .filter { shouldAutomaticallyRestore($0) }
                    .map(\.id)
            )
            for jobID in automaticallyRestoredJobIDs {
                activeJobIDs.insert(jobID)
                startObserving(
                    jobID,
                    writeGeneration: writeGeneration
                )
            }

            let snapshots = try await jobManager.restorePendingJobs()
            if isLibraryWriteAllowed(writeGeneration)
                || !allowsLibraryWrites {
                for snapshot in snapshots {
                    upsert(snapshot)
                }
            }
            guard !Task.isCancelled,
                  isLibraryWriteAllowed(writeGeneration) else {
                if !isLibraryWriteAllowed(writeGeneration) {
                    shouldRetryRestoreWhenWritable = true
                }
                if !Task.isCancelled {
                    publishInvalidatedWriteNotice(
                        writeGeneration: writeGeneration,
                        fallback: .couldNotContinue
                    )
                }
                return
            }
            for jobID in automaticallyRestoredJobIDs {
                guard isLibraryWriteAllowed(writeGeneration) else {
                    shouldRetryRestoreWhenWritable = true
                    publishInvalidatedWriteNotice(
                        writeGeneration: writeGeneration,
                        fallback: .couldNotContinue
                    )
                    return
                }
                let didRefresh = await refreshSnapshot(
                    jobID,
                    writeGeneration: writeGeneration
                )
                guard didRefresh else {
                    if !isLibraryWriteAllowed(writeGeneration) {
                        shouldRetryRestoreWhenWritable = true
                    }
                    if !Task.isCancelled {
                        publishInvalidatedWriteNotice(
                            writeGeneration: writeGeneration,
                            fallback: .couldNotContinue
                        )
                    }
                    return
                }
            }

            hasRestoredPendingJobs = true
        } catch {
            if isLibraryWriteAllowed(writeGeneration) {
                notice = .couldNotContinue
            } else {
                shouldRetryRestoreWhenWritable = true
                publishInvalidatedWriteNotice(
                    writeGeneration: writeGeneration,
                    fallback: .couldNotContinue
                )
            }
        }
    }

    var completedJobIDs: [ImportJobID] {
        jobs.compactMap { snapshot in
            snapshot.state.phase == .completed ? snapshot.id : nil
        }
    }

    func job(for jobID: ImportJobID) -> ImportJobSnapshot? {
        jobs.first { $0.id == jobID }
    }

    func isActive(_ jobID: ImportJobID) -> Bool {
        activeJobIDs.contains(jobID)
    }

    func dismissNotice() {
        notice = nil
    }

    func setLibraryWritesAllowed(_ isAllowed: Bool) {
        guard allowsLibraryWrites != isAllowed else {
            if isAllowed, notice == .libraryReadOnly {
                notice = nil
            }
            return
        }

        allowsLibraryWrites = isAllowed
        libraryWriteGeneration &+= 1
        if !isAllowed {
            for jobID in Array(progressTasks.keys) {
                stopObserving(jobID)
            }
        }
        if isAllowed, notice == .libraryReadOnly {
            notice = nil
        }
        if isAllowed,
           shouldRetryRestoreWhenWritable,
           !isRestoring,
           !hasRestoredPendingJobs {
            shouldRetryRestoreWhenWritable = false
            Task { @MainActor [weak self] in
                await self?.restorePendingJobs()
            }
        }
    }

    private func runExistingJob(
        _ jobID: ImportJobID,
        resuming: Bool,
        writeGeneration: Int
    ) async {
        defer {
            activeJobIDs.remove(jobID)
            stopObserving(jobID)
        }

        guard isLibraryWriteAllowed(writeGeneration) else {
            publishInvalidatedWriteNotice(
                writeGeneration: writeGeneration,
                fallback: .couldNotContinue
            )
            return
        }

        guard let jobManager else {
            notice = .storageUnavailable
            return
        }

        do {
            let snapshot: ImportJobSnapshot
            if resuming {
                snapshot = try await jobManager.resume(jobID)
            } else {
                snapshot = try await jobManager.run(jobID)
            }
            upsert(snapshot)
            guard isLibraryWriteAllowed(writeGeneration) else {
                publishInvalidatedWriteNotice(
                    writeGeneration: writeGeneration,
                    fallback: .couldNotContinue
                )
                return
            }
        } catch {
            guard isLibraryWriteAllowed(writeGeneration) else {
                publishInvalidatedWriteNotice(
                    writeGeneration: writeGeneration,
                    fallback: .couldNotContinue
                )
                return
            }

            await refreshSnapshot(
                jobID,
                writeGeneration: writeGeneration
            )
            if isLibraryWriteAllowed(writeGeneration) {
                notice = .couldNotContinue
            }
        }
    }

    private func shouldAutomaticallyRestore(
        _ snapshot: ImportJobSnapshot
    ) -> Bool {
        switch snapshot.state.phase {
        case .completed, .failed:
            false
        case .paused:
            snapshot.state.pause?.code != .userCancelled
        case .queued, .checkingSpace, .copying, .verifying, .commitPrepared,
                .committing, .generatingThumbnail:
            true
        }
    }

    private func startObserving(
        _ jobID: ImportJobID,
        writeGeneration: Int
    ) {
        stopObserving(jobID)
        let token = UUID()
        observationTokens[jobID] = token

        progressTasks[jobID] = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 250_000_000)

                guard !Task.isCancelled,
                      let self,
                      self.isLibraryWriteAllowed(writeGeneration),
                      self.isCurrentObservation(jobID, token: token),
                      self.activeJobIDs.contains(jobID),
                      let jobManager = self.jobManager else {
                    return
                }

                guard let snapshot = try? await jobManager.snapshot(for: jobID),
                      !Task.isCancelled,
                      self.isLibraryWriteAllowed(writeGeneration),
                      self.isCurrentObservation(jobID, token: token),
                      self.activeJobIDs.contains(jobID) else {
                    return
                }

                self.upsert(snapshot)
            }
        }
    }

    private func isCurrentObservation(
        _ jobID: ImportJobID,
        token: UUID
    ) -> Bool {
        observationTokens[jobID] == token
    }

    private func stopObserving(_ jobID: ImportJobID) {
        observationTokens.removeValue(forKey: jobID)
        progressTasks.removeValue(forKey: jobID)?.cancel()
    }

    @discardableResult
    private func refreshSnapshot(
        _ jobID: ImportJobID,
        writeGeneration: Int
    ) async -> Bool {
        guard let jobManager,
              isLibraryWriteAllowed(writeGeneration),
              let snapshot = try? await jobManager.snapshot(for: jobID),
              isLibraryWriteAllowed(writeGeneration) else {
            return false
        }

        upsert(snapshot)
        return true
    }

    private func isLibraryWriteAllowed(_ generation: Int) -> Bool {
        allowsLibraryWrites && generation == libraryWriteGeneration
    }

    private func publishInvalidatedWriteNotice(
        writeGeneration: Int,
        fallback: ImportJobWorkflowNotice
    ) {
        if !allowsLibraryWrites {
            notice = .libraryReadOnly
        } else if writeGeneration == libraryWriteGeneration {
            notice = fallback
        }
    }

    private func upsert(_ snapshot: ImportJobSnapshot) {
        if let index = jobs.firstIndex(where: { $0.id == snapshot.id }) {
            jobs[index] = snapshot
        } else {
            jobs.append(snapshot)
        }

        jobs.sort {
            $0.id.rawValue.uuidString < $1.id.rawValue.uuidString
        }

        if snapshot.state.isTerminal {
            sourceBookmarksByJobID.removeValue(forKey: snapshot.id)
        }
    }
}
