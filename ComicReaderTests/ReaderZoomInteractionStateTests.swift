import CoreGraphics
import XCTest
@testable import ComicReader

final class ReaderZoomInteractionStateTests: XCTestCase {
    func testInitialStateNormalizesScaleAndClampsOffset() {
        let state = ReaderZoomInteractionState(
            committedScale: 99,
            offset: CGPoint(x: 10_000, y: -10_000),
            viewportSize: CGSize(width: 300, height: 200),
            contentSize: CGSize(width: 300, height: 200)
        )

        XCTAssertEqual(
            state.committedScale,
            ReaderZoomInteractionState.maximumScale
        )
        XCTAssertEqual(state.transientMagnification, 1)
        XCTAssertEqual(state.scale, 16)
        XCTAssertEqual(state.offset, CGPoint(x: 2_250, y: -1_500))
    }

    func testInitialStateRejectsNonFiniteScaleAndGeometry() {
        for scale in [Double.nan, Double.infinity, -Double.infinity] {
            let state = ReaderZoomInteractionState(
                committedScale: scale,
                offset: CGPoint(x: 50, y: 50),
                viewportSize: CGSize(width: CGFloat.nan, height: 200),
                contentSize: CGSize(width: 300, height: CGFloat.infinity)
            )

            XCTAssertEqual(state.committedScale, 1)
            XCTAssertEqual(state.viewportSize, .zero)
            XCTAssertEqual(state.contentSize, .zero)
            XCTAssertEqual(state.offset, .zero)
        }

        XCTAssertEqual(
            ReaderZoomInteractionState(committedScale: -1).scale,
            ReaderZoomInteractionState.minimumScale
        )
    }

    func testTransientMagnificationClampsAndCommitsEffectiveScale() {
        var state = makeState(scale: 2)

        state.updateMagnification(3)

        XCTAssertEqual(state.committedScale, 2)
        XCTAssertEqual(state.transientMagnification, 3)
        XCTAssertEqual(state.scale, 6)

        state.updateMagnification(Double.greatestFiniteMagnitude)
        XCTAssertEqual(
            state.scale,
            ReaderZoomInteractionState.maximumScale
        )

        state.commitMagnification()

        XCTAssertEqual(state.committedScale, 16)
        XCTAssertEqual(state.transientMagnification, 1)
        XCTAssertEqual(state.scale, 16)

        state.updateMagnification(Double.leastNonzeroMagnitude)
        XCTAssertEqual(state.scale, ReaderZoomInteractionState.minimumScale)

        state.commitMagnification()
        XCTAssertEqual(
            state.committedScale,
            ReaderZoomInteractionState.minimumScale
        )
    }

    func testInvalidMagnificationUsesIdentityAndCancellationRestoresOffset() {
        var state = makeState(scale: 2)
        state.setOffset(CGPoint(x: 100, y: 50))

        for magnification in [
            Double.zero,
            -1,
            Double.nan,
            Double.infinity,
        ] {
            state.updateMagnification(magnification)

            XCTAssertEqual(state.transientMagnification, 1)
            XCTAssertEqual(state.scale, 2)
        }

        state.updateMagnification(0.5)
        XCTAssertEqual(state.scale, 1)
        XCTAssertEqual(state.offset, .zero)

        state.cancelMagnification()
        XCTAssertEqual(state.scale, 2)
        XCTAssertEqual(state.offset, CGPoint(x: 100, y: 50))
    }

    func testCommittedScaleNormalizationClearsOffsetAtOrBelowOne() {
        var state = makeState(scale: 2)
        state.setOffset(CGPoint(x: 100, y: 50))

        state.setCommittedScale(0.5)

        XCTAssertEqual(state.committedScale, 0.5)
        XCTAssertEqual(state.offset, .zero)

        state.setCommittedScale(.infinity)
        XCTAssertEqual(state.committedScale, 1)
        XCTAssertEqual(state.offset, .zero)
    }

    func testOffsetAndTranslationClampToScaledContentBounds() {
        var state = makeState(scale: 2)

        state.setOffset(CGPoint(x: 1_000, y: -1_000))
        XCTAssertEqual(state.offset, CGPoint(x: 150, y: -100))

        state.translate(by: CGSize(width: -100, height: 75))
        XCTAssertEqual(state.offset, CGPoint(x: 50, y: -25))

        state.translate(by: CGSize(width: -1_000, height: 1_000))
        XCTAssertEqual(state.offset, CGPoint(x: -150, y: 100))

        state.translate(by: CGSize(
            width: -CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        ))
        XCTAssertEqual(state.offset, CGPoint(x: -150, y: 100))
    }

    func testInvalidOffsetClearsAndInvalidTranslationIsIgnored() {
        var state = makeState(scale: 2)
        state.setOffset(CGPoint(x: 50, y: 25))

        state.translate(by: CGSize(width: CGFloat.nan, height: 10))
        XCTAssertEqual(state.offset, CGPoint(x: 50, y: 25))

        state.setOffset(CGPoint(x: CGFloat.infinity, y: 10))
        XCTAssertEqual(state.offset, .zero)
    }

    func testGeometryChangeReclampsOffsetAfterRotation() {
        var state = ReaderZoomInteractionState(
            committedScale: 2,
            viewportSize: CGSize(width: 300, height: 600),
            contentSize: CGSize(width: 300, height: 600)
        )
        state.setOffset(CGPoint(x: 150, y: 300))

        state.updateGeometry(
            viewportSize: CGSize(width: 600, height: 300),
            contentSize: CGSize(width: 300, height: 600)
        )

        XCTAssertEqual(state.offset, CGPoint(x: 0, y: 300))

        state.updateGeometry(
            viewportSize: CGSize(width: 600, height: 300),
            contentSize: CGSize(width: 600, height: 300)
        )

        XCTAssertEqual(state.offset, CGPoint(x: 0, y: 150))
    }

    func testInvalidGeometryClearsOffset() {
        var state = makeState(scale: 2)
        state.setOffset(CGPoint(x: 50, y: 25))

        state.updateGeometry(
            viewportSize: CGSize(width: 0, height: 200),
            contentSize: CGSize(width: 300, height: 200)
        )

        XCTAssertEqual(state.viewportSize, .zero)
        XCTAssertEqual(state.offset, .zero)
    }

    func testDoubleTapTogglesBetweenOneAndTwo() {
        var state = makeState(scale: 1)

        state.toggleDoubleTapZoom()
        XCTAssertEqual(state.scale, 2)

        state.setOffset(CGPoint(x: 100, y: 50))
        state.toggleDoubleTapZoom()
        XCTAssertEqual(state.scale, 1)
        XCTAssertEqual(state.offset, .zero)

        state.toggleDoubleTapZoom()
        XCTAssertEqual(state.scale, 2)
    }

    func testExtremeFiniteGeometryKeepsOffsetFinite() {
        var state = ReaderZoomInteractionState(
            committedScale: 16,
            viewportSize: CGSize(
                width: CGFloat.greatestFiniteMagnitude,
                height: 100
            ),
            contentSize: CGSize(
                width: CGFloat.greatestFiniteMagnitude,
                height: 100
            )
        )

        state.setOffset(CGPoint(
            x: CGFloat.greatestFiniteMagnitude,
            y: CGFloat.greatestFiniteMagnitude
        ))

        XCTAssertTrue(state.offset.x.isFinite)
        XCTAssertTrue(state.offset.y.isFinite)
        XCTAssertGreaterThan(state.offset.x, 0)
        XCTAssertEqual(state.offset.y, 750)
    }

    func testStateIsSendable() {
        assertSendable(makeState(scale: 2))
    }

    private func makeState(scale: Double) -> ReaderZoomInteractionState {
        ReaderZoomInteractionState(
            committedScale: scale,
            viewportSize: CGSize(width: 300, height: 200),
            contentSize: CGSize(width: 300, height: 200)
        )
    }

    private func assertSendable<T: Sendable>(_ value: T) {
        _ = value
    }
}
