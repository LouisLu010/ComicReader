import Combine
import SwiftUI
import UIKit

@MainActor
struct ReaderScreen: View {
    let title: String

    @State private var controller: ReaderScreenController
    @State private var visibleAssetSnapshot = ReaderVisibleAssetSnapshot.empty
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
        }
        .onDisappear {
            visibleAssetSnapshot = .empty
            flushProgress()
        }
        .toolbar {
            readerControlsToolbar
        }
        .safeAreaInset(edge: .bottom, spacing: 12) {
            if let progress = readerPageProgress {
                ReaderPageProgressView(progress: progress)
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
                    visibleAssetSnapshot: $visibleAssetSnapshot
                )
                .environment(
                    \.readerViewportVisiblePageIDs,
                    visibleAssetSnapshot.pageIDs
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
        }
    }

    @ToolbarContentBuilder
    private var readerControlsToolbar: some ToolbarContent {
        if let sessionController = controller.sessionController {
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

private struct ReaderPageProgressView: View {
    let progress: ReaderPageProgress

    var body: some View {
        HStack(spacing: 10) {
            Text(
                String.localizedStringWithFormat(
                    String(localized: "reader.progress.page"),
                    progress.currentPage,
                    progress.totalPages
                )
            )
            .font(.caption.monospacedDigit())

            ProgressView(
                value: Double(progress.currentPage),
                total: Double(progress.totalPages)
            )
            .progressViewStyle(.linear)
            .frame(width: 96)
            .accessibilityHidden(true)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .foregroundStyle(.white)
        .background(.ultraThinMaterial, in: Capsule())
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("reader.progress")
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
