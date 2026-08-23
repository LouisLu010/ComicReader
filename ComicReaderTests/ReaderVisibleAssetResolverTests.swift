import Foundation
import XCTest
@testable import ComicReader

final class ReaderVisibleAssetResolverTests: XCTestCase {
    func testEmptySnapshotContainsNoVisibleResources() {
        XCTAssertTrue(
            ReaderVisibleAssetSnapshot.empty.presentationIDs.isEmpty
        )
        XCTAssertTrue(ReaderVisibleAssetSnapshot.empty.pageIDs.isEmpty)
        XCTAssertTrue(
            ReaderVisibleAssetSnapshot.empty.assetIdentities.isEmpty
        )
    }

    func testResolveMapsMultiplePresentationsToCompleteIdentities() {
        let fixture = makeFixture(mode: .continuous)
        let pagePresentationIDs = fixture.layout.presentations.map(\.id)

        let snapshot = ReaderVisibleAssetResolver.resolve(
            presentationIDs: pagePresentationIDs,
            layout: fixture.layout,
            assetResolver: fixture.assetResolver
        )

        XCTAssertEqual(snapshot.pageIDs, Set(fixture.pageIDs))
        XCTAssertEqual(snapshot.presentationIDs, pagePresentationIDs)
        XCTAssertEqual(
            snapshot.assetIdentities,
            Set(fixture.pageIDs.map { pageID in
                ReaderPageAssetIdentity(
                    comicID: fixture.comicID,
                    revision: fixture.revision,
                    pageID: pageID
                )
            })
        )
    }

    func testResolveIncludesBothPagesFromSpreadAndDeduplicatesInput() throws {
        let fixture = makeFixture(mode: .spread)
        let spreadID = try XCTUnwrap(
            fixture.layout.presentations.first { presentation in
                if case .spread = presentation.content {
                    return true
                }
                return false
            }?.id
        )

        let snapshot = ReaderVisibleAssetResolver.resolve(
            presentationIDs: [spreadID, spreadID],
            layout: fixture.layout,
            assetResolver: fixture.assetResolver
        )

        XCTAssertEqual(snapshot.pageIDs, Set(fixture.pageIDs))
        XCTAssertEqual(snapshot.presentationIDs, [spreadID])
        XCTAssertEqual(snapshot.assetIdentities.count, 2)
    }

    func testBoundaryAndUnknownPresentationDoNotProducePages() throws {
        let fixture = makeFixture(mode: .singlePage)
        let boundaryID = try XCTUnwrap(
            fixture.layout.presentations.first { presentation in
                if case .chapterBoundary = presentation.content {
                    return true
                }
                return false
            }?.id
        )
        let unknownID = ReaderPresentationID.page(
            .chapter(
                ImportChapterCandidate.ID(rawValue: "unknown-chapter"),
                ImportPageCandidate.ID(rawValue: "unknown-page")
            )
        )

        let snapshot = ReaderVisibleAssetResolver.resolve(
            presentationIDs: [boundaryID, unknownID],
            layout: fixture.layout,
            assetResolver: fixture.assetResolver
        )

        XCTAssertEqual(snapshot.presentationIDs, [boundaryID])
        XCTAssertTrue(snapshot.pageIDs.isEmpty)
        XCTAssertTrue(snapshot.assetIdentities.isEmpty)
    }

    func testCorruptedAndFailedPagesKeepIDsButSkipIdentities() {
        let comicID = managedComicID(
            "00000000-0000-0000-0000-000000000902"
        )
        let corruptedPageID = ImportPageCandidate.ID(rawValue: "corrupted")
        let failedPageID = ImportPageCandidate.ID(rawValue: "failed")
        let chapterID = ImportChapterCandidate.ID(rawValue: "chapter")
        let comic = ReaderComic(
            id: comicID,
            displayName: "Unreadable Comic",
            chapters: [
                ReaderChapter(
                    id: chapterID,
                    displayName: "Chapter",
                    pages: [
                        ReaderPage(
                            id: corruptedPageID,
                            state: .corrupted
                        ),
                        ReaderPage(id: failedPageID),
                    ]
                ),
            ]
        )
        let layout = ReaderLayout(
            comic: comic,
            requestedMode: .continuous,
            direction: .leftToRight,
            capability: .spreadCapable
        )
        let assetResolver = StubPageAssetResolver(
            comicID: comicID,
            revision: ImportPreviewRevision(rawValue: "unreadable-revision"),
            failingPageIDs: [failedPageID]
        )

        let snapshot = ReaderVisibleAssetResolver.resolve(
            presentationIDs: layout.presentations.map(\.id),
            layout: layout,
            assetResolver: assetResolver
        )

        XCTAssertEqual(
            snapshot.pageIDs,
            [corruptedPageID, failedPageID]
        )
        XCTAssertEqual(
            snapshot.presentationIDs,
            layout.presentations.map(\.id)
        )
        XCTAssertTrue(snapshot.assetIdentities.isEmpty)
    }

    func testContinuousResolveIncludesEveryIntersectingPresentation() {
        let fixture = makeFixture(mode: .continuous)
        let firstLocation = location(
            for: fixture.pageIDs[0],
            chapterID: fixture.chapterID
        )
        let secondLocation = location(
            for: fixture.pageIDs[1],
            chapterID: fixture.chapterID
        )
        let snapshot = ReaderVisibleAssetResolver.resolveContinuous(
            geometries: [
                geometry(
                    index: 1,
                    location: secondLocation,
                    minY: 150,
                    height: 600
                ),
                geometry(
                    index: 0,
                    location: firstLocation,
                    minY: -100,
                    height: 250
                ),
            ],
            viewportHeight: 500,
            layout: fixture.layout,
            assetResolver: fixture.assetResolver
        )

        XCTAssertEqual(snapshot.pageIDs, Set(fixture.pageIDs))
        XCTAssertEqual(
            snapshot.presentationIDs,
            fixture.layout.presentations.map(\.id)
        )
        XCTAssertEqual(snapshot.assetIdentities.count, 2)
    }

    func testContinuousResolveReevaluatesStoredGeometryForTallerViewport() {
        let fixture = makeFixture(mode: .continuous)
        let geometries = [
            geometry(
                index: 0,
                location: location(
                    for: fixture.pageIDs[0],
                    chapterID: fixture.chapterID
                ),
                minY: 0,
                height: 400
            ),
            geometry(
                index: 1,
                location: location(
                    for: fixture.pageIDs[1],
                    chapterID: fixture.chapterID
                ),
                minY: 500,
                height: 400
            ),
        ]

        let shortViewport = ReaderVisibleAssetResolver.resolveContinuous(
            geometries: geometries,
            viewportHeight: 450,
            layout: fixture.layout,
            assetResolver: fixture.assetResolver
        )
        let tallViewport = ReaderVisibleAssetResolver.resolveContinuous(
            geometries: geometries,
            viewportHeight: 600,
            layout: fixture.layout,
            assetResolver: fixture.assetResolver
        )

        XCTAssertEqual(shortViewport.pageIDs, [fixture.pageIDs[0]])
        XCTAssertEqual(tallViewport.pageIDs, Set(fixture.pageIDs))
        XCTAssertEqual(shortViewport.presentationIDs.count, 1)
        XCTAssertEqual(tallViewport.presentationIDs.count, 2)
    }

    func testContinuousResolveMapsVisibleSpreadToBothPages() throws {
        let fixture = makeFixture(mode: .spread)
        let spread = try XCTUnwrap(
            fixture.layout.presentations.first { presentation in
                if case .spread = presentation.content {
                    return true
                }
                return false
            }
        )
        let firstLocation = try XCTUnwrap(spread.locations.first)
        let snapshot = ReaderVisibleAssetResolver.resolveContinuous(
            geometries: [
                ReaderContinuousPageGeometry(
                    index: 0,
                    presentationID: spread.id,
                    location: firstLocation,
                    minY: 100,
                    height: 300
                ),
            ],
            viewportHeight: 500,
            layout: fixture.layout,
            assetResolver: fixture.assetResolver
        )

        XCTAssertEqual(snapshot.pageIDs, Set(fixture.pageIDs))
        XCTAssertEqual(snapshot.presentationIDs, [spread.id])
        XCTAssertEqual(snapshot.assetIdentities.count, 2)
    }

    func testContinuousResolveDoesNotExpandOffscreenGeometryWithTolerance() {
        let fixture = makeFixture(mode: .continuous)
        let firstLocation = location(
            for: fixture.pageIDs[0],
            chapterID: fixture.chapterID
        )
        let secondLocation = location(
            for: fixture.pageIDs[1],
            chapterID: fixture.chapterID
        )
        let snapshot = ReaderVisibleAssetResolver.resolveContinuous(
            geometries: [
                geometry(
                    index: 0,
                    location: firstLocation,
                    minY: -101,
                    height: 100
                ),
                geometry(
                    index: 1,
                    location: secondLocation,
                    minY: 500.5,
                    height: 100
                ),
            ],
            viewportHeight: 500,
            layout: fixture.layout,
            assetResolver: fixture.assetResolver,
            pointTolerance: 1
        )

        XCTAssertEqual(snapshot, .empty)
    }

    func testContinuousResolveFiltersInvalidGeometryAndBoundary() throws {
        let fixture = makeFixture(mode: .singlePage)
        let validLocation = location(
            for: fixture.pageIDs[0],
            chapterID: fixture.chapterID
        )
        let invalidLocation = location(
            for: fixture.pageIDs[1],
            chapterID: fixture.chapterID
        )
        let boundaryID = try XCTUnwrap(
            fixture.layout.presentations.first { presentation in
                if case .chapterBoundary = presentation.content {
                    return true
                }
                return false
            }?.id
        )

        let snapshot = ReaderVisibleAssetResolver.resolveContinuous(
            geometries: [
                geometry(
                    index: 0,
                    location: validLocation,
                    minY: 0,
                    height: 100
                ),
                geometry(
                    index: 1,
                    location: invalidLocation,
                    minY: .nan,
                    height: 100
                ),
                geometry(
                    index: 2,
                    location: invalidLocation,
                    minY: 0,
                    height: .infinity
                ),
                geometry(
                    index: 3,
                    location: invalidLocation,
                    minY: 0,
                    height: 0
                ),
                geometry(
                    index: 4,
                    location: invalidLocation,
                    minY: 0,
                    height: -1
                ),
                geometry(
                    index: 5,
                    location: invalidLocation,
                    minY: .greatestFiniteMagnitude,
                    height: .greatestFiniteMagnitude
                ),
                ReaderContinuousPageGeometry(
                    index: 6,
                    presentationID: boundaryID,
                    location: validLocation,
                    minY: 100,
                    height: 100
                ),
            ],
            viewportHeight: 500,
            layout: fixture.layout,
            assetResolver: fixture.assetResolver
        )

        XCTAssertEqual(snapshot.pageIDs, [fixture.pageIDs[0]])
        XCTAssertEqual(
            snapshot.presentationIDs,
            [
                .page(validLocation),
                boundaryID,
            ]
        )
        XCTAssertEqual(snapshot.assetIdentities.count, 1)
    }

    func testResolveCanonicalizesKnownPresentationIDs() throws {
        let fixture = makeFixture(mode: .continuous)
        let firstID = try XCTUnwrap(fixture.layout.presentations.first?.id)
        let lastID = try XCTUnwrap(fixture.layout.presentations.last?.id)
        let unknownID = ReaderPresentationID.page(
            .chapter(
                ImportChapterCandidate.ID(rawValue: "unknown-chapter"),
                ImportPageCandidate.ID(rawValue: "unknown-page")
            )
        )

        let snapshot = ReaderVisibleAssetResolver.resolve(
            presentationIDs: [lastID, unknownID, firstID, lastID],
            layout: fixture.layout,
            assetResolver: fixture.assetResolver
        )

        XCTAssertEqual(snapshot.presentationIDs, [firstID, lastID])
        XCTAssertEqual(snapshot.pageIDs, Set(fixture.pageIDs))
        XCTAssertEqual(snapshot.assetIdentities.count, 2)
    }

    func testResolveUsesLogicalOrderForPhysicalRTLInput() {
        let fixture = makeFixture(
            mode: .singlePage,
            direction: .rightToLeft
        )

        let snapshot = ReaderVisibleAssetResolver.resolve(
            presentationIDs: fixture.layout.pagedDisplayPresentations.map(\.id),
            layout: fixture.layout,
            assetResolver: fixture.assetResolver
        )

        XCTAssertEqual(
            snapshot.presentationIDs,
            fixture.layout.presentations.map(\.id)
        )
        XCTAssertEqual(snapshot.pageIDs, Set(fixture.pageIDs))
        XCTAssertEqual(snapshot.assetIdentities.count, 2)
    }

    func testContinuousResolveRejectsInvalidViewportAndTolerance() {
        let fixture = makeFixture(mode: .continuous)
        let pageLocation = location(
            for: fixture.pageIDs[0],
            chapterID: fixture.chapterID
        )
        let pageGeometry = geometry(
            index: 0,
            location: pageLocation,
            minY: 0,
            height: 100
        )
        let invalidViewportHeights = [
            0,
            -1,
            Double.nan,
            Double.infinity,
        ]

        for viewportHeight in invalidViewportHeights {
            XCTAssertEqual(
                ReaderVisibleAssetResolver.resolveContinuous(
                    geometries: [pageGeometry],
                    viewportHeight: viewportHeight,
                    layout: fixture.layout,
                    assetResolver: fixture.assetResolver
                ),
                .empty
            )
        }

        for pointTolerance in [-1, Double.nan, Double.infinity] {
            XCTAssertEqual(
                ReaderVisibleAssetResolver.resolveContinuous(
                    geometries: [pageGeometry],
                    viewportHeight: 500,
                    layout: fixture.layout,
                    assetResolver: fixture.assetResolver,
                    pointTolerance: pointTolerance
                ),
                .empty
            )
        }
    }

    private func makeFixture(
        mode: ReadingMode,
        direction: ReadingDirection = .leftToRight
    ) -> Fixture {
        let comicID = managedComicID(
            "00000000-0000-0000-0000-000000000901"
        )
        let revision = ImportPreviewRevision(rawValue: "visible-revision")
        let chapterID = ImportChapterCandidate.ID(rawValue: "chapter-1")
        let pageIDs = [
            ImportPageCandidate.ID(rawValue: "page-1"),
            ImportPageCandidate.ID(rawValue: "page-2"),
        ]
        let pages = pageIDs.map { pageID in
            ReaderPage(
                id: pageID,
                displayPixelSize: ImportPixelSize(width: 1_000, height: 1_500)
            )
        }
        let comic = ReaderComic(
            id: comicID,
            displayName: "Visible Comic",
            chapters: [
                ReaderChapter(
                    id: chapterID,
                    displayName: "Chapter 1",
                    pages: pages
                ),
            ]
        )

        return Fixture(
            comicID: comicID,
            revision: revision,
            chapterID: chapterID,
            pageIDs: pageIDs,
            layout: ReaderLayout(
                comic: comic,
                requestedMode: mode,
                direction: direction,
                capability: .spreadCapable
            ),
            assetResolver: StubPageAssetResolver(
                comicID: comicID,
                revision: revision
            )
        )
    }

    private func geometry(
        index: Int,
        location: ReaderPageLocation,
        minY: Double,
        height: Double
    ) -> ReaderContinuousPageGeometry {
        ReaderContinuousPageGeometry(
            index: index,
            presentationID: .page(location),
            location: location,
            minY: minY,
            height: height
        )
    }

    private func location(
        for pageID: ImportPageCandidate.ID,
        chapterID: ImportChapterCandidate.ID
    ) -> ReaderPageLocation {
        .chapter(chapterID, pageID)
    }

    private func managedComicID(_ value: String) -> ManagedComicID {
        ManagedComicID(rawValue: UUID(uuidString: value)!)
    }
}

private struct Fixture {
    let comicID: ManagedComicID
    let revision: ImportPreviewRevision
    let chapterID: ImportChapterCandidate.ID
    let pageIDs: [ImportPageCandidate.ID]
    let layout: ReaderLayout
    let assetResolver: StubPageAssetResolver
}

private enum StubPageAssetResolverError: Error {
    case unavailable
}

private struct StubPageAssetResolver: ReaderPageAssetResolving {
    let comicID: ManagedComicID
    let revision: ImportPreviewRevision
    let failingPageIDs: Set<ImportPageCandidate.ID>

    init(
        comicID: ManagedComicID,
        revision: ImportPreviewRevision,
        failingPageIDs: Set<ImportPageCandidate.ID> = []
    ) {
        self.comicID = comicID
        self.revision = revision
        self.failingPageIDs = failingPageIDs
    }

    func asset(
        for pageID: ImportPageCandidate.ID
    ) throws -> ReaderPageAsset {
        guard !failingPageIDs.contains(pageID) else {
            throw StubPageAssetResolverError.unavailable
        }

        return ReaderPageAsset(
            identity: ReaderPageAssetIdentity(
                comicID: comicID,
                revision: revision,
                pageID: pageID
            ),
            comicRootURL: URL(fileURLWithPath: "/tmp/VisibleAssets"),
            managedRelativePath: ManagedRelativePath(
                components: ["original", "\(pageID.rawValue).png"]
            ),
            mediaType: .png,
            expectedByteCount: 1,
            expectedPixelSize: nil,
            orientation: nil
        )
    }
}
