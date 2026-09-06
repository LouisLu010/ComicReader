import SwiftUI

/// 详情页的元数据编辑入口：打开名称、补充信息与封面编辑面板，
/// 保存后刷新书库目录；环境读取收敛在本子视图内。
struct ComicMetadataEditAction: View {
    let comicID: ManagedComicID

    @Environment(LibraryCatalogCoordinator.self) private var libraryCatalog
    @State private var presentation: EditorPresentation?

    private struct EditorPresentation: Identifiable {
        let id: ManagedComicID
        let editor: FileSystemComicMetadataEditor
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                if let layout = libraryCatalog.applicationLayout {
                    presentation = EditorPresentation(
                        id: comicID,
                        editor: FileSystemComicMetadataEditor(layout: layout)
                    )
                }
            } label: {
                Label("library.metadata.edit", systemImage: "pencil")
            }
            .accessibilityIdentifier("library.metadata.edit")
            .disabled(libraryCatalog.applicationLayout == nil)
        }
        .padding(.top, 8)
        .sheet(item: $presentation) { item in
            ComicMetadataEditSheet(comicID: item.id, editor: item.editor)
        }
    }
}

/// 表单状态只在当前面板内；保存前不改变书库或来源文件。
struct ComicMetadataEditSheet: View {
    let comicID: ManagedComicID
    let editor: FileSystemComicMetadataEditor

    @Environment(\.dismiss) private var dismiss
    @Environment(LibraryCatalogCoordinator.self) private var libraryCatalog
    @State private var displayName = ""
    @State private var author = ""
    @State private var summary = ""
    @State private var tagsText = ""
    @State private var readablePages: [FrozenImportWorkItem] = []
    @State private var selectedCoverID: ImportPageCandidate.ID?
    private enum LoadState {
        case loading, loaded, failed
    }

    @State private var loadState: LoadState = .loading
    @State private var isSaving = false
    @State private var isSaveFailedPresented = false

    var body: some View {
        NavigationStack {
            Form {
                switch loadState {
                case .loaded:
                    Section("library.metadata.displayName") {
                        TextField(
                            "library.metadata.displayName.placeholder",
                            text: $displayName
                        )
                        .accessibilityIdentifier(
                            "library.metadata.displayName"
                        )
                    }

                    supplementalFields

                    Section("library.metadata.cover") {
                        Picker(
                            "library.metadata.cover",
                            selection: $selectedCoverID
                        ) {
                            ForEach(readablePages, id: \.id) { page in
                                Text(page.originalFileName)
                                    .tag(Optional(page.id))
                            }
                        }
                        .pickerStyle(.inline)
                        .labelsHidden()
                        .accessibilityIdentifier("library.metadata.cover")
                    }
                case .loading:
                    Section {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                    }
                case .failed:
                    Section {
                        Text("library.metadata.loadFailed")
                        Button("common.retry") {
                            Task { await load() }
                        }
                        .accessibilityIdentifier("library.metadata.retry")
                    }
                }
            }
            .disabled(isSaving)
            .navigationTitle("library.metadata.edit")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("common.cancel") {
                        dismiss()
                    }
                    .disabled(isSaving)
                    .accessibilityIdentifier("library.metadata.cancel")
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("common.save") {
                        Task {
                            await save()
                        }
                    }
                    .disabled(!canSave)
                    .accessibilityIdentifier("library.metadata.save")
                }
            }
            .task {
                await load()
            }
            .alert(
                "library.metadata.saveFailed",
                isPresented: $isSaveFailedPresented
            ) {
                Button("common.ok", role: .cancel) {}
            }
        }
        .interactiveDismissDisabled(isSaving)
    }

    private var supplementalFields: some View {
        Group {
            Section("library.metadata.author") {
                TextField("library.metadata.author", text: $author)
                    .accessibilityIdentifier("library.metadata.author")
            }
            Section {
                TextField("library.metadata.tags", text: $tagsText)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("library.metadata.tags")
            } header: {
                Text("library.metadata.tags")
            } footer: {
                Text("library.metadata.tags.hint")
            }
            Section("library.metadata.summary") {
                TextEditor(text: $summary)
                    .frame(minHeight: 96)
                    .accessibilityLabel(Text("library.metadata.summary"))
                    .accessibilityIdentifier("library.metadata.summary")
            }
        }
    }

    private var canSave: Bool {
        loadState == .loaded && !isSaving && selectedCoverID != nil
            && ComicMetadataEditPolicy.validatedDisplayName(displayName) != nil
    }

    private func load() async {
        loadState = .loading
        do {
            let descriptor = try await editor.loadDescriptor(comicID: comicID)
            guard !Task.isCancelled else { return }
            readablePages = descriptor.workItems.filter {
                $0.pageState == .readable
            }
            selectedCoverID = descriptor.coverPageID
            displayName = descriptor.displayName
            author = descriptor.metadata?.author ?? ""
            summary = descriptor.metadata?.summary ?? ""
            tagsText = (descriptor.metadata?.tags ?? []).joined(separator: ", ")
            loadState = .loaded
        } catch {
            guard !Task.isCancelled else { return }
            loadState = .failed
        }
    }

    private func save() async {
        guard canSave, let coverPageID = selectedCoverID else {
            return
        }

        isSaving = true
        defer { isSaving = false }

        do {
            _ = try await editor.apply(
                comicID: comicID,
                displayName: displayName,
                coverPageID: coverPageID,
                metadata: ComicMetadata(
                    author: author,
                    summary: summary,
                    tags: ComicMetadataEditPolicy.tags(from: tagsText)
                )
            )
            await libraryCatalog.reload()
            dismiss()
        } catch {
            isSaveFailedPresented = true
        }
    }
}
