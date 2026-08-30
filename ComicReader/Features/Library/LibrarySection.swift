import SwiftUI

enum LibrarySection: String, CaseIterable, Hashable, Identifiable {
    case continueReading
    case all
    case recent
    case favorites
    case unread
    case trash
    case shelves
    case settings

    static let librarySections: [LibrarySection] = [
        .continueReading,
        .all,
        .recent,
        .favorites,
        .unread,
        .trash,
        .shelves,
    ]

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .continueReading:
            "library.section.continue"
        case .all:
            "library.section.all"
        case .recent:
            "library.section.recent"
        case .favorites:
            "library.section.favorites"
        case .unread:
            "library.section.unread"
        case .trash:
            "library.section.trash"
        case .shelves:
            "library.section.shelves"
        case .settings:
            "settings.title"
        }
    }

    var systemImage: String {
        switch self {
        case .continueReading:
            "book.pages"
        case .all:
            "books.vertical"
        case .recent:
            "clock"
        case .favorites:
            "heart"
        case .unread:
            "circle"
        case .trash:
            "trash"
        case .shelves:
            "books.vertical.fill"
        case .settings:
            "gearshape"
        }
    }
}
