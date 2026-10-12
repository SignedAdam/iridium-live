import Foundation

public struct TextStyleRun: Codable, Equatable, Sendable {
    public var location: Int
    public var length: Int
    public var bold: Bool
    public var italic: Bool
    public var underline: Bool

    public init(location: Int, length: Int, bold: Bool = false, italic: Bool = false, underline: Bool = false) {
        self.location = location
        self.length = length
        self.bold = bold
        self.italic = italic
        self.underline = underline
    }

    var isPlain: Bool { !bold && !italic && !underline }
}

extension Transcript {
    @discardableResult
    public mutating func updateTurn(id: UUID, text: String, styles: [TextStyleRun]) -> Bool {
        guard let i = turns.firstIndex(where: { $0.id == id }) else { return false }
        turns[i].text = text
        turns[i].styles = Self.normalized(styles, textLength: text.utf16.count)
        return true
    }

    @discardableResult
    public mutating func deleteTurn(id: UUID) -> Bool {
        guard let i = turns.firstIndex(where: { $0.id == id }) else { return false }
        turns.remove(at: i)
        return true
    }

    public mutating func mergeSpeaker(_ source: String, into target: String) {
        guard source != target else { return }
        var merged: [SpeakerTurn] = []
        for var turn in turns {
            if turn.speakerID == source { turn.speakerID = target }
            if var last = merged.last, last.speakerID == turn.speakerID {
                Self.append(turn, to: &last)
                merged[merged.count - 1] = last
            } else {
                merged.append(turn)
            }
        }
        turns = merged
        speakerNames[source] = nil
    }

    private static func append(_ turn: SpeakerTurn, to last: inout SpeakerTurn) {
        let separator = last.text.isEmpty || turn.text.isEmpty ? "" : " "
        let offset = (last.text + separator).utf16.count
        let shifted = (turn.styles ?? []).map {
            TextStyleRun(location: $0.location + offset, length: $0.length,
                         bold: $0.bold, italic: $0.italic, underline: $0.underline)
        }
        last.text += separator + turn.text
        last.styles = normalized((last.styles ?? []) + shifted, textLength: last.text.utf16.count)
        last.words += turn.words
        last.start = min(last.start, turn.start)
        last.end = max(last.end, turn.end)
    }

    private static func normalized(_ runs: [TextStyleRun], textLength: Int) -> [TextStyleRun]? {
        let kept = runs.compactMap { run -> TextStyleRun? in
            let start = max(0, run.location)
            let end = min(textLength, run.location + run.length)
            guard end > start, !run.isPlain else { return nil }
            return TextStyleRun(location: start, length: end - start,
                                bold: run.bold, italic: run.italic, underline: run.underline)
        }
        .sorted { $0.location < $1.location }
        return kept.isEmpty ? nil : kept
    }
}
