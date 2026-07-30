import Foundation
import Observation

struct ImportPreviewSession: Equatable, Identifiable, Sendable {
    let source: ImportSourceDescriptor
    private(set) var draft: ImportPreviewDraft

    var id: UUID {
        source.id
    }

    var sourceBookmark: Data {
        source.bookmark
    }

    var manifest: ImportManifest {
        draft.manifest
    }

    init(source: ImportSourceDescriptor, manifest: ImportManifest) {
        self.source = source
        draft = ImportPreviewDraft(manifest: manifest)
    }

    mutating func updateDraft(
        _ update: (inout ImportPreviewDraft) throws -> Void
    ) rethrows {
        try update(&draft)
    }
}

enum FolderImportCoordinatorError: Error, Equatable, Sendable {
    case unknownPreviewSession
}

enum FolderImportStatus: Equatable {
    case idle
    case scanning(folderNames: [String])
    case preview(manifests: [ImportManifest])
    case failed
}

@MainActor
@Observable
final class FolderImportCoordinator {
    private(set) var status: FolderImportStatus = .idle
    private(set) var previewSessions: [ImportPreviewSession] = []
    private(set) var failedFolderNames: [String] = []

    private let scanner: any ImportScanning
    private let sourceAccess: any ImportSourceAccessing
    @ObservationIgnored private var scanTask: Task<Void, Never>?
    @ObservationIgnored private var scanGeneration = 0

    init(
        scanner: any ImportScanning = ImportScanner(),
        sourceAccess: any ImportSourceAccessing = SecurityScopedSourceAccess()
    ) {
        self.scanner = scanner
        self.sourceAccess = sourceAccess
    }

    func handleSelectedURLs(_ urls: [URL]) {
        handlePreparedSources(
            ImportSourcePreparer(sourceAccess: sourceAccess).prepare(urls)
        )
    }

    func handleDroppedSources(_ sources: [ImportSourceDescriptor]) {
        handlePreparedSources(ImportSourcePreparation(sources: sources))
    }

    func handlePreparedSources(_ preparation: ImportSourcePreparation) {
        beginScanning(
            preparation.sources,
            rejectedFolderNames: preparation.rejectedDisplayNames
        )
    }

    private func beginScanning(
        _ sources: [ImportSourceDescriptor],
        rejectedFolderNames: [String]
    ) {
        scanTask?.cancel()
        scanGeneration += 1
        clearPreviewResults()

        var seenBookmarks = Set<Data>()
        let sortedSources = sources
            .filter { !$0.displayName.isEmpty }
            .filter { seenBookmarks.insert($0.bookmark).inserted }
            .sorted(by: sourceOrder)
        let sortedRejectedFolderNames = rejectedFolderNames.sorted(by: nameOrder)

        guard !sortedSources.isEmpty else {
            failedFolderNames = sortedRejectedFolderNames
            status = .failed
            return
        }

        let generation = scanGeneration
        status = .scanning(
            folderNames: sortedSources.map(\.displayName)
        )
        scanTask = Task { [weak self] in
            await self?.scan(
                sortedSources,
                rejectedFolderNames: sortedRejectedFolderNames,
                generation: generation
            )
        }
    }

    func handleSelectionFailure() {
        scanTask?.cancel()
        scanTask = nil
        scanGeneration += 1
        clearPreviewResults()
        status = .failed
    }

    func reset() {
        scanTask?.cancel()
        scanTask = nil
        scanGeneration += 1
        clearPreviewResults()
        status = .idle
    }

    func updatePreviewDraft(
        for sessionID: ImportPreviewSession.ID,
        _ update: (inout ImportPreviewDraft) throws -> Void
    ) throws {
        guard let index = previewSessions.firstIndex(where: {
            $0.id == sessionID
        }) else {
            throw FolderImportCoordinatorError.unknownPreviewSession
        }

        var session = previewSessions[index]
        try session.updateDraft(update)
        previewSessions[index] = session
    }

    @discardableResult
    func removePreviewSession(
        withID sessionID: ImportPreviewSession.ID
    ) -> ImportPreviewSession? {
        guard let index = previewSessions.firstIndex(where: {
            $0.id == sessionID
        }) else {
            return nil
        }

        let session = previewSessions.remove(at: index)
        updatePreviewStatus()
        return session
    }

    private func scan(
        _ sources: [ImportSourceDescriptor],
        rejectedFolderNames: [String],
        generation: Int
    ) async {
        var sessions: [ImportPreviewSession] = []
        var failures = rejectedFolderNames

        for source in sources {
            do {
                try Task.checkCancellation()
                let sourceURL = try sourceAccess.resolveBookmark(source.bookmark)
                try sourceAccess.startAccessing(sourceURL)
                defer { sourceAccess.stopAccessing(sourceURL) }
                let manifest = try await scanner.scan(
                    ImportScanRequest(rootURL: sourceURL)
                )
                sessions.append(
                    ImportPreviewSession(source: source, manifest: manifest)
                )
            } catch is CancellationError {
                return
            } catch {
                failures.append(source.displayName)
            }
        }

        do {
            try Task.checkCancellation()
        } catch is CancellationError {
            return
        } catch {
            return
        }

        guard generation == scanGeneration else {
            return
        }

        previewSessions = sessions
        failedFolderNames = failures.sorted(by: nameOrder)
        updatePreviewStatus()
        scanTask = nil
    }

    private func clearPreviewResults() {
        previewSessions = []
        failedFolderNames = []
    }

    private func updatePreviewStatus() {
        guard !previewSessions.isEmpty else {
            status = failedFolderNames.isEmpty ? .idle : .failed
            return
        }

        status = .preview(manifests: previewSessions.map(\.manifest))
    }

    private func sourceOrder(
        _ lhs: ImportSourceDescriptor,
        _ rhs: ImportSourceDescriptor
    ) -> Bool {
        let comparison = lhs.displayName.localizedStandardCompare(rhs.displayName)

        if comparison != .orderedSame {
            return comparison == .orderedAscending
        }

        return lhs.id.uuidString < rhs.id.uuidString
    }

    private func nameOrder(_ lhs: String, _ rhs: String) -> Bool {
        lhs.localizedStandardCompare(rhs) == .orderedAscending
    }
}
