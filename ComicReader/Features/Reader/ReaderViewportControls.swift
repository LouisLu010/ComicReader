import SwiftUI

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
                "reader.pan.left",
                identifier: "reader.pan.left",
                systemImage: "arrow.left",
                isEnabled: canMoveLeft,
                action: onMoveLeft
            )
            panButton(
                "reader.pan.right",
                identifier: "reader.pan.right",
                systemImage: "arrow.right",
                isEnabled: canMoveRight,
                action: onMoveRight
            )
            panButton(
                "reader.pan.up",
                identifier: "reader.pan.up",
                systemImage: "arrow.up",
                isEnabled: canMoveUp,
                action: onMoveUp
            )
            panButton(
                "reader.pan.down",
                identifier: "reader.pan.down",
                systemImage: "arrow.down",
                isEnabled: canMoveDown,
                action: onMoveDown
            )
        }
        .buttonStyle(.bordered)
        .padding(8)
        .foregroundStyle(.white)
        .background(.ultraThinMaterial, in: Capsule())
    }

    private func panButton(
        _ title: LocalizedStringKey,
        identifier: String,
        systemImage: String,
        isEnabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .labelStyle(.iconOnly)
        }
        .disabled(!isEnabled)
        .accessibilityIdentifier(identifier)
    }
}
