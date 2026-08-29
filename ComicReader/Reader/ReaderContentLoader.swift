import Foundation

struct LoadedReaderContent: Sendable {
    let comic: ReaderComic
    let assetResolver: ManagedReaderPageAssetResolver
}

protocol ReaderContentLoading: Sendable {
    func load(
        comicID: ManagedComicID
    ) async throws -> LoadedReaderContent
}

enum ReaderContentLoaderError: Error, Equatable, Sendable {
    case descriptorNotFound
    case descriptorIsDirectory
    case descriptorIsSymbolicLink
    case descriptorUnreadable
    case invalidDescriptor
    case unsupportedDescriptorSchema(Int)
    case comicIDMismatch(
        expected: ManagedComicID,
        actual: ManagedComicID
    )
    case invalidComic(ReaderComicError)
    case invalidAssets(ReaderPageAssetResolverError)
}

/// 按漫画提供各话的用户页序覆盖；无覆盖的话保持自然顺序。
typealias ReaderPageOrdersProvider = @Sendable (ManagedComicID) async -> [
    ImportChapterCandidate.ID: [ImportPageCandidate.ID]
]

actor FileSystemReaderContentLoader: ReaderContentLoading {
    private static let managedResourceKeys: Set<URLResourceKey> = [
        .isDirectoryKey,
        .isRegularFileKey,
        .isSymbolicLinkKey,
        .isAliasFileKey,
    ]

    private let layout: ImportStorageLayout
    private let pageOrdersProvider: ReaderPageOrdersProvider

    init(
        layout: ImportStorageLayout,
        pageOrdersProvider: ReaderPageOrdersProvider = { _ in [:] }
    ) {
        self.layout = layout
        self.pageOrdersProvider = pageOrdersProvider
    }

    func load(
        comicID: ManagedComicID
    ) async throws -> LoadedReaderContent {
        try Task.checkCancellation()

        let libraryURL = layout.libraryURL.standardizedFileURL
        let comicRootURL = layout.libraryURL(for: comicID)
            .standardizedFileURL
        let metadataURL = layout.libraryMetadataURL(for: comicID)
            .standardizedFileURL
        let descriptorURL = metadataURL
            .appendingPathComponent("import-descriptor.json")
            .standardizedFileURL

        try validateManagedDirectory(at: libraryURL)
        try validateManagedDirectory(at: comicRootURL)
        try validateManagedDirectory(at: metadataURL)
        try validateContainment(
            of: descriptorURL,
            in: comicRootURL
        )
        let data = try descriptorData(at: descriptorURL)

        try Task.checkCancellation()

        let descriptor: ManagedComicDescriptor
        do {
            descriptor = try JSONDecoder().decode(
                ManagedComicDescriptor.self,
                from: data
            )
        } catch {
            throw ReaderContentLoaderError.invalidDescriptor
        }

        try Task.checkCancellation()

        guard descriptor.schemaVersion
                == ManagedComicDescriptor.currentSchemaVersion else {
            throw ReaderContentLoaderError.unsupportedDescriptorSchema(
                descriptor.schemaVersion
            )
        }
        guard descriptor.targetComicID == comicID else {
            throw ReaderContentLoaderError.comicIDMismatch(
                expected: comicID,
                actual: descriptor.targetComicID
            )
        }

        let comic: ReaderComic
        do {
            let pageOrders = await pageOrdersProvider(comicID)
            comic = try ReaderComic(
                descriptor: descriptor,
                pageOrdersByChapterID: pageOrders
            )
        } catch let error as ReaderComicError {
            throw ReaderContentLoaderError.invalidComic(error)
        }

        try Task.checkCancellation()

        let assetResolver: ManagedReaderPageAssetResolver
        do {
            assetResolver = try ManagedReaderPageAssetResolver(
                descriptor: descriptor,
                expectedComicID: comicID,
                layout: layout
            )
        } catch let error as ReaderPageAssetResolverError {
            throw ReaderContentLoaderError.invalidAssets(error)
        }

        try Task.checkCancellation()

        return LoadedReaderContent(
            comic: comic,
            assetResolver: assetResolver
        )
    }

    private func descriptorData(at url: URL) throws -> Data {
        let fileManager = FileManager.default

        guard fileManager.fileExists(atPath: url.path) else {
            throw ReaderContentLoaderError.descriptorNotFound
        }

        let values: URLResourceValues
        do {
            values = try url.resourceValues(
                forKeys: Self.managedResourceKeys
            )
        } catch {
            throw ReaderContentLoaderError.descriptorUnreadable
        }

        if values.isSymbolicLink == true || values.isAliasFile == true {
            throw ReaderContentLoaderError.descriptorIsSymbolicLink
        }
        if values.isDirectory == true {
            throw ReaderContentLoaderError.descriptorIsDirectory
        }
        guard values.isRegularFile == true else {
            throw ReaderContentLoaderError.descriptorUnreadable
        }

        do {
            return try Data(contentsOf: url, options: [.mappedIfSafe])
        } catch {
            throw ReaderContentLoaderError.descriptorUnreadable
        }
    }

    private func validateManagedDirectory(at url: URL) throws {
        let values: URLResourceValues
        do {
            values = try url.resourceValues(
                forKeys: Self.managedResourceKeys
            )
        } catch let error as CocoaError
            where error.code == .fileNoSuchFile
                || error.code == .fileReadNoSuchFile {
            throw ReaderContentLoaderError.descriptorNotFound
        } catch {
            throw ReaderContentLoaderError.descriptorUnreadable
        }

        guard values.isSymbolicLink != true,
              values.isAliasFile != true else {
            throw ReaderContentLoaderError.descriptorIsSymbolicLink
        }
        guard values.isDirectory == true else {
            throw ReaderContentLoaderError.descriptorUnreadable
        }
    }

    private func validateContainment(
        of candidateURL: URL,
        in rootURL: URL
    ) throws {
        let canonicalRootURL = rootURL
            .resolvingSymlinksInPath()
            .standardizedFileURL
        let canonicalCandidateURL = candidateURL
            .resolvingSymlinksInPath()
            .standardizedFileURL
        let rootComponents = canonicalRootURL.pathComponents
        let candidateComponents = canonicalCandidateURL.pathComponents

        guard candidateComponents.count > rootComponents.count,
              zip(
                candidateComponents.prefix(rootComponents.count),
                rootComponents
              ).allSatisfy({ candidate, root in candidate == root }) else {
            throw ReaderContentLoaderError.descriptorIsSymbolicLink
        }
    }
}
