import Foundation
import XCTest
@testable import ComicReader

@MainActor
final class FolderImportCoordinatorTests: XCTestCase {
    func testSuccessfulSelectionUsesNaturalNameOrdering() async {
        let manifest = Self.manifest()
        let scanner = RecordingImportScanner(outcome: .success(manifest))
        let coordinator = FolderImportCoordinator(scanner: scanner)
        let urls = [
            URL(fileURLWithPath: "/tmp/chapter10"),
            URL(fileURLWithPath: "/tmp/chapter2"),
        ]

        coordinator.handleSelectedURLs(urls)

        XCTAssertEqual(
            coordinator.status,
            .scanning(folderNames: ["chapter2", "chapter10"])
        )

        await waitForScanToFinish(coordinator)
        let requestedRootNames = await scanner.requestedRootNames()

        XCTAssertEqual(
            requestedRootNames,
            ["chapter2", "chapter10"]
        )
        XCTAssertEqual(
            coordinator.status,
            .preview(manifests: [manifest, manifest])
        )
    }

    func testEmptySelectionFailsGracefully() {
        let coordinator = FolderImportCoordinator()

        coordinator.handleSelectedURLs([])

        XCTAssertEqual(coordinator.status, .failed)
    }

    func testPickerFailureFailsGracefully() {
        let coordinator = FolderImportCoordinator()

        coordinator.handleSelectionFailure()

        XCTAssertEqual(coordinator.status, .failed)
    }

    func testResetClearsPreviousSelection() {
        let coordinator = FolderImportCoordinator()
        coordinator.handleSelectedURLs(
            [URL(fileURLWithPath: "/tmp/comic")]
        )

        coordinator.reset()

        XCTAssertEqual(coordinator.status, .idle)
    }

    func testScannerFailureDoesNotExposeUnderlyingError() async {
        let scanner = RecordingImportScanner(outcome: .failure)
        let coordinator = FolderImportCoordinator(scanner: scanner)

        coordinator.handleSelectedURLs(
            [URL(fileURLWithPath: "/tmp/comic")]
        )
        await waitForScanToFinish(coordinator)

        XCTAssertEqual(coordinator.status, .failed)
    }

    private func waitForScanToFinish(
        _ coordinator: FolderImportCoordinator,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<100 {
            if case .scanning = coordinator.status {
                await Task.yield()
            } else {
                return
            }
        }

        XCTFail(
            "Timed out waiting for folder recognition.",
            file: file,
            line: line
        )
    }

    private static func manifest() -> ImportManifest {
        ImportManifest(
            sourceRootName: "Stub Comic",
            sortLocaleIdentifier: "en_US_POSIX",
            collections: [],
            chapters: [],
            pages: [],
            coverPageID: nil,
            issues: [],
            spaceEstimate: .make(contentBytes: 0, fileCount: 0)
        )
    }
}

private actor RecordingImportScanner: ImportScanning {
    enum Outcome: Sendable {
        case success(ImportManifest)
        case failure
    }

    private let outcome: Outcome
    private var rootNames: [String] = []

    init(outcome: Outcome) {
        self.outcome = outcome
    }

    func scan(_ request: ImportScanRequest) async throws -> ImportManifest {
        rootNames.append(request.rootURL.lastPathComponent)

        switch outcome {
        case let .success(manifest):
            return manifest
        case .failure:
            throw RecordingImportScannerError.failed
        }
    }

    func requestedRootNames() -> [String] {
        rootNames
    }
}

private enum RecordingImportScannerError: Error, Sendable {
    case failed
}
