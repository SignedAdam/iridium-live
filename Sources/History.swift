import AppKit
import SwiftUI

struct HistoryEntry: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    let time: Date
    var text: String
    var raw: String?
    var destination: String?
    var timing: PhraseTiming?
    var audio: [AudioRef]?
    var phrase: String?
    var session: Int?
    var polish: PolishRun?
    var benchmarks: [BenchmarkRun]?
}

extension HistoryEntry {
    var calls: [PhraseTiming.Cleanup] {
        [timing?.cleanup, polish?.cleanup].compactMap { $0 } + (benchmarks ?? []).map(\.cleanup)
    }

    var spend: Double { calls.reduce(0) { $0 + ($1.costUsd ?? 0) } }
}

struct AudioRef: Codable, Equatable, Sendable {
    let file: String
    let start: Double
    let end: Double

    init?(engine object: [String: Any]) {
        guard let file = object["file"] as? String, let start = object["start_s"] as? Double,
              let end = object["end_s"] as? Double else { return nil }
        self.file = file
        self.start = start
        self.end = end
    }
}

@MainActor
final class HistoryStore {
    private static let shown = 2000
    private let file: URL
    private let disk = DispatchQueue(label: "history.disk")

    init(directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        file = directory.appendingPathComponent("history.jsonl")
    }

    func load() -> [HistoryEntry] {
        guard let data = try? String(contentsOf: file, encoding: .utf8) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return data.split(separator: "\n").suffix(Self.shown)
            .compactMap { try? decoder.decode(HistoryEntry.self, from: Data($0.utf8)) }
    }

    func append(_ entry: HistoryEntry) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let json = try? encoder.encode(entry) else { return }
        let line = json + Data("\n".utf8)
        let file = self.file
        disk.async { @Sendable in
            guard let handle = try? FileHandle(forWritingTo: file) else {
                try? line.write(to: file, options: .atomic)
                return
            }
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: line)
        }
    }

    func delete(_ id: UUID) {
        let file = self.file
        disk.async { @Sendable in
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { return }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let kept = text.split(separator: "\n").filter { line in
                (try? decoder.decode(HistoryEntry.self, from: Data(line.utf8)))?.id != id
            }
            try? Data(kept.map { $0 + "\n" }.joined().utf8).write(to: file, options: .atomic)
        }
    }

    func update(_ entry: HistoryEntry) {
        let file = self.file
        disk.async { @Sendable in
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { return }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            guard let replacement = try? encoder.encode(entry) else { return }
            let line = String(decoding: replacement, as: UTF8.self)
            let lines = text.split(separator: "\n").map { old -> String in
                (try? decoder.decode(HistoryEntry.self, from: Data(old.utf8)))?.id == entry.id ? line : String(old)
            }
            try? Data(lines.map { $0 + "\n" }.joined().utf8).write(to: file, options: .atomic)
        }
    }

    func flush() {
        disk.sync {}
    }
}

struct HistoryPane: View {
    @Bindable var model: AppModel
    @State private var query = ""
    @State private var copied: UUID?
    @State private var open: UUID?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass").font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.45))
                TextField("Search", text: $query)
                    .textFieldStyle(.plain)
                    .font(tiktok(13))
            }
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(.white.opacity(0.08)))
            .padding(.horizontal, 14)
            .padding(.top, 14)
            .padding(.bottom, 6)

            if days.isEmpty {
                Text(model.history.isEmpty ? "No history yet." : "Nothing matches.")
                    .font(tiktok(13))
                    .foregroundStyle(.white.opacity(0.34))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(days, id: \.day) { group in
                            Section {
                                ForEach(group.entries) { entry in
                                    Row(entry: entry, copied: copied == entry.id, open: open == entry.id,
                                        retrying: model.retrying.contains(entry.id),
                                        toggle: { toggle(entry) }, copy: { copy(entry) }, delete: { delete(entry) },
                                        retry: { model.onRetryHistory(entry) }, addToNote: { model.onAddToNote(entry) })
                                }
                            } header: {
                                HStack {
                                    Text(group.title.uppercased()).kerning(0.8)
                                    Spacer()
                                    if group.cost > 0 { Text(dollars(group.cost)).monospacedDigit() }
                                }
                                .font(tiktok(10.5, "Medium"))
                                .foregroundStyle(.white.opacity(0.42))
                                .padding(.horizontal, 10)
                                .padding(.top, 10)
                                .padding(.bottom, 4)
                            }
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 10)
                }
                .scrollIndicators(.visible)
            }
        }
        .foregroundStyle(.white.opacity(0.9))
    }

    private var days: [(day: Date, title: String, entries: [HistoryEntry], cost: Double)] {
        let calendar = Calendar.current
        let matching = model.history.reversed().filter { query.isEmpty || $0.text.localizedCaseInsensitiveContains(query) }
        let grouped = Dictionary(grouping: matching) { calendar.startOfDay(for: $0.time) }
        return grouped.keys.sorted(by: >).map { day in
            let title = calendar.isDateInToday(day) ? "Today"
                : calendar.isDateInYesterday(day) ? "Yesterday"
                : day.formatted(.dateTime.weekday(.wide).day().month(.wide))
            let entries = grouped[day]!.sorted { $0.time > $1.time }
            return (day, title, entries, entries.reduce(0) { $0 + $1.spend })
        }
    }

    private func toggle(_ entry: HistoryEntry) {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.9)) { open = open == entry.id ? nil : entry.id }
    }

    private func copy(_ entry: HistoryEntry) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(entry.text.isEmpty ? entry.raw ?? "" : entry.text, forType: .string)
        copied = entry.id
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.2))
            if copied == entry.id { copied = nil }
        }
    }

    private func delete(_ entry: HistoryEntry) {
        withAnimation(.easeOut(duration: 0.2)) { model.deleteHistory(entry.id) }
    }

    private struct Row: View {
        let entry: HistoryEntry
        let copied: Bool
        let open: Bool
        let retrying: Bool
        let toggle: @MainActor () -> Void
        let copy: @MainActor () -> Void
        let delete: @MainActor () -> Void
        let retry: @MainActor () -> Void
        let addToNote: @MainActor () -> Void
        @State private var hovering = false

        var body: some View {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(entry.time.formatted(date: .omitted, time: .shortened))
                        .font(tiktok(11))
                        .monospacedDigit()
                        .foregroundStyle(.white.opacity(0.4))
                        .frame(width: 52, alignment: .leading)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(entry.text.isEmpty ? (entry.raw ?? "") : entry.text)
                            .opacity(entry.text.isEmpty ? 0.5 : 1)
                            .font(tiktok(13))
                            .multilineTextAlignment(.leading)
                        if let timing = entry.timing { TimingSummary(timing: timing) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    HStack(spacing: 2) {
                        RowAction(symbol: "arrow.clockwise", tip: "Retry", action: retry)
                            .opacity(retrying ? 0.35 : 1)
                            .disabled(retrying)
                        RowAction(symbol: "note.text.badge.plus", tip: "Add to current note", action: addToNote)
                        RowAction(symbol: copied ? "checkmark" : "doc.on.doc", tip: "Copy", action: copy)
                        RowAction(symbol: "trash", tip: "Delete", action: delete)
                    }
                    .opacity(hovering || copied || retrying ? 1 : 0)
                    .allowsHitTesting(hovering)
                }
                if open, let timing = entry.timing {
                    PhraseTimeline(timing: timing, heard: entry.raw, text: entry.text, polish: entry.polish,
                                   benchmarks: entry.benchmarks ?? [])
                        .padding(.leading, 62)
                        .padding(.top, 8)
                        .transition(.opacity)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(.white.opacity(open ? 0.06 : hovering ? 0.05 : 0)))
            .contentShape(Rectangle())
            .onTapGesture { if entry.timing != nil { toggle() } }
            .onHover { hovering = $0 }
            .onRightClick {
                [MenuItem(id: "retry", title: "Retry", symbol: "arrow.clockwise", enabled: !retrying, action: retry),
                 MenuItem(id: "note", title: "Add to current note", symbol: "note.text.badge.plus", action: addToNote),
                 MenuItem(id: "copy", title: "Copy", symbol: "doc.on.doc", action: copy),
                 MenuItem(id: "delete", title: "Delete", symbol: "trash", destructive: true, action: delete)]
            }
            .animation(.easeOut(duration: 0.12), value: hovering)
            .animation(.easeOut(duration: 0.15), value: copied)
        }
    }

    private struct RowAction: View {
        let symbol: String
        let tip: String
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
            .tip(tip)
        }
    }
}

