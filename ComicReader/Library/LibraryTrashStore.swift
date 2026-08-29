import Foundation

enum LibraryTrashStoreError: Error, Equatable, Sendable {
    case comicNotFound
    case trashMarkerInvalid
}

/// 回收站的文件级存储：标记、列举与永久删除都在后台执行器
/// 上完成，避免阻塞主线程。永久删除只移除 App 管理目录内的
/// 副本（漫画目录与缩略图），不触碰任何来源目录。
actor FileSystemLibraryTrashStore {
    private let layout: ImportStorageLayout

    init(layout: ImportStorageLayout) {
        self.layout = layout
    }

    func hasMarker(for comicID: ManagedComicID) -> Bool {
        FileManager.default.fileExists(
            atPath: layout.trashMarkerURL(for: comicID).path
        )
    }

    /// 软删除一部漫画。重复标记保留最早的删除时间。
    func markTrashed(
        comicID: ManagedComicID,
        now: Date = Date()
    ) throws -> LibraryTrashedComic {
        let comicRootURL = layout.libraryURL(for: comicID)
        guard FileManager.default.fileExists(atPath: comicRootURL.path)
        else {
            throw LibraryTrashStoreError.comicNotFound
        }

        let markerURL = layout.trashMarkerURL(for: comicID)
        let trashedAt: Date
        if let data = try? Data(contentsOf: markerURL),
           let existing = try? JSONDecoder().decode(
                LibraryTrashMarker.self,
                from: data
            ),
           existing.schemaVersion == LibraryTrashMarker.currentSchemaVersion,
           existing.comicID == comicID {
            trashedAt = existing.trashedAt
        } else {
            trashedAt = now
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        try FileManager.default.createDirectory(
            at: markerURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try encoder
            .encode(LibraryTrashMarker(comicID: comicID, trashedAt: trashedAt))
            .write(to: markerURL, options: .atomic)

        return LibraryTrashedComic(
            id: comicID,
            displayName: displayName(for: comicID),
            trashedAt: trashedAt
        )
    }

    /// 恢复漫画；没有标记时返回 `false`。
    func restore(comicID: ManagedComicID) -> Bool {
        let markerURL = layout.trashMarkerURL(for: comicID)
        guard FileManager.default.fileExists(atPath: markerURL.path) else {
            return false
        }

        return (try? FileManager.default.removeItem(at: markerURL)) != nil
    }

    /// 列举回收站中的漫画；损坏的标记按无标记处理并跳过。
    func trashedComics() -> [LibraryTrashedComic] {
        let fileManager = FileManager.default
        let libraryURL = layout.libraryURL

        guard let directories = try? fileManager.contentsOfDirectory(
            at: libraryURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var result: [LibraryTrashedComic] = []
        for directoryURL in directories {
            guard let comicID = managedComicID(for: directoryURL),
                  hasMarker(for: comicID) else {
                continue
            }

            result.append(
                LibraryTrashedComic(
                    id: comicID,
                    displayName: displayName(for: comicID),
                    trashedAt: trashedAt(for: comicID)
                )
            )
        }

        return result.sorted { lhs, rhs in
            if lhs.trashedAt != rhs.trashedAt {
                return lhs.trashedAt > rhs.trashedAt
            }

            return lhs.displayName.localizedStandardCompare(rhs.displayName)
                == .orderedAscending
        }
    }

    /// 永久删除：移除漫画目录与缩略图；返回是否确实删除了内容。
    func purge(comicID: ManagedComicID) -> Bool {
        let fileManager = FileManager.default
        let comicRootURL = layout.libraryURL(for: comicID)
        let thumbnailURL = layout.thumbnailURL(for: comicID)

        let comicExisted = fileManager.fileExists(atPath: comicRootURL.path)
        let thumbnailExisted = fileManager.fileExists(
            atPath: thumbnailURL.path
        )
        guard comicExisted || thumbnailExisted else {
            return false
        }

        try? fileManager.removeItem(at: comicRootURL)
        try? fileManager.removeItem(at: thumbnailURL)
        return true
    }

    private func managedComicID(for directoryURL: URL) -> ManagedComicID? {
        guard let values = try? directoryURL.resourceValues(
            forKeys: [.isDirectoryKey]
        ), values.isDirectory == true,
           let rawValue = UUID(uuidString: directoryURL.lastPathComponent),
           directoryURL.lastPathComponent.lowercased()
               == rawValue.uuidString.lowercased() else {
            return nil
        }

        return ManagedComicID(rawValue: rawValue)
    }

    private func trashedAt(for comicID: ManagedComicID) -> Date {
        guard let data = try? Data(
            contentsOf: layout.trashMarkerURL(for: comicID)
        ), let marker = try? JSONDecoder().decode(
            LibraryTrashMarker.self,
            from: data
        ), marker.schemaVersion == LibraryTrashMarker.currentSchemaVersion
        else {
            return .distantPast
        }

        return marker.trashedAt
    }

    private func displayName(for comicID: ManagedComicID) -> String {
        let metadataURL = layout.libraryMetadataURL(for: comicID)
        for fileName in ["library-catalog.json", "import-descriptor.json"] {
            let url = metadataURL.appendingPathComponent(fileName)
            if let data = try? Data(contentsOf: url),
               let record = try? JSONDecoder().decode(
                    TrashedComicNameProbe.self,
                    from: data
                ),
               !record.displayName.isEmpty {
                return record.displayName
            }
        }

        return comicID.rawValue.uuidString
    }
}

private struct TrashedComicNameProbe: Decodable {
    let displayName: String
}
