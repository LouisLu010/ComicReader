import Foundation
import SwiftData

@MainActor
struct UITestFixtureConfiguration {
    let modelContainer: ModelContainer
    let importJobs: ImportJobCoordinator
    let readerFeatureServices: ReaderFeatureServices
    let libraryCatalog: LibraryCatalogCoordinator
}

struct UITestFixtureRequest: Equatable, Sendable {
    let rawValue: String
}

enum UITestFixtureBootstrap {
#if DEBUG
    enum Fixture: String, Sendable {
        case emptyLibrary = "empty-library"
        case readerNavigation = "reader-navigation"
    }

    static let environmentKey = "COMICREADER_UI_TEST_FIXTURE"
    static let readerNavigationComicID = ManagedComicID(
        rawValue: UUID(
            uuidString: "00000000-0000-0000-0000-000000000901"
        )!
    )
    static let readerNavigationCoverPageID = ImportPageCandidate.ID(
        rawValue: "ui-cover"
    )
    static let readerNavigationChapterOnePageTwoID = ImportPageCandidate.ID(
        rawValue: "ui-chapter-one-page-two"
    )
    static let readerNavigationChapterTwoPageOneID = ImportPageCandidate.ID(
        rawValue: "ui-chapter-two-page-one"
    )
#endif

    static func requestedFixture(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> UITestFixtureRequest? {
#if DEBUG
        guard let rawValue = environment[environmentKey] else {
            return nil
        }
        return UITestFixtureRequest(rawValue: rawValue)
#else
        _ = environment
        return nil
#endif
    }

    @MainActor
    static func makeConfiguration(
        for request: UITestFixtureRequest
    ) async throws -> UITestFixtureConfiguration {
#if DEBUG
        guard let fixture = Fixture(rawValue: request.rawValue) else {
            throw UITestFixtureBootstrapError.unknownFixture
        }

        let layout = temporaryLayout()
        try await Task.detached(priority: .userInitiated) {
            try install(fixture, in: layout, fileManager: FileManager())
        }.value
        let modelContainer = try ComicReaderModelContainer.makeContainer(
            isStoredInMemoryOnly: true
        )
        let importJobs = ImportJobCoordinator(
            jobManager: RecoverableImportJobManager(
                engine: RecoverableImportEngine(layout: layout)
            ),
            allowsLibraryWrites: false
        )

        return UITestFixtureConfiguration(
            modelContainer: modelContainer,
            importJobs: importJobs,
            readerFeatureServices: ReaderFeatureServices(
                contentLoader: FileSystemReaderContentLoader(layout: layout)
            ),
            libraryCatalog: LibraryCatalogCoordinator(
                loader: FileSystemLibraryCatalogLoader(layout: layout),
                layout: layout
            )
        )
#else
        _ = request
        throw UITestFixtureBootstrapError.unavailable
#endif
    }

#if DEBUG
    static func install(
        _ fixture: Fixture,
        in layout: ImportStorageLayout,
        fileManager: FileManager = .default
    ) throws {
        try resetStorage(at: layout.rootURL, fileManager: fileManager)

        for directory in [
            layout.rootURL,
            layout.importsURL,
            layout.libraryURL,
            layout.thumbnailsURL,
        ] {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        }

        guard fixture == .readerNavigation else {
            return
        }

        try installReaderNavigationFixture(
            in: layout,
            fileManager: fileManager
        )
    }

    private static func temporaryLayout() -> ImportStorageLayout {
        // UI Tests 串行运行；固定根目录让下一次启动可清除上次进程遗留。
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "ComicReaderUITestFixture",
                isDirectory: true
            )
        return ImportStorageLayout(rootURL: rootURL)
    }

    private static func resetStorage(
        at rootURL: URL,
        fileManager: FileManager
    ) throws {
        guard fileManager.fileExists(atPath: rootURL.path) else {
            return
        }

        let values = try rootURL.resourceValues(
            forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        )
        guard values.isSymbolicLink != true,
              values.isDirectory == true else {
            throw UITestFixtureBootstrapError.unsafeStorageRoot
        }

        try fileManager.removeItem(at: rootURL)
    }

    private static func installReaderNavigationFixture(
        in layout: ImportStorageLayout,
        fileManager: FileManager
    ) throws {
        let portraitImageData = try portraitFixtureImageData()
        let landscapeImageData = try landscapeFixtureImageData()
        let cover = makeWorkItem(
            id: readerNavigationCoverPageID,
            sourcePath: ["cover.png"],
            pixelSize: ImportPixelSize(width: 2, height: 3),
            isCover: true,
            byteCount: Int64(portraitImageData.count)
        )
        let chapterOnePageOne = makeWorkItem(
            id: ImportPageCandidate.ID(rawValue: "ui-chapter-one-page-one"),
            sourcePath: ["Chapter 1", "001.png"],
            pixelSize: ImportPixelSize(width: 2, height: 3),
            isCover: false,
            byteCount: Int64(portraitImageData.count)
        )
        let chapterOnePageTwo = makeWorkItem(
            id: readerNavigationChapterOnePageTwoID,
            sourcePath: ["Chapter 1", "002.png"],
            pixelSize: ImportPixelSize(width: 2, height: 3),
            isCover: false,
            byteCount: Int64(portraitImageData.count)
        )
        let chapterTwoPageOne = makeWorkItem(
            id: readerNavigationChapterTwoPageOneID,
            sourcePath: ["Chapter 2", "001.png"],
            pixelSize: ImportPixelSize(width: 3, height: 2),
            isCover: false,
            byteCount: Int64(landscapeImageData.count)
        )
        let chapterTwoPageTwo = makeWorkItem(
            id: ImportPageCandidate.ID(rawValue: "ui-chapter-two-page-two"),
            sourcePath: ["Chapter 2", "002.png"],
            pixelSize: ImportPixelSize(width: 2, height: 3),
            isCover: false,
            byteCount: Int64(portraitImageData.count)
        )
        let workItemAssets = [
            (workItem: cover, data: portraitImageData),
            (workItem: chapterOnePageOne, data: portraitImageData),
            (workItem: chapterOnePageTwo, data: portraitImageData),
            (workItem: chapterTwoPageOne, data: landscapeImageData),
            (workItem: chapterTwoPageTwo, data: portraitImageData),
        ]
        let workItems = workItemAssets.map { $0.workItem }
        let chapters = [
            FrozenImportChapter(
                id: ImportChapterCandidate.ID(rawValue: "ui-chapter-one"),
                parentCollectionID: nil,
                sourceDirectoryPath: SourceRelativePath(
                    components: ["Chapter 1"]
                ),
                originalName: "Chapter 1",
                displayName: "Chapter 1",
                role: .directory,
                pageIDs: [chapterOnePageOne.id, chapterOnePageTwo.id]
            ),
            FrozenImportChapter(
                id: ImportChapterCandidate.ID(rawValue: "ui-chapter-two"),
                parentCollectionID: nil,
                sourceDirectoryPath: SourceRelativePath(
                    components: ["Chapter 2"]
                ),
                originalName: "Chapter 2",
                displayName: "Chapter 2",
                role: .directory,
                pageIDs: [chapterTwoPageOne.id, chapterTwoPageTwo.id]
            ),
        ]
        let plan = FrozenImportPlan(
            id: ImportJobID(
                rawValue: UUID(
                    uuidString: "00000000-0000-0000-0000-000000000902"
                )!
            ),
            revision: ImportPreviewRevision(
                rawValue: "ui-test-reader-navigation-v1"
            ),
            sourceRootName: "Reader UI Test Fixture",
            displayName: "Reader UI Test Comic",
            sourceBookmark: Data(),
            sortLocaleIdentifier: "en_US_POSIX",
            collections: [],
            chapters: chapters,
            workItems: workItems,
            coverPageID: cover.id,
            scanIssues: [],
            spaceEstimate: .make(
                contentBytes: workItems.reduce(0) {
                    $0 + $1.expectedByteCount
                },
                fileCount: workItems.count
            )
        )
        let descriptor = ManagedComicDescriptor(
            plan: plan,
            journal: ImportJobJournal(
                plan: plan,
                targetComicID: readerNavigationComicID
            )
        )
        let comicRootURL = layout.libraryURL(for: readerNavigationComicID)

        for asset in workItemAssets {
            let imageURL = asset.workItem.managedRelativePath.components.reduce(
                comicRootURL
            ) { currentURL, component in
                currentURL.appendingPathComponent(component)
            }
            try write(asset.data, to: imageURL, fileManager: fileManager)
        }

        try write(
            descriptor,
            to: layout.libraryMetadataURL(for: readerNavigationComicID)
                .appendingPathComponent("import-descriptor.json"),
            fileManager: fileManager
        )
        try write(
            LibraryCatalogRecord(
                descriptor: descriptor,
                importedAt: .distantPast
            ),
            to: layout.libraryCatalogURL(for: readerNavigationComicID),
            fileManager: fileManager
        )
    }

    private static func makeWorkItem(
        id: ImportPageCandidate.ID,
        sourcePath: [String],
        pixelSize: ImportPixelSize,
        isCover: Bool,
        byteCount: Int64
    ) -> FrozenImportWorkItem {
        FrozenImportWorkItem(
            id: id,
            sourceRelativePath: SourceRelativePath(components: sourcePath),
            managedRelativePath: ManagedRelativePath(
                components: ["original"] + sourcePath
            ),
            originalFileName: sourcePath.last ?? id.rawValue,
            detectedFormat: .png,
            expectedByteCount: byteCount,
            expectedLightweightFingerprint: nil,
            pixelSize: pixelSize,
            orientation: .up,
            pageState: .readable,
            isCover: isCover
        )
    }

    private static func portraitFixtureImageData() throws -> Data {
        try fixtureImageData(encodedImage: (
            "iVBORw0KGgoAAAANSUhEUgAAAAIAAAADCAIAAAA2iEnWAAAAE"
                + "UlEQVR4nGP8zwACTGASRgEAFEABBVDVLjgAAAAASUVORK5CYII="
        ))
    }

    private static func landscapeFixtureImageData() throws -> Data {
        try fixtureImageData(encodedImage: (
            "iVBORw0KGgoAAAANSUhEUgAAAAMAAAACCAIAAAASFvFNAAAAE"
                + "UlEQVR4nGP4z8AAQQwwxn8AO9gF+zlNlqUAAAAASUVORK5CYII="
        ))
    }

    private static func fixtureImageData(encodedImage: String) throws -> Data {
        // 自生成的微型 PNG，仅用于测试真实 ImageIO 路径，不含用户内容。
        guard let imageData = Data(base64Encoded: encodedImage) else {
            throw UITestFixtureBootstrapError.invalidEmbeddedImage
        }

        return imageData
    }

    private static func write<Value: Encodable>(
        _ value: Value,
        to url: URL,
        fileManager: FileManager
    ) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        try write(try encoder.encode(value), to: url, fileManager: fileManager)
    }

    private static func write(
        _ data: Data,
        to url: URL,
        fileManager: FileManager
    ) throws {
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url, options: .atomic)
    }
#endif
}

enum UITestFixtureBootstrapError: Error, Equatable, LocalizedError, Sendable {
    case unknownFixture
    case unsafeStorageRoot
    case invalidEmbeddedImage
    case unavailable

    var errorDescription: String? {
        switch self {
        case .unknownFixture:
            "Unknown UI test fixture."
        case .unsafeStorageRoot:
            "The UI test fixture storage root is unsafe to replace."
        case .invalidEmbeddedImage:
            "The embedded UI test fixture image is invalid."
        case .unavailable:
            "UI test fixtures are unavailable in this build."
        }
    }
}
