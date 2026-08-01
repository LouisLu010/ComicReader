import Foundation
import XCTest
@testable import ComicReader

@MainActor
final class ImportJobCoordinatorTests: XCTestCase {
    func testReadOnlyGateBlocksImportAndRestoreManagerCalls() async {
        let jobID = Self.jobID("00000000-0000-0000-0000-000000000200")
        let snapshot = Self.snapshot(id: jobID, state: .queued)
        let manager = RecordingImportJobManager(
            enqueueSnapshot: snapshot,
            runSnapshot: snapshot,
            restoredSnapshots: [snapshot]
        )
        let coordinator = ImportJobCoordinator(
            jobManager: manager,
            allowsLibraryWrites: false
        )

        let startedJobID = await coordinator.startImport(
            draft: Self.draft(),
            sourceBookmark: Self.bookmark("read-only")
        )
        await coordinator.restorePendingJobs()
        coordinator.resume(jobID)
        coordinator.cancel(jobID)
        let enqueuedBookmarks = await manager.enqueuedSourceBookmarks()
        let restoreCallCount = await manager.restoreCallCount()
        let resumedJobIDs = await manager.resumedJobIDs()
        let cancelledJobIDs = await manager.cancelledJobIDs()

        XCTAssertNil(startedJobID)
        XCTAssertEqual(coordinator.notice, .libraryReadOnly)
        XCTAssertFalse(coordinator.allowsLibraryWrites)
        XCTAssertEqual(enqueuedBookmarks, [])
        XCTAssertEqual(restoreCallCount, 0)
        XCTAssertEqual(resumedJobIDs, [])
        XCTAssertEqual(cancelledJobIDs, [])

        coordinator.setLibraryWritesAllowed(true)
        XCTAssertTrue(coordinator.allowsLibraryWrites)
        XCTAssertNil(coordinator.notice)
    }

    func testClosingGateWhileEnqueueIsInFlightPreventsFollowUpRun() async {
        let jobID = Self.jobID("00000000-0000-0000-0000-000000000209")
        let snapshot = Self.snapshot(id: jobID, state: .queued)
        let manager = RecordingImportJobManager(
            enqueueSnapshot: snapshot,
            runSnapshot: snapshot,
            enqueueDelayNanoseconds: 200_000_000
        )
        let coordinator = ImportJobCoordinator(jobManager: manager)
        let startTask = Task { @MainActor in
            await coordinator.startImport(
                draft: Self.draft(),
                sourceBookmark: Self.bookmark("in-flight-enqueue")
            )
        }

        await waitForEnqueueCall(manager)
        coordinator.setLibraryWritesAllowed(false)
        let startedJobID = await startTask.value
        let runCallCount = await manager.runCallCount()

        XCTAssertEqual(startedJobID, jobID)
        XCTAssertEqual(runCallCount, 0)
        XCTAssertEqual(coordinator.jobs, [snapshot])
        XCTAssertEqual(coordinator.notice, .libraryReadOnly)
    }

    func testWriteGenerationRejectsReadOnlyABAWhileEnqueueIsInFlight() async {
        let jobID = Self.jobID("00000000-0000-0000-0000-000000000213")
        let snapshot = Self.snapshot(id: jobID, state: .queued)
        let manager = RecordingImportJobManager(
            enqueueSnapshot: snapshot,
            runSnapshot: snapshot,
            enqueueDelayNanoseconds: 200_000_000
        )
        let coordinator = ImportJobCoordinator(jobManager: manager)
        let startTask = Task { @MainActor in
            await coordinator.startImport(
                draft: Self.draft(),
                sourceBookmark: Self.bookmark("in-flight-aba")
            )
        }

        await waitForEnqueueCall(manager)
        coordinator.setLibraryWritesAllowed(false)
        coordinator.setLibraryWritesAllowed(true)
        let startedJobID = await startTask.value
        let runCallCount = await manager.runCallCount()

        XCTAssertEqual(startedJobID, jobID)
        XCTAssertTrue(coordinator.allowsLibraryWrites)
        XCTAssertEqual(runCallCount, 0)
        XCTAssertEqual(coordinator.jobs, [snapshot])
        XCTAssertNil(coordinator.notice)

        coordinator.resume(jobID)
        await waitForJobUpdate(
            coordinator,
            jobID: jobID,
            state: .queued,
            manager: manager,
            expectedRunCount: 1
        )
    }

    func testClosingGateInvalidatesQueuedCancelTask() async {
        let jobID = Self.jobID("00000000-0000-0000-0000-000000000210")
        let snapshot = Self.snapshot(id: jobID, state: .queued)
        let manager = RecordingImportJobManager(
            enqueueSnapshot: snapshot,
            runSnapshot: snapshot
        )
        let coordinator = ImportJobCoordinator(jobManager: manager)

        coordinator.cancel(jobID)
        coordinator.setLibraryWritesAllowed(false)
        await waitForReadOnlyNotice(coordinator)
        let cancelledJobIDs = await manager.cancelledJobIDs()

        XCTAssertEqual(cancelledJobIDs, [])
        XCTAssertEqual(coordinator.notice, .libraryReadOnly)
    }

    func testClosingGateWhileCancelIsInFlightPublishesSettledSnapshot() async {
        let jobID = Self.jobID("00000000-0000-0000-0000-000000000214")
        let pausedSnapshot = Self.snapshot(
            id: jobID,
            state: .paused(.userCancelled)
        )
        let completedSnapshot = Self.snapshot(id: jobID, state: .completed)
        let manager = RecordingImportJobManager(
            enqueueSnapshot: pausedSnapshot,
            runSnapshot: completedSnapshot,
            restoredSnapshots: [pausedSnapshot],
            restoreResultSnapshots: [pausedSnapshot],
            cancelDelayNanoseconds: 200_000_000
        )
        let coordinator = ImportJobCoordinator(jobManager: manager)
        await coordinator.restorePendingJobs()

        coordinator.cancel(jobID)
        await waitForCancelCall(manager)
        coordinator.setLibraryWritesAllowed(false)
        await waitForJobUpdate(
            coordinator,
            jobID: jobID,
            state: .completed,
            manager: manager
        )

        XCTAssertEqual(coordinator.job(for: jobID), completedSnapshot)
        XCTAssertEqual(coordinator.notice, .libraryReadOnly)
    }

    func testReadOnlyABADuringStoredSnapshotReadRetriesAutomatically() async {
        let jobID = Self.jobID("00000000-0000-0000-0000-000000000211")
        let snapshot = Self.snapshot(id: jobID, state: .queued)
        let manager = RecordingImportJobManager(
            enqueueSnapshot: snapshot,
            runSnapshot: snapshot,
            restoredSnapshots: [snapshot],
            storedSnapshotDelayNanoseconds: 200_000_000
        )
        let coordinator = ImportJobCoordinator(jobManager: manager)
        let restoreTask = Task { @MainActor in
            await coordinator.restorePendingJobs()
        }

        await waitForStoredSnapshotCall(manager)
        coordinator.setLibraryWritesAllowed(false)
        coordinator.setLibraryWritesAllowed(true)
        await restoreTask.value
        await waitForRestoreCall(manager)
        await waitForInactiveJob(coordinator, jobID: jobID)
        let restoreCallCount = await manager.restoreCallCount()

        XCTAssertEqual(restoreCallCount, 1)
        XCTAssertEqual(coordinator.jobs, [snapshot])
        XCTAssertFalse(coordinator.isRestoring)
        XCTAssertNil(coordinator.notice)
    }

    func testClosingGateDuringRestorePublishesSettledSnapshots() async {
        let jobID = Self.jobID("00000000-0000-0000-0000-000000000215")
        let queuedSnapshot = Self.snapshot(id: jobID, state: .queued)
        let completedSnapshot = Self.snapshot(id: jobID, state: .completed)
        let manager = RecordingImportJobManager(
            enqueueSnapshot: queuedSnapshot,
            runSnapshot: completedSnapshot,
            restoredSnapshots: [queuedSnapshot],
            restoreResultSnapshots: [completedSnapshot],
            restoreDelayNanoseconds: 200_000_000
        )
        let coordinator = ImportJobCoordinator(jobManager: manager)
        let restoreTask = Task { @MainActor in
            await coordinator.restorePendingJobs()
        }

        await waitForRestoreCall(manager)
        coordinator.setLibraryWritesAllowed(false)
        await restoreTask.value

        XCTAssertEqual(coordinator.job(for: jobID), completedSnapshot)
        XCTAssertFalse(coordinator.isActive(jobID))
        XCTAssertEqual(coordinator.notice, .libraryReadOnly)

        coordinator.setLibraryWritesAllowed(true)
        await waitForRestoreCompletion(
            coordinator,
            manager: manager,
            expectedCallCount: 2
        )
        let restoreCallCount = await manager.restoreCallCount()

        XCTAssertEqual(restoreCallCount, 2)
        XCTAssertEqual(coordinator.job(for: jobID), completedSnapshot)
        XCTAssertNil(coordinator.notice)
    }

    func testReadOnlyABADuringFinalRestoreRefreshRetriesAutomatically() async {
        let jobID = Self.jobID("00000000-0000-0000-0000-000000000216")
        let copyingSnapshot = Self.snapshot(
            id: jobID,
            state: .copying,
            verifiedWorkItemCount: 1
        )
        let pausedSnapshot = Self.snapshot(
            id: jobID,
            state: .paused(.copyFailed(.root)),
            verifiedWorkItemCount: 1
        )
        let manager = RecordingImportJobManager(
            enqueueSnapshot: copyingSnapshot,
            runSnapshot: copyingSnapshot,
            restoredSnapshots: [copyingSnapshot],
            restoreResultSnapshots: [],
            polledSnapshot: pausedSnapshot,
            snapshotDelayNanoseconds: 200_000_000
        )
        let coordinator = ImportJobCoordinator(jobManager: manager)
        let restoreTask = Task { @MainActor in
            await coordinator.restorePendingJobs()
        }

        await waitForSnapshotCall(manager)
        coordinator.setLibraryWritesAllowed(false)
        coordinator.setLibraryWritesAllowed(true)
        await restoreTask.value
        await waitForRestoreCompletion(
            coordinator,
            manager: manager,
            expectedCallCount: 2
        )
        await waitForJobUpdate(
            coordinator,
            jobID: jobID,
            state: .paused,
            manager: manager
        )
        await waitForInactiveJob(coordinator, jobID: jobID)
        let restoreCallCount = await manager.restoreCallCount()

        XCTAssertEqual(restoreCallCount, 2)
        XCTAssertEqual(coordinator.job(for: jobID), pausedSnapshot)
        XCTAssertFalse(coordinator.isActive(jobID))
        XCTAssertNil(coordinator.notice)
    }

    func testClosingGateWhileRunIsInFlightPublishesSettledCompletion() async {
        let jobID = Self.jobID("00000000-0000-0000-0000-000000000212")
        let queuedSnapshot = Self.snapshot(id: jobID, state: .queued)
        let completedSnapshot = Self.snapshot(id: jobID, state: .completed)
        let manager = RecordingImportJobManager(
            enqueueSnapshot: queuedSnapshot,
            runSnapshot: completedSnapshot,
            runDelayNanoseconds: 200_000_000
        )
        let coordinator = ImportJobCoordinator(jobManager: manager)

        let startedJobID = await coordinator.startImport(
            draft: Self.draft(),
            sourceBookmark: Self.bookmark("in-flight-run")
        )
        XCTAssertEqual(startedJobID, jobID)
        await waitForRunCall(manager)

        coordinator.setLibraryWritesAllowed(false)
        await waitForInactiveJob(coordinator, jobID: jobID)

        XCTAssertEqual(coordinator.job(for: jobID), completedSnapshot)
        XCTAssertFalse(coordinator.isActive(jobID))
        XCTAssertEqual(coordinator.notice, .libraryReadOnly)
    }

    func testStartImportEnqueuesRunsAndPublishesLatestSnapshot() async {
        let jobID = Self.jobID("00000000-0000-0000-0000-000000000201")
        let queuedSnapshot = Self.snapshot(id: jobID, state: .queued)
        let completedSnapshot = Self.snapshot(id: jobID, state: .completed)
        let manager = RecordingImportJobManager(
            enqueueSnapshot: queuedSnapshot,
            runSnapshot: completedSnapshot
        )
        let coordinator = ImportJobCoordinator(jobManager: manager)
        let sourceBookmark = Self.bookmark("imported-comic")

        let startedJobID = await coordinator.startImport(
            draft: Self.draft(),
            sourceBookmark: sourceBookmark
        )

        XCTAssertEqual(startedJobID, jobID)
        await waitForJobUpdate(
            coordinator,
            jobID: jobID,
            state: .completed,
            manager: manager,
            expectedRunCount: 1
        )

        let enqueuedSourceBookmarks = await manager.enqueuedSourceBookmarks()
        let runJobIDs = await manager.runJobIDs()

        XCTAssertEqual(enqueuedSourceBookmarks, [sourceBookmark])
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
            sourceBookmark: Self.bookmark("import-failure")
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
            restoredSnapshots: [pausedSnapshot],
            restoreDelayNanoseconds: 200_000_000
        )
        let coordinator = ImportJobCoordinator(jobManager: manager)

        let firstRestore = Task { @MainActor in
            await coordinator.restorePendingJobs()
        }
        await waitForRestoreCall(manager)
        let concurrentRestore = Task { @MainActor in
            await coordinator.restorePendingJobs()
        }

        await concurrentRestore.value
        await firstRestore.value

        let restoreCallCount = await manager.restoreCallCount()

        XCTAssertEqual(restoreCallCount, 1)
        XCTAssertEqual(coordinator.jobs, [pausedSnapshot])
        XCTAssertFalse(coordinator.isRestoring)
    }

    func testRestorePublishesStoredJobBeforeRecoveryCompletes() async {
        let jobID = Self.jobID("00000000-0000-0000-0000-000000000208")
        let queuedSnapshot = Self.snapshot(id: jobID, state: .queued)
        let manager = RecordingImportJobManager(
            enqueueSnapshot: queuedSnapshot,
            runSnapshot: queuedSnapshot,
            restoredSnapshots: [queuedSnapshot],
            polledSnapshot: queuedSnapshot,
            restoreDelayNanoseconds: 1_000_000_000
        )
        let coordinator = ImportJobCoordinator(jobManager: manager)

        let restoreTask = Task { @MainActor in
            await coordinator.restorePendingJobs()
        }

        for _ in 0..<100 {
            if coordinator.isRestoring,
               coordinator.job(for: jobID) == queuedSnapshot,
               coordinator.isActive(jobID) {
                break
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }

        XCTAssertTrue(coordinator.isRestoring)
        XCTAssertEqual(coordinator.job(for: jobID), queuedSnapshot)
        XCTAssertTrue(coordinator.isActive(jobID))

        await restoreTask.value
        XCTAssertFalse(coordinator.isRestoring)
    }

    func testFailedStoredSnapshotReadAllowsRestoreRetry() async {
        let jobID = Self.jobID("00000000-0000-0000-0000-000000000210")
        let pausedSnapshot = Self.snapshot(
            id: jobID,
            state: .paused(.userCancelled)
        )
        let manager = RecordingImportJobManager(
            enqueueSnapshot: pausedSnapshot,
            runSnapshot: pausedSnapshot,
            restoredSnapshots: [pausedSnapshot],
            storedSnapshotFailureCount: 1
        )
        let coordinator = ImportJobCoordinator(jobManager: manager)

        await coordinator.restorePendingJobs()
        XCTAssertEqual(coordinator.notice, .couldNotContinue)
        let initialRestoreCallCount = await manager.restoreCallCount()
        XCTAssertEqual(initialRestoreCallCount, 0)

        await coordinator.restorePendingJobs()

        let retryRestoreCallCount = await manager.restoreCallCount()
        XCTAssertEqual(retryRestoreCallCount, 1)
        XCTAssertEqual(coordinator.jobs, [pausedSnapshot])
    }

    func testRestoreRefreshesJobOmittedAfterRecoveryFailure() async {
        let jobID = Self.jobID("00000000-0000-0000-0000-000000000211")
        let copyingSnapshot = Self.snapshot(
            id: jobID,
            state: .copying,
            verifiedWorkItemCount: 1
        )
        let pausedSnapshot = Self.snapshot(
            id: jobID,
            state: .paused(.copyFailed(.root)),
            verifiedWorkItemCount: 1
        )
        let manager = RecordingImportJobManager(
            enqueueSnapshot: copyingSnapshot,
            runSnapshot: copyingSnapshot,
            restoredSnapshots: [copyingSnapshot],
            restoreResultSnapshots: [],
            polledSnapshot: pausedSnapshot
        )
        let coordinator = ImportJobCoordinator(jobManager: manager)

        await coordinator.restorePendingJobs()

        XCTAssertEqual(coordinator.job(for: jobID), pausedSnapshot)
        XCTAssertFalse(coordinator.isActive(jobID))
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

    func testStartImportPreventsDuplicateSourceWhileJobIsActive() async {
        let jobID = Self.jobID("00000000-0000-0000-0000-000000000205")
        let queuedSnapshot = Self.snapshot(id: jobID, state: .queued)
        let completedSnapshot = Self.snapshot(id: jobID, state: .completed)
        let manager = RecordingImportJobManager(
            enqueueSnapshot: queuedSnapshot,
            runSnapshot: completedSnapshot,
            runDelayNanoseconds: 1_000_000_000
        )
        let coordinator = ImportJobCoordinator(jobManager: manager)
        let sourceBookmark = Self.bookmark("duplicate-source")

        let firstJobID = await coordinator.startImport(
            draft: Self.draft(),
            sourceBookmark: sourceBookmark
        )
        let secondJobID = await coordinator.startImport(
            draft: Self.draft(),
            sourceBookmark: sourceBookmark
        )

        XCTAssertEqual(firstJobID, jobID)
        XCTAssertNil(secondJobID)
        XCTAssertEqual(coordinator.notice, .couldNotStart)

        await waitForJobUpdate(
            coordinator,
            jobID: jobID,
            state: .completed,
            manager: manager,
            expectedRunCount: 1
        )

        let enqueuedSourceBookmarks = await manager.enqueuedSourceBookmarks()
        XCTAssertEqual(enqueuedSourceBookmarks, [sourceBookmark])
    }

    func testPollingPublishesCopyingSnapshotBeforeRunFinishes() async {
        let jobID = Self.jobID("00000000-0000-0000-0000-000000000206")
        let queuedSnapshot = Self.snapshot(id: jobID, state: .queued)
        let copyingSnapshot = Self.snapshot(
            id: jobID,
            state: .copying,
            verifiedWorkItemCount: 1
        )
        let completedSnapshot = Self.snapshot(
            id: jobID,
            state: .completed,
            verifiedWorkItemCount: 1
        )
        let manager = RecordingImportJobManager(
            enqueueSnapshot: queuedSnapshot,
            runSnapshot: completedSnapshot,
            polledSnapshot: copyingSnapshot,
            runDelayNanoseconds: 1_000_000_000
        )
        let coordinator = ImportJobCoordinator(jobManager: manager)

        _ = await coordinator.startImport(
            draft: Self.draft(),
            sourceBookmark: Self.bookmark("progress-source")
        )

        await waitForJobUpdate(
            coordinator,
            jobID: jobID,
            state: .copying,
            manager: manager,
            expectedRunCount: 1
        )

        XCTAssertEqual(coordinator.job(for: jobID), copyingSnapshot)
    }

    func testRunFailureRefreshesPersistedSnapshot() async {
        let jobID = Self.jobID("00000000-0000-0000-0000-000000000207")
        let queuedSnapshot = Self.snapshot(id: jobID, state: .queued)
        let pausedSnapshot = Self.snapshot(
            id: jobID,
            state: .paused(.copyFailed(.root))
        )
        let manager = RecordingImportJobManager(
            enqueueSnapshot: queuedSnapshot,
            runSnapshot: queuedSnapshot,
            polledSnapshot: pausedSnapshot,
            shouldFailRun: true
        )
        let coordinator = ImportJobCoordinator(jobManager: manager)

        _ = await coordinator.startImport(
            draft: Self.draft(),
            sourceBookmark: Self.bookmark("run-failure")
        )

        await waitForJobUpdate(
            coordinator,
            jobID: jobID,
            state: .paused,
            manager: manager,
            expectedRunCount: 1
        )

        XCTAssertEqual(coordinator.notice, .couldNotContinue)
        XCTAssertFalse(coordinator.isActive(jobID))
    }

    func testCancelledObserverCannotOverwriteCompletedSnapshot() async {
        let jobID = Self.jobID("00000000-0000-0000-0000-000000000209")
        let queuedSnapshot = Self.snapshot(id: jobID, state: .queued)
        let copyingSnapshot = Self.snapshot(
            id: jobID,
            state: .copying,
            verifiedWorkItemCount: 1
        )
        let completedSnapshot = Self.snapshot(
            id: jobID,
            state: .completed,
            verifiedWorkItemCount: 1
        )
        let manager = RecordingImportJobManager(
            enqueueSnapshot: queuedSnapshot,
            runSnapshot: completedSnapshot,
            polledSnapshot: copyingSnapshot,
            runDelayNanoseconds: 1_000_000_000,
            snapshotDelayNanoseconds: 1_000_000_000
        )
        let coordinator = ImportJobCoordinator(jobManager: manager)

        _ = await coordinator.startImport(
            draft: Self.draft(),
            sourceBookmark: Self.bookmark("observer-race")
        )

        for _ in 0..<100 {
            if await manager.snapshotCallCount() > 0 {
                break
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }

        let snapshotCallCount = await manager.snapshotCallCount()
        XCTAssertGreaterThan(snapshotCallCount, 0)

        await waitForJobUpdate(
            coordinator,
            jobID: jobID,
            state: .completed,
            manager: manager,
            expectedRunCount: 1
        )
        try? await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(coordinator.job(for: jobID), completedSnapshot)
        XCTAssertFalse(coordinator.isActive(jobID))
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

            try? await Task.sleep(nanoseconds: 20_000_000)
        }

        XCTFail(
            "Timed out waiting for an import job update.",
            file: file,
            line: line
        )
    }

    private func waitForEnqueueCall(
        _ manager: RecordingImportJobManager,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<100 {
            if await manager.enqueueCallCount() > 0 {
                return
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Timed out waiting for enqueue.", file: file, line: line)
    }

    private func waitForReadOnlyNotice(
        _ coordinator: ImportJobCoordinator,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<100 {
            if coordinator.notice == .libraryReadOnly {
                return
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Timed out waiting for read-only notice.", file: file, line: line)
    }

    private func waitForStoredSnapshotCall(
        _ manager: RecordingImportJobManager,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<100 {
            if await manager.storedSnapshotCallCount() > 0 {
                return
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail(
            "Timed out waiting for stored snapshots.",
            file: file,
            line: line
        )
    }

    private func waitForCancelCall(
        _ manager: RecordingImportJobManager,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<100 {
            if await manager.cancelCallCount() > 0 {
                return
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Timed out waiting for cancel.", file: file, line: line)
    }

    private func waitForRestoreCall(
        _ manager: RecordingImportJobManager,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<100 {
            if await manager.restoreCallCount() > 0 {
                return
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Timed out waiting for restore.", file: file, line: line)
    }

    private func waitForRestoreCompletion(
        _ coordinator: ImportJobCoordinator,
        manager: RecordingImportJobManager,
        expectedCallCount: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<100 {
            let callCount = await manager.restoreCallCount()
            if callCount >= expectedCallCount, !coordinator.isRestoring {
                return
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail(
            "Timed out waiting for restore completion.",
            file: file,
            line: line
        )
    }

    private func waitForRunCall(
        _ manager: RecordingImportJobManager,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<100 {
            if await manager.runCallCount() > 0 {
                return
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Timed out waiting for run.", file: file, line: line)
    }

    private func waitForSnapshotCall(
        _ manager: RecordingImportJobManager,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<100 {
            if await manager.snapshotCallCount() > 0 {
                return
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Timed out waiting for snapshot.", file: file, line: line)
    }

    private func waitForInactiveJob(
        _ coordinator: ImportJobCoordinator,
        jobID: ImportJobID,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<100 {
            if !coordinator.isActive(jobID) {
                return
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Timed out waiting for inactive job.", file: file, line: line)
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

    private static func bookmark(_ value: String) -> Data {
        Data(value.utf8)
    }

    private static func snapshot(
        id: ImportJobID,
        state: ImportJobState,
        verifiedWorkItemCount: Int = 0
    ) -> ImportJobSnapshot {
        ImportJobSnapshot(
            id: id,
            displayName: "Stub Comic",
            state: state,
            verifiedWorkItemCount: verifiedWorkItemCount,
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
    private let restoreResultSnapshots: [ImportJobSnapshot]
    private let polledSnapshot: ImportJobSnapshot?
    private let shouldFailEnqueue: Bool
    private let shouldFailRun: Bool
    private let enqueueDelayNanoseconds: UInt64
    private let cancelDelayNanoseconds: UInt64
    private let runDelayNanoseconds: UInt64
    private let snapshotDelayNanoseconds: UInt64
    private let storedSnapshotDelayNanoseconds: UInt64
    private let restoreDelayNanoseconds: UInt64
    private var storedSnapshotFailuresRemaining: Int
    private var sourceBookmarks: [Data] = []
    private var runIDs: [ImportJobID] = []
    private var resumeIDs: [ImportJobID] = []
    private var cancelIDs: [ImportJobID] = []
    private var restores = 0
    private var snapshotCalls = 0
    private var storedSnapshotCalls = 0

    init(
        enqueueSnapshot: ImportJobSnapshot,
        runSnapshot: ImportJobSnapshot,
        resumeSnapshot: ImportJobSnapshot? = nil,
        restoredSnapshots: [ImportJobSnapshot] = [],
        restoreResultSnapshots: [ImportJobSnapshot]? = nil,
        polledSnapshot: ImportJobSnapshot? = nil,
        shouldFailEnqueue: Bool = false,
        shouldFailRun: Bool = false,
        enqueueDelayNanoseconds: UInt64 = 0,
        cancelDelayNanoseconds: UInt64 = 0,
        runDelayNanoseconds: UInt64 = 0,
        snapshotDelayNanoseconds: UInt64 = 0,
        storedSnapshotFailureCount: Int = 0,
        storedSnapshotDelayNanoseconds: UInt64 = 0,
        restoreDelayNanoseconds: UInt64 = 0
    ) {
        self.enqueueSnapshot = enqueueSnapshot
        self.runSnapshot = runSnapshot
        self.resumeSnapshot = resumeSnapshot ?? runSnapshot
        self.restoredSnapshots = restoredSnapshots
        self.restoreResultSnapshots = restoreResultSnapshots ?? restoredSnapshots
        self.polledSnapshot = polledSnapshot
        self.shouldFailEnqueue = shouldFailEnqueue
        self.shouldFailRun = shouldFailRun
        self.enqueueDelayNanoseconds = enqueueDelayNanoseconds
        self.cancelDelayNanoseconds = cancelDelayNanoseconds
        self.runDelayNanoseconds = runDelayNanoseconds
        self.snapshotDelayNanoseconds = snapshotDelayNanoseconds
        self.storedSnapshotFailuresRemaining = storedSnapshotFailureCount
        self.storedSnapshotDelayNanoseconds = storedSnapshotDelayNanoseconds
        self.restoreDelayNanoseconds = restoreDelayNanoseconds
    }

    func enqueue(
        _ draft: ImportPreviewDraft,
        sourceBookmark: Data,
        targetComicID: ManagedComicID
    ) async throws -> ImportJobSnapshot {
        sourceBookmarks.append(sourceBookmark)

        if enqueueDelayNanoseconds > 0 {
            try? await Task.sleep(nanoseconds: enqueueDelayNanoseconds)
        }

        if shouldFailEnqueue {
            throw RecordingImportJobManagerError.enqueueFailed
        }

        return enqueueSnapshot
    }

    func run(_ jobID: ImportJobID) async throws -> ImportJobSnapshot {
        runIDs.append(jobID)

        if runDelayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: runDelayNanoseconds)
        }

        if shouldFailRun {
            throw RecordingImportJobManagerError.runFailed
        }

        return runSnapshot
    }

    func snapshot(for jobID: ImportJobID) async throws -> ImportJobSnapshot {
        snapshotCalls += 1

        if snapshotDelayNanoseconds > 0 {
            try? await Task.sleep(nanoseconds: snapshotDelayNanoseconds)
        }

        return polledSnapshot ?? runSnapshot
    }

    func cancel(_ jobID: ImportJobID) async throws -> ImportJobSnapshot {
        cancelIDs.append(jobID)
        if cancelDelayNanoseconds > 0 {
            try? await Task.sleep(nanoseconds: cancelDelayNanoseconds)
        }
        return runSnapshot
    }

    func resume(_ jobID: ImportJobID) async throws -> ImportJobSnapshot {
        resumeIDs.append(jobID)
        return resumeSnapshot
    }

    func storedJobSnapshots() async throws -> [ImportJobSnapshot] {
        storedSnapshotCalls += 1

        if storedSnapshotDelayNanoseconds > 0 {
            try? await Task.sleep(
                nanoseconds: storedSnapshotDelayNanoseconds
            )
        }

        if storedSnapshotFailuresRemaining > 0 {
            storedSnapshotFailuresRemaining -= 1
            throw RecordingImportJobManagerError.storedSnapshotReadFailed
        }

        return restoredSnapshots
    }

    func restorePendingJobs() async throws -> [ImportJobSnapshot] {
        restores += 1

        if restoreDelayNanoseconds > 0 {
            try? await Task.sleep(nanoseconds: restoreDelayNanoseconds)
        }

        return restoreResultSnapshots
    }

    func enqueuedSourceBookmarks() -> [Data] {
        sourceBookmarks
    }

    func runJobIDs() -> [ImportJobID] {
        runIDs
    }

    func resumedJobIDs() -> [ImportJobID] {
        resumeIDs
    }

    func cancelledJobIDs() -> [ImportJobID] {
        cancelIDs
    }

    func cancelCallCount() -> Int {
        cancelIDs.count
    }

    func enqueueCallCount() -> Int {
        sourceBookmarks.count
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

    func snapshotCallCount() -> Int {
        snapshotCalls
    }

    func storedSnapshotCallCount() -> Int {
        storedSnapshotCalls
    }
}

private enum RecordingImportJobManagerError: Error, Sendable {
    case enqueueFailed
    case runFailed
    case storedSnapshotReadFailed
}
