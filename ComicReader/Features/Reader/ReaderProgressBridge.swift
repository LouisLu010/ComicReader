import Foundation

enum ReaderProgressBridge {
    static func readingPosition(
        from libraryProgress: LibraryReadingProgress?
    ) -> ReadingPosition? {
        guard let libraryProgress else {
            return nil
        }

        return ReadingPosition(
            storageChapterID: libraryProgress.chapterID,
            pageID: libraryProgress.pageID,
            pageOffset: libraryProgress.pageOffset,
            zoomScale: libraryProgress.zoomScale
        )
    }

    static func completedChapterIDs(
        from libraryProgress: LibraryReadingProgress?
    ) -> Set<ImportChapterCandidate.ID> {
        guard let libraryProgress else {
            return []
        }

        return Set(
            libraryProgress.completedChapterIDs.map {
                ImportChapterCandidate.ID(rawValue: $0)
            }
        )
    }

    static func libraryProgress(
        from readerProgress: ReaderProgress,
        preservedComicCompletion: Bool,
        updatedAt: Date = Date()
    ) -> LibraryReadingProgress {
        LibraryReadingProgress(
            chapterID: readerProgress.position.storageChapterID,
            pageID: readerProgress.position.pageID.rawValue,
            pageOffset: readerProgress.position.pageOffset,
            zoomScale: readerProgress.position.zoomScale,
            readingMode: readerProgress.mode,
            readingDirection: readerProgress.direction,
            completedChapterIDs: Set(
                readerProgress.completedChapterIDs.map(\.rawValue)
            ),
            isCompleted: preservedComicCompletion
                || readerProgress.hasReachedFinalChapterEnd,
            updatedAt: updatedAt
        )
    }
}
