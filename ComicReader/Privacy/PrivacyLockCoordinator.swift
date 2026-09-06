import Foundation
import LocalAuthentication
import Observation

@MainActor
protocol DeviceOwnerAuthenticating: AnyObject {
    func authenticate() async -> Bool
    func cancel()
}

@MainActor
final class LocalDeviceOwnerAuthenticator: DeviceOwnerAuthenticating {
    private var context: LAContext?

    func authenticate() async -> Bool {
        let context = LAContext()
        self.context = context
        defer { self.context = nil }
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: nil) else {
            return false
        }
        return (try? await context.evaluatePolicy(
            .deviceOwnerAuthentication,
            localizedReason: String(localized: "privacy.authentication.reason")
        )) == true
    }

    func cancel() {
        context?.invalidate()
    }
}

/// 锁状态在 App 内共享；窗口可见性分别跟踪，认证失效后不接受迟到结果。
@MainActor
@Observable
final class PrivacyLockCoordinator {
    enum SceneActivity: Equatable, Sendable { case active, inactive, background }
    static let preferenceKey = "privacy.deviceOwnerLock.enabled"

    private(set) var isEnabled: Bool
    private(set) var isLocked: Bool
    private(set) var isAuthenticating = false
    private(set) var authenticationFailed = false
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let authenticator: any DeviceOwnerAuthenticating
    @ObservationIgnored private var scenes: [UUID: SceneActivity] = [:]
    @ObservationIgnored private var authenticationGeneration = 0

    init(defaults: UserDefaults = .standard, authenticator: any DeviceOwnerAuthenticating) {
        self.defaults = defaults
        self.authenticator = authenticator
        isEnabled = defaults.bool(forKey: Self.preferenceKey)
        isLocked = isEnabled
    }

    func updateScene(_ id: UUID, activity: SceneActivity) {
        scenes[id] = activity
        // 系统认证面板会让窗口 inactive，不能因此取消认证或重复锁定。
        if activity == .background, !scenes.values.contains(.active) {
            lock()
        }
    }

    func removeScene(_ id: UUID) {
        scenes.removeValue(forKey: id)
        if !scenes.values.contains(.active) { lock() }
    }

    func lock() {
        authenticationGeneration += 1
        authenticator.cancel()
        if isEnabled { isLocked = true }
    }

    func unlock() async {
        guard isEnabled, isLocked else { return }
        if await authenticate() { isLocked = false }
    }

    func setEnabled(_ enabled: Bool) async {
        guard enabled != isEnabled else { return }
        // 开启和关闭都需要系统认证，不自行存储密码或生物识别信息。
        guard await authenticate() else { return }
        defaults.set(enabled, forKey: Self.preferenceKey)
        isEnabled = enabled
        isLocked = false
    }

    private func authenticate() async -> Bool {
        guard !isAuthenticating else { return false }
        isAuthenticating = true
        authenticationFailed = false
        let generation = authenticationGeneration
        defer { isAuthenticating = false }
        let succeeded = await authenticator.authenticate()
        guard generation == authenticationGeneration else { return false }
        authenticationFailed = !succeeded
        return succeeded
    }
}
