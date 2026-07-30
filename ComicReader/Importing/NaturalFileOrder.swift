import Foundation

enum NaturalFileOrder {
    static func areInIncreasingOrder(
        _ lhs: NamedSourceItem,
        _ rhs: NamedSourceItem,
        locale: Locale = .current
    ) -> Bool {
        compare(lhs, rhs, locale: locale) == .orderedAscending
    }

    static func areEquivalent(
        _ lhs: NamedSourceItem,
        _ rhs: NamedSourceItem,
        locale: Locale = .current
    ) -> Bool {
        compare(lhs, rhs, locale: locale) == .orderedSame
    }

    private static func compare(
        _ lhs: NamedSourceItem,
        _ rhs: NamedSourceItem,
        locale: Locale
    ) -> ComparisonResult {
        let comparison = lhs.name.compare(
            rhs.name,
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive, .numeric],
            locale: locale
        )

        if comparison != .orderedSame {
            return comparison
        }

        switch (lhs.creationDate, rhs.creationDate) {
        case let (lhsCreationDate?, rhsCreationDate?)
            where lhsCreationDate != rhsCreationDate:
            return lhsCreationDate < rhsCreationDate
                ? .orderedAscending
                : .orderedDescending
        case (.some, .none):
            return .orderedAscending
        case (.none, .some):
            return .orderedDescending
        default:
            break
        }

        return lhs.name.compare(rhs.name, options: .literal)
    }
}

struct NamedSourceItem {
    let name: String
    let creationDate: Date?
}
