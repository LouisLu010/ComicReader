import Foundation
import Observation

@MainActor
@Observable
final class LibraryTrashCoordinator {
    private(set) var trashedComics: [LibraryTrashedComic] = []

    @ObservationIgnored private let store: FileSystemLibraryTrashStore?

    init(layout: ImportStorageLayout?) {
        store = layout.map { FileSystemLibraryTrashStore(layout: $0) }
    }

    func reload() async {
        trashedComics = await store?.trashedComics() ?? []
    }

    /// 软删除；返回是否发生了状态变化。
    @discardableResult
    func trashComic(for comicID: ManagedComicID) async -> Bool {
        guard !trashedComics.contains(where: { $0.id == comicID }) else {
            return false
        }

        guard let store else {
            return false
        }

        do {
            _ = try await store.markTrashed(comicID: comicID)
        } catch {
            return false
        }

        await reload()
        return true
    }

    /// 恢复漫画；返回是否发生了状态变化。
    @discardableResult
    func restoreComic(for comicID: ManagedComicID) async -> Bool {
        guard let store else {
            return false
        }

        let didRestore = await store.restore(comicID: comicID)
        if didRestore {
            await reload()
        }

        return didRestore
    }

    /// 永久删除：移除 App 管理的漫画副本与缩略图，不可恢复。
    @discardableResult
    func purgeComic(for comicID: ManagedComicID) async -> Bool {
        guard let store else {
            return false
        }

        let didPurge = await store.purge(comicID: comicID)
        if didPurge {
            await reload()
        }

        return didPurge
    }

    /// 清理保留期已满的漫画，返回被清理的漫画 ID。
    @discardableResult
    func purgeComicsPastRetention(now: Date = Date()) async -> [ManagedComicID] {
        guard let store else {
            return []
        }

        let dueComicIDs = LibraryTrashPolicy.purgeDueComicIDs(
            trashedComics,
            now: now
        )
        for comicID in dueComicIDs {
            await store.purge(comicID: comicID)
        }

        if !dueComicIDs.isEmpty {
            await reload()
        }

        return dueComicIDs
    }
}
