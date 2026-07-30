import CryptoKit
import Foundation

struct ImportJobID: Codable, Equatable, Hashable, Identifiable, Sendable {
    let rawValue: UUID

    var id: UUID {
        rawValue
    }

    init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

struct ImportPreviewRevision: Codable, Equatable, Hashable, Sendable {
    let rawValue: String
}

enum ImportPreviewDraftError: Error, Codable, Equatable, Sendable {
    case unknownChapter
    case unknownPage
    case invalidDisplayName
    case invalidChapterOrder
    case crossCollectionMove
    case coverMustBeReadable
    case coverMustBelongToIncludedContent
    case noReadableSelectedChapter
    case missingManifestPage
}

struct ImportPreviewDraft: Equatable, Sendable {
    let manifest: ImportManifest
    private(set) var displayName: String
    private(set) var includedChapterIDs: Set<ImportChapterCandidate.ID>
    private(set) var coverPageID: ImportPageCandidate.ID?
    private var chapterDisplayNames: [ImportChapterCandidate.ID: String]
    private var chapterOrders: [ImportPreviewChapterOrder]

    init(manifest: ImportManifest) {
        self.manifest = manifest
        displayName = manifest.sourceRootName
        includedChapterIDs = Set(manifest.chapters.map(\.id))
        coverPageID = manifest.coverPageID
        chapterDisplayNames = Dictionary(
            uniqueKeysWithValues: manifest.chapters.map {
                ($0.id, $0.originalName)
            }
        )
        chapterOrders = Self.makeChapterOrders(from: manifest.chapters)
        coverPageID = resolvedCoverPageID()
    }

    var spaceEstimate: ImportSpaceEstimate {
        guard let selection = try? selectedPagesAndChapters(),
              let resolvedCoverPageID = resolvedCoverPageID() else {
            return .make(contentBytes: 0, fileCount: 0)
        }

        return Self.makeSpaceEstimate(
            for: makeWorkItems(
                selectedPages: selection.pages,
                coverPageID: resolvedCoverPageID
            )
        )
    }

    func chapterOrder(
        for parentCollectionID: ImportCollectionCandidate.ID?
    ) -> [ImportChapterCandidate.ID] {
        chapterOrders.first {
            $0.parentCollectionID == parentCollectionID
        }?.chapterIDs ?? []
    }

    func chapterDisplayName(
        for chapterID: ImportChapterCandidate.ID
    ) -> String? {
        chapterDisplayNames[chapterID]
    }

    mutating func setDisplayName(_ value: String) throws {
        let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedValue.isEmpty else {
            throw ImportPreviewDraftError.invalidDisplayName
        }

        displayName = trimmedValue
    }

    mutating func setChapterDisplayName(
        _ chapterID: ImportChapterCandidate.ID,
        value: String
    ) throws {
        guard manifest.chapters.contains(where: { $0.id == chapterID }) else {
            throw ImportPreviewDraftError.unknownChapter
        }

        let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedValue.isEmpty else {
            throw ImportPreviewDraftError.invalidDisplayName
        }

        chapterDisplayNames[chapterID] = trimmedValue
    }

    mutating func setChapterIncluded(
        _ chapterID: ImportChapterCandidate.ID,
        isIncluded: Bool
    ) throws {
        guard manifest.chapters.contains(where: { $0.id == chapterID }) else {
            throw ImportPreviewDraftError.unknownChapter
        }

        if isIncluded {
            includedChapterIDs.insert(chapterID)
        } else {
            includedChapterIDs.remove(chapterID)
        }

        coverPageID = resolvedCoverPageID()
    }

    mutating func setCoverPage(
        _ pageID: ImportPageCandidate.ID
    ) throws {
        guard let page = manifest.pages.first(where: { $0.id == pageID }) else {
            throw ImportPreviewDraftError.unknownPage
        }

        guard page.state == .readable else {
            throw ImportPreviewDraftError.coverMustBeReadable
        }

        guard isCoverEligible(pageID) else {
            throw ImportPreviewDraftError.coverMustBelongToIncludedContent
        }

        coverPageID = pageID
    }

    mutating func moveChapter(
        _ chapterID: ImportChapterCandidate.ID,
        before anchorID: ImportChapterCandidate.ID?
    ) throws {
        guard let chapter = manifest.chapters.first(where: { $0.id == chapterID }) else {
            throw ImportPreviewDraftError.unknownChapter
        }

        guard anchorID != chapterID else {
            return
        }

        guard let orderIndex = chapterOrders.firstIndex(where: {
            $0.parentCollectionID == chapter.parentCollectionID
        }) else {
            throw ImportPreviewDraftError.invalidChapterOrder
        }

        if let anchorID {
            guard let anchor = manifest.chapters.first(where: { $0.id == anchorID }) else {
                throw ImportPreviewDraftError.unknownChapter
            }

            guard anchor.parentCollectionID == chapter.parentCollectionID else {
                throw ImportPreviewDraftError.crossCollectionMove
            }
        }

        var order = chapterOrders[orderIndex].chapterIDs
        guard let currentIndex = order.firstIndex(of: chapterID) else {
            throw ImportPreviewDraftError.invalidChapterOrder
        }

        order.remove(at: currentIndex)

        if let anchorID {
            guard let anchorIndex = order.firstIndex(of: anchorID) else {
                throw ImportPreviewDraftError.invalidChapterOrder
            }
            order.insert(chapterID, at: anchorIndex)
        } else {
            order.append(chapterID)
        }

        chapterOrders[orderIndex].chapterIDs = order
    }

    func freeze(
        sourceBookmark: Data,
        jobID: ImportJobID = ImportJobID()
    ) throws -> FrozenImportPlan {
        let selection = try selectedPagesAndChapters()
        guard selection.chapters.contains(where: { chapter in
            manifest.pages(in: chapter).contains { $0.state == .readable }
        }) else {
            throw ImportPreviewDraftError.noReadableSelectedChapter
        }

        guard let resolvedCoverPageID = resolvedCoverPageID() else {
            throw ImportPreviewDraftError.noReadableSelectedChapter
        }

        let selectedCollections = collectionsNeeded(
            by: selection.chapters
        )
        let frozenChapters = selection.chapters.map { chapter in
            FrozenImportChapter(
                id: chapter.id,
                parentCollectionID: chapter.parentCollectionID,
                sourceDirectoryPath: chapter.sourceDirectoryPath,
                originalName: chapter.originalName,
                displayName: chapterDisplayNames[chapter.id] ?? chapter.originalName,
                role: chapter.role,
                pageIDs: chapter.pageIDs
            )
        }
        let workItems = makeWorkItems(
            selectedPages: selection.pages,
            coverPageID: resolvedCoverPageID
        )
        let estimate = Self.makeSpaceEstimate(for: workItems)
        let relevantScanIssues = scanIssues(
            relevantTo: selection.chapters,
            workItems: workItems
        )
        let revision = try Self.revision(
            sourceRootName: manifest.sourceRootName,
            displayName: displayName,
            collections: selectedCollections,
            chapters: frozenChapters,
            workItems: workItems,
            coverPageID: resolvedCoverPageID,
            spaceEstimate: estimate,
            scanIssues: relevantScanIssues
        )

        return FrozenImportPlan(
            id: jobID,
            revision: revision,
            sourceRootName: manifest.sourceRootName,
            displayName: displayName,
            sourceBookmark: sourceBookmark,
            sortLocaleIdentifier: manifest.sortLocaleIdentifier,
            collections: selectedCollections,
            chapters: frozenChapters,
            workItems: workItems,
            coverPageID: resolvedCoverPageID,
            scanIssues: relevantScanIssues,
            spaceEstimate: estimate
        )
    }

    private func selectedPagesAndChapters() throws -> (
        pages: [ImportPageCandidate],
        chapters: [ImportChapterCandidate]
    ) {
        let manifestChapterIDs = Set(manifest.chapters.map(\.id))
        guard includedChapterIDs.isSubset(of: manifestChapterIDs) else {
            throw ImportPreviewDraftError.invalidChapterOrder
        }

        let orderedChapterIDs = chapterOrders.flatMap(\.chapterIDs)
        guard orderedChapterIDs.count == manifest.chapters.count,
              Set(orderedChapterIDs) == manifestChapterIDs else {
            throw ImportPreviewDraftError.invalidChapterOrder
        }

        let chapterByID = Dictionary(
            uniqueKeysWithValues: manifest.chapters.map { ($0.id, $0) }
        )
        let pageByID = Dictionary(
            uniqueKeysWithValues: manifest.pages.map { ($0.id, $0) }
        )
        let chapters = orderedChapterIDs.compactMap { chapterID -> ImportChapterCandidate? in
            guard includedChapterIDs.contains(chapterID) else {
                return nil
            }
            return chapterByID[chapterID]
        }
        var pages: [ImportPageCandidate] = []
        var seenPageIDs = Set<ImportPageCandidate.ID>()

        for chapter in chapters {
            for pageID in chapter.pageIDs where seenPageIDs.insert(pageID).inserted {
                guard let page = pageByID[pageID] else {
                    throw ImportPreviewDraftError.missingManifestPage
                }
                pages.append(page)
            }
        }

        return (pages, chapters)
    }

    private func isCoverEligible(_ pageID: ImportPageCandidate.ID) -> Bool {
        guard let containingChapter = manifest.chapters.first(where: {
            $0.pageIDs.contains(pageID)
        }) else {
            return true
        }

        return includedChapterIDs.contains(containingChapter.id)
    }

    private func resolvedCoverPageID() -> ImportPageCandidate.ID? {
        if let coverPageID,
           let coverPage = manifest.pages.first(where: { $0.id == coverPageID }),
           coverPage.state == .readable,
           isCoverEligible(coverPageID) {
            return coverPageID
        }

        if let suggestedCoverID = manifest.coverPageID,
           let suggestedCover = manifest.pages.first(where: {
               $0.id == suggestedCoverID
           }),
           suggestedCover.state == .readable,
           isCoverEligible(suggestedCoverID) {
            return suggestedCoverID
        }

        return chapterOrders.lazy
            .flatMap(\.chapterIDs)
            .lazy
            .filter(includedChapterIDs.contains)
            .compactMap { chapterID in
                manifest.chapters.first(where: { $0.id == chapterID })
            }
            .lazy
            .flatMap(\.pageIDs)
            .compactMap { pageID in
                manifest.pages.first(where: { $0.id == pageID })
            }
            .first(where: { $0.state == .readable })?
            .id
    }

    private func collectionsNeeded(
        by chapters: [ImportChapterCandidate]
    ) -> [ImportCollectionCandidate] {
        let collectionByID = Dictionary(
            uniqueKeysWithValues: manifest.collections.map { ($0.id, $0) }
        )
        var neededCollectionIDs = Set<ImportCollectionCandidate.ID>()

        for chapter in chapters {
            var currentID = chapter.parentCollectionID

            while let collectionID = currentID,
                  let collection = collectionByID[collectionID] {
                neededCollectionIDs.insert(collectionID)
                currentID = collection.parentID
            }
        }

        return manifest.collections.filter { neededCollectionIDs.contains($0.id) }
    }

    private func makeWorkItems(
        selectedPages: [ImportPageCandidate],
        coverPageID: ImportPageCandidate.ID
    ) -> [FrozenImportWorkItem] {
        let pageByID = Dictionary(
            uniqueKeysWithValues: manifest.pages.map { ($0.id, $0) }
        )
        let selectedPageIDs = selectedPages.map(\.id)
        let orderedPageIDs = [coverPageID] + selectedPageIDs
        var seenPageIDs = Set<ImportPageCandidate.ID>()

        return orderedPageIDs.compactMap { pageID in
            guard seenPageIDs.insert(pageID).inserted,
                  let page = pageByID[pageID] else {
                return nil
            }

            return FrozenImportWorkItem(
                id: page.id,
                sourceRelativePath: page.sourceRelativePath,
                managedRelativePath: ManagedRelativePath(
                    components: ["original"] + page.sourceRelativePath.components
                ),
                originalFileName: page.originalFileName,
                detectedFormat: page.detectedFormat,
                expectedByteCount: page.byteCount,
                expectedLightweightFingerprint: page.lightweightFingerprint,
                pageState: page.state,
                isCover: page.id == coverPageID
            )
        }
    }

    private func scanIssues(
        relevantTo chapters: [ImportChapterCandidate],
        workItems: [FrozenImportWorkItem]
    ) -> [ImportIssue] {
        let workItemPaths = Set(workItems.map(\.sourceRelativePath))

        return manifest.issues.filter { issue in
            issue.sourceRelativePaths.contains { issuePath in
                if workItemPaths.contains(issuePath) {
                    return true
                }

                return chapters.contains { chapter in
                    issuePath.isRelevant(to: chapter)
                }
            }
        }
    }

    private static func makeChapterOrders(
        from chapters: [ImportChapterCandidate]
    ) -> [ImportPreviewChapterOrder] {
        var orders: [ImportPreviewChapterOrder] = []

        for chapter in chapters {
            if let index = orders.firstIndex(where: {
                $0.parentCollectionID == chapter.parentCollectionID
            }) {
                orders[index].chapterIDs.append(chapter.id)
            } else {
                orders.append(
                    ImportPreviewChapterOrder(
                        parentCollectionID: chapter.parentCollectionID,
                        chapterIDs: [chapter.id]
                    )
                )
            }
        }

        return orders
    }

    private static func makeSpaceEstimate(
        for workItems: [FrozenImportWorkItem]
    ) -> ImportSpaceEstimate {
        let contentBytes = workItems.reduce(Int64(0)) { partialResult, workItem in
            let sum = partialResult.addingReportingOverflow(
                max(0, workItem.expectedByteCount)
            )
            return sum.overflow ? Int64.max : sum.partialValue
        }

        return .make(contentBytes: contentBytes, fileCount: workItems.count)
    }

    private static func revision(
        sourceRootName: String,
        displayName: String,
        collections: [ImportCollectionCandidate],
        chapters: [FrozenImportChapter],
        workItems: [FrozenImportWorkItem],
        coverPageID: ImportPageCandidate.ID,
        spaceEstimate: ImportSpaceEstimate,
        scanIssues: [ImportIssue]
    ) throws -> ImportPreviewRevision {
        let payload = FrozenImportRevisionPayload(
            schemaVersion: FrozenImportPlan.currentSchemaVersion,
            sourceRootName: sourceRootName,
            displayName: displayName,
            collections: collections,
            chapters: chapters,
            workItems: workItems,
            coverPageID: coverPageID,
            spaceEstimate: spaceEstimate,
            scanIssues: scanIssues
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(payload)
        let digest = SHA256.hash(data: data)
        let string = digest.map { String(format: "%02x", $0) }.joined()

        return ImportPreviewRevision(rawValue: string)
    }
}

private struct ImportPreviewChapterOrder: Equatable, Sendable {
    let parentCollectionID: ImportCollectionCandidate.ID?
    var chapterIDs: [ImportChapterCandidate.ID]
}

struct FrozenImportPlan: Codable, Equatable, Identifiable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let id: ImportJobID
    let revision: ImportPreviewRevision
    let sourceRootName: String
    let displayName: String
    let sourceBookmark: Data
    let sortLocaleIdentifier: String
    let collections: [ImportCollectionCandidate]
    let chapters: [FrozenImportChapter]
    let workItems: [FrozenImportWorkItem]
    let coverPageID: ImportPageCandidate.ID
    let scanIssues: [ImportIssue]
    let spaceEstimate: ImportSpaceEstimate

    init(
        schemaVersion: Int = Self.currentSchemaVersion,
        id: ImportJobID,
        revision: ImportPreviewRevision,
        sourceRootName: String,
        displayName: String,
        sourceBookmark: Data,
        sortLocaleIdentifier: String,
        collections: [ImportCollectionCandidate],
        chapters: [FrozenImportChapter],
        workItems: [FrozenImportWorkItem],
        coverPageID: ImportPageCandidate.ID,
        scanIssues: [ImportIssue],
        spaceEstimate: ImportSpaceEstimate
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.revision = revision
        self.sourceRootName = sourceRootName
        self.displayName = displayName
        self.sourceBookmark = sourceBookmark
        self.sortLocaleIdentifier = sortLocaleIdentifier
        self.collections = collections
        self.chapters = chapters
        self.workItems = workItems
        self.coverPageID = coverPageID
        self.scanIssues = scanIssues
        self.spaceEstimate = spaceEstimate
    }
}

struct FrozenImportChapter: Codable, Equatable, Identifiable, Sendable {
    let id: ImportChapterCandidate.ID
    let parentCollectionID: ImportCollectionCandidate.ID?
    let sourceDirectoryPath: SourceRelativePath
    let originalName: String
    let displayName: String
    let role: ImportChapterRole
    let pageIDs: [ImportPageCandidate.ID]
}

struct FrozenImportWorkItem: Codable, Equatable, Identifiable, Sendable {
    let id: ImportPageCandidate.ID
    let sourceRelativePath: SourceRelativePath
    let managedRelativePath: ManagedRelativePath
    let originalFileName: String
    let detectedFormat: ImportImageMediaType
    let expectedByteCount: Int64
    let expectedLightweightFingerprint: String?
    let pageState: ImportPageState
    let isCover: Bool
}

struct ManagedRelativePath: Codable, Hashable, Sendable {
    private let path: SourceRelativePath

    var components: [String] {
        path.components
    }

    var stringValue: String {
        path.stringValue
    }

    init(components: [String]) {
        path = SourceRelativePath(components: components)
    }
}

private struct FrozenImportRevisionPayload: Codable {
    let schemaVersion: Int
    let sourceRootName: String
    let displayName: String
    let collections: [ImportCollectionCandidate]
    let chapters: [FrozenImportChapter]
    let workItems: [FrozenImportWorkItem]
    let coverPageID: ImportPageCandidate.ID
    let spaceEstimate: ImportSpaceEstimate
    let scanIssues: [ImportIssue]
}

private extension SourceRelativePath {
    func isRelevant(to chapter: ImportChapterCandidate) -> Bool {
        let chapterComponents = chapter.sourceDirectoryPath.components
        guard components.count == chapterComponents.count + 1 else {
            return false
        }

        return zip(components, chapterComponents).allSatisfy { pair in
            pair.0.utf8.elementsEqual(pair.1.utf8)
        }
    }
}
