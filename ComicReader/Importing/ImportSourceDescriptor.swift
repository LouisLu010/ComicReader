import Foundation

struct ImportSourceDescriptor: Equatable, Identifiable, Sendable {
    let id: UUID
    let bookmark: Data
    let displayName: String

    init(
        id: UUID = UUID(),
        bookmark: Data,
        displayName: String
    ) {
        self.id = id
        self.bookmark = bookmark
        self.displayName = displayName
    }

    init(
        sourceURL: URL,
        sourceAccess: any ImportSourceAccessing
    ) throws {
        self.init(
            bookmark: try sourceAccess.makeBookmark(for: sourceURL),
            displayName: sourceURL.lastPathComponent
        )
    }
}
