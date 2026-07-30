import SwiftUI

@main
struct ComicReaderApp: App {
    var body: some Scene {
        WindowGroup {
            SceneRoot()
        }
        .commands {
            ComicReaderCommands()
        }
    }
}
