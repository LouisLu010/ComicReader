import XCTest
@testable import ComicReader

final class UITestFixtureBootstrapTests: XCTestCase {
    func testMissingEnvironmentDoesNotRequestFixture() {
        XCTAssertNil(
            UITestFixtureBootstrap.requestedFixture(environment: [:])
        )
    }

    @MainActor
    func testRequestedConfigurationUsesFixtureDependencies() async throws {
        let request = try XCTUnwrap(
            UITestFixtureBootstrap.requestedFixture(
                environment: fixtureEnvironment("reader-navigation")
            )
        )
        let configuration = try await UITestFixtureBootstrap.makeConfiguration(
            for: request
        )

        XCTAssertFalse(configuration.importJobs.allowsLibraryWrites)
        let didReloadCatalog = await configuration.libraryCatalog.reload()
        XCTAssertTrue(didReloadCatalog)
        XCTAssertEqual(
            configuration.libraryCatalog.comics.map(\.id),
            [UITestFixtureBootstrap.readerNavigationComicID]
        )

        configuration.importJobs.setLibraryWritesAllowed(true)
        await configuration.importJobs.restorePendingJobs()

        XCTAssertTrue(configuration.importJobs.jobs.isEmpty)
        XCTAssertNil(configuration.importJobs.notice)
    }

    @MainActor
    func testUnknownRequestedFixtureFailsClosed() async throws {
        let request = try XCTUnwrap(
            UITestFixtureBootstrap.requestedFixture(
                environment: fixtureEnvironment("unknown-fixture")
            )
        )

        do {
            _ = try await UITestFixtureBootstrap.makeConfiguration(for: request)
            XCTFail("Expected an unknown fixture to fail")
        } catch {
            XCTAssertEqual(
                error as? UITestFixtureBootstrapError,
                .unknownFixture
            )
        }
    }

    @MainActor
    func testReaderNavigationFixtureLoadsCatalogReaderAndImage() async throws {
        let sandbox = try TemporaryImportSandbox()
        let layout = ImportStorageLayout(rootURL: sandbox.appManagedRootURL)

        try await Task.detached {
            try UITestFixtureBootstrap.install(.readerNavigation, in: layout)
        }.value

        let catalog = try await FileSystemLibraryCatalogLoader(
            layout: layout
        ).loadCatalog()
        XCTAssertEqual(
            catalog.comics.map(\.id),
            [UITestFixtureBootstrap.readerNavigationComicID]
        )

        let loadedContent = try await FileSystemReaderContentLoader(
            layout: layout
        ).load(comicID: UITestFixtureBootstrap.readerNavigationComicID)
        XCTAssertEqual(
            loadedContent.comic.cover?.id,
            UITestFixtureBootstrap.readerNavigationCoverPageID
        )
        XCTAssertEqual(
            loadedContent.comic.chapters.map(\.id),
            [
                ImportChapterCandidate.ID(rawValue: "ui-chapter-one"),
                ImportChapterCandidate.ID(rawValue: "ui-chapter-two"),
            ]
        )

        let asset = try loadedContent.assetResolver.asset(
            for: UITestFixtureBootstrap.readerNavigationCoverPageID
        )
        let image = try await ImageIOReaderImageDecoder().decode(
            ReaderImageDecodeRequest(
                asset: asset,
                target: try ReaderImageTarget(maximumPixelSize: 128)
            )
        )
        XCTAssertGreaterThan(image.estimatedByteCount, 0)
        XCTAssertEqual(image.image.width, 2)
        XCTAssertEqual(image.image.height, 3)

        let landscapeAsset = try loadedContent.assetResolver.asset(
            for: UITestFixtureBootstrap.readerNavigationChapterTwoPageOneID
        )
        let landscapeImage = try await ImageIOReaderImageDecoder().decode(
            ReaderImageDecodeRequest(
                asset: landscapeAsset,
                target: try ReaderImageTarget(maximumPixelSize: 128)
            )
        )
        XCTAssertEqual(landscapeImage.image.width, 3)
        XCTAssertEqual(landscapeImage.image.height, 2)
    }

    @MainActor
    func testEmptyFixtureHasNoCatalogItems() async throws {
        let sandbox = try TemporaryImportSandbox()
        let layout = ImportStorageLayout(rootURL: sandbox.appManagedRootURL)

        try await Task.detached {
            try UITestFixtureBootstrap.install(.emptyLibrary, in: layout)
        }.value

        let catalog = try await FileSystemLibraryCatalogLoader(
            layout: layout
        ).loadCatalog()
        XCTAssertTrue(catalog.comics.isEmpty)
        XCTAssertEqual(catalog.ignoredEntryCount, 0)
    }

    func testInstallRejectsAFileStorageRoot() throws {
        let parentURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: parentURL) }
        let rootURL = parentURL.appendingPathComponent("fixture-root")
        try Data("not-a-directory".utf8).write(to: rootURL)

        XCTAssertThrowsError(
            try UITestFixtureBootstrap.install(
                .emptyLibrary,
                in: ImportStorageLayout(rootURL: rootURL)
            )
        ) { error in
            XCTAssertEqual(
                error as? UITestFixtureBootstrapError,
                .unsafeStorageRoot
            )
        }
    }

    func testInstallRejectsASymbolicLinkStorageRoot() throws {
        let parentURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: parentURL) }
        let targetURL = parentURL.appendingPathComponent(
            "fixture-target",
            isDirectory: true
        )
        let rootURL = parentURL.appendingPathComponent(
            "fixture-root",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: targetURL,
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(
            at: rootURL,
            withDestinationURL: targetURL
        )

        XCTAssertThrowsError(
            try UITestFixtureBootstrap.install(
                .emptyLibrary,
                in: ImportStorageLayout(rootURL: rootURL)
            )
        ) { error in
            XCTAssertEqual(
                error as? UITestFixtureBootstrapError,
                .unsafeStorageRoot
            )
        }
    }

    func testInstallPropagatesDirectoryCreationFailure() throws {
        let parentURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: parentURL) }
        let blockingFileURL = parentURL.appendingPathComponent("blocking-file")
        try Data("not-a-directory".utf8).write(to: blockingFileURL)
        let rootURL = blockingFileURL.appendingPathComponent(
            "fixture-root",
            isDirectory: true
        )

        XCTAssertThrowsError(
            try UITestFixtureBootstrap.install(
                .emptyLibrary,
                in: ImportStorageLayout(rootURL: rootURL)
            )
        ) { error in
            XCTAssertNil(error as? UITestFixtureBootstrapError)
        }
    }

    private func fixtureEnvironment(_ rawValue: String) -> [String: String] {
        [UITestFixtureBootstrap.environmentKey: rawValue]
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString,
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true
        )
        return url
    }
}
