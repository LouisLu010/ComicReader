import Foundation
import XCTest
@testable import ComicReader

final class ImportPreviewDraftTests: XCTestCase {
    func testDefaultsPreserveManifestSelectionAndEstimate() async throws {
        let tree = try TemporaryComicTree(name: "Preview Comic")
        try tree.png("cover.png")
        try tree.png("Chapter 2/02.png")
        try tree.png("Chapter 10/10.png")

        let manifest = try await scan(tree)
        let draft = ImportPreviewDraft(manifest: manifest)

        XCTAssertEqual(draft.displayName, "Preview Comic")
        XCTAssertEqual(
            draft.includedChapterIDs,
            Set(manifest.chapters.map(\.id))
        )
        XCTAssertEqual(draft.coverPageID, manifest.coverPageID)
        XCTAssertEqual(draft.spaceEstimate, manifest.spaceEstimate)
    }

    func testFreezeExcludesDeselectedChapterButKeepsStandaloneCover() async throws {
        let tree = try TemporaryComicTree(name: "Selected Comic")
        let coverURL = try tree.png("cover.png")
        let includedURL = try tree.png("Chapter 1/01.png")
        try tree.png("Chapter 2/01.png")
        let manifest = try await scan(tree)
        let excludedChapter = try XCTUnwrap(manifest.chapters.last)
        let includedChapter = try XCTUnwrap(manifest.chapters.first)
        let coverPageID = try XCTUnwrap(manifest.coverPageID)
        var draft = ImportPreviewDraft(manifest: manifest)

        try draft.setChapterIncluded(excludedChapter.id, isIncluded: false)
        try draft.setDisplayName("Only Chapter 1")

        let plan = try draft.freeze(
            sourceBookmark: Data("bookmark".utf8),
            jobID: ImportJobID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
        )

        XCTAssertEqual(plan.displayName, "Only Chapter 1")
        XCTAssertEqual(plan.chapters.map(\.id), [includedChapter.id])
        XCTAssertEqual(
            Set(plan.workItems.map(\.sourceRelativePath)),
            Set([
                SourceRelativePath(components: [coverURL.lastPathComponent]),
                SourceRelativePath(components: ["Chapter 1", includedURL.lastPathComponent]),
            ])
        )
        XCTAssertEqual(
            plan.spaceEstimate,
            .make(
                contentBytes: try byteCount(of: coverURL)
                    + (try byteCount(of: includedURL)),
                fileCount: 2
            )
        )
        XCTAssertTrue(
            plan.workItems.contains { $0.id == coverPageID && $0.isCover }
        )
        XCTAssertEqual(
            Set(plan.workItems.map(\.managedRelativePath.components)),
            Set([
                ["original", coverURL.lastPathComponent],
                ["original", "Chapter 1", includedURL.lastPathComponent],
            ])
        )
    }

    func testChapterMovesStayInsideTheirCollection() async throws {
        let tree = try TemporaryComicTree(name: "Ordered Comic")
        try tree.png("Volume 1/Chapter 1/01.png")
        try tree.png("Volume 1/Chapter 2/01.png")
        try tree.png("Volume 2/Chapter 3/01.png")
        let manifest = try await scan(tree)
        let volumeOneChapters = manifest.chapters.filter {
            $0.sourceDirectoryPath.components.first == "Volume 1"
        }
        let volumeTwoChapter = try XCTUnwrap(
            manifest.chapters.first {
                $0.sourceDirectoryPath.components.first == "Volume 2"
            }
        )
        let first = try XCTUnwrap(volumeOneChapters.first)
        let second = try XCTUnwrap(volumeOneChapters.last)
        var draft = ImportPreviewDraft(manifest: manifest)

        try draft.moveChapter(second.id, before: first.id)

        XCTAssertEqual(
            draft.chapterOrder(for: first.parentCollectionID),
            [second.id, first.id]
        )
        try draft.moveChapter(second.id, before: second.id)
        XCTAssertEqual(
            draft.chapterOrder(for: first.parentCollectionID),
            [second.id, first.id]
        )
        XCTAssertThrowsError(
            try draft.moveChapter(first.id, before: volumeTwoChapter.id)
        ) { error in
            XCTAssertEqual(error as? ImportPreviewDraftError, .crossCollectionMove)
        }
    }

    func testUnreadableCoverIsRejectedAndFrozenRevisionIsStable() async throws {
        let tree = try TemporaryComicTree(name: "Revision Comic")
        try tree.png("Chapter/01.png")
        try tree.corruptedPNG("Chapter/bad.png")
        let manifest = try await scan(tree)
        let corruptPage = try XCTUnwrap(
            manifest.pages.first(where: { $0.state == .corrupted })
        )
        var draft = ImportPreviewDraft(manifest: manifest)

        XCTAssertThrowsError(try draft.setCoverPage(corruptPage.id)) { error in
            XCTAssertEqual(error as? ImportPreviewDraftError, .coverMustBeReadable)
        }

        let first = try draft.freeze(
            sourceBookmark: Data("bookmark".utf8),
            jobID: ImportJobID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
        )
        let second = try draft.freeze(
            sourceBookmark: Data("bookmark".utf8),
            jobID: ImportJobID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!)
        )
        let data = try JSONEncoder().encode(first)

        XCTAssertEqual(first.revision, second.revision)
        XCTAssertNotEqual(first.id, second.id)
        XCTAssertEqual(first.sourceBookmark, Data("bookmark".utf8))
        XCTAssertEqual(try JSONDecoder().decode(FrozenImportPlan.self, from: data), first)
    }

    func testFrozenPlanExcludesIssuesFromDeselectedDirectories() async throws {
        let tree = try TemporaryComicTree(name: "Issue Scope")
        try tree.png("Included/01.png")
        try tree.corruptedPNG("Excluded/bad.png")
        let manifest = try await scan(tree)
        let draft = ImportPreviewDraft(manifest: manifest)
        let plan = try draft.freeze(sourceBookmark: Data("bookmark".utf8))

        XCTAssertTrue(
            manifest.issues.contains {
                $0.sourceRelativePaths.contains(
                    SourceRelativePath(components: ["Excluded"])
                )
            }
        )
        XCTAssertFalse(
            plan.scanIssues.contains {
                $0.sourceRelativePaths.contains(
                    SourceRelativePath(components: ["Excluded"])
                )
            }
        )
    }

    private func scan(_ tree: TemporaryComicTree) async throws -> ImportManifest {
        try await ImportScanner().scan(
            ImportScanRequest(
                rootURL: tree.rootURL,
                locale: Locale(identifier: "en_US_POSIX")
            )
        )
    }

    private func byteCount(of url: URL) throws -> Int64 {
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        return Int64(try XCTUnwrap(values.fileSize))
    }
}
