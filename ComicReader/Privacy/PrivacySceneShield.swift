import SwiftUI
import UIKit

/// 独立高层窗口覆盖阅读器及其所有 sheet，避免只遮住导航栈却泄露弹窗内容。
struct PrivacySceneShield: UIViewRepresentable {
    let lock: PrivacyLockCoordinator

    func makeUIView(context: Context) -> ShieldInstallerView {
        ShieldInstallerView(lock: lock)
    }

    func updateUIView(_ view: ShieldInstallerView, context: Context) {
        // 明确订阅 Observable 状态，使认证结果同步到 UIKit 遮罩。
        _ = lock.isEnabled
        _ = lock.isLocked
        _ = lock.isAuthenticating
        _ = lock.authenticationFailed
        view.refresh()
    }

    static func dismantleUIView(_ view: ShieldInstallerView, coordinator: ()) {
        view.detach()
    }
}

@MainActor
final class ShieldInstallerView: UIView {
    private let lock: PrivacyLockCoordinator
    private let sceneID = UUID()
    private weak var attachedScene: UIWindowScene?
    private weak var originalKeyWindow: UIWindow?
    private var shield: UIWindow?
    private var hiddenAccessibilityWindows: [(UIWindow, Bool)] = []
    private var activity = PrivacyLockCoordinator.SceneActivity.inactive

    init(lock: PrivacyLockCoordinator) {
        self.lock = lock
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        isAccessibilityElement = false
    }

    required init?(coder: NSCoder) { nil }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard let scene = window?.windowScene, attachedScene !== scene else { return }
        detach()
        attachedScene = scene
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(willDeactivate), name: UIScene.willDeactivateNotification, object: scene)
        center.addObserver(self, selector: #selector(didActivate), name: UIScene.didActivateNotification, object: scene)
        center.addObserver(self, selector: #selector(didEnterBackground), name: UIScene.didEnterBackgroundNotification, object: scene)
        activity = scene.activationState == .foregroundActive ? .active : .inactive
        lock.updateScene(sceneID, activity: activity)
        refresh()
    }

    @objc private func willDeactivate() {
        activity = .inactive
        lock.updateScene(sceneID, activity: activity)
        refresh()
    }

    @objc private func didActivate() {
        activity = .active
        lock.updateScene(sceneID, activity: activity)
        refresh()
    }

    @objc private func didEnterBackground() {
        activity = .background
        lock.updateScene(sceneID, activity: activity)
        refresh()
    }

    func refresh() {
        guard let scene = attachedScene else { return }
        let needsShield = lock.isEnabled && (lock.isLocked || activity != .active)
        guard needsShield else {
            let wasKey = shield?.isKeyWindow == true
            shield?.isHidden = true
            if wasKey { originalKeyWindow?.makeKey() }
            shield = nil
            restoreAccessibility()
            return
        }
        if shield == nil {
            originalKeyWindow = scene.windows.first(where: \.isKeyWindow)
            let overlay = UIWindow(windowScene: scene)
            overlay.windowLevel = UIWindow.Level(rawValue: UIWindow.Level.alert.rawValue + 1)
            overlay.backgroundColor = .systemBackground
            shield = overlay
        }
        for window in scene.windows where window !== shield {
            if !hiddenAccessibilityWindows.contains(where: { $0.0 === window }) {
                hiddenAccessibilityWindows.append((window, window.accessibilityElementsHidden))
                window.accessibilityElementsHidden = true
            }
        }
        shield?.rootViewController = UIHostingController(rootView:
            PrivacyShieldContent(lock: lock, allowsUnlock: activity == .active)
        )
        shield?.isHidden = false
        shield?.rootViewController?.view.accessibilityViewIsModal = true
        if activity == .active, lock.isLocked { shield?.makeKey() }
    }

    func detach() {
        NotificationCenter.default.removeObserver(self)
        shield?.isHidden = true
        shield = nil
        restoreAccessibility()
        if attachedScene != nil { lock.removeScene(sceneID) }
        attachedScene = nil
    }

    private func restoreAccessibility() {
        for (window, wasHidden) in hiddenAccessibilityWindows {
            window.accessibilityElementsHidden = wasHidden
        }
        hiddenAccessibilityWindows.removeAll()
    }
}

private struct PrivacyShieldContent: View {
    let lock: PrivacyLockCoordinator
    let allowsUnlock: Bool

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "lock.shield")
                .font(.largeTitle)
                .accessibilityHidden(true)
            Text("privacy.locked").font(.title)
            if allowsUnlock {
                Button("privacy.unlock") { Task { await lock.unlock() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(lock.isAuthenticating)
                    .accessibilityIdentifier("privacy.unlock")
                if lock.isAuthenticating { ProgressView() }
                if lock.authenticationFailed {
                    Text("privacy.authentication.failed").multilineTextAlignment(.center)
                }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(uiColor: .systemBackground))
        .accessibilityIdentifier("privacy.shield")
    }
}

struct PrivacySettingsSection: View {
    @Environment(PrivacyLockCoordinator.self) private var lock

    var body: some View {
        Section("privacy.settings.title") {
            Toggle("privacy.settings.enabled", isOn: Binding(
                get: { lock.isEnabled },
                set: { enabled in Task { await lock.setEnabled(enabled) } }
            ))
            .disabled(lock.isAuthenticating)
            .accessibilityIdentifier("privacy.settings.enabled")
            Text("privacy.settings.description").font(.footnote)
            if lock.isEnabled {
                Button("privacy.lockNow") { lock.lock() }
                    .accessibilityIdentifier("privacy.lockNow")
            }
            if lock.authenticationFailed {
                Text("privacy.authentication.failed")
                    .accessibilityIdentifier("privacy.authentication.failed")
            }
        }
    }
}
