import Foundation
import SwiftData
import SwiftUI

@main
@MainActor
struct ComicReaderApp: App {
    @State private var bootstrapState: ApplicationBootstrapState

    init() {
        if let request = UITestFixtureBootstrap.requestedFixture() {
            _bootstrapState = State(initialValue: .requested(request))
        } else {
            _bootstrapState = State(
                initialValue: .ready(ApplicationDependencies())
            )
        }
    }

    var body: some Scene {
        WindowGroup {
            ComicReaderApplicationRoot(bootstrapState: $bootstrapState)
        }
        .commands {
            ComicReaderCommands()
        }
    }
}

@MainActor
private struct ComicReaderApplicationRoot: View {
    @Binding var bootstrapState: ApplicationBootstrapState

    @ViewBuilder
    var body: some View {
        switch bootstrapState {
        case .requested, .preparing:
            loadingView
                .task {
                    await loadFixture()
                }
        case let .ready(dependencies):
            ApplicationRoot(
                modelContainer: dependencies.persistence.modelContainer,
                uiTestFixture: dependencies.uiTestFixture,
                libraryState: dependencies.libraryState
            )
            .environment(dependencies.importJobs)
            .environment(dependencies.libraryState)
            .environment(dependencies.persistence)
            .task {
                await dependencies.persistence.openApplicationStore()
            }
        case let .failed(message):
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.largeTitle)
                Text(verbatim: message)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("uiTestFixture.failed")
        }
    }

    private var loadingView: some View {
        ProgressView()
            .accessibilityIdentifier("uiTestFixture.loading")
    }

    private func loadFixture() async {
        guard case let .requested(request) = bootstrapState else {
            return
        }
        bootstrapState = .preparing

        // Bootstrap state is shared by all windows. Finish the in-flight work
        // even if SwiftUI cancels the initiating window's view task.
        do {
            let configuration = try await UITestFixtureBootstrap
                .makeConfiguration(for: request)
            bootstrapState = .ready(
                ApplicationDependencies(uiTestFixture: configuration)
            )
        } catch {
            bootstrapState = .failed(
                "UI test fixture failed to load: \(error.localizedDescription)"
            )
        }
    }
}

@MainActor
private enum ApplicationBootstrapState {
    case requested(UITestFixtureRequest)
    case preparing
    case ready(ApplicationDependencies)
    case failed(String)
}

@MainActor
private struct ApplicationDependencies {
    let importJobs: ImportJobCoordinator
    let libraryState: LibraryStateRepository
    let persistence: LibraryPersistenceController
    let uiTestFixture: UITestFixtureConfiguration?

    init(uiTestFixture: UITestFixtureConfiguration? = nil) {
        self.uiTestFixture = uiTestFixture
        importJobs = uiTestFixture?.importJobs ?? ImportJobCoordinator()
        libraryState = LibraryStateRepository()
        persistence = uiTestFixture.map { configuration in
            LibraryPersistenceController(
                openResult: .opened(configuration.modelContainer)
            )
        } ?? LibraryPersistenceController()
    }
}

@MainActor
private struct ApplicationRoot: View {
    let modelContainer: ModelContainer?
    let uiTestFixture: UITestFixtureConfiguration?
    let libraryState: LibraryStateRepository

    var body: some View {
        Group {
            if let modelContainer {
                sceneRoot(modelContainer: modelContainer)
                    .modelContainer(modelContainer)
            } else {
                sceneRoot(modelContainer: nil)
            }
        }
    }

    private func sceneRoot(modelContainer: ModelContainer?) -> SceneRoot {
        SceneRoot(
            modelContainer: modelContainer,
            readerFeatureServices: uiTestFixture?.readerFeatureServices
                ?? ReaderFeatureServices.applicationSupport(
                    pageOrdersProvider: { comicID in
                        await libraryState.pageOrderOverridesForReader(
                            comicID: comicID
                        )
                    }
                ),
            libraryCatalog: uiTestFixture?.libraryCatalog
        )
    }
}
