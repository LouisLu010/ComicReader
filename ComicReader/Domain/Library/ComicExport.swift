import Foundation

/// 一次原结构导出的静态计划：把每个入库文件按其来源相对路径
/// 还原为导入时的目录结构。独立封面与损坏页一并导出，保持
/// 原始字节不变。
struct ComicExportPlan: Equatable, Sendable {
    let comicID: ManagedComicID
    let displayName: String
    let entries: [ComicExportEntry]
}

struct ComicExportEntry: Equatable, Sendable {
    /// 库内文件位置（相对漫画根目录）。
    let managedRelativePath: ManagedRelativePath
    /// 导出目标位置（相对导出根目录），即导入时的来源路径。
    let exportRelativePath: SourceRelativePath
    let originalFileName: String
}

enum ComicExportPlanner {
    static func makePlan(
        descriptor: ManagedComicDescriptor
    ) -> ComicExportPlan {
        let entries = descriptor.workItems.map { workItem in
            ComicExportEntry(
                managedRelativePath: workItem.managedRelativePath,
                exportRelativePath: workItem.sourceRelativePath,
                originalFileName: workItem.originalFileName
            )
        }

        return ComicExportPlan(
            comicID: descriptor.targetComicID,
            displayName: descriptor.displayName,
            entries: entries
        )
    }

    /// 目标目录下已存在同名文件夹时追加序号，保证导出不覆盖
    /// 既有内容："Comic" → "Comic (2)" → "Comic (3)"……
    static func uniquifiedDirectoryName(
        _ base: String,
        existingNames: Set<String>
    ) -> String {
        var candidate = base
        var suffix = 2

        while existingNames.contains(candidate) {
            candidate = "\(base) (\(suffix))"
            suffix += 1
        }

        return candidate
    }
}
