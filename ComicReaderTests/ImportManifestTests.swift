import Foundation
import XCTest
@testable import ComicReader

final class ImportManifestTests: XCTestCase {
    func testSpaceEstimateRoundsMarginUpAndHandlesOverflow() {
        XCTAssertEqual(
            ImportSpaceEstimate.make(contentBytes: 0, fileCount: 0),
            ImportSpaceEstimate(
                contentBytes: 0,
                temporaryMarginBytes: 0,
                requiredAvailableBytes: 0,
                fileCount: 0
            )
        )
        XCTAssertEqual(
            ImportSpaceEstimate.make(contentBytes: 1, fileCount: 1),
            ImportSpaceEstimate(
                contentBytes: 1,
                temporaryMarginBytes: 1,
                requiredAvailableBytes: 2,
                fileCount: 1
            )
        )
        XCTAssertEqual(
            ImportSpaceEstimate.make(contentBytes: 11, fileCount: 2),
            ImportSpaceEstimate(
                contentBytes: 11,
                temporaryMarginBytes: 2,
                requiredAvailableBytes: 13,
                fileCount: 2
            )
        )

        let overflow = ImportSpaceEstimate.make(
            contentBytes: .max,
            fileCount: -1
        )
        XCTAssertEqual(overflow.requiredAvailableBytes, .max)
        XCTAssertEqual(overflow.fileCount, 0)
    }

    func testManifestIsCodableDeterministicAndDoesNotExposeAbsolutePath() async throws {
        let tree = try TemporaryComicTree(name: "Unicode 漫画")
        try tree.png("第2话/第10页.png")
        try tree.image("第2话/第2页.bin", format: .jpeg)
        let request = ImportScanRequest(
            rootURL: tree.rootURL,
            locale: Locale(identifier: "zh_CN")
        )

        let first = try await ImportScanner().scan(request)
        let second = try await ImportScanner().scan(request)
        let data = try JSONEncoder().encode(first)
        let decoded = try JSONDecoder().decode(
            ImportManifest.self,
            from: data
        )
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))

        XCTAssertEqual(first, second)
        XCTAssertEqual(decoded, first)
        XCTAssertEqual(first.schemaVersion, ImportManifest.currentSchemaVersion)
        XCTAssertFalse(json.contains(tree.rootURL.path))
        XCTAssertTrue(
            first.pages.allSatisfy {
                !$0.sourceRelativePath.stringValue.hasPrefix("/")
            }
        )
    }

    func testScannerSpaceEstimateCountsImportedAssetsAndRoundsMarginUp() async throws {
        let tree = try TemporaryComicTree()
        let coverURL = try tree.png("cover.png")
        let pageURL = try tree.image("chapter/page.bin", format: .jpeg)
        try tree.corruptedPNG("discarded/bad.png")

        let manifest = try await ImportScanner().scan(
            ImportScanRequest(
                rootURL: tree.rootURL,
                locale: Locale(identifier: "en_US_POSIX")
            )
        )
        let expectedContentBytes = try byteCount(of: coverURL)
            + byteCount(of: pageURL)

        XCTAssertEqual(
            manifest.spaceEstimate,
            .make(contentBytes: expectedContentBytes, fileCount: 2)
        )
        XCTAssertEqual(manifest.pages.count, 2)
        XCTAssertEqual(manifest.spaceEstimate.fileCount, 2)
    }

    func testRejectsMissingAndNonDirectoryRootsWithTypedErrors() async throws {
        let tree = try TemporaryComicTree()
        let missingURL = tree.rootURL.appendingPathComponent("missing")
        let fileURL = try tree.file("regular-file", data: Data())

        await assertScanError(
            .rootDoesNotExist,
            rootURL: missingURL
        )
        await assertScanError(
            .rootIsNotDirectory,
            rootURL: fileURL
        )
    }

    func testRejectsSymbolicLinkRootWithoutFollowingIt() async throws {
        let tree = try TemporaryComicTree()
        let targetURL = try tree.directory("target")
        let linkURL = try tree.symbolicLink(
            "root-link",
            destinationURL: targetURL
        )

        await assertScanError(
            .symbolicLinkRootIsUnsupported,
            rootURL: linkURL
        )
    }

    func testRejectsUnsafeSourceRelativePathDuringDecoding() {
        let data = Data(#"{"components":[".."]}"#.utf8)

        XCTAssertThrowsError(
            try JSONDecoder().decode(SourceRelativePath.self, from: data)
        )
    }

    func testCanonicalUnicodeVariantsProduceDistinctStableIDs() {
        let composed = SourceRelativePath(
            components: ["é", "page.png"]
        )
        let decomposed = SourceRelativePath(
            components: ["e\u{301}", "page.png"]
        )

        XCTAssertNotEqual(composed, decomposed)
        XCTAssertNotEqual(
            ImportPageCandidate.ID.sourcePath(composed),
            ImportPageCandidate.ID.sourcePath(decomposed)
        )
        XCTAssertEqual(
            ImportPageCandidate.ID.sourcePath(composed),
            ImportPageCandidate.ID.sourcePath(composed)
        )
    }

    private func assertScanError(
        _ expectedError: ImportScanError,
        rootURL: URL,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await ImportScanner().scan(
                ImportScanRequest(
                    rootURL: rootURL,
                    locale: Locale(identifier: "en_US_POSIX")
                )
            )
            XCTFail(
                "Expected \(expectedError), but scanning succeeded.",
                file: file,
                line: line
            )
        } catch let error as ImportScanError {
            XCTAssertEqual(error, expectedError, file: file, line: line)
        } catch {
            XCTFail(
                "Expected \(expectedError), but received \(error).",
                file: file,
                line: line
            )
        }
    }

    private func byteCount(of url: URL) throws -> Int64 {
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        return Int64(try XCTUnwrap(values.fileSize))
    }
}
