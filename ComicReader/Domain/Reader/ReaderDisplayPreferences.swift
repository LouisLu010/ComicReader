import Foundation

enum ReaderCanvas: String, Codable, CaseIterable, Sendable {
    case black, white, sepia
}

struct ReaderDisplayPreferences: Codable, Equatable, Sendable {
    var canvas: ReaderCanvas = .black
    var brightness: Double = 1
    var trimsWhitespace = false
    var quarterTurns = 0
    var keepsScreenAwake = false
    var animationsEnabled = true

    var validated: Self {
        var result = self
        result.brightness = brightness.isFinite ? min(1, max(0.2, brightness)) : 1
        result.quarterTurns = ((quarterTurns % 4) + 4) % 4
        return result
    }

    func allowsAnimation(reduceMotion: Bool) -> Bool {
        animationsEnabled && !reduceMotion
    }
}
