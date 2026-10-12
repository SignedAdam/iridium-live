@preconcurrency import MeetingKit
import SwiftUI

let otherSideLabel = "Others"

struct MeetingPane: View {
    @Bindable var model: AppModel

    var body: some View {
        if let meetings = model.meetings {
            MeetingPaneBody(model: model, meetings: meetings)
        }
    }
}

private struct MeetingPaneBody: View {
    @Bindable var model: AppModel
    @Bindable var meetings: MeetingsModel
    @State private var followTail = true

    private enum Mode { case idle, live, paused, finishing }

    private var coordinator: RecordingCoordinator { meetings.coordinator }
    private var live: LiveTranscriptModel { meetings.live }

    private var mode: Mode {
        switch coordinator.state {
        case .recording: .live
        case .paused: .paused
        case .stopping: .finishing
        default: .idle
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            switch mode {
            case .idle: idle
            case .live, .paused: recording
            case .finishing: finishing
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .font(tiktok(13))
        .foregroundStyle(.white.opacity(0.9))
        .animation(.easeOut(duration: 0.22), value: mode)
    }

    private var header: some View {
        HStack(spacing: 8) {
            MeetingRecordButton(recording: mode == .live || mode == .paused, busy: mode == .finishing,
                                action: meetings.toggleRecording)
                .disabled(mode == .finishing || (mode == .idle && !coordinator.canRecord))
            if mode == .idle || mode == .finishing {
                Text("Meeting").font(tiktok(15, "Medium")).foregroundStyle(.white.opacity(0.95))
            } else {
                Text(formatTimecode(coordinator.elapsed, includeHours: coordinator.elapsed >= 3600))
                    .font(tiktok(16, "Medium"))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.95))
                Text(mode == .paused ? "Paused" : "Recording")
                    .font(tiktok(11.5, "Medium"))
                    .foregroundStyle(.white.opacity(0.78))
            }
            Spacer(minLength: 8)
            if mode == .live || mode == .paused {
                IconToggle(symbol: mode == .paused ? "play.fill" : "pause.fill", isOn: mode == .paused,
                           tip: mode == .paused ? "Resume" : "Pause",
                           action: { mode == .paused ? meetings.resume() : meetings.pause() })
            } else {
                Button("All meetings") { model.openMeetings() }.buttonStyle(GlassButton())
            }
        }
        .frame(height: 32)
    }

    private var idle: some View {
        VStack(alignment: .leading, spacing: 10) {
            sources
            Text(engineNote)
                .font(tiktok(11.5))
                .foregroundStyle(.white.opacity(0.78))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 2)
            if let message = notice {
                Text(message)
                    .font(tiktok(11.5))
                    .foregroundStyle(accent)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let saved = finished {
                savedLine(saved)
            }
            recent
            Spacer(minLength: 0)
        }
    }

    private var sources: some View {
        VStack(spacing: 0) {
            sourceRow("mic", "Microphone") {
                GlassDropdown(selection: microphone, options: microphoneOptions).frame(width: 176)
            }
            divider
            sourceRow("speaker.wave.2", "System audio") {
                GlassSwitch(isOn: $model.settings.meetingSystem)
            }
            divider
            sourceRow("waveform", "Transcription") {
                GlassDropdown(selection: $model.settings.meetingEngine,
                              options: EngineFactory.options.map { ($0.id, $0.name) }).frame(width: 176)
            }
        }
        .padding(.horizontal, 11)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.white.opacity(0.055)))
    }

    private var divider: some View {
        Rectangle().fill(.white.opacity(0.07)).frame(height: 1)
    }

    private func sourceRow(_ symbol: String, _ title: String, @ViewBuilder control: () -> some View) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.8))
                .frame(width: 14)
            Text(title)
            Spacer(minLength: 8)
            control()
        }
        .frame(height: 32)
    }

    private var recent: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("RECENT")
                .font(tiktok(10.5, "Medium"))
                .kerning(0.8)
                .foregroundStyle(.white.opacity(0.78))
                .padding(.leading, 2)
            if meetings.meetings.isEmpty {
                Text("No meetings yet.")
                    .font(tiktok(12.5))
                    .foregroundStyle(.white.opacity(0.78))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 10)
                    .padding(.horizontal, 10)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.white.opacity(0.05)))
            } else {
                VStack(spacing: 2) {
                    ForEach(meetings.meetings.prefix(4)) { meeting in
                        RecentRow(meeting: meeting, progress: meetings.progress[meeting.id],
                                  open: { model.openMeetings(meeting.id) })
                    }
                }
            }
        }
    }

    private var recording: some View {
        VStack(alignment: .leading, spacing: 10) {
            liveSources
            if model.recording {
                dictating
            }
            if let message = notice {
                Text(message)
                    .font(tiktok(11.5))
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            LiveTranscriptView(live: live, status: live.status, following: $followTail)
        }
    }

    private var liveSources: some View {
        HStack(spacing: 8) {
            Image(systemName: "mic").font(.system(size: 10.5, weight: .medium)).foregroundStyle(.white.opacity(0.8))
            LevelMeter(level: coordinator.micAvailable ? Double(coordinator.micLevel) : 0,
                       active: coordinator.micAvailable && mode == .live)
                .frame(width: 40, height: 14)
            Text("You").font(tiktok(11.5, "Medium")).foregroundStyle(.white.opacity(0.85))
            Rectangle().fill(.white.opacity(0.12)).frame(width: 1, height: 14).padding(.horizontal, 2)
            Image(systemName: "speaker.wave.2").font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.white.opacity(0.8))
            LevelMeter(level: coordinator.systemAvailable ? Double(coordinator.systemLevel) : 0,
                       active: coordinator.systemAvailable && mode == .live)
                .frame(width: 40, height: 14)
            TextField(otherSideLabel, text: Bindable(live).otherName)
                .textFieldStyle(.plain)
                .font(tiktok(11.5, "Medium"))
                .foregroundStyle(accent)
                .frame(width: 72)
            Spacer(minLength: 4)
            Text(EngineFactory.name(for: model.settings.meetingEngine))
                .font(tiktok(11))
                .foregroundStyle(.white.opacity(0.78))
        }
        .frame(height: 22)
    }

    private var dictating: some View {
        HStack(spacing: 7) {
            Image(systemName: "mic.fill").font(.system(size: 10, weight: .semibold)).foregroundStyle(accent)
            Text(model.destination.map { "Dictating into \($0). Kept in the meeting." } ?? "Dictating. Kept in the meeting.")
                .font(tiktok(11.5, "Medium"))
                .foregroundStyle(.white.opacity(0.88))
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .frame(height: 26)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(accent.opacity(0.16))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(accent.opacity(0.3))))
        .transition(.opacity)
    }

    private var finishing: some View {
        VStack(spacing: 10) {
            Spinner().frame(width: 16, height: 16)
            Text("Finishing").font(tiktok(13)).foregroundStyle(.white.opacity(0.85))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var engineNote: String {
        let option = EngineFactory.options.first { $0.id == model.settings.meetingEngine }
        guard let option else { return "" }
        return option.local ? "\(option.name) writes the transcript on this Mac when the meeting ends."
            : "\(option.name) writes the transcript in the cloud when the meeting ends."
    }

    private var notice: String? {
        if let error = meetings.lastError { return error }
        let message = coordinator.statusMessage
        return message.isEmpty ? nil : message
    }

    private var finished: Meeting? {
        guard !meetings.isRecording, let id = live.meetingID else { return nil }
        return meetings.meeting(id)
    }

    private func savedLine(_ meeting: Meeting) -> some View {
        HStack(spacing: 10) {
            Text(meeting.state == .running ? "Saved. Transcribing." : "Saved.")
                .font(tiktok(12.5))
                .foregroundStyle(.white.opacity(0.85))
            Spacer(minLength: 0)
            Button("Open") { model.openMeetings(meeting.id) }.buttonStyle(GlassButton())
        }
        .padding(.horizontal, 11)
        .frame(height: 34)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.white.opacity(0.055)))
    }

    private var microphone: Binding<String> {
        Binding(get: { model.settings.meetingMicrophone ?? "" },
                set: { model.settings.meetingMicrophone = $0.isEmpty ? nil : $0 })
    }

    private var microphoneOptions: [(String, String)] {
        [("", "System default")] + meetings.inputDevices.map { ($0.uid, $0.name) }
    }
}

struct MeetingRecordButton: View {
    let recording: Bool
    let busy: Bool
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().fill(accent.opacity(recording ? 0.22 : hovering ? 0.14 : 0.08))
                    .overlay(Circle().strokeBorder(accent.opacity(recording ? 0.42 : 0.22)))
                    .padding(1)
                if busy {
                    Spinner().frame(width: 13, height: 13)
                } else {
                    RoundedRectangle(cornerRadius: recording ? 2.5 : 6, style: .continuous)
                        .fill(accent)
                        .frame(width: recording ? 11 : 12, height: recording ? 11 : 12)
                        .shadow(color: accent.opacity(recording ? 0.9 : 0.5), radius: recording ? 6 : 4)
                }
            }
            .frame(width: 32, height: 32)
            .contentShape(Circle())
        }
        .buttonStyle(Pressable())
        .opacity(isEnabled ? 1 : 0.38)
        .onHover { hovering = $0 }
        .tip(recording ? "Stop meeting" : "Record meeting")
        .animation(.spring(response: 0.3, dampingFraction: 0.65), value: recording)
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

struct LiveTranscriptView: View {
    let live: LiveTranscriptModel
    let status: LiveTranscriptModel.Status
    @Binding var following: Bool

    private static let tail = "tail"

    var body: some View {
        ZStack(alignment: .bottom) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        if live.transcript.paragraphs.isEmpty {
                            empty
                        }
                        ForEach(live.transcript.paragraphs) { paragraph in
                            LiveParagraph(name: paragraph.kind == .mic ? "You" : (live.namedOther ?? otherSideLabel),
                                          tint: paragraph.kind == .mic ? .white.opacity(0.82) : accent,
                                          text: paragraph.text, pending: paragraph.pending)
                        }
                        Color.clear.frame(height: 1).id(Self.tail)
                    }
                    .padding(.vertical, 2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                }
                .scrollIndicators(.never)
                .defaultScrollAnchor(.bottom)
                .mask(LinearGradient(stops: [.init(color: .clear, location: 0),
                                             .init(color: .black, location: 0.045),
                                             .init(color: .black, location: 1)],
                                     startPoint: .top, endPoint: .bottom))
                .onScrollGeometryChange(for: Bool.self) { geometry in
                    geometry.contentOffset.y + geometry.containerSize.height >= geometry.contentSize.height - 90
                } action: { _, atBottom in
                    following = atBottom
                }
                .onScrollGeometryChange(for: CGFloat.self) { $0.containerSize.height } action: { _, _ in
                    guard following else { return }
                    proxy.scrollTo(Self.tail, anchor: .bottom)
                }
                .onChange(of: live.transcript) {
                    guard following else { return }
                    withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(Self.tail, anchor: .bottom) }
                }
                .overlay(alignment: .bottom) {
                    if !following {
                        Button {
                            following = true
                            withAnimation(.easeOut(duration: 0.22)) { proxy.scrollTo(Self.tail, anchor: .bottom) }
                        } label: {
                            HStack(spacing: 6) {
                                Circle().fill(accent).frame(width: 6, height: 6)
                                Text("Live").font(tiktok(11.5, "Medium")).foregroundStyle(.white.opacity(0.95))
                            }
                            .padding(.horizontal, 10)
                            .frame(height: 24)
                            .background(Capsule().fill(Color(white: 0.16).opacity(0.92))
                                .overlay(Capsule().strokeBorder(.white.opacity(0.2))))
                            .contentShape(Capsule())
                        }
                        .buttonStyle(Pressable())
                        .padding(.bottom, 4)
                        .transition(.opacity)
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.white.opacity(0.05)))
        .animation(.easeOut(duration: 0.2), value: following)
    }

    private var empty: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(emptyTitle).font(tiktok(13, "Medium")).foregroundStyle(.white.opacity(0.92))
            Text(emptyDetail)
                .font(tiktok(12.5))
                .foregroundStyle(.white.opacity(0.78))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var emptyTitle: String {
        switch status {
        case .unavailable: "No live transcript"
        case .preparing: "Starting"
        default: "Listening"
        }
    }

    private var emptyDetail: String {
        switch status {
        case .preparing(let message): message
        case .unavailable(let message): "\(message) The meeting is still being recorded."
        case .finishing, .ended: "Nothing was said."
        default: "What you and \(live.namedOther ?? otherSideLabel) say appears here."
        }
    }
}

private struct LiveParagraph: View {
    let name: String
    let tint: Color
    let text: String
    let pending: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(name)
                .font(tiktok(10.5, "Medium"))
                .kerning(0.5)
                .foregroundStyle(tint)
            line
                .font(tiktok(13))
                .lineSpacing(4)
                .contentTransition(.opacity)
                .animation(.easeOut(duration: 0.24), value: text)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var line: Text {
        let settled = Text(text).foregroundColor(.white.opacity(0.92))
        let gap = text.isEmpty || pending.isEmpty ? "" : " "
        let tail = Text(gap + pending).foregroundColor(.white.opacity(0.62))
        return Text("\(settled)\(tail)")
    }
}

private struct RecentRow: View {
    let meeting: Meeting
    let progress: Double?
    let open: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: open) {
            HStack(spacing: 10) {
                Text(when)
                    .font(tiktok(11))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.78))
                    .frame(width: 58, alignment: .leading)
                Text(meeting.title)
                    .font(tiktok(12.5))
                    .foregroundStyle(.white.opacity(0.92))
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(detail)
                    .font(tiktok(11))
                    .monospacedDigit()
                    .foregroundStyle(meeting.state == .failed ? accent : .white.opacity(0.78))
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(.white.opacity(hovering ? 0.08 : 0.04)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }

    private var when: String {
        let calendar = Calendar.current
        if calendar.isDateInToday(meeting.startedAt) {
            return meeting.startedAt.formatted(date: .omitted, time: .shortened)
        }
        if calendar.isDateInYesterday(meeting.startedAt) { return "Yesterday" }
        return meeting.startedAt.formatted(.dateTime.day().month(.abbreviated))
    }

    private var detail: String {
        if let progress { return "\(Int(progress * 100))%" }
        switch meeting.state {
        case .failed: return "Failed"
        case .running: return "Transcribing"
        default: return formatTimecode(meeting.duration, includeHours: meeting.duration >= 3600)
        }
    }
}
