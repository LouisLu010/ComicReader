import Observation
import SwiftData

enum LibraryPersistenceStatus: Equatable, Sendable {
    case opening
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
    @ObservationIgnored private let open: @Sendable () ->
        ComicReaderModelContainerOpenResult
    @ObservationIgnored private let reopen: @Sendable () ->
        ComicReaderModelContainerOpenResult
    @ObservationIgnored private var openTask: Task<
        ComicReaderModelContainerOpenResult,
        Never
    >?

    init(
        openResult: ComicReaderModelContainerOpenResult? = nil,
        open: @escaping @Sendable () ->
            ComicReaderModelContainerOpenResult = {
            ComicReaderModelContainer.openApplicationContainer()
        },
        reopen: @escaping @Sendable () ->
            ComicReaderModelContainerOpenResult = {
            ComicReaderModelContainer.openApplicationContainer()
        }
    ) {
        modelContainer = nil
        status = .opening
        recovery = nil
        self.open = open
        self.reopen = reopen

        if let openResult {
            apply(openResult, failureStatus: .recoveryRequired)
        }
    }

    init(previewModelContainer: ModelContainer?) {
        modelContainer = previewModelContainer
        status = previewModelContainer == nil ? .recoveryRequired : .ready
        recovery = nil
        open = {
            ComicReaderModelContainer.openApplicationContainer()
        }
        reopen = {
            ComicReaderModelContainer.openApplicationContainer()
        }
    }

    var canRecoverFailedIndex: Bool {
        recovery != nil
            && (status == .recoveryRequired || status == .recoveryFailed)
    }

    func openApplicationStore() async {
        guard status == .opening else {
            return
        }

        let openTask: Task<ComicReaderModelContainerOpenResult, Never>
        if let existingTask = self.openTask {
            openTask = existingTask
        } else {
            let open = self.open
            let newTask = Task.detached(priority: .userInitiated) {
                open()
            }
            self.openTask = newTask
            openTask = newTask
        }

        let result = await openTask.value
        guard status == .opening else {
            return
        }

        self.openTask = nil
        apply(result, failureStatus: .recoveryRequired)
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

        let reopen = self.reopen
        let result = await Task.detached(priority: .userInitiated) {
            reopen()
        }.value
        apply(result, failureStatus: .recoveryFailed)

        switch result {
        case .opened:
            return true
        case .recoveryRequired:
            return false
        }
    }

    private func apply(
        _ result: ComicReaderModelContainerOpenResult,
        failureStatus: LibraryPersistenceStatus
    ) {
        switch result {
        case let .opened(modelContainer):
            self.modelContainer = modelContainer
            recovery = nil
            status = .ready
        case let .recoveryRequired(recovery):
            modelContainer = nil
            self.recovery = recovery
            status = failureStatus
        }
    }
}
