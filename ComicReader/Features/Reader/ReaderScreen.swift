import Combine
import SwiftUI
import UIKit

@MainActor
struct ReaderScreen: View {
    let comicID: ManagedComicID
    let title: String
    let readerOverrides: ComicReaderOverrides
    let resolvedReaderPreferences: ResolvedReaderPreferences
    let canModifyReaderPreferences: Bool

    @State private var controller: ReaderScreenController
    @State private var visibleAssetSnapshot = ReaderVisibleAssetSnapshot.empty
    @State private var thumbnailReloadGeneration: UInt64 = 0
    @State private var presentedSheet: ReaderPresentedSheet?
    @State private var readerOverridesDraft: ComicReaderOverrides
    @State private var isSavingReaderPreference = false
    @State private var readerPreferenceSaveFailed = false
    @Environment(\.scenePhase) private var scenePhase
    private let preferencesWriter: (any ReaderPreferenceWriting)?

    init(
        comicID: ManagedComicID,
        title: String,
        contentLoader: any ReaderContentLoading,
        progressRecorder: (any ReaderProgressRecording)?,
        persistedProgress: LibraryReadingProgress?,
        readerOverrides: ComicReaderOverrides = .none,
        resolvedReaderPreferences: ResolvedReaderPreferences = .default,
        canModifyReaderPreferences: Bool = false,
        preferencesWriter: (any ReaderPreferenceWriting)? = nil
    ) {
        self.comicID = comicID
        self.title = title
        self.readerOverrides = readerOverrides
        self.resolvedReaderPreferences = resolvedReaderPreferences
        self.canModifyReaderPreferences = canModifyReaderPreferences
        self.preferencesWriter = preferencesWriter
        _controller = State(
            initialValue: ReaderScreenController(
                comicID: comicID,
                contentLoader: contentLoader,
                progressRecorder: progressRecorder,
                persistedProgress: persistedProgress,
                resolvedReaderPreferences: resolvedReaderPreferences
            )
        )
        _presentedSheet = State(initialValue: nil)
        _readerOverridesDraft = State(initialValue: readerOverrides)
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Color.black.ignoresSafeArea()
                content(viewportSize: proxy.size)

                if !controlsAreVisible {
                    ReaderControlsRevealButton(onReveal: toggleControls)
                        .frame(
                            maxWidth: .infinity,
                            maxHeight: .infinity,
                            alignment: .bottomTrailing
                        )
                        .padding()
                }
            }
            .onChange(of: proxy.size, initial: true) { _, size in
                controller.setViewportSize(size)
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(
            controlsAreVisible ? .visible : .hidden,
            for: .navigationBar
        )
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
        .onChange(
            of: resolvedReaderPreferences,
            initial: true
        ) { _, preferences in
            _ = controller.applyResolvedReaderPreferences(preferences)
        }
        .onChange(of: readerOverrides, initial: true) { _, overrides in
            guard !isSavingReaderPreference else {
                return
            }

            readerOverridesDraft = overrides
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
            if controlsAreVisible,
               let progress = readerPageProgress,
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
                        readingDirection: layout.direction,
                        canMoveToPreviousPage: (
                            controller.canMoveToPreviousPage
                        ),
                        canMoveToNextPage: controller.canMoveToNextPage,
                        canMoveToPreviousChapter: (
                            controller.canMoveToPreviousChapter
                        ),
                        canMoveToNextChapter: controller.canMoveToNextChapter,
                        onSelectPage: { pageNumber in
                            _ = controller.jumpToPage(pageNumber)
                        },
                        onMoveToPreviousPage: {
                            _ = controller.movePage(.backward)
                        },
                        onMoveToNextPage: {
                            _ = controller.movePage(.forward)
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
        .alert(
            "reader.preferences.saveFailed.title",
            isPresented: $readerPreferenceSaveFailed
        ) {
            Button("common.ok", role: .cancel) {}
        } message: {
            Text("reader.preferences.saveFailed.message")
        }
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
                    tapAreas: controller.resolvedReaderPreferences.tapAreas,
                    controlsAreVisible: controlsAreVisible,
                    isTapInteractionBlocked: presentedSheet != nil,
                    onTapAction: handleTapAction,
                    onContinueChapterBoundary: { chapterID in
                        _ = controller.jumpToChapter(chapterID)
                    },
                    visibleAssetSnapshot: $visibleAssetSnapshot
                )
                .id(
                    ReaderContentIdentity(
                        mode: layout.effectiveMode,
                        direction: layout.direction
                    )
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
        if controlsAreVisible,
           controller.sessionController != nil {
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
                    overrides: readerOverridesDraft,
                    onSelectMode: setReadingModeOverride,
                    onSelectDirection: setReadingDirectionOverride
                )
                .disabled(
                    !canModifyReaderPreferences
                        || isSavingReaderPreference
                        || preferencesWriter == nil
                )
            }

            ToolbarItem(placement: .topBarTrailing) {
                Button(action: toggleControls) {
                    Label(
                        "reader.controls.hide",
                        systemImage: "eye.slash"
                    )
                }
                .disabled(presentedSheet != nil)
                .accessibilityIdentifier("reader.controls.hide")
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

    private var controlsAreVisible: Bool {
        controller.sessionController?.session.controlsAreVisible ?? true
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
            ),
            toggleControls: ReaderCommandAction(
                isEnabled: presentedSheet == nil,
                perform: toggleControls
            )
        )
    }

    private func handleTapAction(_ action: ReaderTapAction) {
        guard presentedSheet == nil else {
            return
        }

        switch action {
        case let .movePage(step):
            _ = controller.movePage(step)
        case .toggleControls:
            toggleControls()
        case .ignore:
            break
        }
    }

    private func toggleControls() {
        guard presentedSheet == nil,
              let sessionController = controller.sessionController else {
            return
        }

        sessionController.toggleControls()
    }

    private func presentChapterList() {
        guard presentedSheet == nil,
              controller.navigationIndex?.chapterDestinations.isEmpty
                == false else {
            return
        }

        presentedSheet = .chapters
    }

    private func setReadingModeOverride(_ mode: ReadingMode?) {
        saveReaderPreference(.mode(mode))
    }

    private func setReadingDirectionOverride(_ direction: ReadingDirection?) {
        saveReaderPreference(.direction(direction))
    }

    private func saveReaderPreference(
        _ mutation: ComicReaderPreferenceMutation
    ) {
        guard canModifyReaderPreferences,
              !isSavingReaderPreference,
              let preferencesWriter else {
            return
        }

        var updatedOverrides = readerOverridesDraft
        mutation.apply(to: &updatedOverrides)
        guard updatedOverrides != readerOverridesDraft else {
            return
        }

        readerOverridesDraft = updatedOverrides
        isSavingReaderPreference = true
        readerPreferenceSaveFailed = false
        Task { @MainActor in
            let didSave = await mutation.persist(
                using: preferencesWriter,
                comicID: comicID
            )
            if !didSave {
                readerOverridesDraft = readerOverrides
                readerPreferenceSaveFailed = true
            }
            isSavingReaderPreference = false
        }
    }
}

private enum ReaderPresentedSheet: String, Identifiable {
    case chapters

    var id: String {
        rawValue
    }
}

/// 布局语义变化时重建阅读内容状态，让连续模式在首帧就带着恢复请求。
private struct ReaderContentIdentity: Hashable {
    let mode: ReadingMode
    let direction: ReadingDirection
}

private enum ComicReaderPreferenceMutation {
    case mode(ReadingMode?)
    case direction(ReadingDirection?)

    func apply(to overrides: inout ComicReaderOverrides) {
        switch self {
        case let .mode(mode):
            overrides.readingMode = mode
        case let .direction(direction):
            overrides.readingDirection = direction
        }
    }

    @MainActor
    func persist(
        using writer: any ReaderPreferenceWriting,
        comicID: ManagedComicID
    ) async -> Bool {
        switch self {
        case let .mode(mode):
            await writer.setReadingModeOverride(mode, for: comicID)
        case let .direction(direction):
            await writer.setReadingDirectionOverride(direction, for: comicID)
        }
    }
}

private struct ReaderControlsRevealButton: View {
    let onReveal: () -> Void

    var body: some View {
        Button(action: onReveal) {
            Label(
                "reader.controls.show",
                systemImage: "rectangle.3.group"
            )
            .labelStyle(.iconOnly)
        }
        .buttonStyle(.borderedProminent)
        .accessibilityIdentifier("reader.controls.reveal")
    }
}

@MainActor
private struct ReaderControlsMenu: View {
    let overrides: ComicReaderOverrides
    let onSelectMode: (ReadingMode?) -> Void
    let onSelectDirection: (ReadingDirection?) -> Void

    var body: some View {
        Menu {
            Section("reader.controls.mode") {
                Button {
                    onSelectMode(nil)
                } label: {
                    ReaderControlOptionLabel(
                        title: "reader.controls.followGlobal",
                        isSelected: overrides.readingMode == nil
                    )
                }
                .accessibilityIdentifier("reader.controls.mode.followGlobal")
                .accessibilityAddTraits(
                    overrides.readingMode == nil ? .isSelected : []
                )

                ForEach(ReadingMode.allCases, id: \.rawValue) { mode in
                    Button {
                        onSelectMode(mode)
                    } label: {
                        ReaderControlOptionLabel(
                            title: mode.controlTitle,
                            isSelected: overrides.readingMode == mode
                        )
                    }
                    .accessibilityIdentifier(mode.accessibilityIdentifier)
                    .accessibilityLabel(mode.controlTitle)
                    .accessibilityAddTraits(
                        overrides.readingMode == mode ? .isSelected : []
                    )
                }
            }

            Section("reader.controls.direction") {
                Button {
                    onSelectDirection(nil)
                } label: {
                    ReaderControlOptionLabel(
                        title: "reader.controls.followGlobal",
                        isSelected: overrides.readingDirection == nil
                    )
                }
                .accessibilityIdentifier(
                    "reader.controls.direction.followGlobal"
                )
                .accessibilityAddTraits(
                    overrides.readingDirection == nil ? .isSelected : []
                )

                ForEach(ReadingDirection.allCases, id: \.rawValue) { direction in
                    Button {
                        onSelectDirection(direction)
                    } label: {
                        ReaderControlOptionLabel(
                            title: direction.controlTitle,
                            isSelected: overrides.readingDirection == direction
                        )
                    }
                    .accessibilityIdentifier(direction.accessibilityIdentifier)
                    .accessibilityLabel(direction.controlTitle)
                    .accessibilityAddTraits(
                        overrides.readingDirection == direction
                            ? .isSelected
                            : []
                    )
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
    let readingDirection: ReadingDirection
    let canMoveToPreviousPage: Bool
    let canMoveToNextPage: Bool
    let canMoveToPreviousChapter: Bool
    let canMoveToNextChapter: Bool
    let onSelectPage: (Int) -> Void
    let onMoveToPreviousPage: () -> Void
    let onMoveToNextPage: () -> Void
    let onMoveToPreviousChapter: () -> Void
    let onMoveToNextChapter: () -> Void

    @State private var selectedPage: Double
    @State private var isEditing = false

    init(
        progress: ReaderPageProgress,
        readingDirection: ReadingDirection,
        canMoveToPreviousPage: Bool,
        canMoveToNextPage: Bool,
        canMoveToPreviousChapter: Bool,
        canMoveToNextChapter: Bool,
        onSelectPage: @escaping (Int) -> Void,
        onMoveToPreviousPage: @escaping () -> Void,
        onMoveToNextPage: @escaping () -> Void,
        onMoveToPreviousChapter: @escaping () -> Void,
        onMoveToNextChapter: @escaping () -> Void
    ) {
        self.progress = progress
        self.readingDirection = readingDirection
        self.canMoveToPreviousPage = canMoveToPreviousPage
        self.canMoveToNextPage = canMoveToNextPage
        self.canMoveToPreviousChapter = canMoveToPreviousChapter
        self.canMoveToNextChapter = canMoveToNextChapter
        self.onSelectPage = onSelectPage
        self.onMoveToPreviousPage = onMoveToPreviousPage
        self.onMoveToNextPage = onMoveToNextPage
        self.onMoveToPreviousChapter = onMoveToPreviousChapter
        self.onMoveToNextChapter = onMoveToNextChapter
        _selectedPage = State(initialValue: Double(progress.currentPage))
    }

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                Button(action: onMoveToPreviousChapter) {
                    Label(
                        "reader.navigation.previousChapter",
                        systemImage: previousChapterSystemImage
                    )
                    .labelStyle(.iconOnly)
                }
                .buttonStyle(.bordered)
                .disabled(!canMoveToPreviousChapter)
                .accessibilityIdentifier("reader.navigation.previousChapter")

                Button(action: onMoveToPreviousPage) {
                    Label(
                        "reader.navigation.previousPage",
                        systemImage: previousPageSystemImage
                    )
                    .labelStyle(.iconOnly)
                }
                .buttonStyle(.bordered)
                .disabled(!canMoveToPreviousPage)
                .accessibilityIdentifier("reader.navigation.previousPage")

                Spacer(minLength: 24)

                Button(action: onMoveToNextPage) {
                    Label(
                        "reader.navigation.nextPage",
                        systemImage: nextPageSystemImage
                    )
                    .labelStyle(.iconOnly)
                }
                .buttonStyle(.bordered)
                .disabled(!canMoveToNextPage)
                .accessibilityIdentifier("reader.navigation.nextPage")

                Button(action: onMoveToNextChapter) {
                    Label(
                        "reader.navigation.nextChapter",
                        systemImage: nextChapterSystemImage
                    )
                    .labelStyle(.iconOnly)
                }
                .buttonStyle(.bordered)
                .disabled(!canMoveToNextChapter)
                .accessibilityIdentifier("reader.navigation.nextChapter")
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("reader.navigation.pageSlider")
                    Spacer()
                    Text(pageDescription)
                        .monospacedDigit()
                        .accessibilityIdentifier(
                            "reader.navigation.currentPage"
                        )
                        .accessibilityValue(
                            Text(
                                verbatim: "\(displayedPage)/\(progress.totalPages)"
                            )
                        )
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
        }
        .frame(maxWidth: 480)
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
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("reader.progress")
    }

    private var previousPageSystemImage: String {
        readingDirection == .leftToRight ? "chevron.left" : "chevron.right"
    }

    private var nextPageSystemImage: String {
        readingDirection == .leftToRight ? "chevron.right" : "chevron.left"
    }

    private var previousChapterSystemImage: String {
        readingDirection == .leftToRight ? "backward.end" : "forward.end"
    }

    private var nextChapterSystemImage: String {
        readingDirection == .leftToRight ? "forward.end" : "backward.end"
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

extension ReadingMode {
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

extension ReadingDirection {
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
