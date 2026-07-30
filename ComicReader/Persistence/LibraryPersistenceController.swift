import Observation
import SwiftData

enum LibraryPersistenceStatus: Equatable, Sendable {
    case ready
    case recoveryRequired
    case recovering
    case recoveryFailed
}

@MainActor
@Observable
final class LibraryPersistenceController {
    private(set) var modelContainer: ModelContainer?
    private(set) var status: LibraryPersistenceStatus

    @ObservationIgnored private var recovery: ComicReaderModelStoreRecovery?
    @ObservationIgnored private let reopen: () -> ComicReaderModelContainerOpenResult

    init(
        openResult: ComicReaderModelContainerOpenResult =
            ComicReaderModelContainer.openApplicationContainer(),
        reopen: @escaping () -> ComicReaderModelContainerOpenResult = {
            ComicReaderModelContainer.openApplicationContainer()
        }
    ) {
        self.reopen = reopen

        switch openResult {
        case let .opened(modelContainer):
            self.modelContainer = modelContainer
            status = .ready
            recovery = nil
        case let .recoveryRequired(recovery):
            modelContainer = nil
            status = .recoveryRequired
            self.recovery = recovery
        }
    }

    init(previewModelContainer: ModelContainer?) {
        modelContainer = previewModelContainer
        status = previewModelContainer == nil ? .recoveryRequired : .ready
        recovery = nil
        reopen = {
            ComicReaderModelContainer.openApplicationContainer()
        }
    }

    var canRecoverFailedIndex: Bool {
        recovery != nil
            && (status == .recoveryRequired || status == .recoveryFailed)
    }

    @discardableResult
    func recoverFailedIndex() async -> Bool {
        guard canRecoverFailedIndex, let recovery else {
            return false
        }

        status = .recovering

        do {
            _ = try await Task.detached(priority: .userInitiated) {
                try ComicReaderModelContainer.deleteFailedStoreIndex(recovery)
            }.value
        } catch {
            status = .recoveryFailed
            return false
        }

        switch reopen() {
        case let .opened(modelContainer):
            self.modelContainer = modelContainer
            self.recovery = nil
            status = .ready
            return true
        case let .recoveryRequired(recovery):
            modelContainer = nil
            self.recovery = recovery
            status = .recoveryFailed
            return false
        }
    }
}
