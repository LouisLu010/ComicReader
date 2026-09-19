import Foundation
import SwiftUI
import UIKit

/// 每次打开均有独立窗口身份，同一本漫画也可在两个窗口各自导航。
struct ComicWindowRequest: Codable, Hashable, Sendable {
    let comicID: UUID
    let instanceID: UUID

    init(comicID: UUID, instanceID: UUID = UUID()) {
        self.comicID = comicID
        self.instanceID = instanceID
    }
}

struct ComicWindowContent: View {
    let request: ComicWindowRequest
    @Environment(LibraryCatalogCoordinator.self) private var catalog
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        NavigationStack {
            Group {
                if let comic = catalog.comics.first(where: { $0.id.rawValue == request.comicID }) {
                    ComicDetailView(comic: comic, thumbnailURL: catalog.thumbnailURL(for: comic))
                } else if catalog.state == .idle || catalog.state == .loading {
                    ProgressView("library.loading")
                } else {
                    ContentUnavailableView {
                        Label("window.comic.unavailable", systemImage: "book.closed")
                    } description: {
                        EmptyView()
                    } actions: {
                        Button("common.retry") { Task { await catalog.reload() } }
                    }
                }
            }
            // 工具栏必须位于导航栈内部才会显示在导航栏；阅读页压栈后由其自身工具栏接管。
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        dismissWindow(id: "comic", value: request)
                    } label: {
                        Label("common.close", systemImage: "xmark")
                    }
                    .accessibilityIdentifier("window.closeComic")
                }
            }
        }
    }
}

/// 把窗口身份写到 UIKit 窗口上，供多窗口测试按窗口定位元素，
/// 不把整个导航栈包装成一个无障碍元素。
struct SceneWindowIdentity: UIViewRepresentable {
    let identifier: String

    func makeUIView(context: Context) -> IdentityView {
        IdentityView(identifier: identifier)
    }

    func updateUIView(_ view: IdentityView, context: Context) {
        view.identifier = identifier
        view.window?.accessibilityIdentifier = identifier
    }

    final class IdentityView: UIView {
        var identifier: String

        init(identifier: String) {
            self.identifier = identifier
            super.init(frame: .zero)
            isUserInteractionEnabled = false
            isAccessibilityElement = false
        }

        required init?(coder: NSCoder) { nil }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            window?.accessibilityIdentifier = identifier
        }
    }
}
