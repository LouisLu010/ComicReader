import XCTest
@testable import ComicReader

final class ComicReaderCommandsTests: XCTestCase {
    func testEnabledActionPerformsExactlyOncePerInvocation() {
        var invocationCount = 0
        let action = ReaderCommandAction(isEnabled: true) {
            invocationCount += 1
        }

        action.performIfEnabled()
        action.performIfEnabled()

        XCTAssertEqual(invocationCount, 2)
    }

    func testDisabledActionDoesNotPerform() {
        var didPerform = false
        let action = ReaderCommandAction(isEnabled: false) {
            didPerform = true
        }

        action.performIfEnabled()

        XCTAssertFalse(didPerform)
    }
}
