import Foundation

/// 一次增量更新扫描的用户决策草稿。默认行为：
/// 新增话全部纳入、替换话全部应用、缺失话全部保留——只有
/// 显式确认才会移除缺失话。冻结后生成可直接执行的更新操作。
struct ComicUpdateDraft: Equatable, Sendable {
    let scan: ComicSourceUpdateScan

    private(set) var includedAddedChapterIDs: Set<ImportChapterCandidate.ID>
    /// 以被替换的已入库话 ID 为键。
    private(set) var appliedReplacementChapterIDs: Set<ImportChapterCandidate.ID>
    /// 以被移除的已入库话 ID 为键。
    private(set) var removedMissingChapterIDs: Set<ImportChapterCandidate.ID>

    init(scan: ComicSourceUpdateScan) {
        self.scan = scan
        includedAddedChapterIDs = Set(
            scan.diff.addedChapters.map(\.id)
        )
        appliedReplacementChapterIDs = Set(
            scan.diff.replacedChapters.map(\.storedChapterID)
        )
        removedMissingChapterIDs = []
    }

    var addedChapterOptions: [ImportChapterCandidate] {
        scan.diff.addedChapters
    }

    var replacementOptions: [ImportUpdateReplacedChapter] {
        scan.diff.replacedChapters
    }

    var missingChapterOptions: [ImportUpdateMissingChapter] {
        scan.diff.missingChapters
    }

    func isAddedChapterIncluded(
        _ chapterID: ImportChapterCandidate.ID
    ) -> Bool {
        includedAddedChapterIDs.contains(chapterID)
    }

    func isReplacementApplied(
        _ storedChapterID: ImportChapterCandidate.ID
    ) -> Bool {
        appliedReplacementChapterIDs.contains(storedChapterID)
    }

    func isMissingChapterRemoved(
        _ storedChapterID: ImportChapterCandidate.ID
    ) -> Bool {
        removedMissingChapterIDs.contains(storedChapterID)
    }

    mutating func setAddedChapterIncluded(
        _ chapterID: ImportChapterCandidate.ID,
        isIncluded: Bool
    ) throws {
        guard scan.diff.addedChapters.contains(where: { $0.id == chapterID })
        else {
            throw ComicUpdateDraftError.unknownAddedChapter
        }

        if isIncluded {
            includedAddedChapterIDs.insert(chapterID)
        } else {
            includedAddedChapterIDs.remove(chapterID)
        }
    }

    mutating func setReplacementApplied(
        _ storedChapterID: ImportChapterCandidate.ID,
        isApplied: Bool
    ) throws {
        guard scan.diff.replacedChapters.contains(where: {
            $0.storedChapterID == storedChapterID
        }) else {
            throw ComicUpdateDraftError.unknownReplacementChapter
        }

        if isApplied {
            appliedReplacementChapterIDs.insert(storedChapterID)
        } else {
            appliedReplacementChapterIDs.remove(storedChapterID)
        }
    }

    mutating func setMissingChapterRemoved(
        _ storedChapterID: ImportChapterCandidate.ID,
        isRemoved: Bool
    ) throws {
        guard scan.diff.missingChapters.contains(where: {
            $0.chapterID == storedChapterID
        }) else {
            throw ComicUpdateDraftError.unknownMissingChapter
        }

        if isRemoved {
            removedMissingChapterIDs.insert(storedChapterID)
        } else {
            removedMissingChapterIDs.remove(storedChapterID)
        }
    }

    func freeze() throws -> FrozenComicUpdate {
        let replacements = scan.diff.replacedChapters.filter {
            appliedReplacementChapterIDs.contains($0.storedChapterID)
        }
        let removedStoredChapterIDs = removedMissingChapterIDs
        let addedChapters = scan.diff.addedChapters.filter {
            includedAddedChapterIDs.contains($0.id)
        }
        let replacedStoredChapterIDs = Set(
            replacements.map(\.storedChapterID)
        )

        var resultingChapters: [FrozenImportChapter] = []
        for storedChapter in scan.descriptor.chapters {
            if removedStoredChapterIDs.contains(storedChapter.id) {
                continue
            }

            if let replacement = replacements.first(where: {
                $0.storedChapterID == storedChapter.id
            }) {
                resultingChapters.append(
                    Self.frozenChapter(for: replacement.freshChapter)
                )
            } else {
                resultingChapters.append(storedChapter)
            }
        }
        resultingChapters.append(
            contentsOf: addedChapters.map(Self.frozenChapter(for:))
        )

        let keptStoredPageIDs = Set(
            scan.descriptor.chapters
                .filter { chapter in
                    !removedStoredChapterIDs.contains(chapter.id)
                        && !replacedStoredChapterIDs.contains(chapter.id)
                }
                .flatMap(\.pageIDs)
        )
        let freshWorkItemsByID = Dictionary(
            uniqueKeysWithValues: freshWorkItems().map {
                ($0.id, $0)
            }
        )

        let coverPageID = try resolvedCoverPageID(
            keptStoredPageIDs: keptStoredPageIDs,
            freshWorkItemsByID: freshWorkItemsByID,
            resultingChapters: resultingChapters
        )

        let copiedWorkItems = Array(
            freshWorkItemsByID.values
        )
        guard resultingChapters.flatMap(\.pageIDs).contains(where: { pageID in
            readablePageState(
                for: pageID,
                keptStoredPageIDs: keptStoredPageIDs,
                freshWorkItemsByID: freshWorkItemsByID
            ) == .readable
        }) else {
            throw ComicUpdateDraftError.noReadableRemainingChapter
        }

        return FrozenComicUpdate(
            addedChapters: addedChapters.map(Self.frozenChapter(for:)),
            addedWorkItems: addedChapters.flatMap { chapter in
                chapter.pageIDs.compactMap { freshWorkItemsByID[$0] }
            },
            addedCollections: Self.collectionsNeeded(
                by: addedChapters,
                in: scan.freshManifest
            ),
            replacedChapters: replacements.map { replacement in
                FrozenComicChapterReplacement(
                    storedChapterID: replacement.storedChapterID,
                    freshChapter: Self.frozenChapter(
                        for: replacement.freshChapter
                    ),
                    freshWorkItems: replacement.freshChapter.pageIDs
                        .compactMap { freshWorkItemsByID[$0] }
                )
            },
            removedChapterIDs: scan.diff.missingChapters
                .filter { removedStoredChapterIDs.contains($0.chapterID) }
                .map(\.chapterID),
            coverPageID: coverPageID,
            spaceEstimate: Self.makeSpaceEstimate(for: copiedWorkItems)
        )
    }

    /// 新增与替换话需要从来源复制的全部工作项。
    private func freshWorkItems() -> [FrozenImportWorkItem] {
        let freshPagesByID = Dictionary(
            uniqueKeysWithValues: scan.freshManifest.pages.map {
                ($0.id, $0)
            }
        )
        let replacementFreshChapters = scan.diff.replacedChapters
            .filter { appliedReplacementChapterIDs.contains($0.storedChapterID) }
            .map(\.freshChapter)
        let addedChapters = scan.diff.addedChapters.filter {
            includedAddedChapterIDs.contains($0.id)
        }

        var seenPageIDs = Set<ImportPageCandidate.ID>()
        var workItems: [FrozenImportWorkItem] = []

        for chapter in replacementFreshChapters + addedChapters {
            for pageID in chapter.pageIDs
            where seenPageIDs.insert(pageID).inserted {
                guard let page = freshPagesByID[pageID] else {
                    continue
                }

                workItems.append(
                    FrozenImportWorkItem(
                        id: page.id,
                        sourceRelativePath: page.sourceRelativePath,
                        managedRelativePath: ManagedRelativePath(
                            components: ["original"]
                                + page.sourceRelativePath.components
                        ),
                        originalFileName: page.originalFileName,
                        detectedFormat: page.detectedFormat,
                        expectedByteCount: page.byteCount,
                        expectedLightweightFingerprint: page
                            .lightweightFingerprint,
                        pixelSize: page.pixelSize,
                        orientation: page.orientation,
                        pageState: page.state,
                        isCover: false
                    )
                )
            }
        }

        return workItems
    }

    private func resolvedCoverPageID(
        keptStoredPageIDs: Set<ImportPageCandidate.ID>,
        freshWorkItemsByID: [
            ImportPageCandidate.ID: FrozenImportWorkItem
        ],
        resultingChapters: [FrozenImportChapter]
    ) throws -> ImportPageCandidate.ID {
        let storedCoverID = scan.descriptor.coverPageID

        // 独立封面资源不属于任何话，更新不会触及它。
        let coverBelongsToAChapter = scan.descriptor.chapters.contains {
            $0.pageIDs.contains(storedCoverID)
        }
        guard coverBelongsToAChapter else {
            return storedCoverID
        }

        if keptStoredPageIDs.contains(storedCoverID),
           readablePageState(
               for: storedCoverID,
               keptStoredPageIDs: keptStoredPageIDs,
               freshWorkItemsByID: freshWorkItemsByID
           ) == .readable {
            return storedCoverID
        }

        if let freshCover = freshWorkItemsByID[storedCoverID],
           freshCover.pageState == .readable {
            return storedCoverID
        }

        if let freshSuggestedCoverID = scan.freshManifest.coverPageID,
           let freshSuggestedCover = freshWorkItemsByID[
               freshSuggestedCoverID
           ],
           freshSuggestedCover.pageState == .readable {
            return freshSuggestedCoverID
        }

        let fallbackCoverID = resultingChapters.lazy
            .flatMap(\.pageIDs)
            .first { pageID in
                readablePageState(
                    for: pageID,
                    keptStoredPageIDs: keptStoredPageIDs,
                    freshWorkItemsByID: freshWorkItemsByID
                ) == .readable
            }

        guard let fallbackCoverID else {
            throw ComicUpdateDraftError.noReadableRemainingChapter
        }

        return fallbackCoverID
    }

    private func readablePageState(
        for pageID: ImportPageCandidate.ID,
        keptStoredPageIDs: Set<ImportPageCandidate.ID>,
        freshWorkItemsByID: [
            ImportPageCandidate.ID: FrozenImportWorkItem
        ]
    ) -> ImportPageState? {
        if keptStoredPageIDs.contains(pageID) {
            return scan.descriptor.workItems.first(where: {
                $0.id == pageID
            })?.pageState
        }

        return freshWorkItemsByID[pageID]?.pageState
    }

    private static func frozenChapter(
        for chapter: ImportChapterCandidate
    ) -> FrozenImportChapter {
        FrozenImportChapter(
            id: chapter.id,
            parentCollectionID: chapter.parentCollectionID,
            sourceDirectoryPath: chapter.sourceDirectoryPath,
            originalName: chapter.originalName,
            displayName: chapter.originalName,
            role: chapter.role,
            pageIDs: chapter.pageIDs
        )
    }

    private static func collectionsNeeded(
        by chapters: [ImportChapterCandidate],
        in manifest: ImportManifest
    ) -> [ImportCollectionCandidate] {
        let collectionByID = Dictionary(
            uniqueKeysWithValues: manifest.collections.map {
                ($0.id, $0)
            }
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

        return manifest.collections.filter {
            neededCollectionIDs.contains($0.id)
        }
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
}

/// 冻结后的漫画更新操作集合：执行器据此复制、交换与清理，
/// 不再读取扫描结果或用户草稿。
struct FrozenComicUpdate: Equatable, Sendable {
    /// 追加进漫画的新话，保持新扫描顺序；在目录树中的自然
    /// 插入位置由执行器结合来源 siblingIndex 决定。
    let addedChapters: [FrozenImportChapter]
    let addedWorkItems: [FrozenImportWorkItem]
    /// 新增话可能引入的分组祖先链；执行器只写入描述符中尚
    /// 不存在的分组。
    let addedCollections: [ImportCollectionCandidate]
    let replacedChapters: [FrozenComicChapterReplacement]
    /// 用户确认移除的缺失话，保持已入库顺序。
    let removedChapterIDs: [ImportChapterCandidate.ID]
    let coverPageID: ImportPageCandidate.ID
    /// 仅统计需要从来源复制的字节（新增 + 替换）。
    let spaceEstimate: ImportSpaceEstimate
}

/// 一次原地章节替换：以新扫描的完整新话替换旧话。
struct FrozenComicChapterReplacement: Equatable, Sendable {
    let storedChapterID: ImportChapterCandidate.ID
    let freshChapter: FrozenImportChapter
    let freshWorkItems: [FrozenImportWorkItem]
}

enum ComicUpdateDraftError: Error, Equatable, Sendable {
    case unknownAddedChapter
    case unknownReplacementChapter
    case unknownMissingChapter
    case noReadableRemainingChapter
}
