import Foundation

enum ImportExecutionFaultPoint: Equatable, Hashable, Sendable {
    case beforeCopy(jobID: ImportJobID, pageID: ImportPageCandidate.ID)
    case afterPreparedCheckpoint(jobID: ImportJobID, pageID: ImportPageCandidate.ID)
    case afterVerifiedCheckpoint(jobID: ImportJobID, pageID: ImportPageCandidate.ID)
    case beforeCommitIntent(ImportJobID)
    case afterCommitPrepared(ImportJobID)
    case beforePayloadMove(ImportJobID)
    case afterPayloadMoved(ImportJobID)
    case beforeThumbnail(ImportJobID)
}

enum ImportInjectedFault: Error, Equatable, Sendable {
    case copyFailed
    case commitMoveFailed
    case simulatedProcessInterruption
}

protocol ImportExecutionFaultInjecting: Sendable {
    func reach(_ point: ImportExecutionFaultPoint) async throws
}

struct NoImportExecutionFaultInjector: ImportExecutionFaultInjecting {
    func reach(_ point: ImportExecutionFaultPoint) async throws {}
}
