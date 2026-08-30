import SwiftUI

/// 详情页的元数据编辑入口：打开编辑面板（显示名 + 封面选择），
/// 保存后刷新书库目录；环境读取收敛在本子视图内。
struct ComicMetadataEditAction: View {
    let comicID: ManagedComicID

    @Environment(LibraryCatalogCoordinator.self) private var libraryCatalog
    @State private var isSheetPresented = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                isSheetPresented = true
            } label: {
                Label("library.metadata.edit", systemImage: "pencil")
            }
            .accessibilityIdentifier("library.metadata.edit")
        }
        .padding(.top, 8)
        .sheet(isPresented: $isSheetPresented) {
            if let layout = libraryCatalog.applicationLayout {
                ComicMetadataEditSheet(
                    comicID: comicID,
                    editor: FileSystemComicMetadataEditor(layout: layout)
                )
            }
        }
    }
}

/// 元数据编辑面板：显示名文本框 + 封面页选择（可读页面）。
struct ComicMetadataEditSheet: View {
    let comicID: ManagedComicID
    let editor: FileSystemComicMetadataEditor

    @Environment(\.dismiss) private var dismiss
    @Environment(LibraryCatalogCoordinator.self) private var libraryCatalog
    @State private var displayName = ""
    @State private var readablePages: [FrozenImportWorkItem] = []
    @State private var selectedCoverID: ImportPageCandidate.ID?
    @State private var isLoaded = false
    @State private var isSaving = false
    @State private var isSaveFailedPresented = false

    var body: some View {
        NavigationStack {
            Form {
                if isLoaded {
                    Section("library.metadata.displayName") {
                        TextField(
                            "library.metadata.displayName.placeholder",
                            text: $displayName
                        )
                        .accessibilityIdentifier(
                            "library.metadata.displayName"
                        )
                    }

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
                } else {
                    Section {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                    }
                }
            }
            .navigationTitle("library.metadata.edit")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("common.cancel") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("common.save") {
                        Task {
                            await save()
                        }
                    }
                    .disabled(!isLoaded || isSaving)
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
    }

    private func load() async {
        do {
            let descriptor = try await editor.loadDescriptor(comicID: comicID)
            readablePages = descriptor.workItems.filter {
                $0.pageState == .readable
            }
            selectedCoverID = descriptor.coverPageID
            displayName = descriptor.displayName
            isLoaded = true
        } catch {
            isLoaded = false
        }
    }

    private func save() async {
        guard let coverPageID = selectedCoverID else {
            return
        }

        isSaving = true
        defer { isSaving = false }

        do {
            _ = try await editor.apply(
                comicID: comicID,
                displayName: displayName,
                coverPageID: coverPageID
            )
            await libraryCatalog.reload()
            dismiss()
        } catch {
            isSaveFailedPresented = true
        }
    }
}
