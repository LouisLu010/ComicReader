import Foundation
import XCTest
@testable import ComicReader

final class ComicMetadataEditTests: XCTestCase {
    func testValidatedDisplayNameTrimsAndRejectsBlank() {
        XCTAssertEqual(
            ComicMetadataEditPolicy.validatedDisplayName("  新名字  "),
            "新名字"
        )
        XCTAssertNil(
            ComicMetadataEditPolicy.validatedDisplayName("   \n\t ")
        )
    }

    func testOnlyReadableExistingPagesAreSelectableCovers() {
        let fixture = MetadataEditFixture()
        let readableID = ImportPageCandidate.ID(rawValue: "page-readable")
        let corruptedID = ImportPageCandidate.ID(rawValue: "page-corrupted")
        let missingID = ImportPageCandidate.ID(rawValue: "page-missing")

        XCTAssertTrue(
            ComicMetadataEditPolicy.isSelectableCoverPage(
                readableID,
                in: fixture.descriptor
            )
        )
        XCTAssertFalse(
            ComicMetadataEditPolicy.isSelectableCoverPage(
                corruptedID,
                in: fixture.descriptor
            )
        )
        XCTAssertFalse(
            ComicMetadataEditPolicy.isSelectableCoverPage(
                missingID,
                in: fixture.descriptor
            )
        )
    }

    func testApplyingDisplayNameKeepsEverythingElse() {
        let fixture = MetadataEditFixture()
        let originalRevision = fixture.descriptor.revision

        let updated = ComicMetadataEditPolicy.applying(
            displayName: "Renamed Comic",
            to: fixture.descriptor
        )

        XCTAssertEqual(updated.displayName, "Renamed Comic")
        XCTAssertNotEqual(updated.revision, originalRevision)
        XCTAssertEqual(updated.jobID, fixture.descriptor.jobID)
        XCTAssertEqual(updated.coverPageID, fixture.descriptor.coverPageID)
        XCTAssertEqual(updated.chapters, fixture.descriptor.chapters)
        XCTAssertEqual(
            updated.workItems.map(\.id),
            fixture.descriptor.workItems.map(\.id)
        )
    }

    func testApplyingCoverMovesCoverFlags() {
        let fixture = MetadataEditFixture()
        let newCoverID = ImportPageCandidate.ID(rawValue: "page-readable")

        let updated = ComicMetadataEditPolicy.applying(
            coverPageID: newCoverID,
            to: fixture.descriptor
        )

        XCTAssertEqual(updated.coverPageID, newCoverID)
        let coverItems = updated.workItems.filter(\.isCover)
        XCTAssertEqual(coverItems.map(\.id), [newCoverID])
        XCTAssertNotEqual(updated.revision, fixture.descriptor.revision)
    }

    func testEditorAppliesRenameAndWritesCatalogRecord() async throws {
        let fixture = try MetadataEditorFixture()

        let updated = try await fixture.editor.apply(
            comicID: fixture.comicID,
            displayName: "Renamed Comic"
        )

        XCTAssertEqual(updated.displayName, "Renamed Comic")

        let persisted = try await fixture.editor.loadDescriptor(
            comicID: fixture.comicID
        )
        XCTAssertEqual(persisted, updated)

        let catalogRecord = try JSONDecoder().decode(
            LibraryCatalogRecord.self,
            from: Data(contentsOf: fixture.layout
                .libraryCatalogURL(for: fixture.comicID))
        )
        XCTAssertEqual(catalogRecord.displayName, "Renamed Comic")
    }

    func testEditorAppliesCoverChangeAndRegeneratesThumbnail() async throws {
        let fixture = try MetadataEditorFixture()
        let newCoverID = ImportPageCandidate.ID(rawValue: "page-readable")

        _ = try await fixture.editor.apply(
            comicID: fixture.comicID,
            coverPageID: newCoverID
        )

        let persisted = try await fixture.editor.loadDescriptor(
            comicID: fixture.comicID
        )
        XCTAssertEqual(persisted.coverPageID, newCoverID)
        XCTAssertEqual(
            fixture.thumbnailGenerator.generatedCoverFileNames,
            ["page-readable"]
        )
    }

    func testEditorRejectsInvalidEdits() async throws {
        let fixture = try MetadataEditorFixture()

        do {
            _ = try await fixture.editor.apply(
                comicID: fixture.comicID,
                displayName: "   "
            )
            XCTFail("Expected invalid display name failure")
        } catch let error as ComicMetadataEditorError {
            XCTAssertEqual(error, .invalidDisplayName)
        }

        do {
            _ = try await fixture.editor.apply(
                comicID: fixture.comicID,
                coverPageID: ImportPageCandidate.ID(rawValue: "page-corrupted")
            )
            XCTFail("Expected invalid cover failure")
        } catch let error as ComicMetadataEditorError {
            XCTAssertEqual(error, .invalidCoverPage)
        }
    }
}

/// 一次性构建含独立封面、可读页与损坏页的描述符，并写入
/// 沙盒资料库供编辑服务读写。
private struct MetadataEditFixture {
    let layout: ImportStorageLayout
    let comicID: ManagedComicID
    let descriptor: ManagedComicDescriptor
    let editor: FileSystemComicMetadataEditor
    let thumbnailGenerator: RecordingThumbnailGenerator

    init() throws {
        let sandboxRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "metadata-edit-\(UUID().uuidString)",
                isDirectory: true
            )
        layout = ImportStorageLayout(rootURL: sandboxRoot)
        comicID = ManagedComicID(
            rawValue: UUID(
                uuidString: "00000000-0000-0000-0000-000000000641"
            )!
        )

        func makeWorkItem(
            _ id: String,
            pageState: ImportPageState,
            isCover: Bool = false
        ) -> FrozenImportWorkItem {
            let sourcePath = SourceRelativePath(components: [id])
            return FrozenImportWorkItem(
                id: ImportPageCandidate.ID(rawValue: id),
                sourceRelativePath: sourcePath,
                managedRelativePath: ManagedRelativePath(
                    components: ["original", id]
                ),
                originalFileName: "\(id).png",
                detectedFormat: .png,
                expectedByteCount: 1_024,
                expectedLightweightFingerprint: "fp:\(id)",
                pageState: pageState,
                isCover: isCover
            )
        }

        let standaloneCover = makeWorkItem(
            "cover",
            pageState: .readable,
            isCover: true
        )
        let readablePage = makeWorkItem("page-readable", pageState: .readable)
        let corruptedPage = makeWorkItem(
            "page-corrupted",
            pageState: .corrupted
        )
        let workItems = [standaloneCover, readablePage, corruptedPage]
        let chapterID = ImportChapterCandidate.ID.sourcePath(
            SourceRelativePath(components: ["Chapter 1"]),
            role: .directory
        )
        let plan = FrozenImportPlan(
            id: ImportJobID(
                rawValue: UUID(
                    uuidString: "00000000-0000-0000-0000-000000000642"
                )!
            ),
            revision: ImportPreviewRevision(rawValue: "metadata-revision"),
            sourceRootName: "Metadata Comic",
            displayName: "Metadata Comic",
            sourceBookmark: Data("bookmark".utf8),
            sortLocaleIdentifier: "en_US",
            collections: [],
            chapters: [
                FrozenImportChapter(
                    id: chapterID,
                    parentCollectionID: nil,
                    sourceDirectoryPath: SourceRelativePath(
                        components: ["Chapter 1"]
                    ),
                    originalName: "Chapter 1",
                    displayName: "Chapter 1",
                    role: .directory,
                    pageIDs: [readablePage.id, corruptedPage.id]
                ),
            ],
            workItems: workItems,
            coverPageID: standaloneCover.id,
            scanIssues: [],
            spaceEstimate: .make(contentBytes: 0, fileCount: 0)
        )
        descriptor = ManagedComicDescriptor(
            plan: plan,
            journal: ImportJobJournal(plan: plan, targetComicID: comicID)
        )

        thumbnailGenerator = RecordingThumbnailGenerator()
        editor = FileSystemComicMetadataEditor(
            layout: layout,
            thumbnailGenerator: thumbnailGenerator
        )

        // 写入描述符与目录记录，模拟一次已完成导入。
        let metadataURL = layout.libraryMetadataURL(for: comicID)
        try FileManager.default.createDirectory(
            at: metadataURL,
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(descriptor).write(
            to: metadataURL.appendingPathComponent("import-descriptor.json"),
            options: .atomic
        )
        try encoder.encode(
            LibraryCatalogRecord(
                descriptor: descriptor,
                importedAt: Date(timeIntervalSince1970: 500)
            )
        ).write(
            to: layout.libraryCatalogURL(for: comicID),
            options: .atomic
        )
    }
}

private final class RecordingThumbnailGenerator: ImportThumbnailGenerating {
    private let lock = NSLock()
    private var _generatedCoverFileNames: [String] = []

    var generatedCoverFileNames: [String] {
        lock.lock()
        defer { lock.unlock() }
        return _generatedCoverFileNames
    }

    func recordGeneration(coverFileName: String) {
        lock.lock()
        defer { lock.unlock() }
        _generatedCoverFileNames.append(coverFileName)
    }

    func generate(from coverURL: URL, to thumbnailURL: URL) async throws {
        recordGeneration(coverFileName: coverURL.lastPathComponent)
        try FileManager.default.createDirectory(
            at: thumbnailURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("thumbnail".utf8).write(to: thumbnailURL, options: .atomic)
    }
}
