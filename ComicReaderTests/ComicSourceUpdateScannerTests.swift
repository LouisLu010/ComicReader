import Foundation
import XCTest
@testable import ComicReader

final class ComicSourceUpdateScannerTests: XCTestCase {
    func testUnchangedSourceProducesEmptyDiff() async throws {
        let fixture = try await UpdateScanFixture.make(pageLayouts: [
            ["Chapter 1", "01.png"],
            ["Chapter 1", "02.png"],
            ["Chapter 2", "01.png"],
        ])

        let scan = try await fixture.scanUpdate()

        XCTAssertTrue(scan.diff.isEmpty)
        XCTAssertEqual(scan.diff.unchangedChapterCount, 2)
        XCTAssertEqual(scan.freshManifest.readablePageCount, 3)
    }

    func testAddedSourcePageMarksChapterForReplacement() async throws {
        let fixture = try await UpdateScanFixture.make(pageLayouts: [
            ["Chapter 1", "01.png"],
        ])
        try fixture.tree.png("Chapter 1/02.png")

        let scan = try await fixture.scanUpdate()

        XCTAssertEqual(scan.diff.replacedChapters.count, 1)
        XCTAssertEqual(
            scan.diff.replacedChapters.first?.addedPagePaths,
            [SourceRelativePath(components: ["Chapter 1", "02.png"])]
        )
        XCTAssertTrue(scan.diff.addedChapters.isEmpty)
    }

    func testAddedSourceChapterIsReportedAsAddition() async throws {
        let fixture = try await UpdateScanFixture.make(pageLayouts: [
            ["Chapter 1", "01.png"],
        ])
        try fixture.tree.png("Chapter 2/01.png")

        let scan = try await fixture.scanUpdate()

        XCTAssertEqual(scan.diff.addedChapters.count, 1)
        XCTAssertEqual(
            scan.diff.addedChapters.first?.sourceDirectoryPath,
            SourceRelativePath(components: ["Chapter 2"])
        )
    }

    func testVanishedSourceChapterIsReportedAsMissing() async throws {
        let fixture = try await UpdateScanFixture.make(pageLayouts: [
            ["Chapter 1", "01.png"],
            ["Chapter 2", "01.png"],
        ])
        try FileManager.default.removeItem(
            at: fixture.tree.directory("Chapter 2")
        )

        let scan = try await fixture.scanUpdate()

        XCTAssertEqual(scan.diff.missingChapters.count, 1)
        XCTAssertEqual(
            scan.diff.missingChapters.first?.sourceDirectoryPath,
            SourceRelativePath(components: ["Chapter 2"])
        )
    }

    func testModifiedSourcePageMarksChapterForReplacement() async throws {
        let fixture = try await UpdateScanFixture.make(pageLayouts: [
            ["Chapter 1", "01.png"],
        ])
        try fixture.tree.alternatePNG("Chapter 1/01.png")

        let scan = try await fixture.scanUpdate()

        XCTAssertEqual(scan.diff.replacedChapters.count, 1)
        XCTAssertEqual(
            scan.diff.replacedChapters.first?.changedPagePaths,
            [SourceRelativePath(components: ["Chapter 1", "01.png"])]
        )
    }

    func testStaleAuthorizationAsksForReauthorization() async throws {
        let fixture = try await UpdateScanFixture.make(pageLayouts: [
            ["Chapter 1", "01.png"],
        ])
        fixture.sourceAccess = StubUpdateSourceAccess(
            resolveError: .staleBookmark
        )

        do {
            _ = try await fixture.scanUpdate()
            XCTFail("Expected stale authorization failure")
        } catch let error as ComicSourceUpdateScanError {
            XCTAssertEqual(error, .staleAuthorization)
        }
    }

    func testUnresolvableAuthorizationIsInvalid() async throws {
        let fixture = try await UpdateScanFixture.make(pageLayouts: [
            ["Chapter 1", "01.png"],
        ])
        fixture.sourceAccess = StubUpdateSourceAccess(
            resolveError: .invalidBookmark
        )

        do {
            _ = try await fixture.scanUpdate()
            XCTFail("Expected invalid authorization failure")
        } catch let error as ComicSourceUpdateScanError {
            XCTAssertEqual(error, .authorizationInvalid)
        }
    }

    func testAuthorizationForAnotherComicIsInvalid() async throws {
        let fixture = try await UpdateScanFixture.make(pageLayouts: [
            ["Chapter 1", "01.png"],
        ])
        fixture.authorization = ComicSourceAuthorization(
            comicID: ManagedComicID(),
            sourceRootName: fixture.descriptor.sourceRootName,
            bookmark: fixture.authorization.bookmark
        )

        do {
            _ = try await fixture.scanUpdate()
            XCTFail("Expected authorization mismatch failure")
        } catch let error as ComicSourceUpdateScanError {
            XCTAssertEqual(error, .authorizationInvalid)
        }
    }

    func testLostSourceAccessIsReportedAsAccessDenied() async throws {
        let fixture = try await UpdateScanFixture.make(pageLayouts: [
            ["Chapter 1", "01.png"],
        ])
        fixture.sourceAccess = StubUpdateSourceAccess(
            startAccessError: .accessDenied
        )

        do {
            _ = try await fixture.scanUpdate()
            XCTFail("Expected access denied failure")
        } catch let error as ComicSourceUpdateScanError {
            XCTAssertEqual(error, .accessDenied)
        }
    }

    func testVanishedSourceRootFailsTheScan() async throws {
        let fixture = try await UpdateScanFixture.make(pageLayouts: [
            ["Chapter 1", "01.png"],
        ])
        let missingRootURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        fixture.sourceAccess = StubUpdateSourceAccess(
            resolvedURL: missingRootURL
        )

        do {
            _ = try await fixture.scanUpdate()
            XCTFail("Expected scan failure for missing source root")
        } catch let error as ComicSourceUpdateScanError {
            XCTAssertEqual(error, .scanFailed(.rootDoesNotExist))
        }
    }
}

private final class UpdateScanFixture {
    let tree: TemporaryComicTree
    let descriptor: ManagedComicDescriptor
    var authorization: ComicSourceAuthorization
    var sourceAccess = StubUpdateSourceAccess()

    private init(
        tree: TemporaryComicTree,
        descriptor: ManagedComicDescriptor,
        authorization: ComicSourceAuthorization
    ) {
        self.tree = tree
        self.descriptor = descriptor
        self.authorization = authorization
        sourceAccess = StubUpdateSourceAccess(resolvedURL: tree.rootURL)
    }

    static func make(
        pageLayouts: [[String]]
    ) async throws -> UpdateScanFixture {
        let tree = try TemporaryComicTree(name: "Update Comic")
        for components in pageLayouts {
            try tree.png(components.joined(separator: "/"))
        }
        let manifest = try await ImportScanner().scan(
            ImportScanRequest(
                rootURL: tree.rootURL,
                locale: Self.locale
            )
        )
        let draft = ImportPreviewDraft(manifest: manifest)
        let plan = try draft.freeze(
            sourceBookmark: Data("test-bookmark".utf8),
            jobID: ImportJobID(
                rawValue: UUID(
                    uuidString: "00000000-0000-0000-0000-000000000201"
                )!
            )
        )
        let comicID = ManagedComicID(
            rawValue: UUID(
                uuidString: "00000000-0000-0000-0000-000000000202"
            )!
        )
        let journal = ImportJobJournal(plan: plan, targetComicID: comicID)

        return UpdateScanFixture(
            tree: tree,
            descriptor: ManagedComicDescriptor(plan: plan, journal: journal),
            authorization: ComicSourceAuthorization(
                comicID: comicID,
                sourceRootName: plan.sourceRootName,
                bookmark: plan.sourceBookmark
            )
        )
    }

    func scanUpdate() async throws -> ComicSourceUpdateScan {
        try await ComicSourceUpdateScanner(sourceAccess: sourceAccess)
            .scan(
                descriptor: descriptor,
                authorization: authorization
            )
    }

    static let locale = Locale(identifier: "en_US")
}

private struct StubUpdateSourceAccess: ImportSourceAccessing {
    let resolvedURL: URL?
    let resolveError: ImportSourceAccessError?
    let startAccessError: ImportSourceAccessError?

    init(
        resolvedURL: URL? = nil,
        resolveError: ImportSourceAccessError? = nil,
        startAccessError: ImportSourceAccessError? = nil
    ) {
        self.resolvedURL = resolvedURL
        self.resolveError = resolveError
        self.startAccessError = startAccessError
    }

    func makeBookmark(for sourceURL: URL) throws -> Data {
        Data("test-bookmark".utf8)
    }

    func resolveBookmark(_ bookmark: Data) throws -> URL {
        if let resolveError {
            throw resolveError
        }

        return resolvedURL ?? URL(fileURLWithPath: "/")
    }

    func startAccessing(_ sourceURL: URL) throws {
        if let startAccessError {
            throw startAccessError
        }
    }

    func stopAccessing(_ sourceURL: URL) {}
}
