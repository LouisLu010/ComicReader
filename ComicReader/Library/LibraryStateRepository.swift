import Foundation
import Observation
import SwiftData

struct LibraryReadingProgress: Equatable, Sendable {
    let chapterID: String
    let pageID: String
    let pageOffset: Double
    let zoomScale: Double
    let isCompleted: Bool
    let updatedAt: Date

    init(
        chapterID: String,
        pageID: String,
        pageOffset: Double,
        zoomScale: Double,
        isCompleted: Bool = false,
        updatedAt: Date = Date()
    ) {
        self.chapterID = chapterID
        self.pageID = pageID
        self.pageOffset = pageOffset.isFinite
            ? min(max(pageOffset, 0), 1)
            : 0
        self.zoomScale = zoomScale.isFinite
            ? min(max(zoomScale, 0.1), 16)
            : 1
        self.isCompleted = isCompleted
        self.updatedAt = updatedAt
    }

    var isValid: Bool {
        !chapterID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !pageID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

struct LibraryComicUserState: Equatable, Sendable {
    static let empty = Self(isFavorite: false, progress: nil)

    let isFavorite: Bool
    let progress: LibraryReadingProgress?
}

enum LibraryStateRepositoryStatus: Equatable, Sendable {
    case unconfigured
    case loading
    case ready
    case unavailable
    case failed
}

private struct LibraryStateStoreSnapshot: Sendable {
    let statesByComicID: [ManagedComicID: LibraryComicUserState]
    let indexedComicIDs: Set<ManagedComicID>
}

private enum LibraryStateProgressWriteResult: Sendable {
    case applied(LibraryStateStoreSnapshot)
    case rejected(LibraryStateStoreSnapshot)
    case missingComic
}

@ModelActor
private actor LibraryStateStore {
    func snapshot() throws -> LibraryStateStoreSnapshot {
        try makeSnapshot(
            storedComics: modelContext.fetch(
                FetchDescriptor<ComicReaderSchemaV1.StoredComic>()
            ),
            storedProgress: modelContext.fetch(
                FetchDescriptor<ComicReaderSchemaV1.StoredReadingProgress>()
            )
        )
    }

    func reconcile(
        catalogItems: [LibraryCatalogItem]
    ) throws -> LibraryStateStoreSnapshot {
        var storedComics = try modelContext.fetch(
            FetchDescriptor<ComicReaderSchemaV1.StoredComic>()
        )
        let storedProgress = try modelContext.fetch(
            FetchDescriptor<ComicReaderSchemaV1.StoredReadingProgress>()
        )
        var comicsByID = firstStoredComicsByComicID(storedComics)

        for item in catalogItems {
            let record = item.record
            let comicID = item.id.rawValue

            if let storedComic = comicsByID[comicID] {
                storedComic.displayName = record.displayName
                storedComic.sourceRootName = record.sourceRootName
                storedComic.importedAt = record.importedAt
                storedComic.chapterCount = record.chapterCount
                storedComic.pageCount = record.pageCount
            } else {
                let storedComic = ComicReaderSchemaV1.StoredComic(
                    comicID: comicID,
                    displayName: record.displayName,
                    sourceRootName: record.sourceRootName,
                    importedAt: record.importedAt,
                    chapterCount: record.chapterCount,
                    pageCount: record.pageCount
                )
                modelContext.insert(storedComic)
                storedComics.append(storedComic)
                comicsByID[comicID] = storedComic
            }
        }

        try saveOrRollback()
        return makeSnapshot(
            storedComics: storedComics,
            storedProgress: storedProgress
        )
    }

    func toggleFavorite(
        for comicID: ManagedComicID
    ) throws -> LibraryStateStoreSnapshot? {
        let storedComics = try modelContext.fetch(
            FetchDescriptor<ComicReaderSchemaV1.StoredComic>()
        )
        let storedProgress = try modelContext.fetch(
            FetchDescriptor<ComicReaderSchemaV1.StoredReadingProgress>()
        )
        guard let storedComic = storedComics.first(where: {
            $0.comicID == comicID.rawValue
        }) else {
            return nil
        }

        storedComic.isFavorite.toggle()
        try saveOrRollback()
        return makeSnapshot(
            storedComics: storedComics,
            storedProgress: storedProgress
        )
    }

    func recordProgress(
        _ progress: LibraryReadingProgress,
        for comicID: ManagedComicID
    ) throws -> LibraryStateProgressWriteResult {
        let storedComics = try modelContext.fetch(
            FetchDescriptor<ComicReaderSchemaV1.StoredComic>()
        )
        guard storedComics.contains(where: {
            $0.comicID == comicID.rawValue
        }) else {
            return .missingComic
        }

        var storedProgress = try modelContext.fetch(
            FetchDescriptor<ComicReaderSchemaV1.StoredReadingProgress>()
        )
        if let record = storedProgress.first(where: {
            $0.comicID == comicID.rawValue
        }) {
            guard progress.updatedAt >= record.updatedAt else {
                return .rejected(
                    makeSnapshot(
                        storedComics: storedComics,
                        storedProgress: storedProgress
                    )
                )
            }

            record.chapterID = progress.chapterID
            record.pageID = progress.pageID
            record.pageOffset = progress.pageOffset
            record.zoomScale = progress.zoomScale
            record.isCompleted = progress.isCompleted
            record.updatedAt = progress.updatedAt
        } else {
            let record = ComicReaderSchemaV1.StoredReadingProgress(
                comicID: comicID.rawValue,
                chapterID: progress.chapterID,
                pageID: progress.pageID,
                pageOffset: progress.pageOffset,
                zoomScale: progress.zoomScale,
                isCompleted: progress.isCompleted,
                updatedAt: progress.updatedAt
            )
            modelContext.insert(record)
            storedProgress.append(record)
        }

        try saveOrRollback()
        return .applied(
            makeSnapshot(
                storedComics: storedComics,
                storedProgress: storedProgress
            )
        )
    }

    private func saveOrRollback() throws {
        do {
            try modelContext.save()
        } catch {
            modelContext.rollback()
            throw error
        }
    }

    private func makeSnapshot(
        storedComics: [ComicReaderSchemaV1.StoredComic],
        storedProgress: [ComicReaderSchemaV1.StoredReadingProgress]
    ) -> LibraryStateStoreSnapshot {
        let comicsByID = firstStoredComicsByComicID(storedComics)
        let progressByComicID = firstStoredProgressByComicID(storedProgress)
        var statesByComicID: [ManagedComicID: LibraryComicUserState] = [:]

        for (rawComicID, storedComic) in comicsByID {
            let progress = progressByComicID[rawComicID].flatMap { record in
                let progress = LibraryReadingProgress(
                    chapterID: record.chapterID,
                    pageID: record.pageID,
                    pageOffset: record.pageOffset,
                    zoomScale: record.zoomScale,
                    isCompleted: record.isCompleted,
                    updatedAt: record.updatedAt
                )
                return progress.isValid ? progress : nil
            }
            statesByComicID[ManagedComicID(rawValue: rawComicID)] =
                LibraryComicUserState(
                    isFavorite: storedComic.isFavorite,
                    progress: progress
                )
        }

        return LibraryStateStoreSnapshot(
            statesByComicID: statesByComicID,
            indexedComicIDs: Set(statesByComicID.keys)
        )
    }

    private func firstStoredComicsByComicID(
        _ records: [ComicReaderSchemaV1.StoredComic]
    ) -> [UUID: ComicReaderSchemaV1.StoredComic] {
        var recordsByComicID: [UUID: ComicReaderSchemaV1.StoredComic] = [:]
        for record in records where recordsByComicID[record.comicID] == nil {
            recordsByComicID[record.comicID] = record
        }
        return recordsByComicID
    }

    private func firstStoredProgressByComicID(
        _ records: [ComicReaderSchemaV1.StoredReadingProgress]
    ) -> [UUID: ComicReaderSchemaV1.StoredReadingProgress] {
        var recordsByComicID: [
            UUID: ComicReaderSchemaV1.StoredReadingProgress
        ] = [:]
        for record in records where recordsByComicID[record.comicID] == nil {
            recordsByComicID[record.comicID] = record
        }
        return recordsByComicID
    }
}

@MainActor
@Observable
final class LibraryStateRepository {
    private(set) var status: LibraryStateRepositoryStatus = .unconfigured
    private(set) var statesByComicID: [ManagedComicID: LibraryComicUserState] = [:]

    @ObservationIgnored private var store: LibraryStateStore?
    @ObservationIgnored private var configuredContainer: ModelContainer?
    @ObservationIgnored private var storeCreationTask: Task<
        LibraryStateStore,
        Never
    >?
    @ObservationIgnored private var indexedComicIDs = Set<ManagedComicID>()

    func configure(modelContainer: ModelContainer?) async {
        guard let modelContainer else {
            storeCreationTask?.cancel()
            storeCreationTask = nil
            store = nil
            configuredContainer = nil
            indexedComicIDs = []
            statesByComicID = [:]
            status = .unavailable
            return
        }

        if configuredContainer === modelContainer {
            guard let storeCreationTask else {
                return
            }

            let createdStore = await storeCreationTask.value
            guard configuredContainer === modelContainer else {
                return
            }

            store = createdStore
            self.storeCreationTask = nil
            if status == .loading {
                await reload()
            }
            return
        }

        storeCreationTask?.cancel()
        status = .loading
        configuredContainer = modelContainer
        let creationTask = Task.detached(priority: .userInitiated) {
            LibraryStateStore(modelContainer: modelContainer)
        }
        storeCreationTask = creationTask
        let createdStore = await creationTask.value
        guard configuredContainer === modelContainer else {
            return
        }

        store = createdStore
        storeCreationTask = nil
        await reload()
    }

    func reload() async {
        guard let store else {
            status = .unavailable
            return
        }

        status = .loading
        do {
            apply(try await store.snapshot())
            status = .ready
        } catch {
            status = .failed
        }
    }

    func reconcile(catalogItems: [LibraryCatalogItem]) async {
        guard let store else {
            status = .unavailable
            return
        }

        status = .loading
        do {
            apply(try await store.reconcile(catalogItems: catalogItems))
            status = .ready
        } catch {
            status = .failed
        }
    }

    func state(for comicID: ManagedComicID) -> LibraryComicUserState {
        statesByComicID[comicID] ?? .empty
    }

    func canModifyState(for comicID: ManagedComicID) -> Bool {
        status == .ready && indexedComicIDs.contains(comicID)
    }

    func toggleFavorite(for comicID: ManagedComicID) async {
        guard let store else {
            status = .unavailable
            return
        }

        do {
            if let snapshot = try await store.toggleFavorite(for: comicID) {
                apply(snapshot)
            }
            status = .ready
        } catch {
            status = .failed
        }
    }

    @discardableResult
    func recordProgress(
        _ progress: LibraryReadingProgress,
        for comicID: ManagedComicID
    ) async -> Bool {
        guard progress.isValid, let store else {
            if store == nil {
                status = .unavailable
            }
            return false
        }

        do {
            let result = try await store.recordProgress(
                progress,
                for: comicID
            )

            switch result {
            case .missingComic:
                return false
            case let .rejected(snapshot):
                apply(snapshot)
                status = .ready
                return false
            case let .applied(snapshot):
                apply(snapshot)
                status = .ready
                return true
            }
        } catch {
            status = .failed
            return false
        }
    }

    func favoriteComics(
        in catalogItems: [LibraryCatalogItem]
    ) -> [LibraryCatalogItem] {
        guard status == .ready else {
            return []
        }

        return catalogItems.filter { state(for: $0.id).isFavorite }
    }

    func unreadComics(
        in catalogItems: [LibraryCatalogItem]
    ) -> [LibraryCatalogItem] {
        guard status == .ready else {
            return []
        }

        return catalogItems.filter {
            state(for: $0.id).progress?.isCompleted != true
        }
    }

    func continueReadingComics(
        in catalogItems: [LibraryCatalogItem]
    ) -> [LibraryCatalogItem] {
        guard status == .ready else {
            return []
        }

        return catalogItems
            .filter {
                state(for: $0.id).progress?.isCompleted == false
            }
            .sorted { lhs, rhs in
                let lhsProgress = state(for: lhs.id).progress
                let rhsProgress = state(for: rhs.id).progress

                switch (lhsProgress, rhsProgress) {
                case let (.some(lhsProgress), .some(rhsProgress)):
                    if lhsProgress.updatedAt != rhsProgress.updatedAt {
                        return lhsProgress.updatedAt > rhsProgress.updatedAt
                    }
                case (.some, .none):
                    return true
                case (.none, .some):
                    return false
                case (.none, .none):
                    break
                }

                return lhs.id.rawValue.uuidString < rhs.id.rawValue.uuidString
            }
    }

    private func apply(_ snapshot: LibraryStateStoreSnapshot) {
        statesByComicID = snapshot.statesByComicID
        indexedComicIDs = snapshot.indexedComicIDs
    }
}
