import Foundation
import XCTest
@testable import ComicReader

final class ReaderPrefetchPolicyTests: XCTestCase {
    func testStationaryPlanUsesVisibleWindowFrontiers()
        throws {
        let layout = makeLayout(pageCount: 7, mode: .continuous)
        let page3 = try pagePresentation("page-3", in: layout)
        let page4 = try pagePresentation("page-4", in: layout)

        XCTAssertEqual(
            ReaderPrefetchPolicy.plan(
                visiblePresentationIDs: [page4, page3],
                in: layout,
                motion: .stationary,
                windowCapability: .singlePageOnly,
                memoryState: .normal
            ).presentationIDs,
            [
                try pagePresentation("page-5", in: layout),
                try pagePresentation("page-6", in: layout),
                try pagePresentation("page-2", in: layout),
            ]
        )
        XCTAssertEqual(
            ReaderPrefetchPolicy.plan(
                visiblePresentationIDs: [page4, page3],
                in: layout,
                motion: .stationary,
                windowCapability: .spreadCapable,
                memoryState: .normal
            ).presentationIDs,
            [
                try pagePresentation("page-5", in: layout),
                try pagePresentation("page-2", in: layout),
            ]
        )
    }

    func testNormalForwardMovementUsesWindowSpecificBudget() throws {
        let layout = makeLayout(pageCount: 8)
        let visible = try pagePresentation("page-4", in: layout)

        let narrowPlan = ReaderPrefetchPolicy.plan(
            visiblePresentationIDs: [visible],
            in: layout,
            motion: .forward(.normal),
            windowCapability: .singlePageOnly,
            memoryState: .normal
        )
        let widePlan = ReaderPrefetchPolicy.plan(
            visiblePresentationIDs: [visible],
            in: layout,
            motion: .forward(.normal),
            windowCapability: .spreadCapable,
            memoryState: .normal
        )

        XCTAssertEqual(
            narrowPlan.presentationIDs,
            [
                try pagePresentation("page-5", in: layout),
                try pagePresentation("page-6", in: layout),
                try pagePresentation("page-3", in: layout),
            ]
        )
        XCTAssertEqual(
            widePlan.presentationIDs,
            [
                try pagePresentation("page-5", in: layout),
                try pagePresentation("page-3", in: layout),
            ]
        )
    }

    func testRapidMovementAddsOnePresentationInThePrimaryDirection() throws {
        let layout = makeLayout(pageCount: 9)
        let visible = try pagePresentation("page-4", in: layout)

        XCTAssertEqual(
            ReaderPrefetchPolicy.plan(
                visiblePresentationIDs: [visible],
                in: layout,
                motion: .forward(.rapid),
                windowCapability: .singlePageOnly,
                memoryState: .normal
            ).presentationIDs,
            [
                try pagePresentation("page-5", in: layout),
                try pagePresentation("page-6", in: layout),
                try pagePresentation("page-7", in: layout),
                try pagePresentation("page-3", in: layout),
            ]
        )
        XCTAssertEqual(
            ReaderPrefetchPolicy.plan(
                visiblePresentationIDs: [visible],
                in: layout,
                motion: .forward(.rapid),
                windowCapability: .spreadCapable,
                memoryState: .normal
            ).presentationIDs,
            [
                try pagePresentation("page-5", in: layout),
                try pagePresentation("page-6", in: layout),
                try pagePresentation("page-3", in: layout),
            ]
        )
    }

    func testBackwardMovementMirrorsThePrimaryBudget() throws {
        let layout = makeLayout(pageCount: 8)
        let visible = try pagePresentation("page-5", in: layout)

        XCTAssertEqual(
            ReaderPrefetchPolicy.plan(
                visiblePresentationIDs: [visible],
                in: layout,
                motion: .backward(.normal),
                windowCapability: .singlePageOnly,
                memoryState: .normal
            ).presentationIDs,
            [
                try pagePresentation("page-4", in: layout),
                try pagePresentation("page-3", in: layout),
                try pagePresentation("page-6", in: layout),
            ]
        )
    }

    func testConstrainedMemoryProducesNoPrefetchPlan() throws {
        let layout = makeLayout(pageCount: 5)
        let visible = try pagePresentation("page-3", in: layout)
        let motions: [ReaderPrefetchMotion] = [
            .stationary,
            .forward(.normal),
            .forward(.rapid),
            .backward(.normal),
            .backward(.rapid),
        ]
        let capabilities: [ReaderLayoutCapability] = [
            .singlePageOnly,
            .spreadCapable,
        ]

        for motion in motions {
            for capability in capabilities {
                XCTAssertEqual(
                    ReaderPrefetchPolicy.plan(
                        visiblePresentationIDs: [visible],
                        in: layout,
                        motion: motion,
                        windowCapability: capability,
                        memoryState: .constrained
                    ),
                    .empty
                )
            }
        }
    }

    func testSkipsBoundariesAndUnreadablePagesWithoutSpendingBudget()
        throws {
        let layout = makeLayout(
            chapters: [
                makeChapter("chapter-1", pages: ["page-1", "page-2"]),
                makeChapter(
                    "chapter-2",
                    pages: ["page-3", "page-4", "page-5"],
                    corruptedPageIDs: ["page-3"]
                ),
            ]
        )
        let visible = try pagePresentation("page-2", in: layout)

        XCTAssertEqual(
            ReaderPrefetchPolicy.plan(
                visiblePresentationIDs: [visible],
                in: layout,
                motion: .forward(.normal),
                windowCapability: .singlePageOnly,
                memoryState: .normal
            ).presentationIDs,
            [
                try pagePresentation("page-4", in: layout),
                try pagePresentation("page-5", in: layout),
                try pagePresentation("page-1", in: layout),
            ]
        )
    }

    func testChapterBoundaryCanAnchorCrossChapterPrefetch() throws {
        let firstChapterID = ImportChapterCandidate.ID(rawValue: "chapter-1")
        let layout = makeLayout(
            chapters: [
                makeChapter("chapter-1", pages: ["page-1", "page-2"]),
                makeChapter("chapter-2", pages: ["page-3", "page-4"]),
            ]
        )

        XCTAssertEqual(
            ReaderPrefetchPolicy.plan(
                visiblePresentationIDs: [
                    .chapterBoundary(firstChapterID),
                ],
                in: layout,
                motion: .stationary,
                windowCapability: .singlePageOnly,
                memoryState: .normal
            ).presentationIDs,
            [
                try pagePresentation("page-3", in: layout),
                try pagePresentation("page-4", in: layout),
                try pagePresentation("page-2", in: layout),
            ]
        )
    }

    func testVisibleWindowUsesLogicalFrontiersAndExcludesVisiblePages()
        throws {
        let layout = makeLayout(pageCount: 8, mode: .continuous)
        let page3 = try pagePresentation("page-3", in: layout)
        let page4 = try pagePresentation("page-4", in: layout)

        XCTAssertEqual(
            ReaderPrefetchPolicy.plan(
                visiblePresentationIDs: [page4, page3, page4],
                in: layout,
                motion: .forward(.normal),
                windowCapability: .singlePageOnly,
                memoryState: .normal
            ).presentationIDs,
            [
                try pagePresentation("page-5", in: layout),
                try pagePresentation("page-6", in: layout),
                try pagePresentation("page-2", in: layout),
            ]
        )
    }

    func testSpreadPlanUsesLogicalOrderAndIsRTLInvariant() throws {
        let leftToRight = makeLayout(
            pageCount: 10,
            mode: .spread,
            direction: .leftToRight
        )
        let rightToLeft = makeLayout(
            pageCount: 10,
            mode: .spread,
            direction: .rightToLeft
        )

        let leftPlan = ReaderPrefetchPolicy.plan(
            visiblePresentationIDs: [
                try pagePresentation("page-5", in: leftToRight),
            ],
            in: leftToRight,
            motion: .forward(.normal),
            windowCapability: .spreadCapable,
            memoryState: .normal
        )
        let rightPlan = ReaderPrefetchPolicy.plan(
            visiblePresentationIDs: [
                try pagePresentation("page-5", in: rightToLeft),
            ],
            in: rightToLeft,
            motion: .forward(.normal),
            windowCapability: .spreadCapable,
            memoryState: .normal
        )

        XCTAssertEqual(
            pageIDs(in: leftPlan, layout: leftToRight),
            [
                "page-7", "page-8",
                "page-3", "page-4",
            ]
        )
        XCTAssertEqual(
            pageIDs(in: rightPlan, layout: rightToLeft),
            [
                "page-7", "page-8",
                "page-3", "page-4",
            ]
        )
    }

    func testCoverIsEligibleAsPreviousNeighbor() throws {
        let cover = ReaderPage(
            id: ImportPageCandidate.ID(rawValue: "cover"),
            displayPixelSize: ImportPixelSize(width: 1_000, height: 1_500),
            isCover: true
        )
        let chapter = makeChapter(
            "chapter-1",
            pages: ["page-1", "page-2"]
        )
        let layout = ReaderLayout(
            comic: ReaderComic(
                id: managedComicID,
                displayName: "Prefetch Comic",
                cover: cover,
                chapters: [chapter]
            ),
            requestedMode: .singlePage,
            direction: .leftToRight,
            capability: .spreadCapable
        )

        let plan = ReaderPrefetchPolicy.plan(
            visiblePresentationIDs: [
                try pagePresentation("page-1", in: layout),
            ],
            in: layout,
            motion: .stationary,
            windowCapability: .singlePageOnly,
            memoryState: .normal
        )

        XCTAssertEqual(
            pageIDs(in: plan, layout: layout),
            ["page-2", "cover"]
        )
    }

    func testMotionDetectsNormalForwardAndBackwardTransitions() throws {
        let layout = makeLayout(pageCount: 7, mode: .continuous)
        let page2 = try pagePresentation("page-2", in: layout)
        let page3 = try pagePresentation("page-3", in: layout)
        let page4 = try pagePresentation("page-4", in: layout)

        XCTAssertEqual(
            ReaderPrefetchPolicy.motion(
                from: [page2, page3],
                to: [page3, page4],
                elapsedTime: 1,
                in: layout
            ),
            .forward(.normal)
        )
        XCTAssertEqual(
            ReaderPrefetchPolicy.motion(
                from: [page3, page4],
                to: [page2, page3],
                elapsedTime: 1,
                in: layout
            ),
            .backward(.normal)
        )
        XCTAssertEqual(
            ReaderPrefetchPolicy.motion(
                from: [page3, page4],
                to: [page4, page3],
                elapsedTime: 0.1,
                in: layout
            ),
            .stationary
        )
    }

    func testMotionBecomesRapidForShortIntervalsOrMultiPageJumps()
        throws {
        let layout = makeLayout(pageCount: 7, mode: .continuous)
        let page2 = try pagePresentation("page-2", in: layout)
        let page3 = try pagePresentation("page-3", in: layout)
        let page5 = try pagePresentation("page-5", in: layout)

        XCTAssertEqual(
            ReaderPrefetchPolicy.motion(
                from: [page2],
                to: [page3],
                elapsedTime: 0.1,
                in: layout
            ),
            .forward(.rapid)
        )
        XCTAssertEqual(
            ReaderPrefetchPolicy.motion(
                from: [page2],
                to: [page5],
                elapsedTime: 1,
                in: layout
            ),
            .forward(.rapid)
        )
        let nonRapidIntervals: [TimeInterval?] = [
            ReaderPrefetchPolicy.rapidTransitionInterval,
            -1,
            TimeInterval.nan,
            TimeInterval.infinity,
            nil,
        ]
        for elapsedTime in nonRapidIntervals {
            XCTAssertEqual(
                ReaderPrefetchPolicy.motion(
                    from: [page2],
                    to: [page3],
                    elapsedTime: elapsedTime,
                    in: layout
                ),
                .forward(.normal)
            )
        }
    }

    func testChapterBoundaryDoesNotTurnOnePageTransitionIntoRapid()
        throws {
        let layout = makeLayout(
            chapters: [
                makeChapter("chapter-1", pages: ["page-1", "page-2"]),
                makeChapter("chapter-2", pages: ["page-3", "page-4"]),
            ],
            mode: .singlePage
        )

        XCTAssertEqual(
            ReaderPrefetchPolicy.motion(
                from: [try pagePresentation("page-2", in: layout)],
                to: [try pagePresentation("page-3", in: layout)],
                elapsedTime: 1,
                in: layout
            ),
            .forward(.normal)
        )
    }

    func testMotionTrackerKeepsOriginalBaselineForRepeatedSnapshot()
        throws {
        let layout = makeLayout(pageCount: 5, mode: .continuous)
        let page2 = try pagePresentation("page-2", in: layout)
        let page3 = try pagePresentation("page-3", in: layout)
        var tracker = ReaderPrefetchMotionTracker()

        XCTAssertEqual(
            tracker.observe(
                presentationIDs: [page2],
                at: 10,
                in: layout
            ),
            .stationary
        )
        XCTAssertEqual(
            tracker.observe(
                presentationIDs: [page2, page2],
                at: 10.5,
                in: layout
            ),
            .stationary
        )
        XCTAssertEqual(
            tracker.observe(
                presentationIDs: [page3],
                at: 10.6,
                in: layout
            ),
            .forward(.normal)
        )
    }

    func testMotionTrackerResetPreventsViewportChangeFromLookingRapid()
        throws {
        let layout = makeLayout(pageCount: 6, mode: .continuous)
        let page2 = try pagePresentation("page-2", in: layout)
        let page3 = try pagePresentation("page-3", in: layout)
        let page4 = try pagePresentation("page-4", in: layout)
        let page5 = try pagePresentation("page-5", in: layout)
        var tracker = ReaderPrefetchMotionTracker()

        _ = tracker.observe(
            presentationIDs: [page2, page3],
            at: 10,
            in: layout
        )
        XCTAssertEqual(
            tracker.observe(
                presentationIDs: [page3, page4],
                at: 10.1,
                in: layout
            ),
            .forward(.rapid)
        )
        XCTAssertEqual(
            tracker.observe(
                presentationIDs: [page4, page3, page4],
                at: 10.15,
                in: layout
            ),
            .forward(.rapid)
        )

        tracker.reset()

        XCTAssertEqual(
            tracker.observe(
                presentationIDs: [page2, page3, page4, page5],
                at: 10.2,
                in: layout
            ),
            .stationary
        )
    }

    func testMotionFallsBackToStationaryForUnknownOrOpposingFrontiers()
        throws {
        let layout = makeLayout(pageCount: 7, mode: .continuous)
        let page2 = try pagePresentation("page-2", in: layout)
        let page3 = try pagePresentation("page-3", in: layout)
        let page4 = try pagePresentation("page-4", in: layout)
        let unknown = ReaderPresentationID.page(
            .chapter(
                ImportChapterCandidate.ID(rawValue: "unknown-chapter"),
                ImportPageCandidate.ID(rawValue: "unknown-page")
            )
        )

        XCTAssertEqual(
            ReaderPrefetchPolicy.motion(
                from: [page2, page4],
                to: [page3],
                elapsedTime: 0.1,
                in: layout
            ),
            .stationary
        )
        XCTAssertEqual(
            ReaderPrefetchPolicy.motion(
                from: [unknown],
                to: [page3],
                elapsedTime: 0.1,
                in: layout
            ),
            .stationary
        )
    }

    func testPlanWithoutKnownVisiblePresentationIsEmpty() {
        let layout = makeLayout(pageCount: 3)
        let unknown = ReaderPresentationID.page(
            .chapter(
                ImportChapterCandidate.ID(rawValue: "unknown-chapter"),
                ImportPageCandidate.ID(rawValue: "unknown-page")
            )
        )

        for presentationIDs in [[], [unknown]] {
            XCTAssertEqual(
                ReaderPrefetchPolicy.plan(
                    visiblePresentationIDs: presentationIDs,
                    in: layout,
                    motion: .forward(.rapid),
                    windowCapability: .singlePageOnly,
                    memoryState: .normal
                ),
                .empty
            )
        }
    }

    private func makeLayout(
        pageCount: Int,
        mode: ReadingMode = .singlePage,
        direction: ReadingDirection = .leftToRight
    ) -> ReaderLayout {
        makeLayout(
            chapters: [
                makeChapter(
                    "chapter-1",
                    pages: (1...pageCount).map { "page-\($0)" }
                ),
            ],
            mode: mode,
            direction: direction
        )
    }

    private func makeLayout(
        chapters: [ReaderChapter],
        mode: ReadingMode = .singlePage,
        direction: ReadingDirection = .leftToRight
    ) -> ReaderLayout {
        ReaderLayout(
            comic: ReaderComic(
                id: managedComicID,
                displayName: "Prefetch Comic",
                chapters: chapters
            ),
            requestedMode: mode,
            direction: direction,
            capability: .spreadCapable
        )
    }

    private func makeChapter(
        _ rawChapterID: String,
        pages rawPageIDs: [String],
        corruptedPageIDs: Set<String> = []
    ) -> ReaderChapter {
        ReaderChapter(
            id: ImportChapterCandidate.ID(rawValue: rawChapterID),
            displayName: rawChapterID,
            pages: rawPageIDs.map { rawPageID in
                ReaderPage(
                    id: ImportPageCandidate.ID(rawValue: rawPageID),
                    displayPixelSize: ImportPixelSize(
                        width: 1_000,
                        height: 1_500
                    ),
                    state: corruptedPageIDs.contains(rawPageID)
                        ? .corrupted
                        : .readable
                )
            }
        )
    }

    private func pagePresentation(
        _ rawPageID: String,
        in layout: ReaderLayout
    ) throws -> ReaderPresentationID {
        try XCTUnwrap(
            layout.presentations.first { presentation in
                presentation.locations.contains { location in
                    location.pageID.rawValue == rawPageID
                }
            }?.id
        )
    }

    private func pageIDs(
        in plan: ReaderPrefetchPlan,
        layout: ReaderLayout
    ) -> [String] {
        plan.presentationIDs.flatMap { presentationID in
            layout.presentation(for: presentationID)?.locations.map {
                $0.pageID.rawValue
            } ?? []
        }
    }

    private var managedComicID: ManagedComicID {
        ManagedComicID(
            rawValue: UUID(
                uuidString: "00000000-0000-0000-0000-000000000921"
            )!
        )
    }
}
