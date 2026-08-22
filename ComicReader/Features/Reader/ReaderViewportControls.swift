import SwiftUI
import UIKit

enum ReaderViewportControlAction: Equatable, Sendable {
    case zoomOut
    case zoomIn
    case panLeft
    case panRight
    case panUp
    case panDown
}

struct ReaderViewportControlRequest: Equatable, Sendable {
    let generation: UInt64
    let action: ReaderViewportControlAction
}

struct ReaderViewportControlState: Equatable, Sendable {
    let isAvailable: Bool
    let zoomPercentage: Int
    let handledGeneration: UInt64?
    let canZoomOut: Bool
    let canZoomIn: Bool
    let canPanLeft: Bool
    let canPanRight: Bool
    let canPanUp: Bool
    let canPanDown: Bool

    static let unavailable = ReaderViewportControlState(
        isAvailable: false,
        zoomPercentage: 100,
        handledGeneration: nil,
        canZoomOut: false,
        canZoomIn: false,
        canPanLeft: false,
        canPanRight: false,
        canPanUp: false,
        canPanDown: false
    )

    var zoomAccessibilityValue: String {
        "\(zoomPercentage)%"
    }
}

struct ReaderViewportControls: View {
    let state: ReaderViewportControlState
    let onAction: (ReaderViewportControlAction) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ReaderZoomControls(
                value: state.zoomAccessibilityValue,
                canZoomOut: state.canZoomOut,
                canZoomIn: state.canZoomIn,
                onZoomOut: { onAction(.zoomOut) },
                onZoomIn: { onAction(.zoomIn) }
            )

            ReaderPanControls(
                canMoveLeft: state.canPanLeft,
                canMoveRight: state.canPanRight,
                canMoveUp: state.canPanUp,
                canMoveDown: state.canPanDown,
                onMoveLeft: { onAction(.panLeft) },
                onMoveRight: { onAction(.panRight) },
                onMoveUp: { onAction(.panUp) },
                onMoveDown: { onAction(.panDown) }
            )
        }
    }
}

private struct ReaderZoomControls: View {
    let value: String
    let canZoomOut: Bool
    let canZoomIn: Bool
    let onZoomOut: () -> Void
    let onZoomIn: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onZoomOut) {
                Label("reader.zoom.out", systemImage: "minus.magnifyingglass")
                    .labelStyle(.iconOnly)
            }
            .disabled(!canZoomOut)
            .accessibilityIdentifier("reader.zoom.out")

            Text(verbatim: value)
                .monospacedDigit()
                .frame(minWidth: 48)
                .accessibilityLabel("reader.zoom.value")
                .accessibilityValue(Text(verbatim: value))
                .accessibilityIdentifier("reader.zoom.value")

            Button(action: onZoomIn) {
                Label("reader.zoom.in", systemImage: "plus.magnifyingglass")
                    .labelStyle(.iconOnly)
            }
            .disabled(!canZoomIn)
            .accessibilityIdentifier("reader.zoom.in")
        }
        .buttonStyle(.bordered)
        .padding(8)
        .foregroundStyle(.white)
        .background(.ultraThinMaterial, in: Capsule())
        .accessibilityElement(children: .contain)
    }
}

private struct ReaderPanControls: View {
    let canMoveLeft: Bool
    let canMoveRight: Bool
    let canMoveUp: Bool
    let canMoveDown: Bool
    let onMoveLeft: () -> Void
    let onMoveRight: () -> Void
    let onMoveUp: () -> Void
    let onMoveDown: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            panButton(
                String(localized: "reader.pan.left"),
                identifier: "reader.pan.left",
                systemImage: "arrow.left",
                isEnabled: canMoveLeft,
                action: onMoveLeft
            )
            panButton(
                String(localized: "reader.pan.right"),
                identifier: "reader.pan.right",
                systemImage: "arrow.right",
                isEnabled: canMoveRight,
                action: onMoveRight
            )
            panButton(
                String(localized: "reader.pan.up"),
                identifier: "reader.pan.up",
                systemImage: "arrow.up",
                isEnabled: canMoveUp,
                action: onMoveUp
            )
            panButton(
                String(localized: "reader.pan.down"),
                identifier: "reader.pan.down",
                systemImage: "arrow.down",
                isEnabled: canMoveDown,
                action: onMoveDown
            )
        }
        .padding(8)
        .foregroundStyle(.white)
        .background(.ultraThinMaterial, in: Capsule())
    }

    private func panButton(
        _ accessibilityLabel: String,
        identifier: String,
        systemImage: String,
        isEnabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        ReaderUIKitPanButton(
            accessibilityLabel: accessibilityLabel,
            accessibilityIdentifier: identifier,
            systemImage: systemImage,
            isEnabled: isEnabled,
            action: action
        )
        .frame(width: 44, height: 44)
        // 同步 SwiftUI 与 UIKit 的禁用语义。
        .disabled(!isEnabled)
    }
}

@MainActor
private struct ReaderUIKitPanButton: UIViewRepresentable {
    let accessibilityLabel: String
    let accessibilityIdentifier: String
    let systemImage: String
    let isEnabled: Bool
    let action: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(action: action)
    }

    func makeUIView(context: Context) -> UIButton {
        let button = UIButton(type: .system)
        button.addTarget(
            context.coordinator,
            action: #selector(Coordinator.performPrimaryAction),
            for: .primaryActionTriggered
        )
        return button
    }

    func updateUIView(_ uiView: UIButton, context: Context) {
        context.coordinator.action = action

        var configuration = UIButton.Configuration.bordered()
        configuration.image = UIImage(systemName: systemImage)
        configuration.baseForegroundColor = .white
        uiView.configuration = configuration
        uiView.isEnabled = isEnabled
        uiView.isPointerInteractionEnabled = true
        uiView.accessibilityLabel = accessibilityLabel
        uiView.accessibilityIdentifier = accessibilityIdentifier
    }

    static func dismantleUIView(
        _ uiView: UIButton,
        coordinator: Coordinator
    ) {
        uiView.removeTarget(
            coordinator,
            action: #selector(Coordinator.performPrimaryAction),
            for: .primaryActionTriggered
        )
    }

    @MainActor
    final class Coordinator: NSObject {
        var action: () -> Void

        init(action: @escaping () -> Void) {
            self.action = action
        }

        @objc func performPrimaryAction() {
            action()
        }
    }
}
