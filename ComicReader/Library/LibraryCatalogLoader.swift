import Foundation

protocol LibraryCatalogLoading: Sendable {
    func loadCatalog() async throws -> LibraryCatalogLoadResult
}

struct LibraryCatalogLoadResult: Equatable, Sendable {
    let comics: [LibraryCatalogItem]
    let ignoredEntryCount: Int
}

struct LibraryCatalogItem: Equatable, Identifiable, Sendable {
    let record: LibraryCatalogRecord
    let thumbnailAvailable: Bool

    var id: ManagedComicID {
        record.id
    }
}

enum LibraryCatalogLoaderError: Error, Equatable, Sendable {
    case storageUnavailable
}

actor FileSystemLibraryCatalogLoader: LibraryCatalogLoading {
    private let layout: ImportStorageLayout

    init(layout: ImportStorageLayout) {
        self.layout = layout
    }

    func loadCatalog() async throws -> LibraryCatalogLoadResult {
        let fileManager = FileManager.default
        let libraryURL = layout.libraryURL

        guard fileManager.fileExists(atPath: libraryURL.path) else {
            return LibraryCatalogLoadResult(comics: [], ignoredEntryCount: 0)
        }

        let directories: [URL]
        do {
            directories = try fileManager.contentsOfDirectory(
                at: libraryURL,
                includingPropertiesForKeys: [
                    .isDirectoryKey,
                    .isSymbolicLinkKey,
                ],
                options: [.skipsHiddenFiles]
            )
        } catch {
            throw LibraryCatalogLoaderError.storageUnavailable
        }

        var comics: [LibraryCatalogItem] = []
        var ignoredEntryCount = 0

        for directoryURL in directories {
            guard let comicID = managedComicID(for: directoryURL) else {
                continue
            }

            // 回收站中的漫画不进入书库，也不计入忽略项。
            let trashMarkerURL = directoryURL
                .appendingPathComponent("metadata", isDirectory: true)
                .appendingPathComponent("trashed.json")
            if fileManager.fileExists(atPath: trashMarkerURL.path) {
                continue
            }

            guard let record = loadRecord(
                for: comicID,
                in: directoryURL,
                fileManager: fileManager
            ) else {
                ignoredEntryCount += 1
                continue
            }

            comics.append(
                LibraryCatalogItem(
                    record: record,
                    thumbnailAvailable: isThumbnailAvailable(
                        for: comicID,
                        fileManager: fileManager
                    )
                )
            )
        }

        return LibraryCatalogLoadResult(
            comics: comics.sorted(by: catalogOrder),
            ignoredEntryCount: ignoredEntryCount
        )
    }

    private func managedComicID(for directoryURL: URL) -> ManagedComicID? {
        guard let values = try? directoryURL.resourceValues(
            forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        ), values.isDirectory == true,
           values.isSymbolicLink != true,
           let rawValue = UUID(uuidString: directoryURL.lastPathComponent),
           directoryURL.lastPathComponent.lowercased()
               == rawValue.uuidString.lowercased() else {
            return nil
        }

        return ManagedComicID(rawValue: rawValue)
    }

    private func loadRecord(
        for comicID: ManagedComicID,
        in directoryURL: URL,
        fileManager: FileManager
    ) -> LibraryCatalogRecord? {
        let metadataURL = directoryURL.appendingPathComponent(
            "metadata",
            isDirectory: true
        )
        let catalogURL = metadataURL.appendingPathComponent("library-catalog.json")

        if let record = decode(
            LibraryCatalogRecord.self,
            at: catalogURL,
            fileManager: fileManager
        ), record.id == comicID, record.isValid {
            return record
        }

        let descriptorURL = metadataURL.appendingPathComponent(
            "import-descriptor.json"
        )
        guard let descriptor = decode(
            ManagedComicDescriptor.self,
            at: descriptorURL,
            fileManager: fileManager
        ), descriptor.schemaVersion == ManagedComicDescriptor.currentSchemaVersion,
           descriptor.targetComicID == comicID else {
            return nil
        }

        let resourceValues = try? directoryURL.resourceValues(
            forKeys: [.contentModificationDateKey]
        )
        let importedAt = resourceValues?.contentModificationDate ?? .distantPast
        let record = LibraryCatalogRecord(
            descriptor: descriptor,
            importedAt: importedAt
        )
        guard record.isValid else {
            return nil
        }

        try? write(record, to: catalogURL, fileManager: fileManager)
        return record
    }

    private func decode<Value: Decodable>(
        _ type: Value.Type,
        at url: URL,
        fileManager: FileManager
    ) -> Value? {
        guard fileManager.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url) else {
            return nil
        }

        return try? JSONDecoder().decode(type, from: data)
    }

    private func write<Value: Encodable>(
        _ value: Value,
        to url: URL,
        fileManager: FileManager
    ) throws {
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(value).write(to: url, options: .atomic)
    }

    private func isThumbnailAvailable(
        for comicID: ManagedComicID,
        fileManager: FileManager
    ) -> Bool {
        let thumbnailURL = layout.thumbnailURL(for: comicID)
        guard let values = try? thumbnailURL.resourceValues(
            forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
        ) else {
            return false
        }

        return values.isRegularFile == true && values.isSymbolicLink != true
    }

    private func catalogOrder(
        _ lhs: LibraryCatalogItem,
        _ rhs: LibraryCatalogItem
    ) -> Bool {
        if lhs.record.importedAt != rhs.record.importedAt {
            return lhs.record.importedAt > rhs.record.importedAt
        }

        let comparison = lhs.record.displayName.localizedStandardCompare(
            rhs.record.displayName
        )
        if comparison != .orderedSame {
            return comparison == .orderedAscending
        }

        return lhs.id.rawValue.uuidString < rhs.id.rawValue.uuidString
    }
}
