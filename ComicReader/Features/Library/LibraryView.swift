import Foundation
import SwiftUI

struct LibraryView: View {
    let section: LibrarySection
    let onImport: () -> Void

    @Environment(FolderImportCoordinator.self) private var importCoordinator
    @Environment(ImportJobCoordinator.self) private var importJobs
    @Environment(LibraryCatalogCoordinator.self) private var libraryCatalog
    @Environment(LibraryStateRepository.self) private var libraryState
    @Environment(LibraryPersistenceController.self) private var persistence

    @State private var presentedPreview: ImportPreviewDestination?
    @State private var presentedReport: ImportReportDestination?
    @State private var isDropFailurePresented = false

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 20) {
                if importJobs.isRestoring {
                    ImportSelectionBanner(kind: .restoring)
                }

                switch importCoordinator.status {
                case let .scanning(folderNames):
                    ImportSelectionBanner(
                        kind: .scanning(folderCount: folderNames.count)
                    )
                case .idle, .preview, .failed:
                    EmptyView()
                }

                if !importCoordinator.failedFolderNames.isEmpty {
                    ImportSelectionBanner(
                        kind: .recognitionFailed(
                            folderCount: importCoordinator.failedFolderNames.count
                        )
                    )
                } else if importCoordinator.status == .failed {
                    ImportSelectionBanner(kind: .selectionFailed)
                }

                if libraryCatalog.state == .loading,
                   libraryCatalog.comics.isEmpty {
                    LibraryCatalogLoadingView()
                } else if libraryCatalog.state == .failed,
                          libraryCatalog.comics.isEmpty {
                    LibraryCatalogFailureView()
                }

                if persistence.status == .opening {
                    LibraryIndexOpeningView()
                } else if libraryState.status == .unavailable
                            || libraryState.status == .failed {
                    LibraryStateUnavailableView()
                }

                if allowsLibraryWrites {
                    ImportFolderDropTarget(
                        onPreparedSources: { preparation in
                            importCoordinator.handlePreparedSources(preparation)
                        },
                        onDropFailure: {
                            isDropFailurePresented = true
                        }
                    )
                }

                if !displayedComics.isEmpty {
                    LibraryComicGrid(
                        title: section.title,
                        comics: displayedComics,
                        thumbnailURL: { comic in
                            libraryCatalog.thumbnailURL(for: comic)
                        }
                    )
                } else if showsEmptySection {
                    LibrarySectionEmptyView(section: section)
                }

                if !importCoordinator.previewSessions.isEmpty {
                    ImportPreviewQueue(
                        sessions: importCoordinator.previewSessions,
                        onReview: { sessionID in
                            presentedPreview = ImportPreviewDestination(
                                sessionID: sessionID
                            )
                        }
                    )
                }

                if !importJobs.jobs.isEmpty {
                    ImportJobListView(
                        jobs: importJobs.jobs,
                        isActive: importJobs.isActive,
                        allowsLibraryWrites: allowsLibraryWrites,
                        onCancel: importJobs.cancel,
                        onResume: importJobs.resume,
                        onShowReport: { jobID in
                            guard let snapshot = importJobs.job(for: jobID) else {
                                return
                            }
                            presentedReport = ImportReportDestination(
                                snapshot: snapshot
                            )
                        }
                    )
                }

                if showsEmptyLibrary {
                    emptyLibrary
                }
            }
            .frame(maxWidth: 820, alignment: .leading)
            .padding()
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .navigationTitle(section.title)
        .modifier(
            LibrarySearchModifier(
                isActive: section == .all,
                text: searchTextBinding
            )
        )
        .toolbar {
            if section == .all {
                ToolbarItem(placement: .secondaryAction) {
                    LibraryFilterMenu(filter: filterBinding)
                }

                ToolbarItem(placement: .secondaryAction) {
                    LibrarySortMenu(filter: filterBinding)
                }
            }

            ToolbarItem(placement: .primaryAction) {
                Button(action: onImport) {
                    Label("import.action", systemImage: "folder.badge.plus")
                }
                .accessibilityIdentifier("import.toolbarButton")
                .disabled(!allowsLibraryWrites)
            }

            ToolbarItem(placement: .secondaryAction) {
                Button {
                    guard allowsLibraryWrites else {
                        return
                    }
                    Task {
                        await reloadCatalogAndReconcileIfWritable()
                    }
                } label: {
                    Label("library.reload", systemImage: "arrow.clockwise")
                }
                .accessibilityIdentifier("library.reload")
                .disabled(!allowsLibraryWrites)
            }
        }
        .sheet(item: $presentedPreview) { destination in
            ImportPreviewView(sessionID: destination.sessionID)
        }
        .sheet(item: $presentedReport) { destination in
            ImportReportView(snapshot: destination.snapshot)
        }
        .alert(item: workflowNoticeBinding) { notice in
            Alert(
                title: Text(workflowNoticeTitle(notice)),
                message: Text(workflowNoticeMessage(notice)),
                dismissButton: .default(Text("common.ok")) {
                    importJobs.dismissNotice()
                }
            )
        }
        .alert("import.dropFailure.title", isPresented: $isDropFailurePresented) {
            Button("common.ok", role: .cancel) {}
        } message: {
            Text("import.dropFailure.description")
        }
    }

    private var showsEmptyLibrary: Bool {
        guard libraryCatalog.comics.isEmpty,
              importCoordinator.previewSessions.isEmpty,
              importJobs.jobs.isEmpty else {
            return false
        }

        if case .scanning = importCoordinator.status {
            return false
        }

        if libraryCatalog.state == .loading || libraryCatalog.state == .failed {
            return false
        }

        return true
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

    private var displayedComics: [LibraryCatalogItem] {
        switch section {
        case .all:
            searchedLibraryComics
        case .unread:
            libraryState.unreadComics(in: libraryCatalog.comicsByTitle)
        case .recent:
            libraryCatalog.comics
        case .continueReading:
            libraryState.continueReadingComics(in: libraryCatalog.comics)
        case .favorites:
            libraryState.favoriteComics(in: libraryCatalog.comicsByTitle)
        case .shelves, .settings:
            []
        }
    }

    /// "全部"分区：应用搜索、筛选与排序后的书库条目。
    private var searchedLibraryComics: [LibraryCatalogItem] {
        let items = libraryCatalog.comicsByTitle
        let sortedComics = LibraryCatalogSearchEngine.filter(
            items.map { libraryState.sortableComic(for: $0) },
            using: libraryCatalog.searchFilter
        )
        let itemsByID = Dictionary(
            uniqueKeysWithValues: items.map { ($0.id, $0) }
        )
        return sortedComics.compactMap { itemsByID[$0.id] }
    }

    private var searchTextBinding: Binding<String> {
        Binding(
            get: { libraryCatalog.searchFilter.searchText },
            set: { libraryCatalog.searchFilter.searchText = $0 }
        )
    }

    private var filterBinding: Binding<LibrarySearchFilter> {
        Binding(
            get: { libraryCatalog.searchFilter },
            set: { libraryCatalog.searchFilter = $0 }
        )
    }

    private var showsEmptySection: Bool {
        guard !libraryCatalog.comics.isEmpty,
              displayedComics.isEmpty else {
            return false
        }

        return !sectionRequiresUserState || libraryState.status == .ready
    }

    private var sectionRequiresUserState: Bool {
        switch section {
        case .continueReading, .favorites, .unread:
            true
        case .all, .recent, .shelves, .settings:
            false
        }
    }

    private var emptyLibrary: some View {
        ContentUnavailableView {
            Label(section.title, systemImage: section.systemImage)
                .accessibilityIdentifier("library.empty")
        } description: {
            Text("library.empty.description")
        } actions: {
            Button(action: onImport) {
                Label("import.action", systemImage: "folder.badge.plus")
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("import.button")
            .disabled(!allowsLibraryWrites)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
    }

    private var workflowNoticeBinding: Binding<ImportJobWorkflowNotice?> {
        Binding(
            get: { importJobs.notice },
            set: { notice in
                if notice == nil {
                    importJobs.dismissNotice()
                }
            }
        )
    }

    private func workflowNoticeTitle(
        _ notice: ImportJobWorkflowNotice
    ) -> LocalizedStringKey {
        switch notice {
        case .storageUnavailable:
            "import.workflow.storageUnavailable.title"
        case .libraryReadOnly:
            "import.workflow.readOnly.title"
        case .couldNotStart, .couldNotContinue:
            "import.workflow.operationFailed.title"
        }
    }

    private func workflowNoticeMessage(
        _ notice: ImportJobWorkflowNotice
    ) -> LocalizedStringKey {
        switch notice {
        case .storageUnavailable:
            "import.workflow.storageUnavailable.message"
        case .libraryReadOnly:
            "import.workflow.readOnly.message"
        case .couldNotStart:
            "import.workflow.startFailed.message"
        case .couldNotContinue:
            "import.workflow.continueFailed.message"
        }
    }
}

private struct LibraryCatalogLoadingView: View {
    var body: some View {
        HStack(spacing: 10) {
            ProgressView()
            Text("library.loading")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("library.loading")
    }
}

private struct LibraryCatalogFailureView: View {
    var body: some View {
        Label(
            "library.loadFailed",
            systemImage: "exclamationmark.triangle.fill"
        )
        .foregroundStyle(.orange)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct LibraryIndexOpeningView: View {
    var body: some View {
        HStack(spacing: 10) {
            ProgressView()
            Text("library.index.opening")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("library.openingIndex")
    }
}

private struct LibraryStateUnavailableView: View {
    var body: some View {
        Label(
            "library.state.unavailable",
            systemImage: "exclamationmark.triangle.fill"
        )
        .font(.subheadline)
        .foregroundStyle(.orange)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct LibrarySearchModifier: ViewModifier {
    let isActive: Bool
    @Binding var text: String

    @ViewBuilder
    func body(content: Content) -> some View {
        if isActive {
            content.searchable(
                text: $text,
                placement: .navigationBarDrawer(displayMode: .automatic),
                prompt: Text("library.search.prompt")
            )
        } else {
            content
        }
    }
}

private struct LibraryFilterMenu: View {
    @Binding var filter: LibrarySearchFilter

    var body: some View {
        Menu {
            Button {
                filter.favoritesOnly.toggle()
            } label: {
                Label {
                    Text("library.filter.favoritesOnly")
                } icon: {
                    Image(
                        systemName: filter.favoritesOnly
                            ? "checkmark" : "circle"
                    )
                }
            }
            .accessibilityIdentifier("library.filter.favoritesOnly")

            Section("library.filter.readState") {
                ForEach(
                    LibraryReadStateFilter.allCases,
                    id: \.rawValue
                ) { readState in
                    Button {
                        filter.readState = readState
                    } label: {
                        LibraryMenuOptionLabel(
                            title: Text("library.filter.readState.\(readState.rawValue)"),
                            isSelected: filter.readState == readState
                        )
                    }
                    .accessibilityIdentifier(
                        "library.filter.readState.\(readState.rawValue)"
                    )
                }
            }
        } label: {
            Label(
                "library.filter.menu",
                systemImage: "line.3.horizontal.decrease.circle"
            )
        }
        .accessibilityIdentifier("library.filter.menu")
    }
}

private struct LibrarySortMenu: View {
    @Binding var filter: LibrarySearchFilter

    var body: some View {
        Menu {
            ForEach(LibrarySortOption.allCases, id: \.rawValue) { sort in
                Button {
                    filter.sort = sort
                } label: {
                    LibraryMenuOptionLabel(
                        title: Text("library.sort.\(sort.rawValue)"),
                        isSelected: filter.sort == sort
                    )
                }
                .accessibilityIdentifier("library.sort.\(sort.rawValue)")
            }
        } label: {
            Label("library.sort.menu", systemImage: "arrow.up.arrow.down")
        }
        .accessibilityIdentifier("library.sort.menu")
    }
}

private struct LibraryMenuOptionLabel: View {
    let title: Text
    let isSelected: Bool

    var body: some View {
        Label {
            title
        } icon: {
            Image(systemName: isSelected ? "checkmark" : "circle")
        }
    }
}

private struct LibrarySectionEmptyView: View {
    let section: LibrarySection

    var body: some View {
        ContentUnavailableView {
            Label(section.title, systemImage: section.systemImage)
        } description: {
            Text("library.section.empty.description")
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }
}

private struct ImportPreviewDestination: Identifiable {
    let sessionID: ImportPreviewSession.ID

    var id: UUID {
        sessionID
    }
}

private struct ImportReportDestination: Identifiable {
    let snapshot: ImportJobSnapshot

    var id: ImportJobID {
        snapshot.id
    }
}

private struct ImportPreviewQueue: View {
    let sessions: [ImportPreviewSession]
    let onReview: (ImportPreviewSession.ID) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("import.preview.ready.title", systemImage: "doc.text.magnifyingglass")
                .font(.headline)

            Text("import.preview.ready.description")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            ForEach(Array(sessions.enumerated()), id: \.element.id) {
                index,
                session in
                Button {
                    onReview(session.id)
                } label: {
                    ImportPreviewCard(session: session)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("import.preview.comic.\(index)")
            }
        }
        .accessibilityIdentifier("import.preview")
    }
}

private struct ImportPreviewCard: View {
    let session: ImportPreviewSession

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: "books.vertical")
                    .font(.title2)
                    .foregroundStyle(.tint)
                    .frame(width: 38, height: 48)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))

                VStack(alignment: .leading, spacing: 4) {
                    Text(session.draft.displayName)
                        .font(.headline)
                        .lineLimit(1)

                    Text(
                        String.localizedStringWithFormat(
                            String(localized: "import.preview.summary"),
                            session.manifest.collections.count,
                            session.manifest.chapters.count,
                            session.manifest.chapterPageCount,
                            session.manifest.issues.count
                        )
                    )
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                }

                Spacer()

                Label("import.preview.review", systemImage: "chevron.right")
                    .labelStyle(.iconOnly)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Label(
                    ByteCountFormatter.string(
                        fromByteCount: session.draft.spaceEstimate.requiredAvailableBytes,
                        countStyle: .file
                    ),
                    systemImage: "externaldrive"
                )
                .font(.caption)
                .foregroundStyle(.secondary)

                Spacer()

                if let coverPage = session.manifest.pages.first(where: {
                    $0.id == session.draft.coverPageID
                }) {
                    Label(coverPage.originalFileName, systemImage: "rectangle.stack")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }
}

private struct ImportSelectionBanner: View {
    enum Kind {
        case scanning(folderCount: Int)
        case selectionFailed
        case recognitionFailed(folderCount: Int)
        case restoring
    }

    let kind: Kind

    var body: some View {
        GroupBox {
            switch kind {
            case let .scanning(folderCount):
                Label {
                    Text(
                        String.localizedStringWithFormat(
                            String(localized: "import.scanning.count"),
                            folderCount
                        )
                    )
                } icon: {
                    ProgressView()
                }
            case .selectionFailed:
                Label("import.failed.description", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            case let .recognitionFailed(folderCount):
                Label {
                    Text(
                        String.localizedStringWithFormat(
                            String(localized: "import.preview.failedScans.description"),
                            folderCount
                        )
                    )
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                }
                .foregroundStyle(.orange)
            case .restoring:
                Label {
                    Text("import.jobs.restoring")
                } icon: {
                    ProgressView()
                }
            }
        }
        .frame(maxWidth: 820, alignment: .leading)
    }
}

#Preview("Empty library") {
    NavigationStack {
        LibraryView(section: .all) {}
            .environment(FolderImportCoordinator())
            .environment(ImportJobCoordinator())
            .environment(LibraryCatalogCoordinator())
            .environment(LibraryStateRepository())
            .environment(
                LibraryPersistenceController(previewModelContainer: nil)
            )
    }
}
