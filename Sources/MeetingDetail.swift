import AppKit
import SwiftUI
@preconcurrency import MeetingKit

@MainActor @Observable
final class MeetingsUI {
    var tab = MeetingTab.transcript
    var speakers = false
    var confirmDelete = false
}

struct MeetingDetail: View {
    let meeting: Meeting
    let meetings: MeetingsModel
    @Bindable var ui: MeetingsUI
    @State private var title = ""
    @State private var copied = false
    @State private var preparing = false
    @FocusState private var titleFocused: Bool

    private var transcribing: Bool { meeting.state == .running }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(.white.opacity(0.08)).frame(height: 1)
            Segments(selection: $ui.tab, options: MeetingTab.allCases.map { ($0, $0.title) })
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 4)
            content
        }
        .onAppear { title = meeting.title }
        .onChange(of: meeting.id) { title = meeting.title }
        .onChange(of: meeting.title) { if !titleFocused { title = meeting.title } }
        .onChange(of: titleFocused) { _, focused in if !focused { commitTitle() } }
        .task(id: meeting.id) {
            preparing = true
            await meetings.preparePlayer(for: meeting.id)
            preparing = false
        }
        .onDisappear {
            meetings.player.stop()
            MeetingsWindow.escape = nil
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 9) {
                    TextField("Title", text: $title)
                        .textFieldStyle(.plain)
                        .font(tiktok(19, "Medium"))
                        .foregroundStyle(.white.opacity(0.98))
                        .focused($titleFocused)
                        .onSubmit { commitTitle(); titleFocused = false }
                    HStack(spacing: 7) {
                        MetaChip(symbol: "calendar", text: meeting.startedAt.formatted(date: .abbreviated, time: .shortened))
                        MetaChip(symbol: "clock", text: formatTimecode(meeting.duration))
                        if meeting.engineID != nil {
                            MetaChip(symbol: "cpu", text: meetings.engineName(meeting.engineID))
                        }
                        if meeting.hasMic { MetaChip(symbol: "mic.fill", text: "Mic") }
                        if meeting.hasSystem { MetaChip(symbol: "speaker.wave.2.fill", text: "System audio") }
                    }
                }
                Spacer(minLength: 8)
                actions
            }
            PlayerBar(player: meetings.player, ready: meetings.playerMeetingID == meeting.id, preparing: preparing)
            if meeting.needsSpeakerAssignment {
                let count = meeting.transcript?.speakerIDs.filter { $0 != AudioStreamKind.mic.defaultSpeakerLabel }.count ?? 0
                Button("Assign speakers, \(count) detected") { openSpeakers() }
                    .buttonStyle(AccentButton())
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .padding(.bottom, 13)
    }

    @ViewBuilder private var actions: some View {
        HStack(spacing: 7) {
            if transcribing {
                HStack(spacing: 7) {
                    Spinner().frame(width: 12, height: 12)
                    Text(meetings.progress[meeting.id].map { "\(Int($0 * 100))%" } ?? "Working")
                        .font(tiktok(12))
                        .monospacedDigit()
                        .foregroundStyle(.white.opacity(0.85))
                    if meetings.slow.contains(meeting.id) {
                        Text("Taking longer than expected")
                            .font(tiktok(11.5))
                            .foregroundStyle(.white.opacity(0.78))
                    }
                }
                MeetingIconButton(symbol: "xmark", tip: "Cancel", tint: accent) {
                    meetings.cancelTranscription(meeting.id)
                }
            } else if meeting.state == .failed {
                Button("Retry") { meetings.transcribe(meeting.id) }.buttonStyle(AccentButton())
            } else if meeting.state != .done {
                Button("Transcribe") { meetings.transcribe(meeting.id) }.buttonStyle(AccentButton())
            }
            if meeting.transcript != nil {
                MeetingIconButton(symbol: copied ? "checkmark" : "doc.on.doc", tip: "Copy transcript") { copy() }
            }
            MeetingMenuButton(items: moreItems)
        }
    }

    private var moreItems: [MenuItem] {
        var items: [MenuItem] = []
        if meeting.state == .done {
            items.append(MenuItem(id: "retranscribe", title: "Re-transcribe", symbol: "arrow.clockwise",
                                  action: { meetings.transcribe(meeting.id) }))
            if meetings.canSummarize {
                items.append(MenuItem(id: "summarize",
                                      title: meeting.summary == nil ? "Summarize" : "Regenerate summary",
                                      symbol: "sparkles",
                                      action: { meetings.summarize(meeting.id) }))
            }
        }
        if meeting.transcript != nil {
            items.append(MenuItem(id: "speakers", title: "Rename speakers", symbol: "person.2",
                                  action: { openSpeakers() }))
            items.append(.separator())
            for format in TranscriptExportFormat.allCases {
                items.append(MenuItem(id: "export." + format.rawValue, title: "Export \(format.displayName)",
                                      symbol: "square.and.arrow.up", action: { export(format) }))
            }
        }
        items.append(.separator())
        items.append(MenuItem(id: "reveal", title: "Reveal in Finder", symbol: "folder", action: { reveal() }))
        items.append(MenuItem(id: "archive", title: meeting.isArchived ? "Unarchive" : "Archive",
                              symbol: meeting.isArchived ? "tray.and.arrow.up" : "archivebox",
                              action: { meetings.setArchived(meeting.id, !meeting.isArchived) }))
        items.append(MenuItem(id: "delete", title: "Delete", symbol: "trash", destructive: true, action: {
            ui.confirmDelete = true
            MeetingsWindow.escape = { ui.confirmDelete = false; MeetingsWindow.escape = nil; return true }
        }))
        return items
    }

    @ViewBuilder private var content: some View {
        switch ui.tab {
        case .transcript:
            TranscriptTab(meeting: meeting, meetings: meetings, player: meetings.player).id(meeting.id)
        case .summary:
            SummaryTab(meeting: meeting, meetings: meetings, player: meetings.player)
        case .actions:
            ActionsTab(meeting: meeting, meetings: meetings)
        case .chat:
            ChatTab(meeting: meeting, meetings: meetings).id(meeting.id)
        }
    }

    private func openSpeakers() {
        ui.speakers = true
        MeetingsWindow.escape = { ui.speakers = false; MeetingsWindow.escape = nil; return true }
    }
}

struct MeetingOverlays: View {
    let meeting: Meeting
    let meetings: MeetingsModel
    @Bindable var ui: MeetingsUI

    var body: some View {
        ZStack {
            if ui.confirmDelete {
                deleteConfirm.transition(.opacity)
            } else if ui.speakers {
                SpeakerSheet(meeting: meeting, meetings: meetings) { close() }
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.15), value: ui.speakers)
        .animation(.easeOut(duration: 0.15), value: ui.confirmDelete)
    }

    private var deleteConfirm: some View {
        ZStack {
            Color.black.opacity(0.45).ignoresSafeArea().onTapGesture { close() }
            VStack(alignment: .leading, spacing: 12) {
                Text("Delete this meeting?")
                    .font(tiktok(15, "Medium"))
                    .foregroundStyle(.white.opacity(0.95))
                Text("This removes the audio and the transcript. Archive keeps the audio.")
                    .font(tiktok(12.5))
                    .foregroundStyle(.white.opacity(0.78))
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Spacer(minLength: 0)
                    Button("Cancel") { close() }.buttonStyle(GlassButton())
                    Button("Delete") {
                        close()
                        meetings.delete(meeting.id)
                    }
                    .buttonStyle(AccentButton())
                }
            }
            .padding(18)
            .frame(width: 360)
            .background(Glass(cornerRadius: 16, tint: 1).shadow(color: .black.opacity(0.5), radius: 26, y: 10))
        }
    }

    private func close() {
        ui.speakers = false
        ui.confirmDelete = false
        MeetingsWindow.escape = nil
    }
}

extension MeetingDetail {
    private func commitTitle() {
        let wanted = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !wanted.isEmpty else {
            title = meeting.title
            return
        }
        guard wanted != meeting.title else { return }
        meetings.rename(meeting.id, to: wanted)
    }

    private func copy() {
        guard let text = meetings.copyText(meeting.id) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copied = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.2))
            copied = false
        }
    }

    private func reveal() {
        guard let folder = meetings.folderURL(meeting.id) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([folder])
    }

    private func export(_ format: TranscriptExportFormat) {
        MeetingExport.save(meeting.id, as: format, meetings: meetings)
    }
}

@MainActor
enum MeetingExport {
    static func sanitize(_ name: String, _ format: TranscriptExportFormat) -> String {
        let banned = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        let cleaned = name.components(separatedBy: banned).joined(separator: "-")
        return cleaned.isEmpty ? "meeting." + format.fileExtension : cleaned
    }

    static func write(_ id: UUID, as format: TranscriptExportFormat, meetings: MeetingsModel, into folder: URL) -> URL? {
        guard let result = meetings.export(id, as: format) else { return nil }
        let url = folder.appendingPathComponent(sanitize(result.fileName, format))
        do {
            try result.text.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            return nil
        }
    }

    static func save(_ id: UUID, as format: TranscriptExportFormat, meetings: MeetingsModel) {
        guard let result = meetings.export(id, as: format) else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = sanitize(result.fileName, format)
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? result.text.write(to: url, atomically: true, encoding: .utf8)
    }
}

struct MetaChip: View {
    let symbol: String
    let text: String

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: symbol).font(.system(size: 9.5, weight: .medium))
            Text(text).font(tiktok(11.5))
        }
        .foregroundStyle(.white.opacity(0.85))
        .padding(.horizontal, 8)
        .frame(height: 21)
        .background(Pill(fill: 0.07))
    }
}

struct MeetingIconButton: View {
    let symbol: String
    let tip: String
    var tint: Color = .white
    let action: @MainActor () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(tint.opacity(hovering ? 1 : 0.85))
                .frame(width: 28, height: 24)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(.white.opacity(hovering ? 0.14 : 0.08))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.white.opacity(0.12))))
                .contentShape(Rectangle())
        }
        .buttonStyle(Pressable())
        .onHover { hovering = $0 }
        .tip(tip)
    }
}

struct MeetingMenuButton: View {
    let items: [MenuItem]
    @State private var rect = MeetingRect()
    @State private var hovering = false

    var body: some View {
        Button {
            if let frame = rect.screenRect {
                MenuPanel.show(items, under: frame)
            } else {
                MenuPanel.show(items, at: NSEvent.mouseLocation)
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(hovering ? 1 : 0.85))
                .frame(width: 28, height: 24)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(.white.opacity(hovering ? 0.14 : 0.08))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.white.opacity(0.12))))
                .contentShape(Rectangle())
        }
        .buttonStyle(Pressable())
        .onHover { hovering = $0 }
        .tip("More")
        .background(MeetingRectReader(box: rect))
    }
}

@MainActor
final class MeetingRect {
    weak var view: NSView?

    var screenRect: NSRect? {
        guard let view, let window = view.window else { return nil }
        return window.convertToScreen(view.convert(view.bounds, to: nil))
    }
}

struct MeetingRectReader: NSViewRepresentable {
    let box: MeetingRect

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        box.view = view
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        box.view = view
    }
}

struct AccentButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Surface(configuration: configuration)
    }

    private struct Surface: View {
        let configuration: Configuration
        @Environment(\.isEnabled) private var isEnabled
        @State private var hovering = false

        var body: some View {
            configuration.label
                .font(tiktok(12, "Medium"))
                .foregroundStyle(.white)
                .padding(.horizontal, 13)
                .frame(height: 25)
                .background(Capsule().fill(accent.opacity(configuration.isPressed ? 1 : hovering ? 0.95 : 0.85)))
                .opacity(isEnabled ? 1 : 0.4)
                .contentShape(Capsule())
                .onHover { hovering = $0 }
                .animation(.easeOut(duration: 0.12), value: hovering)
        }
    }
}

struct PlayerBar: View {
    @Bindable var player: MeetingPlayer
    let ready: Bool
    let preparing: Bool
    @State private var hovering = false

    private var fraction: Double {
        player.duration > 0 ? min(1, player.currentTime / player.duration) : 0
    }

    var body: some View {
        HStack(spacing: 10) {
            Button {
                if player.isPlaying { player.pause() } else { player.play() }
            } label: {
                Group {
                    if preparing && !ready {
                        Spinner().frame(width: 12, height: 12)
                    } else {
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.92))
                    }
                }
                .frame(width: 20, height: 20)
                .contentShape(Circle())
            }
            .buttonStyle(Pressable())
            .disabled(!ready)
            .tip(player.isPlaying ? "Pause" : "Play")

            Text(formatTimecode(player.currentTime))
                .font(tiktok(11))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.78))
                .frame(width: 40, alignment: .leading)
            Scrubber(fraction: fraction) { share in player.seek(to: share * player.duration) }
                .frame(maxWidth: .infinity)
            Text(formatTimecode(player.duration))
                .font(tiktok(11))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.78))
                .frame(width: 40, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.white.opacity(hovering ? 0.08 : 0.05))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.white.opacity(0.1))))
        .opacity(ready || preparing ? 1 : 0.55)
        .onHover { inside in withAnimation(.easeOut(duration: 0.16)) { hovering = inside } }
    }
}

struct Scrubber: View {
    let fraction: Double
    let seek: (Double) -> Void

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.14)).frame(height: 3.5)
                Capsule().fill(.white.opacity(0.75)).frame(width: max(0, width * fraction), height: 3.5)
                Circle().fill(.white)
                    .frame(width: 8, height: 8)
                    .shadow(color: .black.opacity(0.4), radius: 1.5, y: 1)
                    .offset(x: max(0, min(width - 8, width * fraction - 4)))
            }
            .frame(maxHeight: .infinity, alignment: .center)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { gesture in
                seek(min(1, max(0, gesture.location.x / max(1, width))))
            })
        }
        .frame(height: 14)
    }
}
