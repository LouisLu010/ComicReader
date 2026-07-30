import CryptoKit
import Foundation

enum LightweightContentFingerprint {
    private static let sampleByteCount = 64 * 1_024

    static func make(
        fileURL: URL,
        byteCount: Int64
    ) throws -> String {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }

        let prefix = try handle.read(upToCount: sampleByteCount) ?? Data()
        let safeByteCount = max(0, byteCount)
        var suffix = Data()

        if safeByteCount > Int64(sampleByteCount) {
            let suffixOffset = safeByteCount - Int64(sampleByteCount)
            try handle.seek(toOffset: UInt64(suffixOffset))
            suffix = try handle.read(upToCount: sampleByteCount) ?? Data()
        }

        var fingerprintInput = Data()
        var bigEndianByteCount = safeByteCount.bigEndian
        withUnsafeBytes(of: &bigEndianByteCount) {
            fingerprintInput.append(contentsOf: $0)
        }
        fingerprintInput.append(prefix)
        fingerprintInput.append(suffix)

        return SHA256.hash(data: fingerprintInput)
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
