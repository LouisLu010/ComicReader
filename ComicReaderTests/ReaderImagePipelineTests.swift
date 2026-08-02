import CoreGraphics
import Foundation
import XCTest
@testable import ComicReader

final class ReaderImagePipelineTests: XCTestCase {
    func testSuccessfulDecodeIsCached() async throws {
        let decoder = GatedReaderImageDecoder()
        let pipeline = ReaderImagePipeline(decoder: decoder)
        let asset = makeAsset(pageID: "page-1")
        let target = try makeTarget(1_024)

        let firstImage = try await completeCacheMiss(
            asset: asset,
            target: target,
            pipeline: pipeline,
            decoder: decoder,
            expectedCallCount: 1,
            cost: 24
        )
        let secondImage = try await pipeline.image(
            for: asset,
            target: target
        )

        XCTAssertEqual(firstImage.estimatedByteCount, 24)
        XCTAssertEqual(secondImage.estimatedByteCount, 24)
        let callCount = await decoder.callCount
        XCTAssertEqual(callCount, 1)
    }

    func testConcurrentRequestsForSameKeyShareDecode() async throws {
        let decoder = GatedReaderImageDecoder()
        let pipeline = ReaderImagePipeline(decoder: decoder)
        let asset = makeAsset(pageID: "shared-page")
        let target = try makeTarget(1_024)

        let firstTask = Task {
            try await pipeline.image(for: asset, target: target)
        }
        let secondTask = Task {
            try await pipeline.image(for: asset, target: target)
        }

        await waitForCallCount(1, decoder: decoder)
        await drainScheduler()
        let sharedCallCount = await decoder.callCount
        XCTAssertEqual(sharedCallCount, 1)
        await resumeSuccessfully(call: 0, cost: 32, decoder: decoder)

        let firstImage = try await firstTask.value
        let secondImage = try await secondTask.value
        XCTAssertEqual(firstImage.estimatedByteCount, 32)
        XCTAssertEqual(secondImage.estimatedByteCount, 32)
        let finalCallCount = await decoder.callCount
        XCTAssertEqual(finalCallCount, 1)
    }

    func testCacheKeyIncludesTargetComicAndRevision() async throws {
        let decoder = GatedReaderImageDecoder()
        let pipeline = ReaderImagePipeline(decoder: decoder)
        let baseAsset = makeAsset(pageID: "same-page")
        let differentComic = makeAsset(
            pageID: "same-page",
            comicNumber: 2
        )
        let differentRevision = makeAsset(
            pageID: "same-page",
            revision: "revision-2"
        )
        let smallTarget = try makeTarget(1_024)
        let largeTarget = try makeTarget(2_048)

        _ = try await completeCacheMiss(
            asset: baseAsset,
            target: smallTarget,
            pipeline: pipeline,
            decoder: decoder,
            expectedCallCount: 1,
            cost: 10
        )
        _ = try await completeCacheMiss(
            asset: baseAsset,
            target: largeTarget,
            pipeline: pipeline,
            decoder: decoder,
            expectedCallCount: 2,
            cost: 20
        )
        _ = try await completeCacheMiss(
            asset: differentComic,
            target: smallTarget,
            pipeline: pipeline,
            decoder: decoder,
            expectedCallCount: 3,
            cost: 30
        )
        _ = try await completeCacheMiss(
            asset: differentRevision,
            target: smallTarget,
            pipeline: pipeline,
            decoder: decoder,
            expectedCallCount: 4,
            cost: 40
        )

        let baseImage = try await pipeline.image(
            for: baseAsset,
            target: smallTarget
        )
        let largeImage = try await pipeline.image(
            for: baseAsset,
            target: largeTarget
        )
        let otherComicImage = try await pipeline.image(
            for: differentComic,
            target: smallTarget
        )
        let otherRevisionImage = try await pipeline.image(
            for: differentRevision,
            target: smallTarget
        )

        XCTAssertEqual(baseImage.estimatedByteCount, 10)
        XCTAssertEqual(largeImage.estimatedByteCount, 20)
        XCTAssertEqual(otherComicImage.estimatedByteCount, 30)
        XCTAssertEqual(otherRevisionImage.estimatedByteCount, 40)
        let callCount = await decoder.callCount
        let uniqueCalls = Set(await decoder.recordedCalls)
        XCTAssertEqual(callCount, 4)
        XCTAssertEqual(uniqueCalls.count, 4)
    }

    func testFailureIsNotCachedAndNextRequestRetries() async throws {
        let decoder = GatedReaderImageDecoder()
        let pipeline = ReaderImagePipeline(decoder: decoder)
        let asset = makeAsset(pageID: "retry-page")
        let target = try makeTarget(1_024)

        let failingTask = Task {
            try await pipeline.image(for: asset, target: target)
        }
        await waitForCallCount(1, decoder: decoder)
        await fail(call: 0, decoder: decoder)

        do {
            _ = try await failingTask.value
            XCTFail("Expected the first decode to fail.")
        } catch {
            XCTAssertEqual(error as? StubDecodeError, .forced)
        }

        let retriedImage = try await completeCacheMiss(
            asset: asset,
            target: target,
            pipeline: pipeline,
            decoder: decoder,
            expectedCallCount: 2,
            cost: 48
        )
        let cachedImage = try await pipeline.image(
            for: asset,
            target: target
        )

        XCTAssertEqual(retriedImage.estimatedByteCount, 48)
        XCTAssertEqual(cachedImage.estimatedByteCount, 48)
        let callCount = await decoder.callCount
        XCTAssertEqual(callCount, 2)
    }

    func testCancellingOneWaiterDoesNotCancelSharedDecode() async throws {
        let decoder = GatedReaderImageDecoder()
        let pipeline = ReaderImagePipeline(decoder: decoder)
        let asset = makeAsset(pageID: "shared-cancellation-page")
        let target = try makeTarget(1_024)

        let firstTask = Task {
            try await pipeline.image(for: asset, target: target)
        }
        await waitForCallCount(1, decoder: decoder)

        let secondTask = Task {
            try await pipeline.image(for: asset, target: target)
        }
        await drainScheduler()
        firstTask.cancel()
        await assertCancellation(of: firstTask)
        await drainScheduler()

        let callCountBeforeResume = await decoder.callCount
        let cancelledCalls = await decoder.cancelledCallIndices
        XCTAssertEqual(callCountBeforeResume, 1)
        XCTAssertTrue(cancelledCalls.isEmpty)
        await resumeSuccessfully(call: 0, cost: 56, decoder: decoder)

        let secondImage = try await secondTask.value
        XCTAssertEqual(secondImage.estimatedByteCount, 56)
        let finalCallCount = await decoder.callCount
        XCTAssertEqual(finalCallCount, 1)
    }

    func testMaximumConcurrentDecodeLimitIsEnforced() async throws {
        let decoder = GatedReaderImageDecoder()
        let pipeline = ReaderImagePipeline(
            decoder: decoder,
            maximumConcurrentDecodes: 2
        )
        let target = try makeTarget(1_024)
        let assets = (1...4).map {
            makeAsset(pageID: "concurrent-page-\($0)")
        }
        let tasks = assets.map { asset in
            Task {
                try await pipeline.image(for: asset, target: target)
            }
        }

        await waitForCallCount(2, decoder: decoder)
        await drainScheduler()
        let initialCallCount = await decoder.callCount
        let initialActiveCount = await decoder.activeCount
        let initialPeakActiveCount = await decoder.peakActiveCount
        XCTAssertEqual(initialCallCount, 2)
        XCTAssertEqual(initialActiveCount, 2)
        XCTAssertEqual(initialPeakActiveCount, 2)

        await resumeSuccessfully(call: 0, cost: 8, decoder: decoder)
        await waitForCallCount(3, decoder: decoder)
        let peakAfterThirdCall = await decoder.peakActiveCount
        XCTAssertEqual(peakAfterThirdCall, 2)

        await resumeSuccessfully(call: 1, cost: 8, decoder: decoder)
        await waitForCallCount(4, decoder: decoder)
        let peakAfterFourthCall = await decoder.peakActiveCount
        XCTAssertEqual(peakAfterFourthCall, 2)

        await resumeSuccessfully(call: 2, cost: 8, decoder: decoder)
        await resumeSuccessfully(call: 3, cost: 8, decoder: decoder)
        for task in tasks {
            _ = try await task.value
        }

        let finalCallCount = await decoder.callCount
        let finalPeakActiveCount = await decoder.peakActiveCount
        XCTAssertEqual(finalCallCount, 4)
        XCTAssertEqual(finalPeakActiveCount, 2)
    }

    func testCacheEvictsLeastRecentlyUsedImage() async throws {
        let decoder = GatedReaderImageDecoder()
        let pipeline = ReaderImagePipeline(
            decoder: decoder,
            cacheCostLimit: 20
        )
        let target = try makeTarget(1_024)
        let firstAsset = makeAsset(pageID: "lru-first")
        let secondAsset = makeAsset(pageID: "lru-second")
        let thirdAsset = makeAsset(pageID: "lru-third")

        _ = try await completeCacheMiss(
            asset: firstAsset,
            target: target,
            pipeline: pipeline,
            decoder: decoder,
            expectedCallCount: 1,
            cost: 10
        )
        _ = try await completeCacheMiss(
            asset: secondAsset,
            target: target,
            pipeline: pipeline,
            decoder: decoder,
            expectedCallCount: 2,
            cost: 10
        )

        _ = try await pipeline.image(for: firstAsset, target: target)
        _ = try await completeCacheMiss(
            asset: thirdAsset,
            target: target,
            pipeline: pipeline,
            decoder: decoder,
            expectedCallCount: 3,
            cost: 10
        )

        _ = try await pipeline.image(for: firstAsset, target: target)
        let callCountBeforeReload = await decoder.callCount
        XCTAssertEqual(callCountBeforeReload, 3)

        _ = try await completeCacheMiss(
            asset: secondAsset,
            target: target,
            pipeline: pipeline,
            decoder: decoder,
            expectedCallCount: 4,
            cost: 10
        )
        let finalCallCount = await decoder.callCount
        XCTAssertEqual(finalCallCount, 4)
    }

    func testImageLargerThanBudgetIsNotCached() async throws {
        let decoder = GatedReaderImageDecoder()
        let pipeline = ReaderImagePipeline(
            decoder: decoder,
            cacheCostLimit: 9
        )
        let asset = makeAsset(pageID: "oversized-page")
        let target = try makeTarget(1_024)

        _ = try await completeCacheMiss(
            asset: asset,
            target: target,
            pipeline: pipeline,
            decoder: decoder,
            expectedCallCount: 1,
            cost: 10
        )
        _ = try await completeCacheMiss(
            asset: asset,
            target: target,
            pipeline: pipeline,
            decoder: decoder,
            expectedCallCount: 2,
            cost: 10
        )

        let callCount = await decoder.callCount
        XCTAssertEqual(callCount, 2)
    }

    func testRemovingCacheDuringDecodePreventsStaleRefill() async throws {
        let decoder = GatedReaderImageDecoder()
        let pipeline = ReaderImagePipeline(decoder: decoder)
        let asset = makeAsset(pageID: "generation-page")
        let target = try makeTarget(1_024)

        let firstTask = Task {
            try await pipeline.image(for: asset, target: target)
        }
        await waitForCallCount(1, decoder: decoder)
        await pipeline.removeAllCachedImages()
        await resumeSuccessfully(call: 0, cost: 64, decoder: decoder)
        let firstImage = try await firstTask.value
        XCTAssertEqual(firstImage.estimatedByteCount, 64)

        _ = try await completeCacheMiss(
            asset: asset,
            target: target,
            pipeline: pipeline,
            decoder: decoder,
            expectedCallCount: 2,
            cost: 72
        )
        let callCount = await decoder.callCount
        XCTAssertEqual(callCount, 2)
    }

    func testMemoryWarningKeepsVisibleIdentityAndCancelsNonvisibleWork() async throws {
        let decoder = GatedReaderImageDecoder()
        let pipeline = ReaderImagePipeline(
            decoder: decoder,
            maximumConcurrentDecodes: 2
        )
        let target = try makeTarget(1_024)
        let visibleCachedAsset = makeAsset(pageID: "same-page")
        let nonvisibleCachedAsset = makeAsset(
            pageID: "same-page",
            comicNumber: 2
        )
        let visibleRunningAsset = makeAsset(pageID: "visible-running")
        let nonvisibleRunningAsset = makeAsset(pageID: "nonvisible-running")

        _ = try await completeCacheMiss(
            asset: visibleCachedAsset,
            target: target,
            pipeline: pipeline,
            decoder: decoder,
            expectedCallCount: 1,
            cost: 10
        )
        _ = try await completeCacheMiss(
            asset: nonvisibleCachedAsset,
            target: target,
            pipeline: pipeline,
            decoder: decoder,
            expectedCallCount: 2,
            cost: 10
        )

        let visibleTask = Task {
            try await pipeline.image(
                for: visibleRunningAsset,
                target: target
            )
        }
        let nonvisibleTask = Task {
            try await pipeline.image(
                for: nonvisibleRunningAsset,
                target: target
            )
        }
        await waitForCallCount(4, decoder: decoder)

        let visibleIndexValue = await decoder.firstCallIndex(
            for: visibleRunningAsset.identity
        )
        let nonvisibleIndexValue = await decoder.firstCallIndex(
            for: nonvisibleRunningAsset.identity
        )
        let visibleIndex = try XCTUnwrap(visibleIndexValue)
        let nonvisibleIndex = try XCTUnwrap(nonvisibleIndexValue)

        await pipeline.handleMemoryWarning(
            keepingVisibleAssets: [
                visibleCachedAsset.identity,
                visibleRunningAsset.identity,
            ]
        )

        await assertCancellation(of: nonvisibleTask)
        await waitForCancelledCall(
            nonvisibleIndex,
            decoder: decoder
        )
        await resumeSuccessfully(
            call: visibleIndex,
            cost: 20,
            decoder: decoder
        )
        let visibleImage = try await visibleTask.value
        XCTAssertEqual(visibleImage.estimatedByteCount, 20)

        _ = try await pipeline.image(
            for: visibleCachedAsset,
            target: target
        )
        _ = try await pipeline.image(
            for: visibleRunningAsset,
            target: target
        )
        let callCountAfterVisibleHits = await decoder.callCount
        XCTAssertEqual(callCountAfterVisibleHits, 4)

        _ = try await completeCacheMiss(
            asset: nonvisibleCachedAsset,
            target: target,
            pipeline: pipeline,
            decoder: decoder,
            expectedCallCount: 5,
            cost: 30
        )
        let finalCallCount = await decoder.callCount
        XCTAssertEqual(finalCallCount, 5)
    }

    func testPrefetchIsolatesFailuresAndCachesSuccessfulImages() async throws {
        let decoder = GatedReaderImageDecoder()
        let pipeline = ReaderImagePipeline(
            decoder: decoder,
            maximumConcurrentDecodes: 2
        )
        let target = try makeTarget(1_024)
        let failingAsset = makeAsset(pageID: "prefetch-failure")
        let successfulAsset = makeAsset(pageID: "prefetch-success")

        let prefetchTask = Task {
            await pipeline.prefetch(
                [failingAsset, successfulAsset],
                target: target
            )
        }
        await waitForCallCount(2, decoder: decoder)

        let failingIndexValue = await decoder.firstCallIndex(
            for: failingAsset.identity
        )
        let successfulIndexValue = await decoder.firstCallIndex(
            for: successfulAsset.identity
        )
        let failingIndex = try XCTUnwrap(failingIndexValue)
        let successfulIndex = try XCTUnwrap(successfulIndexValue)
        await fail(call: failingIndex, decoder: decoder)
        await resumeSuccessfully(
            call: successfulIndex,
            cost: 44,
            decoder: decoder
        )
        await prefetchTask.value

        let cachedImage = try await pipeline.image(
            for: successfulAsset,
            target: target
        )
        XCTAssertEqual(cachedImage.estimatedByteCount, 44)
        let callCountAfterCacheHit = await decoder.callCount
        XCTAssertEqual(callCountAfterCacheHit, 2)

        _ = try await completeCacheMiss(
            asset: failingAsset,
            target: target,
            pipeline: pipeline,
            decoder: decoder,
            expectedCallCount: 3,
            cost: 52
        )
        let finalCallCount = await decoder.callCount
        XCTAssertEqual(finalCallCount, 3)
    }

    func testPrefetchPlannerIncludesCoverAndSkipsChapterBoundary() throws {
        let cover = makePage("cover", isCover: true)
        let firstPage = makePage("chapter-1-page")
        let secondPage = makePage("chapter-2-page")
        let firstChapterID = makeChapterID("chapter-1")
        let secondChapterID = makeChapterID("chapter-2")
        let layout = ReaderLayout(
            comic: makeComic(
                cover: cover,
                chapters: [
                    makeChapter(firstChapterID, pages: [firstPage]),
                    makeChapter(secondChapterID, pages: [secondPage]),
                ]
            ),
            requestedMode: .singlePage,
            direction: .leftToRight,
            capability: .spreadCapable
        )

        XCTAssertTrue(layout.presentations.contains { presentation in
            if case .chapterBoundary = presentation.content {
                return true
            }
            return false
        })
        XCTAssertEqual(
            ReaderPagePrefetchPlanner.adjacentLocations(
                in: layout,
                around: .chapter(firstChapterID, firstPage.id)
            ),
            [
                .chapter(secondChapterID, secondPage.id),
                .cover(cover.id),
            ]
        )
        XCTAssertEqual(
            ReaderPagePrefetchPlanner.adjacentLocations(
                in: layout,
                around: .cover(cover.id)
            ),
            [.chapter(firstChapterID, firstPage.id)]
        )
    }

    func testPrefetchPlannerExcludesVisibleSpreadAndIgnoresPhysicalRTLSlots() {
        let chapterID = makeChapterID("chapter-1")
        let pages = (1...6).map { makePage("spread-page-\($0)") }
        let comic = makeComic(
            chapters: [makeChapter(chapterID, pages: pages)]
        )
        let leftToRight = ReaderLayout(
            comic: comic,
            requestedMode: .spread,
            direction: .leftToRight,
            capability: .spreadCapable
        )
        let rightToLeft = ReaderLayout(
            comic: comic,
            requestedMode: .spread,
            direction: .rightToLeft,
            capability: .spreadCapable
        )
        let currentLocation = ReaderPageLocation.chapter(
            chapterID,
            pages[2].id
        )
        let expectedLocations: [ReaderPageLocation] = [
            .chapter(chapterID, pages[4].id),
            .chapter(chapterID, pages[1].id),
        ]

        XCTAssertEqual(
            ReaderPagePrefetchPlanner.adjacentLocations(
                in: leftToRight,
                around: currentLocation
            ),
            expectedLocations
        )
        XCTAssertEqual(
            ReaderPagePrefetchPlanner.adjacentLocations(
                in: rightToLeft,
                around: currentLocation
            ),
            expectedLocations
        )
    }

    private func completeCacheMiss(
        asset: ReaderPageAsset,
        target: ReaderImageTarget,
        pipeline: ReaderImagePipeline,
        decoder: GatedReaderImageDecoder,
        expectedCallCount: Int,
        cost: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws -> ReaderDecodedImage {
        let task = Task {
            try await pipeline.image(for: asset, target: target)
        }
        await waitForCallCount(
            expectedCallCount,
            decoder: decoder,
            file: file,
            line: line
        )
        await resumeSuccessfully(
            call: expectedCallCount - 1,
            cost: cost,
            decoder: decoder,
            file: file,
            line: line
        )
        return try await task.value
    }

    private func resumeSuccessfully(
        call index: Int,
        cost: Int,
        decoder: GatedReaderImageDecoder,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let didResume = await decoder.succeedCall(
            at: index,
            cost: cost
        )
        XCTAssertTrue(
            didResume,
            "Expected decode call \(index) to be suspended.",
            file: file,
            line: line
        )
    }

    private func fail(
        call index: Int,
        decoder: GatedReaderImageDecoder,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let didResume = await decoder.failCall(at: index)
        XCTAssertTrue(
            didResume,
            "Expected decode call \(index) to be suspended.",
            file: file,
            line: line
        )
    }

    private func assertCancellation(
        of task: Task<ReaderDecodedImage, any Error>,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await task.value
            XCTFail(
                "Expected the image request to be cancelled.",
                file: file,
                line: line
            )
        } catch is CancellationError {
            return
        } catch {
            XCTFail(
                "Expected CancellationError, received \(error).",
                file: file,
                line: line
            )
        }
    }

    private func waitForCallCount(
        _ expectedCount: Int,
        decoder: GatedReaderImageDecoder,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<500 {
            if await decoder.callCount >= expectedCount {
                return
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }

        let actualCount = await decoder.callCount
        XCTFail(
            "Timed out waiting for \(expectedCount) decode calls; received \(actualCount).",
            file: file,
            line: line
        )
    }

    private func waitForCancelledCall(
        _ index: Int,
        decoder: GatedReaderImageDecoder,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<500 {
            if await decoder.cancelledCallIndices.contains(index) {
                return
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }

        XCTFail(
            "Timed out waiting for decode call \(index) to be cancelled.",
            file: file,
            line: line
        )
    }

    private func drainScheduler() async {
        for _ in 0..<50 {
            await Task.yield()
        }
    }

    private func makeAsset(
        pageID: String,
        comicNumber: Int = 1,
        revision: String = "revision-1"
    ) -> ReaderPageAsset {
        let pageID = ImportPageCandidate.ID(rawValue: pageID)
        return ReaderPageAsset(
            identity: ReaderPageAssetIdentity(
                comicID: makeComicID(comicNumber),
                revision: ImportPreviewRevision(rawValue: revision),
                pageID: pageID
            ),
            comicRootURL: URL(fileURLWithPath: "/unused-comic-root"),
            managedRelativePath: ManagedRelativePath(
                components: ["original", "\(pageID.rawValue).png"]
            ),
            mediaType: .png,
            expectedByteCount: 1,
            expectedPixelSize: ImportPixelSize(width: 1_200, height: 1_800),
            orientation: .up
        )
    }

    private func makeTarget(_ maximumPixelSize: Int) throws -> ReaderImageTarget {
        try ReaderImageTarget(maximumPixelSize: maximumPixelSize)
    }

    private func makeComicID(_ number: Int = 1) -> ManagedComicID {
        let suffix = String(format: "%012d", number)
        return ManagedComicID(
            rawValue: UUID(
                uuidString: "00000000-0000-0000-0000-\(suffix)"
            )!
        )
    }

    private func makeChapterID(
        _ rawValue: String
    ) -> ImportChapterCandidate.ID {
        ImportChapterCandidate.ID(rawValue: rawValue)
    }

    private func makePage(
        _ rawValue: String,
        isCover: Bool = false
    ) -> ReaderPage {
        ReaderPage(
            id: ImportPageCandidate.ID(rawValue: rawValue),
            originalFileName: "\(rawValue).png",
            displayPixelSize: ImportPixelSize(width: 1_200, height: 1_800),
            isCover: isCover
        )
    }

    private func makeChapter(
        _ id: ImportChapterCandidate.ID,
        pages: [ReaderPage]
    ) -> ReaderChapter {
        ReaderChapter(
            id: id,
            displayName: id.rawValue,
            pages: pages
        )
    }

    private func makeComic(
        cover: ReaderPage? = nil,
        chapters: [ReaderChapter]
    ) -> ReaderComic {
        ReaderComic(
            id: makeComicID(),
            displayName: "Pipeline Test Comic",
            cover: cover,
            chapters: chapters
        )
    }
}

private enum StubDecodeError: Error, Equatable, Sendable {
    case forced
}

private actor GatedReaderImageDecoder: ReaderImageDecoding {
    struct RecordedCall: Hashable, Sendable {
        let identity: ReaderPageAssetIdentity
        let target: ReaderImageTarget
    }

    private typealias DecodeContinuation = CheckedContinuation<
        ReaderDecodedImage,
        any Error
    >

    private(set) var recordedCalls: [RecordedCall] = []
    private(set) var activeCount = 0
    private(set) var peakActiveCount = 0
    private(set) var cancelledCallIndices: Set<Int> = []
    private var continuations: [Int: DecodeContinuation] = [:]
    private var cancellationsBeforeSuspension: Set<Int> = []

    var callCount: Int {
        recordedCalls.count
    }

    func decode(
        _ request: ReaderImageDecodeRequest
    ) async throws -> ReaderDecodedImage {
        let index = recordedCalls.count
        recordedCalls.append(
            RecordedCall(
                identity: request.asset.identity,
                target: request.target
            )
        )
        activeCount += 1
        peakActiveCount = max(peakActiveCount, activeCount)
        defer {
            activeCount -= 1
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if cancellationsBeforeSuspension.remove(index) != nil
                    || Task.isCancelled {
                    cancelledCallIndices.insert(index)
                    continuation.resume(throwing: CancellationError())
                } else {
                    continuations[index] = continuation
                }
            }
        } onCancel: {
            Task {
                await self.cancelCall(at: index)
            }
        }
    }

    func firstCallIndex(
        for identity: ReaderPageAssetIdentity
    ) -> Int? {
        recordedCalls.firstIndex { $0.identity == identity }
    }

    func succeedCall(
        at index: Int,
        cost: Int
    ) -> Bool {
        guard let continuation = continuations.removeValue(
            forKey: index
        ) else {
            return false
        }

        continuation.resume(
            returning: ReaderDecodedImage(
                image: Self.makeImage(),
                estimatedByteCount: cost
            )
        )
        return true
    }

    func failCall(at index: Int) -> Bool {
        guard let continuation = continuations.removeValue(
            forKey: index
        ) else {
            return false
        }

        continuation.resume(throwing: StubDecodeError.forced)
        return true
    }

    private func cancelCall(at index: Int) {
        cancelledCallIndices.insert(index)

        guard let continuation = continuations.removeValue(
            forKey: index
        ) else {
            cancellationsBeforeSuspension.insert(index)
            return
        }

        continuation.resume(throwing: CancellationError())
    }

    private static func makeImage() -> CGImage {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(
            data: nil,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        return context.makeImage()!
    }
}
