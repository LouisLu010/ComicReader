import Foundation
import XCTest
@testable import ComicReader

final class ImportScannerRuleTests: XCTestCase {
    func testRecognizesAllSupportedFormatsWithoutTrustingExtensions() async throws {
        let tree = try TemporaryComicTree()
        let fixtures: [(String, TestImageFormat, ImportImageMediaType)] = [
            ("chapter/01.data", .jpeg, .jpeg),
            ("chapter/02", .png, .png),
            ("chapter/03.jpeg", .webP, .webP),
            ("chapter/04.bin", .heic, .heic),
            ("chapter/05.unknown", .heif, .heif),
            ("chapter/06.png", .gif, .gif),
            ("chapter/07.gif", .bmp, .bmp),
            ("chapter/08.webp", .tiff, .tiff),
        ]

        for (path, format, _) in fixtures {
            try tree.image(path, format: format)
        }

        let manifest = try await scan(tree)
        let chapter = try XCTUnwrap(manifest.chapters.first)
        let pages = manifest.pages(in: chapter)

        XCTAssertEqual(pages.count, fixtures.count)
        XCTAssertEqual(pages.map(\.state), Array(repeating: .readable, count: 8))
        XCTAssertEqual(
            pages.map(\.detectedFormat),
            fixtures.map { $0.2 }
        )
        XCTAssertTrue(
            pages.allSatisfy {
                guard let pixelSize = $0.pixelSize else {
                    return false
                }
                return pixelSize.width > 0 && pixelSize.height > 0
            }
        )
    }

    func testPreservesImageOrientationMetadata() async throws {
        let tree = try TemporaryComicTree()
        try tree.jpegWithRightOrientation("chapter/page.data")

        let manifest = try await scan(tree)
        let page = try XCTUnwrap(manifest.pages.first)

        XCTAssertEqual(page.detectedFormat, .jpeg)
        XCTAssertEqual(page.orientation, .right)
        XCTAssertEqual(page.pixelSize, ImportPixelSize(width: 2, height: 3))
    }

    func testReportsIgnoredUnsupportedAndSymbolicLinkItems() async throws {
        let tree = try TemporaryComicTree()
        try tree.png("chapter/page.png")
        try tree.directory("empty")
        try tree.png(".hidden.png")
        try tree.file(".DS_Store", data: Data("metadata".utf8))
        try tree.directory("__MACOSX")
        try tree.file("notes.pdf", data: Data("%PDF-1.7".utf8))
        try tree.symbolicLink(
            "chapter/loop",
            destinationURL: tree.rootURL
        )

        let manifest = try await scan(tree)
        let codes = manifest.issues.map(\.code)

        XCTAssertTrue(codes.contains(.emptyDirectorySkipped))
        XCTAssertTrue(codes.contains(.hiddenItemSkipped))
        XCTAssertTrue(codes.contains(.systemItemSkipped))
        XCTAssertTrue(codes.contains(.unsupportedFileType))
        XCTAssertTrue(codes.contains(.symbolicLinkSkipped))
        XCTAssertEqual(manifest.chapters.count, 1)
        XCTAssertEqual(manifest.readablePageCount, 1)
    }

    func testKeepsCorruptedPagePositionWhenChapterHasReadablePages() async throws {
        let tree = try TemporaryComicTree()
        try tree.image("chapter/page1.png", format: .png)
        try tree.corruptedPNG("chapter/page2.png")
        try tree.image("chapter/page3.png", format: .jpeg)

        let manifest = try await scan(tree)
        let chapter = try XCTUnwrap(manifest.chapters.first)
        let pages = manifest.pages(in: chapter)

        XCTAssertEqual(
            pages.map(\.state),
            [.readable, .corrupted, .readable]
        )
        XCTAssertEqual(pages.map(\.pageIndex), [0, 1, 2])
        XCTAssertTrue(
            manifest.issues.contains {
                $0.code == .corruptedImage
                    && $0.sourceRelativePaths.map(\.stringValue)
                        == ["chapter/page2.png"]
            }
        )
    }

    func testRejectsImageWithReadableMetadataButTruncatedPixels() async throws {
        let tree = try TemporaryComicTree()
        try tree.png("chapter/page1.png")
        try tree.truncatedJPEGWithMetadata("chapter/page2.jpg")

        let manifest = try await scan(tree)
        let chapter = try XCTUnwrap(manifest.chapters.first)
        let pages = manifest.pages(in: chapter)

        XCTAssertEqual(pages.map(\.state), [.readable, .corrupted])
        XCTAssertEqual(pages.last?.detectedFormat, .jpeg)
        XCTAssertTrue(
            manifest.issues.contains {
                $0.code == .corruptedImage
                    && $0.sourceRelativePaths.map(\.stringValue)
                        == ["chapter/page2.jpg"]
            }
        )
    }

    func testPrunesAllCorruptedNestedChapterButKeepsIssues() async throws {
        let tree = try TemporaryComicTree()
        try tree.corruptedPNG("volume/arc/chapter/bad.png")

        let manifest = try await scan(tree)

        XCTAssertTrue(manifest.collections.isEmpty)
        XCTAssertTrue(manifest.chapters.isEmpty)
        XCTAssertEqual(manifest.pages.count, 0)
        XCTAssertTrue(
            manifest.issues.contains {
                $0.code == .corruptedImage
                    && $0.sourceRelativePaths.map(\.stringValue)
                        == ["volume/arc/chapter/bad.png"]
            }
        )
        XCTAssertTrue(
            manifest.issues.contains {
                $0.code == .chapterHasNoReadablePages
                    && $0.sourceRelativePaths.map(\.stringValue)
                        == ["volume/arc/chapter"]
            }
        )
        XCTAssertTrue(
            manifest.issues.contains { $0.code == .noReadableChapter }
        )
    }

    func testPrefersNamedRootCoverAndExcludesOnlySelectedPage() async throws {
        let tree = try TemporaryComicTree()
        try tree.png("folder.png")
        try tree.png("封面.png")
        try tree.png("cover.bin")
        try tree.png("page1.png")

        let manifest = try await scan(tree)
        let chapter = try XCTUnwrap(manifest.chapters.first)
        let chapterPages = manifest.pages(in: chapter)

        XCTAssertEqual(manifest.coverPage?.originalFileName, "cover.bin")
        XCTAssertNil(manifest.coverPage?.pageIndex)
        XCTAssertFalse(
            chapterPages.contains { $0.id == manifest.coverPageID }
        )
        XCTAssertEqual(chapterPages.count, 3)
        XCTAssertEqual(manifest.chapterPageCount, 3)
        XCTAssertEqual(manifest.readableChapterPageCount, 3)
        XCTAssertEqual(manifest.readablePageCount, 4)
        XCTAssertEqual(manifest.pages.count, 4)
    }

    func testUsesFirstSortedRootImageAsCoverWhenNoNamedCoverExists() async throws {
        let tree = try TemporaryComicTree()
        try tree.png("page10.png")
        try tree.png("page2.png")

        let manifest = try await scan(tree)
        let chapter = try XCTUnwrap(manifest.chapters.first)

        XCTAssertEqual(manifest.coverPage?.originalFileName, "page2.png")
        XCTAssertEqual(
            manifest.pages(in: chapter).map(\.originalFileName),
            ["page10.png"]
        )
    }

    func testUsesFirstChapterPageAsCoverWithoutRemovingIt() async throws {
        let tree = try TemporaryComicTree()
        try tree.png("chapter2/page10.png")
        try tree.image("chapter2/page2.jpeg", format: .jpeg)

        let manifest = try await scan(tree)
        let chapter = try XCTUnwrap(manifest.chapters.first)
        let chapterPages = manifest.pages(in: chapter)

        XCTAssertEqual(manifest.coverPage?.originalFileName, "page2.jpeg")
        XCTAssertEqual(manifest.coverPageID, chapterPages.first?.id)
        XCTAssertEqual(chapterPages.count, 2)
    }

    func testCoverOnlyRootProducesNoReadableChapterIssue() async throws {
        let tree = try TemporaryComicTree()
        try tree.png("cover.png")

        let manifest = try await scan(tree)

        XCTAssertEqual(manifest.coverPage?.originalFileName, "cover.png")
        XCTAssertTrue(manifest.chapters.isEmpty)
        XCTAssertEqual(manifest.chapterPageCount, 0)
        XCTAssertEqual(manifest.readableChapterPageCount, 0)
        XCTAssertEqual(manifest.readablePageCount, 1)
        XCTAssertEqual(manifest.pages.count, 1)
        XCTAssertTrue(
            manifest.issues.contains { $0.code == .noReadableChapter }
        )
    }

    func testPreservesArbitraryCollectionDepthAndParentRelationships() async throws {
        let tree = try TemporaryComicTree()
        try tree.png("volume/arc/loose.png")
        try tree.png("volume/arc/chapter/page.png")

        let manifest = try await scan(tree)

        XCTAssertEqual(
            manifest.collections.map(\.sourceRelativePath.stringValue),
            ["volume", "volume/arc"]
        )
        let volume = try XCTUnwrap(manifest.collections.first)
        let arc = try XCTUnwrap(manifest.collections.last)
        XCTAssertNil(volume.parentID)
        XCTAssertEqual(arc.parentID, volume.id)

        XCTAssertEqual(
            manifest.chapters.map(\.sourceDirectoryPath.stringValue),
            ["volume/arc", "volume/arc/chapter"]
        )
        XCTAssertEqual(
            manifest.chapters.map(\.role),
            [.collectionLoosePages, .directory]
        )
        XCTAssertEqual(
            manifest.chapters.map(\.parentCollectionID),
            [arc.id, arc.id]
        )
        XCTAssertEqual(manifest.chapters.map(\.siblingIndex), [0, 1])
    }

    private func scan(_ tree: TemporaryComicTree) async throws -> ImportManifest {
        try await ImportScanner().scan(
            ImportScanRequest(
                rootURL: tree.rootURL,
                locale: Locale(identifier: "en_US_POSIX")
            )
        )
    }
}
