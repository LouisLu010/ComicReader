import Foundation
import XCTest
@testable import ComicReader

final class ComicExportTests: XCTestCase {
    func testPlannerPreservesSourceStructureAndIncludesStandaloneCover() {
        let fixture = makeDescriptorFixture()
        let plan = ComicExportPlanner.makePlan(descriptor: fixture.descriptor)

        XCTAssertEqual(plan.comicID, fixture.comicID)
        XCTAssertEqual(plan.displayName, "Export Comic")
        XCTAssertEqual(plan.entries.count, 4)
        XCTAssertEqual(
            plan.entries.map(\.exportRelativePath.stringValue),
            [
                "cover.png",
                "Chapter 1/01.png",
                "Chapter 1/02.png",
                "Chapter 2/01.png",
            ]
        )
        XCTAssertEqual(
            plan.entries.map(\.managedRelativePath.stringValue),
            [
                "original/cover.png",
                "original/Chapter 1/01.png",
                "original/Chapter 1/02.png",
                "original/Chapter 2/01.png",
            ]
        )
    }

    func testUniquifiedDirectoryNameAppendsSequentialSuffixes() {
        XCTAssertEqual(
            ComicExportPlanner.uniquifiedDirectoryName(
                "Comic",
                existingNames: ["Other"]
            ),
            "Comic"
        )
        XCTAssertEqual(
            ComicExportPlanner.uniquifiedDirectoryName(
                "Comic",
                existingNames: ["Comic"]
            ),
            "Comic (2)"
        )
        XCTAssertEqual(
            ComicExportPlanner.uniquifiedDirectoryName(
                "Comic",
                existingNames: ["Comic", "Comic (2)", "Comic (3)"]
            ),
            "Comic (4)"
        )
    }

    func testExportCopiesOriginalStructureWithoutTouchingLibrary()
        async throws {
        let fixture = try await makeImportedComicFixture()
        let destinationURL = fixture.makeDestinationDirectory()
        let executor = ComicExportExecutor(layout: fixture.layout)

        let exportRootURL = try await fixture.export(
            from: fixture.originalDescriptor,
            to: destinationURL,
            executor: executor
        )

        XCTAssertEqual(
            exportRootURL.lastPathComponent,
            "Export Comic"
        )
        let exportedFiles = try fixture.relativeFiles(
            under: exportRootURL
        )
        XCTAssertEqual(
            exportedFiles,
            [
                "Chapter 1/01.png",
                "Chapter 1/02.png",
                "Chapter 2/01.png",
                "cover.png",
            ]
        )
        XCTAssertEqual(
            try Data(contentsOf: exportRootURL
                .appendingPathComponent("cover.png")),
            try Data(contentsOf: fixture.sandbox.sourceDirectoryURL
                .appendingPathComponent("cover.png"))
        )
        XCTAssertEqual(
            try Data(contentsOf: exportRootURL
                .appendingPathComponent("Chapter 1/01.png")),
            try Data(contentsOf: fixture.sandbox.sourceDirectoryURL
                .appendingPathComponent("Chapter 1/01.png"))
        )

        // 库内文件不受影响，来源目录只读。
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: fixture.layout.libraryURL(for: fixture.comicID)
                    .appendingPathComponent("original/cover.png").path
            )
        )
        XCTAssertTrue(try fixture.sandbox.sourceIsUnchanged(since: fixture.sourceSnapshot))
    }

    func testExportUniquifiesDirectoryNameWhenTaken() async throws {
        let fixture = try await makeImportedComicFixture()
        let destinationURL = fixture.makeDestinationDirectory()
        try FileManager.default.createDirectory(
            at: destinationURL.appendingPathComponent(
                "Export Comic",
                isDirectory: true
            ),
            withIntermediateDirectories: true
        )
        let executor = ComicExportExecutor(layout: fixture.layout)

        let exportRootURL = try await fixture.export(
            from: fixture.originalDescriptor,
            to: destinationURL,
            executor: executor
        )

        XCTAssertEqual(exportRootURL.lastPathComponent, "Export Comic (2)")
    }

    func testExportRejectsDestinationInsideManagedRoot() async throws {
        let fixture = try await makeImportedComicFixture()
        let executor = ComicExportExecutor(layout: fixture.layout)

        do {
            _ = try await fixture.export(
                from: fixture.originalDescriptor,
                to: fixture.layout.libraryURL,
                executor: executor
            )
            XCTFail("Expected managed-destination failure")
        } catch let error as ComicExportError {
            XCTAssertEqual(error, .destinationInvalid)
        }
    }

    func testExportFailureCleansUpPartialOutput() async throws {
        let fixture = try await makeImportedComicFixture()
        // 删除一个库内文件，导出应在复制该项时失败并清理输出。
        try FileManager.default.removeItem(
            at: fixture.layout.libraryURL(for: fixture.comicID)
                .appendingPathComponent("original/Chapter 1/02.png")
        )
        let destinationURL = fixture.makeDestinationDirectory()
        let executor = ComicExportExecutor(layout: fixture.layout)

        do {
            _ = try await fixture.export(
                from: fixture.originalDescriptor,
                to: destinationURL,
                executor: executor
            )
            XCTFail("Expected missing-file failure")
        } catch let error as ComicExportError {
            XCTAssertEqual(
                error,
                .missingManagedFile(
                    SourceRelativePath(components: ["Chapter 1", "02.png"])
                )
            )
        }

        XCTAssertEqual(
            try fixture.relativeFiles(under: destinationURL),
            []
        )
    }

    func testExportRejectsUnknownComic() async throws {
        let fixture = try await makeImportedComicFixture()
        let destinationURL = fixture.makeDestinationDirectory()
        let executor = ComicExportExecutor(layout: fixture.layout)
        let unknownDescriptor = makeDescriptorFixture(
            comicID: ManagedComicID(
                rawValue: UUID(
                    uuidString: "00000000-0000-0000-0000-000000000633"
                )!
            )
        ).descriptor

        do {
            _ = try await executor.export(
                descriptor: unknownDescriptor,
                to: destinationURL
            )
            XCTFail("Expected unknown comic failure")
        } catch let error as ComicExportError {
            XCTAssertEqual(error, .comicNotFound)
        }
    }

    // MARK: - Fixture

    private func makeDescriptorFixture(
        comicID: ManagedComicID = ManagedComicID(
            rawValue: UUID(
                uuidString: "00000000-0000-0000-0000-000000000631"
            )!
        )
    ) -> PlannerFixture {
        PlannerFixture(comicID: comicID)
    }

    private func makeImportedComicFixture() async throws
        -> ImportedComicForExportFixture {
        try await ImportedComicForExportFixture.make()
    }
}

private struct PlannerFixture {
    let comicID: ManagedComicID
    let descriptor: ManagedComicDescriptor

    init(comicID: ManagedComicID) {
        func makeWorkItem(
            _ path: [String],
            isCover: Bool = false
        ) -> FrozenImportWorkItem {
            let sourcePath = SourceRelativePath(components: path)
            return FrozenImportWorkItem(
                id: ImportPageCandidate.ID.sourcePath(sourcePath),
                sourceRelativePath: sourcePath,
                managedRelativePath: ManagedRelativePath(
                    components: ["original"] + path
                ),
                originalFileName: path.last ?? "cover.png",
                detectedFormat: .png,
                expectedByteCount: 1_024,
                expectedLightweightFingerprint: "fp:\(path.joined(separator: "/"))",
                pageState: .readable,
                isCover: isCover
            )
        }

        let cover = makeWorkItem(["cover.png"], isCover: true)
        let chapterOnePages = [
            makeWorkItem(["Chapter 1", "01.png"]),
            makeWorkItem(["Chapter 1", "02.png"]),
        ]
        let chapterTwoPages = [makeWorkItem(["Chapter 2", "01.png"])]
        let workItems = [cover] + chapterOnePages + chapterTwoPages
        let plan = FrozenImportPlan(
            id: ImportJobID(
                rawValue: UUID(
                    uuidString: "00000000-0000-0000-0000-000000000632"
                )!
            ),
            revision: ImportPreviewRevision(rawValue: "export-plan-revision"),
            sourceRootName: "Export Comic",
            displayName: "Export Comic",
            sourceBookmark: Data("bookmark".utf8),
            sortLocaleIdentifier: "en_US",
            collections: [],
            chapters: [
                FrozenImportChapter(
                    id: ImportChapterCandidate.ID.sourcePath(
                        SourceRelativePath(components: ["Chapter 1"]),
                        role: .directory
                    ),
                    parentCollectionID: nil,
                    sourceDirectoryPath: SourceRelativePath(
                        components: ["Chapter 1"]
                    ),
                    originalName: "Chapter 1",
                    displayName: "Chapter 1",
                    role: .directory,
                    pageIDs: chapterOnePages.map(\.id)
                ),
                FrozenImportChapter(
                    id: ImportChapterCandidate.ID.sourcePath(
                        SourceRelativePath(components: ["Chapter 2"]),
                        role: .directory
                    ),
                    parentCollectionID: nil,
                    sourceDirectoryPath: SourceRelativePath(
                        components: ["Chapter 2"]
                    ),
                    originalName: "Chapter 2",
                    displayName: "Chapter 2",
                    role: .directory,
                    pageIDs: chapterTwoPages.map(\.id)
                ),
            ],
            workItems: workItems,
            coverPageID: cover.id,
            scanIssues: [],
            spaceEstimate: .make(contentBytes: 0, fileCount: 0)
        )
        descriptor = ManagedComicDescriptor(
            plan: plan,
            journal: ImportJobJournal(plan: plan, targetComicID: comicID)
        )
    }
}

private final class ImportedComicForExportFixture {
    let sandbox: TemporaryImportSandbox
    let layout: ImportStorageLayout
    let comicID: ManagedComicID
    let originalDescriptor: ManagedComicDescriptor
    let sourceSnapshot: SourceSnapshot

    private init(
        sandbox: TemporaryImportSandbox,
        layout: ImportStorageLayout,
        comicID: ManagedComicID,
        originalDescriptor: ManagedComicDescriptor,
        sourceSnapshot: SourceSnapshot
    ) {
        self.sandbox = sandbox
        self.layout = layout
        self.comicID = comicID
        self.originalDescriptor = originalDescriptor
        self.sourceSnapshot = sourceSnapshot
    }

    static func make() async throws -> ImportedComicForExportFixture {
        let sandbox = try TemporaryImportSandbox(sourceName: "Export Comic")
        try sandbox.sourceTree.png("cover.png")
        try sandbox.sourceTree.png("Chapter 1/01.png")
        try sandbox.sourceTree.png("Chapter 1/02.png")
        try sandbox.sourceTree.png("Chapter 2/01.png")
        let sourceSnapshot = try sandbox.sourceSnapshot()

        let manifest = try await ImportScanner().scan(
            ImportScanRequest(
                rootURL: sandbox.sourceDirectoryURL,
                locale: Locale(identifier: "en_US")
            )
        )
        let draft = ImportPreviewDraft(manifest: manifest)
        let comicID = ManagedComicID(
            rawValue: UUID(
                uuidString: "00000000-0000-0000-0000-000000000630"
            )!
        )
        let layout = ImportStorageLayout(rootURL: sandbox.appManagedRootURL)
        let engine = RecoverableImportEngine(
            layout: layout,
            sourceAccess: ExportFixtureSourceAccess(
                resolvedURL: sandbox.sourceDirectoryURL
            ),
            capacityProvider: ExportFixtureCapacityProvider(),
            thumbnailGenerator: ExportFixtureThumbnailGenerator()
        )
        let queued = try await engine.enqueue(
            draft,
            sourceURL: sandbox.sourceDirectoryURL,
            targetComicID: comicID
        )
        let completed = try await engine.run(queued.id)
        guard completed.state.phase == .completed else {
            throw ComicExportFixtureError.importDidNotComplete
        }

        let descriptor = try JSONDecoder().decode(
            ManagedComicDescriptor.self,
            from: Data(contentsOf: layout
                .libraryMetadataURL(for: comicID)
                .appendingPathComponent("import-descriptor.json"))
        )

        return ImportedComicForExportFixture(
            sandbox: sandbox,
            layout: layout,
            comicID: comicID,
            originalDescriptor: descriptor,
            sourceSnapshot: sourceSnapshot
        )
    }

    func makeDestinationDirectory() -> URL {
        let destinationURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "export-destination-\(UUID().uuidString)",
                isDirectory: true
            )
        try? FileManager.default.createDirectory(
            at: destinationURL,
            withIntermediateDirectories: true
        )
        return destinationURL
    }

    func export(
        from descriptor: ManagedComicDescriptor,
        to destinationURL: URL,
        executor: ComicExportExecutor
    ) async throws -> URL {
        try await executor.export(
            descriptor: descriptor,
            to: destinationURL
        )
    }

    func relativeFiles(under rootURL: URL) throws -> [String] {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: rootURL.path) else {
            return []
        }

        let enumerator = try XCTUnwrap(
            fileManager.enumerator(
                at: rootURL,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: []
            )
        )
        let rootComponentCount = rootURL.pathComponents.count
        var files: [String] = []

        for case let fileURL as URL in enumerator {
            let values = try fileURL.resourceValues(
                forKeys: [.isRegularFileKey]
            )
            guard values.isRegularFile == true else {
                continue
            }

            files.append(
                fileURL.pathComponents
                    .dropFirst(rootComponentCount)
                    .joined(separator: "/")
            )
        }

        return files.sorted()
    }
}

private enum ComicExportFixtureError: Error {
    case importDidNotComplete
}

private struct ExportFixtureSourceAccess: ImportSourceAccessing {
    let resolvedURL: URL

    func makeBookmark(for sourceURL: URL) throws -> Data {
        Data("test-bookmark".utf8)
    }

    func resolveBookmark(_ bookmark: Data) throws -> URL {
        resolvedURL
    }

    func startAccessing(_ sourceURL: URL) throws {}

    func stopAccessing(_ sourceURL: URL) {}
}

private struct ExportFixtureCapacityProvider: ImportCapacityProviding {
    func availableBytes(at destinationRoot: URL) throws -> Int64 {
        .max
    }
}

private struct ExportFixtureThumbnailGenerator: ImportThumbnailGenerating {
    func generate(from coverURL: URL, to thumbnailURL: URL) async throws {
        try FileManager.default.createDirectory(
            at: thumbnailURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("thumbnail".utf8).write(to: thumbnailURL, options: .atomic)
    }
}
