import AppKit
import SwiftUI

public struct SortableTable<Row: Identifiable, Menu: View>: View {
    private let rows: [Row]
    private let columns: [SortableColumn<Row>]
    private let style: TableStyling
    private let primary: (Row) -> Void
    private let menu: (Row) -> Menu
    @Binding private var sort: SortState
    @Binding private var layout: TableColumnCustomization<Row>
    @Binding private var selection: Row.ID?

    public init(_ rows: [Row], columns: [SortableColumn<Row>], sort: Binding<SortState>,
                layout: Binding<TableColumnCustomization<Row>>, selection: Binding<Row.ID?>,
                style: TableStyling = TableStyling(),
                primary: @escaping (Row) -> Void,
                @ViewBuilder menu: @escaping (Row) -> Menu) {
        self.rows = rows
        self.columns = columns
        self.style = style
        self.primary = primary
        self.menu = menu
        _sort = sort
        _layout = layout
        _selection = selection
    }

    public var body: some View {
        Table(rows, selection: $selection, sortOrder: order, columnCustomization: $layout) {
            TableColumnForEach(columns) { column in
                TableColumn(column.title, sortUsing: ColumnComparator<Row>(column: column.id)) { row in
                    column.cell(row)
                }
                .width(min: column.least, ideal: column.ideal)
                .customizationID(column.id)
                .defaultVisibility(column.hidden ? .hidden : .visible)
                .disabledCustomizationBehavior(column.fixed ? .all : [])
            }
        }
        .tableStyle(.inset(alternatesRowBackgrounds: false))
        .scrollContentBackground(.hidden)
        .contextMenu(forSelectionType: Row.ID.self) { ids in
            if let row = pick(ids) { menu(row) }
        } primaryAction: { ids in
            if let row = pick(ids) { primary(row) }
        }
        .background(TableBridge(style: style, label: label, onReturn: fire))
    }

    private func pick(_ ids: Set<Row.ID>) -> Row? {
        guard let id = ids.first ?? selection else { return nil }
        return rows.first { $0.id == id }
    }

    private func fire(_ index: Int) {
        guard rows.indices.contains(index) else { return }
        primary(rows[index])
    }

    private func label(_ index: Int) -> String? {
        guard rows.indices.contains(index), let first = columns.first(where: { !$0.fixed }) else { return nil }
        return first.value(rows[index]).label
    }

    private var order: Binding<[ColumnComparator<Row>]> {
        Binding {
            let chosen = columns.first { $0.id == sort.column } ?? columns.first
            guard let chosen else { return [] }
            return [ColumnComparator(column: chosen.id, order: sort.ascending ? .forward : .reverse)]
        } set: { fresh in
            guard let first = fresh.first else { return }
            let next = SortState(column: first.column, ascending: first.order == .forward)
            guard next != sort else { return }
            var instant = Transaction()
            instant.disablesAnimations = true
            withTransaction(instant) { sort = next }
        }
    }
}

public struct TableStyling: Sendable {
    public var rowHeight: CGFloat
    public var headerFont: String
    public var headerSize: CGFloat
    public var headerOpacity: Double

    public init(rowHeight: CGFloat = 24, headerFont: String = "", headerSize: CGFloat = 11.5,
                headerOpacity: Double = 0.55) {
        self.rowHeight = rowHeight
        self.headerFont = headerFont
        self.headerSize = headerSize
        self.headerOpacity = headerOpacity
    }
}

private struct TableBridge: NSViewRepresentable {
    let style: TableStyling
    let label: (Int) -> String?
    let onReturn: (Int) -> Void

    @MainActor final class Coordinator {
        weak var table: NSTableView?
        var proxy: TypeSelect?
        var monitor: Any?
        var columns = 0
        var onReturn: (Int) -> Void = { _ in }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        view.isHidden = true
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        let box = context.coordinator
        box.onReturn = onReturn
        box.proxy?.label = label
        guard box.table == nil || box.table?.numberOfColumns != box.columns else { return }
        DispatchQueue.main.async { attach(view, box) }
    }

    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        MainActor.assumeIsolated {
            if let monitor = coordinator.monitor { NSEvent.removeMonitor(monitor) }
            coordinator.monitor = nil
        }
    }

    @MainActor private func attach(_ view: NSView, _ box: Coordinator) {
        if box.table == nil {
            guard let root = view.window?.contentView, let found = search(root) else { return }
            box.table = found
            let proxy = TypeSelect()
            proxy.target = found.delegate
            proxy.label = label
            box.proxy = proxy
            found.delegate = proxy
            box.monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak box] event in
                guard event.keyCode == 36, let table = box?.table,
                      let window = table.window, window.isKeyWindow,
                      let responder = window.firstResponder as? NSView,
                      responder === table || responder.isDescendant(of: table) else { return event }
                let row = table.selectedRow
                guard row >= 0 else { return event }
                box?.onReturn(row)
                return nil
            }
        }
        guard let table = box.table else { return }
        box.columns = table.numberOfColumns
        paint(table)
    }

    @MainActor private func search(_ view: NSView) -> NSTableView? {
        if let table = view as? NSTableView { return table }
        for child in view.subviews { if let found = search(child) { return found } }
        return nil
    }

    @MainActor private func paint(_ table: NSTableView) {
        table.backgroundColor = .clear
        table.usesAutomaticRowHeights = false
        table.rowHeight = style.rowHeight
        table.gridStyleMask = []
        table.usesAlternatingRowBackgroundColors = false
        table.style = .inset
        table.enclosingScrollView?.drawsBackground = false
        if let header = table.headerView, !header.wantsLayer {
            header.wantsLayer = true
            header.layer?.backgroundColor = NSColor.clear.cgColor
        }
        let font = NSFont(name: style.headerFont, size: style.headerSize)
            ?? NSFont.systemFont(ofSize: style.headerSize, weight: .medium)
        let colour = NSColor.white.withAlphaComponent(style.headerOpacity)
        for column in table.tableColumns {
            column.headerCell.drawsBackground = false
            column.headerCell.textColor = colour
            column.headerCell.font = font
        }
    }
}

@MainActor private final class TypeSelect: NSObject, NSTableViewDelegate {
    nonisolated(unsafe) weak var target: (any NSTableViewDelegate)?
    var label: (Int) -> String? = { _ in nil }

    func tableView(_ tableView: NSTableView, typeSelectStringFor tableColumn: NSTableColumn?, row: Int) -> String? {
        label(row)
    }

    override func responds(to selector: Selector!) -> Bool {
        super.responds(to: selector) || (target?.responds(to: selector) ?? false)
    }

    override func forwardingTarget(for selector: Selector!) -> Any? { target }
}
