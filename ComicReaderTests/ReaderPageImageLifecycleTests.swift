import XCTest
@testable import ComicReader

final class ReaderPageImageLifecycleTests: XCTestCase {
    func testOnlyVisibleCurrentGenerationCanAcceptImageResult() {
        var lifecycle = ReaderPageImageLifecycle()
        let initialGeneration = lifecycle.generation

        XCTAssertFalse(lifecycle.accepts(generation: initialGeneration))

        lifecycle.didAppear()
        let visibleGeneration = lifecycle.generation

        XCTAssertNotEqual(visibleGeneration, initialGeneration)
        XCTAssertTrue(lifecycle.accepts(generation: visibleGeneration))
        XCTAssertFalse(lifecycle.accepts(generation: initialGeneration))
    }

    func testDisappearanceInvalidatesRequestAndReappearanceCanReload() {
        var lifecycle = ReaderPageImageLifecycle()
        lifecycle.didAppear()
        let firstAppearanceGeneration = lifecycle.generation

        lifecycle.didDisappear()

        XCTAssertFalse(
            lifecycle.accepts(generation: firstAppearanceGeneration)
        )
        XCTAssertFalse(lifecycle.isVisible)

        lifecycle.didAppear()
        let secondAppearanceGeneration = lifecycle.generation

        XCTAssertTrue(lifecycle.isVisible)
        XCTAssertNotEqual(
            secondAppearanceGeneration,
            firstAppearanceGeneration
        )
        XCTAssertTrue(
            lifecycle.accepts(generation: secondAppearanceGeneration)
        )
    }

    func testRepeatedVisibilityCallbacksDoNotCreateDuplicateRequests() {
        var lifecycle = ReaderPageImageLifecycle()
        lifecycle.didAppear()
        let visibleGeneration = lifecycle.generation

        lifecycle.didAppear()
        XCTAssertEqual(lifecycle.generation, visibleGeneration)

        lifecycle.didDisappear()
        let hiddenGeneration = lifecycle.generation

        lifecycle.didDisappear()
        XCTAssertEqual(lifecycle.generation, hiddenGeneration)
    }
}
