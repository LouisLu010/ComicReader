import Observation
import SwiftUI
import UIKit

@MainActor
@Observable
final class ReaderExperienceSettings {
    private(set) var preferences: ReaderDisplayPreferences
    private(set) var pageRotations: [String: [String: Int]]
    private let defaults: UserDefaults
    static let preferenceKey = "reader.display.preferences.v1"
    static let pageRotationsKey = "reader.display.pageRotations.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        pageRotations = defaults.data(forKey: Self.pageRotationsKey).flatMap {
            try? JSONDecoder().decode([String: [String: Int]].self, from: $0)
        }?.mapValues { $0.mapValues { (($0 % 4) + 4) % 4 } } ?? [:]
        preferences = defaults.data(forKey: Self.preferenceKey).flatMap {
            try? JSONDecoder().decode(ReaderDisplayPreferences.self, from: $0)
        }?.validated ?? ReaderDisplayPreferences()
    }

    func update(_ change: (inout ReaderDisplayPreferences) -> Void) {
        var updated = preferences
        change(&updated)
        updated = updated.validated
        guard let data = try? JSONEncoder().encode(updated) else { return }
        defaults.set(data, forKey: Self.preferenceKey)
        preferences = updated
    }

    func rotations(for comicID: ManagedComicID) -> [String: Int] {
        pageRotations[comicID.rawValue.uuidString] ?? [:]
    }

    func setRotation(_ turns: Int?, pageID: String, comicID: ManagedComicID) {
        var updated = pageRotations
        let comicKey = comicID.rawValue.uuidString
        var pages = updated[comicKey] ?? [:]
        pages[pageID] = turns.map { (($0 % 4) + 4) % 4 }
        updated[comicKey] = pages.isEmpty ? nil : pages
        guard let data = try? JSONEncoder().encode(updated) else { return }
        defaults.set(data, forKey: Self.pageRotationsKey)
        pageRotations = updated
    }
}

private struct ReaderPageRotationsKey: EnvironmentKey {
    static let defaultValue: [String: Int] = [:]
}

private struct ReaderDisplayPreferencesKey: EnvironmentKey {
    static let defaultValue = ReaderDisplayPreferences()
}

private struct ReaderPrivacyLockedKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var readerPageRotations: [String: Int] {
        get { self[ReaderPageRotationsKey.self] }
        set { self[ReaderPageRotationsKey.self] = newValue }
    }
    var readerPrivacyLocked: Bool {
        get { self[ReaderPrivacyLockedKey.self] }
        set { self[ReaderPrivacyLockedKey.self] = newValue }
    }
    var readerDisplayPreferences: ReaderDisplayPreferences {
        get { self[ReaderDisplayPreferencesKey.self] }
        set { self[ReaderDisplayPreferencesKey.self] = newValue }
    }
}

extension ReaderCanvas {
    var color: Color {
        switch self {
        case .black: .black
        case .white: .white
        case .sepia: Color(red: 0.94, green: 0.88, blue: 0.73)
        }
    }
}

/// 常亮是 App 级副作用，通过租约避免一个窗口退出时关闭另一窗口的设置。
@MainActor
final class ReaderAwakeCoordinator {
    static let shared = ReaderAwakeCoordinator(
        read: { UIApplication.shared.isIdleTimerDisabled },
        write: { UIApplication.shared.isIdleTimerDisabled = $0 }
    )
    private var leases = Set<UUID>()
    private var previousValue: Bool?
    private let read: () -> Bool
    private let write: (Bool) -> Void

    init(read: @escaping () -> Bool, write: @escaping (Bool) -> Void) {
        self.read = read
        self.write = write
    }

    func update(_ id: UUID, enabled: Bool) {
        if enabled {
            if leases.isEmpty { previousValue = read() }
            leases.insert(id)
            write(true)
        } else {
            leases.remove(id)
            if leases.isEmpty, let previousValue {
                write(previousValue)
                self.previousValue = nil
            }
        }
    }
}
