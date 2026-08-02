import Foundation

struct ReaderPageAssetIdentity: Equatable, Hashable, Sendable {
    let comicID: ManagedComicID
    let revision: ImportPreviewRevision
    let pageID: ImportPageCandidate.ID
}

struct ReaderPageAsset: Equatable, Sendable {
    let identity: ReaderPageAssetIdentity
    let comicRootURL: URL
    let managedRelativePath: ManagedRelativePath
    let mediaType: ImportImageMediaType
    let expectedByteCount: Int64
    let expectedPixelSize: ImportPixelSize?
    let orientation: ImportImageOrientation?
}

protocol ReaderPageAssetResolving: Sendable {
    func asset(
        for pageID: ImportPageCandidate.ID
    ) throws -> ReaderPageAsset
}

enum ReaderPageAssetResolverError: Error, Equatable, Sendable {
    case unsupportedDescriptorSchema(Int)
    case comicIDMismatch(
        expected: ManagedComicID,
        actual: ManagedComicID
    )
    case duplicatePageWorkItem(ImportPageCandidate.ID)
    case invalidManagedPath(ImportPageCandidate.ID)
    case invalidExpectedByteCount(ImportPageCandidate.ID)
    case pageNotFound(ImportPageCandidate.ID)
    case pageIsUnreadable(ImportPageCandidate.ID)
}

struct ManagedReaderPageAssetResolver: ReaderPageAssetResolving {
    private let comicID: ManagedComicID
    private let revision: ImportPreviewRevision
    private let comicRootURL: URL
    private let workItemsByPageID: [
        ImportPageCandidate.ID: FrozenImportWorkItem
    ]

    init(
        descriptor: ManagedComicDescriptor,
        expectedComicID: ManagedComicID,
        layout: ImportStorageLayout
    ) throws {
        guard descriptor.schemaVersion
                == ManagedComicDescriptor.currentSchemaVersion else {
            throw ReaderPageAssetResolverError.unsupportedDescriptorSchema(
                descriptor.schemaVersion
            )
        }

        guard descriptor.targetComicID == expectedComicID else {
            throw ReaderPageAssetResolverError.comicIDMismatch(
                expected: expectedComicID,
                actual: descriptor.targetComicID
            )
        }

        var indexedWorkItems: [
            ImportPageCandidate.ID: FrozenImportWorkItem
        ] = [:]
        indexedWorkItems.reserveCapacity(descriptor.workItems.count)

        for workItem in descriptor.workItems {
            guard indexedWorkItems[workItem.id] == nil else {
                throw ReaderPageAssetResolverError.duplicatePageWorkItem(
                    workItem.id
                )
            }

            guard Self.isReaderManagedPath(workItem.managedRelativePath) else {
                throw ReaderPageAssetResolverError.invalidManagedPath(
                    workItem.id
                )
            }

            guard workItem.expectedByteCount > 0 else {
                throw ReaderPageAssetResolverError.invalidExpectedByteCount(
                    workItem.id
                )
            }

            indexedWorkItems[workItem.id] = workItem
        }

        comicID = expectedComicID
        revision = descriptor.revision
        comicRootURL = layout.libraryURL(for: expectedComicID)
            .standardizedFileURL
        workItemsByPageID = indexedWorkItems
    }

    func asset(
        for pageID: ImportPageCandidate.ID
    ) throws -> ReaderPageAsset {
        guard let workItem = workItemsByPageID[pageID] else {
            throw ReaderPageAssetResolverError.pageNotFound(pageID)
        }

        guard workItem.pageState == .readable else {
            throw ReaderPageAssetResolverError.pageIsUnreadable(pageID)
        }

        return ReaderPageAsset(
            identity: ReaderPageAssetIdentity(
                comicID: comicID,
                revision: revision,
                pageID: workItem.id
            ),
            comicRootURL: comicRootURL,
            managedRelativePath: workItem.managedRelativePath,
            mediaType: workItem.detectedFormat,
            expectedByteCount: workItem.expectedByteCount,
            expectedPixelSize: workItem.pixelSize,
            orientation: workItem.orientation
        )
    }

    private static func isReaderManagedPath(
        _ path: ManagedRelativePath
    ) -> Bool {
        path.components.count >= 2 && path.components.first == "original"
    }
}
