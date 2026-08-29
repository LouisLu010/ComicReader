import Foundation
import SwiftData

enum ComicReaderSchemaV5: VersionedSchema {
    static var versionIdentifier: Schema.Version {
        Schema.Version(5, 0, 0)
    }

    static var models: [any PersistentModel.Type] {
        [
            StoredComic.self,
            StoredReadingProgress.self,
            StoredReaderGlobalPreferences.self,
            StoredChapterPageOrder.self,
        ]
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
        var readingModeOverrideRawValue: String?
        var readingDirectionOverrideRawValue: String?

        init(
            comicID: UUID,
            displayName: String,
            sourceRootName: String,
            importedAt: Date,
            chapterCount: Int,
            pageCount: Int,
            isFavorite: Bool = false,
            readingModeOverrideRawValue: String? = nil,
            readingDirectionOverrideRawValue: String? = nil
        ) {
            self.comicID = comicID
            self.displayName = displayName
            self.sourceRootName = sourceRootName
            self.importedAt = importedAt
            self.chapterCount = max(0, chapterCount)
            self.pageCount = max(0, pageCount)
            self.isFavorite = isFavorite
            self.readingModeOverrideRawValue = readingModeOverrideRawValue
            self.readingDirectionOverrideRawValue = (
                readingDirectionOverrideRawValue
            )
        }
    }

    @Model
    final class StoredReadingProgress {
        @Attribute(.unique) var comicID: UUID
        var chapterID: String
        var pageID: String
        var pageOffset: Double
        var zoomScale: Double
        // 保留用于兼容 V1–V3 的进度记录；阅读偏好由独立覆盖模型决定。
        var readingModeRawValue: String = "continuous"
        var readingDirectionRawValue: String = "leftToRight"
        var completedChapterIDs: [String] = []
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
            completedChapterIDs: [String] = [],
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
            self.completedChapterIDs = Array(Set(completedChapterIDs)).sorted()
            self.isCompleted = isCompleted
            self.updatedAt = updatedAt
        }
    }

    @Model
    final class StoredReaderGlobalPreferences {
        @Attribute(.unique) var recordKey: String
        var defaultReadingModeRawValue: String = "continuous"
        var defaultReadingDirectionRawValue: String = "leftToRight"
        var leftTapActionRawValue: String = "automatic"
        var rightTapActionRawValue: String = "automatic"
        var legacyProgressPreferencesBackfillVersion: Int = 0

        init(
            recordKey: String = "reader-global-v1",
            defaultReadingModeRawValue: String = "continuous",
            defaultReadingDirectionRawValue: String = "leftToRight",
            leftTapActionRawValue: String = "automatic",
            rightTapActionRawValue: String = "automatic",
            legacyProgressPreferencesBackfillVersion: Int = 0
        ) {
            self.recordKey = recordKey
            self.defaultReadingModeRawValue = defaultReadingModeRawValue
            self.defaultReadingDirectionRawValue = (
                defaultReadingDirectionRawValue
            )
            self.leftTapActionRawValue = leftTapActionRawValue
            self.rightTapActionRawValue = rightTapActionRawValue
            self.legacyProgressPreferencesBackfillVersion = (
                legacyProgressPreferencesBackfillVersion
            )
        }
    }

    @Model
    final class StoredChapterPageOrder {
        @Attribute(.unique) var orderKey: String
        var comicID: UUID
        var chapterID: String
        var orderedPageIDs: [String]
        var updatedAt: Date

        init(
            comicID: UUID,
            chapterID: String,
            orderedPageIDs: [String],
            updatedAt: Date
        ) {
            // 单一唯一键规避复合唯一约束；键稳定即可按漫画和话覆盖。
            orderKey = comicID.uuidString.lowercased() + "|" + chapterID
            self.comicID = comicID
            self.chapterID = chapterID
            self.orderedPageIDs = orderedPageIDs
            self.updatedAt = updatedAt
        }
    }
}
