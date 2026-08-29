import Foundation

enum RecoverableImportEngineError: Error, Equatable, Sendable {
    case jobUnavailable
    case persistenceUnavailable
}

actor RecoverableImportEngine {
    private let store: JSONImportJobStore
    private let sourceAccess: any ImportSourceAccessing
    private let capacityProvider: any ImportCapacityProviding
    private let fileCopier: ImportFileCopier
    private let thumbnailGenerator: any ImportThumbnailGenerating
    private let faultInjector: any ImportExecutionFaultInjecting
    private var activeJobIDs = Set<ImportJobID>()
    private var cancellationTokens: [ImportJobID: ImportCancellationToken] = [:]

    init(
        layout: ImportStorageLayout,
        sourceAccess: any ImportSourceAccessing = SecurityScopedSourceAccess(),
        capacityProvider: any ImportCapacityProviding = ImportantUsageCapacityProvider(),
        fileCopier: ImportFileCopier = ImportFileCopier(),
        thumbnailGenerator: any ImportThumbnailGenerating = ImageIOImportThumbnailGenerator(),
        faultInjector: any ImportExecutionFaultInjecting = NoImportExecutionFaultInjector()
    ) {
        store = JSONImportJobStore(layout: layout)
        self.sourceAccess = sourceAccess
        self.capacityProvider = capacityProvider
        self.fileCopier = fileCopier
        self.thumbnailGenerator = thumbnailGenerator
        self.faultInjector = faultInjector
    }

    func enqueue(
        _ draft: ImportPreviewDraft,
        sourceURL: URL,
        targetComicID: ManagedComicID = ManagedComicID()
    ) throws -> ImportJobSnapshot {
        let bookmark = try sourceAccess.makeBookmark(for: sourceURL)
        return try enqueue(
            draft,
            sourceBookmark: bookmark,
            targetComicID: targetComicID
        )
    }

    func enqueue(
        _ draft: ImportPreviewDraft,
        sourceBookmark: Data,
        targetComicID: ManagedComicID = ManagedComicID()
    ) throws -> ImportJobSnapshot {
        let plan = try draft.freeze(sourceBookmark: sourceBookmark)
        return try enqueue(plan, targetComicID: targetComicID)
    }

    func enqueue(
        _ plan: FrozenImportPlan,
        targetComicID: ManagedComicID = ManagedComicID()
    ) throws -> ImportJobSnapshot {
        let journal = try store.create(
            plan: plan,
            targetComicID: targetComicID
        )
        return journal.snapshot(using: plan)
    }

    func snapshot(for jobID: ImportJobID) throws -> ImportJobSnapshot {
        let loaded = try load(jobID)
        return loaded.journal.snapshot(using: loaded.plan)
    }

    func run(_ jobID: ImportJobID) async throws -> ImportJobSnapshot {
        guard !activeJobIDs.contains(jobID) else {
            return try snapshot(for: jobID)
        }

        activeJobIDs.insert(jobID)
        let cancellationToken = ImportCancellationToken()
        cancellationTokens[jobID] = cancellationToken
        defer {
            activeJobIDs.remove(jobID)
            cancellationTokens.removeValue(forKey: jobID)
        }

        let loaded = try load(jobID)
        var journal = loaded.journal
        let plan = loaded.plan

        switch journal.state.phase {
        case .completed, .failed, .paused:
            return journal.snapshot(using: plan)
        case .queued, .checkingSpace, .copying, .verifying, .commitPrepared,
                .committing, .generatingThumbnail:
            break
        }

        if cancellationRequested(for: jobID, journal: journal) {
            journal.cancellationRequested = true
            journal.state = .paused(.userCancelled)
            try persist(journal, for: plan)
            return journal.snapshot(using: plan)
        }

        if journal.state.phase == .commitPrepared
            || journal.state.phase == .committing
            || journal.state.phase == .generatingThumbnail {
            return try await finishCommit(
                plan: plan,
                journal: journal
            )
        }

        journal = try await reconcileStaging(
            plan: plan,
            journal: journal,
            cancellationToken: cancellationToken
        )
        if journal.state.phase == .paused || journal.state.phase == .failed {
            return journal.snapshot(using: plan)
        }

        if allWorkItemsAreVerified(in: journal) {
            return try await finishCommit(
                plan: plan,
                journal: journal
            )
        }

        journal.state = .checkingSpace
        journal.cancellationRequested = cancellationRequested(
            for: jobID,
            journal: journal
        )
        try persist(journal, for: plan)

        if journal.cancellationRequested {
            journal.state = .paused(.userCancelled)
            try persist(journal, for: plan)
            return journal.snapshot(using: plan)
        }

        let remainingEstimate = remainingSpaceEstimate(
            for: plan,
            journal: journal
        )

        do {
            let availableBytes = try capacityProvider.availableBytes(
                at: store.layout.rootURL
            )
            guard availableBytes >= remainingEstimate.requiredAvailableBytes else {
                journal.state = .paused(
                    .insufficientSpace(
                        requiredBytes: remainingEstimate.requiredAvailableBytes,
                        availableBytes: availableBytes
                    )
                )
                try persist(journal, for: plan)
                return journal.snapshot(using: plan)
            }
        } catch {
            journal.state = .paused(
                .insufficientSpace(
                    requiredBytes: remainingEstimate.requiredAvailableBytes,
                    availableBytes: 0
                )
            )
            try persist(journal, for: plan)
            return journal.snapshot(using: plan)
        }

        journal = try await copyPendingWorkItems(
            plan: plan,
            journal: journal,
            cancellationToken: cancellationToken
        )
        if journal.state.phase == .paused || journal.state.phase == .failed {
            return journal.snapshot(using: plan)
        }

        return try await finishCommit(
            plan: plan,
            journal: journal
        )
    }

    func cancel(_ jobID: ImportJobID) throws -> ImportJobSnapshot {
        let loaded = try load(jobID)
        var journal = loaded.journal

        switch journal.state.phase {
        case .completed, .failed, .commitPrepared, .committing, .generatingThumbnail:
            return journal.snapshot(using: loaded.plan)
        case .queued, .checkingSpace, .copying, .verifying, .paused:
            journal.cancellationRequested = true
            if !activeJobIDs.contains(jobID) {
                journal.state = .paused(.userCancelled)
            }
            try persist(journal, for: loaded.plan)
            cancellationTokens[jobID]?.cancel()
            return journal.snapshot(using: loaded.plan)
        }
    }

    func resume(_ jobID: ImportJobID) async throws -> ImportJobSnapshot {
        let loaded = try load(jobID)
        var journal = loaded.journal

        guard journal.state.phase == .paused else {
            return journal.snapshot(using: loaded.plan)
        }

        journal.cancellationRequested = false
        prepareForResume(&journal, plan: loaded.plan)
        try persist(journal, for: loaded.plan)
        return try await run(jobID)
    }

    func storedJobSnapshots() throws -> [ImportJobSnapshot] {
        let jobIDs = try store.jobIDs()

        return jobIDs.compactMap { jobID in
            try? snapshot(for: jobID)
        }
    }

    func restorePendingJobs() async throws -> [ImportJobSnapshot] {
        let jobIDs = try store.jobIDs()

        var snapshots: [ImportJobSnapshot] = []

        for jobID in jobIDs {
            guard let loaded = try? load(jobID) else {
                continue
            }

            var journal = loaded.journal

            switch journal.state.phase {
            case .completed, .failed:
                snapshots.append(journal.snapshot(using: loaded.plan))
            case .paused:
                if journal.state.pause?.code == .userCancelled {
                    snapshots.append(journal.snapshot(using: loaded.plan))
                } else {
                    journal.cancellationRequested = false
                    prepareForResume(&journal, plan: loaded.plan)
                    do {
                        try persist(journal, for: loaded.plan)
                        let snapshot = try await run(jobID)
                        snapshots.append(snapshot)
                    } catch {
                        continue
                    }
                }
            case .queued:
                if let snapshot = try? await run(jobID) {
                    snapshots.append(snapshot)
                }
            case .checkingSpace, .copying, .verifying:
                journal.state = journal.cancellationRequested
                    ? .paused(.userCancelled)
                    : .queued
                do {
                    try persist(journal, for: loaded.plan)
                    let snapshot = try await run(jobID)
                    snapshots.append(snapshot)
                } catch {
                    continue
                }
            case .commitPrepared, .committing, .generatingThumbnail:
                if let snapshot = try? await run(jobID) {
                    snapshots.append(snapshot)
                }
            }
        }

        return snapshots
    }

    private func copyPendingWorkItems(
        plan: FrozenImportPlan,
        journal: ImportJobJournal,
        cancellationToken: ImportCancellationToken
    ) async throws -> ImportJobJournal {
        var journal = journal
        let sourceRootURL: URL

        do {
            sourceRootURL = try sourceAccess.resolveBookmark(plan.sourceBookmark)
            try sourceAccess.startAccessing(sourceRootURL)
        } catch {
            journal.state = .paused(.permissionLost)
            try persist(journal, for: plan)
            return journal
        }
        defer { sourceAccess.stopAccessing(sourceRootURL) }

        for workItem in plan.workItems {
            guard checkpoint(for: workItem.id, in: journal)?.phase != .verified else {
                continue
            }

            if cancellationRequested(for: plan.id, journal: journal) {
                journal.cancellationRequested = true
                journal.state = .paused(.userCancelled)
                try persist(journal, for: plan)
                return journal
            }

            let finalURL = stagedWorkItemURL(
                for: workItem,
                jobID: plan.id
            )
            let partialURL = finalURL.appendingPathExtension("partial")
            let sourceURL = sourceURL(
                rootURL: sourceRootURL,
                sourceRelativePath: workItem.sourceRelativePath
            )

            do {
                journal.state = .copying
                journal.cancellationRequested = cancellationRequested(
                    for: plan.id,
                    journal: journal
                )
                try persist(journal, for: plan)
                try await reachCopyFaultPoint(
                    .beforeCopy(jobID: plan.id, pageID: workItem.id)
                )

                let verification = try await fileCopier.copySource(
                    from: sourceURL,
                    to: partialURL,
                    workItem: workItem,
                    cancellationToken: cancellationToken
                )
                if cancellationRequested(for: plan.id, journal: journal) {
                    throw ImportCopyError.cancelled
                }

                journal.state = .verifying
                try persist(journal, for: plan)
                try await fileCopier.verifyPartial(
                    at: partialURL,
                    expected: verification,
                    cancellationToken: cancellationToken
                )
                if cancellationRequested(for: plan.id, journal: journal) {
                    throw ImportCopyError.cancelled
                }

                guard journal.markPrepared(verification, for: workItem.id) else {
                    journal.state = .failed(.invalidPlan)
                    try persist(journal, for: plan)
                    return journal
                }
                try persist(journal, for: plan)
                try await reachCopyFaultPoint(
                    .afterPreparedCheckpoint(jobID: plan.id, pageID: workItem.id)
                )

                guard !FileManager.default.fileExists(atPath: finalURL.path) else {
                    throw ImportCopyError.verificationFailed
                }
                try FileManager.default.moveItem(at: partialURL, to: finalURL)

                guard journal.markVerified(verification, for: workItem.id) else {
                    journal.state = .failed(.invalidPlan)
                    try persist(journal, for: plan)
                    return journal
                }
                try persist(journal, for: plan)
                try await reachCopyFaultPoint(
                    .afterVerifiedCheckpoint(jobID: plan.id, pageID: workItem.id)
                )
            } catch let error as ImportInjectedFault where error == .simulatedProcessInterruption {
                throw error
            } catch let error as ImportCopyError {
                switch error {
                case .cancelled:
                    journal.cancellationRequested = true
                    journal.state = .paused(.userCancelled)
                case .sourceChanged:
                    journal.state = .paused(
                        .sourceChanged(workItem.sourceRelativePath)
                    )
                case .sourceUnavailable:
                    journal.state = .paused(.permissionLost)
                case .verificationFailed, .copyFailed:
                    journal.runtimeIssues.append(
                        .copyFailed(workItem.sourceRelativePath)
                    )
                    journal.state = .paused(
                        .copyFailed(workItem.sourceRelativePath)
                    )
                }
                try persist(journal, for: plan)
                return journal
            } catch {
                journal.runtimeIssues.append(
                    .copyFailed(workItem.sourceRelativePath)
                )
                journal.state = .paused(.copyFailed(workItem.sourceRelativePath))
                try persist(journal, for: plan)
                return journal
            }
        }

        return journal
    }

    private func reconcileStaging(
        plan: FrozenImportPlan,
        journal: ImportJobJournal,
        cancellationToken: ImportCancellationToken
    ) async throws -> ImportJobJournal {
        var journal = journal

        for workItem in plan.workItems {
            guard let checkpoint = checkpoint(for: workItem.id, in: journal) else {
                journal.state = .failed(.invalidPlan)
                try persist(journal, for: plan)
                return journal
            }

            let finalURL = stagedWorkItemURL(
                for: workItem,
                jobID: plan.id
            )
            let partialURL = finalURL.appendingPathExtension("partial")

            switch checkpoint.phase {
            case .pending:
                if FileManager.default.fileExists(atPath: finalURL.path) {
                    try? FileManager.default.removeItem(at: finalURL)
                }
            case .prepared:
                guard let verification = checkpoint.verification else {
                    journal.state = .failed(.invalidPlan)
                    try persist(journal, for: plan)
                    return journal
                }

                let finalIsValid = await fileCopier.verifyExisting(
                    at: finalURL,
                    expected: verification,
                    cancellationToken: cancellationToken
                )
                if cancellationRequested(for: plan.id, journal: journal) {
                    journal.cancellationRequested = true
                    journal.state = .paused(.userCancelled)
                    try persist(journal, for: plan)
                    return journal
                }
                if finalIsValid {
                    _ = journal.markVerified(verification, for: workItem.id)
                    try? FileManager.default.removeItem(at: partialURL)
                    try persist(journal, for: plan)
                    continue
                }

                let partialIsValid = await fileCopier.verifyExisting(
                    at: partialURL,
                    expected: verification,
                    cancellationToken: cancellationToken
                )
                if cancellationRequested(for: plan.id, journal: journal) {
                    journal.cancellationRequested = true
                    journal.state = .paused(.userCancelled)
                    try persist(journal, for: plan)
                    return journal
                }
                if partialIsValid {
                    try FileManager.default.createDirectory(
                        at: finalURL.deletingLastPathComponent(),
                        withIntermediateDirectories: true
                    )
                    try? FileManager.default.removeItem(at: finalURL)
                    try FileManager.default.moveItem(at: partialURL, to: finalURL)
                    _ = journal.markVerified(verification, for: workItem.id)
                    try persist(journal, for: plan)
                    continue
                }

                _ = journal.resetCheckpoint(for: workItem.id)
                try? FileManager.default.removeItem(at: partialURL)
                try persist(journal, for: plan)
            case .verified:
                guard let verification = checkpoint.verification else {
                    journal.state = .failed(.invalidPlan)
                    try persist(journal, for: plan)
                    return journal
                }

                let finalIsValid = await fileCopier.verifyExisting(
                    at: finalURL,
                    expected: verification,
                    cancellationToken: cancellationToken
                )
                if cancellationRequested(for: plan.id, journal: journal) {
                    journal.cancellationRequested = true
                    journal.state = .paused(.userCancelled)
                    try persist(journal, for: plan)
                    return journal
                }
                guard finalIsValid else {
                    _ = journal.resetCheckpoint(for: workItem.id)
                    try? FileManager.default.removeItem(at: finalURL)
                    try persist(journal, for: plan)
                    continue
                }
            }
        }

        return journal
    }

    private func finishCommit(
        plan: FrozenImportPlan,
        journal: ImportJobJournal
    ) async throws -> ImportJobSnapshot {
        var journal = journal
        let payloadURL = store.layout.payloadURL(for: plan.id)
        let libraryURL = store.layout.libraryURL(for: journal.targetComicID)
        let rootURL = FileManager.default.fileExists(atPath: payloadURL.path)
            ? payloadURL
            : libraryURL
        let cancellationToken = cancellationTokens[plan.id]
            ?? ImportCancellationToken()

        guard allWorkItemsAreVerified(in: journal) else {
            journal.state = .paused(.stagingCorrupted(plan.coverPageIDPath))
            try persist(journal, for: plan)
            return journal.snapshot(using: plan)
        }

        if journal.commitIntent == nil,
           cancellationRequested(for: plan.id, journal: journal) {
            return try pauseForCancellation(journal, plan: plan)
        }

        guard await verifyStagedWorkItems(
            in: plan,
            journal: journal,
            rootURL: rootURL,
            cancellationToken: cancellationToken
        ) else {
            if journal.commitIntent == nil,
               cancellationRequested(for: plan.id, journal: journal) {
                return try pauseForCancellation(journal, plan: plan)
            }
            journal.state = .paused(.stagingCorrupted(plan.coverPageIDPath))
            try persist(journal, for: plan)
            return journal.snapshot(using: plan)
        }

        guard await verifyReadablePages(in: plan, rootURL: rootURL) else {
            if journal.commitIntent == nil,
               cancellationRequested(for: plan.id, journal: journal) {
                return try pauseForCancellation(journal, plan: plan)
            }
            journal.state = .paused(.stagingCorrupted(plan.coverPageIDPath))
            try persist(journal, for: plan)
            return journal.snapshot(using: plan)
        }

        let receipt = ImportCommitReceipt(
            jobID: plan.id,
            targetComicID: journal.targetComicID,
            revision: plan.revision
        )

        if journal.commitIntent == nil {
            if cancellationRequested(for: plan.id, journal: journal) {
                return try pauseForCancellation(journal, plan: plan)
            }

            do {
                try await faultInjector.reach(.beforeCommitIntent(plan.id))
            } catch let error as ImportInjectedFault where error == .simulatedProcessInterruption {
                throw error
            } catch {
                journal.state = .failed(.commitFailed)
                try persist(journal, for: plan)
                return journal.snapshot(using: plan)
            }

            if cancellationRequested(for: plan.id, journal: journal) {
                return try pauseForCancellation(journal, plan: plan)
            }

            do {
                try writePayloadMetadata(
                    plan: plan,
                    journal: journal,
                    receipt: receipt,
                    at: payloadURL
                )
                journal.commitIntent = ImportCommitIntent(
                    jobID: plan.id,
                    targetComicID: journal.targetComicID,
                    revision: plan.revision
                )
                journal.state = .commitPrepared
                try persist(journal, for: plan)
            } catch {
                journal.state = .failed(.stagingUnavailable)
                try persist(journal, for: plan)
                return journal.snapshot(using: plan)
            }

            do {
                try await faultInjector.reach(.afterCommitPrepared(plan.id))
            } catch let error as ImportInjectedFault where error == .simulatedProcessInterruption {
                throw error
            } catch {
                journal.state = .failed(.commitFailed)
                try persist(journal, for: plan)
                return journal.snapshot(using: plan)
            }
        }

        if FileManager.default.fileExists(atPath: libraryURL.path) {
            guard receiptMatches(receipt, in: libraryURL) else {
                journal.state = .paused(.commitConflict)
                try persist(journal, for: plan)
                return journal.snapshot(using: plan)
            }
        } else {
            guard FileManager.default.fileExists(atPath: payloadURL.path) else {
                journal.state = .failed(.stagingUnavailable)
                try persist(journal, for: plan)
                return journal.snapshot(using: plan)
            }

            do {
                try await faultInjector.reach(.beforePayloadMove(plan.id))
            } catch let error as ImportInjectedFault where error == .simulatedProcessInterruption {
                throw error
            } catch {
                journal.state = .failed(.commitFailed)
                try persist(journal, for: plan)
                return journal.snapshot(using: plan)
            }

            do {
                journal.state = .committing
                try persist(journal, for: plan)
                try FileManager.default.moveItem(at: payloadURL, to: libraryURL)
            } catch {
                journal.state = .failed(.commitFailed)
                try persist(journal, for: plan)
                return journal.snapshot(using: plan)
            }

            do {
                try await faultInjector.reach(.afterPayloadMoved(plan.id))
            } catch let error as ImportInjectedFault where error == .simulatedProcessInterruption {
                throw error
            } catch {
                throw ImportInjectedFault.simulatedProcessInterruption
            }
        }

        if journal.thumbnailStatus == .notStarted {
            journal.state = .generatingThumbnail
            try persist(journal, for: plan)

            if let coverWorkItem = plan.workItems.first(where: {
                $0.id == plan.coverPageID
            }) {
                do {
                    try await faultInjector.reach(.beforeThumbnail(plan.id))
                    try await thumbnailGenerator.generate(
                        from: libraryWorkItemURL(
                            for: coverWorkItem,
                            comicID: journal.targetComicID
                        ),
                        to: store.layout.thumbnailURL(for: journal.targetComicID)
                    )
                    journal.thumbnailStatus = .generated
                } catch let error as ImportInjectedFault where error == .simulatedProcessInterruption {
                    throw error
                } catch {
                    journal.thumbnailStatus = .failed
                    journal.runtimeIssues.append(.thumbnailFailed)
                }
            } else {
                journal.thumbnailStatus = .failed
                journal.runtimeIssues.append(.thumbnailFailed)
            }
        }

        journal.finalizeReport(with: plan)
        journal.state = .completed
        try persist(journal, for: plan)
        try? write(
            journal.report,
            to: libraryURL
                .appendingPathComponent("metadata", isDirectory: true)
                .appendingPathComponent("import-report.json")
        )

        return journal.snapshot(using: plan)
    }

    private func verifyReadablePages(
        in plan: FrozenImportPlan,
        rootURL: URL
    ) async -> Bool {
        for workItem in plan.workItems where workItem.pageState == .readable {
            if !(await fileCopier.verifyReadableImage(
                at: managedWorkItemURL(
                    rootURL: rootURL,
                    managedRelativePath: workItem.managedRelativePath
                ),
                workItem: workItem
            )) {
                return false
            }
        }

        return true
    }

    private func verifyStagedWorkItems(
        in plan: FrozenImportPlan,
        journal: ImportJobJournal,
        rootURL: URL,
        cancellationToken: ImportCancellationToken
    ) async -> Bool {
        for workItem in plan.workItems {
            guard let checkpoint = checkpoint(for: workItem.id, in: journal),
                  let verification = checkpoint.verification,
                  await fileCopier.verifyExisting(
                      at: managedWorkItemURL(
                          rootURL: rootURL,
                          managedRelativePath: workItem.managedRelativePath
                      ),
                      expected: verification,
                      cancellationToken: cancellationToken
                  ) else {
                return false
            }
        }

        return true
    }

    private func pauseForCancellation(
        _ journal: ImportJobJournal,
        plan: FrozenImportPlan
    ) throws -> ImportJobSnapshot {
        var journal = journal
        journal.cancellationRequested = true
        journal.state = .paused(.userCancelled)
        try persist(journal, for: plan)
        return journal.snapshot(using: plan)
    }

    private func remainingSpaceEstimate(
        for plan: FrozenImportPlan,
        journal: ImportJobJournal
    ) -> ImportSpaceEstimate {
        let verifiedIDs = Set(journal.verifiedWorkItemIDs)
        let remainingWorkItems = plan.workItems.filter {
            !verifiedIDs.contains($0.id)
        }
        let contentBytes = remainingWorkItems.reduce(Int64(0)) {
            result,
            workItem in
            let sum = result.addingReportingOverflow(
                max(0, workItem.expectedByteCount)
            )
            return sum.overflow ? Int64.max : sum.partialValue
        }

        return .make(
            contentBytes: contentBytes,
            fileCount: remainingWorkItems.count
        )
    }

    private func allWorkItemsAreVerified(in journal: ImportJobJournal) -> Bool {
        journal.checkpoints.allSatisfy { $0.phase == .verified }
    }

    private func prepareForResume(
        _ journal: inout ImportJobJournal,
        plan: FrozenImportPlan
    ) {
        let hasStagedPayload = FileManager.default.fileExists(
            atPath: store.layout.payloadURL(for: plan.id).path
        )
        let hasPublishedLibrary = FileManager.default.fileExists(
            atPath: store.layout.libraryURL(for: journal.targetComicID).path
        )

        if journal.state.pause?.code == .stagingCorrupted,
           journal.commitIntent != nil,
           hasStagedPayload,
           !hasPublishedLibrary {
            journal.commitIntent = nil
            journal.state = .queued
            return
        }

        journal.state = journal.commitIntent == nil ? .queued : .commitPrepared
    }

    private func checkpoint(
        for pageID: ImportPageCandidate.ID,
        in journal: ImportJobJournal
    ) -> ImportWorkItemCheckpoint? {
        journal.checkpoints.first { $0.id == pageID }
    }

    private func cancellationRequested(
        for jobID: ImportJobID,
        journal: ImportJobJournal
    ) -> Bool {
        guard !journal.cancellationRequested else {
            return true
        }

        return (try? store.load(jobID).journal.cancellationRequested) ?? false
    }

    private func reachCopyFaultPoint(
        _ point: ImportExecutionFaultPoint
    ) async throws {
        do {
            try await faultInjector.reach(point)
        } catch let error as ImportInjectedFault {
            switch error {
            case .simulatedProcessInterruption:
                throw error
            case .copyFailed, .commitMoveFailed:
                throw ImportCopyError.copyFailed
            }
        }
    }

    private func stagedWorkItemURL(
        for workItem: FrozenImportWorkItem,
        jobID: ImportJobID
    ) -> URL {
        managedWorkItemURL(
            rootURL: store.layout.payloadURL(for: jobID),
            managedRelativePath: workItem.managedRelativePath
        )
    }

    private func libraryWorkItemURL(
        for workItem: FrozenImportWorkItem,
        comicID: ManagedComicID
    ) -> URL {
        managedWorkItemURL(
            rootURL: store.layout.libraryURL(for: comicID),
            managedRelativePath: workItem.managedRelativePath
        )
    }

    private func sourceURL(
        rootURL: URL,
        sourceRelativePath: SourceRelativePath
    ) -> URL {
        sourceRelativePath.components.reduce(rootURL) { url, component in
            url.appendingPathComponent(component)
        }
    }

    private func managedWorkItemURL(
        rootURL: URL,
        managedRelativePath: ManagedRelativePath
    ) -> URL {
        managedRelativePath.components.reduce(rootURL) { url, component in
            url.appendingPathComponent(component)
        }
    }

    private func load(
        _ jobID: ImportJobID
    ) throws -> (plan: FrozenImportPlan, journal: ImportJobJournal) {
        do {
            return try store.load(jobID)
        } catch ImportJobStoreError.jobNotFound {
            throw RecoverableImportEngineError.jobUnavailable
        } catch {
            throw RecoverableImportEngineError.persistenceUnavailable
        }
    }

    private func persist(
        _ journal: ImportJobJournal,
        for plan: FrozenImportPlan
    ) throws {
        do {
            try store.save(journal, for: plan)
        } catch {
            throw RecoverableImportEngineError.persistenceUnavailable
        }
    }

    private func writePayloadMetadata(
        plan: FrozenImportPlan,
        journal: ImportJobJournal,
        receipt: ImportCommitReceipt,
        at payloadURL: URL
    ) throws {
        let metadataURL = payloadURL.appendingPathComponent(
            "metadata",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: metadataURL,
            withIntermediateDirectories: true
        )
        try write(
            ManagedComicDescriptor(plan: plan, journal: journal),
            to: metadataURL.appendingPathComponent("import-descriptor.json")
        )
        // The complete descriptor can recreate this display-only catalog record.
        try? write(
            LibraryCatalogRecord(plan: plan, journal: journal),
            to: metadataURL.appendingPathComponent("library-catalog.json")
        )
        try write(
            ComicSourceAuthorization(
                comicID: journal.targetComicID,
                sourceRootName: plan.sourceRootName,
                bookmark: plan.sourceBookmark
            ),
            to: metadataURL.appendingPathComponent("source-authorization.json")
        )
        try write(
            receipt,
            to: metadataURL.appendingPathComponent("commit-receipt.json")
        )
    }

    private func receiptMatches(
        _ expectedReceipt: ImportCommitReceipt,
        in libraryURL: URL
    ) -> Bool {
        let receiptURL = libraryURL
            .appendingPathComponent("metadata", isDirectory: true)
            .appendingPathComponent("commit-receipt.json")

        guard let data = try? Data(contentsOf: receiptURL),
              let actualReceipt = try? JSONDecoder().decode(
                  ImportCommitReceipt.self,
                  from: data
              ) else {
            return false
        }

        return actualReceipt == expectedReceipt
    }

    private func write<Value: Encodable>(
        _ value: Value?,
        to url: URL
    ) throws {
        guard let value else {
            return
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(value)
        try data.write(to: url, options: .atomic)
    }
}

private struct ImportCommitReceipt: Codable, Equatable {
    let jobID: ImportJobID
    let targetComicID: ManagedComicID
    let revision: ImportPreviewRevision
}

private extension FrozenImportPlan {
    var coverPageIDPath: SourceRelativePath {
        workItems.first(where: { $0.id == coverPageID })?.sourceRelativePath
            ?? .root
    }
}
