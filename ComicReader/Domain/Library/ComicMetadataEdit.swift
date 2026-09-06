import Foundation

/// 用户补充的漫画信息，与来源名称和页面身份独立。
/// 空字符串或空标签集合表示用户清空该项，而非保留原值。
struct ComicMetadata: Codable, Equatable, Sendable {
    let author: String
    let summary: String
    let tags: [String]

    init(author: String = "", summary: String = "", tags: [String] = []) {
        self.author = author.trimmingCharacters(in: .whitespacesAndNewlines)
        self.summary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        var seen = Set<String>()
        self.tags = tags.compactMap { rawTag in
            let tag = rawTag.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = tag.folding(
                options: [.caseInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
            return !tag.isEmpty && seen.insert(key).inserted ? tag : nil
        }
    }
}

/// 元数据编辑的校验与应用：显示名去除首尾空白后不得为空；
/// 自定义封面页必须是库内已存在且可读的页面。应用编辑会重
/// 新计算描述符修订号，并同步工作项的封面标记。
enum ComicMetadataEditPolicy {
    static func tags(from rawText: String) -> [String] {
        rawText.components(separatedBy: CharacterSet(charactersIn: ",，、;；\n\r"))
    }

    static func validatedDisplayName(_ rawName: String) -> String? {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    static func isSelectableCoverPage(
        _ pageID: ImportPageCandidate.ID,
        in descriptor: ManagedComicDescriptor
    ) -> Bool {
        guard let workItem = descriptor.workItems.first(where: {
            $0.id == pageID
        }) else {
            return false
        }

        return workItem.pageState == .readable
    }

    static func applying(
        displayName: String? = nil,
        coverPageID: ImportPageCandidate.ID? = nil,
        metadata: ComicMetadata? = nil,
        to descriptor: ManagedComicDescriptor
    ) -> ManagedComicDescriptor {
        let newDisplayName = displayName ?? descriptor.displayName
        let newCoverPageID = coverPageID ?? descriptor.coverPageID
        let workItems = descriptor.workItems.map { workItem in
            FrozenImportWorkItem(
                id: workItem.id,
                sourceRelativePath: workItem.sourceRelativePath,
                managedRelativePath: workItem.managedRelativePath,
                originalFileName: workItem.originalFileName,
                detectedFormat: workItem.detectedFormat,
                expectedByteCount: workItem.expectedByteCount,
                expectedLightweightFingerprint: workItem
                    .expectedLightweightFingerprint,
                pixelSize: workItem.pixelSize,
                orientation: workItem.orientation,
                pageState: workItem.pageState,
                isCover: workItem.id == newCoverPageID
            )
        }

        return descriptor.with(
            displayName: newDisplayName,
            workItems: workItems,
            coverPageID: newCoverPageID,
            metadata: metadata
        )
    }
}
