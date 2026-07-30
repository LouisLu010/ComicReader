import CryptoKit
import Foundation

struct SourceFileSnapshot: Equatable {
    let relativePath: String
    let bytes: Data
    let sha256: Data

    init(relativePath: String, bytes: Data) {
        self.relativePath = relativePath
        self.bytes = bytes
        sha256 = Data(SHA256.hash(data: bytes))
    }

    var byteCount: Int64 {
        Int64(bytes.count)
    }
}

struct SourceSnapshot: Equatable {
    let files: [SourceFileSnapshot]

    var byteCount: Int64 {
        files.reduce(0) { $0 + $1.byteCount }
    }
}

final class TemporaryImportSandbox {
    let sourceTree: TemporaryComicTree
    let appManagedRootURL: URL
    let libraryURL: URL
    let importsURL: URL
    let thumbnailsURL: URL

    private let fileManager: FileManager

    var sourceDirectoryURL: URL {
        sourceTree.rootURL
    }

    var readableSourceDirectoryURL: URL {
        sourceTree.rootURL
    }

    init(
        sourceName: String = "Test Comic",
        fileManager: FileManager = .default
    ) throws {
        self.fileManager = fileManager
        sourceTree = try TemporaryComicTree(
            name: sourceName,
            fileManager: fileManager
        )

        let sandboxURL = fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        appManagedRootURL = sandboxURL.appendingPathComponent(
            "ComicReader",
            isDirectory: true
        )
        libraryURL = appManagedRootURL.appendingPathComponent(
            "Library",
            isDirectory: true
        )
        importsURL = appManagedRootURL.appendingPathComponent(
            "Imports",
            isDirectory: true
        )
        thumbnailsURL = appManagedRootURL.appendingPathComponent(
            "Thumbnails",
            isDirectory: true
        )

        try fileManager.createDirectory(
            at: libraryURL,
            withIntermediateDirectories: true
        )
        try fileManager.createDirectory(
            at: importsURL,
            withIntermediateDirectories: true
        )
        try fileManager.createDirectory(
            at: thumbnailsURL,
            withIntermediateDirectories: true
        )
    }

    deinit {
        try? fileManager.removeItem(
            at: appManagedRootURL.deletingLastPathComponent()
        )
    }

    func sourceSnapshot() throws -> SourceSnapshot {
        let resourceKeys: Set<URLResourceKey> = [
            .isRegularFileKey,
            .isSymbolicLinkKey,
        ]
        guard let enumerator = fileManager.enumerator(
            at: sourceDirectoryURL,
            includingPropertiesForKeys: Array(resourceKeys),
            options: [],
            errorHandler: nil
        ) else {
            throw TemporaryImportSandboxError.cannotEnumerateSource
        }

        let rootComponentCount = sourceDirectoryURL.pathComponents.count
        var files: [SourceFileSnapshot] = []

        for case let fileURL as URL in enumerator {
            let values = try fileURL.resourceValues(forKeys: resourceKeys)
            guard values.isRegularFile == true, values.isSymbolicLink != true else {
                continue
            }

            let components = fileURL.pathComponents.dropFirst(rootComponentCount)
            guard !components.isEmpty else {
                throw TemporaryImportSandboxError.invalidSourcePath
            }

            files.append(
                SourceFileSnapshot(
                    relativePath: components.joined(separator: "/"),
                    bytes: try Data(contentsOf: fileURL)
                )
            )
        }

        return SourceSnapshot(
            files: files.sorted { $0.relativePath < $1.relativePath }
        )
    }

    func sourceIsUnchanged(since snapshot: SourceSnapshot) throws -> Bool {
        try sourceSnapshot() == snapshot
    }
}

private enum TemporaryImportSandboxError: Error {
    case cannotEnumerateSource
    case invalidSourcePath
}
