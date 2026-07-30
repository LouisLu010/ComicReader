import Foundation

protocol ImportSourceAccessing: Sendable {
    func makeBookmark(for sourceURL: URL) throws -> Data
    func resolveBookmark(_ bookmark: Data) throws -> URL
    func startAccessing(_ sourceURL: URL) throws
    func stopAccessing(_ sourceURL: URL)
}

enum ImportSourceAccessError: Error, Equatable, Sendable {
    case accessDenied
    case staleBookmark
    case invalidBookmark
}

struct SecurityScopedSourceAccess: ImportSourceAccessing {
    func makeBookmark(for sourceURL: URL) throws -> Data {
        try startAccessing(sourceURL)
        defer { stopAccessing(sourceURL) }

        return try sourceURL.bookmarkData(
            options: .minimalBookmark,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
    }

    func resolveBookmark(_ bookmark: Data) throws -> URL {
        var isStale = false

        do {
            let sourceURL = try URL(
                resolvingBookmarkData: bookmark,
                bookmarkDataIsStale: &isStale
            )
            guard !isStale else {
                throw ImportSourceAccessError.staleBookmark
            }
            return sourceURL
        } catch let error as ImportSourceAccessError {
            throw error
        } catch {
            throw ImportSourceAccessError.invalidBookmark
        }
    }

    func startAccessing(_ sourceURL: URL) throws {
        guard sourceURL.startAccessingSecurityScopedResource() else {
            throw ImportSourceAccessError.accessDenied
        }
    }

    func stopAccessing(_ sourceURL: URL) {
        sourceURL.stopAccessingSecurityScopedResource()
    }
}
