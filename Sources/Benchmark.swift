import AppKit
import SwiftUI

struct BenchmarkRun: Codable, Equatable, Sendable, Identifiable {
    var provider: String
    var model: String
    var text: String
    var ms: Double
    var promptTokens: Double?
    var completionTokens: Double?
    var costUsd: Double?
    var error: String?

    var id: String { "\(provider):\(model)" }
    var modelName: String { Settings.modelName(provider: provider, model: model) }

    var cleanup: PhraseTiming.Cleanup {
        PhraseTiming.Cleanup(provider: provider, model: model, skipped: false, ms: ms, promptTokens: promptTokens,
                             completionTokens: completionTokens, costUsd: costUsd, error: error)
    }
}

struct BenchmarkSummary: Identifiable {
    let provider: String
    let model: String
    var inUse = false
    var runs = 0
    var failures = 0
    var agreed = 0
    var times: [Double] = []
    var spent = 0.0

    var id: String { "\(provider):\(model)" }
    var name: String { Settings.modelName(provider: provider, model: model) }
    var answered: Int { runs - failures }
    var medianMs: Double? { times.isEmpty ? nil : times.sorted()[times.count / 2] }
    var p90Ms: Double? {
        let sorted = times.sorted()
        guard !sorted.isEmpty else { return nil }
        return sorted[min(sorted.count - 1, Int((Double(sorted.count) * 0.9).rounded(.down)))]
    }
    var agreement: Double? { answered > 0 ? Double(agreed) / Double(answered) : nil }
}

func benchmarkSummaries(in history: [HistoryEntry]) -> [BenchmarkSummary] {
    var summaries: [String: BenchmarkSummary] = [:]
    var order: [String] = []

    func add(_ provider: String, _ model: String, inUse: Bool, ms: Double, cost: Double?, failed: Bool, agrees: Bool) {
        let key = "\(provider):\(model)"
        if summaries[key] == nil {
            summaries[key] = BenchmarkSummary(provider: provider, model: model, inUse: inUse)
            order.append(key)
        }
        summaries[key]?.runs += 1
        summaries[key]?.spent += cost ?? 0
        if failed {
            summaries[key]?.failures += 1
        } else {
            summaries[key]?.times.append(ms)
            if agrees { summaries[key]?.agreed += 1 }
        }
    }

    for entry in history {
        guard let runs = entry.benchmarks, !runs.isEmpty else { continue }
        if let used = entry.timing?.cleanup {
            add(used.provider, used.model, inUse: true, ms: used.ms, cost: used.costUsd,
                failed: used.error != nil, agrees: used.error == nil)
        }
        for run in runs {
            add(run.provider, run.model, inUse: false, ms: run.ms, cost: run.costUsd, failed: run.error != nil,
                agrees: same(run.text, entry.text))
        }
    }
    return order.compactMap { summaries[$0] }.sorted { $0.inUse && !$1.inUse }
}

private func same(_ a: String, _ b: String) -> Bool {
    a.split(whereSeparator: \.isWhitespace) == b.split(whereSeparator: \.isWhitespace)
}

func wordDiff(_ text: String, from reference: String) -> [(word: Substring, changed: Bool)] {
    let words = text.split(whereSeparator: \.isWhitespace)
    let theirs = reference.split(whereSeparator: \.isWhitespace)
    var lengths = [[Int]](repeating: [Int](repeating: 0, count: theirs.count + 1), count: words.count + 1)
    for i in stride(from: words.count - 1, through: 0, by: -1) {
        for j in stride(from: theirs.count - 1, through: 0, by: -1) {
            lengths[i][j] = words[i] == theirs[j] ? lengths[i + 1][j + 1] + 1
                : max(lengths[i + 1][j], lengths[i][j + 1])
        }
    }
    var marked: [(Substring, Bool)] = []
    var i = 0, j = 0
    while i < words.count {
        if j < theirs.count, words[i] == theirs[j] {
            marked.append((words[i], false))
            i += 1
            j += 1
        } else if j < theirs.count, lengths[i + 1][j] >= lengths[i][j + 1] {
            marked.append((words[i], true))
            i += 1
        } else if j < theirs.count {
            j += 1
        } else {
            marked.append((words[i], true))
            i += 1
        }
    }
    return marked
}

struct BenchmarkLine: View {
    let run: BenchmarkRun
    let chosen: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 10) {
                Text(run.modelName).foregroundStyle(.white.opacity(0.85))
                Spacer(minLength: 8)
                if let error = run.error {
                    Text(error).foregroundStyle(accent).lineLimit(1)
                } else {
                    if let input = run.promptTokens, let output = run.completionTokens {
                        Text("\(Int(input))/\(Int(output))").foregroundStyle(.white.opacity(0.45))
                    }
                    if let cost = run.costUsd, cost > 0 { Text(dollars(cost)).foregroundStyle(.white.opacity(0.45)) }
                    Text(duration(run.ms)).foregroundStyle(.white.opacity(0.7))
                }
            }
            .font(tiktok(11.5))
            .monospacedDigit()
            if run.error == nil {
                marked.fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var marked: Text {
        var line = AttributedString()
        for (word, changed) in wordDiff(run.text, from: chosen) {
            var piece = AttributedString(word + " ")
            piece.foregroundColor = .white.opacity(changed ? 0.95 : 0.4)
            piece.underlineStyle = changed ? .single : nil
            line += piece
        }
        return Text(line).font(tiktok(11.5))
    }
}

@MainActor
final class BenchmarkPanel {
    private static var open: BenchmarkPanel?
    private let panel: NSPanel

    static func show(history: [HistoryEntry], on screen: NSScreen) {
        if let open {
            open.panel.makeKeyAndOrderFront(nil)
            return
        }
        open = BenchmarkPanel(history: history, screen: screen)
    }

    private init(history: [HistoryEntry], screen: NSScreen) {
        let size = NSSize(width: 640, height: 380)
        let area = screen.visibleFrame
        panel = NSPanel(contentRect: NSRect(x: (area.midX - size.width / 2).rounded(),
                                            y: (area.midY - size.height / 2).rounded(),
                                            width: size.width, height: size.height),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = true
        let close = { @MainActor in
            BenchmarkPanel.open = nil
            self.panel.orderOut(nil)
        }
        let host = NSHostingView(rootView: BenchmarkTable(summaries: benchmarkSummaries(in: history), close: close)
            .frame(width: size.width, height: size.height))
        host.sizingOptions = []
        panel.contentView = host
        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)
        panel.animator().alphaValue = 1
    }
}

private struct BenchmarkTable: View {
    let summaries: [BenchmarkSummary]
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Benchmark").font(tiktok(15, "Medium"))
                Spacer()
                Button("Close", action: close).buttonStyle(.plain).font(tiktok(12)).foregroundStyle(.white.opacity(0.6))
            }
            .padding(.horizontal, 18)
            .padding(.top, 16)
            .padding(.bottom, 10)

            if summaries.isEmpty {
                Text("No results yet. Turn on Benchmark mode and dictate.")
                    .font(tiktok(13))
                    .foregroundStyle(.white.opacity(0.4))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                header
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(summaries) { summary in
                            row(summary)
                            Divider().overlay(.white.opacity(0.07))
                        }
                    }
                    .padding(.horizontal, 18)
                }
                .scrollIndicators(.visible)
                Text("Agreement: how often a model's output matches the current model's output word for word.")
                    .font(tiktok(11))
                    .foregroundStyle(.white.opacity(0.38))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 12)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Glass(cornerRadius: 18, tint: 1))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .padding(10)
        .shadow(color: .black.opacity(0.35), radius: 14, y: 6)
        .foregroundStyle(.white.opacity(0.9))
    }

    private var header: some View {
        cells(["Model", "Runs", "Median", "Slowest 10%", "Failed", "Agrees", "Spent"])
            .font(tiktok(10, "Medium"))
            .kerning(0.6)
            .foregroundStyle(.white.opacity(0.42))
            .padding(.horizontal, 18)
            .padding(.bottom, 6)
    }

    private func row(_ summary: BenchmarkSummary) -> some View {
        HStack(spacing: 0) {
            name(summary)
            value(summary.runs == 0 ? "—" : "\(summary.runs)")
            value(summary.medianMs.map(duration) ?? "—")
            value(summary.p90Ms.map(duration) ?? "—")
            value(summary.failures == 0 ? "—" : "\(summary.failures)", alert: summary.failures > 0)
            value(summary.inUse ? "—" : summary.agreement.map { "\(Int(($0 * 100).rounded()))%" } ?? "—")
            value(summary.spent > 0 ? dollars(summary.spent) : "—")
        }
        .font(tiktok(12))
        .monospacedDigit()
        .padding(.vertical, 7)
    }

    private func name(_ summary: BenchmarkSummary) -> some View {
        HStack(spacing: 6) {
            Text(summary.name).foregroundStyle(.white.opacity(0.92))
            if summary.inUse {
                Text("in use")
                    .font(tiktok(10, "Medium"))
                    .foregroundStyle(.white.opacity(0.5))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(.white.opacity(0.1)))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func value(_ text: String, alert: Bool = false) -> some View {
        Text(text)
            .foregroundStyle(alert ? accent : .white.opacity(0.8))
            .frame(width: 78, alignment: .trailing)
    }

    private func cells(_ titles: [String]) -> some View {
        HStack(spacing: 0) {
            Text(titles[0].uppercased()).frame(maxWidth: .infinity, alignment: .leading)
            ForEach(titles.dropFirst(), id: \.self) { title in
                Text(title.uppercased()).frame(width: 78, alignment: .trailing)
            }
        }
    }
}

