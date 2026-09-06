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
        WindowGroup(id: "library") {
            ComicReaderApplicationRoot(bootstrapState: $bootstrapState)
        }
        .commands {
            ComicReaderCommands()
        }
        WindowGroup("window.comic.title", id: "comic", for: ComicWindowRequest.self) { $request in
            ComicReaderApplicationRoot(bootstrapState: $bootstrapState, comicWindow: request)
        }
    }
}

@MainActor
private struct ComicReaderApplicationRoot: View {
    @Binding var bootstrapState: ApplicationBootstrapState
    var comicWindow: ComicWindowRequest? = nil

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
                libraryState: dependencies.libraryState,
                comicWindow: comicWindow
            )
            .environment(dependencies.importJobs)
            .environment(dependencies.libraryState)
            .environment(dependencies.persistence)
            .environment(dependencies.privacyLock)
            .environment(dependencies.readerExperience)
            .environment(\.readerDisplayPreferences, dependencies.readerExperience.preferences)
            .environment(\.readerPrivacyLocked, dependencies.privacyLock.isLocked)
            .background(PrivacySceneShield(lock: dependencies.privacyLock))
            .opacity(dependencies.privacyLock.isLocked ? 0 : 1)
            .disabled(dependencies.privacyLock.isLocked)
            .accessibilityHidden(dependencies.privacyLock.isLocked)
            .privacySensitive()
            .focusedSceneValue(\.privacyLockCommand, ReaderCommandAction(
                isEnabled: dependencies.privacyLock.isEnabled && !dependencies.privacyLock.isLocked,
                perform: { dependencies.privacyLock.lock() }
            ))
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
    let privacyLock: PrivacyLockCoordinator
    let readerExperience: ReaderExperienceSettings
    let importJobs: ImportJobCoordinator
    let libraryState: LibraryStateRepository
    let persistence: LibraryPersistenceController
    let uiTestFixture: UITestFixtureConfiguration?

    init(uiTestFixture: UITestFixtureConfiguration? = nil) {
        let defaults = uiTestFixture == nil ? UserDefaults.standard
            : UserDefaults(suiteName: "UITest.Preferences.\(UUID().uuidString)")!
        readerExperience = ReaderExperienceSettings(defaults: defaults)
        var authenticator: any DeviceOwnerAuthenticating = LocalDeviceOwnerAuthenticator()
#if DEBUG
        if uiTestFixture?.startsPrivacyLocked == true {
            defaults.set(true, forKey: PrivacyLockCoordinator.preferenceKey)
            authenticator = UITestDeviceOwnerAuthenticator()
        }
#endif
        privacyLock = PrivacyLockCoordinator(defaults: defaults, authenticator: authenticator)
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
    let comicWindow: ComicWindowRequest?

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
            libraryCatalog: uiTestFixture?.libraryCatalog,
            comicWindow: comicWindow
        )
    }
}
