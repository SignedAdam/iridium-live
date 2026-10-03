import SwiftUI

struct PhraseTiming: Codable, Equatable, Sendable {
    struct Cleanup: Codable, Equatable, Sendable {
        var provider: String
        var model: String
        var skipped: Bool
        var ms: Double
        var connectMs: Double?
        var networkMs: Double?
        var queueMs: Double?
        var promptMs: Double?
        var generateMs: Double?
        var promptTokens: Double?
        var completionTokens: Double?
        var costUsd: Double?
        var error: String?

        init(provider: String, model: String, skipped: Bool, ms: Double, connectMs: Double? = nil,
             networkMs: Double? = nil, queueMs: Double? = nil, promptMs: Double? = nil, generateMs: Double? = nil,
             promptTokens: Double? = nil, completionTokens: Double? = nil, costUsd: Double? = nil,
             error: String? = nil) {
            self.provider = provider
            self.model = model
            self.skipped = skipped
            self.ms = ms
            self.connectMs = connectMs
            self.networkMs = networkMs
            self.queueMs = queueMs
            self.promptMs = promptMs
            self.generateMs = generateMs
            self.promptTokens = promptTokens
            self.completionTokens = completionTokens
            self.costUsd = costUsd
            self.error = error
        }

        var providerName: String { Settings.cleanupProviders.first { $0.id == provider }?.name ?? provider }
        var modelName: String { Settings.modelName(provider: provider, model: model) }
    }

    var speechMs: Double
    var endpointMs: Double
    var queueMs: Double
    var decodeMs: Double
    var cleanup: Cleanup?
    var totalMs: Double
}

struct PolishRun: Codable, Equatable, Sendable {
    var text: String
    var heard: String
    var cleanup: PhraseTiming.Cleanup?
}

func engineValue<T: Decodable>(_ object: Any?) -> T? {
    guard let object, JSONSerialization.isValidJSONObject([object]),
          let data = try? JSONSerialization.data(withJSONObject: [object]) else { return nil }
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    return (try? decoder.decode([T].self, from: data))?.first
}

extension PhraseTiming {
    init?(engine object: Any?) {
        guard let timing: PhraseTiming = engineValue(object) else { return nil }
        self = timing
    }
}

func duration(_ ms: Double) -> String {
    ms < 1000 ? "\(Int(ms.rounded())) ms" : String(format: "%.2f s", ms / 1000)
}

func dollars(_ usd: Double) -> String {
    usd >= 0.01 ? String(format: "$%.2f", usd) : String(format: "$%.5f", usd)
}

struct TimingSummary: View {
    let timing: PhraseTiming

    var body: some View {
        HStack(spacing: 10) {
            Text(duration(timing.totalMs))
            if let cleanup = timing.cleanup {
                if cleanup.error != nil {
                    Text("\(cleanup.providerName) failed").foregroundStyle(accent)
                } else if cleanup.skipped {
                    Text("Skipped")
                } else {
                    Text("\(cleanup.providerName) \(duration(cleanup.ms))")
                }
                if let cost = cleanup.costUsd, cost > 0 { Text(dollars(cost)) }
            }
        }
        .font(tiktok(11))
        .monospacedDigit()
        .foregroundStyle(.white.opacity(0.78))
    }
}

struct PhraseTimeline: View {
    let timing: PhraseTiming
    let heard: String?
    var text = ""
    var polish: PolishRun?
    var benchmarks: [BenchmarkRun] = []

    private struct Step: Identifiable {
        let id: String
        let label: String
        let ms: Double
        var shade = 0.0
        var alert = false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            bar
            VStack(spacing: 3) {
                ForEach(steps) { step in line(step) }
                line(Step(id: "total", label: "Total", ms: timing.totalMs), bold: true)
            }
            if let cleanup = timing.cleanup, !cleanup.skipped {
                HStack(spacing: 12) {
                    Text(cleanup.modelName)
                    if let input = cleanup.promptTokens, let output = cleanup.completionTokens {
                        Text("\(Int(input)) tokens in, \(Int(output)) out")
                    }
                    if let cost = cleanup.costUsd { Text(dollars(cost)) }
                }
                .font(tiktok(11))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.78))
            }
            if let heard {
                Text("Heard: \(heard)")
                    .font(tiktok(11.5))
                    .foregroundStyle(.white.opacity(0.78))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let polish { polished(polish) }
            if !benchmarks.isEmpty {
                block("Other models") {
                    ForEach(benchmarks) { run in BenchmarkLine(run: run, chosen: text) }
                }
            }
        }
        .padding(.top, 4)
    }

    private func polished(_ polish: PolishRun) -> some View {
        block("Full recording") {
            if let cleanup = polish.cleanup {
                line(cleanup.error.map {
                    Step(id: "polish", label: "Cleanup failed: \($0)", ms: cleanup.ms, shade: 0.85, alert: true)
                } ?? Step(id: "polish", label: "Cleanup on \(cleanup.providerName)", ms: cleanup.ms, shade: 0.7))
            }
            if polish.text != polish.heard {
                Text(polish.text)
                    .font(tiktok(11.5))
                    .foregroundStyle(.white.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func block(_ title: String, @ViewBuilder _ content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased()).font(tiktok(10, "Medium")).kerning(0.6).foregroundStyle(.white.opacity(0.78))
            content()
        }
        .padding(.top, 2)
    }

    private var steps: [Step] {
        var steps = [Step(id: "pause", label: "End of speech", ms: timing.endpointMs, shade: 0.22)]
        if timing.queueMs >= 1 { steps.append(Step(id: "wait", label: "Waiting", ms: timing.queueMs, shade: 0.12)) }
        steps.append(Step(id: "transcribe", label: "Transcribing", ms: timing.decodeMs, shade: 0.5))
        guard let cleanup = timing.cleanup else { return steps }
        if let error = cleanup.error {
            steps.append(Step(id: "cleanup", label: "\(cleanup.providerName) failed: \(error)", ms: cleanup.ms, shade: 0.85, alert: true))
            return steps
        }
        if cleanup.skipped {
            steps.append(Step(id: "cleanup", label: "Skipped, already clean", ms: cleanup.ms, shade: 0.85))
            return steps
        }
        steps.append(Step(id: "cleanup", label: "Cleanup on \(cleanup.providerName)", ms: cleanup.ms, shade: 0.85))
        let parts: [(String, Double?)] = [("Connecting", cleanup.connectMs), ("Network", cleanup.networkMs),
                                          ("Queued at \(cleanup.providerName)", cleanup.queueMs),
                                          ("Prompt", cleanup.promptMs), ("Writing", cleanup.generateMs)]
        steps += parts.compactMap { label, ms in ms.map { Step(id: label, label: label, ms: $0) } }
        return steps
    }

    private var bar: some View {
        let drawn = steps.filter { $0.shade > 0 }
        let total = max(drawn.reduce(0) { $0 + $1.ms }, 1)
        return GeometryReader { proxy in
            let room = proxy.size.width - CGFloat(drawn.count - 1) * 2
            HStack(spacing: 2) {
                ForEach(drawn) { step in
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(step.alert ? accent : .white.opacity(step.shade))
                        .frame(width: max(2, room * step.ms / total))
                }
            }
        }
        .frame(height: 6)
    }

    private func line(_ step: Step, bold: Bool = false) -> some View {
        HStack(spacing: 7) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(step.alert ? accent : .white.opacity(step.shade))
                .frame(width: 7, height: 7)
                .opacity(step.shade > 0 ? 1 : 0)
            Text(step.label)
                .foregroundStyle(step.alert ? accent : .white.opacity(step.shade > 0 || bold ? 0.9 : 0.78))
                .lineLimit(2)
            Spacer(minLength: 8)
            Text(duration(step.ms))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(bold ? 0.95 : 0.8))
        }
        .font(tiktok(11.5, bold ? "Medium" : "Regular"))
        .padding(.leading, step.shade > 0 || bold ? 0 : 14)
    }
}

