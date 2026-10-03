import SwiftUI

public struct SortableTable<Row: Identifiable>: View {
    private let rows: [Row]
    private let children: WritableKeyPath<Row, [Row]?>?
    private let columns: [SortableColumn<Row>]
    @Binding private var sort: SortState
    private let selection: Binding<Set<Row.ID>>?
    private let expanded: Binding<Set<Row.ID>>?
    @State private var opened: Set<Row.ID> = []

    public init(_ rows: [Row], columns: [SortableColumn<Row>], sort: Binding<SortState>,
                selection: Binding<Set<Row.ID>>? = nil) {
        self.rows = rows
        self.children = nil
        self.columns = columns
        self._sort = sort
        self.selection = selection
        self.expanded = nil
    }

    public init(_ rows: [Row], children: WritableKeyPath<Row, [Row]?>, columns: [SortableColumn<Row>],
                sort: Binding<SortState>, selection: Binding<Set<Row.ID>>? = nil,
                expanded: Binding<Set<Row.ID>>? = nil) {
        self.rows = rows
        self.children = children
        self.columns = columns
        self._sort = sort
        self.selection = selection
        self.expanded = expanded
    }

    public var body: some View {
        let ordered = sorted(rows)
        if children == nil {
            Table(ordered, selection: picked, sortOrder: order) { content(parents: []) }
        } else {
            Table(flattened(ordered), selection: picked, sortOrder: order) {
                content(parents: Set(ordered.map(\.id)))
            }
        }
    }

    @TableColumnBuilder<Row, ColumnComparator<Row>>
    private func content(parents: Set<Row.ID>) -> some TableColumnContent<Row, ColumnComparator<Row>> {
        let first = columns.first?.id
        TableColumnForEach(columns) { column in
            TableColumn(column.title, sortUsing: comparator(column, order: .forward)) { row in
                if children != nil, column.id == first {
                    HStack(spacing: 2) {
                        knob(row, parent: parents.contains(row.id))
                        column.cell(row)
                    }
                } else {
                    column.cell(row)
                }
            }
            .width(min: column.minWidth, ideal: column.width, max: column.maxWidth)
        }
    }

    @ViewBuilder
    private func knob(_ row: Row, parent: Bool) -> some View {
        if parent, let children, let kids = row[keyPath: children], !kids.isEmpty {
            let open = isOpen(row.id)
            Button {
                setOpen(row.id, !open)
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .rotationEffect(.degrees(open ? 90 : 0))
                    .frame(width: 14, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        } else {
            Color.clear.frame(width: parent ? 14 : 26, height: 1)
        }
    }

    private var chosen: SortableColumn<Row>? {
        columns.first { $0.id == sort.column } ?? columns.first
    }

    private func comparator(_ column: SortableColumn<Row>, order: SortOrder) -> ColumnComparator<Row> {
        ColumnComparator(column: column.id, order: order, value: column.value)
    }

    private var order: Binding<[ColumnComparator<Row>]> {
        Binding {
            guard let chosen else { return [] }
            return [comparator(chosen, order: sort.ascending ? .forward : .reverse)]
        } set: { fresh in
            guard let first = fresh.first else { return }
            let next = SortState(column: first.column, ascending: first.order == .forward)
            if next != sort { sort = next }
        }
    }

    private var picked: Binding<Set<Row.ID>> {
        selection ?? .constant([])
    }

    private func isOpen(_ id: Row.ID) -> Bool {
        expanded?.wrappedValue.contains(id) ?? opened.contains(id)
    }

    private func setOpen(_ id: Row.ID, _ open: Bool) {
        var ids = expanded?.wrappedValue ?? opened
        if open { ids.insert(id) } else { ids.remove(id) }
        if let expanded { expanded.wrappedValue = ids } else { opened = ids }
    }

    private func flattened(_ rows: [Row]) -> [Row] {
        guard let children else { return rows }
        var all: [Row] = []
        all.reserveCapacity(rows.count * 2)
        for row in rows {
            all.append(row)
            guard isOpen(row.id), let kids = row[keyPath: children] else { continue }
            all.append(contentsOf: flattened(kids))
        }
        return all
    }

    private func sorted(_ rows: [Row]) -> [Row] {
        guard let chosen else { return rows }
        let value = chosen.value
        let ascending = sort.ascending
        var ready = rows
        if let children {
            for index in ready.indices {
                if let kids = ready[index][keyPath: children] {
                    ready[index][keyPath: children] = sorted(kids)
                }
            }
        }
        return ready.enumerated().sorted { one, other in
            switch SortValue.compare(value(one.element), value(other.element), ascending: ascending) {
            case .orderedAscending: true
            case .orderedDescending: false
            case .orderedSame: one.offset < other.offset
            }
        }.map(\.element)
    }
}
