import Foundation

enum ComicMetadataEditorError: Error, Equatable, Sendable {
    case comicNotFound
    case descriptorUnreadable
    case invalidDisplayName
    case invalidCoverPage
}

/// 元数据编辑服务：读取描述符、应用校验后的编辑、原子写回
/// 描述符与书库目录记录，并在封面变化时刷新缩略图。
actor FileSystemComicMetadataEditor {
    private let layout: ImportStorageLayout
    private let thumbnailGenerator: any ImportThumbnailGenerating

    init(
        layout: ImportStorageLayout,
        thumbnailGenerator: any ImportThumbnailGenerating =
            ImageIOImportThumbnailGenerator()
    ) {
        self.layout = layout
        self.thumbnailGenerator = thumbnailGenerator
    }

    func loadDescriptor(
        comicID: ManagedComicID
    ) throws -> ManagedComicDescriptor {
        let comicRootURL = layout.libraryURL(for: comicID)
        guard FileManager.default.fileExists(atPath: comicRootURL.path) else {
            throw ComicMetadataEditorError.comicNotFound
        }

        return try Self.decodeDescriptor(comicID: comicID, layout: layout)
    }

    /// 应用一次编辑（`nil` 表示对应字段不变），返回更新后的描述符。
    func apply(
        comicID: ManagedComicID,
        displayName: String? = nil,
        coverPageID: ImportPageCandidate.ID? = nil
    ) async throws -> ManagedComicDescriptor {
        let descriptor = try loadDescriptor(comicID: comicID)

        let validatedDisplayName: String?
        if let displayName {
            guard let name = ComicMetadataEditPolicy.validatedDisplayName(
                displayName
            ) else {
                throw ComicMetadataEditorError.invalidDisplayName
            }
            validatedDisplayName = name
        } else {
            validatedDisplayName = nil
        }

        if let coverPageID,
           !ComicMetadataEditPolicy.isSelectableCoverPage(
               coverPageID,
               in: descriptor
           ) {
            throw ComicMetadataEditorError.invalidCoverPage
        }

        let updatedDescriptor = ComicMetadataEditPolicy.applying(
            displayName: validatedDisplayName,
            coverPageID: coverPageID,
            to: descriptor
        )

        try Self.writeDescriptor(updatedDescriptor, layout: layout)
        try Self.writeCatalogRecord(updatedDescriptor, layout: layout)

        if descriptor.coverPageID != updatedDescriptor.coverPageID,
           let coverWorkItem = updatedDescriptor.workItems.first(where: {
               $0.id == updatedDescriptor.coverPageID
           }) {
            _ = try? await thumbnailGenerator.generate(
                from: Self.fileURL(
                    rootURL: layout.libraryURL(for: comicID),
                    components: coverWorkItem.managedRelativePath.components
                ),
                to: layout.thumbnailURL(for: comicID)
            )
        }

        return updatedDescriptor
    }

    static func decodeDescriptor(
        comicID: ManagedComicID,
        layout: ImportStorageLayout
    ) throws -> ManagedComicDescriptor {
        let descriptorURL = layout.libraryMetadataURL(for: comicID)
            .appendingPathComponent("import-descriptor.json")

        guard FileManager.default.fileExists(atPath: descriptorURL.path),
              let data = try? Data(contentsOf: descriptorURL),
              let descriptor = try? JSONDecoder().decode(
                ManagedComicDescriptor.self,
                from: data
              ),
              descriptor.schemaVersion
                  == ManagedComicDescriptor.currentSchemaVersion,
              descriptor.targetComicID == comicID else {
            throw ComicMetadataEditorError.descriptorUnreadable
        }

        return descriptor
    }

    private static func writeDescriptor(
        _ descriptor: ManagedComicDescriptor,
        layout: ImportStorageLayout
    ) throws {
        let metadataURL = layout.libraryMetadataURL(for: descriptor.targetComicID)
        try FileManager.default.createDirectory(
            at: metadataURL,
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(descriptor)
        try data.write(
            to: metadataURL.appendingPathComponent("import-descriptor.json"),
            options: .atomic
        )
    }

    private static func writeCatalogRecord(
        _ descriptor: ManagedComicDescriptor,
        layout: ImportStorageLayout
    ) throws {
        let catalogURL = layout.libraryCatalogURL(for: descriptor.targetComicID)
        let previousImportedAt = (try? JSONDecoder().decode(
            LibraryCatalogRecord.self,
            from: Data(contentsOf: catalogURL)
        ))?.importedAt
        let record = LibraryCatalogRecord(
            descriptor: descriptor,
            importedAt: previousImportedAt ?? Date()
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(record)
        try data.write(to: catalogURL, options: .atomic)
    }

    private static func fileURL(
        rootURL: URL,
        components: [String]
    ) -> URL {
        components.reduce(rootURL) { currentURL, component in
            currentURL.appendingPathComponent(component)
        }
    }
}
