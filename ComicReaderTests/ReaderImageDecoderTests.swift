import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import ComicReader

final class ReaderImageDecoderTests: XCTestCase {
    func testMaximumPixelTargetRejectsNonPositiveValuesAndCapsLargeValues() throws {
        for value in [0, -1, Int.min] {
            XCTAssertThrowsError(
                try ReaderImageTarget(maximumPixelSize: value)
            ) { error in
                XCTAssertEqual(
                    error as? ReaderImageTargetError,
                    .invalidMaximumPixelSize
                )
            }
        }

        XCTAssertEqual(
            try ReaderImageTarget(maximumPixelSize: 321).maximumPixelSize,
            321
        )
        XCTAssertEqual(
            try ReaderImageTarget(maximumPixelSize: Int.max).maximumPixelSize,
            ReaderImageTarget.maximumDecodedPixelSize
        )
    }

    func testDisplayTargetRoundsUpAndCapsDecodedPixelSize() throws {
        XCTAssertEqual(
            try ReaderImageTarget(
                displaySize: CGSize(width: 100.1, height: 50),
                displayScale: 2
            ).maximumPixelSize,
            201
        )
        XCTAssertEqual(
            try ReaderImageTarget(
                displaySize: CGSize(width: 8_000, height: 4_000),
                displayScale: 2
            ).maximumPixelSize,
            ReaderImageTarget.maximumDecodedPixelSize
        )
    }

    func testDisplayTargetRejectsInvalidMetrics() {
        let invalidMetrics: [(CGSize, CGFloat)] = [
            (.zero, 1),
            (CGSize(width: -1, height: 10), 1),
            (CGSize(width: 10, height: -1), 1),
            (CGSize(width: CGFloat.nan, height: 10), 1),
            (CGSize(width: 10, height: CGFloat.infinity), 1),
            (CGSize(width: 10, height: 10), 0),
            (CGSize(width: 10, height: 10), -1),
            (CGSize(width: 10, height: 10), CGFloat.nan),
            (CGSize(width: 10, height: 10), CGFloat.infinity),
        ]

        for (displaySize, displayScale) in invalidMetrics {
            XCTAssertThrowsError(
                try ReaderImageTarget(
                    displaySize: displaySize,
                    displayScale: displayScale
                )
            ) { error in
                XCTAssertEqual(
                    error as? ReaderImageTargetError,
                    .invalidDisplayMetrics
                )
            }
        }
    }

    func testDownsamplesPNGToTargetWithoutUpscalingSmallSource() async throws {
        let tree = try TemporaryComicTree(name: "Decoder PNG")
        let relativePath = "original/chapter/page.png"
        let sourceWidth = 120
        let sourceHeight = 80
        try tree.file(
            relativePath,
            data: try makePNGData(width: sourceWidth, height: sourceHeight)
        )
        let asset = try makeAsset(
            rootURL: tree.rootURL,
            relativePath: relativePath,
            mediaType: .png
        )
        let decoder = ImageIOReaderImageDecoder()

        let downsampled = try await decoder.decode(
            ReaderImageDecodeRequest(
                asset: asset,
                target: try ReaderImageTarget(maximumPixelSize: 40)
            )
        )
        let fullSize = try await decoder.decode(
            ReaderImageDecodeRequest(
                asset: asset,
                target: try ReaderImageTarget(maximumPixelSize: 1_000)
            )
        )

        XCTAssertEqual(max(downsampled.image.width, downsampled.image.height), 40)
        XCTAssertLessThan(downsampled.image.width, sourceWidth)
        XCTAssertLessThan(downsampled.image.height, sourceHeight)
        XCTAssertEqual(fullSize.image.width, sourceWidth)
        XCTAssertEqual(fullSize.image.height, sourceHeight)
        XCTAssertGreaterThan(downsampled.estimatedByteCount, 0)
        XCTAssertGreaterThan(fullSize.estimatedByteCount, 0)
    }

    func testAppliesRightEXIFOrientationDuringDecode() async throws {
        let tree = try TemporaryComicTree(name: "Decoder Orientation")
        let relativePath = "original/chapter/right.jpg"
        try tree.jpegWithRightOrientation(relativePath)
        let asset = try makeAsset(
            rootURL: tree.rootURL,
            relativePath: relativePath,
            mediaType: .jpeg,
            expectedPixelSize: ImportPixelSize(width: 2, height: 3),
            orientation: .right
        )

        let decoded = try await ImageIOReaderImageDecoder().decode(
            ReaderImageDecodeRequest(
                asset: asset,
                target: try ReaderImageTarget(maximumPixelSize: 100)
            )
        )

        XCTAssertEqual(decoded.image.width, 3)
        XCTAssertEqual(decoded.image.height, 2)
    }

    func testDecodesEverySupportedImageFormat() async throws {
        let tree = try TemporaryComicTree(name: "Decoder Formats")
        let fixtures: [(TestImageFormat, ImportImageMediaType)] = [
            (.jpeg, .jpeg),
            (.png, .png),
            (.webP, .webP),
            (.heic, .heic),
            (.heif, .heif),
            (.gif, .gif),
            (.bmp, .bmp),
            (.tiff, .tiff),
        ]
        let decoder = ImageIOReaderImageDecoder()

        for (index, fixture) in fixtures.enumerated() {
            let relativePath = "original/chapter/\(index).data"
            try tree.image(relativePath, format: fixture.0)
            let asset = try makeAsset(
                rootURL: tree.rootURL,
                relativePath: relativePath,
                mediaType: fixture.1,
                pageID: pageID("format-\(index)")
            )

            let decoded = try await decoder.decode(
                ReaderImageDecodeRequest(
                    asset: asset,
                    target: try ReaderImageTarget(maximumPixelSize: 100)
                )
            )

            XCTAssertGreaterThan(decoded.image.width, 0, "Format: \(fixture.0)")
            XCTAssertGreaterThan(decoded.image.height, 0, "Format: \(fixture.0)")
            XCTAssertLessThanOrEqual(
                max(decoded.image.width, decoded.image.height),
                100,
                "Format: \(fixture.0)"
            )
        }
    }

    func testReportsUnreadableImageAndTruncatedPixelDataPrecisely() async throws {
        let tree = try TemporaryComicTree(name: "Decoder Corruption")
        let unreadablePath = "original/chapter/not-image.bin"
        let truncatedPath = "original/chapter/truncated.jpg"
        try tree.file(unreadablePath, data: Data("not an image".utf8))
        try tree.truncatedJPEGWithMetadata(truncatedPath)
        let unreadablePageID = pageID("not-image")
        let truncatedPageID = pageID("truncated")
        let unreadableAsset = try makeAsset(
            rootURL: tree.rootURL,
            relativePath: unreadablePath,
            mediaType: .png,
            pageID: unreadablePageID
        )
        let truncatedAsset = try makeAsset(
            rootURL: tree.rootURL,
            relativePath: truncatedPath,
            mediaType: .jpeg,
            pageID: truncatedPageID
        )

        await assertDecodeError(
            .sourceCannotBeOpened(unreadablePageID),
            asset: unreadableAsset
        )
        await assertDecodeError(
            .imageCannotBeDecoded(truncatedPageID),
            asset: truncatedAsset
        )
    }

    func testReportsMissingManagedFileAndExactSizeMismatch() async throws {
        let tree = try TemporaryComicTree(name: "Decoder Validation")
        let missingPageID = pageID("missing")
        let missingAsset = makeAsset(
            rootURL: tree.rootURL,
            relativePath: "original/chapter/missing.png",
            mediaType: .png,
            expectedByteCount: 10,
            pageID: missingPageID
        )
        let relativePath = "original/chapter/page.png"
        let fileURL = try tree.png(relativePath)
        let actualByteCount = try byteCount(of: fileURL)
        let mismatchedPageID = pageID("size-mismatch")
        let mismatchedAsset = makeAsset(
            rootURL: tree.rootURL,
            relativePath: relativePath,
            mediaType: .png,
            expectedByteCount: actualByteCount + 1,
            pageID: mismatchedPageID
        )

        await assertDecodeError(
            .managedFileUnavailable(missingPageID),
            asset: missingAsset
        )
        await assertDecodeError(
            .fileSizeMismatch(
                pageID: mismatchedPageID,
                expected: actualByteCount + 1,
                actual: actualByteCount
            ),
            asset: mismatchedAsset
        )
    }

    func testRejectsManagedPathOutsideOriginalNamespace() async throws {
        let tree = try TemporaryComicTree(name: "Decoder Namespace")
        let relativePath = "metadata/page.png"
        try tree.png(relativePath)
        let invalidPageID = pageID("invalid-namespace")
        let asset = try makeAsset(
            rootURL: tree.rootURL,
            relativePath: relativePath,
            mediaType: .png,
            pageID: invalidPageID
        )

        await assertDecodeError(
            .invalidManagedPath(invalidPageID),
            asset: asset
        )
    }

    func testRejectsMissingAndNonDirectoryComicRoots() async throws {
        let tree = try TemporaryComicTree(name: "Decoder Roots")
        let missingPageID = pageID("missing-root")
        let missingRoot = tree.rootURL.appendingPathComponent(
            "missing-root",
            isDirectory: true
        )
        let missingRootAsset = makeAsset(
            rootURL: missingRoot,
            relativePath: "original/chapter/page.png",
            mediaType: .png,
            expectedByteCount: 1,
            pageID: missingPageID
        )
        let rootFileURL = try tree.file(
            "root-file",
            data: Data("file, not directory".utf8)
        )
        let fileRootPageID = pageID("file-root")
        let fileRootAsset = makeAsset(
            rootURL: rootFileURL,
            relativePath: "original/chapter/page.png",
            mediaType: .png,
            expectedByteCount: 1,
            pageID: fileRootPageID
        )

        await assertDecodeError(
            .comicRootUnavailable(missingPageID),
            asset: missingRootAsset
        )
        await assertDecodeError(
            .comicRootUnavailable(fileRootPageID),
            asset: fileRootAsset
        )
    }

    func testRejectsComicRootSymbolicLink() async throws {
        let tree = try TemporaryComicTree(name: "Decoder Root Symlink")
        let realRootURL = try tree.directory("real-root")
        let relativePath = "original/chapter/page.png"
        let realFileURL = try tree.png("real-root/\(relativePath)")
        let linkedRootURL = try tree.symbolicLink(
            "linked-root",
            destinationURL: realRootURL
        )
        let linkedRootPageID = pageID("linked-root")
        let asset = makeAsset(
            rootURL: linkedRootURL,
            relativePath: relativePath,
            mediaType: .png,
            expectedByteCount: try byteCount(of: realFileURL),
            pageID: linkedRootPageID
        )

        await assertDecodeError(
            .symbolicLinkUnsupported(linkedRootPageID),
            asset: asset
        )
    }

    func testRejectsLeafSymbolicLink() async throws {
        let tree = try TemporaryComicTree(name: "Decoder Leaf Symlink")
        let realFileURL = try tree.png("real/page.png")
        let relativePath = "original/chapter/page.png"
        try tree.symbolicLink(relativePath, destinationURL: realFileURL)
        let linkedPageID = pageID("linked-leaf")
        let asset = makeAsset(
            rootURL: tree.rootURL,
            relativePath: relativePath,
            mediaType: .png,
            expectedByteCount: try byteCount(of: realFileURL),
            pageID: linkedPageID
        )

        await assertDecodeError(
            .symbolicLinkUnsupported(linkedPageID),
            asset: asset
        )
    }

    func testRejectsIntermediateSymbolicLinkBeforeItCanEscapeComicRoot() async throws {
        let tree = try TemporaryComicTree(name: "Decoder Containment")
        let outsideChapterURL = try tree.directory("outside/chapter")
        let outsideFileURL = try tree.png("outside/chapter/page.png")
        try tree.directory("comic/original")
        try tree.symbolicLink(
            "comic/original/chapter",
            destinationURL: outsideChapterURL
        )
        let escapedPageID = pageID("escaped-intermediate")
        let asset = makeAsset(
            rootURL: tree.rootURL.appendingPathComponent(
                "comic",
                isDirectory: true
            ),
            relativePath: "original/chapter/page.png",
            mediaType: .png,
            expectedByteCount: try byteCount(of: outsideFileURL),
            pageID: escapedPageID
        )

        await assertDecodeError(
            .symbolicLinkUnsupported(escapedPageID),
            asset: asset
        )
    }

    private func assertDecodeError(
        _ expectedError: ReaderImageDecodeError,
        asset: ReaderPageAsset,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await ImageIOReaderImageDecoder().decode(
                ReaderImageDecodeRequest(
                    asset: asset,
                    target: try ReaderImageTarget(maximumPixelSize: 100)
                )
            )
            XCTFail("Expected decoding to fail.", file: file, line: line)
        } catch {
            XCTAssertEqual(
                error as? ReaderImageDecodeError,
                expectedError,
                file: file,
                line: line
            )
        }
    }

    private func makeAsset(
        rootURL: URL,
        relativePath: String,
        mediaType: ImportImageMediaType,
        expectedByteCount: Int64,
        pageID: ImportPageCandidate.ID,
        expectedPixelSize: ImportPixelSize? = nil,
        orientation: ImportImageOrientation? = nil
    ) -> ReaderPageAsset {
        ReaderPageAsset(
            identity: ReaderPageAssetIdentity(
                comicID: ManagedComicID(
                    rawValue: UUID(
                        uuidString: "00000000-0000-0000-0000-000000000801"
                    )!
                ),
                revision: ImportPreviewRevision(
                    rawValue: "decoder-test-revision"
                ),
                pageID: pageID
            ),
            comicRootURL: rootURL,
            managedRelativePath: ManagedRelativePath(
                components: relativePath.split(separator: "/").map(String.init)
            ),
            mediaType: mediaType,
            expectedByteCount: expectedByteCount,
            expectedPixelSize: expectedPixelSize,
            orientation: orientation
        )
    }

    private func makeAsset(
        rootURL: URL,
        relativePath: String,
        mediaType: ImportImageMediaType,
        pageID: ImportPageCandidate.ID = ImportPageCandidate.ID(
            rawValue: "page"
        ),
        expectedPixelSize: ImportPixelSize? = nil,
        orientation: ImportImageOrientation? = nil
    ) throws -> ReaderPageAsset {
        let fileURL = rootURL.appendingPathComponent(relativePath)

        return makeAsset(
            rootURL: rootURL,
            relativePath: relativePath,
            mediaType: mediaType,
            expectedByteCount: try byteCount(of: fileURL),
            pageID: pageID,
            expectedPixelSize: expectedPixelSize,
            orientation: orientation
        )
    }

    private func pageID(_ rawValue: String) -> ImportPageCandidate.ID {
        ImportPageCandidate.ID(rawValue: rawValue)
    }

    private func byteCount(of url: URL) throws -> Int64 {
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        return Int64(try XCTUnwrap(values.fileSize))
    }

    private func makePNGData(width: Int, height: Int) throws -> Data {
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw TestImageError.cannotCreateImage
        }
        context.setFillColor(
            red: 0.2,
            green: 0.4,
            blue: 0.8,
            alpha: 1
        )
        context.fill(
            CGRect(
                x: 0,
                y: 0,
                width: CGFloat(width),
                height: CGFloat(height)
            )
        )

        guard let image = context.makeImage() else {
            throw TestImageError.cannotCreateImage
        }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output as CFMutableData,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            throw TestImageError.cannotCreateImage
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw TestImageError.cannotCreateImage
        }

        return output as Data
    }
}

private enum TestImageError: Error {
    case cannotCreateImage
}
