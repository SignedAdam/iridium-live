import AppKit
import SwiftUI
@preconcurrency import MeetingKit

enum MeetingTab: Hashable, CaseIterable {
    case transcript, summary, actions, chat

    var title: String {
        switch self {
        case .transcript: "Transcript"
        case .summary: "Summary"
        case .actions: "Actions"
        case .chat: "Chat"
        }
    }
}

struct TranscriptTab: View {
    let meeting: Meeting
    let meetings: MeetingsModel
    let player: MeetingPlayer
    @State private var editor: TranscriptEditor
    @State private var dockHeight: CGFloat = 0

    init(meeting: Meeting, meetings: MeetingsModel, player: MeetingPlayer) {
        self.meeting = meeting
        self.meetings = meetings
        self.player = player
        let id = meeting.id
        _editor = State(initialValue: TranscriptEditor { change in
            meetings.editTranscript(id) { transcript in change(&transcript) }
        })
    }

    var body: some View {
        Group {
            if let transcript = meeting.resolvedTranscript, !transcript.turns.isEmpty {
                ZStack(alignment: .bottom) {
                    TranscriptDocumentView(editor: editor, transcript: transcript,
                                           bottomInset: editor.activeLine == nil ? 0 : dockHeight + 12)
                    if let line = editor.activeLine {
                        LineDock(editor: editor, player: player, line: line)
                            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { dockHeight = $0 }
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    } else if editor.showDeletedToast {
                        DeletedToast { editor.undoLastChange() }
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
                .animation(.spring(response: 0.32, dampingFraction: 0.86), value: editor.activeLine == nil)
                .animation(.easeOut(duration: 0.2), value: editor.showDeletedToast)
                .onDisappear { editor.commit() }
            } else if meeting.state == .running {
                running
            } else if meeting.state == .failed {
                MeetingEmptyState(symbol: "exclamationmark.triangle", title: "Transcription failed",
                                  text: meeting.error ?? "Unknown error", action: "Retry") {
                    meetings.transcribe(meeting.id)
                }
            } else {
                MeetingEmptyState(symbol: "text.alignleft", title: "Not transcribed",
                                  text: "Run transcription for a transcript with speakers.", action: "Transcribe") {
                    meetings.transcribe(meeting.id)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var running: some View {
        VStack(spacing: 12) {
            ProgressView(value: meetings.progress[meeting.id] ?? 0)
                .progressViewStyle(.linear)
                .tint(accent)
                .frame(width: 220)
            Text(meetings.progress[meeting.id].map { "Transcribing \(Int($0 * 100))%" } ?? "Transcribing")
                .font(tiktok(12.5))
                .foregroundStyle(.white.opacity(0.85))
            if meetings.slow.contains(meeting.id) {
                Text("Taking longer than expected, still working")
                    .font(tiktok(12))
                    .foregroundStyle(.white.opacity(0.78))
            }
            Button("Cancel") { meetings.cancelTranscription(meeting.id) }
                .buttonStyle(GlassButton())
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct MeetingEmptyState: View {
    let symbol: String
    let title: String
    let text: String
    var action: String? = nil
    var run: (@MainActor () -> Void)? = nil

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.white.opacity(0.8))
            Text(title)
                .font(tiktok(14.5, "Medium"))
                .foregroundStyle(.white.opacity(0.95))
            Text(text)
                .font(tiktok(12.5))
                .foregroundStyle(.white.opacity(0.78))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)
            if let action, let run {
                Button(action) { run() }
                    .buttonStyle(AccentButton())
                    .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct LineDock: View {
    let editor: TranscriptEditor
    let player: MeetingPlayer
    let line: TranscriptLine

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Circle().fill(speakerTint(line.colorIndex)).frame(width: 8, height: 8)
                Text(line.speaker)
                    .font(tiktok(12.5, "Medium"))
                    .foregroundStyle(.white.opacity(0.95))
                    .lineLimit(1)
                Spacer(minLength: 8)
                FormatToggle(symbol: "bold", tip: "Bold (Cmd B)", on: editor.isBold) { editor.toggle(.bold) }
                FormatToggle(symbol: "italic", tip: "Italic (Cmd I)", on: editor.isItalic) { editor.toggle(.italic) }
                FormatToggle(symbol: "underline", tip: "Underline (Cmd U)", on: editor.isUnderline) { editor.toggle(.underline) }
                Rectangle().fill(.white.opacity(0.12)).frame(width: 1, height: 18).padding(.horizontal, 3)
                MeetingIconButton(symbol: "trash", tip: "Delete line", tint: accent) { editor.deleteActiveLine() }
                MeetingIconButton(symbol: "checkmark", tip: "Done (Return)") { editor.deactivate() }
            }
            SnippetPlayerView(player: player, lineID: line.id, lineRange: line.range)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .glass(14)
        .padding(.horizontal, 14)
        .padding(.bottom, 12)
    }
}

private struct FormatToggle: View {
    let symbol: String
    let tip: String
    let on: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(on ? 1 : hovering ? 0.95 : 0.78))
                .frame(width: 26, height: 24)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(on ? accent.opacity(0.35) : .white.opacity(hovering ? 0.09 : 0)))
                .contentShape(Rectangle())
        }
        .buttonStyle(Pressable())
        .onHover { hovering = $0 }
        .tip(tip)
    }
}

private struct DeletedToast: View {
    let undo: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Text("Line deleted")
                .font(tiktok(12.5))
                .foregroundStyle(.white.opacity(0.92))
            Button("Undo", action: undo)
                .buttonStyle(GlassButton())
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .glass(16)
        .padding(.bottom, 14)
    }
}

struct SummaryTab: View {
    let meeting: Meeting
    let meetings: MeetingsModel
    let player: MeetingPlayer

    var body: some View {
        Group {
            if let summary = meeting.summary {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        card(symbol: "sparkles", title: "Summary") {
                            Text(summary.tldr)
                                .font(tiktok(13))
                                .foregroundStyle(.white.opacity(0.95))
                                .lineSpacing(3)
                                .textSelection(.enabled)
                        }
                        if !summary.keyPoints.isEmpty {
                            card(symbol: "list.bullet", title: "Key points") {
                                VStack(alignment: .leading, spacing: 7) {
                                    ForEach(summary.keyPoints, id: \.self) { point in
                                        HStack(alignment: .top, spacing: 8) {
                                            Circle().fill(accent).frame(width: 5, height: 5).padding(.top, 6)
                                            Text(point)
                                                .font(tiktok(12.5))
                                                .foregroundStyle(.white.opacity(0.9))
                                                .textSelection(.enabled)
                                        }
                                    }
                                }
                            }
                        }
                        if !summary.decisions.isEmpty {
                            card(symbol: "checkmark.seal", title: "Decisions") {
                                VStack(alignment: .leading, spacing: 7) {
                                    ForEach(summary.decisions) { decision in
                                        HStack(alignment: .top, spacing: 8) {
                                            Image(systemName: "arrow.right")
                                                .font(.system(size: 10, weight: .semibold))
                                                .foregroundStyle(.white.opacity(0.78))
                                                .padding(.top, 3)
                                            Text(decision.text)
                                                .font(tiktok(12.5))
                                                .foregroundStyle(.white.opacity(0.9))
                                        }
                                    }
                                }
                            }
                        }
                        if !summary.chapters.isEmpty {
                            card(symbol: "list.number", title: "Chapters") {
                                VStack(alignment: .leading, spacing: 4) {
                                    ForEach(summary.chapters) { chapter in
                                        ChapterRow(chapter: chapter, player: player)
                                    }
                                }
                            }
                        }
                        Text("Generated by \(summary.generatedBy)")
                            .font(tiktok(11))
                            .foregroundStyle(.white.opacity(0.78))
                    }
                    .padding(20)
                }
                .scrollContentBackground(.hidden)
            } else {
                empty
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder private var empty: some View {
        if meetings.summarizing.contains(meeting.id) {
            VStack(spacing: 12) {
                Spinner().frame(width: 18, height: 18)
                Text("Summarizing")
                    .font(tiktok(12.5))
                    .foregroundStyle(.white.opacity(0.85))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if !meetings.canSummarize {
            MeetingEmptyState(symbol: "key", title: "No summary key",
                              text: "Summaries, actions and chat need an API key for the chosen provider. Add one in Settings.")
        } else if meeting.state != .done {
            MeetingEmptyState(symbol: "text.alignleft", title: "Transcribe first",
                              text: "Summaries are made from the transcript.")
        } else {
            MeetingEmptyState(symbol: "sparkles", title: "No summary",
                              text: "Generate a short summary, key points, decisions and chapters.",
                              action: "Generate summary") { meetings.summarize(meeting.id) }
        }
    }

    private func card<Content: View>(symbol: String, title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 6) {
                Image(systemName: symbol).font(.system(size: 11, weight: .semibold))
                Text(title).font(tiktok(12, "Medium"))
            }
            .foregroundStyle(.white.opacity(0.95))
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.white.opacity(0.055))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.white.opacity(0.08))))
    }
}

private struct ChapterRow: View {
    let chapter: Chapter
    let player: MeetingPlayer
    @State private var hovering = false

    var body: some View {
        Button { player.seek(to: chapter.start) } label: {
            HStack(spacing: 10) {
                Text(formatTimecode(chapter.start))
                    .font(tiktok(11.5))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.78))
                    .frame(width: 52, alignment: .leading)
                Text(chapter.title)
                    .font(tiktok(12.5))
                    .foregroundStyle(.white.opacity(0.92))
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.white.opacity(hovering ? 0.07 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .tip("Play from here")
    }
}

struct ActionsTab: View {
    let meeting: Meeting
    let meetings: MeetingsModel

    private var items: [ActionItem] { meeting.summary?.actionItems ?? [] }

    var body: some View {
        Group {
            if items.isEmpty {
                MeetingEmptyState(symbol: "checklist", title: "No actions",
                                  text: meeting.summary == nil ? "Generate a summary to pull out action items."
                                                               : "None were found in this meeting.")
            } else {
                ScrollView {
                    VStack(spacing: 9) {
                        ForEach(items) { item in row(item) }
                    }
                    .padding(20)
                }
                .scrollContentBackground(.hidden)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func row(_ item: ActionItem) -> some View {
        HStack(alignment: .top, spacing: 11) {
            Button { meetings.toggleActionItem(item.id, in: meeting.id) } label: {
                Image(systemName: item.done ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 17))
                    .foregroundStyle(item.done ? accent : .white.opacity(0.78))
            }
            .buttonStyle(Pressable())
            VStack(alignment: .leading, spacing: 4) {
                Text(item.text)
                    .font(tiktok(12.5))
                    .strikethrough(item.done)
                    .foregroundStyle(.white.opacity(item.done ? 0.78 : 0.95))
                HStack(spacing: 12) {
                    if let owner = item.owner, !owner.isEmpty {
                        Label(owner, systemImage: "person")
                            .font(tiktok(11.5))
                            .foregroundStyle(.white.opacity(0.78))
                    }
                    if let due = item.due, !due.isEmpty {
                        Label(due, systemImage: "calendar")
                            .font(tiktok(11.5))
                            .foregroundStyle(.white.opacity(0.78))
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(13)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.white.opacity(0.055))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.white.opacity(0.08))))
    }
}

struct ChatTab: View {
    let meeting: Meeting
    let meetings: MeetingsModel
    @State private var input = ""

    var body: some View {
        Group {
            if !meetings.canSummarize {
                MeetingEmptyState(symbol: "key", title: "No chat key",
                                  text: "Chat about a meeting needs an API key for the chosen provider. Add one in Settings.")
            } else if meeting.transcript == nil {
                MeetingEmptyState(symbol: "text.alignleft", title: "Transcribe first",
                                  text: "Chat works over the meeting transcript.")
            } else {
                VStack(spacing: 0) {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 10) {
                                ForEach(meeting.chat) { message in ChatBubble(message: message).id(message.id) }
                                if meetings.chatting.contains(meeting.id) {
                                    Spinner().frame(width: 14, height: 14).id("typing")
                                }
                            }
                            .padding(18)
                        }
                        .scrollContentBackground(.hidden)
                        .onChange(of: meeting.chat.count) {
                            guard let last = meeting.chat.last else { return }
                            withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                        }
                    }
                    Rectangle().fill(.white.opacity(0.08)).frame(height: 1)
                    HStack(spacing: 9) {
                        TextField("Ask about this meeting", text: $input, axis: .vertical)
                            .textFieldStyle(.plain)
                            .font(tiktok(12.5))
                            .lineLimit(1...4)
                            .onSubmit(send)
                        Button(action: send) {
                            Image(systemName: "arrow.up.circle.fill")
                                .font(.system(size: 21))
                                .foregroundStyle(accent)
                        }
                        .buttonStyle(Pressable())
                        .disabled(input.trimmingCharacters(in: .whitespaces).isEmpty || meetings.chatting.contains(meeting.id))
                    }
                    .padding(12)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func send() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !meetings.chatting.contains(meeting.id) else { return }
        input = ""
        meetings.sendChat(text, to: meeting.id)
    }
}

private struct ChatBubble: View {
    let message: ChatMessage

    var body: some View {
        HStack {
            if message.role == .user { Spacer(minLength: 40) }
            Text(message.text)
                .font(tiktok(12.5))
                .textSelection(.enabled)
                .foregroundStyle(.white.opacity(message.role == .user ? 1 : 0.92))
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(message.role == .user ? accent.opacity(0.75) : .white.opacity(0.08)))
            if message.role == .assistant { Spacer(minLength: 40) }
        }
    }
}
