import Foundation
import XCTest
@testable import ComicReader

final class ImportScannerTests: XCTestCase {
    func testRecognizesNaturallySortedChaptersAndImagesByContent() async throws {
        let tree = try TemporaryComicTree()
        try tree.png("chapter10/page10.dat")
        try tree.png("chapter10/page2")
        try tree.png("chapter2/cover-with-wrong-extension.bin")

        let manifest = try await ImportScanner().scan(
            ImportScanRequest(
                rootURL: tree.rootURL,
                locale: Locale(identifier: "en_US_POSIX")
            )
        )

        XCTAssertEqual(manifest.sourceRootName, "Test Comic")
        XCTAssertEqual(
            manifest.chapters.map(\.sourceDirectoryPath.stringValue),
            ["chapter2", "chapter10"]
        )
        let lastChapter = try XCTUnwrap(manifest.chapters.last)
        XCTAssertEqual(
            manifest.pages(in: lastChapter).map(\.originalFileName),
            ["page2", "page10.dat"]
        )
        XCTAssertEqual(manifest.pages.count, 3)
        XCTAssertEqual(manifest.readablePageCount, 3)
    }

    func testPreservesNestedCollectionsAndCreatesLoosePagesChapterForMixedDirectory() async throws {
        let tree = try TemporaryComicTree()
        try tree.png("volume1/loose-page.png")
        try tree.png("volume1/chapter1/page.png")
        try tree.png("volume1/chapter2/page.png")

        let manifest = try await ImportScanner().scan(
            ImportScanRequest(
                rootURL: tree.rootURL,
                locale: Locale(identifier: "en_US_POSIX")
            )
        )

        let volume = try XCTUnwrap(manifest.collections.first)
        XCTAssertNil(volume.parentID)
        XCTAssertEqual(volume.sourceRelativePath.stringValue, "volume1")
        XCTAssertEqual(volume.siblingIndex, 0)

        let loosePagesChapter = try XCTUnwrap(manifest.chapters.first)
        XCTAssertEqual(loosePagesChapter.role, .collectionLoosePages)
        XCTAssertEqual(loosePagesChapter.parentCollectionID, volume.id)
        XCTAssertEqual(loosePagesChapter.sourceDirectoryPath.stringValue, "volume1")
        XCTAssertEqual(loosePagesChapter.siblingIndex, 0)
        XCTAssertEqual(
            manifest.pages(in: loosePagesChapter).map(\.originalFileName),
            ["loose-page.png"]
        )
        XCTAssertEqual(
            manifest.chapters.map(\.sourceDirectoryPath.stringValue),
            ["volume1", "volume1/chapter1", "volume1/chapter2"]
        )
        XCTAssertEqual(
            manifest.chapters.map(\.siblingIndex),
            [0, 1, 2]
        )
    }

    func testReportsSuspectedDuplicateWithoutRemovingEitherPage() async throws {
        let tree = try TemporaryComicTree()
        try tree.png("chapter/page1.png")
        try tree.png("chapter/page2.bin")

        let manifest = try await ImportScanner().scan(
            ImportScanRequest(
                rootURL: tree.rootURL,
                locale: Locale(identifier: "en_US_POSIX")
            )
        )

        let chapter = try XCTUnwrap(manifest.chapters.first)
        XCTAssertEqual(
            manifest.pages(in: chapter).map(\.originalFileName),
            ["page1.png", "page2.bin"]
        )
        XCTAssertNotNil(manifest.pages(in: chapter).first?.lightweightFingerprint)
        XCTAssertEqual(
            manifest.pages(in: chapter).first?.lightweightFingerprint,
            manifest.pages(in: chapter).last?.lightweightFingerprint
        )

        let issue = try XCTUnwrap(
            manifest.issues.first { $0.code == .suspectedDuplicate }
        )
        XCTAssertEqual(issue.severity, .information)
        XCTAssertEqual(
            issue.sourceRelativePaths.map(\.stringValue),
            ["chapter/page1.png", "chapter/page2.bin"]
        )
    }

    func testDoesNotReportSameSizeFilesWithDifferentContentAsDuplicates() async throws {
        let tree = try TemporaryComicTree()
        try tree.png("chapter/page1.png")
        try tree.alternatePNG("chapter/page2.png")

        let manifest = try await ImportScanner().scan(
            ImportScanRequest(
                rootURL: tree.rootURL,
                locale: Locale(identifier: "en_US_POSIX")
            )
        )

        XCTAssertEqual(manifest.pages.count, 2)
        XCTAssertNotEqual(
            manifest.pages.first?.lightweightFingerprint,
            manifest.pages.last?.lightweightFingerprint
        )
        XCTAssertFalse(
            manifest.issues.contains { $0.code == .suspectedDuplicate }
        )
    }
}
