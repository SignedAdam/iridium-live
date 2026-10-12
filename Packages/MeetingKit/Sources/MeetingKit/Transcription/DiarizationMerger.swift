import Foundation

public enum DiarizationMerger {

    public static func mergeChannels(_ channels: [(speaker: String, words: [TranscriptWord])]) -> [TranscriptWord] {
        var all: [TranscriptWord] = []
        for channel in channels {
            for var word in channel.words {
                if word.speakerID == nil { word.speakerID = channel.speaker }
                all.append(word)
            }
        }
        return all.sorted { $0.start < $1.start }
    }

    public static func assignSpeakers(words: [TranscriptWord], segments: [DiarizationSegment], fallback: String) -> [TranscriptWord] {
        guard !segments.isEmpty else {
            return words.map { word in
                var w = word
                if w.speakerID == nil { w.speakerID = fallback }
                return w
            }
        }
        return words.map { word in
            var w = word
            var bestID: String?
            var bestOverlap: TimeInterval = 0
            for seg in segments {
                let overlap = min(w.end, seg.end) - max(w.start, seg.start)
                if overlap > bestOverlap {
                    bestOverlap = overlap
                    bestID = seg.speakerID
                }
            }
            if let id = bestID {
                w.speakerID = id
            } else {
                let mid = (w.start + w.end) / 2
                let nearest = segments.min {
                    abs(midpoint($0) - mid) < abs(midpoint($1) - mid)
                }
                w.speakerID = nearest?.speakerID ?? fallback
            }
            return w
        }
    }

    static let interruptionGap: TimeInterval = 0.3
    static let softMaxUtterance: TimeInterval = 20
    static let hardMaxUtterance: TimeInterval = 40

    public static func buildTurns(from words: [TranscriptWord]) -> [SpeakerTurn] {
        let timeline = words.enumerated()
            .filter { $0.element.text.contains(where: { $0.isLetter || $0.isNumber }) }
            .sorted { ($0.element.start, $0.offset) < ($1.element.start, $1.offset) }
            .map(\.element)
        let longestWord = timeline.map { $0.end - $0.start }.max() ?? 0

        func othersSpeak(from: TimeInterval, to: TimeInterval, except speaker: String) -> Bool {
            var lo = 0, hi = timeline.count
            while lo < hi {
                let mid = (lo + hi) / 2
                if timeline[mid].start < to { lo = mid + 1 } else { hi = mid }
            }
            var i = lo - 1
            while i >= 0 {
                let w = timeline[i]
                if w.start < from - longestWord { break }
                if w.end > from, (w.speakerID ?? defaultSpeaker) != speaker { return true }
                i -= 1
            }
            return false
        }

        var bySpeaker: [String: [(index: Int, word: TranscriptWord)]] = [:]
        var speakerOrder: [String] = []
        for (index, word) in words.enumerated() {
            let speaker = word.speakerID ?? defaultSpeaker
            if bySpeaker[speaker] == nil { speakerOrder.append(speaker) }
            bySpeaker[speaker, default: []].append((index, word))
        }

        var utterances: [(speaker: String, firstIndex: Int, words: [TranscriptWord])] = []
        for speaker in speakerOrder {
            let own = bySpeaker[speaker]!.sorted { ($0.word.start, $0.index) < ($1.word.start, $1.index) }
            var current: [TranscriptWord] = []
            var firstIndex = 0
            for (index, word) in own {
                if let first = current.first, let previous = current.last {
                    let gap = word.start - previous.end
                    let length = previous.end - first.start
                    let interrupted = gap >= interruptionGap
                        && othersSpeak(from: previous.end, to: word.start, except: speaker)
                    let tooLong = length >= hardMaxUtterance
                        || (length >= softMaxUtterance && endsSentence(previous.text))
                    if interrupted || tooLong {
                        utterances.append((speaker, firstIndex, current))
                        current = []
                    }
                }
                if current.isEmpty { firstIndex = index }
                current.append(word)
            }
            if !current.isEmpty { utterances.append((speaker, firstIndex, current)) }
        }
        utterances.sort { ($0.words[0].start, $0.firstIndex) < ($1.words[0].start, $1.firstIndex) }

        var turns: [SpeakerTurn] = []
        for utterance in utterances {
            let end = utterance.words.map(\.end).max() ?? utterance.words[0].end
            if var last = turns.last, last.speakerID == utterance.speaker {
                last.words.append(contentsOf: utterance.words)
                last.end = max(last.end, end)
                turns[turns.count - 1] = last
            } else {
                turns.append(SpeakerTurn(speakerID: utterance.speaker, start: utterance.words[0].start,
                                         end: end, text: "", words: utterance.words))
            }
        }
        for i in turns.indices { turns[i].text = joinWords(turns[i].words) }
        return turns
    }

    private static let defaultSpeaker = "Speaker"

    private static func endsSentence(_ token: String) -> Bool {
        guard let last = token.trimmingCharacters(in: .whitespaces).last else { return false }
        return last == "." || last == "?" || last == "!"
    }

    public static func makeTurns(words: [TranscriptWord], segments: [DiarizationSegment], fallback: String) -> [SpeakerTurn] {
        buildTurns(from: assignSpeakers(words: words, segments: segments, fallback: fallback))
    }

    private static func midpoint(_ seg: DiarizationSegment) -> TimeInterval {
        (seg.start + seg.end) / 2
    }

    static func joinWords(_ words: [TranscriptWord]) -> String {
        var result = ""
        let noLeadingSpace = Set<Character>([".", ",", "!", "?", ";", ":", ")", "]", "}", "'", "’", "”", "%"])
        for word in words {
            let token = word.text.trimmingCharacters(in: .whitespaces)
            if token.isEmpty { continue }
            if result.isEmpty {
                result = token
            } else if let first = token.first, noLeadingSpace.contains(first) {
                result += token
            } else {
                result += " " + token
            }
        }
        return result
    }
}
