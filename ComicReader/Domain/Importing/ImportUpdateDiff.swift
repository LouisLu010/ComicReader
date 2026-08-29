import Foundation

/// 一次同来源重新扫描与已入库内容之间的章节级差异集合。
/// 匹配身份是来源相对路径；内容变化只以轻量内容指纹判断，
/// 文件大小和修改时间不参与最终结论。
struct ImportUpdateDiff: Equatable, Sendable {
    let addedChapters: [ImportChapterCandidate]
    let replacedChapters: [ImportUpdateReplacedChapter]
    let missingChapters: [ImportUpdateMissingChapter]
    let unchangedChapterCount: Int

    var isEmpty: Bool {
        addedChapters.isEmpty
            && replacedChapters.isEmpty
            && missingChapters.isEmpty
    }
}

/// 已入库话在来源中仍然存在，但页面内容发生了变化。
struct ImportUpdateReplacedChapter: Equatable, Sendable {
    /// 重新扫描得到的话；Replace 执行时以它建立完整新章。
    let freshChapter: ImportChapterCandidate
    /// 已入库话的稳定 ID；其角色可能与新扫描结果不同。
    let storedChapterID: ImportChapterCandidate.ID
    /// 新增页面路径，按新扫描的页序排列。
    let addedPagePaths: [SourceRelativePath]
    /// 来源中消失的页面路径，按已入库页序排列。
    let removedPagePaths: [SourceRelativePath]
    /// 路径不变但内容摘要变化的页面路径，按新扫描的页序排列。
    let changedPagePaths: [SourceRelativePath]

    var sourceDirectoryPath: SourceRelativePath {
        freshChapter.sourceDirectoryPath
    }
}

/// 已入库话在本次重新扫描中没有找到对应来源目录。
struct ImportUpdateMissingChapter: Equatable, Sendable {
    let chapterID: ImportChapterCandidate.ID
    let sourceDirectoryPath: SourceRelativePath
}

enum ImportUpdateDiffCalculator {
    static func make(
        storedChapters: [FrozenImportChapter],
        storedWorkItems: [FrozenImportWorkItem],
        freshManifest: ImportManifest
    ) -> ImportUpdateDiff {
        var freshChaptersByPath: [SourceRelativePath: ImportChapterCandidate] = [:]
        for chapter in freshManifest.chapters
        where freshChaptersByPath[chapter.sourceDirectoryPath] == nil {
            freshChaptersByPath[chapter.sourceDirectoryPath] = chapter
        }

        let storedWorkItemsByID = Dictionary(
            storedWorkItems.map { ($0.id, $0) },
            uniquingKeysWith: { _, workItem in workItem }
        )
        let freshPagesByID = Dictionary(
            freshManifest.pages.map { ($0.id, $0) },
            uniquingKeysWith: { _, page in page }
        )

        var addedChapters: [ImportChapterCandidate] = []
        var replacedChapters: [ImportUpdateReplacedChapter] = []
        var missingChapters: [ImportUpdateMissingChapter] = []
        var unchangedChapterCount = 0
        var matchedFreshPaths = Set<SourceRelativePath>()

        for storedChapter in storedChapters {
            guard let freshChapter = freshChaptersByPath[
                storedChapter.sourceDirectoryPath
            ] else {
                missingChapters.append(
                    ImportUpdateMissingChapter(
                        chapterID: storedChapter.id,
                        sourceDirectoryPath: storedChapter.sourceDirectoryPath
                    )
                )
                continue
            }

            matchedFreshPaths.insert(storedChapter.sourceDirectoryPath)
            let storedPages = storedChapter.pageIDs.compactMap { pageID in
                storedWorkItemsByID[pageID].map { entry in
                    ImportUpdatePageEntry(
                        path: entry.sourceRelativePath,
                        fingerprint: entry.expectedLightweightFingerprint
                    )
                }
            }
            let freshPages = freshChapter.pageIDs.compactMap { pageID in
                freshPagesByID[pageID].map { page in
                    ImportUpdatePageEntry(
                        path: page.sourceRelativePath,
                        fingerprint: page.lightweightFingerprint
                    )
                }
            }

            let addedPagePaths = pageDifferences(
                in: freshPages,
                absentFrom: storedPages
            )
            let removedPagePaths = pageDifferences(
                in: storedPages,
                absentFrom: freshPages
            )
            let storedFingerprintsByPath = Dictionary(
                storedPages.map { ($0.path, $0.fingerprint) },
                uniquingKeysWith: { _, fingerprint in fingerprint }
            )
            let changedPagePaths = freshPages.compactMap {
                freshPage -> SourceRelativePath? in
                guard let storedFingerprint = storedFingerprintsByPath[
                    freshPage.path
                ] else {
                    return nil
                }

                return storedFingerprint != freshPage.fingerprint
                    ? freshPage.path : nil
            }

            if addedPagePaths.isEmpty,
               removedPagePaths.isEmpty,
               changedPagePaths.isEmpty {
                unchangedChapterCount += 1
            } else {
                replacedChapters.append(
                    ImportUpdateReplacedChapter(
                        freshChapter: freshChapter,
                        storedChapterID: storedChapter.id,
                        addedPagePaths: addedPagePaths,
                        removedPagePaths: removedPagePaths,
                        changedPagePaths: changedPagePaths
                    )
                )
            }
        }

        for freshChapter in freshManifest.chapters
        where !matchedFreshPaths.contains(freshChapter.sourceDirectoryPath) {
            addedChapters.append(freshChapter)
        }

        return ImportUpdateDiff(
            addedChapters: addedChapters,
            replacedChapters: replacedChapters,
            missingChapters: missingChapters,
            unchangedChapterCount: unchangedChapterCount
        )
    }

    private static func pageDifferences(
        in pages: [ImportUpdatePageEntry],
        absentFrom otherPages: [ImportUpdatePageEntry]
    ) -> [SourceRelativePath] {
        let otherPaths = Set(otherPages.map(\.path))
        return pages
            .filter { !otherPaths.contains($0.path) }
            .map(\.path)
    }
}

private struct ImportUpdatePageEntry: Equatable, Sendable {
    let path: SourceRelativePath
    let fingerprint: String?
}
