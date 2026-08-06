import Combine
import SwiftUI
import UIKit

@MainActor
struct ReaderScreen: View {
    let title: String

    @State private var controller: ReaderScreenController
    @State private var visibleAssetSnapshot = ReaderVisibleAssetSnapshot.empty
    @State private var thumbnailReloadGeneration: UInt64 = 0
    @State private var presentedSheet: ReaderPresentedSheet?
    @Environment(\.scenePhase) private var scenePhase

    init(
        comicID: ManagedComicID,
        title: String,
        contentLoader: any ReaderContentLoading,
        progressRecorder: (any ReaderProgressRecording)?,
        persistedProgress: LibraryReadingProgress?
    ) {
        self.title = title
        _controller = State(
            initialValue: ReaderScreenController(
                comicID: comicID,
                contentLoader: contentLoader,
                progressRecorder: progressRecorder,
                persistedProgress: persistedProgress
            )
        )
        _presentedSheet = State(initialValue: nil)
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Color.black.ignoresSafeArea()
                content(viewportSize: proxy.size)
            }
            .onChange(of: proxy.size, initial: true) { _, size in
                controller.setViewportSize(size)
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .preferredColorScheme(.dark)
        .task {
            _ = await controller.load()
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: UIApplication.didReceiveMemoryWarningNotification
            )
        ) { _ in
            handleMemoryWarning()
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase != .active else {
                return
            }

            flushProgress()
        }
        .onChange(of: controller.state) { _, state in
            guard state != .ready else {
                return
            }

            visibleAssetSnapshot = .empty
            presentedSheet = nil
        }
        .onDisappear {
            visibleAssetSnapshot = .empty
            presentedSheet = nil
            flushProgress()
        }
        .toolbar {
            readerControlsToolbar
        }
        .safeAreaInset(edge: .bottom, spacing: 12) {
            if let progress = readerPageProgress,
               let readerContent = controller.content,
               let layout = controller.layout,
               let sessionController = controller.sessionController {
                VStack(spacing: 8) {
                    if layout.pageCount > 1 {
                        ReaderThumbnailStrip(
                            layout: layout,
                            assetResolver: readerContent.assetResolver,
                            imagePipeline: controller.imagePipeline,
                            selectedPresentationID: (
                                controller.visiblePresentationID
                            ),
                            selectedLocation: sessionController.session.position
                                .location,
                            reloadGeneration: thumbnailReloadGeneration,
                            onSelect: { location in
                                _ = controller.jump(to: location)
                            }
                        )
                    }

                    ReaderPageNavigationView(
                        progress: progress,
                        canMoveToPreviousChapter: (
                            controller.canMoveToPreviousChapter
                        ),
                        canMoveToNextChapter: controller.canMoveToNextChapter,
                        onSelectPage: { pageNumber in
                            _ = controller.jumpToPage(pageNumber)
                        },
                        onMoveToPreviousChapter: {
                            _ = controller.moveToPreviousChapter()
                        },
                        onMoveToNextChapter: {
                            _ = controller.moveToNextChapter()
                        }
                    )
                }
            }
        }
        .sheet(item: $presentedSheet) { sheet in
            switch sheet {
            case .chapters:
                ReaderChapterListView(
                    destinations: controller.navigationIndex?
                        .chapterDestinations ?? [],
                    selectedChapterID: controller.sessionController?
                        .session.position.chapterID,
                    onSelect: { chapterID in
                        controller.jumpToChapter(chapterID)
                    }
                )
                .presentationDetents([.medium, .large])
            }
        }
        .accessibilityIdentifier("reader.screen")
    }

    @ViewBuilder
    private func content(viewportSize: CGSize) -> some View {
        switch controller.state {
        case .idle, .loading:
            ProgressView("reader.loading")
                .tint(.white)
                .foregroundStyle(.white)
                .accessibilityIdentifier("reader.loading")
        case let .failed(failure):
            ReaderLoadFailureView(failure: failure) {
                Task { @MainActor in
                    _ = await controller.load()
                }
            }
        case .ready:
            if let content = controller.content,
               let sessionController = controller.sessionController,
               let layout = controller.layout {
                ReaderContentView(
                    layout: layout,
                    assetResolver: content.assetResolver,
                    imagePipeline: controller.imagePipeline,
                    sessionController: sessionController,
                    viewportSize: viewportSize,
                    navigationRequest: controller.navigationRequest,
                    onVisiblePresentationChanged: {
                        controller.setVisiblePresentationID($0)
                    },
                    visibleAssetSnapshot: $visibleAssetSnapshot
                )
                .environment(
                    \.readerViewportVisiblePageIDs,
                    visibleAssetSnapshot.pageIDs
                )
                .focusedSceneValue(
                    \.readerCommandSet,
                    readerCommandSet(for: sessionController)
                )
            } else {
                ReaderLoadFailureView(failure: .invalidContent) {
                    Task { @MainActor in
                        _ = await controller.load()
                    }
                }
            }
        }
    }

    private func flushProgress() {
        Task { @MainActor in
            _ = await controller.flushPendingProgress()
        }
    }

    private func handleMemoryWarning() {
        let visibleAssetIdentities = visibleAssetSnapshot.assetIdentities
        Task { @MainActor in
            await controller.imagePipeline.handleMemoryWarning(
                keepingVisibleAssets: visibleAssetIdentities
            )
            thumbnailReloadGeneration &+= 1
        }
    }

    @ToolbarContentBuilder
    private var readerControlsToolbar: some ToolbarContent {
        if let sessionController = controller.sessionController {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    presentChapterList()
                } label: {
                    Label(
                        "reader.navigation.chapters",
                        systemImage: "list.bullet"
                    )
                }
                .disabled(
                    controller.navigationIndex?.chapterDestinations.isEmpty
                        != false || presentedSheet != nil
                )
                .accessibilityIdentifier("reader.navigation.chapters")
            }

            ToolbarItem(placement: .topBarTrailing) {
                ReaderControlsMenu(
                    selectedMode: sessionController.session.readingMode,
                    selectedDirection: sessionController.session.readingDirection,
                    controller: controller
                )
            }
        }
    }

    private var readerPageProgress: ReaderPageProgress? {
        guard let layout = controller.layout,
              let sessionController = controller.sessionController else {
            return nil
        }

        return ReaderPageProgress(
            layout: layout,
            location: sessionController.session.position.location
        )
    }

    private func readerCommandSet(
        for sessionController: ReaderSessionController
    ) -> ReaderCommandSet {
        let navigationEnabled = presentedSheet == nil
        let hasChapters = controller.navigationIndex?
            .chapterDestinations.isEmpty == false

        return ReaderCommandSet(
            readingDirection: sessionController.session.readingDirection,
            previousPage: ReaderCommandAction(
                isEnabled: navigationEnabled
                    && controller.canMoveToPreviousPage,
                perform: {
                    guard presentedSheet == nil else {
                        return
                    }
                    _ = controller.movePage(.backward)
                }
            ),
            nextPage: ReaderCommandAction(
                isEnabled: navigationEnabled && controller.canMoveToNextPage,
                perform: {
                    guard presentedSheet == nil else {
                        return
                    }
                    _ = controller.movePage(.forward)
                }
            ),
            previousChapter: ReaderCommandAction(
                isEnabled: navigationEnabled
                    && controller.canMoveToPreviousChapter,
                perform: {
                    guard presentedSheet == nil else {
                        return
                    }
                    _ = controller.moveToPreviousChapter()
                }
            ),
            nextChapter: ReaderCommandAction(
                isEnabled: navigationEnabled
                    && controller.canMoveToNextChapter,
                perform: {
                    guard presentedSheet == nil else {
                        return
                    }
                    _ = controller.moveToNextChapter()
                }
            ),
            showChapterList: ReaderCommandAction(
                isEnabled: navigationEnabled && hasChapters,
                perform: presentChapterList
            )
        )
    }

    private func presentChapterList() {
        guard presentedSheet == nil,
              controller.navigationIndex?.chapterDestinations.isEmpty
                == false else {
            return
        }

        presentedSheet = .chapters
    }
}

private enum ReaderPresentedSheet: String, Identifiable {
    case chapters

    var id: String {
        rawValue
    }
}

@MainActor
private struct ReaderControlsMenu: View {
    let selectedMode: ReadingMode
    let selectedDirection: ReadingDirection
    let controller: ReaderScreenController

    var body: some View {
        Menu {
            Section("reader.controls.mode") {
                ForEach(ReadingMode.allCases, id: \.rawValue) { mode in
                    Button {
                        _ = controller.setReadingMode(mode)
                    } label: {
                        ReaderControlOptionLabel(
                            title: mode.controlTitle,
                            isSelected: selectedMode == mode
                        )
                    }
                    .accessibilityIdentifier(mode.accessibilityIdentifier)
                }
            }

            Section("reader.controls.direction") {
                ForEach(ReadingDirection.allCases, id: \.rawValue) { direction in
                    Button {
                        _ = controller.setReadingDirection(direction)
                    } label: {
                        ReaderControlOptionLabel(
                            title: direction.controlTitle,
                            isSelected: selectedDirection == direction
                        )
                    }
                    .accessibilityIdentifier(direction.accessibilityIdentifier)
                }
            }
        } label: {
            Label("reader.controls.menu", systemImage: "text.justify")
        }
        .accessibilityIdentifier("reader.controls.menu")
    }
}

private struct ReaderControlOptionLabel: View {
    let title: LocalizedStringKey
    let isSelected: Bool

    var body: some View {
        Label {
            Text(title)
        } icon: {
            Image(systemName: isSelected ? "checkmark" : "circle")
        }
    }
}

private struct ReaderPageProgress: Equatable {
    let currentPage: Int
    let totalPages: Int

    init?(layout: ReaderLayout, location: ReaderPageLocation) {
        guard let currentPage = layout.pageNumber(for: location) else {
            return nil
        }

        self.currentPage = currentPage
        totalPages = layout.pageCount
    }
}

private struct ReaderPageNavigationView: View {
    let progress: ReaderPageProgress
    let canMoveToPreviousChapter: Bool
    let canMoveToNextChapter: Bool
    let onSelectPage: (Int) -> Void
    let onMoveToPreviousChapter: () -> Void
    let onMoveToNextChapter: () -> Void

    @State private var selectedPage: Double
    @State private var isEditing = false

    init(
        progress: ReaderPageProgress,
        canMoveToPreviousChapter: Bool,
        canMoveToNextChapter: Bool,
        onSelectPage: @escaping (Int) -> Void,
        onMoveToPreviousChapter: @escaping () -> Void,
        onMoveToNextChapter: @escaping () -> Void
    ) {
        self.progress = progress
        self.canMoveToPreviousChapter = canMoveToPreviousChapter
        self.canMoveToNextChapter = canMoveToNextChapter
        self.onSelectPage = onSelectPage
        self.onMoveToPreviousChapter = onMoveToPreviousChapter
        self.onMoveToNextChapter = onMoveToNextChapter
        _selectedPage = State(initialValue: Double(progress.currentPage))
    }

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onMoveToPreviousChapter) {
                Label(
                    "reader.navigation.previousChapter",
                    systemImage: "backward.end"
                )
                .labelStyle(.iconOnly)
            }
            .buttonStyle(.bordered)
            .disabled(!canMoveToPreviousChapter)
            .accessibilityIdentifier("reader.navigation.previousChapter")

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("reader.navigation.pageSlider")
                    Spacer()
                    Text(pageDescription)
                        .monospacedDigit()
                }
                .font(.caption)

                Slider(
                    value: $selectedPage,
                    in: 1...Double(max(progress.totalPages, 2)),
                    step: 1
                ) { editing in
                    isEditing = editing
                    guard !editing else {
                        return
                    }

                    onSelectPage(Int(selectedPage.rounded()))
                }
                .disabled(progress.totalPages <= 1)
                .accessibilityLabel("reader.navigation.pageSlider")
                .accessibilityValue(Text(verbatim: pageDescription))
                .accessibilityIdentifier("reader.navigation.pageSlider")
            }
            .frame(maxWidth: 420)

            Button(action: onMoveToNextChapter) {
                Label(
                    "reader.navigation.nextChapter",
                    systemImage: "forward.end"
                )
                .labelStyle(.iconOnly)
            }
            .buttonStyle(.bordered)
            .disabled(!canMoveToNextChapter)
            .accessibilityIdentifier("reader.navigation.nextChapter")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .foregroundStyle(.white)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        .padding(.horizontal)
        .onChange(of: progress.currentPage) { _, currentPage in
            guard !isEditing else {
                return
            }

            selectedPage = Double(currentPage)
        }
        .accessibilityIdentifier("reader.progress")
    }

    private var pageDescription: String {
        String.localizedStringWithFormat(
            String(localized: "reader.progress.page"),
            displayedPage,
            progress.totalPages
        )
    }

    private var displayedPage: Int {
        isEditing ? Int(selectedPage.rounded()) : progress.currentPage
    }
}

private struct ReaderChapterListView: View {
    let destinations: [ReaderChapterDestination]
    let selectedChapterID: ImportChapterCandidate.ID?
    let onSelect: (ImportChapterCandidate.ID) -> Bool

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(destinations) { destination in
                Button {
                    guard onSelect(destination.chapterID) else {
                        return
                    }

                    dismiss()
                } label: {
                    HStack {
                        Text(destination.displayName)
                            .foregroundStyle(.primary)
                        Spacer()
                        if destination.chapterID == selectedChapterID {
                            Image(systemName: "checkmark")
                                .foregroundStyle(.tint)
                                .accessibilityHidden(true)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .accessibilityIdentifier(
                    "reader.navigation.chapter.\(destination.chapterID.rawValue)"
                )
            }
            .navigationTitle("reader.navigation.chapters")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("common.close") {
                        dismiss()
                    }
                }
            }
        }
        .accessibilityIdentifier("reader.navigation.chapterList")
    }
}

private extension ReadingMode {
    var controlTitle: LocalizedStringKey {
        switch self {
        case .continuous:
            "reader.controls.mode.continuous"
        case .singlePage:
            "reader.controls.mode.singlePage"
        case .spread:
            "reader.controls.mode.spread"
        }
    }

    var accessibilityIdentifier: String {
        "reader.controls.mode.\(rawValue)"
    }
}

private extension ReadingDirection {
    var controlTitle: LocalizedStringKey {
        switch self {
        case .leftToRight:
            "reader.controls.direction.leftToRight"
        case .rightToLeft:
            "reader.controls.direction.rightToLeft"
        }
    }

    var accessibilityIdentifier: String {
        "reader.controls.direction.\(rawValue)"
    }
}

private struct ReaderLoadFailureView: View {
    let failure: ReaderScreenLoadFailure
    let onRetry: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label(titleKey, systemImage: "exclamationmark.triangle")
        } description: {
            Text(descriptionKey)
        } actions: {
            Button("reader.retry", action: onRetry)
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("reader.retry")
        }
        .foregroundStyle(.white)
        .accessibilityIdentifier("reader.error")
    }

    private var titleKey: LocalizedStringKey {
        switch failure {
        case .unavailable:
            "reader.error.unavailable.title"
        case .invalidContent:
            "reader.error.invalid.title"
        }
    }

    private var descriptionKey: LocalizedStringKey {
        switch failure {
        case .unavailable:
            "reader.error.unavailable.description"
        case .invalidContent:
            "reader.error.invalid.description"
        }
    }
}
