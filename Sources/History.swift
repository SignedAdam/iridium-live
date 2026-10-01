import AppKit
import SwiftUI

/// One finished phrase, as it was typed (cleaned, when AI cleanup ran) and as it was heard.
struct HistoryEntry: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    let time: Date
    let text: String
    var raw: String?
}

/// Every phrase ever said, whether or not notes or typing were on: one JSON object per line in `history.jsonl`,
/// only ever appended to, in order, off the main thread.
@MainActor
final class HistoryStore {
    private static let shown = 2000  // the newest entries kept in memory for the pane
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

    /// Wait until every appended entry is on disk.
    func flush() {
        disk.sync {}
    }
}

/// Everything said so far, newest first, by day. Search narrows it; clicking an entry copies it.
struct HistoryPane: View {
    @Bindable var model: AppModel
    @State private var query = ""
    @State private var copied: UUID?

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
                Text(model.history.isEmpty ? "Everything you say will be kept here." : "Nothing matches.")
                    .font(tiktok(13))
                    .foregroundStyle(.white.opacity(0.34))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(days, id: \.day) { group in
                            Section {
                                ForEach(group.entries) { entry in
                                    Row(entry: entry, copied: copied == entry.id) { copy(entry) }
                                }
                            } header: {
                                Text(group.title.uppercased())
                                    .font(tiktok(10.5, "Medium"))
                                    .kerning(0.8)
                                    .foregroundStyle(.white.opacity(0.42))
                                    .padding(.horizontal, 10)
                                    .padding(.top, 10)
                                    .padding(.bottom, 4)
                                    .frame(maxWidth: .infinity, alignment: .leading)
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

    private var days: [(day: Date, title: String, entries: [HistoryEntry])] {
        let calendar = Calendar.current
        let matching = model.history.reversed().filter { query.isEmpty || $0.text.localizedCaseInsensitiveContains(query) }
        let grouped = Dictionary(grouping: matching) { calendar.startOfDay(for: $0.time) }
        return grouped.keys.sorted(by: >).map { day in
            let title = calendar.isDateInToday(day) ? "Today"
                : calendar.isDateInYesterday(day) ? "Yesterday"
                : day.formatted(.dateTime.weekday(.wide).day().month(.wide))
            return (day, title, grouped[day]!.sorted { $0.time > $1.time })
        }
    }

    private func copy(_ entry: HistoryEntry) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(entry.text, forType: .string)
        copied = entry.id
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.2))
            if copied == entry.id { copied = nil }
        }
    }

    private struct Row: View {
        let entry: HistoryEntry
        let copied: Bool
        let copy: () -> Void
        @State private var hovering = false

        var body: some View {
            Button(action: copy) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(entry.time.formatted(date: .omitted, time: .shortened))
                        .font(tiktok(11))
                        .monospacedDigit()
                        .foregroundStyle(.white.opacity(0.4))
                        .frame(width: 52, alignment: .leading)
                    Text(entry.text)
                        .font(tiktok(13))
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(copied ? 0.9 : 0.55))
                        .opacity(hovering || copied ? 1 : 0)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(.white.opacity(hovering ? 0.07 : 0)))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .help("Click to copy")
            .animation(.easeOut(duration: 0.12), value: hovering)
            .animation(.easeOut(duration: 0.15), value: copied)
        }
    }
}
