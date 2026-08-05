import SwiftUI

struct ReaderPageImageLifecycle: Equatable, Sendable {
    private(set) var generation: UInt64 = 0
    private(set) var isVisible = false

    mutating func didAppear() {
        guard !isVisible else {
            return
        }

        isVisible = true
        advanceGeneration()
    }

    mutating func didDisappear() {
        guard isVisible else {
            return
        }

        isVisible = false
        advanceGeneration()
    }

    func accepts(generation: UInt64) -> Bool {
        isVisible && self.generation == generation
    }

    private mutating func advanceGeneration() {
        generation &+= 1
    }
}

private struct ReaderViewportVisiblePageIDsKey: EnvironmentKey {
    static let defaultValue: Set<ImportPageCandidate.ID> = []
}

extension EnvironmentValues {
    var readerViewportVisiblePageIDs: Set<ImportPageCandidate.ID> {
        get { self[ReaderViewportVisiblePageIDsKey.self] }
        set { self[ReaderViewportVisiblePageIDsKey.self] = newValue }
    }
}
