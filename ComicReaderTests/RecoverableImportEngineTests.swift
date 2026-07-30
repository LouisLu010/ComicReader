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
                rootURL: sandbox.libraryURL,
                comicID: targetComicID,
                components: ["original", coverURL.lastPathComponent]
            )),
            try Data(contentsOf: coverURL)
        )
        XCTAssertEqual(
            try Data(contentsOf: libraryURL(
                rootURL: sandbox.libraryURL,
                comicID: targetComicID,
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
            rootURL: sandbox.libraryURL,
            comicID: targetComicID,
            components: ["metadata", "import-descriptor.json"]
        )
        let descriptor = try XCTUnwrap(
            String(data: Data(contentsOf: descriptorURL), encoding: .utf8)
        )

        XCTAssertFalse(descriptor.contains("sourceBookmark"))
        XCTAssertFalse(descriptor.contains(sandbox.sourceDirectoryURL.path))
    }

    func testInsufficientSpacePausesBeforeCopyWithoutChangingSource() async throws {
        let sandbox = try TemporaryImportSandbox(sourceName: "No Space")
        try sandbox.sourceTree.png("Chapter/01.png")
        let sourceSnapshot = try sandbox.sourceSnapshot()
        let manifest = try await scan(sandbox)
        let draft = ImportPreviewDraft(manifest: manifest)
        let layout = ImportStorageLayout(rootURL: sandbox.appManagedRootURL)
        let engine = RecoverableImportEngine(
            layout: layout,
            sourceAccess: TestSourceAccess(rootURL: sandbox.sourceDirectoryURL),
            capacityProvider: FixedCapacityProvider(value: 0),
            thumbnailGenerator: TestThumbnailGenerator()
        )

        let queued = try await engine.enqueue(
            draft,
            sourceURL: sandbox.sourceDirectoryURL
        )
        let paused = try await engine.run(queued.id)

        XCTAssertEqual(paused.state.phase, .paused)
        XCTAssertEqual(paused.state.pause?.code, .insufficientSpace)
        XCTAssertEqual(paused.verifiedWorkItemCount, 0)
        XCTAssertTrue(try sandbox.sourceIsUnchanged(since: sourceSnapshot))
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: layout.libraryURL.path
                    .appending("/")
                    .appending(queued.id.rawValue.uuidString.lowercased())
            )
        )
    }

    private func scan(_ sandbox: TemporaryImportSandbox) async throws -> ImportManifest {
        try await ImportScanner().scan(
            ImportScanRequest(
                rootURL: sandbox.sourceDirectoryURL,
                locale: Locale(identifier: "en_US_POSIX")
            )
        )
    }

    private func libraryURL(
        rootURL: URL,
        comicID: ManagedComicID,
        components: [String]
    ) -> URL {
        components.reduce(
            rootURL.appendingPathComponent(
                comicID.rawValue.uuidString.lowercased(),
                isDirectory: true
            )
        ) { url, component in
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
