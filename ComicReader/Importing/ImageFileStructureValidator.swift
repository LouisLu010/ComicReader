import Foundation

enum ImageFileStructureValidator {
    static func isStructurallyComplete(
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
}
