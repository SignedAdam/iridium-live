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

    private enum Mode { case idle, live, paused }

    private var coordinator: RecordingCoordinator { meetings.coordinator }
    private var live: LiveTranscriptModel { meetings.live }

    private var mode: Mode {
        switch coordinator.state {
        case .recording: .live
        case .paused: .paused
        default: .idle
        }
    }

    private var saving: Bool { coordinator.state == .stopping }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if mode == .idle {
                header
                idle
            } else {
                recording
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
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("Meeting").font(tiktok(15, "Medium")).foregroundStyle(.white.opacity(0.95))
            Spacer(minLength: 8)
            Button("All meetings") { model.openMeetings() }.buttonStyle(GlassButton())
            Button { meetings.toggleRecording() } label: {
                HStack(spacing: 6) {
                    Circle().fill(accent).frame(width: 7, height: 7)
                    Text("Record")
                }
            }
            .buttonStyle(GlassButton())
            .disabled(!coordinator.canRecord)
        }
        .frame(height: 26)
    }

    private var idle: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let message = notice {
                Text(message)
                    .font(tiktok(11.5))
                    .foregroundStyle(.white.opacity(0.75))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let saved = finished, !saving {
                savedLine(saved)
            }
            sources
            Text(engineNote)
                .font(tiktok(11.5))
                .foregroundStyle(.white.opacity(0.75))
                .fixedSize(horizontal: false, vertical: true)
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
            LiveTranscriptView(live: live, status: live.status, note: notice, following: $followTail)
        }
    }

    private var liveSources: some View {
        HStack(spacing: 8) {
            Text("You").font(tiktok(11.5, "Medium")).foregroundStyle(.white.opacity(0.85))
            LevelMeter(level: coordinator.micAvailable ? Double(coordinator.micLevel) : 0,
                       active: coordinator.micAvailable && mode == .live)
                .frame(width: 36, height: 12)
            Rectangle().fill(.white.opacity(0.12)).frame(width: 1, height: 12).padding(.horizontal, 4)
            OtherName(live: live)
            LevelMeter(level: coordinator.systemAvailable ? Double(coordinator.systemLevel) : 0,
                       active: coordinator.systemAvailable && mode == .live)
                .frame(width: 36, height: 12)
            Spacer(minLength: 4)
        }
        .frame(height: 22)
    }

    private var engineNote: String {
        let option = EngineFactory.options.first { $0.id == model.settings.meetingEngine }
        guard let option else { return "" }
        guard model.settings.meetingAutoTranscribe else {
            return "Meetings are saved without a transcript. Transcribe them with \(option.name) when you want."
        }
        return option.local ? "\(option.name) writes the transcript on this Mac when the meeting ends."
            : "\(option.name) writes the transcript in the cloud when the meeting ends."
    }

    private var notice: String? {
        if let error = meetings.lastError { return error }
        if saving { return "Saving the last meeting." }
        let message = coordinator.statusMessage
        return message.isEmpty ? nil : message
    }

    private var finished: Meeting? {
        guard !meetings.isRecording, let id = meetings.lastSavedID else { return nil }
        return meetings.meeting(id)
    }

    private func savedLine(_ meeting: Meeting) -> some View {
        HStack(spacing: 8) {
            Text(meeting.state == .none ? "Not transcribed" : "Saved")
                .font(tiktok(12.5))
                .foregroundStyle(.white.opacity(0.75))
                .fixedSize()
            Text(meeting.title)
                .font(tiktok(12.5, "Medium"))
                .foregroundStyle(.white.opacity(0.92))
                .lineLimit(1)
            Spacer(minLength: 8)
            if let progress = meetings.progress[meeting.id] {
                Text("\(Int(progress * 100))%")
                    .font(tiktok(11))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.75))
            } else if meeting.state == .running {
                Text("Transcribing").font(tiktok(11)).foregroundStyle(.white.opacity(0.75))
            } else if meeting.state == .none {
                TranscribeControl(title: "Transcribe", meeting: meeting, meetings: meetings).fixedSize()
            }
            Button("Open") { model.openMeetings(meeting.id) }.buttonStyle(GlassButton()).fixedSize()
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

struct LiveTranscriptView: View {
    let live: LiveTranscriptModel
    let status: LiveTranscriptModel.Status
    let note: String?
    @Binding var following: Bool

    private static let tail = "tail"

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let line = statusNote {
                Text(line)
                    .font(tiktok(11.5))
                    .foregroundStyle(.white.opacity(0.75))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        if live.transcript.paragraphs.isEmpty && statusNote == nil {
                            empty
                        }
                        ForEach(live.transcript.paragraphs) { paragraph in
                            LiveParagraph(name: paragraph.kind == .mic ? "You" : (live.namedOther ?? otherSideLabel),
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
                            HStack(spacing: 5) {
                                Image(systemName: "arrow.down").font(.system(size: 9, weight: .semibold))
                                Text("Live").font(tiktok(11.5, "Medium"))
                            }
                            .foregroundStyle(.white.opacity(0.92))
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

    private var statusNote: String? {
        switch status {
        case .preparing(let message): message
        case .unavailable(let message): "\(message) The meeting is still being recorded."
        default: note
        }
    }

    private var empty: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(emptyTitle).font(tiktok(13, "Medium")).foregroundStyle(.white.opacity(0.92))
            Text(emptyDetail)
                .font(tiktok(12.5))
                .foregroundStyle(.white.opacity(0.75))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var emptyTitle: String {
        switch status {
        case .off: "Live transcript off"
        case .finishing, .ended: "Nothing was said"
        default: "Listening"
        }
    }

    private var emptyDetail: String {
        switch status {
        case .off: "The meeting is being recorded. Transcribe it when it ends."
        case .finishing, .ended: "The recording is still saved."
        default: "What you and \(live.namedOther ?? otherSideLabel) say appears here."
        }
    }
}

private struct LiveParagraph: View {
    let name: String
    let text: String
    let pending: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(name)
                .font(tiktok(10.5, "Medium"))
                .kerning(0.5)
                .foregroundStyle(.white.opacity(0.6))
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
        let tail = Text(gap + pending).foregroundColor(.white.opacity(0.6))
        return Text("\(settled)\(tail)")
    }
}

private struct OtherName: View {
    @Bindable var live: LiveTranscriptModel
    @State private var hovering = false

    var body: some View {
        Text(live.namedOther ?? otherSideLabel)
            .font(tiktok(11.5, "Medium"))
            .lineLimit(1)
            .hidden()
            .overlay {
                TextField(otherSideLabel, text: $live.otherName)
                    .textFieldStyle(.plain)
                    .font(tiktok(11.5, "Medium"))
                    .foregroundStyle(.white.opacity(0.85))
            }
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(.white.opacity(hovering ? 0.08 : 0)))
            .padding(.horizontal, -5)
            .onHover { hovering = $0 }
            .tip("Rename")
            .animation(.easeOut(duration: 0.15), value: hovering)
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
        case .none: return "Not transcribed"
        case .done: return formatTimecode(meeting.duration, includeHours: meeting.duration >= 3600)
        }
    }
}
