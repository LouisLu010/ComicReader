import Foundation
import ImageIO
import UniformTypeIdentifiers

struct ImageContentProbe {
    func probe(
        fileURL: URL,
        fileName: String,
        sourceRelativePath: SourceRelativePath,
        byteCount: Int64
    ) -> Result {
        let options = [
            kCGImageSourceShouldCache: false,
            kCGImageSourceShouldCacheImmediately: false,
        ] as CFDictionary

        if let source = CGImageSourceCreateWithURL(fileURL as CFURL, options),
           let sourceType = CGImageSourceGetType(source) {
            guard let systemMediaType = ImportImageMediaType(
                imageSourceType: sourceType as String
            ) else {
                return .issue(
                    ImportIssue(
                        code: .unsupportedFileType,
                        severity: .information,
                        sourceRelativePaths: [sourceRelativePath],
                        detectedTypeIdentifier: sourceType as String
                    )
                )
            }

            var mediaType = systemMediaType
            if systemMediaType == .heic || systemMediaType == .heif,
               let signature = try? readSignature(from: fileURL),
               let signatureMediaType = ImportImageMediaType(signature: signature),
               signatureMediaType == .heic || signatureMediaType == .heif {
                mediaType = signatureMediaType
            }

            return result(
                from: source,
                mediaType: mediaType,
                fileURL: fileURL,
                fileName: fileName,
                sourceRelativePath: sourceRelativePath,
                byteCount: byteCount,
                options: options
            )
        }

        do {
            let signature = try readSignature(from: fileURL)

            if let mediaType = ImportImageMediaType(signature: signature) {
                return .page(
                    ImportPageCandidate(
                        id: .sourcePath(sourceRelativePath),
                        sourceRelativePath: sourceRelativePath,
                        originalFileName: fileName,
                        detectedFormat: mediaType,
                        byteCount: byteCount,
                        pixelSize: nil,
                        orientation: nil,
                        lightweightFingerprint: nil,
                        state: .corrupted,
                        pageIndex: nil
                    ),
                    issue: ImportIssue(
                        code: .corruptedImage,
                        severity: .warning,
                        sourceRelativePaths: [sourceRelativePath]
                    )
                )
            }

            return .issue(
                ImportIssue(
                    code: .unsupportedFileType,
                    severity: .information,
                    sourceRelativePaths: [sourceRelativePath]
                )
            )
        } catch {
            return .issue(
                ImportIssue(
                    code: .unreadableFile,
                    severity: .warning,
                    sourceRelativePaths: [sourceRelativePath]
                )
            )
        }
    }

    private func result(
        from source: CGImageSource,
        mediaType: ImportImageMediaType,
        fileURL: URL,
        fileName: String,
        sourceRelativePath: SourceRelativePath,
        byteCount: Int64,
        options: CFDictionary
    ) -> Result {
        let imageCount = CGImageSourceGetCount(source)
        guard imageCount > 0 else {
            return unreadablePage(
                mediaType: mediaType,
                fileName: fileName,
                sourceRelativePath: sourceRelativePath,
                byteCount: byteCount
            )
        }

        let imageIndex: Int
        if mediaType == .heic || mediaType == .heif {
            imageIndex = CGImageSourceGetPrimaryImageIndex(source)
        } else {
            imageIndex = 0
        }

        guard imageIndex < imageCount,
              !CGImageSourceGetStatusAtIndex(source, imageIndex).isDefinitivelyInvalid,
              let properties = CGImageSourceCopyPropertiesAtIndex(
                  source,
                  imageIndex,
                  options
              ) as NSDictionary?,
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              width > 0,
              height > 0 else {
            return unreadablePage(
                mediaType: mediaType,
                fileName: fileName,
                sourceRelativePath: sourceRelativePath,
                byteCount: byteCount
            )
        }

        guard isStructurallyComplete(
            fileURL: fileURL,
            mediaType: mediaType,
            byteCount: byteCount
        ) else {
            return unreadablePage(
                mediaType: mediaType,
                fileName: fileName,
                sourceRelativePath: sourceRelativePath,
                byteCount: byteCount
            )
        }

        let maxPixelSize = validationThumbnailMaxPixelSize(
            width: width,
            height: height
        )
        let validationOptions = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceShouldCache: true,
            kCGImageSourceShouldCacheImmediately: true,
        ] as CFDictionary

        guard CGImageSourceCreateThumbnailAtIndex(
            source,
            imageIndex,
            validationOptions
        ) != nil,
        CGImageSourceGetStatusAtIndex(source, imageIndex) == .statusComplete else {
            return unreadablePage(
                mediaType: mediaType,
                fileName: fileName,
                sourceRelativePath: sourceRelativePath,
                byteCount: byteCount
            )
        }

        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue
        let page = ImportPageCandidate(
            id: .sourcePath(sourceRelativePath),
            sourceRelativePath: sourceRelativePath,
            originalFileName: fileName,
            detectedFormat: mediaType,
            byteCount: byteCount,
            pixelSize: ImportPixelSize(width: width, height: height),
            orientation: orientation.flatMap {
                ImportImageOrientation(rawValue: $0)
            },
            lightweightFingerprint: nil,
            state: .readable,
            pageIndex: nil
        )

        return .page(page, issue: nil)
    }

    private func validationThumbnailMaxPixelSize(
        width: Int,
        height: Int
    ) -> Int {
        let minimumDimension = min(width, height)
        let maximumDimension = max(width, height)
        let aspectRatioCeiling = maximumDimension / minimumDimension
            + (maximumDimension % minimumDimension == 0 ? 0 : 1)

        return min(
            maximumDimension,
            max(64, aspectRatioCeiling)
        )
    }

    private func isStructurallyComplete(
        fileURL: URL,
        mediaType: ImportImageMediaType,
        byteCount: Int64
    ) -> Bool {
        guard mediaType == .jpeg else {
            return true
        }

        guard byteCount >= 2 else {
            return false
        }

        do {
            let handle = try FileHandle(forReadingFrom: fileURL)
            defer { try? handle.close() }

            try handle.seek(
                toOffset: UInt64(byteCount - 2)
            )
            let marker = try handle.read(upToCount: 2) ?? Data()
            return marker == Data([0xFF, 0xD9])
        } catch {
            return false
        }
    }

    private func unreadablePage(
        mediaType: ImportImageMediaType,
        fileName: String,
        sourceRelativePath: SourceRelativePath,
        byteCount: Int64
    ) -> Result {
        .page(
            ImportPageCandidate(
                id: .sourcePath(sourceRelativePath),
                sourceRelativePath: sourceRelativePath,
                originalFileName: fileName,
                detectedFormat: mediaType,
                byteCount: byteCount,
                pixelSize: nil,
                orientation: nil,
                lightweightFingerprint: nil,
                state: .corrupted,
                pageIndex: nil
            ),
            issue: ImportIssue(
                code: .corruptedImage,
                severity: .warning,
                sourceRelativePaths: [sourceRelativePath]
            )
        )
    }

    private func readSignature(from fileURL: URL) throws -> Data {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        return try handle.read(upToCount: 32) ?? Data()
    }

    enum Result {
        case page(ImportPageCandidate, issue: ImportIssue?)
        case issue(ImportIssue)
    }
}

private extension ImportImageMediaType {
    init?(imageSourceType: String) {
        switch imageSourceType {
        case UTType.jpeg.identifier:
            self = .jpeg
        case UTType.png.identifier:
            self = .png
        case UTType.webP.identifier:
            self = .webP
        case UTType.heic.identifier:
            self = .heic
        case UTType.heif.identifier:
            self = .heif
        case UTType.gif.identifier:
            self = .gif
        case UTType.bmp.identifier:
            self = .bmp
        case UTType.tiff.identifier:
            self = .tiff
        default:
            return nil
        }
    }

    init?(signature: Data) {
        let bytes = [UInt8](signature)

        if bytes.starts(with: [0xFF, 0xD8, 0xFF]) {
            self = .jpeg
        } else if bytes.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) {
            self = .png
        } else if bytes.count >= 12,
                  bytes[0...3].elementsEqual([0x52, 0x49, 0x46, 0x46]),
                  bytes[8...11].elementsEqual([0x57, 0x45, 0x42, 0x50]) {
            self = .webP
        } else if bytes.starts(with: Array("GIF87a".utf8))
                    || bytes.starts(with: Array("GIF89a".utf8)) {
            self = .gif
        } else if bytes.starts(with: [0x42, 0x4D]) {
            self = .bmp
        } else if bytes.starts(with: [0x49, 0x49, 0x2A, 0x00])
                    || bytes.starts(with: [0x4D, 0x4D, 0x00, 0x2A]) {
            self = .tiff
        } else if let heifType = Self.heifType(from: bytes) {
            self = heifType
        } else {
            return nil
        }
    }

    static func heifType(from bytes: [UInt8]) -> ImportImageMediaType? {
        guard bytes.count >= 12,
              bytes[4...7].elementsEqual([0x66, 0x74, 0x79, 0x70]) else {
            return nil
        }

        let brand = String(bytes: bytes[8...11], encoding: .ascii)

        switch brand {
        case "heic", "heix", "hevc", "hevx":
            return .heic
        case "mif1", "msf1", "heif":
            return .heif
        default:
            return nil
        }
    }
}

private extension CGImageSourceStatus {
    var isDefinitivelyInvalid: Bool {
        switch self {
        case .statusInvalidData, .statusUnexpectedEOF, .statusUnknownType:
            return true
        default:
            return false
        }
    }
}
