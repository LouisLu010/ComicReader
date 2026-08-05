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

    mutating func didReceiveMemoryWarning() {
        advanceGeneration()
    }

    func accepts(generation: UInt64) -> Bool {
        isVisible && self.generation == generation
    }

    private mutating func advanceGeneration() {
        generation &+= 1
    }
}

private struct ReaderImageMemoryWarningGenerationKey: EnvironmentKey {
    static let defaultValue: UInt64 = 0
}

extension EnvironmentValues {
    var readerImageMemoryWarningGeneration: UInt64 {
        get { self[ReaderImageMemoryWarningGenerationKey.self] }
        set { self[ReaderImageMemoryWarningGenerationKey.self] = newValue }
    }
}
