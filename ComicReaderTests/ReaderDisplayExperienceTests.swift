import CoreGraphics
import Foundation
import XCTest
@testable import ComicReader

final class ReaderDisplayExperienceTests: XCTestCase {
    func testComicWindowsKeepIndependentIdentityAndRestoreTheirComic() throws {
        let comicID = UUID()
        let first = ComicWindowRequest(comicID: comicID)
        let second = ComicWindowRequest(comicID: comicID)
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(first.comicID, second.comicID)
        XCTAssertEqual(
            try JSONDecoder().decode(ComicWindowRequest.self, from: JSONEncoder().encode(first)),
            first
        )
    }
    func testValidationAndSystemReduceMotionTakePriority() {
        var preferences = ReaderDisplayPreferences()
        preferences.brightness = .nan
        preferences.quarterTurns = -1
        XCTAssertEqual(preferences.validated.brightness, 1)
        XCTAssertEqual(preferences.validated.quarterTurns, 3)
        preferences.brightness = -20
        XCTAssertEqual(preferences.validated.brightness, 0.2)
        XCTAssertFalse(preferences.allowsAnimation(reduceMotion: true))
        preferences.animationsEnabled = false
        XCTAssertFalse(preferences.allowsAnimation(reduceMotion: false))
    }

    @MainActor
    func testDisplaySettingsRoundTripAndDamagedPreferencesRecover() {
        let defaults = UserDefaults(suiteName: "DisplayTests.\(UUID().uuidString)")!
        let settings = ReaderExperienceSettings(defaults: defaults)
        settings.update {
            $0.canvas = .sepia
            $0.trimsWhitespace = true
            $0.brightness = 0.5
            $0.quarterTurns = 5
            $0.keepsScreenAwake = true
            $0.animationsEnabled = false
        }
        XCTAssertEqual(ReaderExperienceSettings(defaults: defaults).preferences, settings.preferences)
        XCTAssertEqual(settings.preferences.quarterTurns, 1)
        defaults.set(Data("invalid".utf8), forKey: ReaderExperienceSettings.preferenceKey)
        XCTAssertEqual(ReaderExperienceSettings(defaults: defaults).preferences, ReaderDisplayPreferences())
    }

    @MainActor
    func testAwakeLeasesRestorePreviousStateOnlyAfterLastWindowLeaves() {
        var disabled = false
        let coordinator = ReaderAwakeCoordinator(read: { disabled }, write: { disabled = $0 })
        let first = UUID(), second = UUID()
        coordinator.update(first, enabled: true)
        coordinator.update(first, enabled: true)
        coordinator.update(second, enabled: true)
        XCTAssertTrue(disabled)
        coordinator.update(first, enabled: false)
        XCTAssertTrue(disabled)
        coordinator.update(second, enabled: false)
        XCTAssertFalse(disabled)
        disabled = true
        coordinator.update(first, enabled: true)
        coordinator.update(first, enabled: false)
        XCTAssertTrue(disabled)
    }

    func testRotationChangesOnlyRenderedDimensions() async throws {
        let image = try makeImage(hasContent: true)
        let processor = ReaderImageAppearanceProcessor()
        let unchanged = try await processor.process(image, trimsWhitespace: false, quarterTurns: 0)
        XCTAssertTrue(unchanged === image)
        let rotated = try await processor.process(image, trimsWhitespace: false, quarterTurns: 1)
        XCTAssertEqual(rotated.width, 80)
        XCTAssertEqual(rotated.height, 120)
        XCTAssertEqual(image.width, 120)
        XCTAssertEqual(image.height, 80)
    }

    func testWhitespaceTrimPreservesContentAndBlankPages() async throws {
        let processor = ReaderImageAppearanceProcessor()
        let image = try makeImage(hasContent: true)
        let trimmed = try await processor.process(image, trimsWhitespace: true, quarterTurns: 0)
        XCTAssertLessThan(trimmed.width, image.width)
        XCTAssertLessThan(trimmed.height, image.height)
        XCTAssertGreaterThanOrEqual(trimmed.width, 60)
        XCTAssertGreaterThanOrEqual(trimmed.height, 30)
        let blank = try makeImage(hasContent: false)
        let preserved = try await processor.process(blank, trimsWhitespace: true, quarterTurns: 3)
        XCTAssertEqual(preserved.width, blank.height)
        XCTAssertEqual(preserved.height, blank.width)
    }

    private func makeImage(hasContent: Bool) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: 120, height: 80, bitsPerComponent: 8, bytesPerRow: 480,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 120, height: 80))
        if hasContent {
            context.setFillColor(gray: 0, alpha: 1)
            context.fill(CGRect(x: 10, y: 20, width: 60, height: 30))
        }
        return try XCTUnwrap(context.makeImage())
    }
}
