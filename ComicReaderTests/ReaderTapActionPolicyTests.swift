import XCTest
@testable import ComicReader

final class ReaderTapActionPolicyTests: XCTestCase {
    func testLeftRegionMovesBackwardInLeftToRightPagedMode() {
        let action = ReaderTapActionPolicy.action(
            horizontalFraction: 0,
            readingMode: .singlePage,
            readingDirection: .leftToRight,
            isZoomed: false,
            isInteractionBlocked: false
        )

        XCTAssertEqual(action, .movePage(.backward))
    }

    func testContinuousModeIgnoresSideRegions() {
        for horizontalFraction in [0.0, 1.0] {
            let action = ReaderTapActionPolicy.action(
                horizontalFraction: horizontalFraction,
                readingMode: .continuous,
                readingDirection: .leftToRight,
                isZoomed: false,
                isInteractionBlocked: false
            )

            XCTAssertEqual(action, .ignore)
        }
    }

    func testContinuousModeStillAllowsCenterControlsToggle() {
        let action = ReaderTapActionPolicy.action(
            horizontalFraction: 0.5,
            readingMode: .continuous,
            readingDirection: .leftToRight,
            isZoomed: false,
            isInteractionBlocked: false
        )

        XCTAssertEqual(action, .toggleControls)
    }

    func testSpreadModeUsesThePagedSideNavigationRules() {
        let action = ReaderTapActionPolicy.action(
            horizontalFraction: 1,
            readingMode: .spread,
            readingDirection: .leftToRight,
            isZoomed: false,
            isInteractionBlocked: false
        )

        XCTAssertEqual(action, .movePage(.forward))
    }

    func testRightToLeftMirrorsPhysicalSideActions() {
        XCTAssertEqual(
            action(
                horizontalFraction: 0,
                readingDirection: .rightToLeft
            ),
            .movePage(.forward)
        )
        XCTAssertEqual(
            action(
                horizontalFraction: 1,
                readingDirection: .rightToLeft
            ),
            .movePage(.backward)
        )
    }

    func testCenterRegionTogglesControlsAtItsLowerBoundary() {
        XCTAssertEqual(
            action(horizontalFraction: 1.0 / 3.0),
            .toggleControls
        )
        XCTAssertEqual(
            action(horizontalFraction: 0.5),
            .toggleControls
        )
        XCTAssertEqual(
            action(horizontalFraction: 2.0 / 3.0),
            .movePage(.forward)
        )
    }

    func testZoomAndPresentedSheetIgnoreTapActions() {
        XCTAssertEqual(
            action(horizontalFraction: 0.5, isZoomed: true),
            .ignore
        )
        XCTAssertEqual(
            action(horizontalFraction: 1, isInteractionBlocked: true),
            .ignore
        )
    }

    func testInvalidFractionsAreIgnored() {
        for horizontalFraction in [
            -0.01,
            1.01,
            .infinity,
            -.infinity,
            .nan,
        ] {
            XCTAssertEqual(action(horizontalFraction: horizontalFraction), .ignore)
        }
    }

    private func action(
        horizontalFraction: Double,
        readingDirection: ReadingDirection = .leftToRight,
        isZoomed: Bool = false,
        isInteractionBlocked: Bool = false
    ) -> ReaderTapAction {
        ReaderTapActionPolicy.action(
            horizontalFraction: horizontalFraction,
            readingMode: .singlePage,
            readingDirection: readingDirection,
            isZoomed: isZoomed,
            isInteractionBlocked: isInteractionBlocked
        )
    }
}
