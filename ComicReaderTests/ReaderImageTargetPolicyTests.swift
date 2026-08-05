import CoreGraphics
import XCTest
@testable import ComicReader

final class ReaderImageTargetPolicyTests: XCTestCase {
    func testRejectsInvalidDisplayMetrics() {
        let invalidMetrics: [(CGSize, CGFloat)] = [
            (.zero, 1),
            (CGSize(width: -1, height: 100), 1),
            (CGSize(width: 100, height: -1), 1),
            (CGSize(width: CGFloat.nan, height: 100), 1),
            (CGSize(width: 100, height: CGFloat.infinity), 1),
            (CGSize(width: 100, height: 100), 0),
            (CGSize(width: 100, height: 100), -1),
            (CGSize(width: 100, height: 100), CGFloat.nan),
            (CGSize(width: 100, height: 100), CGFloat.infinity),
        ]

        for (displaySize, displayScale) in invalidMetrics {
            XCTAssertNil(
                ReaderImageTargetPolicy.target(
                    displaySize: displaySize,
                    displayScale: displayScale
                )
            )
        }
    }

    func testRoundsOneAndTwoTimesDisplayTargetsUpToPixelBuckets() {
        XCTAssertEqual(
            ReaderImageTargetPolicy.target(
                displaySize: CGSize(width: 200, height: 100),
                displayScale: 1
            )?.maximumPixelSize,
            256
        )
        XCTAssertEqual(
            ReaderImageTargetPolicy.target(
                displaySize: CGSize(width: 200, height: 100),
                displayScale: 2
            )?.maximumPixelSize,
            512
        )
    }

    func testUsesMinimumBucketAndAdvancesImmediatelyPastBoundary() {
        XCTAssertEqual(
            ReaderImageTargetPolicy.target(
                displaySize: CGSize(width: 0.5, height: 0.25),
                displayScale: 1
            )?.maximumPixelSize,
            256
        )
        XCTAssertEqual(
            ReaderImageTargetPolicy.target(
                displaySize: CGSize(width: 256, height: 100),
                displayScale: 1
            )?.maximumPixelSize,
            256
        )
        XCTAssertEqual(
            ReaderImageTargetPolicy.target(
                displaySize: CGSize(width: 256.001, height: 100),
                displayScale: 1
            )?.maximumPixelSize,
            512
        )
    }

    func testCapsTargetAtMaximumDecodedPixelSize() {
        XCTAssertEqual(
            ReaderImageTargetPolicy.target(
                displaySize: CGSize(width: 3_000, height: 2_000),
                displayScale: 2
            )?.maximumPixelSize,
            ReaderImageTarget.maximumDecodedPixelSize
        )
    }

    func testCapsExtremeFiniteMetricsWithoutOverflowing() {
        XCTAssertEqual(
            ReaderImageTargetPolicy.target(
                displaySize: CGSize(
                    width: CGFloat.greatestFiniteMagnitude,
                    height: CGFloat.greatestFiniteMagnitude
                ),
                displayScale: CGFloat.greatestFiniteMagnitude
            )?.maximumPixelSize,
            ReaderImageTarget.maximumDecodedPixelSize
        )
    }
}
