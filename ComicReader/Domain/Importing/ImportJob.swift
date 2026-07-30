import Foundation

struct ManagedComicID: Codable, Equatable, Hashable, Identifiable, Sendable {
    let rawValue: UUID

    var id: UUID {
        rawValue
    }

    init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

enum ImportJobPhase: String, Codable, Equatable, Sendable {
    case queued
    case checkingSpace
    case copying
    case verifying
    case paused
    case commitPrepared
    case committing
    case generatingThumbnail
    case completed
    case failed
}

struct ImportJobState: Codable, Equatable, Sendable {
    let phase: ImportJobPhase
    let pause: ImportJobPause?
    let failure: ImportJobFailure?

    static let queued = Self(phase: .queued)
    static let checkingSpace = Self(phase: .checkingSpace)
    static let copying = Self(phase: .copying)
    static let verifying = Self(phase: .verifying)
    static let commitPrepared = Self(phase: .commitPrepared)
    static let committing = Self(phase: .committing)
    static let generatingThumbnail = Self(phase: .generatingThumbnail)
    static let completed = Self(phase: .completed)

    static func paused(_ reason: ImportJobPause) -> Self {
        Self(phase: .paused, pause: reason)
    }

    static func failed(_ failure: ImportJobFailure) -> Self {
        Self(phase: .failed, failure: failure)
    }

    var isTerminal: Bool {
        phase == .completed || phase == .failed
    }

    var isConsistent: Bool {
        switch phase {
        case .paused:
            pause != nil && failure == nil
        case .failed:
            pause == nil && failure != nil
        case .queued, .checkingSpace, .copying, .verifying, .commitPrepared,
                .committing, .generatingThumbnail, .completed:
            pause == nil && failure == nil
        }
    }

    private init(
        phase: ImportJobPhase,
        pause: ImportJobPause? = nil,
        failure: ImportJobFailure? = nil
    ) {
        self.phase = phase
        self.pause = pause
        self.failure = failure
    }
}

enum ImportJobPauseCode: String, Codable, Equatable, Sendable {
    case userCancelled
    case insufficientSpace
    case permissionLost
    case sourceChanged
    case copyFailed
    case interrupted
    case stagingCorrupted
    case commitConflict
}

struct ImportJobPause: Codable, Equatable, Sendable {
    let code: ImportJobPauseCode
    let sourceRelativePath: SourceRelativePath?
    let requiredBytes: Int64?
    let availableBytes: Int64?

    static let userCancelled = Self(code: .userCancelled)
    static let permissionLost = Self(code: .permissionLost)
    static let interrupted = Self(code: .interrupted)

    static func insufficientSpace(
        requiredBytes: Int64,
        availableBytes: Int64
    ) -> Self {
        Self(
            code: .insufficientSpace,
            requiredBytes: max(0, requiredBytes),
            availableBytes: max(0, availableBytes)
        )
    }

    static func sourceChanged(_ sourceRelativePath: SourceRelativePath) -> Self {
        Self(code: .sourceChanged, sourceRelativePath: sourceRelativePath)
    }

    static func copyFailed(_ sourceRelativePath: SourceRelativePath) -> Self {
        Self(code: .copyFailed, sourceRelativePath: sourceRelativePath)
    }

    static func stagingCorrupted(
        _ sourceRelativePath: SourceRelativePath
    ) -> Self {
        Self(code: .stagingCorrupted, sourceRelativePath: sourceRelativePath)
    }

    static let commitConflict = Self(code: .commitConflict)

    private init(
        code: ImportJobPauseCode,
        sourceRelativePath: SourceRelativePath? = nil,
        requiredBytes: Int64? = nil,
        availableBytes: Int64? = nil
    ) {
        self.code = code
        self.sourceRelativePath = sourceRelativePath
        self.requiredBytes = requiredBytes
        self.availableBytes = availableBytes
    }
}

enum ImportJobFailureCode: String, Codable, Equatable, Sendable {
    case invalidPlan
    case stagingUnavailable
    case commitFailed
}

struct ImportJobFailure: Codable, Equatable, Sendable {
    let code: ImportJobFailureCode

    static let invalidPlan = Self(code: .invalidPlan)
    static let stagingUnavailable = Self(code: .stagingUnavailable)
    static let commitFailed = Self(code: .commitFailed)

    private init(code: ImportJobFailureCode) {
        self.code = code
    }
}

struct ImportSHA256Digest: Codable, Equatable, Hashable, Sendable {
    let rawValue: String

    init?(rawValue: String) {
        guard rawValue.utf8.count == 64,
              rawValue.utf8.allSatisfy({ byte in
                  let value = Int(byte)
                  return (48...57).contains(value) || (97...102).contains(value)
              }) else {
            return nil
        }

        self.rawValue = rawValue
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)

        guard let digest = Self(rawValue: rawValue) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "SHA-256 digest must be 64 lowercase hexadecimal characters."
            )
        }

        self = digest
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

enum ImportWorkItemCheckpointPhase: String, Codable, Equatable, Sendable {
    case pending
    case prepared
    case verified
}

struct ImportFileVerification: Codable, Equatable, Sendable {
    let byteCount: Int64
    let sha256: ImportSHA256Digest
}

struct ImportWorkItemCheckpoint: Codable, Equatable, Identifiable, Sendable {
    let id: ImportPageCandidate.ID
    var phase: ImportWorkItemCheckpointPhase
    var verification: ImportFileVerification?

    static func pending(_ id: ImportPageCandidate.ID) -> Self {
        Self(id: id, phase: .pending, verification: nil)
    }

    var isConsistent: Bool {
        switch phase {
        case .pending:
            verification == nil
        case .prepared, .verified:
            verification != nil
        }
    }
}

struct ImportCommitIntent: Codable, Equatable, Sendable {
    let jobID: ImportJobID
    let targetComicID: ManagedComicID
    let revision: ImportPreviewRevision
}

enum ImportThumbnailStatus: String, Codable, Equatable, Sendable {
    case notStarted
    case generated
    case failed
}

enum ImportRuntimeIssueCode: String, Codable, Equatable, Sendable {
    case copyFailed
    case thumbnailFailed
}

struct ImportRuntimeIssue: Codable, Equatable, Sendable {
    let code: ImportRuntimeIssueCode
    let sourceRelativePath: SourceRelativePath?

    static func copyFailed(_ sourceRelativePath: SourceRelativePath) -> Self {
        Self(code: .copyFailed, sourceRelativePath: sourceRelativePath)
    }

    static let thumbnailFailed = Self(code: .thumbnailFailed, sourceRelativePath: nil)
}

struct ImportReport: Codable, Equatable, Sendable {
    let jobID: ImportJobID
    let targetComicID: ManagedComicID
    let revision: ImportPreviewRevision
    let verifiedWorkItemIDs: [ImportPageCandidate.ID]
    let verifiedChapterIDs: [ImportChapterCandidate.ID]
    let scanIssues: [ImportIssue]
    let runtimeIssues: [ImportRuntimeIssue]
    let thumbnailStatus: ImportThumbnailStatus
}

struct ImportJobJournal: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let jobID: ImportJobID
    let targetComicID: ManagedComicID
    let planRevision: ImportPreviewRevision
    var state: ImportJobState
    var cancellationRequested: Bool
    var checkpoints: [ImportWorkItemCheckpoint]
    var commitIntent: ImportCommitIntent?
    var runtimeIssues: [ImportRuntimeIssue]
    var thumbnailStatus: ImportThumbnailStatus
    var report: ImportReport?

    init(plan: FrozenImportPlan, targetComicID: ManagedComicID = ManagedComicID()) {
        schemaVersion = Self.currentSchemaVersion
        jobID = plan.id
        self.targetComicID = targetComicID
        planRevision = plan.revision
        state = .queued
        cancellationRequested = false
        checkpoints = plan.workItems.map { .pending($0.id) }
        commitIntent = nil
        runtimeIssues = []
        thumbnailStatus = .notStarted
        report = nil
    }

    var isConsistent: Bool {
        guard state.isConsistent,
              checkpoints.allSatisfy(\.isConsistent) else {
            return false
        }

        let requiresCommitIntent: Bool
        switch state.phase {
        case .commitPrepared, .committing, .generatingThumbnail, .completed:
            requiresCommitIntent = true
        case .queued, .checkingSpace, .copying, .verifying, .paused, .failed:
            requiresCommitIntent = false
        }

        guard let commitIntent else {
            return !requiresCommitIntent
        }

        return commitIntent.jobID == jobID
            && commitIntent.targetComicID == targetComicID
            && commitIntent.revision == planRevision
            && (requiresCommitIntent
                || state.phase == .failed
                || state.pause?.code == .commitConflict
                || state.pause?.code == .stagingCorrupted
                || state.pause?.code == .interrupted)
    }

    func isCompatible(with plan: FrozenImportPlan) -> Bool {
        plan.id == jobID
            && plan.revision == planRevision
            && plan.workItems.map(\.id) == checkpoints.map(\.id)
            && isConsistent
    }

    var verifiedWorkItemIDs: [ImportPageCandidate.ID] {
        checkpoints.compactMap { checkpoint in
            checkpoint.phase == .verified ? checkpoint.id : nil
        }
    }

    func verifiedByteCount(in plan: FrozenImportPlan) -> Int64 {
        let workItemByID = Dictionary(
            uniqueKeysWithValues: plan.workItems.map { ($0.id, $0) }
        )

        return verifiedWorkItemIDs.reduce(Int64(0)) { result, pageID in
            guard let workItem = workItemByID[pageID] else {
                return result
            }

            let sum = result.addingReportingOverflow(
                max(0, workItem.expectedByteCount)
            )
            return sum.overflow ? Int64.max : sum.partialValue
        }
    }

    func verifiedChapterIDs(in plan: FrozenImportPlan) -> [ImportChapterCandidate.ID] {
        let verifiedPageIDs = Set(verifiedWorkItemIDs)

        return plan.chapters.compactMap { chapter in
            chapter.pageIDs.allSatisfy(verifiedPageIDs.contains) ? chapter.id : nil
        }
    }

    mutating func markPrepared(
        _ verification: ImportFileVerification,
        for pageID: ImportPageCandidate.ID
    ) -> Bool {
        updateCheckpoint(
            pageID,
            phase: .prepared,
            verification: verification
        )
    }

    mutating func markVerified(
        _ verification: ImportFileVerification,
        for pageID: ImportPageCandidate.ID
    ) -> Bool {
        updateCheckpoint(
            pageID,
            phase: .verified,
            verification: verification
        )
    }

    mutating func resetCheckpoint(
        for pageID: ImportPageCandidate.ID
    ) -> Bool {
        updateCheckpoint(pageID, phase: .pending, verification: nil)
    }

    mutating func finalizeReport(with plan: FrozenImportPlan) {
        report = ImportReport(
            jobID: jobID,
            targetComicID: targetComicID,
            revision: planRevision,
            verifiedWorkItemIDs: verifiedWorkItemIDs,
            verifiedChapterIDs: verifiedChapterIDs(in: plan),
            scanIssues: plan.scanIssues,
            runtimeIssues: runtimeIssues,
            thumbnailStatus: thumbnailStatus
        )
    }

    func snapshot(using plan: FrozenImportPlan) -> ImportJobSnapshot {
        ImportJobSnapshot(
            id: jobID,
            displayName: plan.displayName,
            state: state,
            verifiedWorkItemCount: verifiedWorkItemIDs.count,
            totalWorkItemCount: plan.workItems.count,
            verifiedByteCount: verifiedByteCount(in: plan),
            totalByteCount: plan.spaceEstimate.contentBytes,
            verifiedChapterIDs: verifiedChapterIDs(in: plan),
            report: report
        )
    }

    private mutating func updateCheckpoint(
        _ pageID: ImportPageCandidate.ID,
        phase: ImportWorkItemCheckpointPhase,
        verification: ImportFileVerification?
    ) -> Bool {
        guard let index = checkpoints.firstIndex(where: { $0.id == pageID }) else {
            return false
        }

        checkpoints[index].phase = phase
        checkpoints[index].verification = verification
        return true
    }
}

struct ImportJobSnapshot: Equatable, Identifiable, Sendable {
    let id: ImportJobID
    let displayName: String
    let state: ImportJobState
    let verifiedWorkItemCount: Int
    let totalWorkItemCount: Int
    let verifiedByteCount: Int64
    let totalByteCount: Int64
    let verifiedChapterIDs: [ImportChapterCandidate.ID]
    let report: ImportReport?
}
