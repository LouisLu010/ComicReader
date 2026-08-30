import Foundation
import Observation
import SwiftData

private func normalizedCompletedChapterIDs<IDs: Sequence>(
    _ chapterIDs: IDs
) -> Set<String> where IDs.Element == String {
    Set(
        chapterIDs.compactMap { rawChapterID in
            let chapterID = rawChapterID.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            return chapterID.isEmpty ? nil : chapterID
        }
    )
}

struct LibraryReadingProgress: Equatable, Sendable {
    let chapterID: String
    let pageID: String
    let pageOffset: Double
    let zoomScale: Double
    /// 仅用于读取 V1–V3 进度中的旧偏好影子值，不再作为偏好写入来源。
    let readingMode: ReadingMode
    let readingDirection: ReadingDirection
    let completedChapterIDs: Set<String>
    let isCompleted: Bool
    let updatedAt: Date

    init(
        chapterID: String,
        pageID: String,
        pageOffset: Double,
        zoomScale: Double,
        readingMode: ReadingMode = .continuous,
        readingDirection: ReadingDirection = .leftToRight,
        completedChapterIDs: Set<String> = [],
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
        self.readingMode = readingMode
        self.readingDirection = readingDirection
        self.completedChapterIDs = normalizedCompletedChapterIDs(
            completedChapterIDs
        )
        self.isCompleted = isCompleted
        self.updatedAt = updatedAt
    }

    var isValid: Bool {
        !chapterID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !pageID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

struct LibraryComicUserState: Equatable, Sendable {
    static let empty = Self(
        isFavorite: false,
        progress: nil,
        readerOverrides: .none
    )

    let isFavorite: Bool
    let progress: LibraryReadingProgress?
    let readerOverrides: ComicReaderOverrides

    init(
        isFavorite: Bool,
        progress: LibraryReadingProgress?,
        readerOverrides: ComicReaderOverrides = .none
    ) {
        self.isFavorite = isFavorite
        self.progress = progress
        self.readerOverrides = readerOverrides
    }
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
    let globalReaderPreferences: ReaderGlobalPreferences
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
                FetchDescriptor<ComicReaderSchemaV6.StoredComic>()
            ),
            storedProgress: modelContext.fetch(
                FetchDescriptor<ComicReaderSchemaV6.StoredReadingProgress>()
            ),
            globalPreferences: try globalPreferencesRecord()
        )
    }

    func reconcile(
        catalogItems: [LibraryCatalogItem]
    ) throws -> LibraryStateStoreSnapshot {
        var storedComics = try modelContext.fetch(
            FetchDescriptor<ComicReaderSchemaV6.StoredComic>()
        )
        let storedProgress = try modelContext.fetch(
            FetchDescriptor<ComicReaderSchemaV6.StoredReadingProgress>()
        )
        let globalPreferences = try globalPreferencesRecord()
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
                let storedComic = ComicReaderSchemaV6.StoredComic(
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
            storedProgress: storedProgress,
            globalPreferences: globalPreferences
        )
    }

    func toggleFavorite(
        for comicID: ManagedComicID
    ) throws -> LibraryStateStoreSnapshot? {
        let storedComics = try modelContext.fetch(
            FetchDescriptor<ComicReaderSchemaV6.StoredComic>()
        )
        let storedProgress = try modelContext.fetch(
            FetchDescriptor<ComicReaderSchemaV6.StoredReadingProgress>()
        )
        let globalPreferences = try globalPreferencesRecord()
        guard let storedComic = storedComics.first(where: {
            $0.comicID == comicID.rawValue
        }) else {
            return nil
        }

        storedComic.isFavorite.toggle()
        try saveOrRollback()
        return makeSnapshot(
            storedComics: storedComics,
            storedProgress: storedProgress,
            globalPreferences: globalPreferences
        )
    }

    func recordProgress(
        _ progress: LibraryReadingProgress,
        for comicID: ManagedComicID
    ) throws -> LibraryStateProgressWriteResult {
        let storedComics = try modelContext.fetch(
            FetchDescriptor<ComicReaderSchemaV6.StoredComic>()
        )
        let globalPreferences = try globalPreferencesRecord()
        guard storedComics.contains(where: {
            $0.comicID == comicID.rawValue
        }) else {
            return .missingComic
        }

        var storedProgress = try modelContext.fetch(
            FetchDescriptor<ComicReaderSchemaV6.StoredReadingProgress>()
        )
        if let record = storedProgress.first(where: {
            $0.comicID == comicID.rawValue
        }) {
            let mergedCompletedChapterIDs = normalizedCompletedChapterIDs(
                record.completedChapterIDs
            )
                .union(progress.completedChapterIDs)
                .sorted()

            if progress.updatedAt < record.updatedAt {
                if progress.isCompleted
                    || !progress.completedChapterIDs.isEmpty {
                    let mergedComicCompletion = record.isCompleted
                        || progress.isCompleted
                    if record.isCompleted != mergedComicCompletion
                        || record.completedChapterIDs != mergedCompletedChapterIDs {
                        // 位置仍采用较新的记录，但已读状态必须可跨窗口合并。
                        record.isCompleted = mergedComicCompletion
                        record.completedChapterIDs = mergedCompletedChapterIDs
                        try saveOrRollback()
                    }
                    return .applied(
                        makeSnapshot(
                            storedComics: storedComics,
                            storedProgress: storedProgress,
                            globalPreferences: globalPreferences
                        )
                    )
                }

                return .rejected(
                    makeSnapshot(
                        storedComics: storedComics,
                        storedProgress: storedProgress,
                        globalPreferences: globalPreferences
                    )
                )
            }

            record.chapterID = progress.chapterID
            record.pageID = progress.pageID
            record.pageOffset = progress.pageOffset
            record.zoomScale = progress.zoomScale
            // 尚无显式“标记未读”操作，已读状态必须在不同窗口间合并。
            record.completedChapterIDs = mergedCompletedChapterIDs
            record.isCompleted = record.isCompleted || progress.isCompleted
            record.updatedAt = progress.updatedAt
        } else {
            let record = ComicReaderSchemaV6.StoredReadingProgress(
                comicID: comicID.rawValue,
                chapterID: progress.chapterID,
                pageID: progress.pageID,
                pageOffset: progress.pageOffset,
                zoomScale: progress.zoomScale,
                completedChapterIDs: progress.completedChapterIDs.sorted(),
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
                storedProgress: storedProgress,
                globalPreferences: globalPreferences
            )
        )
    }

    func setDefaultReadingMode(
        _ readingMode: ReadingMode
    ) throws -> LibraryStateStoreSnapshot {
        let storedComics = try modelContext.fetch(
            FetchDescriptor<ComicReaderSchemaV6.StoredComic>()
        )
        let storedProgress = try modelContext.fetch(
            FetchDescriptor<ComicReaderSchemaV6.StoredReadingProgress>()
        )
        let globalPreferences = try globalPreferencesRecord()
        globalPreferences.defaultReadingModeRawValue = readingMode.rawValue
        try saveOrRollback()

        return makeSnapshot(
            storedComics: storedComics,
            storedProgress: storedProgress,
            globalPreferences: globalPreferences
        )
    }

    func setDefaultReadingDirection(
        _ readingDirection: ReadingDirection
    ) throws -> LibraryStateStoreSnapshot {
        let storedComics = try modelContext.fetch(
            FetchDescriptor<ComicReaderSchemaV6.StoredComic>()
        )
        let storedProgress = try modelContext.fetch(
            FetchDescriptor<ComicReaderSchemaV6.StoredReadingProgress>()
        )
        let globalPreferences = try globalPreferencesRecord()
        globalPreferences.defaultReadingDirectionRawValue = readingDirection.rawValue
        try saveOrRollback()

        return makeSnapshot(
            storedComics: storedComics,
            storedProgress: storedProgress,
            globalPreferences: globalPreferences
        )
    }

    func setTapZoneAction(
        _ action: ReaderTapZoneAction,
        isLeftZone: Bool
    ) throws -> LibraryStateStoreSnapshot {
        let storedComics = try modelContext.fetch(
            FetchDescriptor<ComicReaderSchemaV6.StoredComic>()
        )
        let storedProgress = try modelContext.fetch(
            FetchDescriptor<ComicReaderSchemaV6.StoredReadingProgress>()
        )
        let globalPreferences = try globalPreferencesRecord()
        if isLeftZone {
            globalPreferences.leftTapActionRawValue = action.rawValue
        } else {
            globalPreferences.rightTapActionRawValue = action.rawValue
        }
        try saveOrRollback()

        return makeSnapshot(
            storedComics: storedComics,
            storedProgress: storedProgress,
            globalPreferences: globalPreferences
        )
    }

    func setReadingModeOverride(
        _ readingMode: ReadingMode?,
        for comicID: ManagedComicID
    ) throws -> LibraryStateStoreSnapshot? {
        let storedComics = try modelContext.fetch(
            FetchDescriptor<ComicReaderSchemaV6.StoredComic>()
        )
        let storedProgress = try modelContext.fetch(
            FetchDescriptor<ComicReaderSchemaV6.StoredReadingProgress>()
        )
        let globalPreferences = try globalPreferencesRecord()
        guard let storedComic = storedComics.first(where: {
            $0.comicID == comicID.rawValue
        }) else {
            return nil
        }

        storedComic.readingModeOverrideRawValue = readingMode?.rawValue
        try saveOrRollback()

        return makeSnapshot(
            storedComics: storedComics,
            storedProgress: storedProgress,
            globalPreferences: globalPreferences
        )
    }

    func setReadingDirectionOverride(
        _ readingDirection: ReadingDirection?,
        for comicID: ManagedComicID
    ) throws -> LibraryStateStoreSnapshot? {
        let storedComics = try modelContext.fetch(
            FetchDescriptor<ComicReaderSchemaV6.StoredComic>()
        )
        let storedProgress = try modelContext.fetch(
            FetchDescriptor<ComicReaderSchemaV6.StoredReadingProgress>()
        )
        let globalPreferences = try globalPreferencesRecord()
        guard let storedComic = storedComics.first(where: {
            $0.comicID == comicID.rawValue
        }) else {
            return nil
        }

        storedComic.readingDirectionOverrideRawValue = readingDirection?.rawValue
        try saveOrRollback()

        return makeSnapshot(
            storedComics: storedComics,
            storedProgress: storedProgress,
            globalPreferences: globalPreferences
        )
    }

    func chapterPageOrder(
        chapterID: ImportChapterCandidate.ID,
        for comicID: ManagedComicID
    ) throws -> ChapterPageOrder? {
        guard let record = try chapterPageOrderRecord(
            comicID: comicID,
            chapterID: chapterID
        ) else {
            return nil
        }

        return ChapterPageOrder(
            chapterID: chapterID,
            orderedPageIDs: record.orderedPageIDs.map { pageID in
                ImportPageCandidate.ID(rawValue: pageID)
            }
        )
    }

    func setChapterPageOrder(
        _ order: ChapterPageOrder,
        for comicID: ManagedComicID
    ) throws -> Bool {
        let storedComics = try modelContext.fetch(
            FetchDescriptor<ComicReaderSchemaV6.StoredComic>()
        )
        guard storedComics.contains(where: {
            $0.comicID == comicID.rawValue
        }) else {
            return false
        }

        let record = try chapterPageOrderRecord(
            comicID: comicID,
            chapterID: order.chapterID
        )
        if let record {
            record.orderedPageIDs = order.orderedPageIDs.map(\.rawValue)
            record.updatedAt = Date()
        } else {
            modelContext.insert(
                ComicReaderSchemaV6.StoredChapterPageOrder(
                    comicID: comicID.rawValue,
                    chapterID: order.chapterID.rawValue,
                    orderedPageIDs: order.orderedPageIDs.map(\.rawValue),
                    updatedAt: Date()
                )
            )
        }

        try saveOrRollback()
        return true
    }

    func clearChapterPageOrder(
        chapterID: ImportChapterCandidate.ID,
        for comicID: ManagedComicID
    ) throws -> Bool {
        guard let record = try chapterPageOrderRecord(
            comicID: comicID,
            chapterID: chapterID
        ) else {
            return false
        }

        modelContext.delete(record)
        try saveOrRollback()
        return true
    }

    func chapterPageOrders(
        for comicID: ManagedComicID
    ) throws -> [ImportChapterCandidate.ID: [ImportPageCandidate.ID]] {
        try modelContext
            .fetch(
                FetchDescriptor<ComicReaderSchemaV6.StoredChapterPageOrder>()
            )
            .reduce(into: [:]) { result, record in
                guard record.comicID == comicID.rawValue else {
                    return
                }

                result[ImportChapterCandidate.ID(rawValue: record.chapterID)] =
                    record.orderedPageIDs.map { pageID in
                        ImportPageCandidate.ID(rawValue: pageID)
                    }
            }
    }

    func shelves() throws -> [ComicShelf] {
        try modelContext
            .fetch(FetchDescriptor<ComicReaderSchemaV6.StoredComicShelf>())
            .map { record in
                ComicShelf(
                    id: ComicShelfID(rawValue: record.shelfID),
                    displayName: record.displayName,
                    sortOrder: record.sortOrder,
                    createdAt: record.createdAt
                )
            }
            .sorted { lhs, rhs in
                if lhs.sortOrder != rhs.sortOrder {
                    return lhs.sortOrder < rhs.sortOrder
                }

                return lhs.createdAt < rhs.createdAt
            }
    }

    func createShelf(named rawName: String) throws -> ComicShelf? {
        guard let name = ComicShelf.normalizedName(rawName) else {
            return nil
        }

        let sortOrder = ((try shelves()).map(\.sortOrder).max() ?? -1) + 1
        let shelf = ComicShelf(displayName: name, sortOrder: sortOrder)
        modelContext.insert(
            ComicReaderSchemaV6.StoredComicShelf(
                shelfID: shelf.id.rawValue,
                displayName: shelf.displayName,
                sortOrder: shelf.sortOrder,
                createdAt: shelf.createdAt
            )
        )
        try saveOrRollback()
        return shelf
    }

    func renameShelf(
        _ shelfID: ComicShelfID,
        to rawName: String
    ) throws -> Bool {
        guard let name = ComicShelf.normalizedName(rawName),
              let record = try shelfRecord(for: shelfID) else {
            return false
        }

        record.displayName = name
        try saveOrRollback()
        return true
    }

    func deleteShelf(_ shelfID: ComicShelfID) throws -> Bool {
        guard let record = try shelfRecord(for: shelfID) else {
            return false
        }

        for membership in try modelContext.fetch(
            FetchDescriptor<ComicReaderSchemaV6.StoredComicShelfMembership>()
        ) where membership.shelfID == shelfID.rawValue {
            modelContext.delete(membership)
        }

        modelContext.delete(record)
        try saveOrRollback()
        return true
    }

    func addComic(
        _ comicID: ManagedComicID,
        toShelf shelfID: ComicShelfID
    ) throws -> Bool {
        guard try shelfRecord(for: shelfID) != nil,
              comicExists(comicID),
              try membershipRecord(shelfID: shelfID, comicID: comicID) == nil
        else {
            return false
        }

        modelContext.insert(
            ComicReaderSchemaV6.StoredComicShelfMembership(
                shelfID: shelfID.rawValue,
                comicID: comicID.rawValue,
                addedAt: Date()
            )
        )
        try saveOrRollback()
        return true
    }

    func removeComic(
        _ comicID: ManagedComicID,
        fromShelf shelfID: ComicShelfID
    ) throws -> Bool {
        guard let membership = try membershipRecord(
            shelfID: shelfID,
            comicID: comicID
        ) else {
            return false
        }

        modelContext.delete(membership)
        try saveOrRollback()
        return true
    }

    func comicIDs(inShelf shelfID: ComicShelfID) throws -> [ManagedComicID] {
        try modelContext
            .fetch(
                FetchDescriptor<ComicReaderSchemaV6.StoredComicShelfMembership>()
            )
            .filter { $0.shelfID == shelfID.rawValue }
            .sorted { $0.addedAt < $1.addedAt }
            .map { ManagedComicID(rawValue: $0.comicID) }
    }

    func shelves(containing comicID: ManagedComicID) throws -> [ComicShelf] {
        let memberShelfIDs = Set(
            try modelContext
                .fetch(
                    FetchDescriptor<ComicReaderSchemaV6.StoredComicShelfMembership>()
                )
                .filter { $0.comicID == comicID.rawValue }
                .map(\.shelfID)
        )

        return try shelves().filter {
            memberShelfIDs.contains($0.id.rawValue)
        }
    }

    private func shelfRecord(
        for shelfID: ComicShelfID
    ) throws -> ComicReaderSchemaV6.StoredComicShelf? {
        try modelContext
            .fetch(FetchDescriptor<ComicReaderSchemaV6.StoredComicShelf>())
            .first { $0.shelfID == shelfID.rawValue }
    }

    private func membershipRecord(
        shelfID: ComicShelfID,
        comicID: ManagedComicID
    ) throws -> ComicReaderSchemaV6.StoredComicShelfMembership? {
        let key = shelfID.rawValue.uuidString.lowercased()
            + "|"
            + comicID.rawValue.uuidString.lowercased()
        return try modelContext
            .fetch(
                FetchDescriptor<ComicReaderSchemaV6.StoredComicShelfMembership>()
            )
            .first { $0.membershipKey == key }
    }

    private func comicExists(
        _ comicID: ManagedComicID
    ) throws -> Bool {
        try modelContext
            .fetch(FetchDescriptor<ComicReaderSchemaV6.StoredComic>())
            .contains { $0.comicID == comicID.rawValue }
    }

    private func chapterPageOrderRecord(
        comicID: ManagedComicID,
        chapterID: ImportChapterCandidate.ID
    ) throws -> ComicReaderSchemaV6.StoredChapterPageOrder? {
        try modelContext
            .fetch(
                FetchDescriptor<ComicReaderSchemaV6.StoredChapterPageOrder>()
            )
            .first { record in
                record.comicID == comicID.rawValue
                    && record.chapterID == chapterID.rawValue
            }
    }

    private func globalPreferencesRecord() throws
        -> ComicReaderSchemaV6.StoredReaderGlobalPreferences {
        let recordKey = "reader-global-v1"
        let records = try modelContext.fetch(
            FetchDescriptor<ComicReaderSchemaV6.StoredReaderGlobalPreferences>(
                predicate: #Predicate { record in
                    record.recordKey == recordKey
                }
            )
        )
        let record: ComicReaderSchemaV6.StoredReaderGlobalPreferences
        if let existingRecord = records.first {
            record = existingRecord
        } else {
            record = ComicReaderSchemaV6.StoredReaderGlobalPreferences()
            modelContext.insert(record)
        }

        guard record.legacyProgressPreferencesBackfillVersion < 1 else {
            return record
        }

        let storedComics = try modelContext.fetch(
            FetchDescriptor<ComicReaderSchemaV6.StoredComic>()
        )
        let storedProgress = try modelContext.fetch(
            FetchDescriptor<ComicReaderSchemaV6.StoredReadingProgress>()
        )
        let progressByComicID = firstStoredProgressByComicID(storedProgress)

        for storedComic in storedComics {
            guard let progress = progressByComicID[storedComic.comicID] else {
                continue
            }

            // 旧 schema 无法区分默认值与显式选择；保守固化旧行为，
            // 避免升级后修改全局默认时悄然改变已读漫画的布局。
            if storedComic.readingModeOverrideRawValue == nil,
               ReadingMode(rawValue: progress.readingModeRawValue) != nil {
                storedComic.readingModeOverrideRawValue = (
                    progress.readingModeRawValue
                )
            }

            if storedComic.readingDirectionOverrideRawValue == nil,
               ReadingDirection(rawValue: progress.readingDirectionRawValue) != nil {
                storedComic.readingDirectionOverrideRawValue = (
                    progress.readingDirectionRawValue
                )
            }
        }

        record.legacyProgressPreferencesBackfillVersion = 1
        try saveOrRollback()
        return record
    }

    private func readerGlobalPreferences(
        from record: ComicReaderSchemaV6.StoredReaderGlobalPreferences
    ) -> ReaderGlobalPreferences {
        ReaderGlobalPreferences(
            defaultReadingMode: ReadingMode(
                rawValue: record.defaultReadingModeRawValue
            ) ?? ReaderGlobalPreferences.default.defaultReadingMode,
            defaultReadingDirection: ReadingDirection(
                rawValue: record.defaultReadingDirectionRawValue
            ) ?? ReaderGlobalPreferences.default.defaultReadingDirection,
            tapAreas: ReaderTapAreaPreferences(
                leftAction: ReaderTapZoneAction(
                    rawValue: record.leftTapActionRawValue
                ) ?? ReaderTapAreaPreferences.default.leftAction,
                rightAction: ReaderTapZoneAction(
                    rawValue: record.rightTapActionRawValue
                ) ?? ReaderTapAreaPreferences.default.rightAction
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
        storedComics: [ComicReaderSchemaV6.StoredComic],
        storedProgress: [ComicReaderSchemaV6.StoredReadingProgress],
        globalPreferences: ComicReaderSchemaV6.StoredReaderGlobalPreferences
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
                    readingMode: ReadingMode(
                        rawValue: record.readingModeRawValue
                    ) ?? .continuous,
                    readingDirection: ReadingDirection(
                        rawValue: record.readingDirectionRawValue
                    ) ?? .leftToRight,
                    completedChapterIDs: Set(record.completedChapterIDs),
                    isCompleted: record.isCompleted,
                    updatedAt: record.updatedAt
                )
                return progress.isValid ? progress : nil
            }
            statesByComicID[ManagedComicID(rawValue: rawComicID)] =
                LibraryComicUserState(
                    isFavorite: storedComic.isFavorite,
                    progress: progress,
                    readerOverrides: ComicReaderOverrides(
                        readingMode: ReadingMode(
                            rawValue: storedComic.readingModeOverrideRawValue
                                ?? ""
                        ),
                        readingDirection: ReadingDirection(
                            rawValue: storedComic.readingDirectionOverrideRawValue
                                ?? ""
                        )
                    )
                )
        }

        return LibraryStateStoreSnapshot(
            statesByComicID: statesByComicID,
            indexedComicIDs: Set(statesByComicID.keys),
            globalReaderPreferences: readerGlobalPreferences(
                from: globalPreferences
            )
        )
    }

    private func firstStoredComicsByComicID(
        _ records: [ComicReaderSchemaV6.StoredComic]
    ) -> [UUID: ComicReaderSchemaV6.StoredComic] {
        var recordsByComicID: [UUID: ComicReaderSchemaV6.StoredComic] = [:]
        for record in records where recordsByComicID[record.comicID] == nil {
            recordsByComicID[record.comicID] = record
        }
        return recordsByComicID
    }

    private func firstStoredProgressByComicID(
        _ records: [ComicReaderSchemaV6.StoredReadingProgress]
    ) -> [UUID: ComicReaderSchemaV6.StoredReadingProgress] {
        var recordsByComicID: [
            UUID: ComicReaderSchemaV6.StoredReadingProgress
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
    private(set) var isWriteAvailable = false
    private(set) var statesByComicID: [ManagedComicID: LibraryComicUserState] = [:]
    private(set) var globalReaderPreferences = ReaderGlobalPreferences.default

    @ObservationIgnored private var store: LibraryStateStore?
    @ObservationIgnored private var configuredContainer: ModelContainer?
    @ObservationIgnored private var storeCreationTask: Task<
        LibraryStateStore,
        Never
    >?
    @ObservationIgnored private let prepareStoreCreation: @Sendable (
        ModelContainer
    ) async -> Void
    @ObservationIgnored private var indexedComicIDs = Set<ManagedComicID>()
    @ObservationIgnored private var configurationGeneration = 0

    init(
        prepareStoreCreation: @escaping @Sendable (
            ModelContainer
        ) async -> Void = { _ in }
    ) {
        self.prepareStoreCreation = prepareStoreCreation
    }

    func configure(modelContainer: ModelContainer?) async {
        guard let modelContainer else {
            configurationGeneration += 1
            storeCreationTask?.cancel()
            storeCreationTask = nil
            store = nil
            configuredContainer = nil
            indexedComicIDs = []
            statesByComicID = [:]
            globalReaderPreferences = .default
            isWriteAvailable = false
            status = .unavailable
            return
        }

        if configuredContainer === modelContainer {
            guard let storeCreationTask else {
                return
            }

            let generation = configurationGeneration
            let createdStore = await storeCreationTask.value
            guard generation == configurationGeneration,
                  configuredContainer === modelContainer else {
                return
            }

            store = createdStore
            self.storeCreationTask = nil
            if status == .loading {
                await reload()
            }
            return
        }

        configurationGeneration += 1
        let generation = configurationGeneration
        storeCreationTask?.cancel()
        store = nil
        indexedComicIDs = []
        statesByComicID = [:]
        globalReaderPreferences = .default
        isWriteAvailable = false
        status = .loading
        configuredContainer = modelContainer
        let prepareStoreCreation = self.prepareStoreCreation
        let creationTask = Task.detached(priority: .userInitiated) {
            await prepareStoreCreation(modelContainer)
            return LibraryStateStore(modelContainer: modelContainer)
        }
        storeCreationTask = creationTask
        let createdStore = await creationTask.value
        guard generation == configurationGeneration,
              configuredContainer === modelContainer else {
            return
        }

        store = createdStore
        storeCreationTask = nil
        await reload()
    }

    func reload() async {
        guard let store else {
            if storeCreationTask == nil {
                isWriteAvailable = false
                status = .unavailable
            }
            return
        }

        let generation = configurationGeneration
        status = .loading
        do {
            let snapshot = try await store.snapshot()
            guard generation == configurationGeneration,
                  self.store === store else {
                return
            }

            apply(snapshot)
            isWriteAvailable = true
            status = .ready
        } catch {
            guard generation == configurationGeneration,
                  self.store === store else {
                return
            }

            isWriteAvailable = false
            status = .failed
        }
    }

    func reconcile(catalogItems: [LibraryCatalogItem]) async {
        guard let store else {
            if storeCreationTask == nil {
                isWriteAvailable = false
                status = .unavailable
            }
            return
        }

        let generation = configurationGeneration
        status = .loading
        do {
            let snapshot = try await store.reconcile(
                catalogItems: catalogItems
            )
            guard generation == configurationGeneration,
                  self.store === store else {
                return
            }

            apply(snapshot)
            isWriteAvailable = true
            status = .ready
        } catch {
            guard generation == configurationGeneration,
                  self.store === store else {
                return
            }

            isWriteAvailable = false
            status = .failed
        }
    }

    func state(for comicID: ManagedComicID) -> LibraryComicUserState {
        statesByComicID[comicID] ?? .empty
    }

    func readerOverrides(for comicID: ManagedComicID) -> ComicReaderOverrides {
        state(for: comicID).readerOverrides
    }

    func resolvedReaderPreferences(
        for comicID: ManagedComicID
    ) -> ResolvedReaderPreferences {
        readerOverrides(for: comicID).resolved(using: globalReaderPreferences)
    }

    func canModifyState(for comicID: ManagedComicID) -> Bool {
        status == .ready && indexedComicIDs.contains(comicID)
    }

    func toggleFavorite(for comicID: ManagedComicID) async {
        guard let store else {
            if storeCreationTask == nil {
                isWriteAvailable = false
                status = .unavailable
            }
            return
        }

        let generation = configurationGeneration
        do {
            let snapshot = try await store.toggleFavorite(for: comicID)
            guard generation == configurationGeneration,
                  self.store === store else {
                return
            }

            if let snapshot {
                apply(snapshot)
            }
            isWriteAvailable = true
            status = .ready
        } catch {
            guard generation == configurationGeneration,
                  self.store === store else {
                return
            }

            isWriteAvailable = false
            status = .failed
        }
    }

    /// 把目录条目与用户状态组装成搜索/排序所需的快照。
    func sortableComic(for item: LibraryCatalogItem) -> LibrarySortableComic {
        let state = statesByComicID[item.id] ?? .empty

        return LibrarySortableComic(
            id: item.id,
            displayName: item.record.displayName,
            importedAt: item.record.importedAt,
            isFavorite: state.isFavorite,
            lastReadAt: state.progress?.updatedAt,
            readState: LibraryComicReadState.make(
                hasReadingProgress: state.progress != nil,
                isCompleted: state.progress?.isCompleted ?? false
            )
        )
    }

    /// 返回 `nil` 表示该话没有用户页序覆盖，按自然顺序阅读。
    func chapterPageOrder(
        chapterID: ImportChapterCandidate.ID,
        for comicID: ManagedComicID
    ) async -> ChapterPageOrder? {
        guard let store else {
            if storeCreationTask == nil {
                isWriteAvailable = false
                status = .unavailable
            }
            return nil
        }

        do {
            return try await store.chapterPageOrder(
                chapterID: chapterID,
                for: comicID
            )
        } catch {
            return nil
        }
    }

    func shelves() async -> [ComicShelf] {
        guard let store else {
            return []
        }

        do {
            return try await store.shelves()
        } catch {
            return []
        }
    }

    func createShelf(named rawName: String) async -> ComicShelf? {
        guard let store else {
            return nil
        }

        do {
            return try await store.createShelf(named: rawName)
        } catch {
            return nil
        }
    }

    @discardableResult
    func renameShelf(
        _ shelfID: ComicShelfID,
        to rawName: String
    ) async -> Bool {
        guard let store else {
            return false
        }

        do {
            return try await store.renameShelf(shelfID, to: rawName)
        } catch {
            return false
        }
    }

    @discardableResult
    func deleteShelf(_ shelfID: ComicShelfID) async -> Bool {
        guard let store else {
            return false
        }

        do {
            return try await store.deleteShelf(shelfID)
        } catch {
            return false
        }
    }

    @discardableResult
    func addComic(
        _ comicID: ManagedComicID,
        toShelf shelfID: ComicShelfID
    ) async -> Bool {
        guard let store else {
            return false
        }

        do {
            return try await store.addComic(comicID, toShelf: shelfID)
        } catch {
            return false
        }
    }

    @discardableResult
    func removeComic(
        _ comicID: ManagedComicID,
        fromShelf shelfID: ComicShelfID
    ) async -> Bool {
        guard let store else {
            return false
        }

        do {
            return try await store.removeComic(comicID, fromShelf: shelfID)
        } catch {
            return false
        }
    }

    func comicIDs(inShelf shelfID: ComicShelfID) async -> [ManagedComicID] {
        guard let store else {
            return []
        }

        do {
            return try await store.comicIDs(inShelf: shelfID)
        } catch {
            return []
        }
    }

    func shelves(containing comicID: ManagedComicID) async -> [ComicShelf] {
        guard let store else {
            return []
        }

        do {
            return try await store.shelves(containing: comicID)
        } catch {
            return []
        }
    }

    @discardableResult
    func setChapterPageOrder(
        _ order: ChapterPageOrder,
        for comicID: ManagedComicID
    ) async -> Bool {
        guard let store else {
            if storeCreationTask == nil {
                isWriteAvailable = false
                status = .unavailable
            }
            return false
        }

        let generation = configurationGeneration
        do {
            let didSave = try await store.setChapterPageOrder(
                order,
                for: comicID
            )
            guard generation == configurationGeneration,
                  self.store === store else {
                return false
            }

            if didSave {
                isWriteAvailable = true
                status = .ready
            }
            return didSave
        } catch {
            guard generation == configurationGeneration,
                  self.store === store else {
                return false
            }

            isWriteAvailable = false
            status = .failed
            return false
        }
    }

    @discardableResult
    func clearChapterPageOrder(
        chapterID: ImportChapterCandidate.ID,
        for comicID: ManagedComicID
    ) async -> Bool {
        guard let store else {
            if storeCreationTask == nil {
                isWriteAvailable = false
                status = .unavailable
            }
            return false
        }

        let generation = configurationGeneration
        do {
            let didClear = try await store.clearChapterPageOrder(
                chapterID: chapterID,
                for: comicID
            )
            guard generation == configurationGeneration,
                  self.store === store else {
                return false
            }

            if didClear {
                isWriteAvailable = true
                status = .ready
            }
            return didClear
        } catch {
            guard generation == configurationGeneration,
                  self.store === store else {
                return false
            }

            isWriteAvailable = false
            status = .failed
            return false
        }
    }

    /// 阅读器加载内容时一次性取回该漫画全部话的用户页序。
    func pageOrderOverridesForReader(
        comicID: ManagedComicID
    ) async -> [ImportChapterCandidate.ID: [ImportPageCandidate.ID]] {
        guard let store else {
            if storeCreationTask == nil {
                isWriteAvailable = false
                status = .unavailable
            }
            return [:]
        }

        do {
            return try await store.chapterPageOrders(for: comicID)
        } catch {
            return [:]
        }
    }

    @discardableResult
    func setDefaultReadingMode(_ readingMode: ReadingMode) async -> Bool {
        guard let store else {
            if storeCreationTask == nil {
                isWriteAvailable = false
                status = .unavailable
            }
            return false
        }

        let generation = configurationGeneration
        do {
            let snapshot = try await store.setDefaultReadingMode(readingMode)
            guard generation == configurationGeneration,
                  self.store === store else {
                return false
            }

            apply(snapshot)
            isWriteAvailable = true
            status = .ready
            return true
        } catch {
            guard generation == configurationGeneration,
                  self.store === store else {
                return false
            }

            isWriteAvailable = false
            status = .failed
            return false
        }
    }

    @discardableResult
    func setDefaultReadingDirection(
        _ readingDirection: ReadingDirection
    ) async -> Bool {
        guard let store else {
            if storeCreationTask == nil {
                isWriteAvailable = false
                status = .unavailable
            }
            return false
        }

        let generation = configurationGeneration
        do {
            let snapshot = try await store.setDefaultReadingDirection(
                readingDirection
            )
            guard generation == configurationGeneration,
                  self.store === store else {
                return false
            }

            apply(snapshot)
            isWriteAvailable = true
            status = .ready
            return true
        } catch {
            guard generation == configurationGeneration,
                  self.store === store else {
                return false
            }

            isWriteAvailable = false
            status = .failed
            return false
        }
    }

    @discardableResult
    func setTapZoneAction(
        _ action: ReaderTapZoneAction,
        isLeftZone: Bool
    ) async -> Bool {
        guard let store else {
            if storeCreationTask == nil {
                isWriteAvailable = false
                status = .unavailable
            }
            return false
        }

        let generation = configurationGeneration
        do {
            let snapshot = try await store.setTapZoneAction(
                action,
                isLeftZone: isLeftZone
            )
            guard generation == configurationGeneration,
                  self.store === store else {
                return false
            }

            apply(snapshot)
            isWriteAvailable = true
            status = .ready
            return true
        } catch {
            guard generation == configurationGeneration,
                  self.store === store else {
                return false
            }

            isWriteAvailable = false
            status = .failed
            return false
        }
    }

    @discardableResult
    func setReadingModeOverride(
        _ readingMode: ReadingMode?,
        for comicID: ManagedComicID
    ) async -> Bool {
        guard let store else {
            if storeCreationTask == nil {
                isWriteAvailable = false
                status = .unavailable
            }
            return false
        }

        let generation = configurationGeneration
        do {
            let snapshot = try await store.setReadingModeOverride(
                readingMode,
                for: comicID
            )
            guard generation == configurationGeneration,
                  self.store === store else {
                return false
            }

            guard let snapshot else {
                isWriteAvailable = true
                status = .ready
                return false
            }

            apply(snapshot)
            isWriteAvailable = true
            status = .ready
            return true
        } catch {
            guard generation == configurationGeneration,
                  self.store === store else {
                return false
            }

            isWriteAvailable = false
            status = .failed
            return false
        }
    }

    @discardableResult
    func setReadingDirectionOverride(
        _ readingDirection: ReadingDirection?,
        for comicID: ManagedComicID
    ) async -> Bool {
        guard let store else {
            if storeCreationTask == nil {
                isWriteAvailable = false
                status = .unavailable
            }
            return false
        }

        let generation = configurationGeneration
        do {
            let snapshot = try await store.setReadingDirectionOverride(
                readingDirection,
                for: comicID
            )
            guard generation == configurationGeneration,
                  self.store === store else {
                return false
            }

            guard let snapshot else {
                isWriteAvailable = true
                status = .ready
                return false
            }

            apply(snapshot)
            isWriteAvailable = true
            status = .ready
            return true
        } catch {
            guard generation == configurationGeneration,
                  self.store === store else {
                return false
            }

            isWriteAvailable = false
            status = .failed
            return false
        }
    }

    @discardableResult
    func recordProgress(
        _ progress: LibraryReadingProgress,
        for comicID: ManagedComicID
    ) async -> Bool {
        guard progress.isValid, let store else {
            if store == nil, storeCreationTask == nil {
                isWriteAvailable = false
                status = .unavailable
            }
            return false
        }

        let generation = configurationGeneration
        do {
            let result = try await store.recordProgress(
                progress,
                for: comicID
            )
            guard generation == configurationGeneration,
                  self.store === store else {
                return false
            }
            isWriteAvailable = true

            switch result {
            case .missingComic:
                status = .ready
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
            guard generation == configurationGeneration,
                  self.store === store else {
                return false
            }

            isWriteAvailable = false
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
        globalReaderPreferences = snapshot.globalReaderPreferences
    }
}
