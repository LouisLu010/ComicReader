import Foundation
import Observation

struct ImportPreviewSession: Equatable, Identifiable, Sendable {
    let sourceURL: URL
    private(set) var draft: ImportPreviewDraft

    var id: URL {
        sourceURL
    }

    var manifest: ImportManifest {
        draft.manifest
    }

    init(sourceURL: URL, manifest: ImportManifest) {
        self.sourceURL = sourceURL
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
    @ObservationIgnored private var scanTask: Task<Void, Never>?
    @ObservationIgnored private var scanGeneration = 0

    init(scanner: any ImportScanning = ImportScanner()) {
        self.scanner = scanner
    }

    func handleSelectedURLs(_ urls: [URL]) {
        scanTask?.cancel()
        scanGeneration += 1
        clearPreviewResults()

        let sortedURLs = urls
            .filter { !$0.lastPathComponent.isEmpty }
            .sorted(by: urlOrder)

        guard !sortedURLs.isEmpty else {
            status = .failed
            return
        }

        let generation = scanGeneration
        status = .scanning(
            folderNames: sortedURLs.map(\.lastPathComponent)
        )
        scanTask = Task { [weak self] in
            await self?.scan(
                sortedURLs,
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
        _ urls: [URL],
        generation: Int
    ) async {
        var sessions: [ImportPreviewSession] = []
        var failures: [String] = []

        for url in urls {
            do {
                try Task.checkCancellation()
                let manifest = try await scanner.scan(
                    ImportScanRequest(rootURL: url)
                )
                sessions.append(
                    ImportPreviewSession(sourceURL: url, manifest: manifest)
                )
            } catch is CancellationError {
                return
            } catch {
                failures.append(url.lastPathComponent)
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
        failedFolderNames = failures
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

    private func urlOrder(_ lhs: URL, _ rhs: URL) -> Bool {
        let comparison = lhs.lastPathComponent.localizedStandardCompare(
            rhs.lastPathComponent
        )

        if comparison != .orderedSame {
            return comparison == .orderedAscending
        }

        return lhs.path < rhs.path
    }
}
