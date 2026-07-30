import Foundation

struct ImportSourcePreparation: Equatable, Sendable {
    let sources: [ImportSourceDescriptor]
    let rejectedDisplayNames: [String]

    init(
        sources: [ImportSourceDescriptor],
        rejectedDisplayNames: [String] = []
    ) {
        self.sources = sources
        self.rejectedDisplayNames = rejectedDisplayNames
    }
}

struct ImportSourcePreparer: Sendable {
    private let sourceAccess: any ImportSourceAccessing

    init(sourceAccess: any ImportSourceAccessing = SecurityScopedSourceAccess()) {
        self.sourceAccess = sourceAccess
    }

    func prepare(_ sourceURLs: [URL]) -> ImportSourcePreparation {
        var sources: [ImportSourceDescriptor] = []
        var rejectedDisplayNames: [String] = []

        for sourceURL in sourceURLs {
            do {
                sources.append(
                    try ImportSourceDescriptor(
                        sourceURL: sourceURL,
                        sourceAccess: sourceAccess
                    )
                )
            } catch {
                rejectedDisplayNames.append(sourceURL.lastPathComponent)
            }
        }

        return ImportSourcePreparation(
            sources: sources,
            rejectedDisplayNames: rejectedDisplayNames
        )
    }
}
