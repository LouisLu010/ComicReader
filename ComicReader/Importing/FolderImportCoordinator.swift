import Foundation
import Observation

enum FolderImportStatus: Equatable {
    case idle
    case selected(names: [String])
    case failed
}

@MainActor
@Observable
final class FolderImportCoordinator {
    private(set) var status: FolderImportStatus = .idle

    func handle(_ result: Result<[URL], Error>) {
        switch result {
        case let .success(urls):
            let names = urls
                .map(\.lastPathComponent)
                .filter { !$0.isEmpty }
                .sorted { $0.localizedStandardCompare($1) == .orderedAscending }

            status = names.isEmpty ? .failed : .selected(names: names)
        case .failure:
            status = .failed
        }
    }

    func reset() {
        status = .idle
    }
}
