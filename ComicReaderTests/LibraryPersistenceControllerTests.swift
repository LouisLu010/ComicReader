import Dispatch
import Foundation
import XCTest
@testable import ComicReader

final class LibraryPersistenceControllerTests: XCTestCase {
    @MainActor
    func testApplicationStoreOpensAsynchronouslyOnDemand() async throws {
        let container = try ComicReaderModelContainer.makeContainer(
            isStoredInMemoryOnly: true
        )
        let openRecorder = ModelContainerOpenRecorder(
            result: .opened(container)
        )
        let controller = LibraryPersistenceController(
            open: {
                openRecorder.open()
            }
        )

        XCTAssertEqual(controller.status, .opening)
        XCTAssertNil(controller.modelContainer)

        await controller.openApplicationStore()
        await controller.openApplicationStore()

        XCTAssertEqual(controller.status, .ready)
        XCTAssertTrue(controller.modelContainer === container)
        XCTAssertEqual(openRecorder.callCount, 1)
    }

    @MainActor
    func testConcurrentOpenCallsReuseInFlightTask() async throws {
        let container = try ComicReaderModelContainer.makeContainer(
            isStoredInMemoryOnly: true
        )
        let openRecorder = ModelContainerOpenRecorder(
            result: .opened(container),
            waitsForRelease: true
        )
        let controller = LibraryPersistenceController(
            open: {
                openRecorder.open()
            }
        )
        defer { openRecorder.releaseOpen() }

        let firstCall = Task { @MainActor in
            await controller.openApplicationStore()
        }
        for _ in 0..<100 {
            guard !openRecorder.hasStarted else {
                break
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(openRecorder.hasStarted)

        let secondCallProbe = MainActorCallProbe()
        let secondCall = Task { @MainActor in
            secondCallProbe.hasEntered = true
            await controller.openApplicationStore()
        }
        for _ in 0..<100 {
            guard !secondCallProbe.hasEntered else {
                break
            }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertTrue(secondCallProbe.hasEntered)

        openRecorder.releaseOpen()
        await firstCall.value
        await secondCall.value

        XCTAssertEqual(openRecorder.callCount, 1)
        XCTAssertEqual(controller.status, .ready)
        XCTAssertTrue(controller.modelContainer === container)
    }

    @MainActor
    func testAsynchronousOpenFailureRequiresExplicitRecovery() async throws {
        let sandboxURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: sandboxURL) }
        let storeURL = sandboxURL.appendingPathComponent("Library.store")
        try Data("corrupt-store".utf8).write(to: storeURL)
        let openRecorder = ModelContainerOpenRecorder(
            result: ComicReaderModelContainer.openDiskContainer(
                storeURL: storeURL
            )
        )
        let controller = LibraryPersistenceController(
            open: {
                openRecorder.open()
            }
        )

        await controller.openApplicationStore()

        XCTAssertEqual(controller.status, .recoveryRequired)
        XCTAssertNil(controller.modelContainer)
        XCTAssertTrue(controller.canRecoverFailedIndex)
        XCTAssertEqual(openRecorder.callCount, 1)
    }

    @MainActor
    func testOpenedStoreStartsReadyWithoutRecoveryAction() async throws {
        let container = try ComicReaderModelContainer.makeContainer(
            isStoredInMemoryOnly: true
        )
        let controller = LibraryPersistenceController(
            openResult: .opened(container)
        )

        XCTAssertEqual(controller.status, .ready)
        XCTAssertTrue(controller.modelContainer === container)
        XCTAssertFalse(controller.canRecoverFailedIndex)
        let didRecover = await controller.recoverFailedIndex()
        XCTAssertFalse(didRecover)
    }

    @MainActor
    func testExplicitRecoveryReopensFailedStore() async throws {
        let sandboxURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: sandboxURL) }
        let storeURL = sandboxURL.appendingPathComponent("Library.store")
        try Data("corrupt-store".utf8).write(to: storeURL)

        let controller = LibraryPersistenceController(
            openResult: ComicReaderModelContainer.openDiskContainer(
                storeURL: storeURL
            ),
            reopen: {
                ComicReaderModelContainer.openDiskContainer(
                    storeURL: storeURL
                )
            }
        )

        XCTAssertEqual(controller.status, .recoveryRequired)
        XCTAssertNil(controller.modelContainer)
        XCTAssertTrue(controller.canRecoverFailedIndex)

        let didRecover = await controller.recoverFailedIndex()

        XCTAssertTrue(didRecover)
        XCTAssertEqual(controller.status, .ready)
        XCTAssertNotNil(controller.modelContainer)
        XCTAssertFalse(controller.canRecoverFailedIndex)
    }

    @MainActor
    func testRecoveryFailureKeepsExplicitRetryAvailable() async throws {
        let sandboxURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: sandboxURL) }
        let storeURL = sandboxURL.appendingPathComponent(
            "Unsafe.store",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: storeURL,
            withIntermediateDirectories: true
        )
        let sentinelURL = storeURL.appendingPathComponent("sentinel.txt")
        let sentinelData = Data("keep-me".utf8)
        try sentinelData.write(to: sentinelURL)

        let controller = LibraryPersistenceController(
            openResult: ComicReaderModelContainer.openDiskContainer(
                storeURL: storeURL
            ),
            reopen: {
                ComicReaderModelContainer.openDiskContainer(
                    storeURL: storeURL
                )
            }
        )

        let didRecover = await controller.recoverFailedIndex()

        XCTAssertFalse(didRecover)
        XCTAssertEqual(controller.status, .recoveryFailed)
        XCTAssertNil(controller.modelContainer)
        XCTAssertTrue(controller.canRecoverFailedIndex)
        XCTAssertEqual(try Data(contentsOf: sentinelURL), sentinelData)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true
        )
        return url
    }
}

private final class ModelContainerOpenRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private let result: ComicReaderModelContainerOpenResult
    private let releaseSemaphore: DispatchSemaphore?
    private var storedCallCount = 0
    private var storedHasStarted = false

    init(
        result: ComicReaderModelContainerOpenResult,
        waitsForRelease: Bool = false
    ) {
        self.result = result
        releaseSemaphore = waitsForRelease
            ? DispatchSemaphore(value: 0)
            : nil
    }

    var callCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedCallCount
    }

    var hasStarted: Bool {
        lock.lock()
        defer { lock.unlock() }
        return storedHasStarted
    }

    func open() -> ComicReaderModelContainerOpenResult {
        lock.lock()
        storedCallCount += 1
        storedHasStarted = true
        lock.unlock()
        releaseSemaphore?.wait()
        return result
    }

    func releaseOpen() {
        releaseSemaphore?.signal()
    }
}

@MainActor
private final class MainActorCallProbe {
    var hasEntered = false
}
