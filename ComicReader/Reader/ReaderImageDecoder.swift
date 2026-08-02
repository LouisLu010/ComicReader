import CoreGraphics
import Foundation
import ImageIO

enum ReaderImageTargetError: Error, Equatable, Sendable {
    case invalidMaximumPixelSize
    case invalidDisplayMetrics
}

struct ReaderImageTarget: Equatable, Hashable, Sendable {
    /// 超大图的更高倍率显示将由后续 tiled rendering 切片负责。
    static let maximumDecodedPixelSize = 4_096

    let maximumPixelSize: Int

    init(maximumPixelSize: Int) throws {
        guard maximumPixelSize > 0 else {
            throw ReaderImageTargetError.invalidMaximumPixelSize
        }

        self.maximumPixelSize = min(
            maximumPixelSize,
            Self.maximumDecodedPixelSize
        )
    }

    init(
        displaySize: CGSize,
        displayScale: CGFloat
    ) throws {
        let width = Double(displaySize.width)
        let height = Double(displaySize.height)
        let scale = Double(displayScale)

        guard width.isFinite,
              height.isFinite,
              scale.isFinite,
              width > 0,
              height > 0,
              scale > 0 else {
            throw ReaderImageTargetError.invalidDisplayMetrics
        }

        let scaledMaximumDimension = max(width, height) * scale
        guard scaledMaximumDimension.isFinite,
              scaledMaximumDimension > 0 else {
            throw ReaderImageTargetError.invalidDisplayMetrics
        }

        if scaledMaximumDimension >= Double(Self.maximumDecodedPixelSize) {
            maximumPixelSize = Self.maximumDecodedPixelSize
        } else {
            maximumPixelSize = max(
                1,
                Int(scaledMaximumDimension.rounded(.up))
            )
        }
    }
}

struct ReaderImageDecodeRequest: Sendable {
    let asset: ReaderPageAsset
    let target: ReaderImageTarget
}

struct ReaderDecodedImage: Sendable {
    let image: CGImage
    let estimatedByteCount: Int

    init(
        image: CGImage,
        estimatedByteCount: Int? = nil
    ) {
        self.image = image

        if let estimatedByteCount {
            self.estimatedByteCount = max(1, estimatedByteCount)
            return
        }

        let byteCount = image.bytesPerRow.multipliedReportingOverflow(
            by: image.height
        )
        self.estimatedByteCount = byteCount.overflow
            ? Int.max
            : max(1, byteCount.partialValue)
    }
}

protocol ReaderImageDecoding: Sendable {
    func decode(
        _ request: ReaderImageDecodeRequest
    ) async throws -> ReaderDecodedImage
}

enum ReaderImageDecodeError: Error, Equatable, Sendable {
    case comicRootUnavailable(ImportPageCandidate.ID)
    case invalidManagedPath(ImportPageCandidate.ID)
    case managedFileUnavailable(ImportPageCandidate.ID)
    case symbolicLinkUnsupported(ImportPageCandidate.ID)
    case managedPathEscapesComicRoot(ImportPageCandidate.ID)
    case fileSizeMismatch(
        pageID: ImportPageCandidate.ID,
        expected: Int64,
        actual: Int64
    )
    case sourceCannotBeOpened(ImportPageCandidate.ID)
    case sourceHasNoImages(ImportPageCandidate.ID)
    case imageCannotBeDecoded(ImportPageCandidate.ID)
}

struct ImageIOReaderImageDecoder: ReaderImageDecoding {
    func decode(
        _ request: ReaderImageDecodeRequest
    ) async throws -> ReaderDecodedImage {
        let priority = Task.currentPriority
        let worker = Task.detached(priority: priority) {
            try Self.decodeSynchronously(request)
        }

        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    private static func decodeSynchronously(
        _ request: ReaderImageDecodeRequest
    ) throws -> ReaderDecodedImage {
        try Task.checkCancellation()
        let fileURL = try ReaderPageAssetFileValidator.validatedFileURL(
            for: request.asset
        )
        let pageID = request.asset.identity.pageID
        let sourceOptions: [CFString: Any] = [
            kCGImageSourceShouldCache: false,
            kCGImageSourceShouldCacheImmediately: false,
        ]

        guard let source = CGImageSourceCreateWithURL(
            fileURL as CFURL,
            sourceOptions as CFDictionary
        ) else {
            throw ReaderImageDecodeError.sourceCannotBeOpened(pageID)
        }

        let imageCount = CGImageSourceGetCount(source)
        guard imageCount > 0 else {
            throw ReaderImageDecodeError.sourceHasNoImages(pageID)
        }

        let imageIndex: Int
        if request.asset.mediaType == .heic
            || request.asset.mediaType == .heif {
            imageIndex = CGImageSourceGetPrimaryImageIndex(source)
        } else {
            imageIndex = 0
        }

        guard imageIndex < imageCount else {
            throw ReaderImageDecodeError.imageCannotBeDecoded(pageID)
        }

        try Task.checkCancellation()
        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: request.target.maximumPixelSize,
            kCGImageSourceShouldCache: true,
            kCGImageSourceShouldCacheImmediately: true,
        ]

        guard let image = CGImageSourceCreateThumbnailAtIndex(
            source,
            imageIndex,
            thumbnailOptions as CFDictionary
        ), CGImageSourceGetStatusAtIndex(source, imageIndex) == .statusComplete else {
            throw ReaderImageDecodeError.imageCannotBeDecoded(pageID)
        }

        try Task.checkCancellation()
        return ReaderDecodedImage(image: image)
    }
}

private enum ReaderPageAssetFileValidator {
    private static let resourceKeys: Set<URLResourceKey> = [
        .isDirectoryKey,
        .isRegularFileKey,
        .isSymbolicLinkKey,
        .isAliasFileKey,
        .isReadableKey,
        .fileSizeKey,
    ]

    static func validatedFileURL(
        for asset: ReaderPageAsset
    ) throws -> URL {
        let pageID = asset.identity.pageID
        let comicRootURL = asset.comicRootURL.standardizedFileURL
        let rootValues: URLResourceValues

        do {
            rootValues = try comicRootURL.resourceValues(
                forKeys: resourceKeys
            )
        } catch {
            throw ReaderImageDecodeError.comicRootUnavailable(pageID)
        }

        guard rootValues.isSymbolicLink != true,
              rootValues.isAliasFile != true else {
            throw ReaderImageDecodeError.symbolicLinkUnsupported(pageID)
        }
        guard rootValues.isDirectory == true else {
            throw ReaderImageDecodeError.comicRootUnavailable(pageID)
        }

        var fileURL = comicRootURL
        let components = asset.managedRelativePath.components
        guard components.count >= 2,
              components.first == "original" else {
            throw ReaderImageDecodeError.invalidManagedPath(pageID)
        }

        for (index, component) in components.enumerated() {
            let isLeaf = index == components.count - 1
            fileURL.appendPathComponent(
                component,
                isDirectory: !isLeaf
            )

            let values: URLResourceValues
            do {
                values = try fileURL.resourceValues(forKeys: resourceKeys)
            } catch {
                throw ReaderImageDecodeError.managedFileUnavailable(pageID)
            }

            guard values.isSymbolicLink != true,
                  values.isAliasFile != true else {
                throw ReaderImageDecodeError.symbolicLinkUnsupported(pageID)
            }

            if isLeaf {
                guard values.isRegularFile == true,
                      values.isReadable == true,
                      let fileSize = values.fileSize else {
                    throw ReaderImageDecodeError.managedFileUnavailable(pageID)
                }

                let actualByteCount = Int64(fileSize)
                guard actualByteCount == asset.expectedByteCount else {
                    throw ReaderImageDecodeError.fileSizeMismatch(
                        pageID: pageID,
                        expected: asset.expectedByteCount,
                        actual: actualByteCount
                    )
                }
            } else if values.isDirectory != true {
                throw ReaderImageDecodeError.managedFileUnavailable(pageID)
            }
        }

        let canonicalRootURL = comicRootURL
            .resolvingSymlinksInPath()
            .standardizedFileURL
        let canonicalFileURL = fileURL
            .resolvingSymlinksInPath()
            .standardizedFileURL

        guard isDescendant(
            canonicalFileURL,
            of: canonicalRootURL
        ) else {
            throw ReaderImageDecodeError.managedPathEscapesComicRoot(pageID)
        }

        return fileURL
    }

    private static func isDescendant(
        _ candidateURL: URL,
        of rootURL: URL
    ) -> Bool {
        let rootComponents = rootURL.pathComponents
        let candidateComponents = candidateURL.pathComponents

        guard candidateComponents.count > rootComponents.count else {
            return false
        }

        return zip(
            candidateComponents.prefix(rootComponents.count),
            rootComponents
        ).allSatisfy { candidate, root in
            candidate == root
        }
    }
}
