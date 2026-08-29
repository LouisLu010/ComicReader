import Foundation
import Observation

enum LibraryCatalogState: Equatable, Sendable {
    case idle
    case loading
    case loaded
    case failed
}

@MainActor
@Observable
final class LibraryCatalogCoordinator {
    private(set) var state: LibraryCatalogState = .idle
    private(set) var comics: [LibraryCatalogItem] = []
    private(set) var comicsByTitle: [LibraryCatalogItem] = []
    private(set) var ignoredEntryCount = 0
    /// 书库搜索/筛选/排序的用户决策；跨分区与窗口共享。
    var searchFilter = LibrarySearchFilter()

    @ObservationIgnored private let loader: (any LibraryCatalogLoading)?
    @ObservationIgnored private let layout: ImportStorageLayout?
    @ObservationIgnored private var reloadGeneration = 0

    init(
        loader: any LibraryCatalogLoading,
        layout: ImportStorageLayout
    ) {
        self.loader = loader
        self.layout = layout
    }

    init() {
        do {
            let layout = try JSONImportJobStore.applicationSupportLayout()
            loader = FileSystemLibraryCatalogLoader(layout: layout)
            self.layout = layout
        } catch {
            loader = nil
            layout = nil
            state = .failed
        }
    }

    @discardableResult
    func reload() async -> Bool {
        guard let loader else {
            state = .failed
            return false
        }

        reloadGeneration += 1
        let generation = reloadGeneration
        state = .loading

        do {
            let result = try await loader.loadCatalog()
            guard !Task.isCancelled, generation == reloadGeneration else {
                return false
            }

            comics = result.comics
            comicsByTitle = result.comics.sorted(by: Self.titleOrder)
            ignoredEntryCount = result.ignoredEntryCount
            state = .loaded
            return true
        } catch is CancellationError {
            return false
        } catch {
            guard generation == reloadGeneration else {
                return false
            }

            state = .failed
            return false
        }
    }

    func reloadAndReconcile(with libraryState: LibraryStateRepository) async {
        guard await reload(), !Task.isCancelled else {
            return
        }

        await libraryState.reconcile(catalogItems: comics)
    }

    func thumbnailURL(for comic: LibraryCatalogItem) -> URL? {
        guard comic.thumbnailAvailable, let layout else {
            return nil
        }

        return layout.thumbnailURL(for: comic.id)
    }

    private static func titleOrder(
        _ lhs: LibraryCatalogItem,
        _ rhs: LibraryCatalogItem
    ) -> Bool {
        let comparison = lhs.record.displayName.localizedStandardCompare(
            rhs.record.displayName
        )
        if comparison != .orderedSame {
            return comparison == .orderedAscending
        }

        return lhs.id.rawValue.uuidString < rhs.id.rawValue.uuidString
    }
}
