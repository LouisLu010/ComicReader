import CoreGraphics
import XCTest
@testable import ComicReader

final class ReaderViewportPolicyTests: XCTestCase {
    func testUsesWindowWidthToChooseSpreadCapability() {
        let policy = ReaderViewportPolicy(minimumSpreadWidth: 900)

        XCTAssertEqual(
            policy.capability(for: CGSize(width: 899.999, height: 700)),
            .singlePageOnly
        )
        XCTAssertEqual(
            policy.capability(for: CGSize(width: 900, height: 1_400)),
            .spreadCapable
        )
        XCTAssertEqual(
            policy.capability(for: CGSize(width: 1_200, height: 600)),
            .spreadCapable
        )
    }

    func testRejectsInvalidViewportDimensions() {
        let policy = ReaderViewportPolicy(minimumSpreadWidth: 900)
        let invalidSizes = [
            CGSize(width: 0, height: 700),
            CGSize(width: -1, height: 700),
            CGSize(width: 1_000, height: 0),
            CGSize(width: 1_000, height: -1),
            CGSize(width: CGFloat.nan, height: 700),
            CGSize(width: CGFloat.infinity, height: 700),
            CGSize(width: 1_000, height: CGFloat.nan),
            CGSize(width: 1_000, height: CGFloat.infinity),
        ]

        for size in invalidSizes {
            XCTAssertEqual(
                policy.capability(for: size),
                .singlePageOnly,
                "Expected invalid size \(size) to disable spread"
            )
        }
    }

    func testInvalidThresholdFallsBackToDefault() {
        for threshold in [
            CGFloat.zero,
            CGFloat(-1),
            CGFloat.nan,
            CGFloat.infinity,
        ] {
            let policy = ReaderViewportPolicy(
                minimumSpreadWidth: threshold
            )

            XCTAssertEqual(
                policy.minimumSpreadWidth,
                ReaderViewportPolicy.defaultMinimumSpreadWidth
            )
        }
    }
}
