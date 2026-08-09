import Foundation
import SwiftData

enum ComicReaderModelContainerOpenResult: Sendable {
    case opened(ModelContainer)
    case recoveryRequired(ComicReaderModelStoreRecovery)
}

struct ComicReaderModelStoreRecovery: Equatable, Sendable {
    fileprivate let storeURL: URL
}

struct ComicReaderModelStoreDeletionReport: Equatable, Sendable {
    let removedFileCount: Int
}

enum ComicReaderModelStoreRecoveryError: Error, Equatable, Sendable {
    case unsafeStoreURL
    case unsafeStoreEntry
}

enum ComicReaderModelContainer {
    static func makeApplicationContainer() -> ModelContainer? {
        switch openApplicationContainer() {
        case let .opened(container):
            return container
        case .recoveryRequired:
            return nil
        }
    }

    static func openApplicationContainer() -> ComicReaderModelContainerOpenResult {
        openDiskContainer()
    }

    /// 打开失败时只返回恢复令牌，不自动修改或删除现有数据库。
    static func openDiskContainer(
        storeURL: URL? = nil
    ) -> ComicReaderModelContainerOpenResult {
        let setup = makeConfiguration(
            isStoredInMemoryOnly: false,
            storeURL: storeURL
        )

        do {
            return .opened(
                try makeContainer(
                    schema: setup.schema,
                    configuration: setup.configuration
                )
            )
        } catch {
            return .recoveryRequired(
                ComicReaderModelStoreRecovery(
                    storeURL: setup.configuration.url.standardizedFileURL
                )
            )
        }
    }

    static func makeContainer(
        isStoredInMemoryOnly: Bool,
        storeURL: URL? = nil
    ) throws -> ModelContainer {
        let setup = makeConfiguration(
            isStoredInMemoryOnly: isStoredInMemoryOnly,
            storeURL: storeURL
        )

        return try makeContainer(
            schema: setup.schema,
            configuration: setup.configuration
        )
    }

    /// 仅删除失败 store 的主文件和 SQLite sidecar；不会递归删除目录。
    static func deleteFailedStoreIndex(
        _ recovery: ComicReaderModelStoreRecovery,
        fileManager: FileManager = .default
    ) throws -> ComicReaderModelStoreDeletionReport {
        let storeURL = recovery.storeURL.standardizedFileURL
        guard storeURL.isFileURL,
              storeURL.pathExtension.lowercased() == "store" else {
            throw ComicReaderModelStoreRecoveryError.unsafeStoreURL
        }

        let candidates = storeFileURLs(for: storeURL)
        var existingFiles: [URL] = []
        for candidate in candidates {
            if try isSafeFile(at: candidate, fileManager: fileManager) {
                existingFiles.append(candidate)
            }
        }

        var removedFileCount = 0
        for candidate in existingFiles {
            guard try isSafeFile(at: candidate, fileManager: fileManager) else {
                continue
            }
            try fileManager.removeItem(at: candidate)
            removedFileCount += 1
        }

        return ComicReaderModelStoreDeletionReport(
            removedFileCount: removedFileCount
        )
    }

    private static func makeConfiguration(
        isStoredInMemoryOnly: Bool,
        storeURL: URL?
    ) -> (schema: Schema, configuration: ModelConfiguration) {
        let schema = Schema(versionedSchema: ComicReaderSchemaV4.self)
        let configuration: ModelConfiguration
        if let storeURL {
            configuration = ModelConfiguration(
                schema: schema,
                url: storeURL,
                cloudKitDatabase: .none
            )
        } else {
            configuration = ModelConfiguration(
                "ComicReader",
                schema: schema,
                isStoredInMemoryOnly: isStoredInMemoryOnly,
                cloudKitDatabase: .none
            )
        }

        return (schema, configuration)
    }

    private static func makeContainer(
        schema: Schema,
        configuration: ModelConfiguration
    ) throws -> ModelContainer {
        try ModelContainer(
            for: schema,
            migrationPlan: ComicReaderMigrationPlan.self,
            configurations: [configuration]
        )
    }

    private static func storeFileURLs(for storeURL: URL) -> [URL] {
        ["-wal", "-shm", "-journal", ""].map { suffix in
            URL(
                fileURLWithPath: storeURL.path + suffix,
                isDirectory: false
            )
        }
    }

    private static func isSafeFile(
        at url: URL,
        fileManager: FileManager
    ) throws -> Bool {
        if (try? fileManager.destinationOfSymbolicLink(atPath: url.path)) != nil {
            throw ComicReaderModelStoreRecoveryError.unsafeStoreEntry
        }

        guard fileManager.fileExists(atPath: url.path) else {
            return false
        }

        let values = try url.resourceValues(
            forKeys: [
                .isDirectoryKey,
                .isRegularFileKey,
                .isSymbolicLinkKey,
            ]
        )
        guard values.isDirectory != true,
              values.isSymbolicLink != true,
              values.isRegularFile == true else {
            throw ComicReaderModelStoreRecoveryError.unsafeStoreEntry
        }

        return true
    }
}
