import Foundation
import SwiftData

enum ComicReaderSchemaV2: VersionedSchema {
    static var versionIdentifier: Schema.Version {
        Schema.Version(2, 0, 0)
    }

    static var models: [any PersistentModel.Type] {
        [StoredComic.self, StoredReadingProgress.self]
    }

    @Model
    final class StoredComic {
        @Attribute(.unique) var comicID: UUID
        var displayName: String
        var sourceRootName: String
        var importedAt: Date
        var chapterCount: Int
        var pageCount: Int
        var isFavorite: Bool

        init(
            comicID: UUID,
            displayName: String,
            sourceRootName: String,
            importedAt: Date,
            chapterCount: Int,
            pageCount: Int,
            isFavorite: Bool = false
        ) {
            self.comicID = comicID
            self.displayName = displayName
            self.sourceRootName = sourceRootName
            self.importedAt = importedAt
            self.chapterCount = max(0, chapterCount)
            self.pageCount = max(0, pageCount)
            self.isFavorite = isFavorite
        }
    }

    @Model
    final class StoredReadingProgress {
        @Attribute(.unique) var comicID: UUID
        var chapterID: String
        var pageID: String
        var pageOffset: Double
        var zoomScale: Double
        var readingModeRawValue: String = "continuous"
        var readingDirectionRawValue: String = "leftToRight"
        var isCompleted: Bool
        var updatedAt: Date

        init(
            comicID: UUID,
            chapterID: String,
            pageID: String,
            pageOffset: Double,
            zoomScale: Double,
            readingModeRawValue: String = "continuous",
            readingDirectionRawValue: String = "leftToRight",
            isCompleted: Bool,
            updatedAt: Date
        ) {
            self.comicID = comicID
            self.chapterID = chapterID
            self.pageID = pageID
            self.pageOffset = pageOffset.isFinite
                ? min(max(pageOffset, 0), 1)
                : 0
            self.zoomScale = zoomScale.isFinite
                ? min(max(zoomScale, 0.1), 16)
                : 1
            self.readingModeRawValue = readingModeRawValue
            self.readingDirectionRawValue = readingDirectionRawValue
            self.isCompleted = isCompleted
            self.updatedAt = updatedAt
        }
    }
}
