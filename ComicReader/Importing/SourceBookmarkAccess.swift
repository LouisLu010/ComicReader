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

        var coordinationError: NSError?
        var bookmark: Data?
        var capturedError: Error?

        NSFileCoordinator().coordinate(
            readingItemAt: sourceURL,
            options: .withoutChanges,
            error: &coordinationError
        ) { coordinatedURL in
            do {
                let values = try coordinatedURL.resourceValues(
                    forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isAliasFileKey]
                )
                guard values.isDirectory == true,
                      values.isSymbolicLink != true,
                      values.isAliasFile != true else {
                    throw ImportSourceAccessError.invalidBookmark
                }

                bookmark = try coordinatedURL.bookmarkData(
                    options: [],
                    includingResourceValuesForKeys: nil,
                    relativeTo: nil
                )
            } catch {
                capturedError = error
            }
        }

        if coordinationError != nil {
            throw ImportSourceAccessError.accessDenied
        }
        if let error = capturedError as? ImportSourceAccessError {
            throw error
        }
        guard let bookmark else {
            throw ImportSourceAccessError.invalidBookmark
        }

        return bookmark
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
