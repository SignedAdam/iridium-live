import Foundation

public struct LiveTranscript: Equatable, Sendable {
    public struct Paragraph: Identifiable, Equatable, Sendable {
        public let id: UUID
        public let kind: AudioStreamKind
        public var text: String
        public var pending: String
    }

    public struct Word: Equatable, Sendable {
        public let text: String
        public let start: TimeInterval
        public let end: TimeInterval
        let key: String

        public init(text: String, start: TimeInterval, end: TimeInterval) {
            self.text = text
            self.start = start
            self.end = end
            self.key = LiveTranscript.key(text)
        }
    }

    struct Segment: Equatable, Sendable {
        let id: UUID
        let kind: AudioStreamKind
        let start: TimeInterval
        let end: TimeInterval
        let text: String
        let words: [Word]
        var visible: String
    }

    static let echoWindow: TimeInterval = 1.2
    static let echoRun = 3
    static let echoPair = 2
    static let echoSegmentShare = 0.6

    private(set) var finals: [Segment] = []
    private(set) var volatile: [AudioStreamKind: Segment] = [:]
    private var systemWords: [Word] = []
    private var longestFinal: TimeInterval = 0

    public init() {}

    public var isEmpty: Bool { finals.isEmpty && volatile.isEmpty }

    public mutating func apply(kind: AudioStreamKind, text: String, words: [Word],
                               start: TimeInterval, end: TimeInterval, isFinal: Bool) {
        var text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.contains(where: { $0.isLetter || $0.isNumber }) { text = "" }
        let previous = volatile[kind]
        let id = previous?.id ?? UUID()
        guard isFinal else {
            guard !text.isEmpty else {
                guard let previous else { return }
                volatile[kind] = nil
                if kind == .system { refreshMic(from: previous.start, to: previous.end) }
                return
            }
            let segment = make(id: id, kind: kind, text: text, words: words, start: start, end: end)
            volatile[kind] = segment
            if kind == .system { refreshMic(from: start, to: end) }
            return
        }
        volatile[kind] = nil
        guard !text.isEmpty else {
            if kind == .system, let previous { refreshMic(from: previous.start, to: previous.end) }
            return
        }
        let segment = make(id: id, kind: kind, text: text, words: words, start: start, end: end)
        let index = finals.firstIndex { $0.start > start } ?? finals.endIndex
        finals.insert(segment, at: index)
        longestFinal = max(longestFinal, end - start)
        if kind == .system {
            absorb(segment.words)
            refreshMic(from: min(start, previous?.start ?? start), to: max(end, previous?.end ?? end))
        }
    }

    public mutating func discardPending(_ kind: AudioStreamKind) {
        guard let previous = volatile[kind] else { return }
        volatile[kind] = nil
        if kind == .system { refreshMic(from: previous.start, to: previous.end) }
    }

    public var paragraphs: [Paragraph] {
        let pending = volatile.values.sorted {
            $0.start != $1.start ? $0.start < $1.start : $0.kind.rawValue < $1.kind.rawValue
        }
        var out: [Paragraph] = []
        var next = 0
        for segment in finals {
            while next < pending.count, Self.precedes(pending[next], segment) {
                append(pending[next], isPending: true, to: &out)
                next += 1
            }
            append(segment, isPending: false, to: &out)
        }
        while next < pending.count {
            append(pending[next], isPending: true, to: &out)
            next += 1
        }
        return out
    }

    private static func precedes(_ a: Segment, _ b: Segment) -> Bool {
        a.start != b.start ? a.start < b.start : a.kind.rawValue < b.kind.rawValue
    }

    private func append(_ segment: Segment, isPending: Bool, to out: inout [Paragraph]) {
        guard !segment.visible.isEmpty else { return }
        if var last = out.last, last.kind == segment.kind {
            if isPending {
                last.pending = Self.join(last.pending, segment.visible)
            } else {
                last.text = Self.join(last.text, segment.visible)
            }
            out[out.count - 1] = last
        } else {
            out.append(Paragraph(id: segment.id, kind: segment.kind,
                                 text: isPending ? "" : segment.visible,
                                 pending: isPending ? segment.visible : ""))
        }
    }

    private func make(id: UUID, kind: AudioStreamKind, text: String, words: [Word],
                      start: TimeInterval, end: TimeInterval) -> Segment {
        let resolved = words.isEmpty ? Self.spread(text, from: start, to: end) : words
        var segment = Segment(id: id, kind: kind, start: start, end: end,
                              text: text, words: resolved, visible: text)
        if kind == .mic { segment.visible = withoutEcho(segment) }
        return segment
    }

    private mutating func absorb(_ words: [Word]) {
        guard !words.isEmpty else { return }
        if systemWords.last.map({ $0.start <= words[0].start }) ?? true {
            systemWords.append(contentsOf: words)
            return
        }
        systemWords.append(contentsOf: words)
        systemWords.sort { $0.start < $1.start }
    }

    private mutating func refreshMic(from start: TimeInterval, to end: TimeInterval) {
        let lo = start - Self.echoWindow
        let hi = end + Self.echoWindow
        var index = finals.count - 1
        while index >= 0, finals[index].start >= lo - longestFinal {
            if finals[index].kind == .mic, finals[index].end >= lo, finals[index].start <= hi {
                finals[index].visible = withoutEcho(finals[index])
            }
            index -= 1
        }
        if var mic = volatile[.mic], mic.end >= lo, mic.start <= hi {
            mic.visible = withoutEcho(mic)
            volatile[.mic] = mic
        }
    }

    private func withoutEcho(_ segment: Segment) -> String {
        let words = segment.words
        guard !words.isEmpty else { return segment.text }
        let pending = volatile[.system]?.words ?? []
        var matched = [Bool](repeating: false, count: words.count)
        var count = 0
        for index in words.indices where words[index].key.isEmpty || heard(words[index], pending: pending) {
            matched[index] = true
            count += 1
        }
        for index in 1..<max(1, words.count - 1) where !matched[index] {
            if matched[index - 1], matched[index + 1] {
                matched[index] = true
                count += 1
            }
        }
        guard count > 0 else { return segment.text }
        var drop = [Bool](repeating: false, count: words.count)
        var dropped = 0
        var longest = 0
        var index = 0
        while index < words.count {
            guard matched[index] else { index += 1; continue }
            var last = index
            while last + 1 < words.count, matched[last + 1] { last += 1 }
            let run = last - index + 1
            longest = max(longest, run)
            if run >= Self.echoRun {
                for position in index...last { drop[position] = true }
                dropped += run
            }
            index = last + 1
        }
        if longest >= Self.echoPair, Double(count) >= Self.echoSegmentShare * Double(words.count) { return "" }
        guard dropped > 0 else { return segment.text }
        var out = ""
        for index in words.indices where !drop[index] {
            out = Self.join(out, words[index].text)
        }
        return out
    }

    private func heard(_ word: Word, pending: [Word]) -> Bool {
        let lo = word.start - Self.echoWindow
        let hi = word.start + Self.echoWindow
        var low = 0
        var high = systemWords.count
        while low < high {
            let mid = (low + high) / 2
            if systemWords[mid].start < lo { low = mid + 1 } else { high = mid }
        }
        var index = low
        while index < systemWords.count, systemWords[index].start <= hi {
            if systemWords[index].key == word.key { return true }
            index += 1
        }
        for other in pending where other.start >= lo && other.start <= hi && other.key == word.key {
            return true
        }
        return false
    }

    static func spread(_ text: String, from start: TimeInterval, to end: TimeInterval) -> [Word] {
        let parts = text.split(whereSeparator: \.isWhitespace)
        guard !parts.isEmpty else { return [] }
        let span = max(0, end - start)
        let step = span / Double(parts.count)
        return parts.enumerated().map { index, part in
            Word(text: String(part), start: start + step * Double(index), end: start + step * Double(index + 1))
        }
    }

    static func key(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.count)
        for character in text.lowercased() where character.isLetter || character.isNumber {
            out.append(character)
        }
        return out
    }

    private static func join(_ a: String, _ b: String) -> String {
        a.isEmpty ? b : a + " " + b
    }
}
