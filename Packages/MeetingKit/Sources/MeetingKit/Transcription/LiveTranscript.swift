import Foundation

public struct LiveTranscript: Equatable, Sendable {
    public struct Paragraph: Identifiable, Equatable, Sendable {
        public let id: UUID
        public let kind: AudioStreamKind
        public var text: String
        public var pending: String
    }

    struct Segment: Equatable, Sendable {
        let id: UUID
        let kind: AudioStreamKind
        let start: TimeInterval
        let end: TimeInterval
        let text: String
    }

    static let echoWindow: TimeInterval = 2.5
    static let echoMinWords = 3
    static let echoOverlap = 0.6

    private(set) var finals: [Segment] = []
    private(set) var volatile: [AudioStreamKind: Segment] = [:]

    public init() {}

    public var isEmpty: Bool { finals.isEmpty && volatile.isEmpty }

    public mutating func apply(kind: AudioStreamKind, text: String, start: TimeInterval, end: TimeInterval, isFinal: Bool) {
        var text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.contains(where: { $0.isLetter || $0.isNumber }) { text = "" }
        let id = volatile[kind]?.id ?? UUID()
        guard isFinal else {
            volatile[kind] = text.isEmpty ? nil : Segment(id: id, kind: kind, start: start, end: end, text: text)
            return
        }
        volatile[kind] = nil
        guard !text.isEmpty else { return }
        let segment = Segment(id: id, kind: kind, start: start, end: end, text: text)
        let index = finals.firstIndex { $0.start > start } ?? finals.endIndex
        finals.insert(segment, at: index)
        pruneEcho(around: segment)
    }

    public mutating func discardPending(_ kind: AudioStreamKind) {
        volatile[kind] = nil
    }

    public var paragraphs: [Paragraph] {
        let pending = Set(volatile.values.map(\.id))
        let ordered = (finals + volatile.values).sorted {
            $0.start != $1.start ? $0.start < $1.start : $0.kind.rawValue < $1.kind.rawValue
        }
        var out: [Paragraph] = []
        for segment in ordered {
            let isPending = pending.contains(segment.id)
            if var last = out.last, last.kind == segment.kind {
                if isPending {
                    last.pending = Self.join(last.pending, segment.text)
                } else {
                    last.text = Self.join(last.text, segment.text)
                }
                out[out.count - 1] = last
            } else {
                out.append(Paragraph(id: segment.id, kind: segment.kind,
                                     text: isPending ? "" : segment.text,
                                     pending: isPending ? segment.text : ""))
            }
        }
        return out
    }

    private mutating func pruneEcho(around segment: Segment) {
        let lo = segment.start - Self.echoWindow
        let hi = segment.end + Self.echoWindow
        let systemNearby = finals.filter { $0.kind == .system && $0.end >= lo - Self.echoWindow && $0.start <= hi + Self.echoWindow }
        guard !systemNearby.isEmpty else { return }
        finals.removeAll { mic in
            guard mic.kind == .mic, mic.end >= lo, mic.start <= hi else { return false }
            let words = Self.words(mic.text)
            guard words.count >= Self.echoMinWords else { return false }
            let heard = Set(systemNearby
                .filter { $0.end >= mic.start - Self.echoWindow && $0.start <= mic.end + Self.echoWindow }
                .flatMap { Self.words($0.text) })
            let repeated = words.filter(heard.contains).count
            return Double(repeated) / Double(words.count) >= Self.echoOverlap
        }
    }

    static func words(_ text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    private static func join(_ a: String, _ b: String) -> String {
        a.isEmpty ? b : a + " " + b
    }
}
