import Foundation
import XCTest
@testable import ComicReader

final class ComicUpdateDraftTests: XCTestCase {
    func testDefaultsIncludeAdditionsApplyReplacementsAndKeepMissing() throws {
        let fixture = try makeFixture { fresh in
            fresh.replaceChapter("Chapter 1", pageFingerprints: [
                "01.png": "fp-changed",
            ])
            fresh.removeChapter("Chapter 2")
            fresh.addChapter("Chapter 3", pageNames: ["01.png"])
        }

        let draft = ComicUpdateDraft(scan: fixture.scan)

        XCTAssertTrue(draft.isAddedChapterIncluded(fixture.addedChapterID("Chapter 3")))
        XCTAssertTrue(draft.isReplacementApplied(fixture.storedChapterID("Chapter 1")))
        XCTAssertFalse(draft.isMissingChapterRemoved(fixture.storedChapterID("Chapter 2")))

        let update = try draft.freeze()

        XCTAssertEqual(
            update.addedChapters.map(\.id.rawValue),
            [fixture.freshChapterID("Chapter 3").rawValue]
        )
        XCTAssertEqual(
            update.replacedChapters.map(\.storedChapterID.rawValue),
            [fixture.storedChapterID("Chapter 1").rawValue]
        )
        XCTAssertTrue(update.removedChapterIDs.isEmpty)
    }

    func testFrozenAddedWorkItemsUseManagedPathsAndFreshContent() throws {
        let fixture = try makeFixture { fresh in
            fresh.addChapter(
                "Chapter 3",
                pageNames: ["01.png"],
                byteCounts: ["01.png": 4_096]
            )
        }

        let update = try ComicUpdateDraft(scan: fixture.scan).freeze()

        XCTAssertEqual(update.addedWorkItems.count, 1)
        let workItem = try XCTUnwrap(update.addedWorkItems.first)
        XCTAssertEqual(
            workItem.managedRelativePath.components,
            ["original", "Chapter 3", "01.png"]
        )
        XCTAssertEqual(
            workItem.sourceRelativePath,
            SourceRelativePath(components: ["Chapter 3", "01.png"])
        )
        XCTAssertEqual(workItem.expectedByteCount, 4_096)
        XCTAssertEqual(
            workItem.expectedLightweightFingerprint,
            fixture.freshFingerprint("Chapter 3/01.png")
        )
        XCTAssertFalse(workItem.isCover)
    }

    func testAppliedReplacementMapsStoredChapterToFreshContent() throws {
        let fixture = try makeFixture { fresh in
            fresh.replaceChapter("Chapter 1", pageFingerprints: [
                "02.png": "fp-changed",
            ])
        }

        let update = try ComicUpdateDraft(scan: fixture.scan).freeze()

        XCTAssertEqual(update.replacedChapters.count, 1)
        let replacement = try XCTUnwrap(update.replacedChapters.first)
        XCTAssertEqual(
            replacement.storedChapterID,
            fixture.storedChapterID("Chapter 1")
        )
        XCTAssertEqual(
            replacement.freshChapter.id,
            fixture.freshChapterID("Chapter 1")
        )
        XCTAssertEqual(
            replacement.freshWorkItems.map(\.sourceRelativePath.stringValue),
            ["Chapter 1/01.png", "Chapter 1/02.png"]
        )
        XCTAssertEqual(
            replacement.freshWorkItems.last?.expectedLightweightFingerprint,
            "fp-changed"
        )
    }

    func testSkippingReplacementKeepsStoredChapterAndCopiesNothing() throws {
        let fixture = try makeFixture { fresh in
            fresh.replaceChapter("Chapter 1", pageFingerprints: [
                "01.png": "fp-changed",
            ])
            fresh.addChapter("Chapter 3", pageNames: ["01.png"])
        }
        var draft = ComicUpdateDraft(scan: fixture.scan)
        try draft.setReplacementApplied(
            fixture.storedChapterID("Chapter 1"),
            isApplied: false
        )

        let update = try draft.freeze()

        XCTAssertTrue(update.replacedChapters.isEmpty)
        XCTAssertEqual(update.addedWorkItems.count, 1)
    }

    func testConfirmedMissingChapterIsRemovedAndCanBeRestored() throws {
        let fixture = try makeFixture { fresh in
            fresh.removeChapter("Chapter 2")
        }
        var draft = ComicUpdateDraft(scan: fixture.scan)
        try draft.setMissingChapterRemoved(
            fixture.storedChapterID("Chapter 2"),
            isRemoved: true
        )

        let update = try draft.freeze()

        XCTAssertEqual(
            update.removedChapterIDs,
            [fixture.storedChapterID("Chapter 2")]
        )

        try draft.setMissingChapterRemoved(
            fixture.storedChapterID("Chapter 2"),
            isRemoved: false
        )
        XCTAssertTrue(try draft.freeze().removedChapterIDs.isEmpty)
    }

    func testRemovedMissingChaptersPreserveStoredOrder() throws {
        let fixture = try makeFixture { fresh in
            fresh.removeChapter("Chapter 1")
            fresh.removeChapter("Chapter 2")
            fresh.addChapter("Chapter 3", pageNames: ["01.png"])
        }
        var draft = ComicUpdateDraft(scan: fixture.scan)
        try draft.setMissingChapterRemoved(
            fixture.storedChapterID("Chapter 2"),
            isRemoved: true
        )
        try draft.setMissingChapterRemoved(
            fixture.storedChapterID("Chapter 1"),
            isRemoved: true
        )

        let update = try draft.freeze()

        XCTAssertEqual(
            update.removedChapterIDs,
            [
                fixture.storedChapterID("Chapter 1"),
                fixture.storedChapterID("Chapter 2"),
            ]
        )
    }

    func testInChapterCoverSurvivesReplacementThroughFreshPage() throws {
        let fixture = try makeFixture(
            standaloneCover: false,
            coverChapter: "Chapter 1",
            coverPage: "01.png"
        ) { fresh in
            fresh.replaceChapter("Chapter 1", pageFingerprints: [
                "02.png": "fp-changed",
            ])
        }

        let update = try ComicUpdateDraft(scan: fixture.scan).freeze()

        XCTAssertEqual(update.coverPageID, fixture.storedCoverPageID)
    }

    func testCoverFallsBackToFreshSuggestionWhenCoverPageVanishes() throws {
        let fixture = try makeFixture(
            standaloneCover: false,
            coverChapter: "Chapter 1",
            coverPage: "01.png"
        ) { fresh in
            fresh.replaceChapter(
                "Chapter 1",
                pageNames: ["02.png"],
                pageFingerprints: ["02.png": "fp-02"]
            )
        }

        let update = try ComicUpdateDraft(scan: fixture.scan).freeze()

        XCTAssertEqual(
            update.coverPageID,
            fixture.freshPageID("Chapter 1", "02.png")
        )
    }

    func testCoverFallsBackToFirstReadableWhenSuggestionUnavailable() throws {
        let fixture = try makeFixture(
            standaloneCover: false,
            coverChapter: "Chapter 1",
            coverPage: "01.png"
        ) { fresh in
            fresh.suggestsCover = false
            fresh.replaceChapter(
                "Chapter 1",
                pageNames: ["02.png"],
                pageFingerprints: ["02.png": "fp-02"]
            )
        }

        let update = try ComicUpdateDraft(scan: fixture.scan).freeze()

        XCTAssertEqual(
            update.coverPageID,
            fixture.freshPageID("Chapter 1", "02.png")
        )
    }

    func testRemovingEveryRemainingChapterThrows() throws {
        let fixture = try makeFixture { fresh in
            fresh.removeChapter("Chapter 1")
            fresh.removeChapter("Chapter 2")
        }
        var draft = ComicUpdateDraft(scan: fixture.scan)
        try draft.setMissingChapterRemoved(
            fixture.storedChapterID("Chapter 1"),
            isRemoved: true
        )
        try draft.setMissingChapterRemoved(
            fixture.storedChapterID("Chapter 2"),
            isRemoved: true
        )

        XCTAssertThrowsError(try draft.freeze()) { error in
            XCTAssertEqual(
                error as? ComicUpdateDraftError,
                .noReadableRemainingChapter
            )
        }
    }

    func testSpaceEstimateCountsOnlyCopiedWorkItems() throws {
        let fixture = try makeFixture { fresh in
            fresh.replaceChapter(
                "Chapter 1",
                pageNames: ["01.png", "02.png"],
                pageFingerprints: ["02.png": "fp-changed"],
                byteCounts: ["01.png": 1_000, "02.png": 2_000]
            )
            fresh.addChapter(
                "Chapter 3",
                pageNames: ["01.png"],
                byteCounts: ["01.png": 4_000]
            )
        }

        let update = try ComicUpdateDraft(scan: fixture.scan).freeze()

        XCTAssertEqual(update.spaceEstimate.contentBytes, 7_000)
        XCTAssertEqual(update.spaceEstimate.fileCount, 3)
    }

    func testAddedCollectionAncestorsAreIncluded() throws {
        let fixture = try makeFixture { fresh in
            fresh.addChapter(
                "Chapter 3",
                pageNames: ["01.png"],
                underCollection: "Volume 2"
            )
        }

        let update = try ComicUpdateDraft(scan: fixture.scan).freeze()

        XCTAssertEqual(update.addedCollections.count, 1)
        XCTAssertEqual(
            update.addedCollections.first?.originalName,
            "Volume 2"
        )
        XCTAssertEqual(
            update.addedChapters.first?.parentCollectionID,
            update.addedCollections.first?.id
        )
    }

    func testAdditionsPreserveFreshManifestOrder() throws {
        let fixture = try makeFixture { fresh in
            fresh.addChapter("Chapter 30", pageNames: ["01.png"])
            fresh.addChapter("Chapter 4", pageNames: ["01.png"])
        }

        let update = try ComicUpdateDraft(scan: fixture.scan).freeze()

        XCTAssertEqual(
            update.addedChapters.map(\.originalName),
            ["Chapter 30", "Chapter 4"]
        )
    }

    func testSelectionMutatorsRejectUnknownIdentifiers() throws {
        let fixture = try makeFixture { fresh in
            fresh.removeChapter("Chapter 2")
        }
        var draft = ComicUpdateDraft(scan: fixture.scan)

        XCTAssertThrowsError(
            try draft.setAddedChapterIncluded(
                ImportChapterCandidate.ID(rawValue: "chapter:unknown"),
                isIncluded: true
            )
        ) { error in
            XCTAssertEqual(error as? ComicUpdateDraftError, .unknownAddedChapter)
        }
        XCTAssertThrowsError(
            try draft.setReplacementApplied(
                ImportChapterCandidate.ID(rawValue: "chapter:unknown"),
                isApplied: true
            )
        ) { error in
            XCTAssertEqual(
                error as? ComicUpdateDraftError,
                .unknownReplacementChapter
            )
        }
        XCTAssertThrowsError(
            try draft.setMissingChapterRemoved(
                ImportChapterCandidate.ID(rawValue: "chapter:unknown"),
                isRemoved: true
            )
        ) { error in
            XCTAssertEqual(
                error as? ComicUpdateDraftError,
                .unknownMissingChapter
            )
        }
    }

    // MARK: - Fixture

    private func makeFixture(
        standaloneCover: Bool = true,
        coverChapter: String? = nil,
        coverPage: String? = nil,
        fresh: (inout FreshComicBuilder) throws -> Void
    ) throws -> UpdateDraftFixture {
        var builder = FreshComicBuilder()
        builder.addChapter("Chapter 1", pageNames: ["01.png", "02.png"])
        builder.addChapter("Chapter 2", pageNames: ["01.png"])
        try fresh(&builder)

        return try UpdateDraftFixture(
            standaloneCover: standaloneCover,
            coverChapter: coverChapter,
            coverPage: coverPage,
            fresh: builder
        )
    }
}

private struct UpdateDraftFixture {
    let scan: ComicSourceUpdateScan
    let storedChapterIDsByPath: [String: ImportChapterCandidate.ID]
    let freshChapterIDsByPath: [String: ImportChapterCandidate.ID]
    let freshFingerprintsByPath: [String: String]
    let freshPageIDsByPath: [String: ImportPageCandidate.ID]
    let storedCoverPageID: ImportPageCandidate.ID

    func storedChapterID(_ name: String) -> ImportChapterCandidate.ID {
        storedChapterIDsByPath[name]!
    }

    func freshChapterID(_ name: String) -> ImportChapterCandidate.ID {
        freshChapterIDsByPath[name]!
    }

    func freshFingerprint(_ pagePath: String) -> String {
        freshFingerprintsByPath[pagePath]!
    }

    func addedChapterID(_ name: String) -> ImportChapterCandidate.ID {
        freshChapterIDsByPath[name]!
    }

    func freshPageID(
        _ chapterName: String,
        _ pageName: String
    ) -> ImportPageCandidate.ID {
        freshPageIDsByPath["\(chapterName)/\(pageName)"]!
    }

    init(
        standaloneCover: Bool,
        coverChapter: String?,
        coverPage: String?,
        fresh: FreshComicBuilder
    ) throws {
        let comicID = ManagedComicID(
            rawValue: UUID(
                uuidString: "00000000-0000-0000-0000-000000000301"
            )!
        )
        var storedChapters: [FrozenImportChapter] = []
        var storedWorkItems: [FrozenImportWorkItem] = []
        var storedChapterIDs: [String: ImportChapterCandidate.ID] = [:]

        func makeStoredChapter(
            _ name: String,
            pageNames: [String]
        ) {
            let directoryPath = SourceRelativePath(components: [name])
            let chapterID = ImportChapterCandidate.ID.sourcePath(
                directoryPath,
                role: .directory
            )
            var pageIDs: [ImportPageCandidate.ID] = []

            for pageName in pageNames {
                let pagePath = directoryPath.appending(pageName)
                let pageID = ImportPageCandidate.ID.sourcePath(pagePath)
                pageIDs.append(pageID)
                let fingerprint = "fp:\(name)/\(pageName)"
                storedWorkItems.append(
                    FrozenImportWorkItem(
                        id: pageID,
                        sourceRelativePath: pagePath,
                        managedRelativePath: ManagedRelativePath(
                            components: ["original", name, pageName]
                        ),
                        originalFileName: pageName,
                        detectedFormat: .png,
                        expectedByteCount: 1_000,
                        expectedLightweightFingerprint: fingerprint,
                        pageState: .readable,
                        isCover: false
                    )
                )
            }

            storedChapterIDs[name] = chapterID
            storedChapters.append(
                FrozenImportChapter(
                    id: chapterID,
                    parentCollectionID: nil,
                    sourceDirectoryPath: directoryPath,
                    originalName: name,
                    displayName: name,
                    role: .directory,
                    pageIDs: pageIDs
                )
            )
        }

        makeStoredChapter("Chapter 1", pageNames: ["01.png", "02.png"])
        makeStoredChapter("Chapter 2", pageNames: ["01.png"])

        var coverPageID: ImportPageCandidate.ID
        if standaloneCover {
            let coverPath = SourceRelativePath(components: ["cover.png"])
            let coverID = ImportPageCandidate.ID.sourcePath(coverPath)
            storedWorkItems.append(
                FrozenImportWorkItem(
                    id: coverID,
                    sourceRelativePath: coverPath,
                    managedRelativePath: ManagedRelativePath(
                        components: ["original", "cover.png"]
                    ),
                    originalFileName: "cover.png",
                    detectedFormat: .png,
                    expectedByteCount: 1_000,
                    expectedLightweightFingerprint: "fp:cover.png",
                    pageState: .readable,
                    isCover: true
                )
            )
            coverPageID = coverID
        } else {
            let chapterName = try XCTUnwrap(coverChapter)
            let pageName = try XCTUnwrap(coverPage)
            coverPageID = ImportPageCandidate.ID.sourcePath(
                SourceRelativePath(components: [chapterName, pageName])
            )
        }

        let plan = FrozenImportPlan(
            id: ImportJobID(
                rawValue: UUID(
                    uuidString: "00000000-0000-0000-0000-000000000302"
                )!
            ),
            revision: ImportPreviewRevision(rawValue: "stored-revision"),
            sourceRootName: "Stored Comic",
            displayName: "Stored Comic",
            sourceBookmark: Data("stored-bookmark".utf8),
            sortLocaleIdentifier: "en_US",
            collections: [],
            chapters: storedChapters,
            workItems: storedWorkItems,
            coverPageID: coverPageID,
            scanIssues: [],
            spaceEstimate: .make(contentBytes: 0, fileCount: 0)
        )
        let descriptor = ManagedComicDescriptor(
            plan: plan,
            journal: ImportJobJournal(plan: plan, targetComicID: comicID)
        )
        let freshManifest = fresh.makeManifest()
        let diff = ImportUpdateDiffCalculator.make(
            storedChapters: descriptor.chapters,
            storedWorkItems: descriptor.workItems,
            freshManifest: freshManifest
        )

        self.scan = ComicSourceUpdateScan(
            descriptor: descriptor,
            freshManifest: freshManifest,
            diff: diff
        )
        storedChapterIDsByPath = storedChapterIDs
        freshChapterIDsByPath = fresh.chapterIDsByPath
        freshFingerprintsByPath = fresh.fingerprintsByPath
        freshPageIDsByPath = fresh.pageIDsByPath
        storedCoverPageID = coverPageID
    }
}

private struct FreshComicBuilder {
    /// 新扫描清单的封面建议开关；真实扫描总是给出建议，
    /// 关闭它用于验证草稿的封面回退路径。
    var suggestsCover = true

    private(set) var chapters: [ImportChapterCandidate] = []
    private(set) var collections: [ImportCollectionCandidate] = []
    private(set) var chapterIDsByPath: [String: ImportChapterCandidate.ID] = [:]
    private(set) var fingerprintsByPath: [String: String] = [:]
    private(set) var pageIDsByPath: [String: ImportPageCandidate.ID] = [:]
    private var pagesByChapter: [String: [ImportPageCandidate]] = [:]

    var pages: [ImportPageCandidate] {
        chapters.flatMap { pagesByChapter[$0.originalName] ?? [] }
    }

    mutating func addChapter(
        _ name: String,
        pageNames: [String],
        byteCounts: [String: Int64] = [:],
        pageFingerprints: [String: String] = [:],
        underCollection: String? = nil
    ) {
        let collectionID = underCollection.map { collectionName in
            if let existing = collections.first(where: {
                $0.originalName == collectionName
            }) {
                return existing.id
            }

            let id = ImportCollectionCandidate.ID.sourcePath(
                SourceRelativePath(components: [collectionName])
            )
            collections.append(
                ImportCollectionCandidate(
                    id: id,
                    parentID: nil,
                    sourceRelativePath: SourceRelativePath(
                        components: [collectionName]
                    ),
                    originalName: collectionName,
                    siblingIndex: collections.count
                )
            )
            return id
        }
        let directoryPath = underCollection == nil
            ? SourceRelativePath(components: [name])
            : SourceRelativePath(components: [underCollection!, name])
        appendChapter(
            named: name,
            parentCollectionID: collectionID,
            directoryPath: directoryPath,
            pageNames: pageNames,
            byteCounts: byteCounts,
            pageFingerprints: pageFingerprints
        )
    }

    mutating func replaceChapter(
        _ name: String,
        pageNames: [String]? = nil,
        pageFingerprints: [String: String] = [:],
        byteCounts: [String: Int64] = [:]
    ) {
        let existing = chapters.first(where: { $0.originalName == name })
        let directoryComponents = existing?.sourceDirectoryPath.components
            ?? [name]
        let parentCollectionID = existing?.parentCollectionID
        let originalIndex = chapters.firstIndex(where: {
            $0.originalName == name
        })
        removeChapter(name)

        appendChapter(
            named: name,
            parentCollectionID: parentCollectionID,
            directoryPath: SourceRelativePath(
                components: directoryComponents
            ),
            pageNames: pageNames ?? ["01.png", "02.png"],
            byteCounts: byteCounts,
            pageFingerprints: pageFingerprints,
            insertAtIndex: originalIndex
        )
    }

    mutating func removeChapter(_ name: String) {
        chapters.removeAll { $0.originalName == name }
        pagesByChapter[name] = nil
    }

    func makeManifest() -> ImportManifest {
        ImportManifest(
            sourceRootName: "Stored Comic",
            sortLocaleIdentifier: "en_US",
            collections: collections,
            chapters: chapters,
            pages: pages,
            coverPageID: suggestsCover ? pages.first?.id : nil,
            issues: [],
            spaceEstimate: .make(contentBytes: 0, fileCount: 0)
        )
    }

    private mutating func appendChapter(
        named name: String,
        parentCollectionID: ImportCollectionCandidate.ID?,
        directoryPath: SourceRelativePath,
        pageNames: [String],
        byteCounts: [String: Int64],
        pageFingerprints: [String: String],
        insertAtIndex: Int? = nil
    ) {
        let chapterID = ImportChapterCandidate.ID.sourcePath(
            directoryPath,
            role: .directory
        )
        var chapterPages: [ImportPageCandidate] = []

        for pageName in pageNames {
            let pagePath = directoryPath.appending(pageName)
            let pageID = ImportPageCandidate.ID.sourcePath(pagePath)
            let fingerprint = pageFingerprints[pageName]
                ?? "fp:\(name)/\(pageName)"
            fingerprintsByPath["\(name)/\(pageName)"] = fingerprint
            pageIDsByPath["\(name)/\(pageName)"] = pageID
            chapterPages.append(
                ImportPageCandidate(
                    id: pageID,
                    sourceRelativePath: pagePath,
                    originalFileName: pageName,
                    detectedFormat: .png,
                    byteCount: byteCounts[pageName] ?? 1_000,
                    pixelSize: ImportPixelSize(width: 100, height: 150),
                    orientation: .up,
                    lightweightFingerprint: fingerprint,
                    state: .readable,
                    pageIndex: chapterPages.count
                )
            )
        }

        chapterIDsByPath[name] = chapterID
        pagesByChapter[name] = chapterPages
        let chapter = ImportChapterCandidate(
            id: chapterID,
            parentCollectionID: parentCollectionID,
            sourceDirectoryPath: directoryPath,
            originalName: name,
            role: .directory,
            siblingIndex: chapters.count,
            pageIDs: chapterPages.map(\.id)
        )

        if let insertAtIndex,
           chapters.indices.contains(insertAtIndex) {
            chapters.insert(chapter, at: insertAtIndex)
        } else {
            chapters.append(chapter)
        }
    }
}
