import Foundation

enum ComicExportError: Error, Equatable, Sendable {
    /// 已入库漫画目录或描述符不存在。
    case comicNotFound
    case descriptorUnreadable
    /// 目标位置无效（不存在、不是目录，或位于 App 管理目录内）。
    case destinationInvalid
    /// 库内缺少计划中的文件。
    case missingManagedFile(SourceRelativePath)
    case copyFailed(SourceRelativePath)
}

/// 原结构导出执行器：把已入库漫画按导入时的目录结构复制到
/// 用户指定位置。写入新目录，不覆盖既有内容；中途失败时清
/// 理本次创建的导出根目录，来源与库内文件始终只读。
actor ComicExportExecutor {
    private let layout: ImportStorageLayout

    init(layout: ImportStorageLayout) {
        self.layout = layout
    }

    /// 返回实际使用的导出根目录（`目标/显示名`，重名自动追加序号）。
    /// 描述符在执行器内读取，调用方只需要漫画 ID 与目标位置。
    func export(
        comicID: ManagedComicID,
        to destinationURL: URL
    ) async throws -> URL {
        let fileManager = FileManager.default
        let comicRootURL = layout.libraryURL(for: comicID)

        guard fileManager.fileExists(atPath: comicRootURL.path) else {
            throw ComicExportError.comicNotFound
        }

        let descriptor: ManagedComicDescriptor
        do {
            let descriptorData = try Data(contentsOf: layout
                .libraryMetadataURL(for: comicID)
                .appendingPathComponent("import-descriptor.json"))
            descriptor = try JSONDecoder().decode(
                ManagedComicDescriptor.self,
                from: descriptorData
            )
        } catch {
            throw ComicExportError.descriptorUnreadable
        }

        guard descriptor.targetComicID == comicID else {
            throw ComicExportError.comicNotFound
        }

        guard Self.isUsableDestination(
            destinationURL,
            managedRootURL: layout.rootURL,
            fileManager: fileManager
        ) else {
            throw ComicExportError.destinationInvalid
        }

        let plan = ComicExportPlanner.makePlan(descriptor: descriptor)
        let existingNames = Set(
            (try? fileManager.contentsOfDirectory(atPath: destinationURL.path))
                ?? []
        )
        let exportRootURL = destinationURL.appendingPathComponent(
            ComicExportPlanner.uniquifiedDirectoryName(
                plan.displayName,
                existingNames: existingNames
            ),
            isDirectory: true
        )

        do {
            try fileManager.createDirectory(
                at: exportRootURL,
                withIntermediateDirectories: true
            )

            for entry in plan.entries {
                let sourceURL = entry.managedRelativePath.components.reduce(
                    comicRootURL
                ) { currentURL, component in
                    currentURL.appendingPathComponent(component)
                }
                let destinationFileURL = entry.exportRelativePath.components
                    .reduce(exportRootURL) { currentURL, component in
                        currentURL.appendingPathComponent(component)
                    }

                guard fileManager.fileExists(atPath: sourceURL.path) else {
                    throw ComicExportError.missingManagedFile(
                        entry.exportRelativePath
                    )
                }

                do {
                    try fileManager.createDirectory(
                        at: destinationFileURL.deletingLastPathComponent(),
                        withIntermediateDirectories: true
                    )
                    try fileManager.copyItem(
                        at: sourceURL,
                        to: destinationFileURL
                    )
                } catch {
                    throw ComicExportError.copyFailed(
                        entry.exportRelativePath
                    )
                }
            }
        } catch {
            try? fileManager.removeItem(at: exportRootURL)
            throw error
        }

        return exportRootURL
    }

    /// 目标必须是已存在的目录，且不能位于 App 管理目录内，
    /// 避免把资料库复制进自己的数据。
    private static func isUsableDestination(
        _ destinationURL: URL,
        managedRootURL: URL,
        fileManager: FileManager
    ) -> Bool {
        let standardizedDestination = destinationURL.standardizedFileURL
        let standardizedManagedRoot = managedRootURL.standardizedFileURL

        guard standardizedDestination.path != standardizedManagedRoot.path,
              !standardizedDestination.path.hasPrefix(
                  standardizedManagedRoot.path + "/"
              ) else {
            return false
        }

        var isDirectory: ObjCBool = false
        return fileManager.fileExists(
            atPath: standardizedDestination.path,
            isDirectory: &isDirectory
        ) && isDirectory.boolValue
    }
}
