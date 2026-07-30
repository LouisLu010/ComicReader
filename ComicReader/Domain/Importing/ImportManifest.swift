import Foundation

struct ImportScanRequest: Sendable {
    let rootURL: URL
    let locale: Locale

    init(rootURL: URL, locale: Locale = .current) {
        self.rootURL = rootURL
        self.locale = locale
    }
}

protocol ImportScanning: Sendable {
    func scan(_ request: ImportScanRequest) async throws -> ImportManifest
}

struct ImportManifest: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let sourceRootName: String
    let sortLocaleIdentifier: String
    let collections: [ImportCollectionCandidate]
    let chapters: [ImportChapterCandidate]
    let pages: [ImportPageCandidate]
    let coverPageID: ImportPageCandidate.ID?
    let issues: [ImportIssue]
    let spaceEstimate: ImportSpaceEstimate

    init(
        schemaVersion: Int = Self.currentSchemaVersion,
        sourceRootName: String,
        sortLocaleIdentifier: String,
        collections: [ImportCollectionCandidate],
        chapters: [ImportChapterCandidate],
        pages: [ImportPageCandidate],
        coverPageID: ImportPageCandidate.ID?,
        issues: [ImportIssue],
        spaceEstimate: ImportSpaceEstimate
    ) {
        self.schemaVersion = schemaVersion
        self.sourceRootName = sourceRootName
        self.sortLocaleIdentifier = sortLocaleIdentifier
        self.collections = collections
        self.chapters = chapters
        self.pages = pages
        self.coverPageID = coverPageID
        self.issues = issues
        self.spaceEstimate = spaceEstimate
    }

    var coverPage: ImportPageCandidate? {
        guard let coverPageID else {
            return nil
        }
        return pages.first { $0.id == coverPageID }
    }

    var readablePageCount: Int {
        pages.filter { $0.state == .readable }.count
    }

    var chapterPageCount: Int {
        chapters.reduce(0) { $0 + $1.pageIDs.count }
    }

    var readableChapterPageCount: Int {
        let chapterPageIDs = Set(chapters.flatMap(\.pageIDs))
        return pages.filter {
            chapterPageIDs.contains($0.id) && $0.state == .readable
        }.count
    }

    func pages(in chapter: ImportChapterCandidate) -> [ImportPageCandidate] {
        let pageByID = Dictionary(uniqueKeysWithValues: pages.map { ($0.id, $0) })
        return chapter.pageIDs.compactMap { pageByID[$0] }
    }
}

struct ImportCollectionCandidate: Codable, Equatable, Identifiable, Sendable {
    struct ID: Codable, Hashable, RawRepresentable, Sendable {
        let rawValue: String

        init(rawValue: String) {
            self.rawValue = rawValue
        }
    }

    let id: ID
    let parentID: ID?
    let sourceRelativePath: SourceRelativePath
    let originalName: String
    let siblingIndex: Int
}

struct ImportChapterCandidate: Codable, Equatable, Identifiable, Sendable {
    struct ID: Codable, Hashable, RawRepresentable, Sendable {
        let rawValue: String

        init(rawValue: String) {
            self.rawValue = rawValue
        }
    }

    let id: ID
    let parentCollectionID: ImportCollectionCandidate.ID?
    let sourceDirectoryPath: SourceRelativePath
    let originalName: String
    let role: ImportChapterRole
    let siblingIndex: Int
    let pageIDs: [ImportPageCandidate.ID]
}

enum ImportChapterRole: String, Codable, Equatable, Sendable {
    case directory
    case rootLoosePages
    case collectionLoosePages
}

struct ImportPageCandidate: Codable, Equatable, Identifiable, Sendable {
    struct ID: Codable, Hashable, RawRepresentable, Sendable {
        let rawValue: String

        init(rawValue: String) {
            self.rawValue = rawValue
        }
    }

    let id: ID
    let sourceRelativePath: SourceRelativePath
    let originalFileName: String
    let detectedFormat: ImportImageMediaType
    let byteCount: Int64
    let pixelSize: ImportPixelSize?
    let orientation: ImportImageOrientation?
    let lightweightFingerprint: String?
    let state: ImportPageState
    let pageIndex: Int?
}

enum ImportPageState: String, Codable, Equatable, Sendable {
    case readable
    case corrupted
}

struct ImportPixelSize: Codable, Equatable, Sendable {
    let width: Int
    let height: Int
}

enum ImportImageOrientation: Int, Codable, Equatable, Sendable {
    case up = 1
    case upMirrored = 2
    case down = 3
    case downMirrored = 4
    case leftMirrored = 5
    case right = 6
    case rightMirrored = 7
    case left = 8
}

enum ImportImageMediaType: String, CaseIterable, Codable, Equatable, Sendable {
    case jpeg
    case png
    case webP
    case heic
    case heif
    case gif
    case bmp
    case tiff
}

struct SourceRelativePath: Codable, Hashable, Sendable {
    static let root = SourceRelativePath(components: [])

    let components: [String]

    var stringValue: String {
        components.joined(separator: "/")
    }

    var lastComponent: String? {
        components.last
    }

    func appending(_ component: String) -> SourceRelativePath {
        SourceRelativePath(components: components + [component])
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        guard lhs.components.count == rhs.components.count else {
            return false
        }

        return zip(lhs.components, rhs.components).allSatisfy { pair in
            pair.0.utf8.elementsEqual(pair.1.utf8)
        }
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(components.count)

        for component in components {
            hasher.combine(component.utf8.count)
            for byte in component.utf8 {
                hasher.combine(byte)
            }
        }
    }

    init(components: [String]) {
        precondition(
            Self.areSafe(components),
            "Source-relative paths must contain safe path components."
        )
        self.components = components
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let components = try container.decode(
            [String].self,
            forKey: .components
        )

        guard Self.areSafe(components) else {
            throw DecodingError.dataCorruptedError(
                forKey: .components,
                in: container,
                debugDescription: "Source-relative path contains unsafe components."
            )
        }

        self.components = components
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(components, forKey: .components)
    }

    var identifierComponent: String {
        components
            .map(Self.hexEncodedUTF8)
            .joined(separator: "/")
    }

    private enum CodingKeys: String, CodingKey {
        case components
    }

    private static func areSafe(_ components: [String]) -> Bool {
        components.allSatisfy {
            !$0.isEmpty
                && $0 != "."
                && $0 != ".."
                && !$0.contains("/")
                && !$0.contains("\0")
        }
    }

    private static func hexEncodedUTF8(_ component: String) -> String {
        var encoded: [UInt8] = []
        encoded.reserveCapacity(component.utf8.count * 2)

        for byte in component.utf8 {
            encoded.append(identifierHexAlphabet[Int(byte >> 4)])
            encoded.append(identifierHexAlphabet[Int(byte & 0x0F)])
        }

        return String(decoding: encoded, as: UTF8.self)
    }

    private static let identifierHexAlphabet = Array(
        "0123456789abcdef".utf8
    )
}

struct ImportIssue: Codable, Equatable, Sendable {
    let code: ImportIssueCode
    let severity: ImportIssueSeverity
    let sourceRelativePaths: [SourceRelativePath]
    let detectedTypeIdentifier: String?

    init(
        code: ImportIssueCode,
        severity: ImportIssueSeverity,
        sourceRelativePaths: [SourceRelativePath],
        detectedTypeIdentifier: String? = nil
    ) {
        self.code = code
        self.severity = severity
        self.sourceRelativePaths = sourceRelativePaths
        self.detectedTypeIdentifier = detectedTypeIdentifier
    }
}

enum ImportIssueCode: String, Codable, Equatable, Sendable {
    case hiddenItemSkipped
    case systemItemSkipped
    case symbolicLinkSkipped
    case aliasSkipped
    case emptyDirectorySkipped
    case unsupportedFileType
    case unreadableFile
    case unreadableDirectory
    case corruptedImage
    case lightweightFingerprintUnavailable
    case chapterHasNoReadablePages
    case suspectedDuplicate
    case noReadableChapter
}

enum ImportIssueSeverity: String, Codable, Equatable, Sendable {
    case information
    case warning
}

struct ImportSpaceEstimate: Codable, Equatable, Sendable {
    let contentBytes: Int64
    let temporaryMarginBytes: Int64
    let requiredAvailableBytes: Int64
    let fileCount: Int

    static func make(contentBytes: Int64, fileCount: Int) -> Self {
        let safeContentBytes = max(0, contentBytes)
        let quotient = safeContentBytes / 10
        let remainder = safeContentBytes % 10
        let margin = quotient.addingReportingOverflow(remainder == 0 ? 0 : 1)
        let safeMargin = margin.overflow ? Int64.max : margin.partialValue
        let total = safeContentBytes.addingReportingOverflow(safeMargin)

        return Self(
            contentBytes: safeContentBytes,
            temporaryMarginBytes: safeMargin,
            requiredAvailableBytes: total.overflow ? Int64.max : total.partialValue,
            fileCount: max(0, fileCount)
        )
    }
}

enum ImportScanError: Error, Equatable, Sendable {
    case rootDoesNotExist
    case rootIsNotDirectory
    case symbolicLinkRootIsUnsupported
    case aliasRootIsUnsupported
    case rootCannotBeRead
}

extension ImportCollectionCandidate.ID {
    static func sourcePath(_ path: SourceRelativePath) -> Self {
        Self(rawValue: "collection:\(path.identifierComponent)")
    }
}

extension ImportChapterCandidate.ID {
    static func sourcePath(
        _ path: SourceRelativePath,
        role: ImportChapterRole
    ) -> Self {
        Self(rawValue: "chapter:\(path.identifierComponent)#\(role.rawValue)")
    }
}

extension ImportPageCandidate.ID {
    static func sourcePath(_ path: SourceRelativePath) -> Self {
        Self(rawValue: "page:\(path.identifierComponent)")
    }
}
