import Foundation
import XCTest
@testable import ComicReader

final class ComicUpdateExecutorTests: XCTestCase {
    func testApplyExecutesAdditionReplacementRemovalAndCleanup()
        async throws {
        let fixture = try await makeImportedComicFixture()
        try fixture.sandbox.sourceTree.alternatePNG("Chapter 1/02.png")
        try fixture.sandbox.sourceTree.png("Chapter 1/03.png")
        try fixture.sandbox.sourceTree.png("Chapter 3/01.png")
        try FileManager.default.removeItem(
            at: fixture.sandbox.sourceTree.directory("Chapter 2")
        )

        let update = try await fixture.makeUpdate(removingMissing: true)

        // 执行器不得修改来源；快照须在 apply 之前采集。
        let snapshotBeforeApply = try fixture.sandbox.sourceSnapshot()
        let result = try await fixture.apply(update)
        let comicRootURL = fixture.layout.libraryURL(for: fixture.comicID)

        // 结果章节序：替换话原位、缺失话移除、新增话追加。
        XCTAssertEqual(
            result.descriptor.chapters.map(\.originalName),
            ["Chapter 1", "Chapter 3"]
        )
        XCTAssertEqual(result.descriptor.chapters.count, 2)
        XCTAssertEqual(
            result.descriptor.workItems.count,
            5
        )
        XCTAssertEqual(
            result.descriptor.workItems.first?.id,
            fixture.originalDescriptor.coverPageID
        )
        XCTAssertNotEqual(
            result.descriptor.revision,
            fixture.originalDescriptor.revision
        )
        XCTAssertEqual(
            result.descriptor.jobID,
            fixture.originalDescriptor.jobID
        )
        XCTAssertEqual(
            result.descriptor.displayName,
            fixture.originalDescriptor.displayName
        )

        // 磁盘内容与新描述符一致。
        XCTAssertEqual(
            try Data(contentsOf: comicRootURL
                .appendingPathComponent("original/Chapter 1/02.png")),
            try Data(contentsOf: fixture.sandbox.sourceDirectoryURL
                .appendingPathComponent("Chapter 1/02.png"))
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: comicRootURL
                    .appendingPathComponent("original/Chapter 1/03.png").path
            )
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: comicRootURL
                    .appendingPathComponent("original/Chapter 3/01.png").path
            )
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: comicRootURL
                    .appendingPathComponent("original/Chapter 2/01.png").path
            ),
            "清理之前旧文件仍然存在"
        )

        // 清理只移除被取代的文件。
        try await fixture.executor.cleanupSupersededFiles(
            previousDescriptor: fixture.originalDescriptor,
            updatedDescriptor: result.descriptor
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: comicRootURL
                    .appendingPathComponent("original/Chapter 2/01.png").path
            )
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: comicRootURL
                    .appendingPathComponent("original/Chapter 2").path
            )
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: comicRootURL
                    .appendingPathComponent("original/Chapter 1/01.png").path
            )
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: comicRootURL
                    .appendingPathComponent("original/cover.png").path
            )
        )

        // 描述符与目录记录已落盘且与返回结果一致。
        let persistedDescriptor = try JSONDecoder().decode(
            ManagedComicDescriptor.self,
            from: Data(contentsOf: fixture.layout
                .libraryMetadataURL(for: fixture.comicID)
                .appendingPathComponent("import-descriptor.json"))
        )
        XCTAssertEqual(persistedDescriptor, result.descriptor)
        let persistedRecord = try JSONDecoder().decode(
            LibraryCatalogRecord.self,
            from: Data(contentsOf: fixture.layout
                .libraryCatalogURL(for: fixture.comicID))
        )
        XCTAssertEqual(persistedRecord, result.catalogRecord)
        XCTAssertEqual(persistedRecord.chapterCount, 2)

        // 来源始终只读。
        XCTAssertTrue(
            try fixture.sandbox.sourceIsUnchanged(
                since: snapshotBeforeApply
            )
        )
    }

    func testApplyFailureKeepsLibraryAndDescriptorUntouched() async throws {
        let fixture = try await makeImportedComicFixture()
        try fixture.sandbox.sourceTree.alternatePNG("Chapter 1/02.png")

        let update = try await fixture.makeUpdate(removingMissing: false)
        let libraryPageURL = fixture.layout.libraryURL(for: fixture.comicID)
            .appendingPathComponent("original/Chapter 1/02.png")
        let expectedLibraryBytes = try Data(contentsOf: libraryPageURL)
        let originalCatalogRecord = try JSONDecoder().decode(
            LibraryCatalogRecord.self,
            from: Data(contentsOf: fixture.layout
                .libraryCatalogURL(for: fixture.comicID))
        )

        // 冻结之后来源再次变化，复制阶段的校验应当失败。
        try fixture.sandbox.sourceTree.file(
            "Chapter 1/02.png",
            data: Data("diverged".utf8)
        )

        do {
            _ = try await fixture.apply(update)
            XCTFail("Expected source change failure")
        } catch let error as ComicUpdateExecutionError {
            XCTAssertEqual(error, .sourceChanged)
        }

        XCTAssertEqual(
            try Data(contentsOf: libraryPageURL),
            expectedLibraryBytes
        )
        let persistedDescriptor = try JSONDecoder().decode(
            ManagedComicDescriptor.self,
            from: Data(contentsOf: fixture.layout
                .libraryMetadataURL(for: fixture.comicID)
                .appendingPathComponent("import-descriptor.json"))
        )
        XCTAssertEqual(persistedDescriptor, fixture.originalDescriptor)
        let persistedCatalogRecord = try JSONDecoder().decode(
            LibraryCatalogRecord.self,
            from: Data(contentsOf: fixture.layout
                .libraryCatalogURL(for: fixture.comicID))
        )
        XCTAssertEqual(persistedCatalogRecord, originalCatalogRecord)
    }

    func testApplyRejectsAuthorizationForAnotherComic() async throws {
        let fixture = try await makeImportedComicFixture()
        let update = try await fixture.makeUpdate(removingMissing: false)
        let mismatchedAuthorization = ComicSourceAuthorization(
            comicID: ManagedComicID(),
            sourceRootName: fixture.authorization.sourceRootName,
            bookmark: fixture.authorization.bookmark
        )

        do {
            _ = try await fixture.executor.apply(
                descriptor: fixture.originalDescriptor,
                update: update,
                authorization: mismatchedAuthorization
            )
            XCTFail("Expected authorization mismatch failure")
        } catch let error as ComicUpdateExecutionError {
            XCTAssertEqual(error, .authorizationInvalid)
        }
    }

    func testApplyMapsStaleBookmarkToReauthorization() async throws {
        let fixture = try await makeImportedComicFixture()
        let update = try await fixture.makeUpdate(removingMissing: false)
        let staleExecutor = ComicUpdateExecutor(
            layout: fixture.layout,
            sourceAccess: FailingUpdateSourceAccess(error: .staleBookmark)
        )

        do {
            _ = try await staleExecutor.apply(
                descriptor: fixture.originalDescriptor,
                update: update,
                authorization: fixture.authorization
            )
            XCTFail("Expected stale authorization failure")
        } catch let error as ComicUpdateExecutionError {
            XCTAssertEqual(error, .staleAuthorization)
        }
    }

    // MARK: - Fixture

    private func makeImportedComicFixture() async throws
        -> UpdateExecutionFixture {
        try await UpdateExecutionFixture.make()
    }
}

private final class UpdateExecutionFixture {
    let sandbox: TemporaryImportSandbox
    let layout: ImportStorageLayout
    let comicID: ManagedComicID
    let originalDescriptor: ManagedComicDescriptor
    let authorization: ComicSourceAuthorization
    let executor: ComicUpdateExecutor
    let sourceSnapshot: SourceSnapshot

    private init(
        sandbox: TemporaryImportSandbox,
        layout: ImportStorageLayout,
        comicID: ManagedComicID,
        originalDescriptor: ManagedComicDescriptor,
        authorization: ComicSourceAuthorization,
        sourceSnapshot: SourceSnapshot
    ) {
        self.sandbox = sandbox
        self.layout = layout
        self.comicID = comicID
        self.originalDescriptor = originalDescriptor
        self.authorization = authorization
        self.sourceSnapshot = sourceSnapshot
        executor = ComicUpdateExecutor(
            layout: layout,
            sourceAccess: StubExecutorSourceAccess(
                resolvedURL: sandbox.sourceDirectoryURL
            )
        )
    }

    static func make() async throws -> UpdateExecutionFixture {
        let sandbox = try TemporaryImportSandbox(sourceName: "Update Target")
        try sandbox.sourceTree.png("cover.png")
        try sandbox.sourceTree.png("Chapter 1/01.png")
        try sandbox.sourceTree.png("Chapter 1/02.png")
        try sandbox.sourceTree.png("Chapter 2/01.png")
        let sourceSnapshot = try sandbox.sourceSnapshot()

        let locale = Locale(identifier: "en_US")
        let manifest = try await ImportScanner().scan(
            ImportScanRequest(rootURL: sandbox.sourceDirectoryURL, locale: locale)
        )
        let draft = ImportPreviewDraft(manifest: manifest)
        let comicID = ManagedComicID(
            rawValue: UUID(
                uuidString: "00000000-0000-0000-0000-000000000401"
            )!
        )
        let layout = ImportStorageLayout(rootURL: sandbox.appManagedRootURL)
        let engine = RecoverableImportEngine(
            layout: layout,
            sourceAccess: StubExecutorSourceAccess(
                resolvedURL: sandbox.sourceDirectoryURL
            ),
            capacityProvider: MaxCapacityProvider(),
            thumbnailGenerator: StubThumbnailGenerator()
        )
        let queued = try await engine.enqueue(
            draft,
            sourceURL: sandbox.sourceDirectoryURL,
            targetComicID: comicID
        )
        let completed = try await engine.run(queued.id)
        guard completed.state.phase == .completed else {
            throw UpdateExecutionFixtureError.importDidNotComplete
        }

        guard let authorization = ComicSourceAuthorizationStore(layout: layout)
            .load(for: comicID) else {
            throw UpdateExecutionFixtureError.authorizationMissing
        }

        let descriptor = try JSONDecoder().decode(
            ManagedComicDescriptor.self,
            from: Data(contentsOf: layout
                .libraryMetadataURL(for: comicID)
                .appendingPathComponent("import-descriptor.json"))
        )

        return UpdateExecutionFixture(
            sandbox: sandbox,
            layout: layout,
            comicID: comicID,
            originalDescriptor: descriptor,
            authorization: authorization,
            sourceSnapshot: sourceSnapshot
        )
    }

    /// 依据当前来源重新扫描并冻结一次默认决策的更新。
    func makeUpdate(removingMissing: Bool) async throws -> FrozenComicUpdate {
        let manifest = try await ImportScanner().scan(
            ImportScanRequest(
                rootURL: sandbox.sourceDirectoryURL,
                locale: Locale(identifier: "en_US")
            )
        )
        let diff = ImportUpdateDiffCalculator.make(
            storedChapters: originalDescriptor.chapters,
            storedWorkItems: originalDescriptor.workItems,
            freshManifest: manifest
        )
        var draft = ComicUpdateDraft(
            scan: ComicSourceUpdateScan(
                descriptor: originalDescriptor,
                freshManifest: manifest,
                diff: diff
            )
        )

        if removingMissing {
            for missing in diff.missingChapters {
                try draft.setMissingChapterRemoved(
                    missing.chapterID,
                    isRemoved: true
                )
            }
        }

        return try draft.freeze()
    }

    func apply(
        _ update: FrozenComicUpdate
    ) async throws -> ManagedComicUpdateResult {
        try await executor.apply(
            descriptor: originalDescriptor,
            update: update,
            authorization: authorization
        )
    }
}

private enum UpdateExecutionFixtureError: Error {
    case importDidNotComplete
    case authorizationMissing
}

private struct StubExecutorSourceAccess: ImportSourceAccessing {
    let resolvedURL: URL
    let resolveError: ImportSourceAccessError?

    init(
        resolvedURL: URL,
        resolveError: ImportSourceAccessError? = nil
    ) {
        self.resolvedURL = resolvedURL
        self.resolveError = resolveError
    }

    func makeBookmark(for sourceURL: URL) throws -> Data {
        Data("test-bookmark".utf8)
    }

    func resolveBookmark(_ bookmark: Data) throws -> URL {
        if let resolveError {
            throw resolveError
        }

        return resolvedURL
    }

    func startAccessing(_ sourceURL: URL) throws {}

    func stopAccessing(_ sourceURL: URL) {}
}

private struct FailingUpdateSourceAccess: ImportSourceAccessing {
    let error: ImportSourceAccessError

    func makeBookmark(for sourceURL: URL) throws -> Data {
        Data("test-bookmark".utf8)
    }

    func resolveBookmark(_ bookmark: Data) throws -> URL {
        throw error
    }

    func startAccessing(_ sourceURL: URL) throws {}

    func stopAccessing(_ sourceURL: URL) {}
}

private struct MaxCapacityProvider: ImportCapacityProviding {
    func availableBytes(at destinationRoot: URL) throws -> Int64 {
        .max
    }
}

private struct StubThumbnailGenerator: ImportThumbnailGenerating {
    func generate(from coverURL: URL, to thumbnailURL: URL) async throws {
        try FileManager.default.createDirectory(
            at: thumbnailURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("thumbnail".utf8).write(to: thumbnailURL, options: .atomic)
    }
}
