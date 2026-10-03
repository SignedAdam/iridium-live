import AppKit
import SwiftUI

@MainActor
enum ModelsPanel {
    private static var open: NSPanel?

    static func show(on screen: NSScreen, model: AppModel) {
        if let open {
            open.makeKeyAndOrderFront(nil)
            return
        }
        let size = NSSize(width: 1160, height: 680)
        let area = screen.visibleFrame
        let panel = ModelsKeyPanel(contentRect: NSRect(x: (area.midX - size.width / 2).rounded(),
                                                       y: (area.midY - size.height / 2).rounded(),
                                                       width: size.width, height: size.height),
                                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = true
        let host = NSHostingView(rootView: ModelsView(model: model, close: close)
            .frame(width: size.width, height: size.height))
        host.sizingOptions = []
        panel.contentView = host
        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)
        panel.animator().alphaValue = model.settings.controlOpacity
        open = panel
    }

    static func close() {
        open?.orderOut(nil)
        open = nil
    }
}

private final class ModelsKeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor @Observable
final class CatalogStore {
    var catalog: Catalog?
    var credits: Credits?
    var loading = false
    var done = 0
    var total = 0
    var failure: String?

    private var client: OpenRouterClient?
    private var started = false

    static let cacheURL = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Library/Application Support/Iridium Live/openrouter-catalog.json")

    private let cache = CatalogCache(url: CatalogStore.cacheURL)

    func open() {
        guard !started else { return }
        started = true
        let keys = Keychain.shared
        let file = cache
        Task {
            let found = await Task.detached { (keys.values()["openrouter"], file.load()) }.value
            let client = OpenRouterClient(apiKey: found.0)
            self.client = client
            catalog = found.1
            if let stored = found.1, stored.age <= 3600 {
                credits = try? await client.credits()
            } else {
                refresh()
            }
        }
    }

    func refresh() {
        guard !loading, let client else { return }
        loading = true
        done = 0
        total = 0
        failure = nil
        Task {
            do {
                let fresh = try await client.catalog(filter: ModelFilter(outputModalities: ["text"])) { done, total in
                    guard done % 5 == 0 || done == total else { return }
                    Task { @MainActor in
                        self.done = done
                        self.total = total
                    }
                }
                catalog = fresh
                try? cache.save(fresh)
                credits = try? await client.credits()
            } catch {
                failure = "Could not load models"
            }
            loading = false
        }
    }
}

private struct EndpointRow: Identifiable {
    let endpoint: CatalogEndpoint
    let released: Date?

    var id: String { endpoint.id }
}

private struct SavedRow: Identifiable {
    var id: String
    var name: String
    var saved: SavedModel?
    var current = false
    var latency: Double?
    var throughput: Double?
    var input: Double?
    var output: Double?
    var context: Double?
    var uptime: Double?
    var children: [SavedRow]?
}

enum ModelsTab: String, CaseIterable {
    case provider = "Provider models"
    case mine = "My models"
}

struct ModelsView: View {
    let model: AppModel
    let close: () -> Void
    @State private var store = CatalogStore()
    @State private var tab: ModelsTab
    @State private var search = ""
    @State private var bestOnly = false
    @State private var sort = SortState(column: "latency", ascending: true)
    @State private var mineSort = SortState(column: "name", ascending: true)
    @State private var collapsed: Set<String> = []

    init(model: AppModel, close: @escaping () -> Void, tab: ModelsTab = .provider) {
        self.model = model
        self.close = close
        _tab = State(initialValue: tab)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if tab == .provider { toolbar }
            Divider().overlay(.white.opacity(0.08))
            table
        }
        .background(Glass(cornerRadius: 18, tint: model.settings.glassTint))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .padding(10)
        .shadow(color: .black.opacity(0.35), radius: 14, y: 6)
        .font(tiktok(12))
        .foregroundStyle(.white.opacity(0.88))
        .onAppear { store.open() }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Text("Models")
                .font(tiktok(16, "Medium"))
                .foregroundStyle(.white.opacity(0.95))
            Segments(selection: $tab, options: ModelsTab.allCases.map { ($0, $0.rawValue) })
            Spacer(minLength: 0)
            Button("Done", action: close)
                .buttonStyle(GlassButton())
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 14)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.45))
                TextField("Search", text: $search)
                    .textFieldStyle(.plain)
                    .font(tiktok(13))
            }
            .padding(.horizontal, 10)
            .frame(width: 240, height: 28)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(.white.opacity(0.08)))
            Text("Best provider per model")
            GlassSwitch(isOn: $bestOnly)
            Spacer(minLength: 0)
            ModelsStatus(store: store)
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 10)
    }

    @ViewBuilder private var table: some View {
        switch tab {
        case .provider:
            SortableTable(endpointRows, columns: endpointColumns, sort: $sort)
                .modifier(TableLook())
        case .mine:
            let rows = savedRows
            SortableTable(rows, children: \.children, columns: savedColumns, sort: $mineSort,
                          expanded: expansion(rows))
                .modifier(TableLook())
        }
    }

    private var endpointRows: [EndpointRow] {
        guard let catalog = store.catalog else { return [] }
        let filter = ModelFilter(search: search, outputModalities: ["text"], needsLatency: true)
        let models = catalog.modelsByID
        var kept = catalog.endpoints.filter { filter.matches($0, model: models[$0.modelID]) }
        if bestOnly { kept = kept.best(by: metric) }
        return kept.map { EndpointRow(endpoint: $0, released: models[$0.modelID]?.created) }
    }

    private var metric: EndpointMetric {
        switch sort.column {
        case "throughput": .throughput
        case "input": .inputPrice
        case "output": .outputPrice
        case "uptime": .uptime
        case "context": .context
        default: .latency
        }
    }

    private var endpointColumns: [SortableColumn<EndpointRow>] {
        let saved = Set(model.settings.openRouterModels.map(\.id))
        return [
            .custom(id: "model", title: "Model", width: 180, minWidth: 120,
                    value: { .text($0.endpoint.modelShortName) }) { row in
                Text(row.endpoint.modelShortName)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .help(row.endpoint.modelName)
            },
            .custom(id: "provider", title: "Provider", width: 106, minWidth: 80,
                    value: { .text($0.endpoint.providerName) }) { row in
                Text(row.endpoint.providerName)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .help(row.endpoint.providerName)
            },
            .number(id: "latency", title: "Latency ms", width: 94, minWidth: 94, maxWidth: 94, format: whole) { $0.endpoint.latency.p50 },
            .number(id: "throughput", title: "Tokens/s", width: 70, minWidth: 70, maxWidth: 70, format: whole) { $0.endpoint.throughput.p50 },
            .number(id: "input", title: "Input $/M", width: 72, minWidth: 72, maxWidth: 72, format: money) { $0.endpoint.inputPrice },
            .number(id: "output", title: "Output $/M", width: 80, minWidth: 80, maxWidth: 80, format: money) { $0.endpoint.outputPrice },
            .number(id: "context", title: "Context", width: 60, minWidth: 60, maxWidth: 60, format: tokens) { $0.endpoint.contextLength.map(Double.init) },
            .number(id: "uptime", title: "Uptime 30 min", width: 92, minWidth: 92, maxWidth: 92, format: percent) { $0.endpoint.uptime30m },
            .text(id: "quantization", title: "Quantization", width: 90, minWidth: 90, maxWidth: 90) { $0.endpoint.quantization ?? "" },
            .date(id: "released", title: "Released", width: 78, minWidth: 78, maxWidth: 78, format: day) { $0.released },
            .custom(id: "save", title: "", width: 26, minWidth: 26, maxWidth: 26) { row in
                SaveButton(kept: saved.contains(row.endpoint.savedID)) {
                    model.save(SavedModel(modelID: row.endpoint.modelID, modelName: row.endpoint.modelName,
                                          providerName: row.endpoint.providerName, tag: row.endpoint.tag))
                }
            },
        ]
    }

    private var savedRows: [SavedRow] {
        let current = model.settings.cleanupModels["openrouter"]
        let endpoints = store.catalog?.endpoints ?? []
        let stats = Dictionary(endpoints.map { ($0.savedID, $0) }, uniquingKeysWith: { first, _ in first })
        let groups = Dictionary(grouping: model.settings.openRouterModels, by: \.modelID)
        return groups.keys.sorted().map { modelID in
            let saved = groups[modelID] ?? []
            let children = saved.map { entry -> SavedRow in
                let found = stats[entry.id]
                return SavedRow(id: entry.id, name: entry.providerName, saved: entry, current: entry.id == current,
                                latency: found?.latency.p50, throughput: found?.throughput.p50,
                                input: found?.inputPrice, output: found?.outputPrice,
                                context: found?.contextLength.map(Double.init), uptime: found?.uptime30m)
            }
            return SavedRow(id: modelID, name: saved.first?.shortName ?? modelID, saved: nil,
                            current: children.contains { $0.current },
                            latency: children.compactMap(\.latency).min(),
                            throughput: children.compactMap(\.throughput).max(),
                            input: children.compactMap(\.input).min(),
                            output: children.compactMap(\.output).min(),
                            context: children.compactMap(\.context).max(),
                            uptime: children.compactMap(\.uptime).max(),
                            children: children)
        }
    }

    private var savedColumns: [SortableColumn<SavedRow>] {
        [
            .custom(id: "name", title: "Model", width: 240, value: { .text($0.name) }) { row in
                HStack(spacing: 6) {
                    Text(row.name).lineLimit(1)
                    if row.current {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(accent)
                    }
                    Spacer(minLength: 0)
                }
            },
            number("latency", "Latency ms", 80, whole) { $0.latency },
            number("throughput", "Tokens/s", 70, whole) { $0.throughput },
            number("input", "Input $/M", 72, money) { $0.input },
            number("output", "Output $/M", 78, money) { $0.output },
            number("context", "Context", 60, tokens) { $0.context },
            number("uptime", "Uptime 30 min", 96, percent) { $0.uptime },
            .custom(id: "use", title: "", width: 108) { row in
                HStack(spacing: 6) {
                    if let saved = row.saved {
                        if row.current {
                            Text("In use")
                                .font(tiktok(11))
                                .foregroundStyle(.white.opacity(0.5))
                        } else {
                            Button("Use") { model.use(saved) }
                                .buttonStyle(GlassButton())
                        }
                        RowIcon(symbol: "trash") { model.removeSaved(saved.id) }
                    }
                    Spacer(minLength: 0)
                }
            },
        ]
    }

    private func number(_ id: String, _ title: String, _ width: CGFloat,
                        _ format: @escaping @Sendable (Double?) -> String,
                        _ value: @escaping @Sendable (SavedRow) -> Double?) -> SortableColumn<SavedRow> {
        .custom(id: id, title: title, width: width, minWidth: width, maxWidth: width,
                value: { value($0).map { SortValue.number($0) } ?? .none }) { row in
            Text(row.children == nil ? format(value(row)) : "")
                .monospacedDigit()
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    private func expansion(_ rows: [SavedRow]) -> Binding<Set<String>> {
        let ids = Set(rows.map(\.id))
        return Binding {
            ids.subtracting(collapsed)
        } set: { open in
            collapsed = ids.subtracting(open)
        }
    }
}

private struct ModelsStatus: View {
    let store: CatalogStore

    var body: some View {
        HStack(spacing: 10) {
            Text(status)
                .font(tiktok(11.5))
                .foregroundStyle(.white.opacity(0.5))
            if let credits = store.credits {
                Text(money(credits.left) + " left")
                    .font(tiktok(11.5))
                    .foregroundStyle(.white.opacity(0.5))
            }
            RowIcon(symbol: "arrow.clockwise") { store.refresh() }
                .disabled(store.loading)
        }
    }

    private var status: String {
        if let failure = store.failure { return failure }
        if store.loading {
            return store.total > 0 ? "Loading \(store.done) of \(store.total)" : "Loading"
        }
        guard let fetched = store.catalog?.fetched else { return "No models yet" }
        return "Updated " + ago(Date().timeIntervalSince(fetched))
    }
}

private struct SaveButton: View {
    let kept: Bool
    let save: () -> Void

    var body: some View {
        Button(action: save) {
            Image(systemName: kept ? "checkmark.circle.fill" : "plus")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(kept ? accent : .white.opacity(0.7))
                .frame(width: 24, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(kept)
    }
}

private struct RowIcon: View {
    let symbol: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(hovering ? 0.95 : 0.5))
                .frame(width: 20, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

private struct TableLook: ViewModifier {
    func body(content: Content) -> some View {
        content
            .tableStyle(.inset(alternatesRowBackgrounds: false))
            .scrollContentBackground(.hidden)
            .font(tiktok(12))
            .foregroundStyle(.white.opacity(0.88))
            .background(TableSkin())
    }
}

private struct TableSkin: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.isHidden = true
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async {
            guard let root = view.window?.contentView else { return }
            paint(root)
        }
    }

    private func paint(_ view: NSView) {
        if let table = view as? NSTableView {
            if table.backgroundColor != .clear { table.backgroundColor = .clear }
            if table.usesAutomaticRowHeights { table.usesAutomaticRowHeights = false }
            if table.rowHeight != 24 { table.rowHeight = 24 }
            if table.gridStyleMask != [] { table.gridStyleMask = [] }
            if table.enclosingScrollView?.drawsBackground == true { table.enclosingScrollView?.drawsBackground = false }
            if table.usesAlternatingRowBackgroundColors { table.usesAlternatingRowBackgroundColors = false }
            if let header = table.headerView, !header.wantsLayer {
                header.wantsLayer = true
                header.layer?.backgroundColor = NSColor.clear.cgColor
            }
            let font = NSFont(name: "TikTokSans-Medium", size: 11.5)
            let colour = NSColor.white.withAlphaComponent(0.45)
            for column in table.tableColumns where column.headerCell.font != font || column.headerCell.textColor != colour {
                column.headerCell.drawsBackground = false
                column.headerCell.textColor = colour
                if let font { column.headerCell.font = font }
            }
        }
        for child in view.subviews { paint(child) }
    }
}

@Sendable private func whole(_ value: Double?) -> String {
    guard let value else { return "" }
    return String(format: "%.0f", value)
}

@Sendable private func money(_ value: Double?) -> String {
    guard let value else { return "" }
    if value == 0 { return "free" }
    return value < 0.1 ? String(format: "$%.3f", value) : String(format: "$%.2f", value)
}

private func money(_ value: Double) -> String {
    String(format: "$%.2f", value)
}

@Sendable private func tokens(_ value: Double?) -> String {
    guard let value else { return "" }
    if value >= 1_000_000 { return String(format: "%.1fM", value / 1_000_000) }
    if value >= 1000 { return String(format: "%.0fk", value / 1000) }
    return String(format: "%.0f", value)
}

@Sendable private func percent(_ value: Double?) -> String {
    guard let value else { return "" }
    return String(format: "%.0f%%", value)
}

private let dayFormat: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "d MMM yy"
    return formatter
}()

@Sendable private func day(_ value: Date?) -> String {
    guard let value else { return "" }
    return dayFormat.string(from: value)
}

private func ago(_ seconds: TimeInterval) -> String {
    if seconds < 90 { return "just now" }
    if seconds < 3600 { return "\(Int(seconds / 60)) min ago" }
    if seconds < 86400 {
        let hours = Int(seconds / 3600)
        return hours == 1 ? "1 hour ago" : "\(hours) hours ago"
    }
    let days = Int(seconds / 86400)
    return days == 1 ? "1 day ago" : "\(days) days ago"
}
