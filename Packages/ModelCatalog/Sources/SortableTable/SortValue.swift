import Foundation
import SwiftUI

public enum SortValue: Hashable, Sendable {
    case number(Double)
    case text(String)
    case date(Date)
    case none

    public var isNone: Bool { if case .none = self { return true } else { return false } }

    public var label: String? { if case let .text(text) = self { return text } else { return nil } }

    private var rank: Int {
        switch self {
        case .number: 0
        case .text: 1
        case .date: 2
        case .none: 3
        }
    }

    public static func compare(_ lhs: SortValue, _ rhs: SortValue, ascending: Bool) -> ComparisonResult {
        switch (lhs, rhs) {
        case (.none, .none): return .orderedSame
        case (.none, _): return .orderedDescending
        case (_, .none): return .orderedAscending
        default: break
        }
        let result: ComparisonResult
        switch (lhs, rhs) {
        case let (.number(a), .number(b)):
            result = a == b ? .orderedSame : (a < b ? .orderedAscending : .orderedDescending)
        case let (.date(a), .date(b)):
            result = a == b ? .orderedSame : (a < b ? .orderedAscending : .orderedDescending)
        case let (.text(a), .text(b)):
            result = a.caseInsensitiveCompare(b)
        default:
            let a = lhs.rank, b = rhs.rank
            result = a == b ? .orderedSame : (a < b ? .orderedAscending : .orderedDescending)
        }
        guard !ascending else { return result }
        switch result {
        case .orderedAscending: return .orderedDescending
        case .orderedDescending: return .orderedAscending
        case .orderedSame: return .orderedSame
        }
    }
}

public struct SortState: Codable, Hashable, Sendable {
    public var column: String
    public var ascending: Bool

    public init(column: String = "", ascending: Bool = true) {
        self.column = column
        self.ascending = ascending
    }
}

public struct ColumnComparator<Row>: SortComparator {
    public let column: String
    public var order: SortOrder

    public init(column: String, order: SortOrder = .forward) {
        self.column = column
        self.order = order
    }

    public func compare(_ lhs: Row, _ rhs: Row) -> ComparisonResult { .orderedSame }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.column == rhs.column && lhs.order == rhs.order
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(column)
        hasher.combine(order)
    }
}

public struct SortableColumn<Row>: Identifiable {
    public let id: String
    public let title: String
    public let ideal: CGFloat
    public let least: CGFloat
    public let hidden: Bool
    public let fixed: Bool
    public let value: @Sendable (Row) -> SortValue
    public let cell: @MainActor (Row) -> AnyView

    public init(id: String, title: String, ideal: CGFloat, least: CGFloat,
                hidden: Bool = false, fixed: Bool = false,
                value: @escaping @Sendable (Row) -> SortValue,
                @ViewBuilder cell: @escaping @MainActor (Row) -> some View) {
        self.id = id
        self.title = title
        self.ideal = ideal
        self.least = least
        self.hidden = hidden
        self.fixed = fixed
        self.value = value
        self.cell = { AnyView(cell($0)) }
    }

    public static func text(id: String, title: String, ideal: CGFloat, least: CGFloat, hidden: Bool = false,
                            value: @escaping @Sendable (Row) -> String) -> SortableColumn<Row> {
        SortableColumn(id: id, title: title, ideal: ideal, least: least, hidden: hidden,
                       value: { .text(value($0)) }) { row in
            Text(value(row)).lineLimit(1).truncationMode(.tail).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    public static func number(id: String, title: String, ideal: CGFloat, least: CGFloat, hidden: Bool = false,
                              format: @escaping @Sendable (Double?) -> String,
                              value: @escaping @Sendable (Row) -> Double?) -> SortableColumn<Row> {
        SortableColumn(id: id, title: title, ideal: ideal, least: least, hidden: hidden,
                       value: { value($0).map { SortValue.number($0) } ?? .none }) { row in
            Text(format(value(row))).lineLimit(1).monospacedDigit().frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    public static func date(id: String, title: String, ideal: CGFloat, least: CGFloat, hidden: Bool = false,
                            format: @escaping @Sendable (Date?) -> String,
                            value: @escaping @Sendable (Row) -> Date?) -> SortableColumn<Row> {
        SortableColumn(id: id, title: title, ideal: ideal, least: least, hidden: hidden,
                       value: { value($0).map { SortValue.date($0) } ?? .none }) { row in
            Text(format(value(row))).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
