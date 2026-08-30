import CryptoKit
import Foundation

struct ManagedComicDescriptor: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let jobID: ImportJobID
    let targetComicID: ManagedComicID
    let revision: ImportPreviewRevision
    let sourceRootName: String
    let displayName: String
    let sortLocaleIdentifier: String
    let collections: [ImportCollectionCandidate]
    let chapters: [FrozenImportChapter]
    let workItems: [FrozenImportWorkItem]
    let coverPageID: ImportPageCandidate.ID

    init(plan: FrozenImportPlan, journal: ImportJobJournal) {
        schemaVersion = Self.currentSchemaVersion
        jobID = plan.id
        targetComicID = journal.targetComicID
        revision = plan.revision
        sourceRootName = plan.sourceRootName
        displayName = plan.displayName
        sortLocaleIdentifier = plan.sortLocaleIdentifier
        collections = plan.collections
        chapters = plan.chapters
        workItems = plan.workItems
        coverPageID = plan.coverPageID
    }

    private init(
        schemaVersion: Int,
        jobID: ImportJobID,
        targetComicID: ManagedComicID,
        revision: ImportPreviewRevision,
        sourceRootName: String,
        displayName: String,
        sortLocaleIdentifier: String,
        collections: [ImportCollectionCandidate],
        chapters: [FrozenImportChapter],
        workItems: [FrozenImportWorkItem],
        coverPageID: ImportPageCandidate.ID
    ) {
        self.schemaVersion = schemaVersion
        self.jobID = jobID
        self.targetComicID = targetComicID
        self.revision = revision
        self.sourceRootName = sourceRootName
        self.displayName = displayName
        self.sortLocaleIdentifier = sortLocaleIdentifier
        self.collections = collections
        self.chapters = chapters
        self.workItems = workItems
        self.coverPageID = coverPageID
    }

    /// 应用元数据编辑（显示名/封面），生成新修订号的描述符。
    func with(
        displayName: String,
        workItems: [FrozenImportWorkItem],
        coverPageID: ImportPageCandidate.ID
    ) -> ManagedComicDescriptor {
        ManagedComicDescriptor(
            schemaVersion: Self.currentSchemaVersion,
            jobID: jobID,
            targetComicID: targetComicID,
            revision: Self.makeRevision(
                sourceRootName: sourceRootName,
                displayName: displayName,
                sortLocaleIdentifier: sortLocaleIdentifier,
                collections: collections,
                chapters: chapters,
                workItems: workItems,
                coverPageID: coverPageID
            ),
            sourceRootName: sourceRootName,
            displayName: displayName,
            sortLocaleIdentifier: sortLocaleIdentifier,
            collections: collections,
            chapters: chapters,
            workItems: workItems,
            coverPageID: coverPageID
        )
    }

    /// 应用一次更新后的描述符：沿用导入身份与展示信息，
    /// 以新内容重新计算修订号。
    func updated(
        collections: [ImportCollectionCandidate],
        chapters: [FrozenImportChapter],
        workItems: [FrozenImportWorkItem],
        coverPageID: ImportPageCandidate.ID
    ) -> ManagedComicDescriptor {
        ManagedComicDescriptor(
            schemaVersion: Self.currentSchemaVersion,
            jobID: jobID,
            targetComicID: targetComicID,
            revision: Self.makeRevision(
                sourceRootName: sourceRootName,
                displayName: displayName,
                sortLocaleIdentifier: sortLocaleIdentifier,
                collections: collections,
                chapters: chapters,
                workItems: workItems,
                coverPageID: coverPageID
            ),
            sourceRootName: sourceRootName,
            displayName: displayName,
            sortLocaleIdentifier: sortLocaleIdentifier,
            collections: collections,
            chapters: chapters,
            workItems: workItems,
            coverPageID: coverPageID
        )
    }

    private static func makeRevision(
        sourceRootName: String,
        displayName: String,
        sortLocaleIdentifier: String,
        collections: [ImportCollectionCandidate],
        chapters: [FrozenImportChapter],
        workItems: [FrozenImportWorkItem],
        coverPageID: ImportPageCandidate.ID
    ) -> ImportPreviewRevision {
        struct RevisionPayload: Encodable {
            let schemaVersion: Int
            let sourceRootName: String
            let displayName: String
            let sortLocaleIdentifier: String
            let collections: [ImportCollectionCandidate]
            let chapters: [FrozenImportChapter]
            let workItems: [FrozenImportWorkItem]
            let coverPageID: ImportPageCandidate.ID
        }

        let payload = RevisionPayload(
            schemaVersion: FrozenImportPlan.currentSchemaVersion,
            sourceRootName: sourceRootName,
            displayName: displayName,
            sortLocaleIdentifier: sortLocaleIdentifier,
            collections: collections,
            chapters: chapters,
            workItems: workItems,
            coverPageID: coverPageID
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = (try? encoder.encode(payload)) ?? Data()
        let digest = SHA256.hash(data: data)

        return ImportPreviewRevision(
            rawValue: digest.map { String(format: "%02x", $0) }.joined()
        )
    }
}

struct LibraryCatalogRecord: Codable, Equatable, Identifiable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let id: ManagedComicID
    let displayName: String
    let sourceRootName: String
    let importedAt: Date
    let chapterCount: Int
    let pageCount: Int
    let contentTree: [LibraryCatalogTreeNode]

    init(
        id: ManagedComicID,
        displayName: String,
        sourceRootName: String,
        importedAt: Date,
        chapterCount: Int,
        pageCount: Int,
        contentTree: [LibraryCatalogTreeNode]
    ) {
        schemaVersion = Self.currentSchemaVersion
        self.id = id
        self.displayName = displayName
        self.sourceRootName = sourceRootName
        self.importedAt = importedAt
        self.chapterCount = max(0, chapterCount)
        self.pageCount = max(0, pageCount)
        self.contentTree = contentTree
    }

    init(
        plan: FrozenImportPlan,
        journal: ImportJobJournal,
        importedAt: Date = Date()
    ) {
        self.init(
            id: journal.targetComicID,
            displayName: plan.displayName,
            sourceRootName: plan.sourceRootName,
            importedAt: importedAt,
            chapterCount: plan.chapters.count,
            pageCount: plan.workItems.count,
            contentTree: LibraryCatalogTreeBuilder.makeTree(
                collections: plan.collections,
                chapters: plan.chapters
            )
        )
    }

    init(
        descriptor: ManagedComicDescriptor,
        importedAt: Date
    ) {
        self.init(
            id: descriptor.targetComicID,
            displayName: descriptor.displayName,
            sourceRootName: descriptor.sourceRootName,
            importedAt: importedAt,
            chapterCount: descriptor.chapters.count,
            pageCount: descriptor.workItems.count,
            contentTree: LibraryCatalogTreeBuilder.makeTree(
                collections: descriptor.collections,
                chapters: descriptor.chapters
            )
        )
    }

    var isValid: Bool {
        guard schemaVersion == Self.currentSchemaVersion,
              !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !sourceRootName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              chapterCount >= 0,
              pageCount >= 0 else {
            return false
        }

        var seenNodeIDs = Set<String>()
        var previousDepth = -1

        for node in contentTree {
            guard node.isValid(seenNodeIDs: &seenNodeIDs),
                  node.depth <= previousDepth + 1 else {
                return false
            }

            previousDepth = node.depth
        }

        return true
    }
}

struct LibraryCatalogTreeNode: Codable, Equatable, Identifiable, Sendable {
    enum Kind: String, Codable, Equatable, Sendable {
        case collection
        case chapter
    }

    let id: String
    let kind: Kind
    let title: String
    let pageCount: Int
    let depth: Int

    init(
        id: String,
        kind: Kind,
        title: String,
        pageCount: Int,
        depth: Int = 0
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.pageCount = max(0, pageCount)
        self.depth = max(0, depth)
    }

    fileprivate func isValid(seenNodeIDs: inout Set<String>) -> Bool {
        guard !id.isEmpty,
              !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              pageCount >= 0,
              depth >= 0,
              seenNodeIDs.insert(id).inserted else {
            return false
        }

        return true
    }
}

private enum LibraryCatalogTreeBuilder {
    private enum Entry {
        case collection(ImportCollectionCandidate)
        case chapter(FrozenImportChapter)
    }

    private struct PendingEntry {
        let entry: Entry
        let depth: Int
        let ancestors: Set<ImportCollectionCandidate.ID>
    }

    static func makeTree(
        collections: [ImportCollectionCandidate],
        chapters: [FrozenImportChapter]
    ) -> [LibraryCatalogTreeNode] {
        let collectionsByParent = Dictionary(
            grouping: collections,
            by: \.parentID
        )
        let chaptersByParent = Dictionary(
            grouping: chapters,
            by: \.parentCollectionID
        )

        func entries(
            under parentID: ImportCollectionCandidate.ID?
        ) -> [Entry] {
            let collectionEntries = (collectionsByParent[parentID] ?? [])
                .sorted(by: Self.collectionOrder)
                .map(Entry.collection)
            let chapterEntries = (chaptersByParent[parentID] ?? [])
                .map(Entry.chapter)

            return collectionEntries + chapterEntries
        }

        var nodes: [LibraryCatalogTreeNode] = []
        var pendingEntries = entries(under: nil).reversed().map {
            PendingEntry(entry: $0, depth: 0, ancestors: [])
        }
        var seenCollectionIDs = Set<ImportCollectionCandidate.ID>()

        while let pending = pendingEntries.popLast() {
            switch pending.entry {
            case let .collection(collection):
                guard !pending.ancestors.contains(collection.id),
                      seenCollectionIDs.insert(collection.id).inserted else {
                    continue
                }

                nodes.append(
                    LibraryCatalogTreeNode(
                        id: "collection:\(collection.id.rawValue)",
                        kind: .collection,
                        title: collection.originalName,
                        pageCount: 0,
                        depth: pending.depth
                    )
                )

                let childAncestors = pending.ancestors.union([collection.id])
                for entry in entries(under: collection.id).reversed() {
                    pendingEntries.append(
                        PendingEntry(
                            entry: entry,
                            depth: pending.depth + 1,
                            ancestors: childAncestors
                        )
                    )
                }
            case let .chapter(chapter):
                nodes.append(
                    LibraryCatalogTreeNode(
                        id: "chapter:\(chapter.id.rawValue)",
                        kind: .chapter,
                        title: chapter.displayName,
                        pageCount: chapter.pageIDs.count,
                        depth: pending.depth
                    )
                )
            }
        }

        return nodes
    }

    private static func collectionOrder(
        _ lhs: ImportCollectionCandidate,
        _ rhs: ImportCollectionCandidate
    ) -> Bool {
        if lhs.siblingIndex != rhs.siblingIndex {
            return lhs.siblingIndex < rhs.siblingIndex
        }

        let comparison = lhs.originalName.localizedStandardCompare(rhs.originalName)
        if comparison != .orderedSame {
            return comparison == .orderedAscending
        }

        return lhs.id.rawValue < rhs.id.rawValue
    }
}
