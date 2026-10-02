import SwiftUI

/// What is known about one cleanup model: how it did on the benchmark of 40 dictated phrases (fillers, spoken
/// corrections, numbers, money, times, emails; measured 1 October 2026), and how it has done for you, from
/// the timings in your history.
struct ModelStats {
    struct Benchmark {
        var medianMs: Double?
        var p90Ms: Double?
        var usable: String?         // phrases whose cleanup was right in substance, e.g. "37 of 40"
        var exact: String?          // word for word as expected
        var perThousand: String?    // cost of 1,000 phrases
        var note: String?
    }

    struct Yours {
        var sent = 0, skipped = 0, failed = 0
        var medianMs: Double?
        var p90Ms: Double?
        var tokensIn: Double?
        var tokensOut: Double?
        var spent = 0.0
    }

    let provider: String
    let model: String

    var benchmark: Benchmark? { Self.benchmarks["\(provider):\(model)"] }

    /// How this model has done for you: its own phrase cleanups, the passes it made over whole recordings, and every
    /// phrase it answered while benchmarking, which are all calls to the same model.
    func yours(in history: [HistoryEntry]) -> Yours {
        let runs = history.flatMap(\.calls).filter { $0.provider == provider && $0.model == model }
        var yours = Yours()
        yours.skipped = runs.filter(\.skipped).count
        yours.failed = runs.filter { $0.error != nil }.count
        let answered = runs.filter { !$0.skipped && $0.error == nil }
        yours.sent = answered.count + yours.failed
        let times = answered.map(\.ms).sorted()
        if !times.isEmpty {
            yours.medianMs = times[times.count / 2]
            yours.p90Ms = times[min(times.count - 1, Int((Double(times.count) * 0.9).rounded(.down)))]
        }
        let counted = answered.filter { $0.promptTokens != nil && $0.completionTokens != nil }
        if !counted.isEmpty {
            yours.tokensIn = counted.reduce(0) { $0 + ($1.promptTokens ?? 0) } / Double(counted.count)
            yours.tokensOut = counted.reduce(0) { $0 + ($1.completionTokens ?? 0) } / Double(counted.count)
        }
        yours.spent = runs.reduce(0) { $0 + ($1.costUsd ?? 0) }
        return yours
    }

    private static let benchmarks: [String: Benchmark] = [
        "groq:qwen/qwen3.8-27b": Benchmark(medianMs: 143, p90Ms: 251, usable: "37 of 40", exact: "19 of 40", perThousand: "$0.47"),
        "groq:openai/gpt-oss-120b": Benchmark(medianMs: 343, p90Ms: 670, usable: "35 of 40", exact: "19 of 40", perThousand: "$0.08"),
        "groq:openai/gpt-oss-20b": Benchmark(medianMs: 414, p90Ms: 3517, usable: "34 of 40", exact: "15 of 40", perThousand: "$0.04",
                                             note: "5 of 40 took longer than 2.5 s"),
        "openrouter:openai/gpt-oss-120b:nitro": Benchmark(perThousand: "$0.02",
                                                          note: "Not measured here (no OpenRouter credits). The same model on Groq: 343 ms."),
        "openrouter:qwen/qwen3.8-27b:nitro": Benchmark(medianMs: 440, p90Ms: 742, usable: "29 of 34", exact: "18 of 34", perThousand: "$0.27",
                                                       note: "Measured on its free endpoint"),
        "openrouter:inclusionai/ling-3.0-flash": Benchmark(medianMs: 825, p90Ms: 1177, usable: "27 of 31", exact: "18 of 31",
                                                           perThousand: "$0.01", note: "Measured on its free endpoint"),
    ]
}

/// The card beside a model in the model list: the benchmark, then your own numbers.
struct ModelStatsCard: View {
    let name: String
    let providerName: String
    let stats: ModelStats
    let history: [HistoryEntry]

    var body: some View {
        let yours = stats.yours(in: history)
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(name).font(tiktok(13.5, "Medium")).foregroundStyle(.white.opacity(0.95))
                Text("on \(providerName)")
                    .font(tiktok(11.5)).foregroundStyle(.white.opacity(0.5))
            }
            if let bench = stats.benchmark {
                block("Benchmark, 40 dictated phrases") {
                    if let ms = bench.medianMs { line("Median", duration(ms)) }
                    if let ms = bench.p90Ms { line("Slowest 10% from", duration(ms)) }
                    if let usable = bench.usable { line("Right in substance", usable) }
                    if let exact = bench.exact { line("Word for word", exact) }
                    if let cost = bench.perThousand { line("Per 1,000 phrases", cost) }
                    if let note = bench.note { remark(note) }
                }
            }
            block(yours.sent + yours.skipped == 0 ? "Yours" : "Yours, \(yours.sent + yours.skipped) calls") {
                if yours.sent + yours.skipped == 0 {
                    remark("Not used yet")
                } else {
                    if let ms = yours.medianMs { line("Median", duration(ms)) }
                    if let ms = yours.p90Ms { line("Slowest 10% from", duration(ms)) }
                    if yours.skipped > 0 { line("Already clean, not sent", "\(yours.skipped)") }
                    if yours.failed > 0 { line("Failed", "\(yours.failed)", alert: true) }
                    if let input = yours.tokensIn, let output = yours.tokensOut {
                        line("Tokens per phrase", "\(Int(input.rounded())) in, \(Int(output.rounded())) out")
                    }
                    if yours.spent > 0 { line("Spent", dollars(yours.spent)) }
                }
            }
        }
        .padding(14)
        .frame(width: 250, alignment: .leading)
    }

    private func block(_ title: String, @ViewBuilder _ content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased()).font(tiktok(10, "Medium")).kerning(0.6).foregroundStyle(.white.opacity(0.42))
            content()
        }
    }

    private func line(_ label: String, _ value: String, alert: Bool = false) -> some View {
        HStack {
            Text(label).foregroundStyle(.white.opacity(0.7))
            Spacer(minLength: 8)
            Text(value).monospacedDigit().foregroundStyle(alert ? accent : .white.opacity(0.92))
        }
        .font(tiktok(12))
    }

    private func remark(_ text: String) -> some View {
        Text(text).font(tiktok(11.5)).foregroundStyle(.white.opacity(0.45)).fixedSize(horizontal: false, vertical: true)
    }
}
