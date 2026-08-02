import Foundation
import XCTest
@testable import ComicReader

final class ReaderPageAssetResolverTests: XCTestCase {
    func testAssetPreservesIdentityRootPathAndPersistedMetadata() throws {
        let comicID = managedComicID("00000000-0000-0000-0000-000000000801")
        let revision = ImportPreviewRevision(rawValue: "asset-revision")
        let pageID = ImportPageCandidate.ID(rawValue: "page-1")
        let managedPath = ManagedRelativePath(
            components: ["original", "Chapter 1", "01.heic"]
        )
        let workItem = makeWorkItem(
            pageID,
            managedRelativePath: managedPath,
            detectedFormat: .heic,
            expectedByteCount: 4_096,
            pixelSize: ImportPixelSize(width: 3_000, height: 4_500),
            orientation: .rightMirrored
        )
        let descriptor = makeDescriptor(
            comicID: comicID,
            revision: revision,
            workItems: [workItem]
        )
        let layout = ImportStorageLayout(
            rootURL: URL(fileURLWithPath: "/tmp/ComicReader/../ReaderAssets")
        )
        let resolver = try ManagedReaderPageAssetResolver(
            descriptor: descriptor,
            expectedComicID: comicID,
            layout: layout
        )

        let asset = try resolver.asset(for: pageID)

        XCTAssertEqual(
            asset.identity,
            ReaderPageAssetIdentity(
                comicID: comicID,
                revision: revision,
                pageID: pageID
            )
        )
        XCTAssertEqual(asset.identity.revision, revision)
        XCTAssertEqual(
            asset.comicRootURL,
            layout.libraryURL(for: comicID).standardizedFileURL
        )
        XCTAssertEqual(asset.managedRelativePath, managedPath)
        XCTAssertEqual(asset.managedRelativePath.components,
                       ["original", "Chapter 1", "01.heic"])
        XCTAssertEqual(asset.mediaType, .heic)
        XCTAssertEqual(asset.expectedByteCount, 4_096)
        XCTAssertEqual(
            asset.expectedPixelSize,
            ImportPixelSize(width: 3_000, height: 4_500)
        )
        XCTAssertEqual(asset.orientation, .rightMirrored)
    }

    func testInitializationRejectsUnsupportedDescriptorSchema() throws {
        let comicID = managedComicID("00000000-0000-0000-0000-000000000802")
        let descriptor = try descriptor(
            changingSchemaVersionTo: ManagedComicDescriptor.currentSchemaVersion + 1,
            in: makeDescriptor(comicID: comicID)
        )

        XCTAssertThrowsError(
            try ManagedReaderPageAssetResolver(
                descriptor: descriptor,
                expectedComicID: comicID,
                layout: makeLayout()
            )
        ) { error in
            XCTAssertEqual(
                error as? ReaderPageAssetResolverError,
                .unsupportedDescriptorSchema(
                    ManagedComicDescriptor.currentSchemaVersion + 1
                )
            )
        }
    }

    func testInitializationRejectsComicIDMismatch() {
        let actualComicID = managedComicID(
            "00000000-0000-0000-0000-000000000803"
        )
        let expectedComicID = managedComicID(
            "00000000-0000-0000-0000-000000000804"
        )
        let descriptor = makeDescriptor(comicID: actualComicID)

        XCTAssertThrowsError(
            try ManagedReaderPageAssetResolver(
                descriptor: descriptor,
                expectedComicID: expectedComicID,
                layout: makeLayout()
            )
        ) { error in
            XCTAssertEqual(
                error as? ReaderPageAssetResolverError,
                .comicIDMismatch(
                    expected: expectedComicID,
                    actual: actualComicID
                )
            )
        }
    }

    func testInitializationRejectsDuplicateWorkItem() {
        let comicID = managedComicID("00000000-0000-0000-0000-000000000805")
        let pageID = ImportPageCandidate.ID(rawValue: "duplicate-page")
        let workItem = makeWorkItem(pageID)
        let descriptor = makeDescriptor(
            comicID: comicID,
            workItems: [workItem, workItem]
        )

        XCTAssertThrowsError(
            try ManagedReaderPageAssetResolver(
                descriptor: descriptor,
                expectedComicID: comicID,
                layout: makeLayout()
            )
        ) { error in
            XCTAssertEqual(
                error as? ReaderPageAssetResolverError,
                .duplicatePageWorkItem(pageID)
            )
        }
    }

    func testInitializationRejectsManagedPathOutsideOriginalDirectory() {
        let comicID = managedComicID("00000000-0000-0000-0000-000000000806")
        let pageID = ImportPageCandidate.ID(rawValue: "preview-page")
        let descriptor = makeDescriptor(
            comicID: comicID,
            workItems: [
                makeWorkItem(
                    pageID,
                    managedRelativePath: ManagedRelativePath(
                        components: ["preview", "01.png"]
                    )
                ),
            ]
        )

        XCTAssertThrowsError(
            try ManagedReaderPageAssetResolver(
                descriptor: descriptor,
                expectedComicID: comicID,
                layout: makeLayout()
            )
        ) { error in
            XCTAssertEqual(
                error as? ReaderPageAssetResolverError,
                .invalidManagedPath(pageID)
            )
        }
    }

    func testInitializationRejectsNonPositiveExpectedByteCount() {
        let comicID = managedComicID("00000000-0000-0000-0000-000000000807")

        for (rawPageID, byteCount) in [("zero-byte", Int64(0)),
                                       ("negative-byte", Int64(-1))] {
            let pageID = ImportPageCandidate.ID(rawValue: rawPageID)
            let descriptor = makeDescriptor(
                comicID: comicID,
                workItems: [
                    makeWorkItem(
                        pageID,
                        expectedByteCount: byteCount
                    ),
                ]
            )

            XCTAssertThrowsError(
                try ManagedReaderPageAssetResolver(
                    descriptor: descriptor,
                    expectedComicID: comicID,
                    layout: makeLayout()
                )
            ) { error in
                XCTAssertEqual(
                    error as? ReaderPageAssetResolverError,
                    .invalidExpectedByteCount(pageID)
                )
            }
        }
    }

    func testAssetRejectsMissingPage() throws {
        let comicID = managedComicID("00000000-0000-0000-0000-000000000808")
        let missingPageID = ImportPageCandidate.ID(rawValue: "missing-page")
        let resolver = try ManagedReaderPageAssetResolver(
            descriptor: makeDescriptor(comicID: comicID),
            expectedComicID: comicID,
            layout: makeLayout()
        )

        XCTAssertThrowsError(try resolver.asset(for: missingPageID)) { error in
            XCTAssertEqual(
                error as? ReaderPageAssetResolverError,
                .pageNotFound(missingPageID)
            )
        }
    }

    func testAssetRejectsCorruptedPage() throws {
        let comicID = managedComicID("00000000-0000-0000-0000-000000000809")
        let pageID = ImportPageCandidate.ID(rawValue: "corrupted-page")
        let resolver = try ManagedReaderPageAssetResolver(
            descriptor: makeDescriptor(
                comicID: comicID,
                workItems: [makeWorkItem(pageID, pageState: .corrupted)]
            ),
            expectedComicID: comicID,
            layout: makeLayout()
        )

        XCTAssertThrowsError(try resolver.asset(for: pageID)) { error in
            XCTAssertEqual(
                error as? ReaderPageAssetResolverError,
                .pageIsUnreadable(pageID)
            )
        }
    }

    private func makeDescriptor(
        comicID: ManagedComicID,
        revision: ImportPreviewRevision = ImportPreviewRevision(
            rawValue: "resolver-test-revision"
        ),
        workItems: [FrozenImportWorkItem] = []
    ) -> ManagedComicDescriptor {
        let fallbackPageID = ImportPageCandidate.ID(rawValue: "cover")
        let coverPageID = workItems.first?.id ?? fallbackPageID
        let plan = FrozenImportPlan(
            id: ImportJobID(
                rawValue: UUID(
                    uuidString: "00000000-0000-0000-0000-000000000810"
                )!
            ),
            revision: revision,
            sourceRootName: "Resolver Test Source",
            displayName: "Resolver Test Comic",
            sourceBookmark: Data(),
            sortLocaleIdentifier: "en_US_POSIX",
            collections: [],
            chapters: [],
            workItems: workItems,
            coverPageID: coverPageID,
            scanIssues: [],
            spaceEstimate: .make(
                contentBytes: workItems.reduce(Int64(0)) {
                    $0 + max(0, $1.expectedByteCount)
                },
                fileCount: workItems.count
            )
        )
        let journal = ImportJobJournal(plan: plan, targetComicID: comicID)

        return ManagedComicDescriptor(plan: plan, journal: journal)
    }

    private func makeWorkItem(
        _ pageID: ImportPageCandidate.ID,
        managedRelativePath: ManagedRelativePath? = nil,
        detectedFormat: ImportImageMediaType = .png,
        expectedByteCount: Int64 = 1,
        pixelSize: ImportPixelSize? = nil,
        orientation: ImportImageOrientation? = nil,
        pageState: ImportPageState = .readable
    ) -> FrozenImportWorkItem {
        FrozenImportWorkItem(
            id: pageID,
            sourceRelativePath: SourceRelativePath(
                components: ["Chapter 1", "\(pageID.rawValue).png"]
            ),
            managedRelativePath: managedRelativePath ?? ManagedRelativePath(
                components: ["original", "Chapter 1", "\(pageID.rawValue).png"]
            ),
            originalFileName: "\(pageID.rawValue).png",
            detectedFormat: detectedFormat,
            expectedByteCount: expectedByteCount,
            expectedLightweightFingerprint: "fingerprint-\(pageID.rawValue)",
            pixelSize: pixelSize,
            orientation: orientation,
            pageState: pageState,
            isCover: false
        )
    }

    private func descriptor(
        changingSchemaVersionTo schemaVersion: Int,
        in descriptor: ManagedComicDescriptor
    ) throws -> ManagedComicDescriptor {
        var payload = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: try JSONEncoder().encode(descriptor)
            ) as? [String: Any]
        )
        payload["schemaVersion"] = schemaVersion

        return try JSONDecoder().decode(
            ManagedComicDescriptor.self,
            from: JSONSerialization.data(
                withJSONObject: payload,
                options: [.sortedKeys]
            )
        )
    }

    private func makeLayout() -> ImportStorageLayout {
        ImportStorageLayout(
            rootURL: URL(fileURLWithPath: "/tmp/ComicReaderResolverTests")
        )
    }

    private func managedComicID(_ value: String) -> ManagedComicID {
        ManagedComicID(rawValue: UUID(uuidString: value)!)
    }
}
