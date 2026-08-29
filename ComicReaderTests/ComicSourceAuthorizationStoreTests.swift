import Foundation
import XCTest
@testable import ComicReader

final class ComicSourceAuthorizationStoreTests: XCTestCase {
    func testSaveAndLoadRoundTripPreservesAuthorization() throws {
        let fixture = try makeFixture()
        let authorizedAt = Date(timeIntervalSince1970: 1_000_000)
        let authorization = ComicSourceAuthorization(
            comicID: fixture.comicID,
            sourceRootName: "Reauthorized Comic",
            bookmark: Data("bookmark".utf8),
            authorizedAt: authorizedAt
        )

        try fixture.store.save(authorization, for: fixture.comicID)
        let loaded = fixture.store.load(for: fixture.comicID)

        XCTAssertEqual(loaded, authorization)
        XCTAssertEqual(loaded?.authorizedAt, authorizedAt)
    }

    func testSaveRejectsAuthorizationForAnotherComic() throws {
        let fixture = try makeFixture()
        let existing = try seedAuthorization(in: fixture)

        XCTAssertThrowsError(
            try fixture.store.save(
                ComicSourceAuthorization(
                    comicID: ManagedComicID(),
                    sourceRootName: "Other",
                    bookmark: Data("other".utf8)
                ),
                for: fixture.comicID
            )
        ) { error in
            XCTAssertEqual(
                error as? ComicSourceAuthorizationStoreError,
                .comicIDMismatch
            )
        }

        XCTAssertEqual(
            fixture.store.load(for: fixture.comicID),
            existing
        )
    }

    func testSaveRejectsUnknownSchema() throws {
        let fixture = try makeFixture()

        XCTAssertThrowsError(
            try fixture.store.save(
                ComicSourceAuthorization(
                    schemaVersion: ComicSourceAuthorization
                        .currentSchemaVersion + 1,
                    comicID: fixture.comicID,
                    sourceRootName: "Future",
                    bookmark: Data("bookmark".utf8)
                ),
                for: fixture.comicID
            )
        ) { error in
            XCTAssertEqual(
                error as? ComicSourceAuthorizationStoreError,
                .unsupportedSchema
            )
        }
        XCTAssertNil(fixture.store.load(for: fixture.comicID))
    }

    func testCorruptedRecordDegradesToMissing() throws {
        let fixture = try makeFixture()
        try seedAuthorization(in: fixture)

        try Data("not json".utf8).write(
            to: fixture.layout.sourceAuthorizationURL(for: fixture.comicID)
        )

        XCTAssertNil(fixture.store.load(for: fixture.comicID))
    }

    func testReauthorizeReplacesAuthorizationWithPickedDirectory() throws {
        let fixture = try makeFixture()
        let original = try seedAuthorization(in: fixture)
        let pickedURL = fixture.pickedDirectoryURL
        let reauthorizeDate = Date(timeIntervalSince1970: 2_000_000)
        let reauthorizer = ComicSourceReauthorizer(
            sourceAccess: StubReauthorizationSourceAccess(
                bookmarkByURL: [pickedURL: Data("picked-bookmark".utf8)]
            ),
            store: fixture.store
        )

        let reauthorized = try reauthorizer.reauthorize(
            comicID: fixture.comicID,
            sourceURL: pickedURL,
            now: reauthorizeDate
        )

        XCTAssertEqual(reauthorized.comicID, fixture.comicID)
        XCTAssertEqual(
            reauthorized.sourceRootName,
            pickedURL.lastPathComponent
        )
        XCTAssertEqual(reauthorized.bookmark, Data("picked-bookmark".utf8))
        XCTAssertEqual(reauthorized.authorizedAt, reauthorizeDate)
        XCTAssertNotEqual(reauthorized, original)
        XCTAssertEqual(
            fixture.store.load(for: fixture.comicID),
            reauthorized
        )
    }

    func testFailedReauthorizationKeepsExistingAuthorization() throws {
        let fixture = try makeFixture()
        let existing = try seedAuthorization(in: fixture)
        let pickedURL = fixture.pickedDirectoryURL
        let reauthorizer = ComicSourceReauthorizer(
            sourceAccess: StubReauthorizationSourceAccess(
                bookmarkByURL: [:],
                makeBookmarkError: .accessDenied
            ),
            store: fixture.store
        )

        XCTAssertThrowsError(
            try reauthorizer.reauthorize(
                comicID: fixture.comicID,
                sourceURL: pickedURL
            )
        ) { error in
            XCTAssertEqual(
                error as? ImportSourceAccessError,
                .accessDenied
            )
        }

        XCTAssertEqual(
            fixture.store.load(for: fixture.comicID),
            existing
        )
    }

    // MARK: - Fixture

    private func makeFixture() throws -> ReauthorizationFixture {
        try ReauthorizationFixture()
    }

    private func seedAuthorization(
        in fixture: ReauthorizationFixture
    ) throws -> ComicSourceAuthorization {
        let authorization = ComicSourceAuthorization(
            comicID: fixture.comicID,
            sourceRootName: "Original Source",
            bookmark: Data("original-bookmark".utf8)
        )
        try fixture.store.save(authorization, for: fixture.comicID)
        return authorization
    }
}

private final class ReauthorizationFixture {
    let layout: ImportStorageLayout
    let store: ComicSourceAuthorizationStore
    let comicID: ManagedComicID
    let pickedDirectoryURL: URL
    private let sandboxRootURL: URL

    init() throws {
        let sandboxRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "authorization-store-\(UUID().uuidString)",
                isDirectory: true
            )
        sandboxRootURL = sandboxRoot
        layout = ImportStorageLayout(rootURL: sandboxRoot)
        store = ComicSourceAuthorizationStore(layout: layout)
        comicID = ManagedComicID(
            rawValue: UUID(
                uuidString: "00000000-0000-0000-0000-000000000501"
            )!
        )
        pickedDirectoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "Picked Source-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: pickedDirectoryURL,
            withIntermediateDirectories: true
        )
    }

    deinit {
        try? FileManager.default.removeItem(at: sandboxRootURL)
        try? FileManager.default.removeItem(at: pickedDirectoryURL)
    }
}

private struct StubReauthorizationSourceAccess: ImportSourceAccessing {
    let bookmarkByURL: [URL: Data]
    let makeBookmarkError: ImportSourceAccessError?

    init(
        bookmarkByURL: [URL: Data],
        makeBookmarkError: ImportSourceAccessError? = nil
    ) {
        self.bookmarkByURL = bookmarkByURL
        self.makeBookmarkError = makeBookmarkError
    }

    func makeBookmark(for sourceURL: URL) throws -> Data {
        if let makeBookmarkError {
            throw makeBookmarkError
        }

        guard let bookmark = bookmarkByURL[sourceURL] else {
            throw ImportSourceAccessError.invalidBookmark
        }

        return bookmark
    }

    func resolveBookmark(_ bookmark: Data) throws -> URL {
        throw ImportSourceAccessError.invalidBookmark
    }

    func startAccessing(_ sourceURL: URL) throws {}

    func stopAccessing(_ sourceURL: URL) {}
}
