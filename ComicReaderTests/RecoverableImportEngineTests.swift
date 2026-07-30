import Foundation
import XCTest
@testable import ComicReader

final class RecoverableImportEngineTests: XCTestCase {
    func testRunCopiesOriginalBytesCommitsOnceAndLeavesSourceUntouched() async throws {
        let sandbox = try TemporaryImportSandbox(sourceName: "Imported Comic")
        let coverURL = try sandbox.sourceTree.png("cover.png")
        let pageURL = try sandbox.sourceTree.image(
            "Chapter 1/page-without-extension",
            format: .jpeg
        )
        let sourceSnapshot = try sandbox.sourceSnapshot()
        let manifest = try await scan(sandbox)
        let draft = ImportPreviewDraft(manifest: manifest)
        let targetComicID = ManagedComicID(
            rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000010")!
        )
        let layout = ImportStorageLayout(rootURL: sandbox.appManagedRootURL)
        let engine = RecoverableImportEngine(
            layout: layout,
            sourceAccess: TestSourceAccess(rootURL: sandbox.sourceDirectoryURL),
            capacityProvider: FixedCapacityProvider(value: .max),
            thumbnailGenerator: TestThumbnailGenerator()
        )

        let queued = try await engine.enqueue(
            draft,
            sourceURL: sandbox.sourceDirectoryURL,
            targetComicID: targetComicID
        )
        let completed = try await engine.run(queued.id)
        let loaded = try JSONImportJobStore(layout: layout).load(queued.id)

        XCTAssertEqual(completed.state.phase, .completed)
        XCTAssertEqual(completed.verifiedWorkItemCount, 2)
        XCTAssertEqual(completed.report?.thumbnailStatus, .generated)
        XCTAssertTrue(try sandbox.sourceIsUnchanged(since: sourceSnapshot))
        XCTAssertEqual(
            try Data(contentsOf: libraryURL(
                rootURL: layout.libraryURL(for: targetComicID),
                components: ["original", coverURL.lastPathComponent]
            )),
            try Data(contentsOf: coverURL)
        )
        XCTAssertEqual(
            try Data(contentsOf: libraryURL(
                rootURL: layout.libraryURL(for: targetComicID),
                components: ["original", "Chapter 1", pageURL.lastPathComponent]
            )),
            try Data(contentsOf: pageURL)
        )
        XCTAssertEqual(loaded.journal.state.phase, .completed)
        XCTAssertEqual(loaded.journal.verifiedWorkItemIDs, loaded.plan.workItems.map(\.id))
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: layout.thumbnailURL(for: targetComicID).path
            )
        )

        let descriptorURL = libraryURL(
            rootURL: layout.libraryURL(for: targetComicID),
            components: ["metadata", "import-descriptor.json"]
        )
        let descriptor = try XCTUnwrap(
            String(data: Data(contentsOf: descriptorURL), encoding: .utf8)
        )

        XCTAssertFalse(descriptor.contains("sourceBookmark"))
        XCTAssertFalse(descriptor.contains(sandbox.sourceDirectoryURL.path))
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: layout.creatingJobDirectory(for: queued.id).path
            )
        )
    }

    func testStoredJobSnapshotsExposeQueuedJobsBeforeRecoveryRuns() async throws {
        let sandbox = try TemporaryImportSandbox(sourceName: "Stored Jobs")
        try sandbox.sourceTree.png("Chapter/01.png")
        let manifest = try await scan(sandbox)
        let layout = ImportStorageLayout(rootURL: sandbox.appManagedRootURL)
        let engine = RecoverableImportEngine(
            layout: layout,
            sourceAccess: TestSourceAccess(rootURL: sandbox.sourceDirectoryURL),
            capacityProvider: FixedCapacityProvider(value: .max),
            thumbnailGenerator: TestThumbnailGenerator()
        )

        let queued = try await engine.enqueue(
            ImportPreviewDraft(manifest: manifest),
            sourceURL: sandbox.sourceDirectoryURL
        )
        let snapshots = try await engine.storedJobSnapshots()

        XCTAssertEqual(snapshots, [queued])
    }

    func testInsufficientSpacePausesBeforeCopyWithoutChangingSource() async throws {
        let sandbox = try TemporaryImportSandbox(sourceName: "No Space")
        try sandbox.sourceTree.png("Chapter/01.png")
        let sourceSnapshot = try sandbox.sourceSnapshot()
        let manifest = try await scan(sandbox)
        let draft = ImportPreviewDraft(manifest: manifest)
        let layout = ImportStorageLayout(rootURL: sandbox.appManagedRootURL)
        let targetComicID = ManagedComicID(
            rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000020")!
        )
        let engine = RecoverableImportEngine(
            layout: layout,
            sourceAccess: TestSourceAccess(rootURL: sandbox.sourceDirectoryURL),
            capacityProvider: FixedCapacityProvider(value: 0),
            thumbnailGenerator: TestThumbnailGenerator()
        )

        let queued = try await engine.enqueue(
            draft,
            sourceURL: sandbox.sourceDirectoryURL,
            targetComicID: targetComicID
        )
        let paused = try await engine.run(queued.id)

        XCTAssertEqual(paused.state.phase, .paused)
        XCTAssertEqual(paused.state.pause?.code, .insufficientSpace)
        XCTAssertEqual(paused.verifiedWorkItemCount, 0)
        XCTAssertEqual(
            paused.state.pause?.requiredBytes,
            ImportSpaceEstimate.make(
                contentBytes: paused.totalByteCount,
                fileCount: paused.totalWorkItemCount
            ).requiredAvailableBytes
        )
        XCTAssertEqual(paused.state.pause?.availableBytes, 0)
        XCTAssertTrue(try sandbox.sourceIsUnchanged(since: sourceSnapshot))
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: layout.libraryURL(for: targetComicID).path
            )
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: layout.payloadURL(for: queued.id)
                    .appendingPathComponent("original", isDirectory: true)
                    .path
            )
        )
    }

    func testCopyFailurePausesAndExplicitResumeKeepsVerifiedWork() async throws {
        let sandbox = try TemporaryImportSandbox(sourceName: "Copy Failure")
        try sandbox.sourceTree.png("Chapter/01.png")
        try sandbox.sourceTree.png("Chapter/02.png")
        let sourceSnapshot = try sandbox.sourceSnapshot()
        let manifest = try await scan(sandbox)
        let draft = ImportPreviewDraft(manifest: manifest)
        let layout = ImportStorageLayout(rootURL: sandbox.appManagedRootURL)
        let targetComicID = ManagedComicID(
            rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000030")!
        )
        let faultInjector = ScriptedFaultInjector()
        let engine = RecoverableImportEngine(
            layout: layout,
            sourceAccess: TestSourceAccess(rootURL: sandbox.sourceDirectoryURL),
            capacityProvider: FixedCapacityProvider(value: .max),
            thumbnailGenerator: TestThumbnailGenerator(),
            faultInjector: faultInjector
        )

        let queued = try await engine.enqueue(
            draft,
            sourceURL: sandbox.sourceDirectoryURL,
            targetComicID: targetComicID
        )
        let plan = try JSONImportJobStore(layout: layout).load(queued.id).plan
        let failedWorkItem = try XCTUnwrap(plan.workItems.dropFirst().first)
        await faultInjector.set(
            .copyFailed,
            at: .beforeCopy(jobID: queued.id, pageID: failedWorkItem.id)
        )

        let paused = try await engine.run(queued.id)
        let pausedJournal = try JSONImportJobStore(layout: layout).load(queued.id)

        XCTAssertEqual(paused.state.phase, .paused)
        XCTAssertEqual(paused.state.pause?.code, .copyFailed)
        XCTAssertEqual(paused.verifiedWorkItemCount, 1)
        XCTAssertEqual(pausedJournal.journal.checkpoints[0].phase, .verified)
        XCTAssertEqual(pausedJournal.journal.checkpoints[1].phase, .pending)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: layout.libraryURL(for: targetComicID).path
            )
        )
        XCTAssertTrue(try sandbox.sourceIsUnchanged(since: sourceSnapshot))

        let resumedEngine = RecoverableImportEngine(
            layout: layout,
            sourceAccess: TestSourceAccess(rootURL: sandbox.sourceDirectoryURL),
            capacityProvider: FixedCapacityProvider(value: .max),
            thumbnailGenerator: TestThumbnailGenerator()
        )
        let completed = try await resumedEngine.resume(queued.id)

        XCTAssertEqual(completed.state.phase, .completed)
        XCTAssertEqual(completed.verifiedWorkItemCount, 2)
        XCTAssertEqual(completed.report?.runtimeIssues, [
            .copyFailed(failedWorkItem.sourceRelativePath),
        ])
        XCTAssertTrue(try sandbox.sourceIsUnchanged(since: sourceSnapshot))
    }

    func testPermissionLossPausesBeforeCopyWithoutChangingSource() async throws {
        let sandbox = try TemporaryImportSandbox(sourceName: "Permission Lost")
        try sandbox.sourceTree.png("Chapter/01.png")
        let sourceSnapshot = try sandbox.sourceSnapshot()
        let manifest = try await scan(sandbox)
        let layout = ImportStorageLayout(rootURL: sandbox.appManagedRootURL)
        let targetComicID = ManagedComicID(
            rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000040")!
        )
        let engine = RecoverableImportEngine(
            layout: layout,
            sourceAccess: DenyingSourceAccess(rootURL: sandbox.sourceDirectoryURL),
            capacityProvider: FixedCapacityProvider(value: .max),
            thumbnailGenerator: TestThumbnailGenerator()
        )

        let queued = try await engine.enqueue(
            ImportPreviewDraft(manifest: manifest),
            sourceURL: sandbox.sourceDirectoryURL,
            targetComicID: targetComicID
        )
        let paused = try await engine.run(queued.id)

        XCTAssertEqual(paused.state.phase, .paused)
        XCTAssertEqual(paused.state.pause?.code, .permissionLost)
        XCTAssertEqual(paused.verifiedWorkItemCount, 0)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: layout.libraryURL(for: targetComicID).path
            )
        )
        XCTAssertTrue(try sandbox.sourceIsUnchanged(since: sourceSnapshot))
    }

    func testSourceChangeAfterPreviewPausesWithoutPublishingLibrary() async throws {
        let sandbox = try TemporaryImportSandbox(sourceName: "Source Changed")
        try sandbox.sourceTree.png("Chapter/01.png")
        let manifest = try await scan(sandbox)
        try sandbox.sourceTree.alternatePNG("Chapter/01.png")
        let sourceSnapshot = try sandbox.sourceSnapshot()
        let layout = ImportStorageLayout(rootURL: sandbox.appManagedRootURL)
        let targetComicID = ManagedComicID(
            rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000050")!
        )
        let engine = RecoverableImportEngine(
            layout: layout,
            sourceAccess: TestSourceAccess(rootURL: sandbox.sourceDirectoryURL),
            capacityProvider: FixedCapacityProvider(value: .max),
            thumbnailGenerator: TestThumbnailGenerator()
        )

        let queued = try await engine.enqueue(
            ImportPreviewDraft(manifest: manifest),
            sourceURL: sandbox.sourceDirectoryURL,
            targetComicID: targetComicID
        )
        let paused = try await engine.run(queued.id)

        XCTAssertEqual(paused.state.phase, .paused)
        XCTAssertEqual(paused.state.pause?.code, .sourceChanged)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: layout.libraryURL(for: targetComicID).path
            )
        )
        XCTAssertTrue(try sandbox.sourceIsUnchanged(since: sourceSnapshot))
    }

    func testDeletedSourceAfterPreviewPausesAsSourceChanged() async throws {
        let sandbox = try TemporaryImportSandbox(sourceName: "Deleted Source")
        let pageURL = try sandbox.sourceTree.png("Chapter/01.png")
        let manifest = try await scan(sandbox)
        try FileManager.default.removeItem(at: pageURL)
        let sourceSnapshot = try sandbox.sourceSnapshot()
        let layout = ImportStorageLayout(rootURL: sandbox.appManagedRootURL)
        let targetComicID = ManagedComicID(
            rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000055")!
        )
        let engine = RecoverableImportEngine(
            layout: layout,
            sourceAccess: TestSourceAccess(rootURL: sandbox.sourceDirectoryURL),
            capacityProvider: FixedCapacityProvider(value: .max),
            thumbnailGenerator: TestThumbnailGenerator()
        )

        let queued = try await engine.enqueue(
            ImportPreviewDraft(manifest: manifest),
            sourceURL: sandbox.sourceDirectoryURL,
            targetComicID: targetComicID
        )
        let paused = try await engine.run(queued.id)

        XCTAssertEqual(paused.state.phase, .paused)
        XCTAssertEqual(paused.state.pause?.code, .sourceChanged)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: layout.libraryURL(for: targetComicID).path
            )
        )
        XCTAssertTrue(try sandbox.sourceIsUnchanged(since: sourceSnapshot))
    }

    func testThumbnailFailureKeepsPublishedOriginalsAndCompletes() async throws {
        let sandbox = try TemporaryImportSandbox(sourceName: "Thumbnail Failure")
        let coverURL = try sandbox.sourceTree.png("cover.png")
        try sandbox.sourceTree.png("Chapter/01.png")
        let sourceSnapshot = try sandbox.sourceSnapshot()
        let manifest = try await scan(sandbox)
        let layout = ImportStorageLayout(rootURL: sandbox.appManagedRootURL)
        let targetComicID = ManagedComicID(
            rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000060")!
        )
        let engine = RecoverableImportEngine(
            layout: layout,
            sourceAccess: TestSourceAccess(rootURL: sandbox.sourceDirectoryURL),
            capacityProvider: FixedCapacityProvider(value: .max),
            thumbnailGenerator: FailingThumbnailGenerator()
        )

        let queued = try await engine.enqueue(
            ImportPreviewDraft(manifest: manifest),
            sourceURL: sandbox.sourceDirectoryURL,
            targetComicID: targetComicID
        )
        let completed = try await engine.run(queued.id)

        XCTAssertEqual(completed.state.phase, .completed)
        XCTAssertEqual(completed.report?.thumbnailStatus, .failed)
        XCTAssertEqual(completed.report?.runtimeIssues, [.thumbnailFailed])
        XCTAssertEqual(
            try Data(contentsOf: libraryURL(
                rootURL: layout.libraryURL(for: targetComicID),
                components: ["original", coverURL.lastPathComponent]
            )),
            try Data(contentsOf: coverURL)
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: layout.thumbnailURL(for: targetComicID).path
            )
        )
        XCTAssertTrue(try sandbox.sourceIsUnchanged(since: sourceSnapshot))
    }

    func testCancelBeforeCommitIntentKeepsStagingAndRequiresExplicitResume() async throws {
        let sandbox = try TemporaryImportSandbox(sourceName: "Cancel Commit")
        try sandbox.sourceTree.png("Chapter/01.png")
        try sandbox.sourceTree.png("Chapter/02.png")
        let sourceSnapshot = try sandbox.sourceSnapshot()
        let manifest = try await scan(sandbox)
        let layout = ImportStorageLayout(rootURL: sandbox.appManagedRootURL)
        let targetComicID = ManagedComicID(
            rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000070")!
        )
        let faultInjector = BlockingCommitFaultInjector()
        let engine = RecoverableImportEngine(
            layout: layout,
            sourceAccess: TestSourceAccess(rootURL: sandbox.sourceDirectoryURL),
            capacityProvider: FixedCapacityProvider(value: .max),
            thumbnailGenerator: TestThumbnailGenerator(),
            faultInjector: faultInjector
        )

        let queued = try await engine.enqueue(
            ImportPreviewDraft(manifest: manifest),
            sourceURL: sandbox.sourceDirectoryURL,
            targetComicID: targetComicID
        )
        let runTask = Task {
            try await engine.run(queued.id)
        }

        let timeoutTask = Task {
            do {
                try await Task.sleep(nanoseconds: 5_000_000_000)
            } catch {
                return
            }
            await faultInjector.expireCommitBoundaryWaiters()
        }
        let reachedCommitBoundary = await faultInjector.waitUntilCommitBoundary()
        timeoutTask.cancel()
        guard reachedCommitBoundary else {
            await faultInjector.release()
            _ = try? await runTask.value
            XCTFail("Timed out waiting for the commit cancellation boundary.")
            return
        }

        _ = try await engine.cancel(queued.id)
        await faultInjector.release()
        let paused = try await runTask.value
        let pausedJournal = try JSONImportJobStore(layout: layout).load(queued.id)

        XCTAssertEqual(paused.state.phase, .paused)
        XCTAssertEqual(paused.state.pause?.code, .userCancelled)
        XCTAssertTrue(pausedJournal.journal.cancellationRequested)
        XCTAssertTrue(
            pausedJournal.journal.checkpoints.allSatisfy { checkpoint in
                checkpoint.phase == .verified
            }
        )
        XCTAssertNil(pausedJournal.journal.commitIntent)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: layout.libraryURL(for: targetComicID).path
            )
        )
        XCTAssertTrue(try sandbox.sourceIsUnchanged(since: sourceSnapshot))

        let resumedEngine = RecoverableImportEngine(
            layout: layout,
            sourceAccess: TestSourceAccess(rootURL: sandbox.sourceDirectoryURL),
            capacityProvider: FixedCapacityProvider(value: .max),
            thumbnailGenerator: TestThumbnailGenerator()
        )
        let restored = try await resumedEngine.restorePendingJobs()

        XCTAssertEqual(restored.map(\.state.phase), [.paused])
        XCTAssertEqual(restored.first?.state.pause?.code, .userCancelled)

        let completed = try await resumedEngine.resume(queued.id)

        XCTAssertEqual(completed.state.phase, .completed)
        XCTAssertTrue(try sandbox.sourceIsUnchanged(since: sourceSnapshot))
    }

    func testRestartAfterPayloadMoveFinalizesWithoutReadingSourceAgain() async throws {
        let sandbox = try TemporaryImportSandbox(sourceName: "Moved Payload")
        try sandbox.sourceTree.png("Chapter/01.png")
        let sourceSnapshot = try sandbox.sourceSnapshot()
        let manifest = try await scan(sandbox)
        let layout = ImportStorageLayout(rootURL: sandbox.appManagedRootURL)
        let targetComicID = ManagedComicID(
            rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000080")!
        )
        let faultInjector = ScriptedFaultInjector()
        let engine = RecoverableImportEngine(
            layout: layout,
            sourceAccess: TestSourceAccess(rootURL: sandbox.sourceDirectoryURL),
            capacityProvider: FixedCapacityProvider(value: .max),
            thumbnailGenerator: TestThumbnailGenerator(),
            faultInjector: faultInjector
        )

        let queued = try await engine.enqueue(
            ImportPreviewDraft(manifest: manifest),
            sourceURL: sandbox.sourceDirectoryURL,
            targetComicID: targetComicID
        )
        await faultInjector.set(
            .simulatedProcessInterruption,
            at: .afterPayloadMoved(queued.id)
        )

        do {
            _ = try await engine.run(queued.id)
            XCTFail("Expected a simulated process interruption.")
        } catch let error as ImportInjectedFault {
            XCTAssertEqual(error, .simulatedProcessInterruption)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let interrupted = try JSONImportJobStore(layout: layout).load(queued.id)
        XCTAssertEqual(interrupted.journal.state.phase, .committing)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: layout.libraryURL(for: targetComicID).path
            )
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: layout.payloadURL(for: queued.id).path
            )
        )

        let restoredEngine = RecoverableImportEngine(
            layout: layout,
            sourceAccess: DenyingSourceAccess(rootURL: sandbox.sourceDirectoryURL),
            capacityProvider: FixedCapacityProvider(value: .max),
            thumbnailGenerator: TestThumbnailGenerator()
        )
        let restored = try await restoredEngine.restorePendingJobs()
        let completed = try await restoredEngine.snapshot(for: queued.id)

        XCTAssertEqual(restored.map(\.state.phase), [.completed])
        XCTAssertEqual(completed.state.phase, .completed)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: libraryURL(
                    rootURL: layout.libraryURL(for: targetComicID),
                    components: ["metadata", "commit-receipt.json"]
                ).path
            )
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: layout.payloadURL(for: queued.id).path
            )
        )
        XCTAssertTrue(try sandbox.sourceIsUnchanged(since: sourceSnapshot))
    }

    func testCommitMoveFailureKeepsPayloadForDiagnosis() async throws {
        let sandbox = try TemporaryImportSandbox(sourceName: "Commit Move Failure")
        try sandbox.sourceTree.png("Chapter/01.png")
        let sourceSnapshot = try sandbox.sourceSnapshot()
        let manifest = try await scan(sandbox)
        let layout = ImportStorageLayout(rootURL: sandbox.appManagedRootURL)
        let targetComicID = ManagedComicID(
            rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000085")!
        )
        let faultInjector = ScriptedFaultInjector()
        let engine = RecoverableImportEngine(
            layout: layout,
            sourceAccess: TestSourceAccess(rootURL: sandbox.sourceDirectoryURL),
            capacityProvider: FixedCapacityProvider(value: .max),
            thumbnailGenerator: TestThumbnailGenerator(),
            faultInjector: faultInjector
        )

        let queued = try await engine.enqueue(
            ImportPreviewDraft(manifest: manifest),
            sourceURL: sandbox.sourceDirectoryURL,
            targetComicID: targetComicID
        )
        await faultInjector.set(
            .commitMoveFailed,
            at: .beforePayloadMove(queued.id)
        )

        let failed = try await engine.run(queued.id)

        XCTAssertEqual(failed.state.phase, .failed)
        XCTAssertEqual(failed.state.failure?.code, .commitFailed)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: layout.payloadURL(for: queued.id).path
            )
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: layout.libraryURL(for: targetComicID).path
            )
        )
        XCTAssertTrue(try sandbox.sourceIsUnchanged(since: sourceSnapshot))
    }

    func testRestartAfterPreparedCheckpointPromotesPartialWithoutSourceAccess() async throws {
        let sandbox = try TemporaryImportSandbox(sourceName: "Prepared Checkpoint")
        let pageURL = try sandbox.sourceTree.png("Chapter/01.png")
        let sourceSnapshot = try sandbox.sourceSnapshot()
        let manifest = try await scan(sandbox)
        let layout = ImportStorageLayout(rootURL: sandbox.appManagedRootURL)
        let targetComicID = ManagedComicID(
            rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000090")!
        )
        let faultInjector = ScriptedFaultInjector()
        let engine = RecoverableImportEngine(
            layout: layout,
            sourceAccess: TestSourceAccess(rootURL: sandbox.sourceDirectoryURL),
            capacityProvider: FixedCapacityProvider(value: .max),
            thumbnailGenerator: TestThumbnailGenerator(),
            faultInjector: faultInjector
        )

        let queued = try await engine.enqueue(
            ImportPreviewDraft(manifest: manifest),
            sourceURL: sandbox.sourceDirectoryURL,
            targetComicID: targetComicID
        )
        let workItem = try XCTUnwrap(
            JSONImportJobStore(layout: layout).load(queued.id).plan.workItems.first
        )
        await faultInjector.set(
            .simulatedProcessInterruption,
            at: .afterPreparedCheckpoint(jobID: queued.id, pageID: workItem.id)
        )

        do {
            _ = try await engine.run(queued.id)
            XCTFail("Expected a simulated process interruption.")
        } catch let error as ImportInjectedFault {
            XCTAssertEqual(error, .simulatedProcessInterruption)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let interrupted = try JSONImportJobStore(layout: layout).load(queued.id)
        XCTAssertEqual(interrupted.journal.checkpoints[0].phase, .prepared)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: managedURL(
                    rootURL: layout.payloadURL(for: queued.id),
                    path: workItem.managedRelativePath
                ).appendingPathExtension("partial").path
            )
        )

        let restoredEngine = RecoverableImportEngine(
            layout: layout,
            sourceAccess: DenyingSourceAccess(rootURL: sandbox.sourceDirectoryURL),
            capacityProvider: FixedCapacityProvider(value: .max),
            thumbnailGenerator: TestThumbnailGenerator()
        )
        let restored = try await restoredEngine.restorePendingJobs()

        XCTAssertEqual(restored.map(\.state.phase), [.completed])
        XCTAssertEqual(
            try Data(contentsOf: managedURL(
                rootURL: layout.libraryURL(for: targetComicID),
                path: workItem.managedRelativePath
            )),
            try Data(contentsOf: pageURL)
        )
        XCTAssertTrue(try sandbox.sourceIsUnchanged(since: sourceSnapshot))
    }

    func testRestartAfterVerifiedCheckpointDoesNotCopySourceAgain() async throws {
        let sandbox = try TemporaryImportSandbox(sourceName: "Verified Checkpoint")
        let pageURL = try sandbox.sourceTree.png("Chapter/01.png")
        let sourceSnapshot = try sandbox.sourceSnapshot()
        let manifest = try await scan(sandbox)
        let layout = ImportStorageLayout(rootURL: sandbox.appManagedRootURL)
        let targetComicID = ManagedComicID(
            rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000095")!
        )
        let faultInjector = ScriptedFaultInjector()
        let engine = RecoverableImportEngine(
            layout: layout,
            sourceAccess: TestSourceAccess(rootURL: sandbox.sourceDirectoryURL),
            capacityProvider: FixedCapacityProvider(value: .max),
            thumbnailGenerator: TestThumbnailGenerator(),
            faultInjector: faultInjector
        )

        let queued = try await engine.enqueue(
            ImportPreviewDraft(manifest: manifest),
            sourceURL: sandbox.sourceDirectoryURL,
            targetComicID: targetComicID
        )
        let workItem = try XCTUnwrap(
            JSONImportJobStore(layout: layout).load(queued.id).plan.workItems.first
        )
        await faultInjector.set(
            .simulatedProcessInterruption,
            at: .afterVerifiedCheckpoint(jobID: queued.id, pageID: workItem.id)
        )

        do {
            _ = try await engine.run(queued.id)
            XCTFail("Expected a simulated process interruption.")
        } catch let error as ImportInjectedFault {
            XCTAssertEqual(error, .simulatedProcessInterruption)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let interrupted = try JSONImportJobStore(layout: layout).load(queued.id)
        XCTAssertEqual(interrupted.journal.checkpoints[0].phase, .verified)

        let restoredEngine = RecoverableImportEngine(
            layout: layout,
            sourceAccess: DenyingSourceAccess(rootURL: sandbox.sourceDirectoryURL),
            capacityProvider: FixedCapacityProvider(value: .max),
            thumbnailGenerator: TestThumbnailGenerator()
        )
        let restored = try await restoredEngine.restorePendingJobs()

        XCTAssertEqual(restored.map(\.state.phase), [.completed])
        XCTAssertEqual(
            try Data(contentsOf: managedURL(
                rootURL: layout.libraryURL(for: targetComicID),
                path: workItem.managedRelativePath
            )),
            try Data(contentsOf: pageURL)
        )
        XCTAssertTrue(try sandbox.sourceIsUnchanged(since: sourceSnapshot))
    }

    func testStagingCorruptionAfterCommitIntentReturnsToCopyOnResume() async throws {
        let sandbox = try TemporaryImportSandbox(sourceName: "Corrupted Staging")
        let pageURL = try sandbox.sourceTree.png("Chapter/01.png")
        let sourceBytes = try Data(contentsOf: pageURL)
        let sourceSnapshot = try sandbox.sourceSnapshot()
        let manifest = try await scan(sandbox)
        let layout = ImportStorageLayout(rootURL: sandbox.appManagedRootURL)
        let targetComicID = ManagedComicID(
            rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000100")!
        )
        let faultInjector = ScriptedFaultInjector()
        let engine = RecoverableImportEngine(
            layout: layout,
            sourceAccess: TestSourceAccess(rootURL: sandbox.sourceDirectoryURL),
            capacityProvider: FixedCapacityProvider(value: .max),
            thumbnailGenerator: TestThumbnailGenerator(),
            faultInjector: faultInjector
        )

        let queued = try await engine.enqueue(
            ImportPreviewDraft(manifest: manifest),
            sourceURL: sandbox.sourceDirectoryURL,
            targetComicID: targetComicID
        )
        let workItem = try XCTUnwrap(
            JSONImportJobStore(layout: layout).load(queued.id).plan.workItems.first
        )
        await faultInjector.set(
            .simulatedProcessInterruption,
            at: .afterCommitPrepared(queued.id)
        )

        do {
            _ = try await engine.run(queued.id)
            XCTFail("Expected a simulated process interruption.")
        } catch let error as ImportInjectedFault {
            XCTAssertEqual(error, .simulatedProcessInterruption)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let stagedURL = managedURL(
            rootURL: layout.payloadURL(for: queued.id),
            path: workItem.managedRelativePath
        )
        try Data(repeating: 0, count: sourceBytes.count).write(
            to: stagedURL,
            options: .atomic
        )

        let recoveryEngine = RecoverableImportEngine(
            layout: layout,
            sourceAccess: TestSourceAccess(rootURL: sandbox.sourceDirectoryURL),
            capacityProvider: FixedCapacityProvider(value: .max),
            thumbnailGenerator: TestThumbnailGenerator()
        )
        let corrupted = try await recoveryEngine.run(queued.id)
        let pausedJournal = try JSONImportJobStore(layout: layout).load(queued.id)

        XCTAssertEqual(corrupted.state.phase, .paused)
        XCTAssertEqual(corrupted.state.pause?.code, .stagingCorrupted)
        XCTAssertNotNil(pausedJournal.journal.commitIntent)

        let completed = try await recoveryEngine.resume(queued.id)

        XCTAssertEqual(completed.state.phase, .completed)
        XCTAssertEqual(
            try Data(contentsOf: managedURL(
                rootURL: layout.libraryURL(for: targetComicID),
                path: workItem.managedRelativePath
            )),
            sourceBytes
        )
        XCTAssertTrue(try sandbox.sourceIsUnchanged(since: sourceSnapshot))
    }

    func testInterruptedJobCreationDirectoryIsNotRestoredAsAnImport() throws {
        let sandbox = try TemporaryImportSandbox(sourceName: "Interrupted Create")
        let layout = ImportStorageLayout(rootURL: sandbox.appManagedRootURL)
        let store = JSONImportJobStore(layout: layout)
        let jobID = ImportJobID(
            rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000110")!
        )
        let creatingDirectory = layout.creatingJobDirectory(for: jobID)

        try FileManager.default.createDirectory(
            at: creatingDirectory,
            withIntermediateDirectories: true
        )
        try Data("incomplete".utf8).write(
            to: creatingDirectory.appendingPathComponent("plan.json"),
            options: .atomic
        )

        XCTAssertEqual(try store.jobIDs(), [])
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: creatingDirectory.path)
        )
    }

    func testOneFailedJobDoesNotBlockAnotherQueuedJob() async throws {
        let firstSandbox = try TemporaryImportSandbox(sourceName: "First Batch Comic")
        try firstSandbox.sourceTree.png("Chapter/01.png")
        let firstSourceSnapshot = try firstSandbox.sourceSnapshot()
        let secondSource = try TemporaryComicTree(name: "Second Batch Comic")
        let secondPageURL = try secondSource.png("Chapter/01.png")
        let secondSourceBytes = try Data(contentsOf: secondPageURL)
        let firstManifest = try await scan(firstSandbox)
        let secondManifest = try await scan(rootURL: secondSource.rootURL)
        let layout = ImportStorageLayout(rootURL: firstSandbox.appManagedRootURL)
        let faultInjector = ScriptedFaultInjector()
        let engine = RecoverableImportEngine(
            layout: layout,
            sourceAccess: MappedSourceAccess(sourceURLs: [
                firstSandbox.sourceDirectoryURL,
                secondSource.rootURL,
            ]),
            capacityProvider: FixedCapacityProvider(value: .max),
            thumbnailGenerator: TestThumbnailGenerator(),
            faultInjector: faultInjector
        )
        let firstComicID = ManagedComicID(
            rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000120")!
        )
        let secondComicID = ManagedComicID(
            rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000121")!
        )

        let firstJob = try await engine.enqueue(
            ImportPreviewDraft(manifest: firstManifest),
            sourceURL: firstSandbox.sourceDirectoryURL,
            targetComicID: firstComicID
        )
        let secondJob = try await engine.enqueue(
            ImportPreviewDraft(manifest: secondManifest),
            sourceURL: secondSource.rootURL,
            targetComicID: secondComicID
        )
        let firstWorkItem = try XCTUnwrap(
            JSONImportJobStore(layout: layout).load(firstJob.id).plan.workItems.first
        )
        await faultInjector.set(
            .copyFailed,
            at: .beforeCopy(jobID: firstJob.id, pageID: firstWorkItem.id)
        )

        async let firstResult = engine.run(firstJob.id)
        async let secondResult = engine.run(secondJob.id)
        let (firstPaused, secondCompleted) = try await (firstResult, secondResult)

        XCTAssertEqual(firstPaused.state.pause?.code, .copyFailed)
        XCTAssertEqual(secondCompleted.state.phase, .completed)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: layout.libraryURL(for: firstComicID).path
            )
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: layout.libraryURL(for: secondComicID).path
            )
        )
        XCTAssertTrue(try firstSandbox.sourceIsUnchanged(since: firstSourceSnapshot))
        XCTAssertEqual(try Data(contentsOf: secondPageURL), secondSourceBytes)
    }

    private func scan(_ sandbox: TemporaryImportSandbox) async throws -> ImportManifest {
        try await scan(rootURL: sandbox.sourceDirectoryURL)
    }

    private func scan(rootURL: URL) async throws -> ImportManifest {
        try await ImportScanner().scan(
            ImportScanRequest(
                rootURL: rootURL,
                locale: Locale(identifier: "en_US_POSIX")
            )
        )
    }

    private func libraryURL(
        rootURL: URL,
        components: [String]
    ) -> URL {
        components.reduce(
            rootURL
        ) { url, component in
            url.appendingPathComponent(component)
        }
    }

    private func managedURL(
        rootURL: URL,
        path: ManagedRelativePath
    ) -> URL {
        path.components.reduce(rootURL) { url, component in
            url.appendingPathComponent(component)
        }
    }
}

private struct TestSourceAccess: ImportSourceAccessing {
    let rootURL: URL

    func makeBookmark(for sourceURL: URL) throws -> Data {
        Data("test-bookmark".utf8)
    }

    func resolveBookmark(_ bookmark: Data) throws -> URL {
        rootURL
    }

    func startAccessing(_ sourceURL: URL) throws {}

    func stopAccessing(_ sourceURL: URL) {}
}

private struct DenyingSourceAccess: ImportSourceAccessing {
    let rootURL: URL

    func makeBookmark(for sourceURL: URL) throws -> Data {
        Data("test-bookmark".utf8)
    }

    func resolveBookmark(_ bookmark: Data) throws -> URL {
        rootURL
    }

    func startAccessing(_ sourceURL: URL) throws {
        throw ImportSourceAccessError.accessDenied
    }

    func stopAccessing(_ sourceURL: URL) {}
}

private struct MappedSourceAccess: ImportSourceAccessing {
    let sourceURLs: [URL]

    func makeBookmark(for sourceURL: URL) throws -> Data {
        guard let index = sourceURLs.firstIndex(of: sourceURL) else {
            throw ImportSourceAccessError.invalidBookmark
        }

        return Data(String(index).utf8)
    }

    func resolveBookmark(_ bookmark: Data) throws -> URL {
        guard let value = String(data: bookmark, encoding: .utf8),
              let index = Int(value),
              sourceURLs.indices.contains(index) else {
            throw ImportSourceAccessError.invalidBookmark
        }

        return sourceURLs[index]
    }

    func startAccessing(_ sourceURL: URL) throws {}

    func stopAccessing(_ sourceURL: URL) {}
}

private actor ScriptedFaultInjector: ImportExecutionFaultInjecting {
    private var faults: [ImportExecutionFaultPoint: ImportInjectedFault] = [:]

    func set(
        _ fault: ImportInjectedFault,
        at point: ImportExecutionFaultPoint
    ) {
        faults[point] = fault
    }

    func reach(_ point: ImportExecutionFaultPoint) async throws {
        guard let fault = faults.removeValue(forKey: point) else {
            return
        }

        throw fault
    }
}

private actor BlockingCommitFaultInjector: ImportExecutionFaultInjecting {
    private var hasReachedCommitBoundary = false
    private var isReleased = false
    private var reachWaiters: [CheckedContinuation<Bool, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func reach(_ point: ImportExecutionFaultPoint) async throws {
        guard case .beforeCommitIntent = point else {
            return
        }

        hasReachedCommitBoundary = true
        let waiters = reachWaiters
        reachWaiters.removeAll()
        for waiter in waiters {
            waiter.resume(returning: true)
        }

        guard !isReleased else {
            return
        }

        await withCheckedContinuation { continuation in
            releaseWaiters.append(continuation)
        }
    }

    func waitUntilCommitBoundary() async -> Bool {
        guard !hasReachedCommitBoundary else {
            return true
        }

        return await withCheckedContinuation { continuation in
            reachWaiters.append(continuation)
        }
    }

    func expireCommitBoundaryWaiters() {
        let waiters = reachWaiters
        reachWaiters.removeAll()
        for waiter in waiters {
            waiter.resume(returning: false)
        }
    }

    func release() {
        isReleased = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }
}

private struct FixedCapacityProvider: ImportCapacityProviding {
    let value: Int64

    func availableBytes(at destinationRoot: URL) throws -> Int64 {
        value
    }
}

private struct TestThumbnailGenerator: ImportThumbnailGenerating {
    func generate(from coverURL: URL, to thumbnailURL: URL) async throws {
        try FileManager.default.createDirectory(
            at: thumbnailURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("thumbnail".utf8).write(to: thumbnailURL, options: .atomic)
    }
}

private struct FailingThumbnailGenerator: ImportThumbnailGenerating {
    func generate(from coverURL: URL, to thumbnailURL: URL) async throws {
        throw ImportThumbnailError.destinationCannotBeCreated
    }
}
