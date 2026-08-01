import Foundation
import XCTest
@testable import ComicReader

final class LibraryCatalogLoaderTests: XCTestCase {
    func testLoadsCatalogRecordsByMostRecentImport() async throws {
        let sandboxURL = try makeSandboxURL()
        defer { try? FileManager.default.removeItem(at: sandboxURL) }

        let layout = ImportStorageLayout(rootURL: sandboxURL)
        let olderID = comicID("00000000-0000-0000-0000-000000000301")
        let newerID = comicID("00000000-0000-0000-0000-000000000302")
        let olderRecord = record(
            id: olderID,
            title: "Chapter 10",
            importedAt: Date(timeIntervalSince1970: 10)
        )
        let newerRecord = record(
            id: newerID,
            title: "Chapter 2",
            importedAt: Date(timeIntervalSince1970: 20)
        )

        try write(olderRecord, to: layout.libraryCatalogURL(for: olderID))
        try write(newerRecord, to: layout.libraryCatalogURL(for: newerID))
        try FileManager.default.createDirectory(
            at: layout.thumbnailsURL,
            withIntermediateDirectories: true
        )
        try Data("thumbnail".utf8).write(
            to: layout.thumbnailURL(for: newerID),
            options: .atomic
        )

        let result = try await FileSystemLibraryCatalogLoader(
            layout: layout
        ).loadCatalog()

        XCTAssertEqual(result.comics.map(\.id), [newerID, olderID])
        XCTAssertEqual(result.comics.map(\.record), [newerRecord, olderRecord])
        XCTAssertEqual(
            result.comics.map(\.thumbnailAvailable),
            [true, false]
        )
        XCTAssertEqual(result.ignoredEntryCount, 0)
    }

    func testIgnoresMismatchedOrMalformedCatalogRecords() async throws {
        let sandboxURL = try makeSandboxURL()
        defer { try? FileManager.default.removeItem(at: sandboxURL) }

        let layout = ImportStorageLayout(rootURL: sandboxURL)
        let validID = comicID("00000000-0000-0000-0000-000000000303")
        let mismatchedID = comicID("00000000-0000-0000-0000-000000000304")
        let otherID = comicID("00000000-0000-0000-0000-000000000305")

        try write(
            record(
                id: validID,
                title: "Readable Comic",
                importedAt: Date(timeIntervalSince1970: 30)
            ),
            to: layout.libraryCatalogURL(for: validID)
        )
        try write(
            record(
                id: otherID,
                title: "Wrong Comic",
                importedAt: Date(timeIntervalSince1970: 40)
            ),
            to: layout.libraryCatalogURL(for: mismatchedID)
        )

        let malformedID = comicID("00000000-0000-0000-0000-000000000306")
        let malformedURL = layout.libraryCatalogURL(for: malformedID)
        try FileManager.default.createDirectory(
            at: malformedURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("not-json".utf8).write(to: malformedURL, options: .atomic)
        try FileManager.default.createDirectory(
            at: layout.libraryURL.appendingPathComponent(
                "not-a-managed-comic",
                isDirectory: true
            ),
            withIntermediateDirectories: true
        )

        let result = try await FileSystemLibraryCatalogLoader(
            layout: layout
        ).loadCatalog()

        XCTAssertEqual(result.comics.map(\.id), [validID])
        XCTAssertEqual(result.ignoredEntryCount, 2)
    }

    func testRebuildsMissingCatalogRecordFromDescriptor() async throws {
        let sandboxURL = try makeSandboxURL()
        defer { try? FileManager.default.removeItem(at: sandboxURL) }

        let layout = ImportStorageLayout(rootURL: sandboxURL)
        let comicID = comicID("00000000-0000-0000-0000-000000000307")
        let descriptor = managedDescriptor(comicID: comicID)
        let descriptorURL = layout.libraryMetadataURL(for: comicID)
            .appendingPathComponent("import-descriptor.json")
        try write(descriptor, to: descriptorURL)

        let result = try await FileSystemLibraryCatalogLoader(
            layout: layout
        ).loadCatalog()
        let rebuiltURL = layout.libraryCatalogURL(for: comicID)
        let rebuiltData = try Data(contentsOf: rebuiltURL)

        XCTAssertEqual(result.comics.map(\.id), [comicID])
        XCTAssertTrue(FileManager.default.fileExists(atPath: rebuiltURL.path))
        XCTAssertFalse(
            String(decoding: rebuiltData, as: UTF8.self)
                .contains("external-source-reference")
        )
    }

    func testUsesNaturalTitleAndStableIdentifierOrderingWhenDatesMatch() async throws {
        let sandboxURL = try makeSandboxURL()
        defer { try? FileManager.default.removeItem(at: sandboxURL) }

        let layout = ImportStorageLayout(rootURL: sandboxURL)
        let importedAt = Date(timeIntervalSince1970: 50)
        let chapter10ID = comicID("00000000-0000-0000-0000-000000000309")
        let chapter2ID = comicID("00000000-0000-0000-0000-000000000308")
        let laterSameTitleID = comicID("00000000-0000-0000-0000-000000000311")
        let earlierSameTitleID = comicID("00000000-0000-0000-0000-000000000310")

        try write(
            record(id: chapter10ID, title: "Chapter 10", importedAt: importedAt),
            to: layout.libraryCatalogURL(for: chapter10ID)
        )
        try write(
            record(id: chapter2ID, title: "Chapter 2", importedAt: importedAt),
            to: layout.libraryCatalogURL(for: chapter2ID)
        )
        try write(
            record(id: laterSameTitleID, title: "Same", importedAt: importedAt),
            to: layout.libraryCatalogURL(for: laterSameTitleID)
        )
        try write(
            record(id: earlierSameTitleID, title: "Same", importedAt: importedAt),
            to: layout.libraryCatalogURL(for: earlierSameTitleID)
        )

        let result = try await FileSystemLibraryCatalogLoader(
            layout: layout
        ).loadCatalog()

        XCTAssertEqual(
            result.comics.map(\.id),
            [chapter2ID, chapter10ID, earlierSameTitleID, laterSameTitleID]
        )
    }

    func testRejectsCatalogRecordsWithAnInvalidTreeDepth() {
        let invalidRecord = LibraryCatalogRecord(
            id: comicID("00000000-0000-0000-0000-000000000313"),
            displayName: "Invalid Tree",
            sourceRootName: "source",
            importedAt: .distantPast,
            chapterCount: 1,
            pageCount: 1,
            contentTree: [
                LibraryCatalogTreeNode(
                    id: "orphaned-chapter",
                    kind: .chapter,
                    title: "Chapter 1",
                    pageCount: 1,
                    depth: 1
                ),
            ]
        )

        XCTAssertFalse(invalidRecord.isValid)
    }

    @MainActor
    func testCoordinatorPublishesTheLatestLoadedCatalog() async {
        let comic = LibraryCatalogItem(
            record: record(
                id: comicID("00000000-0000-0000-0000-000000000307"),
                title: "Coordinator Comic",
                importedAt: .distantPast
            ),
            thumbnailAvailable: false
        )
        let layout = ImportStorageLayout(
            rootURL: FileManager.default.temporaryDirectory
        )
        let coordinator = LibraryCatalogCoordinator(
            loader: FixedLibraryCatalogLoader(
                result: LibraryCatalogLoadResult(
                    comics: [comic],
                    ignoredEntryCount: 1
                )
            ),
            layout: layout
        )

        let didLoad = await coordinator.reload()

        XCTAssertTrue(didLoad)
        XCTAssertEqual(coordinator.state, .loaded)
        XCTAssertEqual(coordinator.comics, [comic])
        XCTAssertEqual(coordinator.comicsByTitle, [comic])
        XCTAssertEqual(coordinator.ignoredEntryCount, 1)
    }

    @MainActor
    func testCoordinatorReturnsFalseWhenCatalogLoadingFails() async {
        let coordinator = LibraryCatalogCoordinator(
            loader: FailingLibraryCatalogLoader(),
            layout: ImportStorageLayout(
                rootURL: FileManager.default.temporaryDirectory
            )
        )

        let didLoad = await coordinator.reload()

        XCTAssertFalse(didLoad)
        XCTAssertEqual(coordinator.state, .failed)
    }

    private func makeSandboxURL() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true
        )
        return url
    }

    private func write<Value: Encodable>(
        _ value: Value,
        to url: URL
    ) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(value).write(to: url, options: .atomic)
    }

    private func record(
        id: ManagedComicID,
        title: String,
        importedAt: Date
    ) -> LibraryCatalogRecord {
        LibraryCatalogRecord(
            id: id,
            displayName: title,
            sourceRootName: "source",
            importedAt: importedAt,
            chapterCount: 2,
            pageCount: 24,
            contentTree: [
                LibraryCatalogTreeNode(
                    id: "chapter-\(id.rawValue.uuidString)",
                    kind: .chapter,
                    title: "Chapter 1",
                    pageCount: 24
                ),
            ]
        )
    }

    private func comicID(_ value: String) -> ManagedComicID {
        ManagedComicID(rawValue: UUID(uuidString: value)!)
    }

    private func managedDescriptor(
        comicID: ManagedComicID
    ) -> ManagedComicDescriptor {
        let jobID = ImportJobID(
            rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000312")!
        )
        let chapterID = ImportChapterCandidate.ID(rawValue: "chapter")
        let pageID = ImportPageCandidate.ID(rawValue: "page")
        let plan = FrozenImportPlan(
            schemaVersion: FrozenImportPlan.currentSchemaVersion,
            id: jobID,
            revision: ImportPreviewRevision(rawValue: "revision"),
            sourceRootName: "Imported Source",
            displayName: "Rebuilt Comic",
            sourceBookmark: Data("external-source-reference".utf8),
            sortLocaleIdentifier: "en_US",
            collections: [],
            chapters: [
                FrozenImportChapter(
                    id: chapterID,
                    parentCollectionID: nil,
                    sourceDirectoryPath: .root,
                    originalName: "Chapter 1",
                    displayName: "Chapter 1",
                    role: .directory,
                    pageIDs: [pageID]
                ),
            ],
            workItems: [
                FrozenImportWorkItem(
                    id: pageID,
                    sourceRelativePath: SourceRelativePath(
                        components: ["Chapter 1", "01.png"]
                    ),
                    managedRelativePath: ManagedRelativePath(
                        components: ["original", "Chapter 1", "01.png"]
                    ),
                    originalFileName: "01.png",
                    detectedFormat: .png,
                    expectedByteCount: 1,
                    expectedLightweightFingerprint: nil,
                    pageState: .readable,
                    isCover: true
                ),
            ],
            coverPageID: pageID,
            scanIssues: [],
            spaceEstimate: .make(contentBytes: 1, fileCount: 1)
        )
        let journal = ImportJobJournal(plan: plan, targetComicID: comicID)

        return ManagedComicDescriptor(plan: plan, journal: journal)
    }
}

private actor FixedLibraryCatalogLoader: LibraryCatalogLoading {
    let result: LibraryCatalogLoadResult

    init(result: LibraryCatalogLoadResult) {
        self.result = result
    }

    func loadCatalog() async throws -> LibraryCatalogLoadResult {
        result
    }
}

private actor FailingLibraryCatalogLoader: LibraryCatalogLoading {
    func loadCatalog() async throws -> LibraryCatalogLoadResult {
        throw LibraryCatalogLoaderTestError.loadFailed
    }
}

private enum LibraryCatalogLoaderTestError: Error, Sendable {
    case loadFailed
}
