import CoreGraphics
import Foundation
import XCTest
@testable import ComicReader

final class ReaderPrefetchAssetBatchResolverTests: XCTestCase {
    func testResolvesFullPageAndSpreadBatchesInPlanOrder() throws {
        let cover = makePage("cover", isCover: true)
        let firstPage = makePage("page-1")
        let secondPage = makePage("page-2")
        let widePage = makePage(
            "wide-page",
            displayPixelSize: ImportPixelSize(width: 1_500, height: 1_000)
        )
        let layout = makeLayout(
            cover: cover,
            pages: [firstPage, secondPage, widePage],
            mode: .spread
        )
        let coverPresentation = try XCTUnwrap(
            layout.presentations.first { presentation in
                presentation.locations.first?.pageID == cover.id
            }
        )
        let spreadPresentation = try XCTUnwrap(
            layout.presentations.first { presentation in
                if case .spread = presentation.content {
                    return true
                }
                return false
            }
        )
        let widePagePresentation = try XCTUnwrap(
            layout.presentations.first { presentation in
                guard case let .page(page) = presentation.content else {
                    return false
                }
                return page.page.id == widePage.id
            }
        )
        let fullPageTarget = try ReaderImageTarget(maximumPixelSize: 2_048)
        let spreadPageTarget = try ReaderImageTarget(maximumPixelSize: 1_024)

        let batches = ReaderPrefetchAssetBatchResolver.resolve(
            plan: ReaderPrefetchPlan(
                presentationIDs: [
                    coverPresentation.id,
                    spreadPresentation.id,
                    widePagePresentation.id,
                ]
            ),
            layout: layout,
            assetResolver: StubPrefetchPageAssetResolver(),
            targets: ReaderPrefetchTargets(
                fullPage: fullPageTarget,
                spreadPage: spreadPageTarget
            )
        )

        XCTAssertEqual(
            batches.map(\.target),
            [fullPageTarget, spreadPageTarget, fullPageTarget]
        )
        XCTAssertEqual(
            batches.map { batch in
                batch.assets.map(\.identity.pageID)
            },
            [
                [cover.id],
                [firstPage.id, secondPage.id],
                [widePage.id],
            ]
        )

        let reversedBatches = ReaderPrefetchAssetBatchResolver.resolve(
            plan: ReaderPrefetchPlan(
                presentationIDs: [
                    spreadPresentation.id,
                    widePagePresentation.id,
                    coverPresentation.id,
                ]
            ),
            layout: layout,
            assetResolver: StubPrefetchPageAssetResolver(),
            targets: ReaderPrefetchTargets(
                fullPage: fullPageTarget,
                spreadPage: spreadPageTarget
            )
        )

        XCTAssertEqual(
            reversedBatches.map(\.target),
            [spreadPageTarget, fullPageTarget]
        )
        XCTAssertEqual(
            reversedBatches.map { batch in
                batch.assets.map(\.identity.pageID)
            },
            [
                [firstPage.id, secondPage.id],
                [widePage.id, cover.id],
            ]
        )
    }

    func testSkipsBoundaryCorruptedFailureAndDuplicateAssets() throws {
        let readablePage = makePage("readable")
        let corruptedPage = makePage("corrupted", state: .corrupted)
        let failedPage = makePage("failed")
        let layout = makeLayout(
            pages: [readablePage, corruptedPage, failedPage],
            mode: .singlePage
        )
        let readablePresentationID = try presentationID(
            for: readablePage.id,
            in: layout
        )
        let corruptedPresentationID = try presentationID(
            for: corruptedPage.id,
            in: layout
        )
        let failedPresentationID = try presentationID(
            for: failedPage.id,
            in: layout
        )
        let boundaryID = try XCTUnwrap(
            layout.presentations.first { presentation in
                if case .chapterBoundary = presentation.content {
                    return true
                }
                return false
            }?.id
        )
        let target = try ReaderImageTarget(maximumPixelSize: 1_024)

        let batches = ReaderPrefetchAssetBatchResolver.resolve(
            plan: ReaderPrefetchPlan(
                presentationIDs: [
                    readablePresentationID,
                    corruptedPresentationID,
                    failedPresentationID,
                    boundaryID,
                    readablePresentationID,
                ]
            ),
            layout: layout,
            assetResolver: StubPrefetchPageAssetResolver(
                failingPageIDs: [failedPage.id]
            ),
            targets: ReaderPrefetchTargets(
                fullPage: target,
                spreadPage: nil
            )
        )

        XCTAssertEqual(batches.count, 1)
        XCTAssertEqual(batches.first?.target, target)
        XCTAssertEqual(
            batches.first?.assets.map(\.identity.pageID),
            [readablePage.id]
        )
    }

    func testKeepsReadableSpreadPageWhenSiblingAssetResolutionFails() throws {
        let firstPage = makePage("page-1")
        let secondPage = makePage("page-2")
        let layout = makeLayout(
            pages: [firstPage, secondPage],
            mode: .spread
        )
        let spreadPresentation = try XCTUnwrap(
            layout.presentations.first { presentation in
                if case .spread = presentation.content {
                    return true
                }
                return false
            }
        )
        let target = try ReaderImageTarget(maximumPixelSize: 1_024)

        let batches = ReaderPrefetchAssetBatchResolver.resolve(
            plan: ReaderPrefetchPlan(
                presentationIDs: [spreadPresentation.id]
            ),
            layout: layout,
            assetResolver: StubPrefetchPageAssetResolver(
                failingPageIDs: [firstPage.id]
            ),
            targets: ReaderPrefetchTargets(
                fullPage: nil,
                spreadPage: target
            )
        )

        XCTAssertEqual(batches.count, 1)
        XCTAssertEqual(batches.first?.target, target)
        XCTAssertEqual(
            batches.first?.assets.map(\.identity.pageID),
            [secondPage.id]
        )
    }

    func testReturnsNoBatchesForEmptyUnknownOrUnavailableTargets() throws {
        let page = makePage("page")
        let layout = makeLayout(pages: [page], mode: .singlePage)
        let presentationID = try presentationID(for: page.id, in: layout)
        let target = try ReaderImageTarget(maximumPixelSize: 1_024)
        let resolver = StubPrefetchPageAssetResolver()
        let unknownID = ReaderPresentationID.page(
            .chapter(
                ImportChapterCandidate.ID(rawValue: "unknown-chapter"),
                ImportPageCandidate.ID(rawValue: "unknown-page")
            )
        )

        XCTAssertTrue(
            ReaderPrefetchAssetBatchResolver.resolve(
                plan: ReaderPrefetchPlan(presentationIDs: []),
                layout: layout,
                assetResolver: resolver,
                targets: ReaderPrefetchTargets(
                    fullPage: target,
                    spreadPage: target
                )
            ).isEmpty
        )
        XCTAssertTrue(
            ReaderPrefetchAssetBatchResolver.resolve(
                plan: ReaderPrefetchPlan(presentationIDs: [unknownID]),
                layout: layout,
                assetResolver: resolver,
                targets: ReaderPrefetchTargets(
                    fullPage: target,
                    spreadPage: target
                )
            ).isEmpty
        )
        XCTAssertTrue(
            ReaderPrefetchAssetBatchResolver.resolve(
                plan: ReaderPrefetchPlan(
                    presentationIDs: [presentationID]
                ),
                layout: layout,
                assetResolver: resolver,
                targets: ReaderPrefetchTargets(
                    fullPage: nil,
                    spreadPage: nil
                )
            ).isEmpty
        )
    }

    func testPrefetchTargetsUseBaseViewportScale() {
        let targets = ReaderPrefetchTargetPolicy.targets(
            viewportSize: CGSize(width: 1_366, height: 1_024),
            displayScale: 2
        )

        XCTAssertEqual(targets.fullPage?.maximumPixelSize, 2_816)
        XCTAssertEqual(targets.spreadPage?.maximumPixelSize, 2_048)
    }

    func testPrefetchTargetsRejectInvalidViewportMetrics() {
        let targets = ReaderPrefetchTargetPolicy.targets(
            viewportSize: .zero,
            displayScale: 2
        )

        XCTAssertNil(targets.fullPage)
        XCTAssertNil(targets.spreadPage)
    }

    private func makeLayout(
        cover: ReaderPage? = nil,
        pages: [ReaderPage],
        mode: ReadingMode
    ) -> ReaderLayout {
        ReaderLayout(
            comic: ReaderComic(
                id: managedComicID,
                displayName: "Prefetch Assets",
                cover: cover,
                chapters: [
                    ReaderChapter(
                        id: chapterID,
                        displayName: "Chapter",
                        pages: pages
                    ),
                ]
            ),
            requestedMode: mode,
            direction: .leftToRight,
            capability: .spreadCapable
        )
    }

    private func makePage(
        _ rawValue: String,
        state: ImportPageState = .readable,
        displayPixelSize: ImportPixelSize = ImportPixelSize(
            width: 1_000,
            height: 1_500
        ),
        isCover: Bool = false
    ) -> ReaderPage {
        ReaderPage(
            id: ImportPageCandidate.ID(rawValue: rawValue),
            displayPixelSize: displayPixelSize,
            state: state,
            isCover: isCover
        )
    }

    private func presentationID(
        for pageID: ImportPageCandidate.ID,
        in layout: ReaderLayout
    ) throws -> ReaderPresentationID {
        try XCTUnwrap(
            layout.presentations.first { presentation in
                presentation.locations.contains { $0.pageID == pageID }
            }?.id
        )
    }

    private var managedComicID: ManagedComicID {
        ManagedComicID(
            rawValue: UUID(
                uuidString: "00000000-0000-0000-0000-000000000922"
            )!
        )
    }

    private var chapterID: ImportChapterCandidate.ID {
        ImportChapterCandidate.ID(rawValue: "chapter")
    }
}

private enum StubPrefetchPageAssetResolverError: Error {
    case unavailable
}

private struct StubPrefetchPageAssetResolver: ReaderPageAssetResolving {
    let failingPageIDs: Set<ImportPageCandidate.ID>

    init(failingPageIDs: Set<ImportPageCandidate.ID> = []) {
        self.failingPageIDs = failingPageIDs
    }

    func asset(
        for pageID: ImportPageCandidate.ID
    ) throws -> ReaderPageAsset {
        guard !failingPageIDs.contains(pageID) else {
            throw StubPrefetchPageAssetResolverError.unavailable
        }

        return ReaderPageAsset(
            identity: ReaderPageAssetIdentity(
                comicID: ManagedComicID(
                    rawValue: UUID(
                        uuidString: "00000000-0000-0000-0000-000000000922"
                    )!
                ),
                revision: ImportPreviewRevision(rawValue: "prefetch-revision"),
                pageID: pageID
            ),
            comicRootURL: URL(fileURLWithPath: "/tmp/PrefetchAssets"),
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
