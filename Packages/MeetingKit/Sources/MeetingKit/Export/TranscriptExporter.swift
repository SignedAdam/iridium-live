import Foundation

public enum TranscriptExportFormat: String, CaseIterable, Sendable {
    case markdown
    case srt
    case vtt
    case plainText

    public var fileExtension: String {
        switch self {
        case .markdown: return "md"
        case .srt: return "srt"
        case .vtt: return "vtt"
        case .plainText: return "txt"
        }
    }

    public var displayName: String {
        switch self {
        case .markdown: return "Markdown"
        case .srt: return "SubRip (SRT)"
        case .vtt: return "WebVTT"
        case .plainText: return "Plain Text"
        }
    }
}

public enum TranscriptExporter {

    public static func export(
        _ transcript: Transcript,
        as format: TranscriptExportFormat,
        title: String? = nil,
        date: Date? = nil,
        summary: MeetingSummary? = nil
    ) -> String {
        switch format {
        case .markdown:
            return markdown(transcript, title: title, date: date, summary: summary)
        case .srt:
            return srt(transcript)
        case .vtt:
            return vtt(transcript)
        case .plainText:
            return plainText(transcript, title: title, date: date)
        }
    }

    private static func markdown(
        _ transcript: Transcript,
        title: String?,
        date: Date?,
        summary: MeetingSummary?
    ) -> String {
        var lines: [String] = []

        if let title, !title.isEmpty {
            lines.append("# \(title)")
        }
        if let date {
            lines.append("_\(Timecode.isoDate(date))_")
        }

        if let summary {
            if !lines.isEmpty { lines.append("") }
            lines.append("## Summary")
            lines.append("")
            lines.append("**TL;DR:** \(summary.tldr)")

            if !summary.keyPoints.isEmpty {
                lines.append("")
                lines.append("### Key Points")
                for point in summary.keyPoints {
                    lines.append("- \(point)")
                }
            }

            if !summary.actionItems.isEmpty {
                lines.append("")
                lines.append("### Action Items")
                for item in summary.actionItems {
                    let box = item.done ? "[x]" : "[ ]"
                    var line = "- \(box) \(item.text)"
                    if let owner = item.owner, !owner.isEmpty {
                        line += " (\(owner))"
                    }
                    if let due = item.due, !due.isEmpty {
                        line += " due \(due)"
                    }
                    lines.append(line)
                }
            }

            if !summary.decisions.isEmpty {
                lines.append("")
                lines.append("### Decisions")
                for decision in summary.decisions {
                    lines.append("- \(decision.text)")
                }
            }
        }

        if !lines.isEmpty { lines.append("") }
        lines.append("## Transcript")
        lines.append("")
        for turn in transcript.turns {
            let name = transcript.name(for: turn.speakerID)
            lines.append("**\(name)** [\(Timecode.clock(turn.start))]: \(turn.text)")
        }

        return lines.joined(separator: "\n")
    }

    private static func srt(_ transcript: Transcript) -> String {
        var blocks: [String] = []
        for (index, turn) in transcript.turns.enumerated() {
            let name = transcript.name(for: turn.speakerID)
            let timeline = "\(Timecode.srt(turn.start)) --> \(Timecode.srt(turn.end))"
            let block = """
            \(index + 1)
            \(timeline)
            \(name): \(turn.text)
            """
            blocks.append(block)
        }
        return blocks.joined(separator: "\n\n") + (blocks.isEmpty ? "" : "\n")
    }

    private static func vtt(_ transcript: Transcript) -> String {
        var lines: [String] = ["WEBVTT", ""]
        for turn in transcript.turns {
            let name = transcript.name(for: turn.speakerID)
            lines.append("\(Timecode.vtt(turn.start)) --> \(Timecode.vtt(turn.end))")
            lines.append("\(name): \(turn.text)")
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    private static func plainText(
        _ transcript: Transcript,
        title: String?,
        date: Date?
    ) -> String {
        var header: [String] = []
        if let title, !title.isEmpty {
            header.append(title)
        }
        if let date {
            header.append(Timecode.isoDate(date))
        }

        let body = transcript.turns
            .map { "\(transcript.name(for: $0.speakerID)): \($0.text)" }
            .joined(separator: "\n\n")

        guard !header.isEmpty else { return body }

        let headerText = header.joined(separator: "\n")
        return body.isEmpty ? headerText : headerText + "\n\n" + body
    }
}

fileprivate enum Timecode {

    private static func components(_ seconds: TimeInterval) -> (h: Int, m: Int, s: Int, ms: Int) {
        let safe = (seconds.isFinite && seconds > 0) ? seconds : 0
        let totalMillis = Int((safe * 1000).rounded())
        let ms = totalMillis % 1000
        let totalSeconds = totalMillis / 1000
        let s = totalSeconds % 60
        let m = (totalSeconds / 60) % 60
        let h = totalSeconds / 3600
        return (h, m, s, ms)
    }

    private static func pad(_ value: Int, _ width: Int) -> String {
        String(value).leftPadded(to: width, with: "0")
    }

    static func srt(_ seconds: TimeInterval) -> String {
        let c = components(seconds)
        return "\(pad(c.h, 2)):\(pad(c.m, 2)):\(pad(c.s, 2)),\(pad(c.ms, 3))"
    }

    static func vtt(_ seconds: TimeInterval) -> String {
        let c = components(seconds)
        return "\(pad(c.h, 2)):\(pad(c.m, 2)):\(pad(c.s, 2)).\(pad(c.ms, 3))"
    }

    static func clock(_ seconds: TimeInterval) -> String {
        let c = components(seconds)
        if c.h > 0 {
            return "\(c.h):\(pad(c.m, 2)):\(pad(c.s, 2))"
        }
        return "\(pad(c.m, 2)):\(pad(c.s, 2))"
    }

    static func isoDate(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        let year = parts.year ?? 0
        let month = parts.month ?? 1
        let day = parts.day ?? 1
        return "\(pad(year, 4))-\(pad(month, 2))-\(pad(day, 2))"
    }
}

fileprivate extension String {
    func leftPadded(to width: Int, with character: Character) -> String {
        guard count < width else { return self }
        return String(repeating: character, count: width - count) + self
    }
}
