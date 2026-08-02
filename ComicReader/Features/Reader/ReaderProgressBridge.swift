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
            isCompleted: preservedComicCompletion
                || readerProgress.hasReachedFinalChapterEnd,
            updatedAt: updatedAt
        )
    }
}
