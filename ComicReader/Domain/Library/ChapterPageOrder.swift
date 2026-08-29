import Foundation

/// 一话内的用户页序覆盖；提交前必须校验为该话页面的一个
/// 排列。存储中的记录按话键控，读取时不与当前页面集合重新
/// 校验——替换话之后由更新流程负责按内容摘要尽量迁移。
struct ChapterPageOrder: Equatable, Sendable {
    let chapterID: ImportChapterCandidate.ID
    let orderedPageIDs: [ImportPageCandidate.ID]

    /// 从存储还原：不做页面集合校验。
    init(
        chapterID: ImportChapterCandidate.ID,
        orderedPageIDs: [ImportPageCandidate.ID]
    ) {
        self.chapterID = chapterID
        self.orderedPageIDs = orderedPageIDs
    }

    /// 用户提交路径：页序必须恰为该话页面集合的一个排列。
    init(
        chapterID: ImportChapterCandidate.ID,
        orderedPageIDs: [ImportPageCandidate.ID],
        naturalPageIDs: [ImportPageCandidate.ID]
    ) throws {
        guard !orderedPageIDs.isEmpty else {
            throw ChapterPageOrderError.emptyPages
        }
        guard orderedPageIDs.count == naturalPageIDs.count,
              Set(orderedPageIDs) == Set(naturalPageIDs) else {
            throw ChapterPageOrderError.notAPermutation
        }

        self.chapterID = chapterID
        self.orderedPageIDs = orderedPageIDs
    }

    /// 整话反序。
    static func reversed(
        _ chapterID: ImportChapterCandidate.ID,
        naturalPageIDs: [ImportPageCandidate.ID]
    ) -> ChapterPageOrder {
        ChapterPageOrder(
            chapterID: chapterID,
            orderedPageIDs: naturalPageIDs.reversed()
        )
    }

    /// 与自然顺序一致时该覆盖是冗余的，可以清除。
    func isRedundant(for naturalPageIDs: [ImportPageCandidate.ID]) -> Bool {
        orderedPageIDs == naturalPageIDs
    }

    /// 应用到当前话页面：覆盖里已消失的页面按自然顺序补回，
    /// 新页面按自然顺序并入尾部，保持全部页面可读。
    func applied(to naturalPageIDs: [ImportPageCandidate.ID]) ->
        [ImportPageCandidate.ID] {
        let orderedSet = Set(orderedPageIDs)
        let preserved = orderedPageIDs.filter {
            naturalPageIDs.contains($0)
        }
        let appended = naturalPageIDs.filter { !orderedSet.contains($0) }
        return preserved + appended
    }
}

enum ChapterPageOrderError: Error, Equatable, Sendable {
    case emptyPages
    case notAPermutation
}
