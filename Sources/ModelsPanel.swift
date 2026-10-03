import AppKit
import SwiftUI

@MainActor
enum ModelsPanel {
    private static var open: NSWindow?
    private static var keeper: ModelsWindowDelegate?

    static func show(on screen: NSScreen, model: AppModel) {
        if let open {
            NSApp.activate(ignoringOtherApps: true)
            open.makeKeyAndOrderFront(nil)
            return
        }
        let size = NSSize(width: 1290, height: 720)
        let area = screen.visibleFrame
        let window = ModelsWindow(contentRect: NSRect(x: (area.midX - size.width / 2).rounded(),
                                                      y: (area.midY - size.height / 2).rounded(),
                                                      width: size.width, height: size.height),
                                  styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                                  backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.title = "Models"
        window.isOpaque = false
        window.backgroundColor = .clear
        window.isMovableByWindowBackground = true
        window.appearance = NSAppearance(named: .darkAqua)
        window.minSize = NSSize(width: 820, height: 500)
        window.collectionBehavior = [.fullScreenNone]
        if !window.setFrameUsingName(frameName) { window.setFrame(window.frame, display: false) }
        window.setFrameAutosaveName(frameName)
        let store = CatalogStore(sort: Remembered.sort())
        store.open()
        let host = NSHostingView(rootView: ModelsView(model: model, store: store))
        host.sizingOptions = []
        window.contentView = host
        let delegate = ModelsWindowDelegate()
        window.delegate = delegate
        keeper = delegate
        open = window

        let target = window.frame
        window.setFrame(target.offsetBy(dx: 0, dy: -8), display: false)
        window.alphaValue = 0
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            window.animator().alphaValue = model.settings.controlOpacity
            window.animator().setFrame(target, display: true)
        }
    }

    static func close() {
        open?.delegate = nil
        open?.close()
        open = nil
        keeper = nil
    }

    static func fadeOut(_ window: NSWindow) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            window.animator().alphaValue = 0
        } completionHandler: {
            MainActor.assumeIsolated { close() }
        }
    }

    static let frameName = "IridiumModelsWindow"
}

private final class ModelsWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func cancelOperation(_ sender: Any?) {
        performClose(nil)
    }
}

private final class ModelsWindowDelegate: NSObject, NSWindowDelegate {
    private var leaving = false

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard !leaving else { return true }
        leaving = true
        ModelsPanel.fadeOut(sender)
        return false
    }
}

struct EndpointRow: Identifiable, Sendable {
    let id: String
    let savedID: String
    let modelID: String
    let name: String
    let fullName: String
    let maker: Brand
    let provider: Brand
    let providerName: String
    let tag: String
    let latency: Double?
    let latency90: Double?
    let throughput: Double?
    let input: Double?
    let output: Double?
    let cacheRead: Double?
    let context: Double?
    let maxOutput: Double?
    let json: Bool
    let tools: Bool
    let uptime30m: Double?
    let uptime1d: Double?
    let quantization: String
    let released: Date?
    let haystack: String
}

@MainActor @Observable
final class CatalogStore {
    private(set) var rows: [EndpointRow] = []
    private(set) var loaded = false
    private(set) var makers: [Brand] = []
    private(set) var latencyBySaved: [String: Double] = [:]
    private(set) var fetched: Date?
    private(set) var search = ""
    private(set) var maker: String?
    private(set) var bestOnly = false
    private(set) var sort = SortState(column: "latency", ascending: true)
    var credits: Credits?
    var loading = false
    var done = 0
    var total = 0
    var failure: String?

    private var all: [EndpointRow] = []
    private var client: OpenRouterClient?
    private var started = false
    private var pending: [(String, Bool)] = []

    static let cacheURL = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Library/Application Support/Iridium Live/openrouter-catalog.json")

    private let cache = CatalogCache(url: CatalogStore.cacheURL)

    init(sort: SortState) {
        self.sort = sort
    }

    func open() {
        guard !started else { return }
        started = true
        let keys = Keychain.shared
        let file = cache
        let disk = Task.detached(priority: .userInitiated) { file.load() }
        let unlock = Task.detached(priority: .userInitiated) { keys.values()["openrouter"] }
        Task {
            let stored = await disk.value
            if let stored { accept(stored) }
            let client = OpenRouterClient(apiKey: await unlock.value)
            self.client = client
            Task { self.credits = try? await client.credits() }
            if stored == nil || stored!.age > 21600 { refresh() }
        }
    }

    func refresh() {
        guard !loading, let client else { return }
        loading = true
        done = 0
        total = 0
        failure = nil
        let file = cache
        Task {
            do {
                let fresh = try await client.catalog(filter: ModelFilter(outputModalities: ["text"])) { done, total in
                    guard done % 10 == 0 || done == total else { return }
                    Task { @MainActor in
                        self.done = done
                        self.total = total
                    }
                }
                accept(fresh)
                Task.detached(priority: .utility) { try? file.save(fresh) }
                credits = try? await client.credits()
            } catch {
                failure = "Could not load models"
            }
            loading = false
        }
    }

    func setSearch(_ text: String) {
        guard text != search else { return }
        search = text
        rebuild()
    }

    func setMaker(_ slug: String?) {
        guard slug != maker else { return }
        maker = slug
        rebuild()
    }

    func setBestOnly(_ on: Bool) {
        guard on != bestOnly else { return }
        bestOnly = on
        rebuild()
    }

    func setSort(_ state: SortState) {
        guard state != sort else { return }
        sort = state
        rebuild()
    }

    private func accept(_ catalog: Catalog) {
        let models = catalog.modelsByID
        var built: [EndpointRow] = []
        built.reserveCapacity(catalog.endpoints.count)
        var latency: [String: Double] = [:]
        var seen: [String: Brand] = [:]
        for endpoint in catalog.endpoints {
            guard endpoint.latency.p50 != nil else { continue }
            let model = models[endpoint.modelID]
            let maker = Brand.maker(ofModel: endpoint.modelID)
            seen[maker.slug] = maker
            let name = endpoint.modelShortName
            let parameters = Set(endpoint.supportedParameters)
            built.append(EndpointRow(id: endpoint.id,
                                     savedID: endpoint.savedID,
                                     modelID: endpoint.modelID,
                                     name: name,
                                     fullName: endpoint.modelName,
                                     maker: maker,
                                     provider: Brand.provider(tag: endpoint.tag),
                                     providerName: endpoint.providerName,
                                     tag: endpoint.tag,
                                     latency: endpoint.latency.p50,
                                     latency90: endpoint.latency.p90,
                                     throughput: endpoint.throughput.p50,
                                     input: endpoint.inputPrice,
                                     output: endpoint.outputPrice,
                                     cacheRead: endpoint.cacheReadPrice,
                                     context: endpoint.contextLength.map(Double.init),
                                     maxOutput: endpoint.maxCompletionTokens.map(Double.init),
                                     json: parameters.contains("response_format"),
                                     tools: parameters.contains("tools"),
                                     uptime30m: endpoint.uptime30m,
                                     uptime1d: endpoint.uptime1d,
                                     quantization: endpoint.quantization == "unknown" ? "" : endpoint.quantization ?? "",
                                     released: model?.created,
                                     haystack: "\(endpoint.modelID) \(name) \(endpoint.providerName)".lowercased()))
            if let p50 = endpoint.latency.p50 { latency[endpoint.savedID] = p50 }
        }
        all = built
        latencyBySaved = latency
        makers = seen.values.sorted { $0.name.caseInsensitiveCompare($1.name) == .orderedAscending }
        fetched = catalog.fetched
        loaded = true
        rebuild()
    }

    private func rebuild() {
        let wanted = search.trimmingCharacters(in: .whitespaces).lowercased()
        let slug = maker
        var kept = all
        if !wanted.isEmpty || slug != nil {
            kept = all.filter { row in
                if let slug, row.maker.slug != slug { return false }
                return wanted.isEmpty || row.haystack.contains(wanted)
            }
        }
        if bestOnly { kept = pickBest(kept) }
        let column = sort.column
        let ascending = sort.ascending
        rows = kept.enumerated().sorted { one, other in
            switch SortValue.compare(sortValue(one.element, column), sortValue(other.element, column),
                                     ascending: ascending) {
            case .orderedAscending: return true
            case .orderedDescending: return false
            case .orderedSame: return one.offset < other.offset
            }
        }.map(\.element)
    }

    private func pickBest(_ rows: [EndpointRow]) -> [EndpointRow] {
        let lower = bestLower
        var picked: [String: EndpointRow] = [:]
        var order: [String] = []
        picked.reserveCapacity(rows.count)
        for row in rows {
            guard let standing = picked[row.modelID] else {
                picked[row.modelID] = row
                order.append(row.modelID)
                continue
            }
            guard let mine = bestValue(row) else { continue }
            guard let theirs = bestValue(standing) else {
                picked[row.modelID] = row
                continue
            }
            if lower ? mine < theirs : mine > theirs { picked[row.modelID] = row }
        }
        return order.compactMap { picked[$0] }
    }

    private var bestLower: Bool {
        switch sort.column {
        case "throughput", "context", "uptime30m", "uptime1d", "maxOutput": false
        default: true
        }
    }

    private func bestValue(_ row: EndpointRow) -> Double? {
        switch sort.column {
        case "throughput": row.throughput
        case "input": row.input
        case "output": row.output
        case "context": row.context
        case "uptime30m": row.uptime30m
        case "uptime1d": row.uptime1d
        case "maxOutput": row.maxOutput
        default: row.latency
        }
    }
}

private func sortValue(_ row: EndpointRow, _ column: String) -> SortValue {
    switch column {
    case "name": .text(row.name)
    case "provider": .text(row.providerName)
    case "latency90": row.latency90.map { SortValue.number($0) } ?? .none
    case "throughput": row.throughput.map { SortValue.number($0) } ?? .none
    case "input": row.input.map { SortValue.number($0) } ?? .none
    case "output": row.output.map { SortValue.number($0) } ?? .none
    case "cacheRead": row.cacheRead.map { SortValue.number($0) } ?? .none
    case "context": row.context.map { SortValue.number($0) } ?? .none
    case "maxOutput": row.maxOutput.map { SortValue.number($0) } ?? .none
    case "json": .number(row.json ? 1 : 0)
    case "tools": .number(row.tools ? 1 : 0)
    case "uptime30m": row.uptime30m.map { SortValue.number($0) } ?? .none
    case "uptime1d": row.uptime1d.map { SortValue.number($0) } ?? .none
    case "quantization": row.quantization.isEmpty ? .none : .text(row.quantization)
    case "released": row.released.map { SortValue.date($0) } ?? .none
    case "saved": .none
    default: row.latency.map { SortValue.number($0) } ?? .none
    }
}

private enum Remembered {
    static let sortKey = "models.sort"
    static let columnsKey = "models.columns"
    static let sidebarKey = "models.sidebar"

    static func sort() -> SortState {
        guard let data = UserDefaults.standard.data(forKey: sortKey),
              let found = try? JSONDecoder().decode(SortState.self, from: data) else {
            return SortState(column: "latency", ascending: true)
        }
        return found
    }

    static func store(sort: SortState) {
        guard let data = try? JSONEncoder().encode(sort) else { return }
        UserDefaults.standard.set(data, forKey: sortKey)
    }

    static func columns() -> TableColumnCustomization<EndpointRow> {
        guard let data = UserDefaults.standard.data(forKey: columnsKey),
              let found = try? JSONDecoder().decode(TableColumnCustomization<EndpointRow>.self, from: data) else {
            return TableColumnCustomization<EndpointRow>()
        }
        return found
    }

    static func store(columns: TableColumnCustomization<EndpointRow>) {
        guard let data = try? JSONEncoder().encode(columns) else { return }
        UserDefaults.standard.set(data, forKey: columnsKey)
    }
}

struct ModelsView: View {
    let model: AppModel
    @State private var store: CatalogStore
    @State private var typed = ""
    @State private var sidebar = !UserDefaults.standard.bool(forKey: Remembered.sidebarKey)
    @State private var selection: String?
    @State private var sort = Remembered.sort()
    @State private var columns = Remembered.columns()

    init(model: AppModel, store: CatalogStore) {
        self.model = model
        _store = State(initialValue: store)
    }

    var body: some View {
        ZStack {
            Glass(cornerRadius: 12, tint: model.settings.glassTint)
            VStack(spacing: 0) {
                titleBar
                line
                HStack(spacing: 0) {
                    if sidebar {
                        SidebarView(model: model, store: store)
                            .frame(width: 236)
                            .transition(.move(edge: .leading).combined(with: .opacity))
                        Rectangle().fill(.white.opacity(0.08)).frame(width: 1)
                    }
                    VStack(spacing: 0) {
                        toolbar
                        line
                        table
                    }
                }
            }
        }
        .ignoresSafeArea()
        .font(tiktok(12))
        .foregroundStyle(.white.opacity(0.88))
        .onAppear { store.open() }
        .onChange(of: sort) { _, fresh in
            store.setSort(fresh)
            Remembered.store(sort: fresh)
        }
        .onChange(of: columns) { _, fresh in Remembered.store(columns: fresh) }
        .task(id: typed) {
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            store.setSearch(typed)
        }
    }

    private var line: some View {
        Rectangle().fill(.white.opacity(0.08)).frame(height: 1)
    }

    private var titleBar: some View {
        HStack(spacing: 10) {
            Button {
                withAnimation(.easeOut(duration: 0.2)) { sidebar.toggle() }
                UserDefaults.standard.set(!sidebar, forKey: Remembered.sidebarKey)
            } label: {
                Image(systemName: "sidebar.left")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(sidebar ? 0.95 : 0.7))
                    .frame(width: 26, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(sidebar ? "Hide my models" : "Show my models")
            Text("Models")
                .font(tiktok(15, "Medium"))
                .foregroundStyle(.white.opacity(0.95))
            Spacer(minLength: 0)
        }
        .padding(.leading, 76)
        .padding(.trailing, 14)
        .frame(height: 40)
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.6))
                TextField("Search", text: $typed)
                    .textFieldStyle(.plain)
                    .font(tiktok(13))
                if !typed.isEmpty {
                    Button { typed = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.6))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .frame(width: 230, height: 28)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(.white.opacity(0.08)))
            makerMenu
            HStack(spacing: 8) {
                Text("Best provider per model").foregroundStyle(.white.opacity(0.8))
                GlassSwitch(isOn: Binding { store.bestOnly } set: { store.setBestOnly($0) })
            }
            Spacer(minLength: 0)
            status
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    private var makerMenu: some View {
        Menu {
            Button("All makers") { store.setMaker(nil) }
            Divider()
            ForEach(store.makers, id: \.slug) { maker in
                Button {
                    store.setMaker(maker.slug)
                } label: {
                    Label { Text(maker.name) } icon: { BrandMark(brand: maker, size: 14) }
                }
            }
        } label: {
            HStack(spacing: 6) {
                if let slug = store.maker, let found = store.makers.first(where: { $0.slug == slug }) {
                    BrandMark(brand: found, size: 14)
                    Text(found.name)
                } else {
                    Text("All makers")
                }
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
            }
            .foregroundStyle(.white.opacity(0.85))
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(.white.opacity(0.08)))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .fixedSize()
    }

    private var status: some View {
        HStack(spacing: 12) {
            if let credits = store.credits {
                Text(money(credits.left) + " left")
                    .font(tiktok(13, "Medium"))
                    .foregroundStyle(.white)
            }
            Text(progress)
                .font(tiktok(11.5))
                .foregroundStyle(.white.opacity(0.75))
            Button { store.refresh() } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(store.loading ? 0.35 : 0.8))
                    .frame(width: 22, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(store.loading)
            .help("Refresh the model list")
        }
    }

    private var progress: String {
        if let failure = store.failure { return failure }
        if store.loading { return store.total > 0 ? "Loading \(store.done) of \(store.total)" : "Loading" }
        guard let fetched = store.fetched else { return "No models yet" }
        return "Updated " + ago(Date().timeIntervalSince(fetched))
    }

    @ViewBuilder private var table: some View {
        if store.loaded {
            SortableTable(store.rows, columns: tableColumns, sort: $sort, layout: $columns,
                          selection: $selection,
                          style: TableStyling(rowHeight: 24, headerFont: "TikTokSans-Medium", headerOpacity: 0.75)) { row in
                use(row)
            } menu: { row in
                rowMenu(row)
            }
        } else {
            VStack {
                Text(store.failure ?? "Loading models")
                    .font(tiktok(12))
                    .foregroundStyle(.white.opacity(0.75))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder private func rowMenu(_ row: EndpointRow) -> some View {
        Button("Use") { use(row) }
        if model.settings.openRouterModels.contains(where: { $0.id == row.savedID }) {
            Button("Remove from My models") { remove(row.savedID) }
        } else {
            Button("Save to My models") { save(row) }
        }
        Divider()
        Button("Copy model ID") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(row.modelID, forType: .string)
        }
        Button("Open on OpenRouter") {
            guard let url = URL(string: "https://openrouter.ai/" + row.modelID) else { return }
            NSWorkspace.shared.open(url)
        }
    }

    private func saved(_ row: EndpointRow) -> SavedModel {
        SavedModel(modelID: row.modelID, modelName: row.fullName, providerName: row.providerName, tag: row.tag)
    }

    private func use(_ row: EndpointRow) {
        withAnimation(.easeOut(duration: 0.2)) { model.use(saved(row)) }
    }

    private func save(_ row: EndpointRow) {
        withAnimation(.easeOut(duration: 0.2)) { model.save(saved(row)) }
    }

    private func remove(_ id: String) {
        withAnimation(.easeOut(duration: 0.2)) { model.removeSaved(id) }
    }

    private var tableColumns: [SortableColumn<EndpointRow>] {
        [
            SortableColumn(id: "saved", title: "Saved", ideal: 44, least: 40, fixed: true,
                           value: { _ in .none }) { row in
                SavedStar(model: model, savedID: row.savedID) { keep in
                    if keep { save(row) } else { remove(row.savedID) }
                }
            },
            SortableColumn(id: "name", title: "Model", ideal: 182, least: 120,
                           value: { .text($0.name) }) { row in
                HStack(spacing: 7) {
                    BrandMark(brand: row.maker, size: 15)
                    Text(row.name)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .foregroundStyle(.white.opacity(0.92))
                    Spacer(minLength: 0)
                }
                .help(row.fullName)
            },
            SortableColumn(id: "provider", title: "Provider", ideal: 98, least: 80,
                           value: { .text($0.providerName) }) { row in
                HStack(spacing: 6) {
                    BrandMark(brand: row.provider, size: 13)
                    Text(row.providerName).lineLimit(1).truncationMode(.tail)
                    Spacer(minLength: 0)
                }
            },
            .number(id: "latency", title: "Latency ms", ideal: 94, least: 70, format: whole) { $0.latency },
            .number(id: "latency90", title: "Latency p90 ms", ideal: 96, least: 72, hidden: true, format: whole) { $0.latency90 },
            .number(id: "throughput", title: "Tokens/s", ideal: 70, least: 58, format: whole) { $0.throughput },
            .number(id: "input", title: "Input $/M", ideal: 76, least: 62, format: money) { $0.input },
            .number(id: "output", title: "Output $/M", ideal: 82, least: 62, format: money) { $0.output },
            .number(id: "cacheRead", title: "Cache read $/M", ideal: 100, least: 72, hidden: true, format: money) { $0.cacheRead },
            .number(id: "context", title: "Context", ideal: 62, least: 54, format: tokens) { $0.context },
            .number(id: "maxOutput", title: "Max output", ideal: 86, least: 64, hidden: true, format: tokens) { $0.maxOutput },
            .text(id: "json", title: "JSON output", ideal: 80, least: 66) { $0.json ? "Yes" : "" },
            .text(id: "tools", title: "Tools", ideal: 58, least: 50, hidden: true) { $0.tools ? "Yes" : "" },
            .number(id: "uptime30m", title: "Uptime 30 min", ideal: 92, least: 72, format: percent) { $0.uptime30m },
            .number(id: "uptime1d", title: "Uptime 1 day", ideal: 90, least: 70, hidden: true, format: percent) { $0.uptime1d },
            .text(id: "quantization", title: "Quantization", ideal: 78, least: 64) { $0.quantization },
            .date(id: "released", title: "Released", ideal: 74, least: 64, format: day) { $0.released },
        ]
    }
}

private struct SidebarView: View {
    let model: AppModel
    let store: CatalogStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("My models")
                .font(tiktok(12, "Medium"))
                .foregroundStyle(.white.opacity(0.75))
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
            Rectangle().fill(.white.opacity(0.08)).frame(height: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(groups, id: \.0) { modelID, entries in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 7) {
                                BrandMark(brand: Brand.maker(ofModel: modelID), size: 15)
                                Text(entries.first?.shortName ?? modelID)
                                    .font(tiktok(12, "Medium"))
                                    .foregroundStyle(.white.opacity(0.9))
                                    .lineLimit(1)
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 10)
                            ForEach(entries) { entry in
                                SavedLine(entry: entry,
                                          current: current == entry.id,
                                          latency: store.latencyBySaved[entry.id],
                                          use: { withAnimation(.easeOut(duration: 0.2)) { model.use(entry) } },
                                          remove: { withAnimation(.easeOut(duration: 0.2)) { model.removeSaved(entry.id) } })
                                    .transition(.opacity.combined(with: .move(edge: .leading)))
                            }
                        }
                        .transition(.opacity.combined(with: .move(edge: .leading)))
                    }
                    if groups.isEmpty {
                        Text("Save models with the star")
                            .font(tiktok(11.5))
                            .foregroundStyle(.white.opacity(0.75))
                            .padding(.horizontal, 14)
                    }
                }
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var current: String? { model.settings.cleanupModels["openrouter"] }

    private var groups: [(String, [SavedModel])] {
        var order: [String] = []
        var found: [String: [SavedModel]] = [:]
        for entry in model.settings.openRouterModels {
            if found[entry.modelID] == nil { order.append(entry.modelID) }
            found[entry.modelID, default: []].append(entry)
        }
        return order.map { ($0, found[$0] ?? []) }
    }
}

private struct SavedLine: View {
    let entry: SavedModel
    let current: Bool
    let latency: Double?
    let use: () -> Void
    let remove: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: use) {
            HStack(spacing: 6) {
                Circle()
                    .fill(current ? accent : .clear)
                    .frame(width: 5, height: 5)
                Text(entry.providerName)
                    .font(tiktok(11.5, current ? "Medium" : "Regular"))
                    .foregroundStyle(.white.opacity(current ? 1 : 0.75))
                    .lineLimit(1)
                Spacer(minLength: 4)
                if hovering {
                    Button(action: remove) {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.white.opacity(0.75))
                            .frame(width: 16, height: 16)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Remove from My models")
                } else if let latency {
                    Text(whole(latency) + " ms")
                        .font(tiktok(11))
                        .monospacedDigit()
                        .foregroundStyle(.white.opacity(0.75))
                }
            }
            .padding(.leading, 10)
            .padding(.trailing, 8)
            .frame(height: 22)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(current ? accent.opacity(0.18) : .white.opacity(hovering ? 0.07 : 0)))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(current ? accent.opacity(0.45) : .clear))
            .padding(.horizontal, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

private struct SavedStar: View {
    let model: AppModel
    let savedID: String
    let toggle: (Bool) -> Void
    @State private var hovering = false

    var body: some View {
        let kept = model.settings.openRouterModels.contains { $0.id == savedID }
        Button { toggle(!kept) } label: {
            Image(systemName: kept ? "star.fill" : "star")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(kept ? Color(red: 1, green: 0.78, blue: 0.22) : .white.opacity(hovering ? 0.9 : 0.45))
                .frame(maxWidth: .infinity, alignment: .center)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(kept ? "Remove from My models" : "Save to My models")
    }
}

struct BrandMark: View {
    let brand: Brand
    let size: CGFloat

    var body: some View {
        if let image = BrandIcons.image(brand.icon) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .frame(width: size, height: size)
        } else {
            let colour = Color(brand: brand)
            Text(brand.initials)
                .font(.system(size: size * 0.5, weight: .semibold))
                .foregroundStyle(colour)
                .frame(width: size, height: size)
                .background(RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
                    .fill(colour.opacity(0.2)))
        }
    }
}

extension Color {
    init(brand: Brand) {
        self.init(red: Double((brand.hex >> 16) & 0xFF) / 255,
                  green: Double((brand.hex >> 8) & 0xFF) / 255,
                  blue: Double(brand.hex & 0xFF) / 255)
    }
}

@MainActor
enum BrandIcons {
    private static var cache: [String: NSImage?] = [:]

    static func image(_ name: String?) -> NSImage? {
        guard let name else { return nil }
        if let found = cache[name] { return found }
        let url = Bundle.main.url(forResource: name, withExtension: "png", subdirectory: "Brands")
        let image = url.flatMap { NSImage(contentsOf: $0) }
        cache[name] = image
        return image
    }
}

@Sendable private func whole(_ value: Double?) -> String {
    guard let value else { return "" }
    return String(format: "%.0f", value)
}

private func whole(_ value: Double) -> String { String(format: "%.0f", value) }

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
        return hours == 1 ? "1 h ago" : "\(hours) h ago"
    }
    let days = Int(seconds / 86400)
    return days == 1 ? "1 day ago" : "\(days) days ago"
}
