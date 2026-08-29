import Foundation
import XCTest
@testable import ComicReader

final class ImportUpdateDiffTests: XCTestCase {
    func testEmptyDiffWhenFreshScanMatchesStoredContent() {
        let stored = makeStoredComic(
            chapters: [
                makeStoredChapter(["Chapter 1"], pageNames: ["01.png", "02.png"]),
                makeStoredChapter(["Chapter 2"], pageNames: ["01.png"]),
            ]
        )
        let fresh = makeManifest(
            chapters: [
                makeFreshChapter(["Chapter 1"], pageNames: ["01.png", "02.png"]),
                makeFreshChapter(["Chapter 2"], pageNames: ["01.png"]),
            ]
        )

        let diff = ImportUpdateDiffCalculator.make(
            storedChapters: stored.chapters,
            storedWorkItems: stored.workItems,
            freshManifest: fresh
        )

        XCTAssertTrue(diff.isEmpty)
        XCTAssertEqual(diff.unchangedChapterCount, 2)
    }

    func testNewSourceChapterIsReportedAsAddition() {
        let stored = makeStoredComic(
            chapters: [
                makeStoredChapter(["Chapter 1"], pageNames: ["01.png"]),
            ]
        )
        let addedChapter = makeFreshChapter(
            ["Chapter 2"],
            pageNames: ["01.png"]
        )
        let fresh = makeManifest(
            chapters: [
                makeFreshChapter(["Chapter 1"], pageNames: ["01.png"]),
                addedChapter,
            ]
        )

        let diff = ImportUpdateDiffCalculator.make(
            storedChapters: stored.chapters,
            storedWorkItems: stored.workItems,
            freshManifest: fresh
        )

        XCTAssertEqual(diff.addedChapters.map(\.id), [addedChapter.chapter.id])
        XCTAssertEqual(diff.unchangedChapterCount, 1)
    }

    func testVanishedSourceChapterIsReportedAsMissing() {
        let missingChapter = makeStoredChapter(
            ["Chapter 2"],
            pageNames: ["01.png"]
        )
        let stored = makeStoredComic(chapters: [
            makeStoredChapter(["Chapter 1"], pageNames: ["01.png"]),
            missingChapter,
        ])
        let fresh = makeManifest(
            chapters: [
                makeFreshChapter(["Chapter 1"], pageNames: ["01.png"]),
            ]
        )

        let diff = ImportUpdateDiffCalculator.make(
            storedChapters: stored.chapters,
            storedWorkItems: stored.workItems,
            freshManifest: fresh
        )

        XCTAssertEqual(
            diff.missingChapters,
            [
                ImportUpdateMissingChapter(
                    chapterID: missingChapter.chapter.id,
                    sourceDirectoryPath: SourceRelativePath(
                        components: ["Chapter 2"]
                    )
                ),
            ]
        )
        XCTAssertTrue(diff.addedChapters.isEmpty)
        XCTAssertEqual(diff.unchangedChapterCount, 1)
    }

    func testAddedPageMarksChapterForReplacement() {
        let stored = makeStoredComic(
            chapters: [
                makeStoredChapter(["Chapter 1"], pageNames: ["01.png"]),
            ]
        )
        let fresh = makeManifest(
            chapters: [
                makeFreshChapter(
                    ["Chapter 1"],
                    pageNames: ["01.png", "02.png"]
                ),
            ]
        )

        let diff = ImportUpdateDiffCalculator.make(
            storedChapters: stored.chapters,
            storedWorkItems: stored.workItems,
            freshManifest: fresh
        )

        XCTAssertEqual(diff.replacedChapters.count, 1)
        XCTAssertEqual(
            diff.replacedChapters.first?.addedPagePaths,
            [SourceRelativePath(components: ["Chapter 1", "02.png"])]
        )
        XCTAssertTrue(diff.replacedChapters.first?.removedPagePaths.isEmpty ?? false)
        XCTAssertTrue(diff.replacedChapters.first?.changedPagePaths.isEmpty ?? false)
        XCTAssertEqual(diff.unchangedChapterCount, 0)
    }

    func testRemovedPageMarksChapterForReplacement() {
        let stored = makeStoredComic(
            chapters: [
                makeStoredChapter(
                    ["Chapter 1"],
                    pageNames: ["01.png", "02.png"]
                ),
            ]
        )
        let fresh = makeManifest(
            chapters: [
                makeFreshChapter(["Chapter 1"], pageNames: ["02.png"]),
            ]
        )

        let diff = ImportUpdateDiffCalculator.make(
            storedChapters: stored.chapters,
            storedWorkItems: stored.workItems,
            freshManifest: fresh
        )

        XCTAssertEqual(diff.replacedChapters.count, 1)
        XCTAssertEqual(
            diff.replacedChapters.first?.removedPagePaths,
            [SourceRelativePath(components: ["Chapter 1", "01.png"])]
        )
        XCTAssertTrue(diff.replacedChapters.first?.addedPagePaths.isEmpty ?? false)
    }

    func testChangedFingerprintMarksChapterForReplacement() {
        let stored = makeStoredComic(
            chapters: [
                makeStoredChapter(
                    ["Chapter 1"],
                    pageNames: ["01.png", "02.png"]
                ),
            ]
        )
        let fresh = makeManifest(
            chapters: [
                makeFreshChapter(
                    ["Chapter 1"],
                    pageNames: ["01.png", "02.png"],
                    fingerprintOverrides: ["02.png": "updated"]
                ),
            ]
        )

        let diff = ImportUpdateDiffCalculator.make(
            storedChapters: stored.chapters,
            storedWorkItems: stored.workItems,
            freshManifest: fresh
        )

        XCTAssertEqual(diff.replacedChapters.count, 1)
        XCTAssertEqual(
            diff.replacedChapters.first?.changedPagePaths,
            [SourceRelativePath(components: ["Chapter 1", "02.png"])]
        )
        XCTAssertTrue(diff.replacedChapters.first?.addedPagePaths.isEmpty ?? false)
        XCTAssertTrue(diff.replacedChapters.first?.removedPagePaths.isEmpty ?? false)
    }

    func testReadablePageTurningCorruptedMarksChapterForReplacement() {
        let stored = makeStoredComic(
            chapters: [
                makeStoredChapter(["Chapter 1"], pageNames: ["01.png"]),
            ]
        )
        let fresh = makeManifest(
            chapters: [
                makeFreshChapter(
                    ["Chapter 1"],
                    pageNames: ["01.png"],
                    stateOverrides: ["01.png": .corrupted],
                    fingerprintOverrides: ["01.png": nil]
                ),
            ]
        )

        let diff = ImportUpdateDiffCalculator.make(
            storedChapters: stored.chapters,
            storedWorkItems: stored.workItems,
            freshManifest: fresh
        )

        XCTAssertEqual(diff.replacedChapters.count, 1)
        XCTAssertEqual(
            diff.replacedChapters.first?.changedPagePaths,
            [SourceRelativePath(components: ["Chapter 1", "01.png"])]
        )
    }

    func testRoleChangeAtSamePathStillMatchesByPath() {
        let stored = makeStoredComic(
            chapters: [
                makeStoredChapter(
                    ["Chapter 1"],
                    pageNames: ["01.png"],
                    role: .directory
                ),
            ]
        )
        let fresh = makeManifest(
            chapters: [
                makeFreshChapter(
                    ["Chapter 1"],
                    pageNames: ["01.png"],
                    role: .collectionLoosePages
                ),
            ]
        )

        let diff = ImportUpdateDiffCalculator.make(
            storedChapters: stored.chapters,
            storedWorkItems: stored.workItems,
            freshManifest: fresh
        )

        XCTAssertTrue(diff.isEmpty)
        XCTAssertEqual(diff.unchangedChapterCount, 1)
    }

    func testMixedDiffPreservesStoredAndFreshOrdering() {
        let unchangedA = makeStoredChapter(["A"], pageNames: ["01.png"])
        let replacedB = makeStoredChapter(
            ["B"],
            pageNames: ["01.png", "02.png"]
        )
        let missingC = makeStoredChapter(["C"], pageNames: ["01.png"])
        let unchangedD = makeStoredChapter(["D"], pageNames: ["01.png"])
        let replacedF = makeStoredChapter(["F"], pageNames: ["01.png"])
        let stored = makeStoredComic(chapters: [
            unchangedA,
            replacedB,
            missingC,
            unchangedD,
            replacedF,
        ])

        let addedE = makeFreshChapter(["E"], pageNames: ["01.png"])
        let fresh = makeManifest(chapters: [
            makeFreshChapter(
                ["A"],
                pageNames: ["01.png"]
            ),
            makeFreshChapter(
                ["D"],
                pageNames: ["01.png"]
            ),
            makeFreshChapter(
                ["B"],
                pageNames: ["01.png", "02.png"],
                fingerprintOverrides: ["02.png": "updated"]
            ),
            addedE,
            makeFreshChapter(
                ["F"],
                pageNames: ["01.png"],
                fingerprintOverrides: ["01.png": "updated"]
            ),
        ])

        let diff = ImportUpdateDiffCalculator.make(
            storedChapters: stored.chapters,
            storedWorkItems: stored.workItems,
            freshManifest: fresh
        )

        XCTAssertEqual(
            diff.replacedChapters.map(\.storedChapterID.rawValue),
            [replacedB.chapter.id.rawValue, replacedF.chapter.id.rawValue]
        )
        XCTAssertEqual(
            diff.replacedChapters.map(\.sourceDirectoryPath.stringValue),
            ["B", "F"]
        )
        XCTAssertEqual(diff.missingChapters.map(\.chapterID.rawValue), [
            missingC.chapter.id.rawValue,
        ])
        XCTAssertEqual(diff.addedChapters.map(\.id), [addedE.chapter.id])
        XCTAssertEqual(diff.unchangedChapterCount, 2)
    }

    func testRootLoosePagesChapterMatchesByRootPath() {
        let stored = makeStoredComic(
            chapters: [
                makeStoredChapter([], pageNames: ["01.png"], role: .rootLoosePages),
            ]
        )
        let fresh = makeManifest(
            chapters: [
                makeFreshChapter(
                    [],
                    pageNames: ["01.png", "02.png"],
                    role: .rootLoosePages
                ),
            ]
        )

        let diff = ImportUpdateDiffCalculator.make(
            storedChapters: stored.chapters,
            storedWorkItems: stored.workItems,
            freshManifest: fresh
        )

        XCTAssertEqual(diff.replacedChapters.count, 1)
        XCTAssertEqual(
            diff.replacedChapters.first?.sourceDirectoryPath.stringValue,
            ""
        )
        XCTAssertEqual(
            diff.replacedChapters.first?.addedPagePaths,
            [SourceRelativePath(components: ["02.png"])]
        )
    }

    private func makeStoredComic(
        chapters: [(chapter: FrozenImportChapter, workItems: [FrozenImportWorkItem])]
    ) -> (chapters: [FrozenImportChapter], workItems: [FrozenImportWorkItem]) {
        (
            chapters.map(\.chapter),
            chapters.flatMap(\.workItems)
        )
    }

    private func makeStoredChapter(
        _ directoryComponents: [String],
        pageNames: [String],
        role: ImportChapterRole = .directory
    ) -> (chapter: FrozenImportChapter, workItems: [FrozenImportWorkItem]) {
        let directoryPath = SourceRelativePath(components: directoryComponents)
        let chapterID = ImportChapterCandidate.ID.sourcePath(
            directoryPath,
            role: role
        )
        var workItems: [FrozenImportWorkItem] = []
        var pageIDs: [ImportPageCandidate.ID] = []

        for pageName in pageNames {
            let pagePath = directoryPath.appending(pageName)
            let pageID = ImportPageCandidate.ID.sourcePath(pagePath)
            pageIDs.append(pageID)
            workItems.append(
                FrozenImportWorkItem(
                    id: pageID,
                    sourceRelativePath: pagePath,
                    managedRelativePath: ManagedRelativePath(
                        components: ["original", chapterID.rawValue, pageName]
                    ),
                    originalFileName: pageName,
                    detectedFormat: .png,
                    expectedByteCount: 1_024,
                    expectedLightweightFingerprint: "fingerprint:\(pageName)",
                    pageState: .readable,
                    isCover: false
                )
            )
        }

        return (
            chapter: FrozenImportChapter(
                id: chapterID,
                parentCollectionID: nil,
                sourceDirectoryPath: directoryPath,
                originalName: directoryPath.lastComponent ?? "root",
                displayName: directoryPath.lastComponent ?? "root",
                role: role,
                pageIDs: pageIDs
            ),
            workItems: workItems
        )
    }

    private func makeFreshChapter(
        _ directoryComponents: [String],
        pageNames: [String],
        role: ImportChapterRole = .directory,
        stateOverrides: [String: ImportPageState] = [:],
        fingerprintOverrides: [String: String?] = [:]
    ) -> (chapter: ImportChapterCandidate, pages: [ImportPageCandidate]) {
        let directoryPath = SourceRelativePath(components: directoryComponents)
        let chapterID = ImportChapterCandidate.ID.sourcePath(
            directoryPath,
            role: role
        )
        var pages: [ImportPageCandidate] = []
        var pageIDs: [ImportPageCandidate.ID] = []

        for (index, pageName) in pageNames.enumerated() {
            let pagePath = directoryPath.appending(pageName)
            let pageID = ImportPageCandidate.ID.sourcePath(pagePath)
            pageIDs.append(pageID)
            let fingerprint: String?
            if case let override? = fingerprintOverrides[pageName] {
                fingerprint = override
            } else {
                fingerprint = "fingerprint:\(pageName)"
            }

            pages.append(
                ImportPageCandidate(
                    id: pageID,
                    sourceRelativePath: pagePath,
                    originalFileName: pageName,
                    detectedFormat: .png,
                    byteCount: 1_024,
                    pixelSize: ImportPixelSize(width: 100, height: 150),
                    orientation: .up,
                    lightweightFingerprint: fingerprint,
                    state: stateOverrides[pageName] ?? .readable,
                    pageIndex: index
                )
            )
        }

        return (
            chapter: ImportChapterCandidate(
                id: chapterID,
                parentCollectionID: nil,
                sourceDirectoryPath: directoryPath,
                originalName: directoryPath.lastComponent ?? "root",
                role: role,
                siblingIndex: 0,
                pageIDs: pageIDs
            ),
            pages: pages
        )
    }

    private func makeManifest(
        chapters: [(chapter: ImportChapterCandidate, pages: [ImportPageCandidate])]
    ) -> ImportManifest {
        ImportManifest(
            sourceRootName: "Fresh Scan",
            sortLocaleIdentifier: "en_US",
            collections: [],
            chapters: chapters.map(\.chapter),
            pages: chapters.flatMap(\.pages),
            coverPageID: chapters.first?.pages.first?.id,
            issues: [],
            spaceEstimate: .make(contentBytes: 0, fileCount: 0)
        )
    }
}
