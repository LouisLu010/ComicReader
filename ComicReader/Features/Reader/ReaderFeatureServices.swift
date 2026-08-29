import SwiftUI

struct ReaderFeatureServices: Sendable {
    let contentLoader: any ReaderContentLoading

    init(contentLoader: any ReaderContentLoading) {
        self.contentLoader = contentLoader
    }

    static func applicationSupport(
        pageOrdersProvider: ReaderPageOrdersProvider = { _ in [:] }
    ) -> ReaderFeatureServices? {
        guard let layout = try? JSONImportJobStore.applicationSupportLayout() else {
            return nil
        }

        return ReaderFeatureServices(
            contentLoader: FileSystemReaderContentLoader(
                layout: layout,
                pageOrdersProvider: pageOrdersProvider
            )
        )
    }
}

private struct ReaderFeatureServicesKey: EnvironmentKey {
    static let defaultValue: ReaderFeatureServices? = nil
}

extension EnvironmentValues {
    var readerFeatureServices: ReaderFeatureServices? {
        get { self[ReaderFeatureServicesKey.self] }
        set { self[ReaderFeatureServicesKey.self] = newValue }
    }
}
