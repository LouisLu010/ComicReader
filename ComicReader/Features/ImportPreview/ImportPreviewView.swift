import Foundation
import SwiftUI

struct ImportPreviewView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(FolderImportCoordinator.self) private var importCoordinator
    @Environment(ImportJobCoordinator.self) private var importJobs

    let sessionID: ImportPreviewSession.ID

    @State private var isStartingImport = false
    @State private var editorNotice: ImportPreviewEditorNotice?

    var body: some View {
        Group {
            if let session = currentSession {
                editor(for: session)
            } else {
                ContentUnavailableView {
                    Label(
                        "import.preview.unavailable.title",
                        systemImage: "doc.badge.ellipsis"
                    )
                } description: {
                    Text("import.preview.unavailable.description")
                }
            }
        }
        .accessibilityIdentifier("import.preview.editor")
    }

    private func editor(for session: ImportPreviewSession) -> some View {
        NavigationStack {
            Form {
                summarySection(for: session.draft)
                coverOnlyPagesSection(for: session.draft)

                Section("import.preview.displayName") {
                    TextField(
                        "import.preview.displayName",
                        text: displayNameBinding
                    )
                    .textInputAutocapitalization(.words)
                }

                if let editorNotice {
                    Section {
                        Label(editorNotice.localizationKey, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                }

                chapterSections(for: session.draft)
            }
            .navigationTitle("import.preview.title")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("common.close") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task {
                            await startImport()
                        }
                    } label: {
                        if isStartingImport {
                            ProgressView()
                        } else {
                            Text("import.preview.start")
                        }
                    }
                    .disabled(!canStartImport || isStartingImport)
                }
            }
        }
    }

    @ViewBuilder
    private func summarySection(for draft: ImportPreviewDraft) -> some View {
        Section("import.preview.summarySection") {
            LabeledContent(
                "import.preview.copyEstimate",
                value: ByteCountFormatter.string(
                    fromByteCount: draft.spaceEstimate.requiredAvailableBytes,
                    countStyle: .file
                )
            )
            LabeledContent(
                "import.preview.files",
                value: draft.spaceEstimate.fileCount.formatted()
            )
            LabeledContent(
                "import.preview.readablePages",
                value: draft.manifest.readableChapterPageCount.formatted()
            )
            LabeledContent(
                "import.preview.issues",
                value: draft.manifest.issues.count.formatted()
            )

            if !canStartImport {
                Label(
                    "import.preview.noReadableContent",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .foregroundStyle(.orange)
            }
        }
    }

    @ViewBuilder
    private func coverOnlyPagesSection(for draft: ImportPreviewDraft) -> some View {
        let chapterPageIDs = Set(draft.manifest.chapters.flatMap(\.pageIDs))
        let coverOnlyPages = draft.manifest.pages.filter {
            !chapterPageIDs.contains($0.id) && $0.state == .readable
        }

        if !coverOnlyPages.isEmpty {
            Section("import.preview.coverSection") {
                ForEach(coverOnlyPages) { page in
                    Button {
                        setCover(page.id)
                    } label: {
                        HStack {
                            Label(page.originalFileName, systemImage: "photo")
                            Spacer()
                            Image(
                                systemName: draft.coverPageID == page.id
                                    ? "checkmark.seal.fill"
                                    : "rectangle.stack.badge.plus"
                            )
                        }
                    }
                    .buttonStyle(.borderless)
                }
            }
        }
    }

    @ViewBuilder
    private func chapterSections(for draft: ImportPreviewDraft) -> some View {
        ForEach(chapterGroups(for: draft)) { group in
            Section {
                ForEach(group.chapters) { chapter in
                    chapterEditorRow(chapter, in: group, draft: draft)
                }
            } header: {
                Text(group.title)
            }
        }
    }

    private func chapterEditorRow(
        _ chapter: ImportChapterCandidate,
        in group: ImportPreviewChapterGroup,
        draft: ImportPreviewDraft
    ) -> some View {
        let pages = draft.manifest.pages(in: chapter)
        let readablePages = pages.filter { $0.state == .readable }
        let chapterIndex = group.chapters.firstIndex(where: {
            $0.id == chapter.id
        }) ?? 0

        return VStack(alignment: .leading, spacing: 10) {
            TextField(
                "import.preview.chapterName",
                text: chapterNameBinding(for: chapter.id)
            )

            Toggle(
                "import.preview.includeChapter",
                isOn: chapterIncludedBinding(for: chapter.id)
            )

            HStack(spacing: 8) {
                Button {
                    moveChapterUp(chapter, in: group, at: chapterIndex)
                } label: {
                    Label("import.preview.moveUp", systemImage: "arrow.up")
                }
                .disabled(chapterIndex == 0)

                Button {
                    moveChapterDown(chapter, in: group, at: chapterIndex)
                } label: {
                    Label("import.preview.moveDown", systemImage: "arrow.down")
                }
                .disabled(chapterIndex >= group.chapters.count - 1)
            }
            .buttonStyle(.borderless)
            .font(.caption)

            DisclosureGroup {
                ForEach(pages) { page in
                    HStack(spacing: 10) {
                        Label(
                            page.originalFileName,
                            systemImage: page.state == .readable
                                ? "photo"
                                : "exclamationmark.triangle"
                        )
                        .foregroundStyle(
                            page.state == .readable ? Color.primary : .orange
                        )
                        .lineLimit(1)

                        Spacer()

                        if page.state == .readable {
                            Button {
                                setCover(page.id)
                            } label: {
                                Image(
                                    systemName: draft.coverPageID == page.id
                                        ? "checkmark.seal.fill"
                                        : "rectangle.stack.badge.plus"
                                )
                            }
                            .accessibilityLabel(
                                draft.coverPageID == page.id
                                    ? Text("import.preview.coverSelected")
                                    : Text("import.preview.setCover")
                            )
                            .buttonStyle(.borderless)
                        }
                    }
                }
            } label: {
                Text(
                    String.localizedStringWithFormat(
                        String(localized: "import.preview.chapterPages"),
                        readablePages.count
                    )
                )
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private var currentSession: ImportPreviewSession? {
        importCoordinator.previewSessions.first { $0.id == sessionID }
    }

    private var currentDraft: ImportPreviewDraft? {
        currentSession?.draft
    }

    private var canStartImport: Bool {
        guard let draft = currentDraft else {
            return false
        }

        return draft.manifest.chapters.contains { chapter in
            draft.includedChapterIDs.contains(chapter.id)
                && draft.manifest.pages(in: chapter).contains {
                    $0.state == .readable
                }
        }
    }

    private var displayNameBinding: Binding<String> {
        Binding(
            get: { currentDraft?.displayName ?? "" },
            set: { value in
                applyDraftUpdate { draft in
                    try draft.setDisplayName(value)
                }
            }
        )
    }

    private func chapterNameBinding(
        for chapterID: ImportChapterCandidate.ID
    ) -> Binding<String> {
        Binding(
            get: {
                currentDraft?.chapterDisplayName(for: chapterID) ?? ""
            },
            set: { value in
                applyDraftUpdate { draft in
                    try draft.setChapterDisplayName(chapterID, value: value)
                }
            }
        )
    }

    private func chapterIncludedBinding(
        for chapterID: ImportChapterCandidate.ID
    ) -> Binding<Bool> {
        Binding(
            get: {
                currentDraft?.includedChapterIDs.contains(chapterID) ?? false
            },
            set: { isIncluded in
                applyDraftUpdate { draft in
                    try draft.setChapterIncluded(
                        chapterID,
                        isIncluded: isIncluded
                    )
                }
            }
        )
    }

    private func chapterGroups(
        for draft: ImportPreviewDraft
    ) -> [ImportPreviewChapterGroup] {
        let manifest = draft.manifest
        let chapterByID = Dictionary(
            uniqueKeysWithValues: manifest.chapters.map { ($0.id, $0) }
        )
        let collectionByID = Dictionary(
            uniqueKeysWithValues: manifest.collections.map { ($0.id, $0) }
        )
        var parentIDs: [ImportCollectionCandidate.ID?] = manifest.collections.map(\.id)

        if manifest.chapters.contains(where: { $0.parentCollectionID == nil }) {
            parentIDs.insert(nil, at: 0)
        }

        return parentIDs.compactMap { parentID in
            let chapters = draft.chapterOrder(for: parentID).compactMap {
                chapterByID[$0]
            }
            guard !chapters.isEmpty else {
                return nil
            }

            let title: String
            if let parentID,
               let collection = collectionByID[parentID] {
                title = collection.sourceRelativePath.stringValue
            } else {
                title = String(localized: "import.preview.root")
            }

            return ImportPreviewChapterGroup(
                parentID: parentID,
                title: title,
                chapters: chapters
            )
        }
    }

    private func moveChapterUp(
        _ chapter: ImportChapterCandidate,
        in group: ImportPreviewChapterGroup,
        at index: Int
    ) {
        guard index > 0 else {
            return
        }

        applyDraftUpdate { draft in
            try draft.moveChapter(
                chapter.id,
                before: group.chapters[index - 1].id
            )
        }
    }

    private func moveChapterDown(
        _ chapter: ImportChapterCandidate,
        in group: ImportPreviewChapterGroup,
        at index: Int
    ) {
        guard index < group.chapters.count - 1 else {
            return
        }

        let anchorID = index + 2 < group.chapters.count
            ? group.chapters[index + 2].id
            : nil

        applyDraftUpdate { draft in
            try draft.moveChapter(chapter.id, before: anchorID)
        }
    }

    private func setCover(_ pageID: ImportPageCandidate.ID) {
        applyDraftUpdate { draft in
            try draft.setCoverPage(pageID)
        }
    }

    private func applyDraftUpdate(
        _ update: (inout ImportPreviewDraft) throws -> Void
    ) {
        do {
            try importCoordinator.updatePreviewDraft(
                for: sessionID,
                update
            )
            editorNotice = nil
        } catch {
            editorNotice = .invalidChange
        }
    }

    private func startImport() async {
        guard !isStartingImport else {
            return
        }

        guard let session = currentSession else {
            return
        }

        isStartingImport = true
        defer {
            isStartingImport = false
        }

        guard await importJobs.startImport(
            draft: session.draft,
            sourceURL: session.sourceURL
        ) != nil else {
            editorNotice = .couldNotStart
            return
        }

        importCoordinator.removePreviewSession(withID: sessionID)
        dismiss()
    }
}

private struct ImportPreviewChapterGroup: Identifiable {
    let parentID: ImportCollectionCandidate.ID?
    let title: String
    let chapters: [ImportChapterCandidate]

    var id: String {
        parentID?.rawValue ?? "root"
    }
}

private enum ImportPreviewEditorNotice: Identifiable {
    case invalidChange
    case couldNotStart

    var id: String {
        switch self {
        case .invalidChange:
            "invalidChange"
        case .couldNotStart:
            "couldNotStart"
        }
    }

    var localizationKey: LocalizedStringKey {
        switch self {
        case .invalidChange:
            "import.preview.editError"
        case .couldNotStart:
            "import.preview.startError"
        }
    }
}
