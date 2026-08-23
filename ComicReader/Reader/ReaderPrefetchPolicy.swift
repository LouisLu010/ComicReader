import Foundation

enum ReaderPrefetchSpeed: Equatable, Hashable, Sendable {
    case normal
    case rapid
}

enum ReaderPrefetchMotion: Equatable, Hashable, Sendable {
    case stationary
    case forward(ReaderPrefetchSpeed)
    case backward(ReaderPrefetchSpeed)
}

enum ReaderPrefetchMemoryState: Equatable, Hashable, Sendable {
    case normal
    /// 收到内存告警后保持保守模式，直到当前 ReaderScreen 生命周期结束。
    case constrained
}

struct ReaderPrefetchPlan: Equatable, Hashable, Sendable {
    static let empty = Self(presentationIDs: [])

    let presentationIDs: [ReaderPresentationID]
}

struct ReaderPrefetchMotionTracker: Equatable, Sendable {
    private var sample: Sample?
    private(set) var motion: ReaderPrefetchMotion = .stationary

    init() {
        sample = nil
    }

    mutating func reset() {
        sample = nil
        motion = .stationary
    }

    mutating func observe(
        presentationIDs: [ReaderPresentationID],
        at uptime: TimeInterval,
        in layout: ReaderLayout
    ) -> ReaderPrefetchMotion {
        let canonicalIDs = layout.canonicalPresentationIDs(presentationIDs)
        guard uptime.isFinite,
              uptime >= 0,
              !canonicalIDs.isEmpty else {
            reset()
            return motion
        }

        guard let previousSample = sample else {
            sample = Sample(
                presentationIDs: canonicalIDs,
                uptime: uptime
            )
            motion = .stationary
            return motion
        }

        guard canonicalIDs != previousSample.presentationIDs else {
            return motion
        }
        guard uptime >= previousSample.uptime else {
            sample = Sample(
                presentationIDs: canonicalIDs,
                uptime: uptime
            )
            motion = .stationary
            return motion
        }

        motion = ReaderPrefetchPolicy.motion(
            from: previousSample.presentationIDs,
            to: canonicalIDs,
            elapsedTime: uptime - previousSample.uptime,
            in: layout
        )
        sample = Sample(
            presentationIDs: canonicalIDs,
            uptime: uptime
        )
        return motion
    }
}

private extension ReaderPrefetchMotionTracker {
    struct Sample: Equatable, Sendable {
        let presentationIDs: [ReaderPresentationID]
        let uptime: TimeInterval
    }
}

enum ReaderPrefetchPolicy {
    /// 小于该间隔的相邻可见窗口变化按快速滚动处理。
    static let rapidTransitionInterval: TimeInterval = 0.25

    static func motion(
        from previousPresentationIDs: [ReaderPresentationID],
        to visiblePresentationIDs: [ReaderPresentationID],
        elapsedTime: TimeInterval?,
        in layout: ReaderLayout
    ) -> ReaderPrefetchMotion {
        guard let previousRange = visibleRange(
            for: previousPresentationIDs,
            in: layout
        ),
        let visibleRange = visibleRange(
            for: visiblePresentationIDs,
            in: layout
        ) else {
            return .stationary
        }

        let firstDelta = visibleRange.firstIndex
            - previousRange.firstIndex
        let lastDelta = visibleRange.lastIndex
            - previousRange.lastIndex

        let logicalDirection: LogicalDirection
        if firstDelta >= 0,
           lastDelta >= 0,
           firstDelta > 0 || lastDelta > 0 {
            logicalDirection = .forward
        } else if firstDelta <= 0,
                  lastDelta <= 0,
                  firstDelta < 0 || lastDelta < 0 {
            logicalDirection = .backward
        } else {
            return .stationary
        }

        let distance = movementDistance(
            from: previousRange,
            to: visibleRange,
            direction: logicalDirection,
            in: layout
        )
        let speed: ReaderPrefetchSpeed = isRapid(
            distance: distance,
            elapsedTime: elapsedTime
        ) ? .rapid : .normal

        switch logicalDirection {
        case .forward:
            return .forward(speed)
        case .backward:
            return .backward(speed)
        }
    }

    static func plan(
        visiblePresentationIDs: [ReaderPresentationID],
        in layout: ReaderLayout,
        motion: ReaderPrefetchMotion,
        windowCapability: ReaderLayoutCapability,
        memoryState: ReaderPrefetchMemoryState
    ) -> ReaderPrefetchPlan {
        guard memoryState == .normal,
              let visibleRange = visibleRange(
                  for: visiblePresentationIDs,
                  in: layout
              ) else {
            return .empty
        }

        let budget = directionalBudget(
            for: motion,
            windowCapability: windowCapability
        )
        let forwardIDs = scan(
            in: layout,
            from: visibleRange.lastIndex + 1,
            step: 1,
            limit: budget.forward
        )
        let backwardIDs = scan(
            in: layout,
            from: visibleRange.firstIndex - 1,
            step: -1,
            limit: budget.backward
        )

        switch motion {
        case .backward:
            return ReaderPrefetchPlan(
                presentationIDs: backwardIDs + forwardIDs
            )
        case .stationary, .forward:
            return ReaderPrefetchPlan(
                presentationIDs: forwardIDs + backwardIDs
            )
        }
    }

    private static func isRapid(
        distance: Int,
        elapsedTime: TimeInterval?
    ) -> Bool {
        if distance > 1 {
            return true
        }

        guard let elapsedTime,
              elapsedTime.isFinite,
              elapsedTime >= 0 else {
            return false
        }

        return elapsedTime < rapidTransitionInterval
    }

    private static func directionalBudget(
        for motion: ReaderPrefetchMotion,
        windowCapability: ReaderLayoutCapability
    ) -> DirectionalBudget {
        switch motion {
        case .stationary:
            // 初次打开仍以逻辑下一屏为主要候选；窄窗目标较小，可多保留一屏。
            return DirectionalBudget(
                forward: primaryBudget(
                    speed: .normal,
                    windowCapability: windowCapability
                ),
                backward: 1
            )
        case let .forward(speed):
            return DirectionalBudget(
                forward: primaryBudget(
                    speed: speed,
                    windowCapability: windowCapability
                ),
                backward: 1
            )
        case let .backward(speed):
            return DirectionalBudget(
                forward: 1,
                backward: primaryBudget(
                    speed: speed,
                    windowCapability: windowCapability
                )
            )
        }
    }

    private static func primaryBudget(
        speed: ReaderPrefetchSpeed,
        windowCapability: ReaderLayoutCapability
    ) -> Int {
        let normalBudget = windowCapability.supportsSpread ? 1 : 2
        return speed == .rapid ? normalBudget + 1 : normalBudget
    }

    private static func visibleRange(
        for presentationIDs: [ReaderPresentationID],
        in layout: ReaderLayout
    ) -> VisibleRange? {
        let indices = layout.canonicalPresentationIDs(
            presentationIDs
        ).compactMap { presentationID in
            layout.presentationIndex(for: presentationID)
        }

        guard let firstIndex = indices.min(),
              let lastIndex = indices.max() else {
            return nil
        }

        return VisibleRange(
            firstIndex: firstIndex,
            lastIndex: lastIndex
        )
    }

    private static func movementDistance(
        from previousRange: VisibleRange,
        to visibleRange: VisibleRange,
        direction: LogicalDirection,
        in layout: ReaderLayout
    ) -> Int {
        let firstDistance: Int
        let lastDistance: Int

        switch direction {
        case .forward:
            firstDistance = cappedTraversalDistance(
                in: layout,
                from: previousRange.firstIndex + 1,
                through: visibleRange.firstIndex
            )
            lastDistance = cappedTraversalDistance(
                in: layout,
                from: previousRange.lastIndex + 1,
                through: visibleRange.lastIndex
            )
        case .backward:
            firstDistance = cappedTraversalDistance(
                in: layout,
                from: visibleRange.firstIndex,
                through: previousRange.firstIndex - 1
            )
            lastDistance = cappedTraversalDistance(
                in: layout,
                from: visibleRange.lastIndex,
                through: previousRange.lastIndex - 1
            )
        }

        // 章节结束页也属于一次真实的可见窗口移动，但不应把跨话的
        // 单步导航误判成跨多页跳转。
        return max(1, max(firstDistance, lastDistance))
    }

    private static func cappedTraversalDistance(
        in layout: ReaderLayout,
        from startIndex: Int,
        through endIndex: Int
    ) -> Int {
        guard startIndex <= endIndex else {
            return 0
        }

        var index = startIndex
        var distance = 0
        var inspectedCount = 0

        // 速度分类只区分 1 屏与多屏；到 2 即可短路，避免大跨度跳转
        // 在 MainActor 上线性扫描整本漫画。
        while index <= endIndex,
              layout.presentations.indices.contains(index),
              distance < 2,
              inspectedCount < 4 {
            if !isChapterBoundary(layout.presentations[index]) {
                distance += 1
            }
            index += 1
            inspectedCount += 1
        }

        if index <= endIndex,
           layout.presentations.indices.contains(index) {
            return 2
        }

        return distance
    }

    private static func scan(
        in layout: ReaderLayout,
        from startIndex: Int,
        step: Int,
        limit: Int
    ) -> [ReaderPresentationID] {
        guard limit > 0 else {
            return []
        }

        var presentationIDs: [ReaderPresentationID] = []
        presentationIDs.reserveCapacity(limit)
        var index = startIndex

        while layout.presentations.indices.contains(index),
              presentationIDs.count < limit {
            let presentation = layout.presentations[index]
            if containsReadablePage(presentation) {
                presentationIDs.append(presentation.id)
            }
            index += step
        }

        return presentationIDs
    }

    private static func containsReadablePage(
        _ presentation: ReaderPresentation
    ) -> Bool {
        switch presentation.content {
        case let .page(page):
            return page.page.state == .readable
        case let .spread(spread):
            return spread.pagesInReadingOrder.contains {
                $0.page.state == .readable
            }
        case .chapterBoundary:
            return false
        }
    }

    private static func isChapterBoundary(
        _ presentation: ReaderPresentation
    ) -> Bool {
        if case .chapterBoundary = presentation.content {
            return true
        }
        return false
    }
}

private extension ReaderPrefetchPolicy {
    enum LogicalDirection {
        case forward
        case backward
    }

    struct VisibleRange {
        let firstIndex: Int
        let lastIndex: Int
    }

    struct DirectionalBudget {
        let forward: Int
        let backward: Int
    }
}
