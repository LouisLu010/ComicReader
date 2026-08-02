import CoreGraphics

struct ReaderViewportPolicy: Equatable, Sendable {
    static let defaultMinimumSpreadWidth: CGFloat = 900

    let minimumSpreadWidth: CGFloat

    init(
        minimumSpreadWidth: CGFloat = Self.defaultMinimumSpreadWidth
    ) {
        if minimumSpreadWidth.isFinite, minimumSpreadWidth > 0 {
            self.minimumSpreadWidth = minimumSpreadWidth
        } else {
            self.minimumSpreadWidth = Self.defaultMinimumSpreadWidth
        }
    }

    func capability(for viewportSize: CGSize) -> ReaderLayoutCapability {
        guard viewportSize.width.isFinite,
              viewportSize.height.isFinite,
              viewportSize.width > 0,
              viewportSize.height > 0,
              viewportSize.width >= minimumSpreadWidth else {
            return .singlePageOnly
        }

        return .spreadCapable
    }
}
