import SwiftData
import SwiftUI

private struct LibraryCatalogRefreshID: Equatable {
    let completedJobIDs: [ImportJobID]
    let allowsLibraryWrites: Bool
}

struct SceneRoot: View {
    let modelContainer: ModelContainer?

    @State private var router = AppRouter()
    @State private var importCoordinator = FolderImportCoordinator()
    @State private var libraryCatalog = LibraryCatalogCoordinator()
    @State private var allowsIncrementalCatalogRefresh = false
    @Environment(ImportJobCoordinator.self) private var importJobs
    @Environment(LibraryStateRepository.self) private var libraryState
    @Environment(LibraryPersistenceController.self) private var persistence

    init(modelContainer: ModelContainer? = nil) {
        self.modelContainer = modelContainer
    }

    var body: some View {
        AppView(router: router)
            .environment(importCoordinator)
            .environment(importJobs)
            .environment(libraryCatalog)
            .task {
                guard !Task.isCancelled else {
                    return
                }
                await libraryState.configure(modelContainer: modelContainer)
                guard !Task.isCancelled else {
                    return
                }

                let shouldAllowLibraryWrites = allowsLibraryWrites
                importJobs.setLibraryWritesAllowed(shouldAllowLibraryWrites)
                if shouldAllowLibraryWrites {
                    await importJobs.restorePendingJobs()
                }
                guard !Task.isCancelled else {
                    return
                }

                // 首次目录快照前启用完成任务触发的刷新，避免漏掉并发提交。
                allowsIncrementalCatalogRefresh = true
                if allowsLibraryWrites {
                    await reloadCatalogAndReconcileIfWritable()
                } else {
                    _ = await libraryCatalog.reload()
                }
                guard !Task.isCancelled else {
                    return
                }
            }
            .task(id: allowsLibraryWrites) {
                guard !Task.isCancelled else {
                    return
                }
                let shouldAllowLibraryWrites = allowsLibraryWrites
                importJobs.setLibraryWritesAllowed(shouldAllowLibraryWrites)
                guard allowsIncrementalCatalogRefresh else {
                    return
                }
                if shouldAllowLibraryWrites {
                    await importJobs.restorePendingJobs()
                    guard !Task.isCancelled else {
                        return
                    }
                    await reloadCatalogAndReconcileIfWritable()
                }
            }
            .task(
                id: LibraryCatalogRefreshID(
                    completedJobIDs: importJobs.completedJobIDs,
                    allowsLibraryWrites: allowsLibraryWrites
                )
            ) {
                guard !Task.isCancelled,
                      allowsIncrementalCatalogRefresh else {
                    return
                }

                if allowsLibraryWrites {
                    await reloadCatalogAndReconcileIfWritable()
                } else {
                    _ = await libraryCatalog.reload()
                }
            }
    }

    private var allowsLibraryWrites: Bool {
        persistence.status == .ready && libraryState.isWriteAvailable
    }

    private func reloadCatalogAndReconcileIfWritable() async {
        guard await libraryCatalog.reload(),
              !Task.isCancelled,
              allowsLibraryWrites else {
            return
        }

        await libraryState.reconcile(catalogItems: libraryCatalog.comics)
    }
}

#Preview {
    SceneRoot()
        .environment(ImportJobCoordinator())
        .environment(LibraryStateRepository())
        .environment(
            LibraryPersistenceController(previewModelContainer: nil)
        )
}
