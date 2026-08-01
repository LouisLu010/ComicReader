import Foundation
import XCTest
@testable import ComicReader

@MainActor
final class ReaderSessionControllerTests: XCTestCase {
    func testFlushCoalescesLatestPositionAndUsesIncreasingTimestamps() async throws {
        let chapterID = chapterID("chapter-1")
        let firstPage = page("page-1")
        let secondPage = page("page-2")
        let recorder = RecordingReaderProgressRecorder()
        let controller = ReaderSessionController(
            session: try session(
                chapters: [chapter(chapterID, pages: [firstPage, secondPage])]
            ),
            recorder: recorder,
            now: { Date(timeIntervalSince1970: 100) },
            debounceNanoseconds: 60_000_000_000
        )

        XCTAssertTrue(
            controller.move(
                to: .chapter(chapterID, firstPage.id),
                pageOffset: 0.25,
                zoomScale: 1.5
            )
        )
        XCTAssertTrue(
            controller.move(
                to: .chapter(chapterID, secondPage.id),
                pageOffset: 0.75,
                zoomScale: 2
            )
        )
        let didPersistLatestPosition = await controller.flushPendingProgress()
        XCTAssertTrue(didPersistLatestPosition)

        XCTAssertEqual(recorder.records.count, 1)
        XCTAssertEqual(recorder.records[0].comicID, controller.session.comic.id)
        XCTAssertEqual(recorder.records[0].progress.pageID, secondPage.id.rawValue)
        XCTAssertEqual(recorder.records[0].progress.pageOffset, 0.75)
        XCTAssertEqual(recorder.records[0].progress.zoomScale, 2)
        XCTAssertEqual(controller.progressPersistenceState, .saved)

        XCTAssertTrue(
            controller.move(
                to: .chapter(chapterID, firstPage.id),
                pageOffset: 0.5,
                zoomScale: 1
            )
        )
        let didPersistNextPosition = await controller.flushPendingProgress()
        XCTAssertTrue(didPersistNextPosition)

        XCTAssertEqual(recorder.records.count, 2)
        XCTAssertGreaterThan(
            recorder.records[1].progress.updatedAt,
            recorder.records[0].progress.updatedAt
        )
    }

    func testDebouncedPersistenceWritesOnlyLatestPosition() async throws {
        let chapterID = chapterID("chapter-1")
        let firstPage = page("page-1")
        let secondPage = page("page-2")
        let recorder = RecordingReaderProgressRecorder()
        let controller = ReaderSessionController(
            session: try session(
                chapters: [chapter(chapterID, pages: [firstPage, secondPage])]
            ),
            recorder: recorder,
            debounceNanoseconds: 10_000_000
        )

        XCTAssertTrue(
            controller.move(
                to: .chapter(chapterID, firstPage.id),
                pageOffset: 0.25
            )
        )
        XCTAssertTrue(
            controller.move(
                to: .chapter(chapterID, secondPage.id),
                pageOffset: 0.75
            )
        )
        await waitForRecordCount(1, from: recorder)

        XCTAssertEqual(recorder.records.count, 1)
        XCTAssertEqual(recorder.records[0].progress.pageID, secondPage.id.rawValue)
        XCTAssertEqual(recorder.records[0].progress.pageOffset, 0.75)
        XCTAssertEqual(controller.progressPersistenceState, .saved)
    }

    func testCrossChapterMovementPersistsImmediately() async throws {
        let firstChapterID = chapterID("chapter-1")
        let secondChapterID = chapterID("chapter-2")
        let firstPage = page("page-1")
        let secondPage = page("page-2")
        let recorder = RecordingReaderProgressRecorder()
        let controller = ReaderSessionController(
            session: try session(
                chapters: [
                    chapter(firstChapterID, pages: [firstPage]),
                    chapter(secondChapterID, pages: [secondPage]),
                ]
            ),
            recorder: recorder,
            debounceNanoseconds: 60_000_000_000
        )

        XCTAssertTrue(
            controller.move(
                to: .chapter(secondChapterID, secondPage.id),
                pageOffset: 0.25
            )
        )
        await waitForRecordCount(1, from: recorder)

        XCTAssertEqual(recorder.records.count, 1)
        XCTAssertEqual(recorder.records[0].progress.pageID, secondPage.id.rawValue)
        XCTAssertEqual(recorder.records[0].progress.pageOffset, 0.25)
    }

    func testFlushFailureKeepsLatestProgressForRetry() async throws {
        let chapterID = chapterID("chapter-1")
        let firstPage = page("page-1")
        let recorder = RecordingReaderProgressRecorder(outcomes: [false, true])
        let controller = ReaderSessionController(
            session: try session(chapters: [chapter(chapterID, pages: [firstPage])]),
            recorder: recorder,
            debounceNanoseconds: 60_000_000_000
        )

        XCTAssertTrue(
            controller.move(
                to: .chapter(chapterID, firstPage.id),
                pageOffset: 0.5
            )
        )

        let didFailFirstPersistence = await controller.flushPendingProgress()
        XCTAssertFalse(didFailFirstPersistence)
        XCTAssertEqual(controller.progressPersistenceState, .failed)
        XCTAssertEqual(recorder.records.count, 1)

        let didRetryPersistence = await controller.flushPendingProgress()
        XCTAssertTrue(didRetryPersistence)
        XCTAssertEqual(controller.progressPersistenceState, .saved)
        XCTAssertEqual(recorder.records.count, 2)
        XCTAssertEqual(recorder.records[0].progress, recorder.records[1].progress)
    }

    func testControllerUsesTimestampNewerThanPersistedProgress() async throws {
        let chapterID = chapterID("chapter-1")
        let firstPage = page("page-1")
        let persistedProgress = LibraryReadingProgress(
            chapterID: chapterID.rawValue,
            pageID: firstPage.id.rawValue,
            pageOffset: 0.1,
            zoomScale: 1,
            updatedAt: Date(timeIntervalSince1970: 300)
        )
        let recorder = RecordingReaderProgressRecorder()
        let controller = ReaderSessionController(
            session: try session(chapters: [chapter(chapterID, pages: [firstPage])]),
            recorder: recorder,
            persistedProgress: persistedProgress,
            now: { Date(timeIntervalSince1970: 100) },
            debounceNanoseconds: 60_000_000_000
        )

        XCTAssertTrue(
            controller.move(
                to: .chapter(chapterID, firstPage.id),
                pageOffset: 0.5
            )
        )
        let didPersist = await controller.flushPendingProgress()

        XCTAssertTrue(didPersist)
        XCTAssertGreaterThan(
            recorder.records[0].progress.updatedAt,
            persistedProgress.updatedAt
        )
    }

    func testControllerPreservesExistingComicCompletion() async throws {
        let chapterID = chapterID("chapter-1")
        let firstPage = page("page-1")
        let persistedProgress = LibraryReadingProgress(
            chapterID: chapterID.rawValue,
            pageID: firstPage.id.rawValue,
            pageOffset: 1,
            zoomScale: 1,
            isCompleted: true,
            updatedAt: .distantPast
        )
        let recorder = RecordingReaderProgressRecorder()
        let controller = ReaderSessionController(
            session: try session(chapters: [chapter(chapterID, pages: [firstPage])]),
            recorder: recorder,
            persistedProgress: persistedProgress,
            debounceNanoseconds: 60_000_000_000
        )

        XCTAssertTrue(
            controller.move(
                to: .chapter(chapterID, firstPage.id),
                pageOffset: 0
            )
        )
        let didPersist = await controller.flushPendingProgress()

        XCTAssertTrue(didPersist)
        XCTAssertTrue(recorder.records[0].progress.isCompleted)
    }

    func testFlushWaitsForInFlightSaveAndPersistsLatestPosition() async throws {
        let chapterID = chapterID("chapter-1")
        let firstPage = page("page-1")
        let secondPage = page("page-2")
        let recorder = SuspendingReaderProgressRecorder()
        let finalFlushProbe = FlushTaskProbe()
        let controller = ReaderSessionController(
            session: try session(
                chapters: [chapter(chapterID, pages: [firstPage, secondPage])]
            ),
            recorder: recorder,
            debounceNanoseconds: 60_000_000_000
        )

        XCTAssertTrue(
            controller.move(
                to: .chapter(chapterID, firstPage.id),
                pageOffset: 0.25
            )
        )
        let firstFlush = Task { @MainActor in
            await controller.flushPendingProgress()
        }
        await waitForSuspendedWrite(recorder)

        XCTAssertTrue(
            controller.move(
                to: .chapter(chapterID, secondPage.id),
                pageOffset: 0.75
            )
        )
        let finalFlush = Task { @MainActor in
            finalFlushProbe.didStart = true
            let didPersist = await controller.flushPendingProgress()
            finalFlushProbe.didFinish = true
            return didPersist
        }
        await waitForFlushStart(finalFlushProbe)
        XCTAssertFalse(finalFlushProbe.didFinish)
        recorder.resumeCurrentWrite()

        let didPersistFirstFlush = await firstFlush.value
        let didPersistFinalFlush = await finalFlush.value
        XCTAssertTrue(didPersistFirstFlush)
        XCTAssertTrue(didPersistFinalFlush)
        XCTAssertEqual(recorder.records.count, 2)
        XCTAssertEqual(recorder.records.last?.progress.pageID, secondPage.id.rawValue)
        XCTAssertEqual(recorder.records.last?.progress.pageOffset, 0.75)
        XCTAssertEqual(controller.progressPersistenceState, .saved)
    }

    func testControllerWritesComicCompletionOnlyAfterFinalChapterEnds() async throws {
        let firstChapterID = chapterID("chapter-1")
        let finalChapterID = chapterID("chapter-2")
        let firstPage = page("page-1")
        let finalPage = page("page-2")
        let recorder = RecordingReaderProgressRecorder()
        let controller = ReaderSessionController(
            session: try session(
                chapters: [
                    chapter(firstChapterID, pages: [firstPage]),
                    chapter(finalChapterID, pages: [finalPage]),
                ],
                readingMode: .singlePage
            ),
            recorder: recorder,
            debounceNanoseconds: 60_000_000_000
        )

        XCTAssertTrue(
            controller.move(to: .chapter(firstChapterID, firstPage.id))
        )
        XCTAssertTrue(controller.finishCurrentPresentation())
        let didPersistFirstChapter = await controller.flushPendingProgress()
        XCTAssertTrue(didPersistFirstChapter)
        XCTAssertFalse(recorder.records.last?.progress.isCompleted ?? true)

        XCTAssertTrue(
            controller.move(to: .chapter(finalChapterID, finalPage.id))
        )
        XCTAssertTrue(controller.finishCurrentPresentation())
        let didPersistFinalChapter = await controller.flushPendingProgress()
        XCTAssertTrue(didPersistFinalChapter)
        XCTAssertTrue(recorder.records.last?.progress.isCompleted ?? false)
    }

    func testControllerKeepsComicCompletionStickyAfterBacktracking() async throws {
        let firstChapterID = chapterID("chapter-1")
        let finalChapterID = chapterID("chapter-2")
        let firstPage = page("page-1")
        let finalPage = page("page-2")
        let recorder = RecordingReaderProgressRecorder()
        let controller = ReaderSessionController(
            session: try session(
                chapters: [
                    chapter(firstChapterID, pages: [firstPage]),
                    chapter(finalChapterID, pages: [finalPage]),
                ]
            ),
            recorder: recorder,
            debounceNanoseconds: 60_000_000_000
        )

        XCTAssertTrue(
            controller.move(
                to: .chapter(firstChapterID, firstPage.id),
                pageOffset: 1
            )
        )
        let didPersistFirstChapter = await controller.flushPendingProgress()
        XCTAssertTrue(didPersistFirstChapter)
        XCTAssertFalse(recorder.records.last?.progress.isCompleted ?? true)

        XCTAssertTrue(
            controller.move(
                to: .chapter(finalChapterID, finalPage.id),
                pageOffset: 1
            )
        )
        let didPersistFinalChapter = await controller.flushPendingProgress()
        XCTAssertTrue(didPersistFinalChapter)
        XCTAssertTrue(recorder.records.last?.progress.isCompleted ?? false)

        XCTAssertTrue(
            controller.move(
                to: .chapter(firstChapterID, firstPage.id),
                pageOffset: 0
            )
        )
        let didPersistBacktrackedPosition = await controller.flushPendingProgress()
        XCTAssertTrue(didPersistBacktrackedPosition)
        XCTAssertTrue(recorder.records.last?.progress.isCompleted ?? false)
    }

    func testSeparateControllersDoNotShareProgressState() async throws {
        let firstRecorder = RecordingReaderProgressRecorder()
        let secondRecorder = RecordingReaderProgressRecorder()
        let firstChapterID = chapterID("first-chapter")
        let secondChapterID = chapterID("second-chapter")
        let firstPage = page("first-page")
        let secondPage = page("second-page")
        let firstController = ReaderSessionController(
            session: try session(
                comicID: comicID("00000000-0000-0000-0000-000000000711"),
                chapters: [chapter(firstChapterID, pages: [firstPage])]
            ),
            recorder: firstRecorder,
            debounceNanoseconds: 60_000_000_000
        )
        let secondController = ReaderSessionController(
            session: try session(
                comicID: comicID("00000000-0000-0000-0000-000000000712"),
                chapters: [chapter(secondChapterID, pages: [secondPage])]
            ),
            recorder: secondRecorder,
            debounceNanoseconds: 60_000_000_000
        )

        XCTAssertTrue(
            firstController.move(
                to: .chapter(firstChapterID, firstPage.id),
                pageOffset: 0.25
            )
        )
        XCTAssertTrue(
            secondController.move(
                to: .chapter(secondChapterID, secondPage.id),
                pageOffset: 0.75
            )
        )
        let didPersistFirstController = await firstController.flushPendingProgress()
        let didPersistSecondController = await secondController.flushPendingProgress()
        XCTAssertTrue(didPersistFirstController)
        XCTAssertTrue(didPersistSecondController)

        XCTAssertEqual(firstRecorder.records.count, 1)
        XCTAssertEqual(secondRecorder.records.count, 1)
        XCTAssertEqual(
            firstRecorder.records[0].comicID,
            firstController.session.comic.id
        )
        XCTAssertEqual(
            secondRecorder.records[0].comicID,
            secondController.session.comic.id
        )
        XCTAssertEqual(firstRecorder.records[0].progress.pageOffset, 0.25)
        XCTAssertEqual(secondRecorder.records[0].progress.pageOffset, 0.75)
    }

    private func session(
        comicID: ManagedComicID? = nil,
        chapters: [ReaderChapter],
        readingMode: ReadingMode = .continuous
    ) throws -> ReaderSession {
        let resolvedComicID = comicID ?? self.comicID(
            "00000000-0000-0000-0000-000000000710"
        )
        return try ReaderSession(
            comic: ReaderComic(
                id: resolvedComicID,
                displayName: "Controller Test Comic",
                chapters: chapters
            ),
            readingMode: readingMode
        )
    }

    private func comicID(_ rawValue: String) -> ManagedComicID {
        ManagedComicID(rawValue: UUID(uuidString: rawValue)!)
    }

    private func chapterID(_ rawValue: String) -> ImportChapterCandidate.ID {
        ImportChapterCandidate.ID(rawValue: rawValue)
    }

    private func page(_ rawValue: String) -> ReaderPage {
        ReaderPage(
            id: ImportPageCandidate.ID(rawValue: rawValue),
            originalFileName: rawValue,
            displayPixelSize: ImportPixelSize(width: 1200, height: 1800)
        )
    }

    private func chapter(
        _ id: ImportChapterCandidate.ID,
        pages: [ReaderPage]
    ) -> ReaderChapter {
        ReaderChapter(id: id, displayName: id.rawValue, pages: pages)
    }

    private func waitForSuspendedWrite(
        _ recorder: SuspendingReaderProgressRecorder,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<100 {
            if recorder.isWaitingForResume {
                return
            }
            await Task.yield()
        }

        XCTFail("Timed out waiting for the progress recorder.", file: file, line: line)
    }

    private func waitForRecordCount(
        _ count: Int,
        from recorder: RecordingReaderProgressRecorder,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<200 {
            if recorder.records.count >= count {
                return
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }

        XCTFail("Timed out waiting for persisted progress.", file: file, line: line)
    }

    private func waitForFlushStart(
        _ probe: FlushTaskProbe,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<100 {
            if probe.didStart {
                return
            }
            await Task.yield()
        }

        XCTFail("Timed out waiting for the final flush to start.", file: file, line: line)
    }
}

@MainActor
private final class RecordingReaderProgressRecorder: ReaderProgressRecording {
    struct Record: Equatable {
        let progress: LibraryReadingProgress
        let comicID: ManagedComicID
    }

    private var outcomes: [Bool]
    private(set) var records: [Record] = []

    init(outcomes: [Bool] = []) {
        self.outcomes = outcomes
    }

    func recordProgress(
        _ progress: LibraryReadingProgress,
        for comicID: ManagedComicID
    ) async -> Bool {
        records.append(Record(progress: progress, comicID: comicID))
        return outcomes.isEmpty ? true : outcomes.removeFirst()
    }
}

@MainActor
private final class SuspendingReaderProgressRecorder: ReaderProgressRecording {
    struct Record: Equatable {
        let progress: LibraryReadingProgress
        let comicID: ManagedComicID
    }

    private(set) var records: [Record] = []
    private var continuation: CheckedContinuation<Bool, Never>?
    private var queuedResumeResult: Bool?
    private(set) var isWaitingForResume = false

    func recordProgress(
        _ progress: LibraryReadingProgress,
        for comicID: ManagedComicID
    ) async -> Bool {
        records.append(Record(progress: progress, comicID: comicID))

        guard records.count == 1 else {
            return true
        }

        isWaitingForResume = true
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            if let queuedResumeResult {
                self.queuedResumeResult = nil
                self.continuation = nil
                self.isWaitingForResume = false
                continuation.resume(returning: queuedResumeResult)
            }
        }
    }

    func resumeCurrentWrite() {
        guard let continuation else {
            queuedResumeResult = true
            return
        }

        self.continuation = nil
        isWaitingForResume = false
        continuation.resume(returning: true)
    }
}

@MainActor
private final class FlushTaskProbe {
    var didStart = false
    var didFinish = false
}
