import SwiftUI

/// The bar along the bottom of the control: record, input level and elapsed time, then the typing, notes, history
/// and settings switches.
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
            IconToggle(symbol: "clock.arrow.circlepath", isOn: model.pane == .history, tip: "History", action: model.toggleHistory)
                .padding(.leading, 2)
            IconToggle(symbol: "gearshape", isOn: model.pane == .settings, tip: "Settings", action: model.toggleSettings)
                .padding(.leading, 2)
        }
        .frame(width: AppModel.barSize.width, height: AppModel.barSize.height, alignment: .leading)
    }
}

/// The record button: a glowing red dot in a glass well. Recording turns it into a rounded square with a slow halo;
/// a thin arc circles it until the model is ready (recording already works; audio waits for the model).
struct RecordOrb: View {
    let recording: Bool
    let loading: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            TimelineView(.animation(paused: !recording && !loading)) { context in
                let time = context.date.timeIntervalSinceReferenceDate
                let pulse = 1 - pow(1 - time.truncatingRemainder(dividingBy: 1.8) / 1.8, 2)  // ease-out, repeating
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

/// Nine bars that follow the voice, tallest in the middle; resting dots when not recording.
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

/// Elapsed recording time; dim while stopped.
struct Clock: View {
    let recording: Bool
    let since: Date

    var body: some View {
        TimelineView(.periodic(from: since, by: 0.25)) { context in
            let seconds = recording ? max(0, Int(context.date.timeIntervalSince(since))) : 0
            Text(String(format: "%d:%02d", seconds / 60, seconds % 60))
                .font(tiktok(15, "Medium"))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(recording ? 0.92 : 0.4))
        }
    }
}
