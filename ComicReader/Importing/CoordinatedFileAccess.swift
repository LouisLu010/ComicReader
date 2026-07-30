import Foundation

struct CoordinatedFileAccess {
    func read<Value>(
        at url: URL,
        _ accessor: (URL) throws -> Value
    ) throws -> Value {
        // 目录级 security scope 由导入引擎在整个复制期间持有。
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?
        var accessResult: Swift.Result<Value, Error>?

        coordinator.coordinate(
            readingItemAt: url,
            options: [],
            error: &coordinationError
        ) { coordinatedURL in
            accessResult = Swift.Result {
                try accessor(coordinatedURL)
            }
        }

        if let coordinationError {
            throw coordinationError
        }

        guard let accessResult else {
            throw CocoaError(.fileReadUnknown)
        }

        return try accessResult.get()
    }
}
