import CryptoKit
import Foundation

final class ImportCancellationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var isCancelled = false

    func cancel() {
        lock.lock()
        isCancelled = true
        lock.unlock()
    }

    func throwIfCancelled() throws {
        lock.lock()
        let cancelled = isCancelled
        lock.unlock()

        if cancelled {
            throw ImportCopyError.cancelled
        }
    }
}

enum ImportCopyError: Error, Equatable, Sendable {
    case cancelled
    case sourceChanged
    case sourceUnavailable
    case verificationFailed
    case copyFailed
}

struct ImportFileCopier: Sendable {
    private static let chunkByteCount = 1_024 * 1_024

    func copySource(
        from sourceURL: URL,
        to partialURL: URL,
        workItem: FrozenImportWorkItem,
        cancellationToken: ImportCancellationToken
    ) async throws -> ImportFileVerification {
        try await Task.detached(priority: .utility) {
            try Self.copySourceSynchronously(
                from: sourceURL,
                to: partialURL,
                workItem: workItem,
                cancellationToken: cancellationToken
            )
        }.value
    }

    func verifyPartial(
        at partialURL: URL,
        expected: ImportFileVerification,
        cancellationToken: ImportCancellationToken
    ) async throws {
        try await Task.detached(priority: .utility) {
            try cancellationToken.throwIfCancelled()
            let actual = try Self.verification(
                of: partialURL,
                cancellationToken: cancellationToken
            )
            guard actual == expected else {
                throw ImportCopyError.verificationFailed
            }
        }.value
    }

    func verifyExisting(
        at url: URL,
        expected: ImportFileVerification,
        cancellationToken: ImportCancellationToken
    ) async -> Bool {
        await Task.detached(priority: .utility) {
            do {
                try cancellationToken.throwIfCancelled()
                return try Self.verification(
                    of: url,
                    cancellationToken: cancellationToken
                ) == expected
            } catch {
                return false
            }
        }.value
    }

    func verifyReadableImage(
        at url: URL,
        workItem: FrozenImportWorkItem
    ) async -> Bool {
        await Task.detached(priority: .utility) {
            let result = ImageContentProbe().probe(
                fileURL: url,
                fileName: workItem.originalFileName,
                sourceRelativePath: workItem.sourceRelativePath,
                byteCount: workItem.expectedByteCount
            )

            guard case let .page(page, _) = result else {
                return false
            }

            return page.state == .readable
                && page.detectedFormat == workItem.detectedFormat
        }.value
    }

    private static func copySourceSynchronously(
        from sourceURL: URL,
        to partialURL: URL,
        workItem: FrozenImportWorkItem,
        cancellationToken: ImportCancellationToken
    ) throws -> ImportFileVerification {
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: partialURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? fileManager.removeItem(at: partialURL)

        var didComplete = false
        defer {
            if !didComplete {
                try? fileManager.removeItem(at: partialURL)
            }
        }

        let verification = try CoordinatedFileAccess().read(at: sourceURL) {
            coordinatedSourceURL in
            try cancellationToken.throwIfCancelled()
            let sourceValues = try coordinatedSourceURL.resourceValues(
                forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
            )
            guard sourceValues.isRegularFile == true,
                  sourceValues.isSymbolicLink != true,
                  let sourceSize = sourceValues.fileSize,
                  Int64(sourceSize) == workItem.expectedByteCount else {
                throw ImportCopyError.sourceChanged
            }

            if let expectedFingerprint = workItem.expectedLightweightFingerprint {
                let actualFingerprint = try LightweightContentFingerprint.make(
                    fileURL: coordinatedSourceURL,
                    byteCount: Int64(sourceSize)
                )
                guard actualFingerprint == expectedFingerprint else {
                    throw ImportCopyError.sourceChanged
                }
            }

            guard fileManager.createFile(
                atPath: partialURL.path,
                contents: nil
            ) else {
                throw ImportCopyError.copyFailed
            }

            let sourceHandle = try FileHandle(forReadingFrom: coordinatedSourceURL)
            defer { try? sourceHandle.close() }
            let destinationHandle = try FileHandle(forWritingTo: partialURL)
            defer { try? destinationHandle.close() }
            var digest = SHA256()
            var byteCount = Int64(0)

            while true {
                try cancellationToken.throwIfCancelled()
                let data = try sourceHandle.read(upToCount: chunkByteCount) ?? Data()
                guard !data.isEmpty else {
                    break
                }

                digest.update(data: data)
                try destinationHandle.write(contentsOf: data)
                let sum = byteCount.addingReportingOverflow(Int64(data.count))
                guard !sum.overflow else {
                    throw ImportCopyError.copyFailed
                }
                byteCount = sum.partialValue
            }

            try destinationHandle.synchronize()
            guard byteCount == workItem.expectedByteCount else {
                throw ImportCopyError.sourceChanged
            }

            guard let sourceDigest = ImportSHA256Digest(
                rawValue: Self.hexadecimalString(digest.finalize())
            ) else {
                throw ImportCopyError.copyFailed
            }

            return ImportFileVerification(
                byteCount: byteCount,
                sha256: sourceDigest
            )
        }

        didComplete = true
        return verification
    }

    private static func verification(
        of url: URL,
        cancellationToken: ImportCancellationToken
    ) throws -> ImportFileVerification {
        let values = try url.resourceValues(
            forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        )
        guard values.isRegularFile == true,
              values.isSymbolicLink != true,
              let size = values.fileSize,
              size >= 0 else {
            throw ImportCopyError.verificationFailed
        }

        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var digest = SHA256()
        var byteCount = Int64(0)

        while true {
            try cancellationToken.throwIfCancelled()
            let data = try handle.read(upToCount: chunkByteCount) ?? Data()
            guard !data.isEmpty else {
                break
            }

            digest.update(data: data)
            let sum = byteCount.addingReportingOverflow(Int64(data.count))
            guard !sum.overflow else {
                throw ImportCopyError.verificationFailed
            }
            byteCount = sum.partialValue
        }

        guard byteCount == Int64(size),
              let fileDigest = ImportSHA256Digest(
                  rawValue: Self.hexadecimalString(digest.finalize())
              ) else {
            throw ImportCopyError.verificationFailed
        }

        return ImportFileVerification(byteCount: byteCount, sha256: fileDigest)
    }

    private static func hexadecimalString(_ digest: SHA256.Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}
