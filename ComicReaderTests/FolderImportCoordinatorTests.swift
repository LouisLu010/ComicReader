import Foundation
import XCTest
@testable import ComicReader

@MainActor
final class FolderImportCoordinatorTests: XCTestCase {
    func testSuccessfulSelectionUsesNaturalNameOrdering() async {
        let manifest = Self.manifest()
        let scanner = RecordingImportScanner(outcome: .success(manifest))
        let coordinator = FolderImportCoordinator(
            scanner: scanner,
            sourceAccess: TestFolderSourceAccess()
        )
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
        XCTAssertEqual(
            coordinator.previewSessions.map(\.source.displayName),
            ["chapter2", "chapter10"]
        )
        XCTAssertEqual(
            coordinator.previewSessions.map(\.draft.manifest),
            [manifest, manifest]
        )
        XCTAssertEqual(coordinator.failedFolderNames, [])
    }

    func testEmptySelectionFailsGracefully() {
        let coordinator = FolderImportCoordinator()

        coordinator.handleSelectedURLs([])

        XCTAssertEqual(coordinator.status, .failed)
    }

    func testPickerFailureFailsGracefully() async {
        let scanner = RecordingImportScanner(outcome: .success(Self.manifest()))
        let coordinator = FolderImportCoordinator(
            scanner: scanner,
            sourceAccess: TestFolderSourceAccess()
        )
        coordinator.handleSelectedURLs(
            [URL(fileURLWithPath: "/tmp/comic")]
        )
        await waitForScanToFinish(coordinator)
        XCTAssertFalse(coordinator.previewSessions.isEmpty)

        coordinator.handleSelectionFailure()

        XCTAssertEqual(coordinator.status, .failed)
        XCTAssertEqual(coordinator.previewSessions, [])
        XCTAssertEqual(coordinator.failedFolderNames, [])
    }

    func testResetClearsPreviousSelection() async {
        let scanner = RecordingImportScanner(outcome: .success(Self.manifest()))
        let coordinator = FolderImportCoordinator(
            scanner: scanner,
            sourceAccess: TestFolderSourceAccess()
        )
        coordinator.handleSelectedURLs(
            [URL(fileURLWithPath: "/tmp/comic")]
        )
        await waitForScanToFinish(coordinator)
        XCTAssertFalse(coordinator.previewSessions.isEmpty)

        coordinator.reset()

        XCTAssertEqual(coordinator.status, .idle)
        XCTAssertEqual(coordinator.previewSessions, [])
        XCTAssertEqual(coordinator.failedFolderNames, [])
    }

    func testScannerFailureDoesNotExposeUnderlyingError() async {
        let scanner = RecordingImportScanner(outcome: .failure)
        let coordinator = FolderImportCoordinator(
            scanner: scanner,
            sourceAccess: TestFolderSourceAccess()
        )

        coordinator.handleSelectedURLs(
            [URL(fileURLWithPath: "/tmp/comic")]
        )
        await waitForScanToFinish(coordinator)

        XCTAssertEqual(coordinator.status, .failed)
        XCTAssertEqual(coordinator.previewSessions, [])
        XCTAssertEqual(coordinator.failedFolderNames, ["comic"])
    }

    func testBatchSelectionKeepsSuccessfulSessionsWhenAnotherFolderFails() async throws {
        let successfulManifest = Self.manifest(sourceRootName: "chapter2")
        let scanner = SelectiveImportScanner(
            manifests: ["chapter2": successfulManifest],
            failedRootNames: ["chapter10"]
        )
        let coordinator = FolderImportCoordinator(
            scanner: scanner,
            sourceAccess: TestFolderSourceAccess()
        )
        let urls = [
            URL(fileURLWithPath: "/tmp/chapter10"),
            URL(fileURLWithPath: "/tmp/chapter2"),
        ]

        coordinator.handleSelectedURLs(urls)
        await waitForScanToFinish(coordinator)
        let requestedRootNames = await scanner.requestedRootNames()

        XCTAssertEqual(
            requestedRootNames,
            ["chapter2", "chapter10"]
        )
        XCTAssertEqual(
            coordinator.status,
            .preview(manifests: [successfulManifest])
        )
        XCTAssertEqual(
            coordinator.previewSessions.map(\.source.displayName),
            ["chapter2"]
        )
        XCTAssertEqual(
            coordinator.previewSessions.first?.draft.manifest,
            successfulManifest
        )
        XCTAssertEqual(coordinator.failedFolderNames, ["chapter10"])

        let removed = coordinator.removePreviewSession(
            withID: try XCTUnwrap(coordinator.previewSessions.first?.id)
        )

        XCTAssertEqual(removed?.source.displayName, "chapter2")
        XCTAssertEqual(coordinator.status, .failed)
        XCTAssertEqual(coordinator.previewSessions, [])
        XCTAssertEqual(coordinator.failedFolderNames, ["chapter10"])
    }

    func testDroppedSourceKeepsThePreparedBookmarkThroughPreview() async throws {
        let manifest = Self.manifest(sourceRootName: "Dropped Comic")
        let scanner = RecordingImportScanner(outcome: .success(manifest))
        let sourceAccess = TestFolderSourceAccess()
        let sourceURL = URL(fileURLWithPath: "/tmp/dropped-comic")
        let source = try ImportSourceDescriptor(
            sourceURL: sourceURL,
            sourceAccess: sourceAccess
        )
        let coordinator = FolderImportCoordinator(
            scanner: scanner,
            sourceAccess: sourceAccess
        )

        coordinator.handleDroppedSources([source])
        await waitForScanToFinish(coordinator)

        XCTAssertEqual(coordinator.previewSessions.map(\.source), [source])
        let requestedRootNames = await scanner.requestedRootNames()
        XCTAssertEqual(requestedRootNames, ["dropped-comic"])
    }

    func testPreviewDraftUpdatesPersistForTheMatchingSession() async throws {
        let manifest = Self.manifest()
        let scanner = RecordingImportScanner(outcome: .success(manifest))
        let coordinator = FolderImportCoordinator(
            scanner: scanner,
            sourceAccess: TestFolderSourceAccess()
        )
        let sourceURL = URL(fileURLWithPath: "/tmp/comic")

        coordinator.handleSelectedURLs([sourceURL])
        await waitForScanToFinish(coordinator)
        let session = try XCTUnwrap(coordinator.previewSessions.first)

        try coordinator.updatePreviewDraft(for: session.id) { draft in
            try draft.setDisplayName("Renamed Comic")
        }

        let updatedSession = try XCTUnwrap(coordinator.previewSessions.first)
        XCTAssertEqual(updatedSession.source.displayName, "comic")
        XCTAssertEqual(
            updatedSession.source.bookmark,
            Data(sourceURL.absoluteString.utf8)
        )
        XCTAssertEqual(updatedSession.manifest, manifest)
        XCTAssertEqual(updatedSession.draft.displayName, "Renamed Comic")
        XCTAssertEqual(
            coordinator.status,
            .preview(manifests: [manifest])
        )
    }

    func testPreviewDraftUpdateFailureLeavesStoredSessionUnchanged() async throws {
        let manifest = Self.manifest()
        let scanner = RecordingImportScanner(outcome: .success(manifest))
        let coordinator = FolderImportCoordinator(
            scanner: scanner,
            sourceAccess: TestFolderSourceAccess()
        )
        let sourceURL = URL(fileURLWithPath: "/tmp/comic")

        coordinator.handleSelectedURLs([sourceURL])
        await waitForScanToFinish(coordinator)
        let session = try XCTUnwrap(coordinator.previewSessions.first)

        XCTAssertThrowsError(
            try coordinator.updatePreviewDraft(for: session.id) { draft in
                try draft.setDisplayName("Temporary Name")
                throw RecordingImportScannerError.failed
            }
        ) { error in
            XCTAssertEqual(error as? RecordingImportScannerError, .failed)
        }

        XCTAssertEqual(coordinator.previewSessions, [session])
    }

    func testPreviewDraftUpdateRejectsAnUnknownSession() {
        let coordinator = FolderImportCoordinator()
        let unknownID = UUID()

        XCTAssertThrowsError(
            try coordinator.updatePreviewDraft(for: unknownID) { _ in }
        ) { error in
            XCTAssertEqual(
                error as? FolderImportCoordinatorError,
                .unknownPreviewSession
            )
        }
        XCTAssertNil(coordinator.removePreviewSession(withID: unknownID))
    }

    func testRemovingTheLastConfirmedSessionReturnsToIdle() async throws {
        let scanner = RecordingImportScanner(outcome: .success(Self.manifest()))
        let coordinator = FolderImportCoordinator(
            scanner: scanner,
            sourceAccess: TestFolderSourceAccess()
        )
        let sourceURL = URL(fileURLWithPath: "/tmp/comic")

        coordinator.handleSelectedURLs([sourceURL])
        await waitForScanToFinish(coordinator)
        let session = try XCTUnwrap(coordinator.previewSessions.first)

        let removed = coordinator.removePreviewSession(withID: session.id)

        XCTAssertEqual(removed, session)
        XCTAssertEqual(coordinator.status, .idle)
        XCTAssertEqual(coordinator.previewSessions, [])
        XCTAssertEqual(coordinator.failedFolderNames, [])
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

    private static func manifest(
        sourceRootName: String = "Stub Comic"
    ) -> ImportManifest {
        ImportManifest(
            sourceRootName: sourceRootName,
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

private enum RecordingImportScannerError: Error, Equatable, Sendable {
    case failed
}

private struct TestFolderSourceAccess: ImportSourceAccessing {
    func makeBookmark(for sourceURL: URL) throws -> Data {
        Data(sourceURL.absoluteString.utf8)
    }

    func resolveBookmark(_ bookmark: Data) throws -> URL {
        guard let value = String(data: bookmark, encoding: .utf8),
              let sourceURL = URL(string: value) else {
            throw ImportSourceAccessError.invalidBookmark
        }

        return sourceURL
    }

    func startAccessing(_ sourceURL: URL) throws {}

    func stopAccessing(_ sourceURL: URL) {}
}

private actor SelectiveImportScanner: ImportScanning {
    private let manifests: [String: ImportManifest]
    private let failedRootNames: Set<String>
    private var rootNames: [String] = []

    init(
        manifests: [String: ImportManifest],
        failedRootNames: Set<String>
    ) {
        self.manifests = manifests
        self.failedRootNames = failedRootNames
    }

    func scan(_ request: ImportScanRequest) async throws -> ImportManifest {
        let rootName = request.rootURL.lastPathComponent
        rootNames.append(rootName)

        if failedRootNames.contains(rootName) {
            throw RecordingImportScannerError.failed
        }

        guard let manifest = manifests[rootName] else {
            throw RecordingImportScannerError.failed
        }

        return manifest
    }

    func requestedRootNames() -> [String] {
        rootNames
    }
}
