import Foundation
import XCTest
@testable import ComicReader

@MainActor
final class PrivacyLockCoordinatorTests: XCTestCase {
    private func fixture(enabled: Bool = false) -> (PrivacyLockCoordinator, TestAuthenticator, UserDefaults) {
        let defaults = UserDefaults(suiteName: "PrivacyTests.\(UUID().uuidString)")!
        defaults.set(enabled, forKey: PrivacyLockCoordinator.preferenceKey)
        let authenticator = TestAuthenticator()
        return (PrivacyLockCoordinator(defaults: defaults, authenticator: authenticator), authenticator, defaults)
    }

    func testEnabledLockStartsLockedAndFailureCannotUnlock() async {
        let (lock, authenticator, _) = fixture(enabled: true)
        XCTAssertTrue(lock.isLocked)
        authenticator.result = false
        await lock.unlock()
        XCTAssertTrue(lock.isLocked)
        XCTAssertTrue(lock.authenticationFailed)
        authenticator.result = true
        await lock.unlock()
        XCTAssertFalse(lock.isLocked)
        XCTAssertFalse(lock.authenticationFailed)
    }

    func testEnablingAndDisablingRequireAuthenticationAndPersist() async {
        let (lock, authenticator, defaults) = fixture()
        authenticator.result = false
        await lock.setEnabled(true)
        XCTAssertFalse(lock.isEnabled)
        authenticator.result = true
        await lock.setEnabled(true)
        XCTAssertTrue(defaults.bool(forKey: PrivacyLockCoordinator.preferenceKey))
        authenticator.result = false
        await lock.setEnabled(false)
        XCTAssertTrue(lock.isEnabled)
        authenticator.result = true
        await lock.setEnabled(false)
        XCTAssertFalse(lock.isEnabled)
        XCTAssertFalse(defaults.bool(forKey: PrivacyLockCoordinator.preferenceKey))
    }

    func testInactiveAuthenticationPanelDoesNotRelockButBackgroundDoes() async {
        let (lock, _, _) = fixture(enabled: true)
        let scene = UUID()
        lock.updateScene(scene, activity: .active)
        await lock.unlock()
        lock.updateScene(scene, activity: .inactive)
        XCTAssertFalse(lock.isLocked)
        lock.updateScene(scene, activity: .background)
        XCTAssertTrue(lock.isLocked)
    }

    func testBackgroundWindowDoesNotInterruptOtherActiveWindow() async {
        let (lock, _, _) = fixture(enabled: true)
        let first = UUID(), second = UUID()
        lock.updateScene(first, activity: .active)
        lock.updateScene(second, activity: .active)
        await lock.unlock()
        lock.updateScene(first, activity: .background)
        XCTAssertFalse(lock.isLocked)
        lock.removeScene(second)
        XCTAssertTrue(lock.isLocked)
    }

    func testBackgroundDiscardsLateSuccessfulAuthentication() async {
        let (lock, authenticator, _) = fixture(enabled: true)
        authenticator.suspends = true
        let scene = UUID()
        lock.updateScene(scene, activity: .active)
        let task = Task { await lock.unlock() }
        while authenticator.continuation == nil { await Task.yield() }
        lock.updateScene(scene, activity: .background)
        authenticator.continuation?.resume(returning: true)
        await task.value
        XCTAssertTrue(lock.isLocked)
        XCTAssertFalse(lock.isAuthenticating)
        XCTAssertGreaterThan(authenticator.cancelCount, 0)
    }
}

@MainActor
private final class TestAuthenticator: DeviceOwnerAuthenticating {
    var result = true
    var suspends = false
    var cancelCount = 0
    var continuation: CheckedContinuation<Bool, Never>?

    func authenticate() async -> Bool {
        if suspends {
            return await withCheckedContinuation { continuation = $0 }
        }
        return result
    }

    func cancel() { cancelCount += 1 }
}
