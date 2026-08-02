import Foundation

enum ReaderPagePrefetchPlanner {
    static func adjacentLocations(
        in layout: ReaderLayout,
        around location: ReaderPageLocation,
        distance: Int = 1
    ) -> [ReaderPageLocation] {
        guard distance > 0,
              let presentationIndex = layout.presentationIndex(
                for: location
              ) else {
            return []
        }

        let visibleLocations = Set(
            layout.presentations[presentationIndex].locations
        )
        let orderedLocations = layout.presentations.flatMap(\.locations)
        let visibleIndices = orderedLocations.indices.filter {
            visibleLocations.contains(orderedLocations[$0])
        }

        guard let firstVisibleIndex = visibleIndices.first,
              let lastVisibleIndex = visibleIndices.last else {
            return []
        }

        let boundedDistance = min(distance, orderedLocations.count)
        var result: [ReaderPageLocation] = []

        for offset in 1...boundedDistance {
            let nextIndex = lastVisibleIndex + offset
            if orderedLocations.indices.contains(nextIndex) {
                result.append(orderedLocations[nextIndex])
            }

            let previousIndex = firstVisibleIndex - offset
            if orderedLocations.indices.contains(previousIndex) {
                result.append(orderedLocations[previousIndex])
            }
        }

        return result
    }
}

actor ReaderImagePipeline {
    static let defaultCacheCostLimit = 96 * 1_024 * 1_024
    static let defaultMaximumConcurrentDecodes = 2

    private typealias ImageContinuation = CheckedContinuation<
        ReaderDecodedImage,
        any Error
    >

    private struct CacheKey: Hashable, Sendable {
        let identity: ReaderPageAssetIdentity
        let target: ReaderImageTarget
    }

    private struct CacheEntry {
        let image: ReaderDecodedImage
        var lastAccess: UInt64
    }

    private enum JobState: Equatable {
        case queued
        case running
    }

    private struct DecodeJob {
        let token: UUID
        let key: CacheKey
        let request: ReaderImageDecodeRequest
        var priority: TaskPriority
        var cacheGeneration: UInt64
        var state: JobState
        var waiters: [UUID: ImageContinuation]
    }

    private struct RunningDecode {
        let key: CacheKey
        let task: Task<Void, Never>
    }

    private let decoder: any ReaderImageDecoding
    private let cacheCostLimit: Int
    private let maximumConcurrentDecodes: Int

    private var cache: [CacheKey: CacheEntry] = [:]
    private var cacheCost = 0
    private var accessCounter: UInt64 = 0
    private var cacheGeneration: UInt64 = 0
    private var jobs: [CacheKey: DecodeJob] = [:]
    private var queuedKeys: [CacheKey] = []
    private var runningDecodes: [UUID: RunningDecode] = [:]

    init(
        decoder: any ReaderImageDecoding = ImageIOReaderImageDecoder(),
        cacheCostLimit: Int = ReaderImagePipeline.defaultCacheCostLimit,
        maximumConcurrentDecodes: Int = ReaderImagePipeline
            .defaultMaximumConcurrentDecodes
    ) {
        self.decoder = decoder
        self.cacheCostLimit = max(0, cacheCostLimit)
        self.maximumConcurrentDecodes = max(
            1,
            maximumConcurrentDecodes
        )
    }

    func image(
        for asset: ReaderPageAsset,
        target: ReaderImageTarget,
        priority: TaskPriority = .userInitiated
    ) async throws -> ReaderDecodedImage {
        try Task.checkCancellation()

        let key = CacheKey(
            identity: asset.identity,
            target: target
        )
        if let cachedImage = cachedImage(for: key) {
            return cachedImage
        }

        try Task.checkCancellation()
        let waiterID = UUID()
        let request = ReaderImageDecodeRequest(
            asset: asset,
            target: target
        )

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }

                enqueue(
                    request: request,
                    key: key,
                    priority: priority,
                    waiterID: waiterID,
                    continuation: continuation
                )
            }
        } onCancel: {
            Task {
                await self.cancelWaiter(
                    waiterID,
                    for: key
                )
            }
        }
    }

    func prefetch(
        _ assets: [ReaderPageAsset],
        target: ReaderImageTarget
    ) async {
        await withTaskGroup(of: Void.self) { group in
            for asset in assets where !Task.isCancelled {
                group.addTask {
                    _ = try? await self.image(
                        for: asset,
                        target: target,
                        priority: .utility
                    )
                }
            }
        }
    }

    /// 清空当前缓存代次。已开始的旧解码仍可返回给等待者，但不能回填缓存。
    func removeAllCachedImages() {
        cacheGeneration &+= 1
        cache.removeAll(keepingCapacity: true)
        cacheCost = 0
    }

    /// 内存告警时仅保留可见页，并取消不再可见的排队或执行中请求。
    func handleMemoryWarning(
        keepingVisibleAssets visibleAssets: Set<ReaderPageAssetIdentity>
    ) {
        cacheGeneration &+= 1

        for key in Array(cache.keys)
            where !visibleAssets.contains(key.identity) {
            removeCachedImage(for: key)
        }

        for key in Array(jobs.keys) {
            guard var job = jobs[key] else {
                continue
            }

            if visibleAssets.contains(key.identity) {
                job.cacheGeneration = cacheGeneration
                jobs[key] = job
                continue
            }

            jobs.removeValue(forKey: key)
            queuedKeys.removeAll { $0 == key }
            runningDecodes[job.token]?.task.cancel()

            for continuation in job.waiters.values {
                continuation.resume(throwing: CancellationError())
            }
        }

        startQueuedJobsIfPossible()
    }

    private func enqueue(
        request: ReaderImageDecodeRequest,
        key: CacheKey,
        priority: TaskPriority,
        waiterID: UUID,
        continuation: ImageContinuation
    ) {
        if var job = jobs[key] {
            job.waiters[waiterID] = continuation
            if priority.rawValue > job.priority.rawValue,
               job.state == .queued {
                job.priority = priority
            }
            jobs[key] = job
            return
        }

        let job = DecodeJob(
            token: UUID(),
            key: key,
            request: request,
            priority: priority,
            cacheGeneration: cacheGeneration,
            state: .queued,
            waiters: [waiterID: continuation]
        )
        jobs[key] = job
        queuedKeys.append(key)
        startQueuedJobsIfPossible()
    }

    private func cancelWaiter(
        _ waiterID: UUID,
        for key: CacheKey
    ) {
        guard var job = jobs[key],
              let continuation = job.waiters.removeValue(
                forKey: waiterID
              ) else {
            return
        }

        continuation.resume(throwing: CancellationError())

        guard job.waiters.isEmpty else {
            jobs[key] = job
            return
        }

        jobs.removeValue(forKey: key)
        queuedKeys.removeAll { $0 == key }
        runningDecodes[job.token]?.task.cancel()
        startQueuedJobsIfPossible()
    }

    private func startQueuedJobsIfPossible() {
        while runningDecodes.count < maximumConcurrentDecodes,
              let queueIndex = nextQueuedJobIndex() {
            let key = queuedKeys.remove(at: queueIndex)
            guard var job = jobs[key], job.state == .queued else {
                continue
            }

            job.state = .running
            jobs[key] = job

            let decoder = self.decoder
            let request = job.request
            let token = job.token
            let priority = job.priority
            let task = Task.detached(priority: priority) { [weak self] in
                do {
                    let image = try await decoder.decode(request)
                    await self?.decodeFinished(
                        key: key,
                        token: token,
                        result: .success(image)
                    )
                } catch {
                    await self?.decodeFinished(
                        key: key,
                        token: token,
                        result: .failure(error)
                    )
                }
            }

            runningDecodes[token] = RunningDecode(
                key: key,
                task: task
            )
        }
    }

    private func nextQueuedJobIndex() -> Int? {
        var selectedIndex: Int?
        var selectedPriority: UInt8 = 0

        for index in queuedKeys.indices {
            guard let job = jobs[queuedKeys[index]],
                  job.state == .queued else {
                continue
            }

            if selectedIndex == nil
                || job.priority.rawValue > selectedPriority {
                selectedIndex = index
                selectedPriority = job.priority.rawValue
            }
        }

        if selectedIndex == nil, !queuedKeys.isEmpty {
            queuedKeys.removeAll { jobs[$0]?.state != .queued }
            return nextQueuedJobIndex()
        }

        return selectedIndex
    }

    private func decodeFinished(
        key: CacheKey,
        token: UUID,
        result: Result<ReaderDecodedImage, any Error>
    ) {
        guard let runningDecode = runningDecodes.removeValue(
            forKey: token
        ), runningDecode.key == key else {
            return
        }

        if let job = jobs[key], job.token == token {
            jobs.removeValue(forKey: key)

            switch result {
            case let .success(image):
                if job.cacheGeneration == cacheGeneration {
                    insert(image, for: key)
                }

                for continuation in job.waiters.values {
                    continuation.resume(returning: image)
                }
            case let .failure(error):
                for continuation in job.waiters.values {
                    continuation.resume(throwing: error)
                }
            }
        }

        startQueuedJobsIfPossible()
    }

    private func cachedImage(
        for key: CacheKey
    ) -> ReaderDecodedImage? {
        guard var entry = cache[key] else {
            return nil
        }

        accessCounter &+= 1
        entry.lastAccess = accessCounter
        cache[key] = entry
        return entry.image
    }

    private func insert(
        _ image: ReaderDecodedImage,
        for key: CacheKey
    ) {
        let cost = image.estimatedByteCount
        guard cacheCostLimit > 0, cost <= cacheCostLimit else {
            return
        }

        removeCachedImage(for: key)

        while cacheCost > cacheCostLimit - cost,
              let leastRecentlyUsedKey = cache.min(
                by: { $0.value.lastAccess < $1.value.lastAccess }
              )?.key {
            removeCachedImage(for: leastRecentlyUsedKey)
        }

        accessCounter &+= 1
        cache[key] = CacheEntry(
            image: image,
            lastAccess: accessCounter
        )
        cacheCost += cost
    }

    private func removeCachedImage(
        for key: CacheKey
    ) {
        guard let entry = cache.removeValue(forKey: key) else {
            return
        }

        cacheCost = max(0, cacheCost - entry.image.estimatedByteCount)
    }
}
