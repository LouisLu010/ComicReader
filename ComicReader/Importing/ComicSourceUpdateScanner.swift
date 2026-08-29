import Foundation

/// 一次同来源更新扫描的结果：重新扫描得到的导入清单，
/// 以及它与已入库描述符之间的增量更新差异。
struct ComicSourceUpdateScan: Equatable, Sendable {
    let descriptor: ManagedComicDescriptor
    let freshManifest: ImportManifest
    let diff: ImportUpdateDiff
}

enum ComicSourceUpdateScanError: Error, Equatable, Sendable {
    /// 授权与目标漫画不匹配，或书签无法解析。
    case authorizationInvalid
    /// 书签已过期，需要用户重新授权来源目录。
    case staleAuthorization
    case accessDenied
    case scanFailed(ImportScanError)
}

/// 用保存的来源授权重新扫描同一来源目录，并基于已入库
/// 描述符计算增量更新差异。书签身份即来源身份；来源根目录
/// 被用户重命名不影响相对路径匹配。
struct ComicSourceUpdateScanner: Sendable {
    private let sourceAccess: any ImportSourceAccessing
    private let importScanner: any ImportScanning

    init(
        sourceAccess: any ImportSourceAccessing = SecurityScopedSourceAccess(),
        importScanner: any ImportScanning = ImportScanner()
    ) {
        self.sourceAccess = sourceAccess
        self.importScanner = importScanner
    }

    func scan(
        descriptor: ManagedComicDescriptor,
        authorization: ComicSourceAuthorization
    ) async throws -> ComicSourceUpdateScan {
        guard authorization.comicID == descriptor.targetComicID else {
            throw ComicSourceUpdateScanError.authorizationInvalid
        }

        let sourceURL: URL
        do {
            sourceURL = try sourceAccess.resolveBookmark(
                authorization.bookmark
            )
        } catch let error as ImportSourceAccessError {
            throw ComicSourceUpdateScanError(error)
        }

        do {
            try sourceAccess.startAccessing(sourceURL)
            defer { sourceAccess.stopAccessing(sourceURL) }

            let manifest = try await importScanner.scan(
                ImportScanRequest(
                    rootURL: sourceURL,
                    locale: Locale(
                        identifier: descriptor.sortLocaleIdentifier
                    )
                )
            )
            let diff = ImportUpdateDiffCalculator.make(
                storedChapters: descriptor.chapters,
                storedWorkItems: descriptor.workItems,
                freshManifest: manifest
            )
            return ComicSourceUpdateScan(
                descriptor: descriptor,
                freshManifest: manifest,
                diff: diff
            )
        } catch let error as ImportScanError {
            throw ComicSourceUpdateScanError.scanFailed(error)
        } catch let error as ImportSourceAccessError {
            throw ComicSourceUpdateScanError(error)
        }
    }
}

private extension ComicSourceUpdateScanError {
    init(_ sourceAccessError: ImportSourceAccessError) {
        switch sourceAccessError {
        case .staleBookmark:
            self = .staleAuthorization
        case .invalidBookmark:
            self = .authorizationInvalid
        case .accessDenied:
            self = .accessDenied
        }
    }
}
