@preconcurrency import MeetingKit
import SwiftUI

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
        VStack(alignment: .leading, spacing: 0) {
            switch mode {
            case .idle: idle
            case .live, .paused: recording
            case .finishing: finishing
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .font(tiktok(13))
        .foregroundStyle(.white.opacity(0.9))
        .animation(.easeOut(duration: 0.2), value: mode)
    }

    private var idle: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button { model.toggleMeetingRecording() } label: {
                HStack(spacing: 9) {
                    Circle().fill(accent).frame(width: 10, height: 10)
                    Text("Record meeting")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(WideButton())
            .disabled(!coordinator.canRecord)
            sources
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
            Button("All meetings") { model.openMeetings() }.buttonStyle(WideButton())
        }
    }

    private var sources: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "mic").font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.78))
                Text("Microphone")
                Spacer(minLength: 8)
                GlassDropdown(selection: microphone, options: microphoneOptions).frame(width: 176)
            }
            .frame(height: 32)
            Rectangle().fill(.white.opacity(0.07)).frame(height: 1)
            HStack(spacing: 10) {
                Image(systemName: "speaker.wave.2").font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.78))
                Text("System audio")
                Spacer(minLength: 8)
                GlassSwitch(isOn: $model.settings.meetingSystem)
            }
            .frame(height: 32)
        }
        .padding(.horizontal, 11)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.white.opacity(0.055)))
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
            HStack(spacing: 10) {
                LiveDot(paused: mode == .paused)
                Text(formatTimecode(coordinator.elapsed, includeHours: coordinator.elapsed >= 3600))
                    .font(tiktok(20, "Medium"))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(mode == .paused ? 0.6 : 0.95))
                Spacer(minLength: 8)
                meter("Mic", level: coordinator.micLevel, on: coordinator.micAvailable)
                meter("System", level: coordinator.systemLevel, on: coordinator.systemAvailable)
            }
            HStack(spacing: 8) {
                if mode == .paused {
                    Button("Resume") { meetings.resume() }.buttonStyle(WideButton())
                } else {
                    Button("Pause") { meetings.pause() }.buttonStyle(WideButton())
                }
                Button {
                    model.toggleMeetingRecording()
                } label: {
                    HStack(spacing: 8) {
                        RoundedRectangle(cornerRadius: 2.5, style: .continuous).fill(accent).frame(width: 10, height: 10)
                        Text("Stop")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(WideButton())
            }
            if let message = notice {
                Text(message)
                    .font(tiktok(11.5))
                    .foregroundStyle(.white.opacity(0.78))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            transcript
        }
    }

    private var finishing: some View {
        VStack(spacing: 10) {
            Spinner()
            Text("Finishing").font(tiktok(13)).foregroundStyle(.white.opacity(0.78))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var transcript: some View {
        VStack(alignment: .leading, spacing: 8) {
            legend
            Rectangle().fill(.white.opacity(0.07)).frame(height: 1)
            document
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.white.opacity(0.055)))
    }

    private var legend: some View {
        HStack(spacing: 14) {
            HStack(spacing: 6) {
                Circle().fill(.white.opacity(0.85)).frame(width: 6, height: 6)
                Text("You").font(tiktok(12, "Medium")).foregroundStyle(.white.opacity(0.9))
            }
            HStack(spacing: 5) {
                Circle().fill(accent).frame(width: 6, height: 6)
                TextField(LiveTranscriptModel.defaultOtherLabel, text: Bindable(live).otherName)
                    .textFieldStyle(.plain)
                    .font(tiktok(12, "Medium"))
                    .foregroundStyle(accent)
                    .frame(width: 74)
                Image(systemName: "pencil").font(.system(size: 9, weight: .semibold)).foregroundStyle(.white.opacity(0.6))
            }
            Spacer(minLength: 0)
            if let state = liveState {
                Text(state).font(tiktok(11)).foregroundStyle(.white.opacity(0.78)).lineLimit(1)
            }
        }
    }

    private var document: some View {
        let paragraphs = live.transcript.paragraphs
        return ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 9) {
                    if paragraphs.isEmpty {
                        Text(placeholder)
                            .font(tiktok(12.5))
                            .foregroundStyle(.white.opacity(0.78))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    ForEach(paragraphs) { paragraph in
                        LiveParagraph(name: paragraph.kind == .mic ? "You" : live.otherLabel,
                                      tint: paragraph.kind == .mic ? .white.opacity(0.95) : accent,
                                      text: paragraph.text, pending: paragraph.pending)
                    }
                    Color.clear.frame(height: 1).id(Self.tail)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
            }
            .scrollIndicators(.visible)
            .defaultScrollAnchor(.bottom)
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentOffset.y + geometry.containerSize.height >= geometry.contentSize.height - 40
            } action: { _, atBottom in
                followTail = atBottom
            }
            .onChange(of: live.transcript) {
                guard followTail else { return }
                withAnimation(.easeOut(duration: 0.18)) { proxy.scrollTo(Self.tail, anchor: .bottom) }
            }
        }
    }

    private static let tail = "tail"

    private var placeholder: String {
        switch live.status {
        case .preparing(let message): message
        case .unavailable(let message): message
        case .listening: "Listening. What you and \(live.otherLabel) say appears here."
        case .finishing, .ended: "Nothing was said."
        case .idle: "Start a meeting to see the live transcript."
        }
    }

    private var liveState: String? {
        switch live.status {
        case .preparing(let message): message
        case .unavailable(let message): message
        case .finishing: "Finishing"
        case .ended: "Ended"
        default: nil
        }
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

    private func meter(_ label: String, level: Float, on: Bool) -> some View {
        VStack(spacing: 3) {
            LevelMeter(level: on ? Double(level) : 0, active: on && mode == .live)
                .frame(width: 56, height: 18)
            Text(label).font(tiktok(9.5, "Medium")).foregroundStyle(.white.opacity(on ? 0.78 : 0.4))
        }
    }

    private var microphone: Binding<String> {
        Binding(get: { model.settings.meetingMicrophone ?? "" },
                set: { model.settings.meetingMicrophone = $0.isEmpty ? nil : $0 })
    }

    private var microphoneOptions: [(String, String)] {
        [("", "System default")] + meetings.inputDevices.map { ($0.uid, $0.name) }
    }
}

private struct LiveParagraph: View {
    let name: String
    let tint: Color
    let text: String
    let pending: String

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            RoundedRectangle(cornerRadius: 1, style: .continuous).fill(tint.opacity(0.35)).frame(width: 2)
            line
                .font(tiktok(12.5))
                .lineSpacing(3)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var line: Text {
        let label = Text("\(name): ").font(tiktok(12.5, "Medium")).foregroundColor(tint)
        let settled = Text(text).foregroundColor(.white.opacity(0.92))
        let gap = text.isEmpty || pending.isEmpty ? "" : " "
        let tail = Text(gap + pending).foregroundColor(.white.opacity(0.45))
        return Text("\(label)\(settled)\(tail)")
    }
}

private struct LiveDot: View {
    let paused: Bool
    @State private var dim = false

    var body: some View {
        Circle()
            .fill(accent)
            .frame(width: 10, height: 10)
            .opacity(paused ? 0.45 : dim ? 0.5 : 1)
            .onAppear {
                guard !paused else { return }
                withAnimation(.easeInOut(duration: 1.05).repeatForever(autoreverses: true)) { dim = true }
            }
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

private struct WideButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Surface(configuration: configuration)
    }

    private struct Surface: View {
        let configuration: Configuration
        @Environment(\.isEnabled) private var isEnabled
        @State private var hovering = false

        var body: some View {
            configuration.label
                .font(tiktok(13, "Medium"))
                .foregroundStyle(.white.opacity(0.95))
                .frame(maxWidth: .infinity)
                .frame(height: 34)
                .background {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(.white.opacity(configuration.isPressed ? 0.22 : hovering && isEnabled ? 0.16 : 0.1))
                        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(.white.opacity(0.13)))
                }
                .opacity(isEnabled ? 1 : 0.38)
                .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .onHover { hovering = $0 }
                .animation(.easeOut(duration: 0.12), value: hovering)
        }
    }
}
