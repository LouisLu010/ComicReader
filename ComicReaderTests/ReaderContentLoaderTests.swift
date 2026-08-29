import Foundation
import XCTest
@testable import ComicReader

final class ReaderContentLoaderTests: XCTestCase {
    func testLoadsComicAndManagedAssetResolverWithoutUsingSourceAccess() async throws {
        let sandboxURL = try makeSandboxURL()
        defer { try? FileManager.default.removeItem(at: sandboxURL) }

        let layout = ImportStorageLayout(rootURL: sandboxURL)
        let comicID = managedComicID(
            "00000000-0000-0000-0000-000000000901"
        )
        let pageID = ImportPageCandidate.ID(rawValue: "page-1")
        let descriptor = makeDescriptor(
            comicID: comicID,
            sourceBookmark: Data(
                "not-a-bookmark:/private/unavailable/source".utf8
            ),
            workItems: [makeWorkItem(pageID)]
        )
        try write(
            descriptor,
            to: descriptorURL(for: comicID, layout: layout)
        )

        let content = try await FileSystemReaderContentLoader(
            layout: layout
        ).load(comicID: comicID)
        let asset = try content.assetResolver.asset(for: pageID)

        XCTAssertEqual(content.comic.id, comicID)
        XCTAssertEqual(content.comic.displayName, "Reader Loader Comic")
        XCTAssertEqual(content.comic.chapters.flatMap(\.pages).map(\.id), [pageID])
        XCTAssertEqual(
            asset.comicRootURL,
            layout.libraryURL(for: comicID).standardizedFileURL
        )
        XCTAssertEqual(
            asset.managedRelativePath.components,
            ["original", "Chapter 1", "page-1.png"]
        )
    }

    func testAppliesUserPageOrderOverrideWhenLoadingComic() async throws {
        let sandboxURL = try makeSandboxURL()
        defer { try? FileManager.default.removeItem(at: sandboxURL) }

        let layout = ImportStorageLayout(rootURL: sandboxURL)
        let comicID = managedComicID(
            "00000000-0000-0000-0000-000000000903"
        )
        let pageIDs = ["page-1", "page-2", "page-3"].map(
            ImportPageCandidate.ID.init
        )
        let workItems = pageIDs.enumerated().map { index, pageID in
            makeWorkItem(
                pageID,
                managedRelativePath: ManagedRelativePath(
                    components: [
                        "original",
                        "Chapter 1",
                        "page-\(index + 1).png",
                    ]
                )
            )
        }
        try write(
            makeDescriptor(comicID: comicID, workItems: workItems),
            to: descriptorURL(for: comicID, layout: layout)
        )
        let chapterID = ImportChapterCandidate.ID(rawValue: "chapter-1")

        // 完整排列覆盖。
        let fullOverrideLoader = FileSystemReaderContentLoader(
            layout: layout,
            pageOrdersProvider: { _ in
                [chapterID: pageIDs.reversed()]
            }
        )
        let reordered = try await fullOverrideLoader.load(comicID: comicID)
        XCTAssertEqual(
            reordered.comic.chapters.first?.pages.map(\.id),
            pageIDs.reversed()
        )

        // 部分覆盖：保留可匹配页序，其余按自然顺序补回。
        let partialOverrideLoader = FileSystemReaderContentLoader(
            layout: layout,
            pageOrdersProvider: { _ in
                [chapterID: [ImportPageCandidate.ID(rawValue: "page-2")]]
            }
        )
        let partiallyReordered = try await partialOverrideLoader.load(
            comicID: comicID
        )
        XCTAssertEqual(
            partiallyReordered.comic.chapters.first?.pages.map(\.id),
            ["page-2", "page-1", "page-3"].map(ImportPageCandidate.ID.init)
        )
    }

    func testMissingDescriptorHasExplicitError() async throws {
        let sandboxURL = try makeSandboxURL()
        defer { try? FileManager.default.removeItem(at: sandboxURL) }

        let comicID = managedComicID(
            "00000000-0000-0000-0000-000000000902"
        )

        do {
            _ = try await FileSystemReaderContentLoader(
                layout: ImportStorageLayout(rootURL: sandboxURL)
            ).load(comicID: comicID)
            XCTFail("Expected a missing descriptor error.")
        } catch {
            XCTAssertEqual(
                error as? ReaderContentLoaderError,
                .descriptorNotFound
            )
        }
    }

    func testDirectoryAtDescriptorPathIsRejected() async throws {
        let sandboxURL = try makeSandboxURL()
        defer { try? FileManager.default.removeItem(at: sandboxURL) }

        let layout = ImportStorageLayout(rootURL: sandboxURL)
        let comicID = managedComicID(
            "00000000-0000-0000-0000-000000000903"
        )
        try FileManager.default.createDirectory(
            at: descriptorURL(for: comicID, layout: layout),
            withIntermediateDirectories: true
        )

        do {
            _ = try await FileSystemReaderContentLoader(
                layout: layout
            ).load(comicID: comicID)
            XCTFail("Expected a descriptor directory error.")
        } catch {
            XCTAssertEqual(
                error as? ReaderContentLoaderError,
                .descriptorIsDirectory
            )
        }
    }

    func testSymbolicLinkDescriptorIsRejectedWithoutReadingItsTarget() async throws {
        let sandboxURL = try makeSandboxURL()
        defer { try? FileManager.default.removeItem(at: sandboxURL) }

        let layout = ImportStorageLayout(rootURL: sandboxURL)
        let comicID = managedComicID(
            "00000000-0000-0000-0000-000000000904"
        )
        let externalDescriptorURL = sandboxURL.appendingPathComponent(
            "external-descriptor.json"
        )
        try JSONEncoder().encode(
            makeDescriptor(comicID: comicID)
        ).write(to: externalDescriptorURL, options: .atomic)

        let managedDescriptorURL = descriptorURL(
            for: comicID,
            layout: layout
        )
        try FileManager.default.createDirectory(
            at: managedDescriptorURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(
            at: managedDescriptorURL,
            withDestinationURL: externalDescriptorURL
        )

        do {
            _ = try await FileSystemReaderContentLoader(
                layout: layout
            ).load(comicID: comicID)
            XCTFail("Expected a symbolic link descriptor error.")
        } catch {
            XCTAssertEqual(
                error as? ReaderContentLoaderError,
                .descriptorIsSymbolicLink
            )
        }
    }

    func testSymbolicLinkMetadataDirectoryCannotEscapeManagedComicRoot() async throws {
        let sandboxURL = try makeSandboxURL()
        defer { try? FileManager.default.removeItem(at: sandboxURL) }

        let layout = ImportStorageLayout(rootURL: sandboxURL)
        let comicID = managedComicID(
            "00000000-0000-0000-0000-000000000913"
        )
        let externalMetadataURL = sandboxURL.appendingPathComponent(
            "external-metadata",
            isDirectory: true
        )
        try write(
            makeDescriptor(comicID: comicID),
            to: externalMetadataURL.appendingPathComponent(
                "import-descriptor.json"
            )
        )

        let comicRootURL = layout.libraryURL(for: comicID)
        try FileManager.default.createDirectory(
            at: comicRootURL,
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(
            at: layout.libraryMetadataURL(for: comicID),
            withDestinationURL: externalMetadataURL
        )

        do {
            _ = try await FileSystemReaderContentLoader(
                layout: layout
            ).load(comicID: comicID)
            XCTFail("Expected a managed-directory symbolic link error.")
        } catch {
            XCTAssertEqual(
                error as? ReaderContentLoaderError,
                .descriptorIsSymbolicLink
            )
        }
    }

    func testSymbolicLinkComicDirectoryCannotEscapeManagedLibrary() async throws {
        let sandboxURL = try makeSandboxURL()
        defer { try? FileManager.default.removeItem(at: sandboxURL) }

        let layout = ImportStorageLayout(rootURL: sandboxURL)
        let comicID = managedComicID(
            "00000000-0000-0000-0000-000000000914"
        )
        let externalComicURL = sandboxURL.appendingPathComponent(
            "external-comic",
            isDirectory: true
        )
        try write(
            makeDescriptor(comicID: comicID),
            to: externalComicURL
                .appendingPathComponent("metadata", isDirectory: true)
                .appendingPathComponent("import-descriptor.json")
        )

        try FileManager.default.createDirectory(
            at: layout.libraryURL,
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(
            at: layout.libraryURL(for: comicID),
            withDestinationURL: externalComicURL
        )

        do {
            _ = try await FileSystemReaderContentLoader(
                layout: layout
            ).load(comicID: comicID)
            XCTFail("Expected a managed-comic symbolic link error.")
        } catch {
            XCTAssertEqual(
                error as? ReaderContentLoaderError,
                .descriptorIsSymbolicLink
            )
        }
    }

    func testMalformedJSONIsReportedAsInvalidDescriptor() async throws {
        let sandboxURL = try makeSandboxURL()
        defer { try? FileManager.default.removeItem(at: sandboxURL) }

        let layout = ImportStorageLayout(rootURL: sandboxURL)
        let comicID = managedComicID(
            "00000000-0000-0000-0000-000000000905"
        )
        try write(
            Data("not-json".utf8),
            to: descriptorURL(for: comicID, layout: layout)
        )

        do {
            _ = try await FileSystemReaderContentLoader(
                layout: layout
            ).load(comicID: comicID)
            XCTFail("Expected an invalid descriptor error.")
        } catch {
            XCTAssertEqual(
                error as? ReaderContentLoaderError,
                .invalidDescriptor
            )
        }
    }

    func testUnsupportedSchemaIsReportedBeforeDomainConstruction() async throws {
        let sandboxURL = try makeSandboxURL()
        defer { try? FileManager.default.removeItem(at: sandboxURL) }

        let layout = ImportStorageLayout(rootURL: sandboxURL)
        let comicID = managedComicID(
            "00000000-0000-0000-0000-000000000906"
        )
        let unsupportedSchema = ManagedComicDescriptor.currentSchemaVersion + 1
        let data = try encodedDescriptor(
            makeDescriptor(comicID: comicID),
            changing: ["schemaVersion": unsupportedSchema]
        )
        try write(
            data,
            to: descriptorURL(for: comicID, layout: layout)
        )

        do {
            _ = try await FileSystemReaderContentLoader(
                layout: layout
            ).load(comicID: comicID)
            XCTFail("Expected an unsupported schema error.")
        } catch {
            XCTAssertEqual(
                error as? ReaderContentLoaderError,
                .unsupportedDescriptorSchema(unsupportedSchema)
            )
        }
    }

    func testComicIDMismatchIsReportedExplicitly() async throws {
        let sandboxURL = try makeSandboxURL()
        defer { try? FileManager.default.removeItem(at: sandboxURL) }

        let layout = ImportStorageLayout(rootURL: sandboxURL)
        let expectedID = managedComicID(
            "00000000-0000-0000-0000-000000000907"
        )
        let actualID = managedComicID(
            "00000000-0000-0000-0000-000000000908"
        )
        try write(
            makeDescriptor(comicID: actualID),
            to: descriptorURL(for: expectedID, layout: layout)
        )

        do {
            _ = try await FileSystemReaderContentLoader(
                layout: layout
            ).load(comicID: expectedID)
            XCTFail("Expected a comic identifier mismatch.")
        } catch {
            XCTAssertEqual(
                error as? ReaderContentLoaderError,
                .comicIDMismatch(expected: expectedID, actual: actualID)
            )
        }
    }

    func testReaderComicValidationErrorIsPreserved() async throws {
        let sandboxURL = try makeSandboxURL()
        defer { try? FileManager.default.removeItem(at: sandboxURL) }

        let layout = ImportStorageLayout(rootURL: sandboxURL)
        let comicID = managedComicID(
            "00000000-0000-0000-0000-000000000909"
        )
        let pageID = ImportPageCandidate.ID(rawValue: "page-1")
        let missingCoverID = ImportPageCandidate.ID(rawValue: "missing-cover")
        try write(
            makeDescriptor(
                comicID: comicID,
                workItems: [makeWorkItem(pageID)],
                coverPageID: missingCoverID
            ),
            to: descriptorURL(for: comicID, layout: layout)
        )

        do {
            _ = try await FileSystemReaderContentLoader(
                layout: layout
            ).load(comicID: comicID)
            XCTFail("Expected a ReaderComic validation error.")
        } catch {
            XCTAssertEqual(
                error as? ReaderContentLoaderError,
                .invalidComic(.missingCoverWorkItem(missingCoverID))
            )
        }
    }

    func testAssetResolverValidationErrorIsPreserved() async throws {
        let sandboxURL = try makeSandboxURL()
        defer { try? FileManager.default.removeItem(at: sandboxURL) }

        let layout = ImportStorageLayout(rootURL: sandboxURL)
        let comicID = managedComicID(
            "00000000-0000-0000-0000-000000000910"
        )
        let pageID = ImportPageCandidate.ID(rawValue: "page-1")
        try write(
            makeDescriptor(
                comicID: comicID,
                workItems: [
                    makeWorkItem(
                        pageID,
                        managedRelativePath: ManagedRelativePath(
                            components: ["preview", "page-1.png"]
                        )
                    ),
                ]
            ),
            to: descriptorURL(for: comicID, layout: layout)
        )

        do {
            _ = try await FileSystemReaderContentLoader(
                layout: layout
            ).load(comicID: comicID)
            XCTFail("Expected an asset resolver validation error.")
        } catch {
            XCTAssertEqual(
                error as? ReaderContentLoaderError,
                .invalidAssets(.invalidManagedPath(pageID))
            )
        }
    }

    func testCancellationIsNotWrappedAsAContentError() async {
        let comicID = managedComicID(
            "00000000-0000-0000-0000-000000000911"
        )
        let loader = FileSystemReaderContentLoader(
            layout: ImportStorageLayout(
                rootURL: FileManager.default.temporaryDirectory
            )
        )
        let task = Task {
            withUnsafeCurrentTask { currentTask in
                currentTask?.cancel()
            }
            return try await loader.load(comicID: comicID)
        }

        do {
            _ = try await task.value
            XCTFail("Expected CancellationError.")
        } catch is CancellationError {
            // Expected: cancellation remains distinguishable from content failure.
        } catch {
            XCTFail("Expected CancellationError, received \(error).")
        }
    }

    private func makeDescriptor(
        comicID: ManagedComicID,
        sourceBookmark: Data = Data(),
        workItems: [FrozenImportWorkItem]? = nil,
        coverPageID: ImportPageCandidate.ID? = nil
    ) -> ManagedComicDescriptor {
        let defaultPageID = ImportPageCandidate.ID(rawValue: "page-1")
        let resolvedWorkItems = workItems ?? [makeWorkItem(defaultPageID)]
        let chapterPageIDs = resolvedWorkItems.map(\.id)
        let plan = FrozenImportPlan(
            id: ImportJobID(
                rawValue: UUID(
                    uuidString: "00000000-0000-0000-0000-000000000912"
                )!
            ),
            revision: ImportPreviewRevision(rawValue: "reader-loader-revision"),
            sourceRootName: "Unavailable External Source",
            displayName: "Reader Loader Comic",
            sourceBookmark: sourceBookmark,
            sortLocaleIdentifier: "en_US_POSIX",
            collections: [],
            chapters: [
                FrozenImportChapter(
                    id: ImportChapterCandidate.ID(rawValue: "chapter-1"),
                    parentCollectionID: nil,
                    sourceDirectoryPath: SourceRelativePath(
                        components: ["missing-source", "Chapter 1"]
                    ),
                    originalName: "Chapter 1",
                    displayName: "Chapter 1",
                    role: .directory,
                    pageIDs: chapterPageIDs
                ),
            ],
            workItems: resolvedWorkItems,
            coverPageID: coverPageID ?? defaultPageID,
            scanIssues: [],
            spaceEstimate: .make(
                contentBytes: resolvedWorkItems.reduce(Int64(0)) {
                    $0 + max(0, $1.expectedByteCount)
                },
                fileCount: resolvedWorkItems.count
            )
        )
        let journal = ImportJobJournal(plan: plan, targetComicID: comicID)

        return ManagedComicDescriptor(plan: plan, journal: journal)
    }

    private func makeWorkItem(
        _ pageID: ImportPageCandidate.ID,
        managedRelativePath: ManagedRelativePath? = nil
    ) -> FrozenImportWorkItem {
        FrozenImportWorkItem(
            id: pageID,
            sourceRelativePath: SourceRelativePath(
                components: ["missing-source", "Chapter 1", "page-1.png"]
            ),
            managedRelativePath: managedRelativePath ?? ManagedRelativePath(
                components: ["original", "Chapter 1", "page-1.png"]
            ),
            originalFileName: "page-1.png",
            detectedFormat: .png,
            expectedByteCount: 128,
            expectedLightweightFingerprint: "unused-source-fingerprint",
            pixelSize: ImportPixelSize(width: 1_200, height: 1_800),
            orientation: .up,
            pageState: .readable,
            isCover: true
        )
    }

    private func descriptorURL(
        for comicID: ManagedComicID,
        layout: ImportStorageLayout
    ) -> URL {
        layout.libraryMetadataURL(for: comicID)
            .appendingPathComponent("import-descriptor.json")
    }

    private func write<Value: Encodable>(
        _ value: Value,
        to url: URL
    ) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        try write(try encoder.encode(value), to: url)
    }

    private func write(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url, options: .atomic)
    }

    private func encodedDescriptor(
        _ descriptor: ManagedComicDescriptor,
        changing values: [String: Any]
    ) throws -> Data {
        var payload = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: try JSONEncoder().encode(descriptor)
            ) as? [String: Any]
        )
        for (key, value) in values {
            payload[key] = value
        }
        return try JSONSerialization.data(
            withJSONObject: payload,
            options: [.sortedKeys]
        )
    }

    private func makeSandboxURL() throws -> URL {
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

    private func managedComicID(_ value: String) -> ManagedComicID {
        ManagedComicID(rawValue: UUID(uuidString: value)!)
    }
}
