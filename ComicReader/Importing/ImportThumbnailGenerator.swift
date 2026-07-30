import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

protocol ImportThumbnailGenerating: Sendable {
    func generate(
        from coverURL: URL,
        to thumbnailURL: URL
    ) async throws
}

enum ImportThumbnailError: Error, Equatable, Sendable {
    case sourceCannotBeDecoded
    case destinationCannotBeCreated
}

struct ImageIOImportThumbnailGenerator: ImportThumbnailGenerating {
    private static let maximumPixelSize = 720

    func generate(
        from coverURL: URL,
        to thumbnailURL: URL
    ) async throws {
        try await Task.detached(priority: .utility) {
            try Self.generateSynchronously(
                from: coverURL,
                to: thumbnailURL
            )
        }.value
    }

    private static func generateSynchronously(
        from coverURL: URL,
        to thumbnailURL: URL
    ) throws {
        guard let source = CGImageSourceCreateWithURL(
            coverURL as CFURL,
            nil
        ) else {
            throw ImportThumbnailError.sourceCannotBeDecoded
        }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(
            source,
            0,
            options as CFDictionary
        ) else {
            throw ImportThumbnailError.sourceCannotBeDecoded
        }

        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: thumbnailURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let partialURL = thumbnailURL.appendingPathExtension("partial")
        try? fileManager.removeItem(at: partialURL)
        defer { try? fileManager.removeItem(at: partialURL) }

        guard let destination = CGImageDestinationCreateWithURL(
            partialURL as CFURL,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            throw ImportThumbnailError.destinationCannotBeCreated
        }

        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw ImportThumbnailError.destinationCannotBeCreated
        }

        try? fileManager.removeItem(at: thumbnailURL)
        try fileManager.moveItem(at: partialURL, to: thumbnailURL)
    }
}
