import AppKit
import Observation
import SwiftUI

/// The colour of everything the model was allowed to read but not change.
let contextOrange = Color(red: 1.0, green: 0.64, blue: 0.21)

/// One cleanup call exactly as the engine ran it: the phrase, the earlier text it was shown, the cues and rules that
/// applied, what came back and whether it was used.
struct CorrectionRun: Codable, Equatable, Sendable {
    /// A rewrite the model asked for in an earlier sentence.
    struct Edit: Codable, Equatable, Sendable {
        /// An earlier phrase as it reads after the edit.
        struct Phrase: Codable, Equatable, Sendable {
            var id: String
            var text: String
        }

        var find: String
        var replace: String
        var at: Int
        var applied: Bool
        var phrases: [Phrase]?
    }

    var kind: String
    var input: String
    var context: String
    var contextSentences: Int?
    var reach: Int?
    var cues: [String]?
    var rules: [String]?
    var instructions: Bool?
    var output: String
    var rejected: String?
    var accepted: Bool
    var skipped: Bool
    var note: String
    var edit: Edit?
    var ms: Double?

    /// What this call is called in the view.
    var title: String {
        switch kind {
        case "polish": "Polish"
        case "correct": "Correction"
        default: "Cleanup"
        }
    }

    var changedText: Bool { output != input }
    var usedContext: Bool { !context.isEmpty || kind == "polish" }
}

/// One recording: the phrases that belong to it and every cleanup call it made, in order.
struct CorrectionSession: Identifiable, Equatable {
    struct Call: Identifiable, Equatable {
        let id: Int
        let run: CorrectionRun
        let stats: PhraseTiming.Cleanup?
        let phrase: String?
    }

    let id: String
    let time: Date
    let entries: [HistoryEntry]
    let calls: [Call]

    var text: String { entries.map(\.text).filter { !$0.isEmpty }.joined(separator: " ") }

    /// The words as they were heard, one chunk per call, so a call can be pointed at inside the transcript.
    var heardChunks: [(call: Int, text: String)] {
        calls.filter { $0.run.kind != "polish" }.map { ($0.id, $0.run.input) }
    }

    var spend: Double { calls.reduce(0) { $0 + ($1.stats?.costUsd ?? 0) } }
    var changes: Int { calls.filter { $0.run.changedText || $0.run.edit?.applied == true }.count }

    /// Groups the history into recordings, newest first, keeping only the ones that recorded their cleanup calls.
    static func sessions(in history: [HistoryEntry]) -> [CorrectionSession] {
        var groups: [[HistoryEntry]] = []
        for entry in history {
            if let last = groups.last?.last, last.session == entry.session, entry.session != nil,
               last.time.distance(to: entry.time) < 900 {
                groups[groups.count - 1].append(entry)
            } else {
                groups.append([entry])
            }
        }
        return groups.reversed().compactMap { entries in
            var calls: [Call] = []
            for entry in entries {
                for run in entry.corrections ?? [] {
                    let stats = run.kind == "polish" ? entry.polish?.cleanup : entry.timing?.cleanup
                    calls.append(Call(id: calls.count, run: run, stats: stats, phrase: entry.phrase))
                }
            }
            guard !calls.isEmpty, let first = entries.first else { return nil }
            return CorrectionSession(id: first.phrase ?? first.id.uuidString, time: first.time, entries: entries,
                                     calls: calls)
        }
    }

    /// The calls whose text this call was shown as context.
    func contextCalls(of call: Call) -> Set<Int> {
        let earlier = calls.filter { $0.id < call.id && $0.run.kind != "polish" }
        if call.run.kind == "polish" { return Set(earlier.map(\.id)) }
        let seen = CorrectionSession.plain(call.run.context)
        guard !seen.isEmpty else { return [] }
        return Set(earlier.filter { other in
            let text = CorrectionSession.plain(other.run.output)
            return !text.isEmpty && seen.contains(text)
        }.map(\.id))
    }

    /// The part of the context that came from before this recording, such as the note being dictated into. Empty
    /// when the earlier phrases cannot be found in it, so nothing is shown that may be wrong.
    func foreignContext(of call: Call) -> String {
        let earlier = calls.filter { $0.id < call.id && !$0.run.output.isEmpty }
        guard !earlier.isEmpty else { return call.run.context.trimmingCharacters(in: .whitespaces) }
        for other in earlier {
            guard let range = call.run.context.range(of: other.run.output) else { continue }
            return String(call.run.context[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
        }
        return ""
    }

    private static func plain(_ text: String) -> String {
        text.lowercased().filter { !$0.isPunctuation }.split(separator: " ").joined(separator: " ")
    }
}

/// A word-level difference between what was heard and what the model wrote.
enum DiffPiece: Equatable {
    case same(String)
    case removed(String)
    case added(String)
}

/// What makes two words the same word: punctuation and capitalisation changes are not worth marking.
private func diffKey(_ word: String) -> String {
    word.lowercased().filter { $0.isLetter || $0.isNumber }
}

/// Word-level diff, longest common subsequence, with neighbouring pieces of the same kind merged so a rewritten
/// phrase reads as one change.
func wordDiff(_ before: String, _ after: String) -> [DiffPiece] {
    let old = before.split(separator: " ").map(String.init)
    let new = after.split(separator: " ").map(String.init)
    let oldKeys = old.map(diffKey), newKeys = new.map(diffKey)
    var table = [[Int]](repeating: [Int](repeating: 0, count: new.count + 1), count: old.count + 1)
    if !old.isEmpty && !new.isEmpty {
        for row in stride(from: old.count - 1, through: 0, by: -1) {
            for column in stride(from: new.count - 1, through: 0, by: -1) {
                table[row][column] = oldKeys[row] == newKeys[column]
                    ? table[row + 1][column + 1] + 1
                    : max(table[row + 1][column], table[row][column + 1])
            }
        }
    }
    var pieces: [DiffPiece] = []
    func push(_ piece: DiffPiece) {
        switch (pieces.last, piece) {
        case let (.same(have), .same(word)): pieces[pieces.count - 1] = .same(have + " " + word)
        case let (.removed(have), .removed(word)): pieces[pieces.count - 1] = .removed(have + " " + word)
        case let (.added(have), .added(word)): pieces[pieces.count - 1] = .added(have + " " + word)
        default: pieces.append(piece)
        }
    }
    var row = 0, column = 0
    while row < old.count && column < new.count {
        if oldKeys[row] == newKeys[column] {
            push(.same(new[column]))
            row += 1
            column += 1
        } else if table[row + 1][column] >= table[row][column + 1] {
            push(.removed(old[row]))
            row += 1
        } else {
            push(.added(new[column]))
            column += 1
        }
    }
    while row < old.count {
        push(.removed(old[row]))
        row += 1
    }
    while column < new.count {
        push(.added(new[column]))
        column += 1
    }
    return pieces
}

/// Renders a diff the way a patch reads: what went is struck through, what came is lit up.
func diffText(_ pieces: [DiffPiece], size: CGFloat) -> Text {
    var line = AttributedString()
    for piece in pieces {
        var part: AttributedString
        switch piece {
        case let .same(words):
            part = AttributedString(words)
            part.foregroundColor = .white.opacity(0.75)
        case let .removed(words):
            part = AttributedString(words)
            part.foregroundColor = .white.opacity(0.5)
            part.strikethroughStyle = .single
            part.backgroundColor = .white.opacity(0.07)
        case let .added(words):
            part = AttributedString(words)
            part.foregroundColor = .white
            part.backgroundColor = accent.opacity(0.33)
        }
        part.font = tiktok(13)
        if !line.characters.isEmpty { line += AttributedString(" ") }
        line += part
    }
    return Text(line).font(tiktok(size))
}

/// Which recording the corrections window is looking at, so opening it again from a history row can move it.
@MainActor
@Observable
final class CorrectionsChoice {
    static let shared = CorrectionsChoice()
    var session: String?

    /// Points the window at the recording a history entry belongs to.
    func show(_ entry: HistoryEntry, in history: [HistoryEntry]) {
        session = CorrectionSession.sessions(in: history).first { group in
            group.entries.contains { $0.id == entry.id }
        }?.id
    }
}

struct CorrectionsView: View {
    @Bindable var model: AppModel
    @State private var call: Int?
    private let choice = CorrectionsChoice.shared

    private var sessions: [CorrectionSession] { CorrectionSession.sessions(in: model.history) }

    private var shown: CorrectionSession? {
        sessions.first { $0.id == choice.session } ?? sessions.first
    }

    var body: some View {
        HStack(spacing: 0) {
            list
            Rectangle().fill(.white.opacity(0.1)).frame(width: 1)
            if let session = shown {
                CorrectionDetail(session: session, live: live(session), selected: $call)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .id(session.id)
            } else {
                Text("No corrections recorded yet.")
                    .font(tiktok(13))
                    .foregroundStyle(.white.opacity(0.7))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Glass(cornerRadius: 16))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .foregroundStyle(.white.opacity(0.9))
        .onChange(of: model.history.count) {
            guard model.recording || model.finishing, let newest = sessions.first else { return }
            choice.session = newest.id
            call = newest.calls.last?.id
        }
    }

    /// What the engine is doing right now, if this recording is the one being spoken.
    private func live(_ session: CorrectionSession) -> String? {
        guard session.id == sessions.first?.id else { return nil }
        if model.recording { return "Listening, cleanup runs at each pause" }
        return model.finishing ? "Polishing the whole recording" : nil
    }

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(sessions) { session in
                    let chosen = session.id == shown?.id
                    Button {
                        choice.session = session.id
                        call = nil
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                Text(session.time.formatted(date: .omitted, time: .shortened))
                                    .font(tiktok(11.5, "Medium"))
                                    .monospacedDigit()
                                if live(session) != nil {
                                    Circle().fill(accent).frame(width: 6, height: 6)
                                }
                                Spacer(minLength: 4)
                                Text("\(session.calls.count)")
                                    .font(tiktok(11))
                                    .foregroundStyle(.white.opacity(0.6))
                                    .monospacedDigit()
                            }
                            Text(session.text.isEmpty ? "No text" : session.text)
                                .font(tiktok(12))
                                .foregroundStyle(.white.opacity(chosen ? 0.9 : 0.65))
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                            Text(session.time.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)))
                                .font(tiktok(10.5))
                                .foregroundStyle(.white.opacity(0.45))
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(.white.opacity(chosen ? 0.08 : 0)))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(8)
        }
        .frame(width: 252)
        .scrollIndicators(.visible)
    }
}

/// The transcript of one recording with the context in orange, and every call under it as a diff.
struct CorrectionDetail: View {
    let session: CorrectionSession
    var live: String?
    @Binding var selected: Int?

    private var chosen: CorrectionSession.Call? {
        session.calls.first { $0.id == selected } ?? session.calls.last
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                transcript
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(session.calls) { call in
                        CorrectionCard(call: call, chosen: call.id == chosen?.id,
                                       tap: { selected = selected == call.id ? nil : call.id })
                    }
                    if let live { pending(live) }
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.visible)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text(session.time.formatted(date: .abbreviated, time: .shortened))
                .font(tiktok(14, "Medium"))
            Text("\(session.calls.count) calls")
                .font(tiktok(11.5))
                .foregroundStyle(.white.opacity(0.65))
                .monospacedDigit()
            Text("\(session.changes) changed")
                .font(tiktok(11.5))
                .foregroundStyle(.white.opacity(0.65))
                .monospacedDigit()
            if session.spend > 0 {
                Text(dollars(session.spend))
                    .font(tiktok(11.5))
                    .foregroundStyle(.white.opacity(0.65))
                    .monospacedDigit()
            }
            Spacer(minLength: 0)
            if let live {
                HStack(spacing: 6) {
                    Circle().fill(accent).frame(width: 6, height: 6)
                    Text(live).font(tiktok(11.5)).foregroundStyle(.white.opacity(0.8))
                }
            }
        }
    }

    /// What was transcribed, with the part the chosen call was given as context marked orange.
    private var transcript: some View {
        let marked = chosen.map { session.contextCalls(of: $0) } ?? []
        var line = AttributedString()
        for chunk in session.heardChunks {
            var part = AttributedString(chunk.text)
            part.font = tiktok(13)
            if marked.contains(chunk.call) {
                part.foregroundColor = contextOrange
                part.backgroundColor = contextOrange.opacity(0.14)
            } else if chunk.call == chosen?.id {
                part.foregroundColor = .white
                part.underlineStyle = .single
            } else {
                part.foregroundColor = .white.opacity(0.42)
            }
            if !line.characters.isEmpty { line += AttributedString(" ") }
            line += part
        }
        let foreign = chosen.map { session.foreignContext(of: $0) } ?? ""
        return VStack(alignment: .leading, spacing: 6) {
            Text("Heard").font(tiktok(10.5, "Medium")).kerning(0.8).foregroundStyle(.white.opacity(0.6))
            if !foreign.isEmpty {
                Text("from before this recording: \(foreign)")
                    .font(tiktok(11.5))
                    .foregroundStyle(contextOrange.opacity(0.9))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(line)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            Text("Orange is what the chosen call read as context")
                .font(tiktok(10.5))
                .foregroundStyle(.white.opacity(0.45))
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(.white.opacity(0.05)))
    }

    private func pending(_ message: String) -> some View {
        HStack(spacing: 8) {
            Circle().fill(accent).frame(width: 6, height: 6)
            Text(message).font(tiktok(12)).foregroundStyle(.white.opacity(0.75))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(.white.opacity(0.04)))
    }
}

/// One call: what it was, what it read, and the diff it produced.
struct CorrectionCard: View {
    let call: CorrectionSession.Call
    let chosen: Bool
    let tap: @MainActor () -> Void
    @State private var hovering = false

    private var run: CorrectionRun { call.run }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            top
            if chosen, run.usedContext { context }
            if run.skipped {
                Text(run.input).font(tiktok(13)).foregroundStyle(.white.opacity(0.6))
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                diffText(wordDiff(run.input, run.output), size: 13)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            if let edit = run.edit { earlier(edit) }
            if let rejected = run.rejected { refused(rejected) }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous)
            .fill(.white.opacity(chosen ? 0.07 : hovering ? 0.05 : 0.03)))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous)
            .strokeBorder(.white.opacity(chosen ? 0.16 : 0), lineWidth: 1))
        .contentShape(Rectangle())
        .onTapGesture { tap() }
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }

    private var top: some View {
        HStack(spacing: 8) {
            Text(run.title).font(tiktok(11.5, "Medium"))
            if run.skipped {
                tag("skipped", .white.opacity(0.45))
            } else if !run.accepted {
                tag(run.note.isEmpty ? "not used" : shortNote, accent)
            } else if run.changedText {
                tag("changed", .white.opacity(0.6))
            } else {
                tag("kept", .white.opacity(0.45))
            }
            ForEach(run.cues ?? [], id: \.self) { cue in tag("heard \"\(cue)\"", contextOrange) }
            ForEach(run.rules ?? [], id: \.self) { rule in tag(rule, .white.opacity(0.5)) }
            if run.instructions == true { tag("your instructions", .white.opacity(0.5)) }
            Spacer(minLength: 4)
            if let stats = call.stats {
                Text(stats.modelName).font(tiktok(10.5)).foregroundStyle(.white.opacity(0.5))
                Text(duration(stats.ms)).font(tiktok(10.5)).monospacedDigit().foregroundStyle(.white.opacity(0.5))
                if let cost = stats.costUsd, cost > 0 {
                    Text(dollars(cost)).font(tiktok(10.5)).monospacedDigit().foregroundStyle(.white.opacity(0.5))
                }
            } else if let ms = run.ms {
                Text(duration(ms)).font(tiktok(10.5)).monospacedDigit().foregroundStyle(.white.opacity(0.5))
            }
        }
    }

    private var shortNote: String {
        run.note.contains("unsafe edit") ? "edit refused"
            : run.note.contains("implausible") ? "rewrite refused"
            : run.note.contains("JSON") ? "bad answer"
            : run.note.contains("cut off") ? "cut off" : run.note
    }

    private var context: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(tiktok(10.5, "Medium")).kerning(0.8).foregroundStyle(contextOrange.opacity(0.85))
            Text(run.kind == "polish" ? run.input : (run.context.isEmpty ? "nothing yet" : "…" + run.context))
                .font(tiktok(11.5))
                .foregroundStyle(contextOrange.opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(contextOrange.opacity(0.1)))
    }

    private var label: String {
        if run.kind == "polish" { return "WHOLE RECORDING AS CONTEXT" }
        if let sentences = run.contextSentences {
            return "CONTEXT, LAST \(sentences) SENTENCES, \(run.reach ?? 1) EDITABLE"
        }
        return "CONTEXT"
    }

    private func earlier(_ edit: CorrectionRun.Edit) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(edit.applied ? "EDITED EARLIER" : "EDIT REFUSED")
                .font(tiktok(10.5, "Medium"))
                .kerning(0.8)
                .foregroundStyle(.white.opacity(edit.applied ? 0.6 : 0.45))
            diffText(wordDiff(edit.find, edit.replace), size: 12.5)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(edit.phrases ?? [], id: \.id) { phrase in
                if !phrase.text.isEmpty {
                    Text(phrase.text)
                        .font(tiktok(11.5))
                        .foregroundStyle(.white.opacity(0.65))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(.white.opacity(0.05)))
    }

    private func refused(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("NOT USED").font(tiktok(10.5, "Medium")).kerning(0.8).foregroundStyle(accent.opacity(0.85))
            Text(text)
                .font(tiktok(11.5))
                .foregroundStyle(.white.opacity(0.55))
                .strikethrough()
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(accent.opacity(0.1)))
    }

    private func tag(_ text: String, _ colour: Color) -> some View {
        Text(text)
            .font(tiktok(10.5))
            .foregroundStyle(colour)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(colour.opacity(0.12)))
    }
}
