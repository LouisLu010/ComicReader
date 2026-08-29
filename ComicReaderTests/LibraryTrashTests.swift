import Foundation
import SwiftData
import XCTest
@testable import ComicReader

final class LibraryTrashPolicyTests: XCTestCase {
    func testPurgeDateIsThirtyDaysAfterTrashing() {
        let trashedAt = Date(timeIntervalSince1970: 1_000_000)

        XCTAssertEqual(
            LibraryTrashRetention.purgeDate(forTrashedAt: trashedAt),
            trashedAt.addingTimeInterval(30 * 86_400)
        )
        XCTAssertEqual(LibraryTrashRetention.dayCount, 30)
    }

    func testPurgeDueBoundaryIsInclusive() {
        let trashedAt = Date(timeIntervalSince1970: 0)
        let comic = LibraryTrashedComic(
            id: ManagedComicID(),
            displayName: "Comic",
            trashedAt: trashedAt
        )

        XCTAssertFalse(
            comic.isPurgeDue(
                now: trashedAt.addingTimeInterval(30 * 86_400 - 1)
            )
        )
        XCTAssertTrue(
            comic.isPurgeDue(now: comic.purgeAfter)
        )
    }

    func testPurgeDueComicIDsKeepsOrderAndSkipsRecent() {
        let old = LibraryTrashedComic(
            id: ManagedComicID(
                rawValue: UUID(
                    uuidString: "00000000-0000-0000-0000-000000000611"
                )!
            ),
            displayName: "Old",
            trashedAt: Date(timeIntervalSince1970: 0)
        )
        let recent = LibraryTrashedComic(
            id: ManagedComicID(
                rawValue: UUID(
                    uuidString: "00000000-0000-0000-0000-000000000612"
                )!
            ),
            displayName: "Recent",
            trashedAt: Date(timeIntervalSince1970: 100 * 86_400)
        )
        let now = Date(timeIntervalSince1970: 131 * 86_400)

        XCTAssertEqual(
            LibraryTrashPolicy.purgeDueComicIDs(
                [recent, old, recent],
                now: now
            ),
            [old.id]
        )
    }
}

final class LibraryTrashStoreTests: XCTestCase {
    func testTrashRestorePurgeLifecycleExcludesFromCatalog() async throws {
        let fixture = try await makeImportedComicFixture()
        let catalogLoader = FileSystemLibraryCatalogLoader(
            layout: fixture.layout
        )
        let coordinator = LibraryTrashCoordinator(layout: fixture.layout)

        // 初始：两部漫画都在书库可见。
        var catalog = try await catalogLoader.loadCatalog()
        XCTAssertEqual(catalog.comics.count, 2)
        XCTAssertTrue(coordinator.trashedComics.isEmpty)

        // 软删除：标记存在、书库不再展示、可展示快照齐全。
        let trashedAt = Date(timeIntervalSince1970: 1_000)
        let trashed = try await fixture.store.markTrashed(
            comicID: fixture.recentComicID,
            now: trashedAt
        )
        XCTAssertEqual(trashed.id, fixture.recentComicID)
        XCTAssertEqual(trashed.displayName, "Update Target")
        XCTAssertEqual(trashed.trashedAt, trashedAt)
        XCTAssertEqual(
            trashed.purgeAfter,
            trashedAt.addingTimeInterval(30 * 86_400)
        )

        catalog = try await catalogLoader.loadCatalog()
        XCTAssertEqual(catalog.comics.map(\.id), [fixture.dueComicID])
        XCTAssertEqual(catalog.ignoredEntryCount, 0)

        await coordinator.reload()
        XCTAssertEqual(
            coordinator.trashedComics.map(\.id),
            [fixture.recentComicID]
        )

        // 重复标记保留最早删除时间。
        let remarkTrashed = try await fixture.store.markTrashed(
            comicID: fixture.recentComicID,
            now: trashedAt.addingTimeInterval(60)
        )
        XCTAssertEqual(remarkTrashed.trashedAt, trashedAt)

        // 恢复：标记移除、书库重新可见。
        let didRestore = await coordinator.restoreComic(
            for: fixture.recentComicID
        )
        XCTAssertTrue(didRestore)
        catalog = try await catalogLoader.loadCatalog()
        XCTAssertEqual(catalog.comics.count, 2)
        XCTAssertTrue(coordinator.trashedComics.isEmpty)
        XCTAssertFalse(
            await coordinator.restoreComic(for: fixture.recentComicID)
        )

        // 再次软删除后永久删除：目录与缩略图一并移除。
        _ = try await fixture.store.markTrashed(
            comicID: fixture.recentComicID
        )
        await coordinator.reload()
        XCTAssertEqual(coordinator.trashedComics.count, 1)

        let comicRootURL = fixture.layout.libraryURL(
            for: fixture.recentComicID
        )
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: comicRootURL.path)
        )
        let didPurge = await coordinator.purgeComic(
            for: fixture.recentComicID
        )
        XCTAssertTrue(didPurge)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: comicRootURL.path)
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.layout
                    .thumbnailURL(for: fixture.recentComicID).path
            )
        )
        XCTAssertTrue(coordinator.trashedComics.isEmpty)
        XCTAssertFalse(
            await coordinator.purgeComic(for: fixture.recentComicID)
        )

        catalog = try await catalogLoader.loadCatalog()
        XCTAssertEqual(catalog.comics.map(\.id), [fixture.dueComicID])
    }

    func testPurgeComicsPastRetentionOnlyRemovesDueComics() async throws {
        let fixture = try await makeImportedComicFixture()
        let coordinator = LibraryTrashCoordinator(layout: fixture.layout)
        let now = Date(timeIntervalSince1970: 40 * 86_400)

        // 未到期的漫画：保留；到期且已恢复的漫画：不在回收站。
        _ = try await fixture.store.markTrashed(
            comicID: fixture.recentComicID,
            now: now.addingTimeInterval(-5 * 86_400)
        )
        _ = try await fixture.store.markTrashed(
            comicID: fixture.dueComicID,
            now: now.addingTimeInterval(-31 * 86_400)
        )
        await coordinator.reload()
        XCTAssertEqual(coordinator.trashedComics.count, 2)

        let dueIDs = await coordinator.purgeComicsPastRetention(now: now)
        XCTAssertEqual(dueIDs, [fixture.dueComicID])
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: fixture.layout
                    .libraryURL(for: fixture.recentComicID).path
            )
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.layout.libraryURL(for: fixture.dueComicID).path
            )
        )
        XCTAssertEqual(
            coordinator.trashedComics.map(\.id),
            [fixture.recentComicID]
        )
    }

    func testMarkTrashedRejectsUnknownComic() async throws {
        let fixture = try await makeImportedComicFixture()
        let unknownComicID = ManagedComicID(
            rawValue: UUID(
                uuidString: "00000000-0000-0000-0000-000000000621"
            )!
        )

        do {
            _ = try await fixture.store.markTrashed(comicID: unknownComicID)
            XCTFail("Expected unknown comic failure")
        } catch let error as LibraryTrashStoreError {
            XCTAssertEqual(error, .comicNotFound)
        }
    }

    // MARK: - Fixture

    private func makeImportedComicFixture() async throws
        -> ImportedComicForTrashFixture {
        try await ImportedComicForTrashFixture.make()
    }
}

private final class ImportedComicForTrashFixture {
    let layout: ImportStorageLayout
    let recentComicID: ManagedComicID
    let dueComicID: ManagedComicID
    let store: FileSystemLibraryTrashStore

    private init(
        layout: ImportStorageLayout,
        recentComicID: ManagedComicID,
        dueComicID: ManagedComicID
    ) {
        self.layout = layout
        self.recentComicID = recentComicID
        self.dueComicID = dueComicID
        store = FileSystemLibraryTrashStore(layout: layout)
    }

    static func make() async throws -> ImportedComicForTrashFixture {
        let sandbox = try TemporaryImportSandbox(sourceName: "Update Target")
        try sandbox.sourceTree.png("cover.png")
        try sandbox.sourceTree.png("Chapter 1/01.png")

        let manifest = try await ImportScanner().scan(
            ImportScanRequest(
                rootURL: sandbox.sourceDirectoryURL,
                locale: Locale(identifier: "en_US")
            )
        )
        let draft = ImportPreviewDraft(manifest: manifest)
        let recentComicID = ManagedComicID(
            rawValue: UUID(
                uuidString: "00000000-0000-0000-0000-000000000620"
            )!
        )
        let dueComicID = ManagedComicID(
            rawValue: UUID(
                uuidString: "00000000-0000-0000-0000-000000000622"
            )!
        )
        let layout = ImportStorageLayout(rootURL: sandbox.appManagedRootURL)
        let engine = RecoverableImportEngine(
            layout: layout,
            sourceAccess: TrashFixtureSourceAccess(
                resolvedURL: sandbox.sourceDirectoryURL
            ),
            capacityProvider: TrashFixtureCapacityProvider(),
            thumbnailGenerator: TrashFixtureThumbnailGenerator()
        )

        for comicID in [recentComicID, dueComicID] {
            let queued = try await engine.enqueue(
                draft,
                sourceURL: sandbox.sourceDirectoryURL,
                targetComicID: comicID
            )
            let completed = try await engine.run(queued.id)
            guard completed.state.phase == .completed else {
                throw LibraryTrashFixtureError.importDidNotComplete
            }
        }

        return ImportedComicForTrashFixture(
            layout: layout,
            recentComicID: recentComicID,
            dueComicID: dueComicID
        )
    }
}

private enum LibraryTrashFixtureError: Error {
    case importDidNotComplete
}

private struct TrashFixtureSourceAccess: ImportSourceAccessing {
    let resolvedURL: URL

    func makeBookmark(for sourceURL: URL) throws -> Data {
        Data("test-bookmark".utf8)
    }

    func resolveBookmark(_ bookmark: Data) throws -> URL {
        resolvedURL
    }

    func startAccessing(_ sourceURL: URL) throws {}

    func stopAccessing(_ sourceURL: URL) {}
}

private struct TrashFixtureCapacityProvider: ImportCapacityProviding {
    func availableBytes(at destinationRoot: URL) throws -> Int64 {
        .max
    }
}

private struct TrashFixtureThumbnailGenerator: ImportThumbnailGenerating {
    func generate(from coverURL: URL, to thumbnailURL: URL) async throws {
        try FileManager.default.createDirectory(
            at: thumbnailURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("thumbnail".utf8).write(to: thumbnailURL, options: .atomic)
    }
}
