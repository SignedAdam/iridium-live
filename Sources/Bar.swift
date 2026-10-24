@preconcurrency import MeetingKit
import SwiftUI

struct ControlBar: View {
    @Bindable var model: AppModel

    var body: some View {
        if model.metrics.compact {
            CompactBar(model: model)
        } else {
            FullBar(model: model)
        }
    }
}

struct FullBar: View {
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
        .frame(width: ControlMetrics.full.barSize.width, height: ControlMetrics.full.barSize.height, alignment: .leading)
    }
}

struct CompactBar: View {
    @Bindable var model: AppModel
    private static let icon: CGFloat = 22

    var body: some View {
        let size = ControlMetrics.compact.barSize
        HStack(spacing: 0) {
            RecordOrb(recording: model.recording, loading: !model.ready || model.finishing, size: 20,
                      action: model.toggleRecording)
                .padding(.leading, 6)
            if model.recording {
                LevelMeter(level: model.level, active: true, slim: true)
                    .frame(width: 24, height: 14)
                    .padding(.leading, 6)
                    .transition(.opacity)
            }
            Clock(recording: model.recording, since: model.recordingSince, size: 11.5)
                .frame(width: 30, alignment: .leading)
                .padding(.leading, 6)
            Rectangle().fill(.white.opacity(0.14)).frame(width: 1, height: 12)
                .opacity(model.activity == nil ? 0 : 1)
            CompactActivity(model: model)
                .padding(.leading, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 1) {
                IconToggle(symbol: "keyboard", isOn: model.typing, size: Self.icon, glyph: 11,
                           tip: model.typing ? "Stop typing" : "Type into apps",
                           action: { model.onTypingRequest(!model.typing) })
                IconToggle(symbol: "note.text", isOn: model.notesCapturing, size: Self.icon, glyph: 11,
                           tip: model.notesCapturing ? "Stop notes" : "Notes", action: model.toggleNotes)
                IconToggle(symbol: "person.2.wave.2", isOn: model.pane == .meeting, size: Self.icon, glyph: 11,
                           tip: "Meeting", action: model.toggleMeeting)
                IconToggle(symbol: "clock.arrow.circlepath", isOn: model.pane == .history, size: Self.icon, glyph: 11,
                           tip: "History", action: model.toggleHistory)
                IconToggle(symbol: "gearshape", isOn: model.pane == .settings, size: Self.icon, glyph: 11,
                           tip: "Settings", action: model.toggleSettings)
            }
            .padding(.leading, 6)
            .padding(.trailing, 5)
        }
        .frame(width: size.width, height: size.height, alignment: .leading)
        .animation(.easeOut(duration: 0.24), value: model.recording)
    }
}

struct CompactActivity: View {
    @Bindable var model: AppModel

    var body: some View {
        let activity = model.activity
        GeometryReader { geometry in
            if let activity {
                let label = line(activity)
                ViewThatFits(in: .horizontal) {
                    label
                    label.frame(width: geometry.size.width, alignment: .leading)
                        .clipped()
                        .mask(LinearGradient(stops: [.init(color: .black, location: 0.78),
                                                     .init(color: .clear, location: 1)],
                                             startPoint: .leading, endPoint: .trailing))
                }
                .frame(width: geometry.size.width, height: geometry.size.height, alignment: .leading)
                .transition(.opacity)
            }
        }
        .frame(height: 14)
        .allowsHitTesting(false)
        .animation(.easeOut(duration: 0.22), value: activity)
    }

    private func line(_ activity: String) -> some View {
        HStack(spacing: 5) {
            if model.recording {
                Image(systemName: model.typingNow ? "keyboard" : "note.text").font(.system(size: 9, weight: .semibold))
            } else {
                Spinner().frame(width: 9, height: 9)
            }
            Text(activity).font(tiktok(11, "Medium")).lineLimit(1)
        }
        .foregroundStyle(.white.opacity(0.82))
        .fixedSize()
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
            let metrics = model.metrics
            let compact = metrics.compact
            let paused = meetings.coordinator.state == .paused
            let saving = meetings.coordinator.state == .stopping
            HStack(spacing: compact ? 8 : 10) {
                Button(action: model.toggleMeeting) {
                    HStack(spacing: compact ? 8 : 10) {
                        if saving {
                            Text("Saving").font(tiktok(compact ? 11 : 12.5, "Medium")).foregroundStyle(.white.opacity(0.75))
                            Spacer(minLength: 0)
                        } else {
                            elapsed(meetings, paused: paused, compact: compact)
                            line(meetings, compact: compact)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .tip(model.pane == .meeting ? "Hide meeting" : "Show meeting")
                if !saving {
                    HStack(spacing: compact ? 1 : 2) {
                        IconToggle(symbol: paused ? "play.fill" : "pause.fill", isOn: paused,
                                   size: compact ? 20 : 26, glyph: compact ? 9 : 11,
                                   tip: paused ? "Resume" : "Pause",
                                   action: { paused ? meetings.resume() : meetings.pause() })
                        IconToggle(symbol: "stop.fill", isOn: false, size: compact ? 20 : 26, glyph: compact ? 8.5 : 10,
                                   tip: "Stop recording", action: model.toggleMeetingRecording)
                    }
                }
            }
            .padding(.leading, compact ? 8 : 10)
            .padding(.trailing, compact ? 6 : 11)
            .frame(width: metrics.barSize.width, height: metrics.stripHeight)
            .overlay(alignment: .top) { Rectangle().fill(.white.opacity(0.08)).frame(height: 1) }
            .animation(.easeOut(duration: 0.22), value: paused)
            .animation(.easeOut(duration: 0.22), value: saving)
        }
    }

    private func elapsed(_ meetings: MeetingsModel, paused: Bool, compact: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: compact ? 5 : 6) {
            TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                Text(formatTimecode(meetings.coordinator.elapsed,
                                    includeHours: meetings.coordinator.elapsed >= 3600))
                    .font(tiktok(compact ? 11 : 12.5, "Medium"))
                    .monospacedDigit()
                    .foregroundStyle(paused ? .white.opacity(0.75) : accent)
            }
            if paused {
                Text("Paused").font(tiktok(compact ? 10 : 11, "Medium")).foregroundStyle(.white.opacity(0.75))
            }
        }
    }

    private func line(_ meetings: MeetingsModel, compact: Bool) -> some View {
        let said = caption(meetings)
        let body = Text(said)
            .font(tiktok(compact ? 11 : 12))
            .foregroundStyle(.white.opacity(said == "Listening" ? 0.6 : 0.88))
            .lineLimit(1)
            .contentTransition(.opacity)
            .fixedSize()
            .animation(.easeOut(duration: 0.24), value: said)
        return HStack(spacing: compact ? 5 : 6) {
            if let who = speaker(meetings) {
                Text(who)
                    .font(tiktok(compact ? 10 : 11, "Medium"))
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
            .frame(minWidth: compact ? 100 : 120, maxWidth: .infinity)
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

/// Starts recording the moment it is pressed rather than when let go: the microphone takes a moment to open, and
/// people start talking as they click. Stopping waits for the release, like any button.
struct RecordOrb: View {
    let recording: Bool
    let loading: Bool
    var size: CGFloat = 40
    let action: () -> Void
    @State private var hovering = false
    @State private var startedOnPress = false

    var body: some View {
        let scale = size / 40
        Button { if !startedOnPress { action() } } label: {
            TimelineView(.animation(paused: !recording && !loading)) { context in
                let time = context.date.timeIntervalSinceReferenceDate
                let pulse = 1 - pow(1 - time.truncatingRemainder(dividingBy: 1.8) / 1.8, 2)
                ZStack {
                    Circle().fill(.white.opacity(hovering ? 0.15 : 0.08))
                        .overlay(Circle().strokeBorder(.white.opacity(0.2)))
                        .padding(2 * scale)
                    if recording {
                        Circle().stroke(accent.opacity(0.8), lineWidth: 1.5 * scale)
                            .padding(2 * scale)
                            .scaleEffect(0.94 + 0.36 * pulse)
                            .opacity(0.8 * (1 - pulse))
                    }
                    RoundedRectangle(cornerRadius: (recording ? 3.5 : 8) * scale, style: .continuous)
                        .fill(accent)
                        .frame(width: (recording ? 13 : 16) * scale, height: (recording ? 13 : 16) * scale)
                        .shadow(color: accent.opacity(recording ? 0.95 : 0.5), radius: (recording ? 8 : 5) * scale)
                    if loading {
                        Circle().trim(from: 0, to: 0.2)
                            .stroke(.white.opacity(0.7), style: StrokeStyle(lineWidth: 1.5 * scale, lineCap: .round))
                            .padding(0.75 * scale)
                            .rotationEffect(.degrees(-360 * time.truncatingRemainder(dividingBy: 1.1) / 1.1))
                            .transition(.opacity)
                    }
                }
            }
            .frame(width: size, height: size)
            .contentShape(Circle())
        }
        .buttonStyle(Pressable {
            startedOnPress = !recording
            if startedOnPress { action() }
        })
        .onHover { hovering = $0 }
        .tip(recording ? "Stop" : "Record")
        .animation(.spring(response: 0.32, dampingFraction: 0.62), value: recording)
        .animation(.easeOut(duration: 0.4), value: loading)
    }
}

struct LevelMeter: View {
    private static let wide: [CGFloat] = [0.38, 0.58, 0.8, 0.94, 1, 0.94, 0.8, 0.58, 0.38]
    private static let narrow: [CGFloat] = [0.45, 0.78, 1, 0.78, 0.45]
    let level: Double
    let active: Bool
    var slim = false

    var body: some View {
        let profile = slim ? Self.narrow : Self.wide
        let thickness: CGFloat = slim ? 2 : 3
        GeometryReader { geometry in
            HStack(alignment: .center,
                   spacing: (geometry.size.width - thickness * CGFloat(profile.count)) / CGFloat(profile.count - 1)) {
                ForEach(profile.indices, id: \.self) { index in
                    Capsule()
                        .fill(.white.opacity(active ? 0.92 : 0.26))
                        .frame(width: thickness, height: max(thickness, geometry.size.height * level * profile[index]
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
    var size: CGFloat = 15

    var body: some View {
        TimelineView(.periodic(from: since, by: 0.25)) { context in
            let seconds = recording ? max(0, Int(context.date.timeIntervalSince(since))) : 0
            Text(String(format: "%d:%02d", seconds / 60, seconds % 60))
                .font(tiktok(size, "Medium"))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(recording ? 0.92 : 0.78))
        }
    }
}
