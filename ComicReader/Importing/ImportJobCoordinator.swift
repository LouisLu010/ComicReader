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

    @ObservationIgnored private var jobManager: (any ImportJobManaging)?
    private var activeJobIDs = Set<ImportJobID>()
    @ObservationIgnored private var hasRestoredPendingJobs = false
    @ObservationIgnored private var progressTasks: [
        ImportJobID: Task<Void, Never>
    ] = [:]
    @ObservationIgnored private var observationTokens: [ImportJobID: UUID] = [:]
    @ObservationIgnored private var pendingSourceBookmarks = Set<Data>()
    @ObservationIgnored private var sourceBookmarksByJobID: [ImportJobID: Data] = [:]

    init(jobManager: any ImportJobManaging) {
        self.jobManager = jobManager
    }

    init() {
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
            sourceBookmarksByJobID[snapshot.id] = sourceBookmark
            upsert(snapshot)
            activeJobIDs.insert(snapshot.id)
            startObserving(snapshot.id)

            Task { @MainActor [weak self] in
                await self?.runExistingJob(snapshot.id, resuming: false)
            }

            return snapshot.id
        } catch {
            notice = .couldNotStart
            return nil
        }
    }

    func cancel(_ jobID: ImportJobID) {
        guard let jobManager else {
            notice = .storageUnavailable
            return
        }

        Task { @MainActor [weak self] in
            guard let self else {
                return
            }

            do {
                let snapshot = try await jobManager.cancel(jobID)
                upsert(snapshot)
            } catch {
                await refreshSnapshot(jobID)
                notice = .couldNotContinue
            }
        }
    }

    func resume(_ jobID: ImportJobID) {
        guard jobManager != nil, !activeJobIDs.contains(jobID) else {
            return
        }

        let shouldResume = job(for: jobID)?.state.phase == .paused
        activeJobIDs.insert(jobID)
        startObserving(jobID)

        Task { @MainActor [weak self] in
            guard let self else {
                return
            }

            await runExistingJob(jobID, resuming: shouldResume)
        }
    }

    func restorePendingJobs() async {
        guard !hasRestoredPendingJobs, !isRestoring, !Task.isCancelled else {
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
        }

        do {
            let storedSnapshots = try await jobManager.storedJobSnapshots()
            guard !Task.isCancelled else {
                return
            }

            for snapshot in storedSnapshots {
                upsert(snapshot)
            }

            automaticallyRestoredJobIDs = Set(
                storedSnapshots
                    .filter { shouldAutomaticallyRestore($0) }
                    .map(\.id)
            )
            for jobID in automaticallyRestoredJobIDs {
                activeJobIDs.insert(jobID)
                startObserving(jobID)
            }

            let snapshots = try await jobManager.restorePendingJobs()
            guard !Task.isCancelled else {
                return
            }

            for snapshot in snapshots {
                upsert(snapshot)
            }
            for jobID in automaticallyRestoredJobIDs {
                await refreshSnapshot(jobID)
            }

            hasRestoredPendingJobs = true
        } catch {
            notice = .couldNotContinue
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

    private func runExistingJob(
        _ jobID: ImportJobID,
        resuming: Bool
    ) async {
        defer {
            activeJobIDs.remove(jobID)
            stopObserving(jobID)
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
        } catch {
            await refreshSnapshot(jobID)
            notice = .couldNotContinue
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

    private func startObserving(_ jobID: ImportJobID) {
        stopObserving(jobID)
        let token = UUID()
        observationTokens[jobID] = token

        progressTasks[jobID] = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 250_000_000)

                guard !Task.isCancelled,
                      let self,
                      self.isCurrentObservation(jobID, token: token),
                      self.activeJobIDs.contains(jobID),
                      let jobManager = self.jobManager else {
                    return
                }

                guard let snapshot = try? await jobManager.snapshot(for: jobID),
                      !Task.isCancelled,
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

    private func refreshSnapshot(_ jobID: ImportJobID) async {
        guard let jobManager,
              let snapshot = try? await jobManager.snapshot(for: jobID) else {
            return
        }

        upsert(snapshot)
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
