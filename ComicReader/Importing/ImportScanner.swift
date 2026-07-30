import Foundation

struct ImportScanner: ImportScanning {
    func scan(_ request: ImportScanRequest) async throws -> ImportManifest {
        let didStartSecurityScope = request.rootURL.startAccessingSecurityScopedResource()
        defer {
            if didStartSecurityScope {
                request.rootURL.stopAccessingSecurityScopedResource()
            }
        }

        let worker = Task.detached(priority: .userInitiated) {
            var engine = ImportScannerEngine(
                fileManager: .default,
                locale: request.locale
            )
            return try engine.scan(rootURL: request.rootURL)
        }

        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
    }
}

private struct ImportScannerEngine {
    private let fileManager: FileManager
    private let locale: Locale
    private let imageProbe = ImageContentProbe()
    private let coordinatedAccess = CoordinatedFileAccess()

    private var collections: [ImportCollectionCandidate] = []
    private var chapters: [ImportChapterCandidate] = []
    private var pages: [ImportPageCandidate] = []
    private var issues: [ImportIssue] = []

    init(fileManager: FileManager, locale: Locale) {
        self.fileManager = fileManager
        self.locale = locale
    }

    mutating func scan(rootURL: URL) throws -> ImportManifest {
        let rootValues: URLResourceValues

        do {
            rootValues = try rootURL.resourceValues(
                forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isAliasFileKey]
            )
        } catch let error as CocoaError
            where error.code == .fileNoSuchFile
                || error.code == .fileReadNoSuchFile {
            throw ImportScanError.rootDoesNotExist
        } catch {
            throw ImportScanError.rootCannotBeRead
        }

        if rootValues.isSymbolicLink == true {
            throw ImportScanError.symbolicLinkRootIsUnsupported
        }

        if rootValues.isAliasFile == true {
            throw ImportScanError.aliasRootIsUnsupported
        }

        guard rootValues.isDirectory == true else {
            throw ImportScanError.rootIsNotDirectory
        }

        let rootDirectory = try scanDirectory(
            at: rootURL,
            sourceName: rootURL.lastPathComponent,
            sourceRelativePath: .root,
            isRoot: true
        )
        let coverSelection = selectCover(in: rootDirectory)
        let rootPages = rootDirectory.pages.filter {
            $0.page.id != coverSelection.excludedRootPageID
        }

        var rootSiblingIndex = 0
        if appendChapter(
            sourceName: rootDirectory.sourceName,
            sourceDirectoryPath: .root,
            role: .rootLoosePages,
            siblingIndex: rootSiblingIndex,
            parentCollectionID: nil,
            scannedPages: rootPages
        ) {
            rootSiblingIndex += 1
        }

        for child in rootDirectory.children {
            if appendDirectory(
                child,
                parentCollectionID: nil,
                siblingIndex: rootSiblingIndex
            ) {
                rootSiblingIndex += 1
            }
        }

        if let coverPage = coverSelection.page,
           !pages.contains(where: { $0.id == coverPage.id }) {
            pages.append(coverPage.withPageIndex(nil))
        }

        if chapters.isEmpty {
            issues.append(
                ImportIssue(
                    code: .noReadableChapter,
                    severity: .warning,
                    sourceRelativePaths: [.root]
                )
            )
        }

        issues.sort(by: issueOrder)

        let contentBytes = pages.reduce(Int64(0)) { total, page in
            let addition = total.addingReportingOverflow(max(0, page.byteCount))
            return addition.overflow ? Int64.max : addition.partialValue
        }

        return ImportManifest(
            sourceRootName: rootDirectory.sourceName,
            sortLocaleIdentifier: locale.identifier,
            collections: collections,
            chapters: chapters,
            pages: pages,
            coverPageID: coverSelection.page?.id,
            issues: issues,
            spaceEstimate: .make(
                contentBytes: contentBytes,
                fileCount: pages.count
            )
        )
    }

    private mutating func scanDirectory(
        at directoryURL: URL,
        sourceName: String,
        sourceRelativePath: SourceRelativePath,
        isRoot: Bool
    ) throws -> ScannedDirectory {
        try Task.checkCancellation()

        let childrenURLs: [URL]

        do {
            childrenURLs = try coordinatedAccess.read(at: directoryURL) { coordinatedURL in
                try fileManager.contentsOfDirectory(
                    at: coordinatedURL,
                    includingPropertiesForKeys: Array(Self.resourceKeys),
                    options: []
                )
            }
        } catch {
            if isRoot {
                throw ImportScanError.rootCannotBeRead
            }

            issues.append(
                ImportIssue(
                    code: .unreadableDirectory,
                    severity: .warning,
                    sourceRelativePaths: [sourceRelativePath]
                )
            )
            return ScannedDirectory(
                sourceName: sourceName,
                sourceRelativePath: sourceRelativePath,
                pages: [],
                children: [],
                wasReadable: false,
                hadEntries: false
            )
        }

        var entries: [SourceEntry] = []

        for childURL in childrenURLs {
            try Task.checkCancellation()
            let childName = childURL.lastPathComponent
            let childPath = sourceRelativePath.appending(childName)

            if Self.isSystemItem(childName) {
                issues.append(
                    ImportIssue(
                        code: .systemItemSkipped,
                        severity: .information,
                        sourceRelativePaths: [childPath]
                    )
                )
                continue
            }

            let values: URLResourceValues

            do {
                values = try childURL.resourceValues(forKeys: Self.resourceKeys)
            } catch {
                issues.append(
                    ImportIssue(
                        code: .unreadableFile,
                        severity: .warning,
                        sourceRelativePaths: [childPath]
                    )
                )
                continue
            }

            if values.isHidden == true || childName.hasPrefix(".") {
                issues.append(
                    ImportIssue(
                        code: .hiddenItemSkipped,
                        severity: .information,
                        sourceRelativePaths: [childPath]
                    )
                )
                continue
            }

            if values.isSymbolicLink == true {
                issues.append(
                    ImportIssue(
                        code: .symbolicLinkSkipped,
                        severity: .information,
                        sourceRelativePaths: [childPath]
                    )
                )
                continue
            }

            if values.isAliasFile == true {
                issues.append(
                    ImportIssue(
                        code: .aliasSkipped,
                        severity: .information,
                        sourceRelativePaths: [childPath]
                    )
                )
                continue
            }

            entries.append(
                SourceEntry(
                    url: childURL,
                    name: childName,
                    sourceRelativePath: childPath,
                    values: values
                )
            )
        }

        entries.sort {
            sourceItemOrder(
                lhsName: $0.name,
                lhsCreationDate: $0.values.creationDate,
                lhsPath: $0.sourceRelativePath,
                rhsName: $1.name,
                rhsCreationDate: $1.values.creationDate,
                rhsPath: $1.sourceRelativePath
            )
        }

        var scannedPages: [ScannedPage] = []
        var scannedDirectories: [ScannedDirectory] = []

        for entry in entries {
            try Task.checkCancellation()

            if entry.values.isDirectory == true {
                let directory = try scanDirectory(
                    at: entry.url,
                    sourceName: entry.name,
                    sourceRelativePath: entry.sourceRelativePath,
                    isRoot: false
                )

                if directory.wasReadable,
                   directory.pages.isEmpty,
                   directory.children.isEmpty,
                   !directory.hadEntries {
                    issues.append(
                        ImportIssue(
                            code: .emptyDirectorySkipped,
                            severity: .information,
                            sourceRelativePaths: [entry.sourceRelativePath]
                        )
                    )
                }

                if !directory.pages.isEmpty || !directory.children.isEmpty {
                    scannedDirectories.append(directory)
                }
                continue
            }

            guard entry.values.isRegularFile == true else {
                issues.append(
                    ImportIssue(
                        code: .unsupportedFileType,
                        severity: .information,
                        sourceRelativePaths: [entry.sourceRelativePath]
                    )
                )
                continue
            }

            let scannedFile: ScannedFile

            do {
                scannedFile = try coordinatedAccess.read(at: entry.url) { coordinatedURL in
                    let byteCount = try fileByteCount(at: coordinatedURL)
                    let result = imageProbe.probe(
                        fileURL: coordinatedURL,
                        fileName: entry.name,
                        sourceRelativePath: entry.sourceRelativePath,
                        byteCount: byteCount
                    )
                    let fingerprint: String?
                    let fingerprintIssue: ImportIssue?

                    if case let .page(page, _) = result,
                       page.state == .readable {
                        do {
                            fingerprint = try LightweightContentFingerprint.make(
                                fileURL: coordinatedURL,
                                byteCount: byteCount
                            )
                            fingerprintIssue = nil
                        } catch {
                            fingerprint = nil
                            fingerprintIssue = ImportIssue(
                                code: .lightweightFingerprintUnavailable,
                                severity: .information,
                                sourceRelativePaths: [entry.sourceRelativePath]
                            )
                        }
                    } else {
                        fingerprint = nil
                        fingerprintIssue = nil
                    }

                    return ScannedFile(
                        result: result,
                        fingerprint: fingerprint,
                        fingerprintIssue: fingerprintIssue
                    )
                }
            } catch {
                issues.append(
                    ImportIssue(
                        code: .unreadableFile,
                        severity: .warning,
                        sourceRelativePaths: [entry.sourceRelativePath]
                    )
                )
                continue
            }

            switch scannedFile.result {
            case let .page(page, issue):
                scannedPages.append(
                    ScannedPage(
                        page: page.withLightweightFingerprint(
                            scannedFile.fingerprint
                        ),
                        creationDate: entry.values.creationDate
                    )
                )
                if let issue {
                    issues.append(issue)
                }
                if let fingerprintIssue = scannedFile.fingerprintIssue {
                    issues.append(fingerprintIssue)
                }
            case let .issue(issue):
                issues.append(issue)
            }
        }

        scannedPages.sort {
            sourceItemOrder(
                lhsName: $0.page.originalFileName,
                lhsCreationDate: $0.creationDate,
                lhsPath: $0.page.sourceRelativePath,
                rhsName: $1.page.originalFileName,
                rhsCreationDate: $1.creationDate,
                rhsPath: $1.page.sourceRelativePath
            )
        }

        if !scannedPages.isEmpty,
           !scannedPages.contains(where: { $0.page.state == .readable }) {
            appendNoReadablePagesIssue(for: sourceRelativePath)
        }

        return ScannedDirectory(
            sourceName: sourceName,
            sourceRelativePath: sourceRelativePath,
            pages: scannedPages,
            children: scannedDirectories,
            wasReadable: true,
            hadEntries: !childrenURLs.isEmpty
        )
    }

    private func fileByteCount(at fileURL: URL) throws -> Int64 {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        let byteCount = try handle.seekToEnd()

        guard byteCount <= UInt64(Int64.max) else {
            throw CocoaError(.fileReadTooLarge)
        }

        return Int64(byteCount)
    }

    private mutating func appendDirectory(
        _ directory: ScannedDirectory,
        parentCollectionID: ImportCollectionCandidate.ID?,
        siblingIndex: Int
    ) -> Bool {
        let validChildren = directory.children.filter {
            hasReadableChapter($0)
        }
        let hasReadableDirectPages = directory.pages.contains {
            $0.page.state == .readable
        }

        if validChildren.isEmpty {
            guard hasReadableDirectPages else {
                if !directory.pages.isEmpty {
                    appendNoReadablePagesIssue(for: directory.sourceRelativePath)
                }
                return false
            }

            return appendChapter(
                sourceName: directory.sourceName,
                sourceDirectoryPath: directory.sourceRelativePath,
                role: .directory,
                siblingIndex: siblingIndex,
                parentCollectionID: parentCollectionID,
                scannedPages: directory.pages
            )
        }

        let collectionID = ImportCollectionCandidate.ID.sourcePath(
            directory.sourceRelativePath
        )
        collections.append(
            ImportCollectionCandidate(
                id: collectionID,
                parentID: parentCollectionID,
                sourceRelativePath: directory.sourceRelativePath,
                originalName: directory.sourceName,
                siblingIndex: siblingIndex
            )
        )

        var childSiblingIndex = 0

        if !directory.pages.isEmpty {
            if hasReadableDirectPages {
                if appendChapter(
                    sourceName: directory.sourceName,
                    sourceDirectoryPath: directory.sourceRelativePath,
                    role: .collectionLoosePages,
                    siblingIndex: childSiblingIndex,
                    parentCollectionID: collectionID,
                    scannedPages: directory.pages
                ) {
                    childSiblingIndex += 1
                }
            } else {
                appendNoReadablePagesIssue(for: directory.sourceRelativePath)
            }
        }

        for child in directory.children {
            if appendDirectory(
                child,
                parentCollectionID: collectionID,
                siblingIndex: childSiblingIndex
            ) {
                childSiblingIndex += 1
            }
        }

        return true
    }

    @discardableResult
    private mutating func appendChapter(
        sourceName: String,
        sourceDirectoryPath: SourceRelativePath,
        role: ImportChapterRole,
        siblingIndex: Int,
        parentCollectionID: ImportCollectionCandidate.ID?,
        scannedPages: [ScannedPage]
    ) -> Bool {
        guard !scannedPages.isEmpty else {
            return false
        }

        guard scannedPages.contains(where: { $0.page.state == .readable }) else {
            appendNoReadablePagesIssue(for: sourceDirectoryPath)
            return false
        }

        let chapterID = ImportChapterCandidate.ID.sourcePath(
            sourceDirectoryPath,
            role: role
        )
        appendSuspectedDuplicateIssues(in: scannedPages)
        let indexedPages = scannedPages.enumerated().map { index, scannedPage in
            scannedPage.page.withPageIndex(index)
        }

        pages.append(contentsOf: indexedPages)
        chapters.append(
            ImportChapterCandidate(
                id: chapterID,
                parentCollectionID: parentCollectionID,
                sourceDirectoryPath: sourceDirectoryPath,
                originalName: sourceName,
                role: role,
                siblingIndex: siblingIndex,
                pageIDs: indexedPages.map(\.id)
            )
        )
        return true
    }

    private mutating func appendSuspectedDuplicateIssues(
        in scannedPages: [ScannedPage]
    ) {
        var pathsByFingerprint: [String: [SourceRelativePath]] = [:]

        for scannedPage in scannedPages
        where scannedPage.page.state == .readable {
            guard let fingerprint = scannedPage.page.lightweightFingerprint else {
                continue
            }

            pathsByFingerprint[fingerprint, default: []].append(
                scannedPage.page.sourceRelativePath
            )
        }

        for paths in pathsByFingerprint.values where paths.count > 1 {
            issues.append(
                ImportIssue(
                    code: .suspectedDuplicate,
                    severity: .information,
                    sourceRelativePaths: paths
                )
            )
        }
    }

    private func hasReadableChapter(_ directory: ScannedDirectory) -> Bool {
        directory.pages.contains { $0.page.state == .readable }
            || directory.children.contains { hasReadableChapter($0) }
    }

    private mutating func appendNoReadablePagesIssue(
        for path: SourceRelativePath
    ) {
        guard !issues.contains(where: {
            $0.code == .chapterHasNoReadablePages
                && $0.sourceRelativePaths == [path]
        }) else {
            return
        }

        issues.append(
            ImportIssue(
                code: .chapterHasNoReadablePages,
                severity: .warning,
                sourceRelativePaths: [path]
            )
        )
    }

    private func selectCover(in root: ScannedDirectory) -> CoverSelection {
        let readableRootPages = root.pages.filter {
            $0.page.state == .readable
        }
        let explicitCandidates = readableRootPages.compactMap { scannedPage -> (
            rank: Int,
            page: ScannedPage
        )? in
            guard let rank = Self.coverRank(
                for: baseName(of: scannedPage.page.originalFileName)
            ) else {
                return nil
            }
            return (rank, scannedPage)
        }
        let explicitCover = explicitCandidates.min { lhs, rhs in
            if lhs.rank != rhs.rank {
                return lhs.rank < rhs.rank
            }
            return sourceItemOrder(
                lhsName: lhs.page.page.originalFileName,
                lhsCreationDate: lhs.page.creationDate,
                lhsPath: lhs.page.page.sourceRelativePath,
                rhsName: rhs.page.page.originalFileName,
                rhsCreationDate: rhs.page.creationDate,
                rhsPath: rhs.page.page.sourceRelativePath
            )
        }?.page
        let rootCover = explicitCover ?? readableRootPages.first

        if let rootCover {
            return CoverSelection(
                page: rootCover.page,
                excludedRootPageID: rootCover.page.id
            )
        }

        return CoverSelection(
            page: firstReadablePage(in: root),
            excludedRootPageID: nil
        )
    }

    private func firstReadablePage(
        in directory: ScannedDirectory
    ) -> ImportPageCandidate? {
        if let page = directory.pages.first(where: {
            $0.page.state == .readable
        }) {
            return page.page
        }

        for child in directory.children {
            if let page = firstReadablePage(in: child) {
                return page
            }
        }

        return nil
    }

    private func sourceItemOrder(
        lhsName: String,
        lhsCreationDate: Date?,
        lhsPath: SourceRelativePath,
        rhsName: String,
        rhsCreationDate: Date?,
        rhsPath: SourceRelativePath
    ) -> Bool {
        let lhs = NamedSourceItem(
            name: lhsName,
            creationDate: lhsCreationDate
        )
        let rhs = NamedSourceItem(
            name: rhsName,
            creationDate: rhsCreationDate
        )

        if NaturalFileOrder.areEquivalent(lhs, rhs, locale: locale) {
            return lhsPath.identifierComponent <
                rhsPath.identifierComponent
        }

        return NaturalFileOrder.areInIncreasingOrder(
            lhs,
            rhs,
            locale: locale
        )
    }

    private func issueOrder(_ lhs: ImportIssue, _ rhs: ImportIssue) -> Bool {
        let lhsPath = lhs.sourceRelativePaths.first?.stringValue ?? ""
        let rhsPath = rhs.sourceRelativePaths.first?.stringValue ?? ""
        let lhsItem = NamedSourceItem(name: lhsPath, creationDate: nil)
        let rhsItem = NamedSourceItem(name: rhsPath, creationDate: nil)

        if NaturalFileOrder.areEquivalent(lhsItem, rhsItem, locale: locale) {
            return lhs.code.rawValue < rhs.code.rawValue
        }

        return NaturalFileOrder.areInIncreasingOrder(
            lhsItem,
            rhsItem,
            locale: locale
        )
    }

    private func baseName(of fileName: String) -> String {
        (fileName as NSString)
            .deletingPathExtension
            .precomposedStringWithCanonicalMapping
            .folding(
                options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                locale: locale
            )
            .lowercased(with: locale)
    }

    private static func coverRank(for baseName: String) -> Int? {
        switch baseName {
        case "cover":
            0
        case "folder":
            1
        case "封面":
            2
        default:
            nil
        }
    }

    private static let resourceKeys: Set<URLResourceKey> = [
        .isDirectoryKey,
        .isRegularFileKey,
        .isSymbolicLinkKey,
        .isAliasFileKey,
        .isHiddenKey,
        .creationDateKey,
    ]

    private static let systemItemNames: Set<String> = [
        ".ds_store",
        "thumbs.db",
        "desktop.ini",
        "__macosx",
    ]

    private static func isSystemItem(_ name: String) -> Bool {
        let lowercaseName = name.lowercased()
        return systemItemNames.contains(lowercaseName)
            || lowercaseName.hasPrefix("._")
    }
}

private struct SourceEntry {
    let url: URL
    let name: String
    let sourceRelativePath: SourceRelativePath
    let values: URLResourceValues
}

private struct ScannedDirectory {
    let sourceName: String
    let sourceRelativePath: SourceRelativePath
    let pages: [ScannedPage]
    let children: [ScannedDirectory]
    let wasReadable: Bool
    let hadEntries: Bool
}

private struct ScannedPage {
    let page: ImportPageCandidate
    let creationDate: Date?
}

private struct ScannedFile {
    let result: ImageContentProbe.Result
    let fingerprint: String?
    let fingerprintIssue: ImportIssue?
}

private struct CoverSelection {
    let page: ImportPageCandidate?
    let excludedRootPageID: ImportPageCandidate.ID?
}

private extension ImportPageCandidate {
    func withPageIndex(_ pageIndex: Int?) -> Self {
        Self(
            id: id,
            sourceRelativePath: sourceRelativePath,
            originalFileName: originalFileName,
            detectedFormat: detectedFormat,
            byteCount: byteCount,
            pixelSize: pixelSize,
            orientation: orientation,
            lightweightFingerprint: lightweightFingerprint,
            state: state,
            pageIndex: pageIndex
        )
    }

    func withLightweightFingerprint(_ fingerprint: String?) -> Self {
        Self(
            id: id,
            sourceRelativePath: sourceRelativePath,
            originalFileName: originalFileName,
            detectedFormat: detectedFormat,
            byteCount: byteCount,
            pixelSize: pixelSize,
            orientation: orientation,
            lightweightFingerprint: fingerprint,
            state: state,
            pageIndex: pageIndex
        )
    }
}
