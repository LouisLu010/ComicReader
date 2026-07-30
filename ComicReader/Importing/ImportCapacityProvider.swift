import Foundation

protocol ImportCapacityProviding: Sendable {
    func availableBytes(at destinationRoot: URL) throws -> Int64
}

enum ImportCapacityError: Error, Equatable, Sendable {
    case unavailable
}

struct ImportantUsageCapacityProvider: ImportCapacityProviding {
    func availableBytes(at destinationRoot: URL) throws -> Int64 {
        let values = try destinationRoot.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey]
        )
        guard let capacity = values.volumeAvailableCapacityForImportantUsage,
              capacity >= 0 else {
            throw ImportCapacityError.unavailable
        }

        return Int64(capacity)
    }
}
