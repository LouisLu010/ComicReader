import Foundation
import XCTest
@testable import ComicReader

@MainActor
final class ImportJobCoordinatorTests: XCTestCase {
    func testStartImportEnqueuesRunsAndPublishesLatestSnapshot() async {
        let jobID = Self.jobID("00000000-0000-0000-0000-000000000201")
        let queuedSnapshot = Self.snapshot(id: jobID, state: .queued)
        let completedSnapshot = Self.snapshot(id: jobID, state: .completed)
        let manager = RecordingImportJobManager(
            enqueueSnapshot: queuedSnapshot,
            runSnapshot: completedSnapshot
        )
        let coordinator = ImportJobCoordinator(jobManager: manager)
        let sourceURL = URL(fileURLWithPath: "/tmp/imported-comic")

        let startedJobID = await coordinator.startImport(
            draft: Self.draft(),
            sourceURL: sourceURL
        )

        XCTAssertEqual(startedJobID, jobID)
        await waitForJobUpdate(
            coordinator,
            jobID: jobID,
            state: .completed,
            manager: manager,
            expectedRunCount: 1
        )

        let enqueuedSourceURLs = await manager.enqueuedSourceURLs()
        let runJobIDs = await manager.runJobIDs()

        XCTAssertEqual(enqueuedSourceURLs, [sourceURL])
        XCTAssertEqual(runJobIDs, [jobID])
        XCTAssertEqual(coordinator.job(for: jobID), completedSnapshot)
        XCTAssertEqual(coordinator.jobs, [completedSnapshot])
        XCTAssertNil(coordinator.notice)
    }

    func testStartImportFailureShowsGenericNotice() async {
        let jobID = Self.jobID("00000000-0000-0000-0000-000000000202")
        let snapshot = Self.snapshot(id: jobID, state: .queued)
        let manager = RecordingImportJobManager(
            enqueueSnapshot: snapshot,
            runSnapshot: snapshot,
            shouldFailEnqueue: true
        )
        let coordinator = ImportJobCoordinator(jobManager: manager)

        let startedJobID = await coordinator.startImport(
            draft: Self.draft(),
            sourceURL: URL(fileURLWithPath: "/tmp/import-failure")
        )

        XCTAssertNil(startedJobID)
        XCTAssertEqual(coordinator.notice, .couldNotStart)
        XCTAssertEqual(coordinator.jobs, [])
        let runJobIDs = await manager.runJobIDs()

        XCTAssertEqual(runJobIDs, [])
    }

    func testRestorePendingJobsOnlyRunsManagerOnce() async {
        let jobID = Self.jobID("00000000-0000-0000-0000-000000000203")
        let pausedSnapshot = Self.snapshot(
            id: jobID,
            state: .paused(.userCancelled)
        )
        let manager = RecordingImportJobManager(
            enqueueSnapshot: pausedSnapshot,
            runSnapshot: pausedSnapshot,
            restoredSnapshots: [pausedSnapshot]
        )
        let coordinator = ImportJobCoordinator(jobManager: manager)

        await coordinator.restorePendingJobs()
        await coordinator.restorePendingJobs()

        let restoreCallCount = await manager.restoreCallCount()

        XCTAssertEqual(restoreCallCount, 1)
        XCTAssertEqual(coordinator.jobs, [pausedSnapshot])
        XCTAssertFalse(coordinator.isRestoring)
    }

    func testResumeStartsTaskAndPublishesResumedSnapshot() async {
        let jobID = Self.jobID("00000000-0000-0000-0000-000000000204")
        let pausedSnapshot = Self.snapshot(
            id: jobID,
            state: .paused(.userCancelled)
        )
        let completedSnapshot = Self.snapshot(id: jobID, state: .completed)
        let manager = RecordingImportJobManager(
            enqueueSnapshot: pausedSnapshot,
            runSnapshot: completedSnapshot,
            resumeSnapshot: completedSnapshot,
            restoredSnapshots: [pausedSnapshot]
        )
        let coordinator = ImportJobCoordinator(jobManager: manager)

        await coordinator.restorePendingJobs()
        coordinator.resume(jobID)

        await waitForJobUpdate(
            coordinator,
            jobID: jobID,
            state: .completed,
            manager: manager,
            expectedResumeCount: 1
        )

        let resumedJobIDs = await manager.resumedJobIDs()

        XCTAssertEqual(resumedJobIDs, [jobID])
        XCTAssertEqual(coordinator.job(for: jobID), completedSnapshot)
        XCTAssertFalse(coordinator.isActive(jobID))
        XCTAssertNil(coordinator.notice)
    }

    private func waitForJobUpdate(
        _ coordinator: ImportJobCoordinator,
        jobID: ImportJobID,
        state: ImportJobPhase,
        manager: RecordingImportJobManager,
        expectedRunCount: Int = 0,
        expectedResumeCount: Int = 0,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<100 {
            let runCount = await manager.runCallCount()
            let resumeCount = await manager.resumeCallCount()

            if runCount == expectedRunCount,
               resumeCount == expectedResumeCount,
               coordinator.job(for: jobID)?.state.phase == state {
                return
            }

            await Task.yield()
        }

        XCTFail(
            "Timed out waiting for an import job update.",
            file: file,
            line: line
        )
    }

    private static func draft() -> ImportPreviewDraft {
        ImportPreviewDraft(
            manifest: ImportManifest(
                sourceRootName: "Stub Comic",
                sortLocaleIdentifier: "en_US_POSIX",
                collections: [],
                chapters: [],
                pages: [],
                coverPageID: nil,
                issues: [],
                spaceEstimate: .make(contentBytes: 0, fileCount: 0)
            )
        )
    }

    private static func jobID(_ value: String) -> ImportJobID {
        ImportJobID(rawValue: UUID(uuidString: value)!)
    }

    private static func snapshot(
        id: ImportJobID,
        state: ImportJobState
    ) -> ImportJobSnapshot {
        ImportJobSnapshot(
            id: id,
            displayName: "Stub Comic",
            state: state,
            verifiedWorkItemCount: 0,
            totalWorkItemCount: 1,
            verifiedByteCount: 0,
            totalByteCount: 1,
            verifiedChapterIDs: [],
            report: nil
        )
    }
}

private actor RecordingImportJobManager: ImportJobManaging {
    private let enqueueSnapshot: ImportJobSnapshot
    private let runSnapshot: ImportJobSnapshot
    private let resumeSnapshot: ImportJobSnapshot
    private let restoredSnapshots: [ImportJobSnapshot]
    private let shouldFailEnqueue: Bool
    private var sourceURLs: [URL] = []
    private var runIDs: [ImportJobID] = []
    private var resumeIDs: [ImportJobID] = []
    private var restores = 0

    init(
        enqueueSnapshot: ImportJobSnapshot,
        runSnapshot: ImportJobSnapshot,
        resumeSnapshot: ImportJobSnapshot? = nil,
        restoredSnapshots: [ImportJobSnapshot] = [],
        shouldFailEnqueue: Bool = false
    ) {
        self.enqueueSnapshot = enqueueSnapshot
        self.runSnapshot = runSnapshot
        self.resumeSnapshot = resumeSnapshot ?? runSnapshot
        self.restoredSnapshots = restoredSnapshots
        self.shouldFailEnqueue = shouldFailEnqueue
    }

    func enqueue(
        _ draft: ImportPreviewDraft,
        sourceURL: URL,
        targetComicID: ManagedComicID
    ) async throws -> ImportJobSnapshot {
        sourceURLs.append(sourceURL)

        if shouldFailEnqueue {
            throw RecordingImportJobManagerError.enqueueFailed
        }

        return enqueueSnapshot
    }

    func run(_ jobID: ImportJobID) async throws -> ImportJobSnapshot {
        runIDs.append(jobID)
        return runSnapshot
    }

    func cancel(_ jobID: ImportJobID) async throws -> ImportJobSnapshot {
        runSnapshot
    }

    func resume(_ jobID: ImportJobID) async throws -> ImportJobSnapshot {
        resumeIDs.append(jobID)
        return resumeSnapshot
    }

    func restorePendingJobs() async -> [ImportJobSnapshot] {
        restores += 1
        return restoredSnapshots
    }

    func enqueuedSourceURLs() -> [URL] {
        sourceURLs
    }

    func runJobIDs() -> [ImportJobID] {
        runIDs
    }

    func resumedJobIDs() -> [ImportJobID] {
        resumeIDs
    }

    func runCallCount() -> Int {
        runIDs.count
    }

    func resumeCallCount() -> Int {
        resumeIDs.count
    }

    func restoreCallCount() -> Int {
        restores
    }
}

private enum RecordingImportJobManagerError: Error, Sendable {
    case enqueueFailed
}
