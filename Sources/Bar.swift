@preconcurrency import MeetingKit
import SwiftUI

struct ControlBar: View {
    @Bindable var model: AppModel

    var body: some View {
        HStack(spacing: 0) {
            RecordOrb(recording: model.recording, loading: !model.ready || model.finishing, action: model.toggleRecording)
                .padding(.leading, 8)
            LevelMeter(level: model.recording ? model.level : 0, active: model.recording)
                .frame(width: 56, height: 28)
                .padding(.leading, 14)
            Clock(recording: model.recording, since: model.recordingSince)
                .frame(width: 50, alignment: .leading)
                .padding(.leading, 10)
            Rectangle().fill(.white.opacity(0.14)).frame(width: 1, height: 18).padding(.leading, 4)
            IconToggle(symbol: "keyboard", isOn: model.typing, tip: model.typing ? "Stop typing" : "Type into apps",
                       action: { model.onTypingRequest(!model.typing) })
                .padding(.leading, 9)
            IconToggle(symbol: "note.text", isOn: model.notesCapturing, tip: model.notesCapturing ? "Stop notes" : "Notes",
                       action: model.toggleNotes)
                .padding(.leading, 2)
            MeetingToggle(model: model)
                .padding(.leading, 2)
            IconToggle(symbol: "clock.arrow.circlepath", isOn: model.pane == .history, tip: "History", action: model.toggleHistory)
                .padding(.leading, 2)
            IconToggle(symbol: "gearshape", isOn: model.pane == .settings, tip: "Settings", action: model.toggleSettings)
                .padding(.leading, 2)
        }
        .frame(width: AppModel.barSize.width, height: AppModel.barSize.height, alignment: .leading)
    }
}

struct MeetingToggle: View {
    @Bindable var model: AppModel

    var body: some View {
        IconToggle(symbol: "person.2.wave.2", isOn: model.pane == .meeting, tip: "Meeting", action: model.toggleMeeting)
    }
}

struct MeetingStrip: View {
    @Bindable var model: AppModel

    var body: some View {
        if let meetings = model.meetings {
            let paused = meetings.coordinator.state == .paused
            let saving = meetings.coordinator.state == .stopping
            HStack(spacing: 10) {
                Button(action: model.toggleMeeting) {
                    HStack(spacing: 10) {
                        if saving {
                            Text("Saving").font(tiktok(12.5, "Medium")).foregroundStyle(.white.opacity(0.75))
                            Spacer(minLength: 0)
                        } else {
                            elapsed(meetings, paused: paused)
                            line(meetings)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .tip(model.pane == .meeting ? "Hide meeting" : "Show meeting")
                if !saving {
                    HStack(spacing: 2) {
                        IconToggle(symbol: paused ? "play.fill" : "pause.fill", isOn: paused, size: 26, glyph: 11,
                                   tip: paused ? "Resume" : "Pause",
                                   action: { paused ? meetings.resume() : meetings.pause() })
                        IconToggle(symbol: "stop.fill", isOn: false, size: 26, glyph: 10, tip: "Stop recording",
                                   action: model.toggleMeetingRecording)
                    }
                }
            }
            .padding(.leading, 10)
            .padding(.trailing, 11)
            .frame(width: AppModel.barSize.width, height: AppModel.stripHeight)
            .overlay(alignment: .top) { Rectangle().fill(.white.opacity(0.08)).frame(height: 1) }
            .animation(.easeOut(duration: 0.22), value: paused)
            .animation(.easeOut(duration: 0.22), value: saving)
        }
    }

    private func elapsed(_ meetings: MeetingsModel, paused: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                Text(formatTimecode(meetings.coordinator.elapsed,
                                    includeHours: meetings.coordinator.elapsed >= 3600))
                    .font(tiktok(12.5, "Medium"))
                    .monospacedDigit()
                    .foregroundStyle(paused ? .white.opacity(0.75) : accent)
            }
            if paused {
                Text("Paused").font(tiktok(11, "Medium")).foregroundStyle(.white.opacity(0.75))
            }
        }
    }

    private func line(_ meetings: MeetingsModel) -> some View {
        let said = caption(meetings)
        let body = Text(said)
            .font(tiktok(12))
            .foregroundStyle(.white.opacity(said == "Listening" ? 0.6 : 0.88))
            .lineLimit(1)
            .contentTransition(.opacity)
            .fixedSize()
            .animation(.easeOut(duration: 0.24), value: said)
        return HStack(spacing: 6) {
            if let who = speaker(meetings) {
                Text(who)
                    .font(tiktok(11, "Medium"))
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)
            }
            GeometryReader { geometry in
                ViewThatFits(in: .horizontal) {
                    body
                    body.frame(width: geometry.size.width, alignment: .trailing)
                        .clipped()
                        .mask(LinearGradient(stops: [.init(color: .clear, location: 0),
                                                     .init(color: .black, location: 0.22)],
                                             startPoint: .leading, endPoint: .trailing))
                }
                .frame(width: geometry.size.width, height: geometry.size.height, alignment: .leading)
            }
            .frame(minWidth: 120, maxWidth: .infinity)
        }
    }

    private func speaker(_ meetings: MeetingsModel) -> String? {
        guard let last = meetings.live.transcript.paragraphs.last else { return nil }
        return last.kind == .mic ? "You" : (meetings.live.namedOther ?? otherSideLabel)
    }

    private func caption(_ meetings: MeetingsModel) -> String {
        guard let last = meetings.live.transcript.paragraphs.last else { return "Listening" }
        let said = [last.text, last.pending].filter { !$0.isEmpty }.joined(separator: " ")
        return said.isEmpty ? "Listening" : said
    }
}

struct RecordOrb: View {
    let recording: Bool
    let loading: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            TimelineView(.animation(paused: !recording && !loading)) { context in
                let time = context.date.timeIntervalSinceReferenceDate
                let pulse = 1 - pow(1 - time.truncatingRemainder(dividingBy: 1.8) / 1.8, 2)
                ZStack {
                    Circle().fill(.white.opacity(hovering ? 0.15 : 0.08))
                        .overlay(Circle().strokeBorder(.white.opacity(0.2)))
                        .padding(2)
                    if recording {
                        Circle().stroke(accent.opacity(0.8), lineWidth: 1.5)
                            .padding(2)
                            .scaleEffect(0.94 + 0.36 * pulse)
                            .opacity(0.8 * (1 - pulse))
                    }
                    RoundedRectangle(cornerRadius: recording ? 3.5 : 8, style: .continuous)
                        .fill(accent)
                        .frame(width: recording ? 13 : 16, height: recording ? 13 : 16)
                        .shadow(color: accent.opacity(recording ? 0.95 : 0.5), radius: recording ? 8 : 5)
                    if loading {
                        Circle().trim(from: 0, to: 0.2)
                            .stroke(.white.opacity(0.7), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                            .padding(0.75)
                            .rotationEffect(.degrees(-360 * time.truncatingRemainder(dividingBy: 1.1) / 1.1))
                            .transition(.opacity)
                    }
                }
            }
            .frame(width: 40, height: 40)
            .contentShape(Circle())
        }
        .buttonStyle(Pressable())
        .onHover { hovering = $0 }
        .tip(recording ? "Stop" : "Record")
        .animation(.spring(response: 0.32, dampingFraction: 0.62), value: recording)
        .animation(.easeOut(duration: 0.4), value: loading)
    }
}

struct LevelMeter: View {
    private static let profile: [CGFloat] = [0.38, 0.58, 0.8, 0.94, 1, 0.94, 0.8, 0.58, 0.38]
    let level: Double
    let active: Bool

    var body: some View {
        GeometryReader { geometry in
            HStack(alignment: .center, spacing: (geometry.size.width - 27) / 8) {
                ForEach(Self.profile.indices, id: \.self) { index in
                    Capsule()
                        .fill(.white.opacity(active ? 0.92 : 0.26))
                        .frame(width: 3, height: max(3, geometry.size.height * level * Self.profile[index]
                                                       * (active ? .random(in: 0.75...1) : 0)))
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .animation(.easeOut(duration: 0.09), value: level)
        .animation(.easeOut(duration: 0.3), value: active)
    }
}

struct Clock: View {
    let recording: Bool
    let since: Date

    var body: some View {
        TimelineView(.periodic(from: since, by: 0.25)) { context in
            let seconds = recording ? max(0, Int(context.date.timeIntervalSince(since))) : 0
            Text(String(format: "%d:%02d", seconds / 60, seconds % 60))
                .font(tiktok(15, "Medium"))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(recording ? 0.92 : 0.78))
        }
    }
}

