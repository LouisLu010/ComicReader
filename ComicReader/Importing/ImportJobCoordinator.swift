import Foundation
import Observation

protocol ImportJobManaging: Sendable {
    func enqueue(
        _ draft: ImportPreviewDraft,
        sourceURL: URL,
        targetComicID: ManagedComicID
    ) async throws -> ImportJobSnapshot
    func run(_ jobID: ImportJobID) async throws -> ImportJobSnapshot
    func cancel(_ jobID: ImportJobID) async throws -> ImportJobSnapshot
    func resume(_ jobID: ImportJobID) async throws -> ImportJobSnapshot
    func restorePendingJobs() async -> [ImportJobSnapshot]
}

struct RecoverableImportJobManager: ImportJobManaging {
    private let engine: RecoverableImportEngine

    init(engine: RecoverableImportEngine) {
        self.engine = engine
    }

    func enqueue(
        _ draft: ImportPreviewDraft,
        sourceURL: URL,
        targetComicID: ManagedComicID
    ) async throws -> ImportJobSnapshot {
        try await engine.enqueue(
            draft,
            sourceURL: sourceURL,
            targetComicID: targetComicID
        )
    }

    func cancel(_ jobID: ImportJobID) async throws -> ImportJobSnapshot {
        try await engine.cancel(jobID)
    }

    func run(_ jobID: ImportJobID) async throws -> ImportJobSnapshot {
        try await engine.run(jobID)
    }

    func resume(_ jobID: ImportJobID) async throws -> ImportJobSnapshot {
        try await engine.resume(jobID)
    }

    func restorePendingJobs() async -> [ImportJobSnapshot] {
        await engine.restorePendingJobs()
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
        sourceURL: URL
    ) async -> ImportJobID? {
        guard let jobManager else {
            notice = .storageUnavailable
            return nil
        }

        do {
            let snapshot = try await jobManager.enqueue(
                draft,
                sourceURL: sourceURL,
                targetComicID: ManagedComicID()
            )
            upsert(snapshot)
            activeJobIDs.insert(snapshot.id)

            Task { @MainActor [weak self] in
                await self?.runQueuedJob(snapshot.id)
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
                notice = .couldNotContinue
            }
        }
    }

    func resume(_ jobID: ImportJobID) {
        guard let jobManager, !activeJobIDs.contains(jobID) else {
            return
        }

        activeJobIDs.insert(jobID)

        Task { @MainActor [weak self] in
            guard let self else {
                return
            }

            defer {
                activeJobIDs.remove(jobID)
            }

            do {
                let snapshot = try await jobManager.resume(jobID)
                upsert(snapshot)
            } catch {
                notice = .couldNotContinue
            }
        }
    }

    func restorePendingJobs() async {
        guard !hasRestoredPendingJobs else {
            return
        }

        hasRestoredPendingJobs = true
        guard let jobManager else {
            notice = .storageUnavailable
            return
        }

        isRestoring = true
        defer {
            isRestoring = false
        }

        let snapshots = await jobManager.restorePendingJobs()
        for snapshot in snapshots {
            upsert(snapshot)
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

    private func runQueuedJob(_ jobID: ImportJobID) async {
        defer {
            activeJobIDs.remove(jobID)
        }

        guard let jobManager else {
            notice = .storageUnavailable
            return
        }

        do {
            let snapshot = try await jobManager.run(jobID)
            upsert(snapshot)
        } catch {
            notice = .couldNotContinue
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
    }
}
