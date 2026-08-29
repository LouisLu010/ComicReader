import Foundation

enum ComicUpdateExecutionError: Error, Equatable, Sendable {
    /// 更新与漫画或授权记录不匹配。
    case authorizationInvalid
    /// 书签已过期，需要来源重授权。
    case staleAuthorization
    case accessDenied
    /// 来源内容与预览时扫描结果不一致。
    case sourceChanged
    /// 来源暂时不可读（云盘未下载、权限被收回等）。
    case sourceUnavailable
    case copyFailed
}

struct ManagedComicUpdateResult: Equatable, Sendable {
    let descriptor: ManagedComicDescriptor
    let catalogRecord: LibraryCatalogRecord
}

/// 安全应用一次冻结的漫画更新：先把全部新页复制进暂存区并
/// 逐项校验（字节数、内容摘要、可读性），全部成功后才把文件
/// 放入资料库、原子写入新描述符，最后由调用方异步清理被取代
/// 的旧文件。任何失败都保持已入库漫画原样可用。
actor ComicUpdateExecutor {
    private let sourceAccess: any ImportSourceAccessing
    private let fileCopier: ImportFileCopier
    private let thumbnailGenerator: any ImportThumbnailGenerating
    private let layout: ImportStorageLayout

    init(
        layout: ImportStorageLayout,
        sourceAccess: any ImportSourceAccessing = SecurityScopedSourceAccess(),
        thumbnailGenerator: any ImportThumbnailGenerating =
            ImageIOImportThumbnailGenerator()
    ) {
        self.layout = layout
        self.sourceAccess = sourceAccess
        self.fileCopier = ImportFileCopier()
        self.thumbnailGenerator = thumbnailGenerator
    }

    func apply(
        descriptor: ManagedComicDescriptor,
        update: FrozenComicUpdate,
        authorization: ComicSourceAuthorization
    ) async throws -> ManagedComicUpdateResult {
        guard descriptor.targetComicID == authorization.comicID else {
            throw ComicUpdateExecutionError.authorizationInvalid
        }

        let sourceRootURL: URL
        do {
            sourceRootURL = try sourceAccess.resolveBookmark(
                authorization.bookmark
            )
        } catch let error as ImportSourceAccessError {
            throw Self.executionError(for: error)
        }

        let cancellationToken = ImportCancellationToken()
        let stagingRootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "comic-update-\(UUID().uuidString)",
                isDirectory: true
            )

        do {
            try sourceAccess.startAccessing(sourceRootURL)
            defer { sourceAccess.stopAccessing(sourceRootURL) }

            let freshWorkItems = update.addedWorkItems
                + update.replacedChapters.flatMap(\.freshWorkItems)
            try await copyAndVerify(
                freshWorkItems,
                from: sourceRootURL,
                stagingRootURL: stagingRootURL,
                cancellationToken: cancellationToken
            )

            let result = try await placeFilesAndSwapDescriptor(
                descriptor: descriptor,
                update: update,
                freshWorkItems: freshWorkItems,
                stagingRootURL: stagingRootURL
            )
            try? FileManager.default.removeItem(at: stagingRootURL)
            return result
        } catch let error as ComicUpdateExecutionError {
            try? FileManager.default.removeItem(at: stagingRootURL)
            throw error
        }
    }

    /// 删除新描述符不再引用的旧页面文件，并把清空后的目录一并
    /// 移除。必须在 `apply` 成功交换描述符之后调用。
    func cleanupSupersededFiles(
        previousDescriptor: ManagedComicDescriptor,
        updatedDescriptor: ManagedComicDescriptor
    ) throws {
        let referencedPaths = Set(
            updatedDescriptor.workItems.map {
                $0.managedRelativePath.stringValue
            }
        )
        let comicRootURL = layout.libraryURL(
            for: updatedDescriptor.targetComicID
        )
        var touchedDirectories = Set<String>()

        for workItem in previousDescriptor.workItems
        where !referencedPaths.contains(
            workItem.managedRelativePath.stringValue
        ) {
            let fileURL = Self.fileURL(
                rootURL: comicRootURL,
                components: workItem.managedRelativePath.components
            )
            try? FileManager.default.removeItem(at: fileURL)
            touchedDirectories.insert(
                fileURL.deletingLastPathComponent().path
            )
        }

        // 自最深目录向 original 根方向移除空目录。
        let originalRootPath = comicRootURL
            .appendingPathComponent("original", isDirectory: true).path
        for directoryPath in touchedDirectories.sorted(by: >) {
            var currentURL = URL(fileURLWithPath: directoryPath)
            while currentURL.path.hasPrefix(originalRootPath),
                  currentURL.path != originalRootPath {
                let contents = (try? FileManager.default.contentsOfDirectory(
                    atPath: currentURL.path
                )) ?? [""]
                guard contents.isEmpty else {
                    break
                }

                try? FileManager.default.removeItem(at: currentURL)
                currentURL = currentURL.deletingLastPathComponent()
            }
        }
    }

    private func copyAndVerify(
        _ freshWorkItems: [FrozenImportWorkItem],
        from sourceRootURL: URL,
        stagingRootURL: URL,
        cancellationToken: ImportCancellationToken
    ) async throws {
        for workItem in freshWorkItems {
            let sourceURL = Self.fileURL(
                rootURL: sourceRootURL,
                components: workItem.sourceRelativePath.components
            )
            let stagedURL = Self.fileURL(
                rootURL: stagingRootURL,
                components: workItem.managedRelativePath.components
            )

            let verification: ImportFileVerification
            do {
                verification = try await fileCopier.copySource(
                    from: sourceURL,
                    to: stagedURL,
                    workItem: workItem,
                    cancellationToken: cancellationToken
                )
                try await fileCopier.verifyPartial(
                    at: stagedURL,
                    expected: verification,
                    cancellationToken: cancellationToken
                )
            } catch let error as ImportCopyError {
                throw Self.executionError(for: error)
            }

            if workItem.pageState == .readable {
                guard await fileCopier.verifyReadableImage(
                    at: stagedURL,
                    workItem: workItem
                ) else {
                    throw ComicUpdateExecutionError.copyFailed
                }
            }
        }
    }

    private func placeFilesAndSwapDescriptor(
        descriptor: ManagedComicDescriptor,
        update: FrozenComicUpdate,
        freshWorkItems: [FrozenImportWorkItem],
        stagingRootURL: URL
    ) async throws -> ManagedComicUpdateResult {
        let fileManager = FileManager.default
        let comicRootURL = layout.libraryURL(for: descriptor.targetComicID)

        // 1. 把新文件放入资料库；此时旧描述符仍有效，最坏情况
        //    只是存在尚未被引用的新文件。
        for workItem in freshWorkItems {
            let destinationURL = Self.fileURL(
                rootURL: comicRootURL,
                components: workItem.managedRelativePath.components
            )
            let stagedURL = Self.fileURL(
                rootURL: stagingRootURL,
                components: workItem.managedRelativePath.components
            )
            do {
                try fileManager.createDirectory(
                    at: destinationURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                if fileManager.fileExists(atPath: destinationURL.path) {
                    try fileManager.removeItem(at: destinationURL)
                }
                try fileManager.moveItem(
                    at: stagedURL,
                    to: destinationURL
                )
            } catch {
                throw ComicUpdateExecutionError.copyFailed
            }
        }

        // 2. 组装并原子写入新描述符与书库目录记录；此后新内容
        //    正式生效，旧文件成为待清理的孤立文件。
        let keptStoredPageIDs = Set(
            descriptor.chapters
                .filter { chapter in
                    !update.removedChapterIDs.contains(chapter.id)
                        && !update.replacedChapters.contains {
                            $0.storedChapterID == chapter.id
                        }
                }
                .flatMap(\.pageIDs)
        )
        let storedChapterPageIDs = Set(
            descriptor.chapters.flatMap(\.pageIDs)
        )
        let keptWorkItems = descriptor.workItems.filter { workItem in
            keptStoredPageIDs.contains(workItem.id)
                || !storedChapterPageIDs.contains(workItem.id)
        }
        let updatedCollections = descriptor.collections
            + update.addedCollections.filter { collection in
                !descriptor.collections.contains { $0.id == collection.id }
            }
        let updatedWorkItems = keptWorkItems
            + freshWorkItems.sorted { $0.id.rawValue < $1.id.rawValue }
        let updatedDescriptor = descriptor.updated(
            collections: updatedCollections,
            chapters: update.resultingChapters,
            workItems: updatedWorkItems,
            coverPageID: update.coverPageID
        )

        let metadataURL = layout.libraryMetadataURL(
            for: descriptor.targetComicID
        )
        let catalogRecord = LibraryCatalogRecord(
            descriptor: updatedDescriptor,
            importedAt: Date()
        )
        do {
            try fileManager.createDirectory(
                at: metadataURL,
                withIntermediateDirectories: true
            )
            try Self.write(
                updatedDescriptor,
                to: metadataURL.appendingPathComponent(
                    "import-descriptor.json"
                )
            )
            try Self.write(
                catalogRecord,
                to: layout.libraryCatalogURL(for: descriptor.targetComicID)
            )
        } catch {
            throw ComicUpdateExecutionError.copyFailed
        }

        // 3. 封面变化时刷新缩略图；缩略图可重建，失败不影响更新。
        if descriptor.coverPageID != update.coverPageID,
           let coverWorkItem = updatedDescriptor.workItems.first(where: {
               $0.id == update.coverPageID
           }) {
            _ = try? await thumbnailGenerator.generate(
                from: Self.fileURL(
                    rootURL: comicRootURL,
                    components: coverWorkItem.managedRelativePath.components
                ),
                to: layout.thumbnailURL(for: descriptor.targetComicID)
            )
        }

        return ManagedComicUpdateResult(
            descriptor: updatedDescriptor,
            catalogRecord: catalogRecord
        )
    }

    private static func fileURL(
        rootURL: URL,
        components: [String]
    ) -> URL {
        components.reduce(rootURL) { currentURL, component in
            currentURL.appendingPathComponent(component)
        }
    }

    private static func write<Value: Encodable>(
        _ value: Value,
        to url: URL
    ) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(value)
        try data.write(to: url, options: .atomic)
    }

    private static func executionError(
        for sourceAccessError: ImportSourceAccessError
    ) -> ComicUpdateExecutionError {
        switch sourceAccessError {
        case .staleBookmark:
            return .staleAuthorization
        case .invalidBookmark:
            return .authorizationInvalid
        case .accessDenied:
            return .accessDenied
        }
    }

    private static func executionError(
        for copyError: ImportCopyError
    ) -> ComicUpdateExecutionError {
        switch copyError {
        case .cancelled, .sourceChanged:
            return .sourceChanged
        case .sourceUnavailable:
            return .sourceUnavailable
        case .verificationFailed, .copyFailed:
            return .copyFailed
        }
    }
}
