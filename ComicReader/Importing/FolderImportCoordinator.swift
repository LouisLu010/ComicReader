import Foundation
import Observation

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

    private let scanner: any ImportScanning
    @ObservationIgnored private var scanTask: Task<Void, Never>?
    @ObservationIgnored private var scanGeneration = 0

    init(scanner: any ImportScanning = ImportScanner()) {
        self.scanner = scanner
    }

    func handleSelectedURLs(_ urls: [URL]) {
        scanTask?.cancel()
        scanGeneration += 1

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
        status = .failed
    }

    func reset() {
        scanTask?.cancel()
        scanTask = nil
        scanGeneration += 1
        status = .idle
    }

    private func scan(
        _ urls: [URL],
        generation: Int
    ) async {
        do {
            var manifests: [ImportManifest] = []

            for url in urls {
                try Task.checkCancellation()
                manifests.append(
                    try await scanner.scan(
                        ImportScanRequest(rootURL: url)
                    )
                )
            }

            try Task.checkCancellation()
            guard generation == scanGeneration else {
                return
            }

            status = .preview(manifests: manifests)
            scanTask = nil
        } catch is CancellationError {
            return
        } catch {
            guard generation == scanGeneration else {
                return
            }

            status = .failed
            scanTask = nil
        }
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
