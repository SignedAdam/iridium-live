import SwiftUI

/// Settings, inside the control's glass: sections of rows on soft cards, a title on the left and its control flush
/// with the right edge. Every change applies at once and is saved.
struct SettingsPane: View {
    @Bindable var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Section("Memory") {
                    if let reading = model.memory {
                        Row("PhononLive") { Figure(gigabytes(reading.total)) }
                        Row("Your Mac", detail: reading.warning ? lowMemoryAdvice : nil, alert: true) {
                            Figure("\(gigabytes(reading.physical - min(reading.physical, reading.available), unit: false)) of \(String(format: "%.0f GB", Double(reading.physical) / 1_073_741_824))")
                        }
                    }
                    Row("Models") {
                        Button(model.speech.state == "unloaded" ? "Unloaded" : "Unload", action: model.onUnload)
                            .buttonStyle(GlassButton())
                            .disabled(model.speech.state == "unloaded")
                    }
                }
                Section("Speech") {
                    Row("Model", detail: status(model.speech), alert: model.speech.state == "error") {
                        Segments(selection: $model.settings.speechModel, options: Settings.speechModels)
                    }
                }
                Section("Hotkeys") {
                    let clashing = Hotkey.conflicting(in: model.settings.hotkeys)
                    let waiting = Hotkey.waitingForDoubleTap(in: model.settings.hotkeys)
                    ForEach($model.settings.hotkeys) { $hotkey in
                        HotkeyRow(hotkey: $hotkey, capturing: model.capturingHotkey == hotkey.id,
                                  conflict: clashing.contains(hotkey.id), waits: waiting.contains(hotkey.id),
                                  capture: { model.onCaptureHotkey(hotkey.id) },
                                  remove: { model.settings.hotkeys.removeAll { $0.id == hotkey.id } })
                    }
                    HStack {
                        Button("Add hotkey") {
                            let hotkey = Hotkey(keyCode: 54)
                            model.settings.hotkeys.append(hotkey)
                            model.onCaptureHotkey(hotkey.id)
                        }
                        .buttonStyle(GlassButton())
                        Spacer()
                        if !model.hotkeysListening, !model.settings.hotkeys.isEmpty {
                            Text("Needs Accessibility access").font(tiktok(12)).foregroundStyle(accent)
                        }
                    }
                    .frame(height: Row<EmptyView>.height)
                }
                Section("Typing") {
                    Row("Wait before typing") {
                        GlassSlider(value: $model.settings.typingHold, range: 0.2...3, step: 0.1) { String(format: "%.1f s", $0) }
                    }
                }
                Section("AI cleanup") {
                    Row("Clean up dictation", detail: model.settings.cleanupEnabled ? status(model.cleanup, lastMs: model.lastCleanupMs) : nil,
                        alert: model.cleanup.state == "error") {
                        GlassSwitch(isOn: $model.settings.cleanupEnabled)
                    }
                    Group {
                        Row("Runs on") {
                            Segments(selection: $model.settings.cleanupProvider, options: Settings.cleanupProviders.map { ($0.id, $0.name) })
                        }
                        Row("Model") {
                            GlassMenu(selection: $model.settings.cleanupModel,
                                      options: Settings.cleanupModels(on: model.settings.cleanupProvider))
                                .frame(width: 180)
                        }
                    }
                    .dimmed(!model.settings.cleanupEnabled)
                }
                Section("Recordings") {
                    Row("Save audio") {
                        GlassSwitch(isOn: $model.settings.saveAudio)
                    }
                    Row("Split at pauses of") {
                        GlassSlider(value: $model.settings.audioSplitSeconds, range: 0.5...10, step: 0.5) { String(format: "%.1f s", $0) }
                    }
                    .dimmed(!model.settings.saveAudio)
                    Row("Folder", detail: model.lastRecording.map { "Latest \($0.file), \(Int($0.seconds.rounded())) s" }) {
                        Button("Open", action: model.onOpenRecordings).buttonStyle(GlassButton())
                    }
                }
                Section("Captions") {
                    Row("Show captions") {
                        GlassSwitch(isOn: $model.settings.captionsShown)
                    }
                    Group {
                        Row("Position") {
                            Segments(selection: $model.settings.captionPosition,
                                     options: [(Settings.CaptionPosition.top, "Top"), (.bottom, "Bottom")])
                        }
                        Row("Font") {
                            GlassMenu(selection: $model.settings.captionFont, options: Settings.captionFonts.map { ($0, $0) })
                                .frame(width: 150)
                        }
                        Row("Size") {
                            GlassSlider(value: $model.settings.captionSize, range: 24...96, step: 1) { String(format: "%.0f pt", $0) }
                        }
                        Row("Stay for") {
                            GlassSlider(value: $model.settings.captionSeconds, range: 1...10, step: 0.5) { String(format: "%.1f s", $0) }
                        }
                        Row("Opacity") {
                            GlassSlider(value: $model.settings.captionOpacity, range: 0.2...1, step: 0.05) { String(format: "%.0f%%", $0 * 100) }
                        }
                    }
                    .dimmed(!model.settings.captionsShown)
                }
                Section("Look") {
                    Row("Glass tint") {
                        GlassSlider(value: $model.settings.glassTint, range: 0...1, step: 0.05) { String(format: "%.0f%%", $0 * 100) }
                    }
                    Row("Opacity") {
                        GlassSlider(value: $model.settings.controlOpacity, range: 0.3...1, step: 0.05) { String(format: "%.0f%%", $0 * 100) }
                    }
                }
            }
            .padding(12)
        }
        .scrollIndicators(.visible)
        .font(tiktok(13))
        .foregroundStyle(.white.opacity(0.88))
    }

    private var lowMemoryAdvice: String {
        model.settings.cleanupEnabled && model.settings.cleanupProvider == Settings.localCleanup
            ? "Running low. Cleanup on Groq would free about 2.5 GB." : "Running low. Closing other apps helps."
    }

    /// What a model is doing, in a few words; nothing while it is simply ready.
    private func status(_ status: ModelStatus, lastMs: Double? = nil) -> String? {
        switch status.state {
        case "downloading": "Downloading \(Int(status.progress * 100))%"
        case "loading": "Loading…"
        case "unloaded": "Unloaded"
        case "error": status.model?.contains(":") == true ? status.message : "Couldn’t load: \(status.message)"  // provider:model is remote
        case "ready": lastMs.map { "Last phrase took \(Int($0)) ms" }
        default: nil
        }
    }

    private func gigabytes(_ bytes: UInt64, unit: Bool = true) -> String {
        String(format: unit ? "%.1f GB" : "%.1f", Double(bytes) / 1_073_741_824)
    }
}

/// A titled group of rows on a soft card, with hairlines between the rows.
private struct Section<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title.uppercased())
                .font(tiktok(10.5, "Medium"))
                .kerning(0.8)
                .foregroundStyle(.white.opacity(0.42))
                .padding(.leading, 12)
            Group(subviews: content) { rows in
                VStack(spacing: 0) {
                    ForEach(rows) { row in
                        if row.id != rows.first?.id {
                            Rectangle().fill(.white.opacity(0.07)).frame(height: 1)
                        }
                        row
                    }
                }
            }
            .padding(.horizontal, 12)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.white.opacity(0.055)))
        }
    }
}

/// A title, an optional line under it, and the control on the right.
private struct Row<Control: View>: View {
    static var height: CGFloat { 38 }

    let title: String
    let detail: String?
    let alert: Bool
    @ViewBuilder let control: Control

    init(_ title: String, detail: String? = nil, alert: Bool = false, @ViewBuilder control: () -> Control) {
        self.title = title
        self.detail = detail
        self.alert = alert
        self.control = control()
    }

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let detail {
                    Text(detail)
                        .font(tiktok(11.5))
                        .foregroundStyle(alert ? accent : .white.opacity(0.45))
                        .lineLimit(2)
                        .transition(.opacity)
                }
            }
            Spacer(minLength: 0)
            control
        }
        .padding(.vertical, 6)
        .frame(minHeight: Self.height)
        .animation(.easeOut(duration: 0.2), value: detail)
    }
}

private extension View {
    /// Shown but out of play while the switch above it is off.
    func dimmed(_ dimmed: Bool) -> some View {
        disabled(dimmed).opacity(dimmed ? 0.4 : 1).animation(.easeOut(duration: 0.15), value: dimmed)
    }
}

/// A value shown on the right of a row.
private struct Figure: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text).monospacedDigit().foregroundStyle(.white.opacity(0.6))
    }
}

/// A frosted pill around a light edge: the surface of every control here.
private struct Pill: View {
    var fill = 0.1
    var body: some View {
        Capsule().fill(.white.opacity(fill)).overlay(Capsule().strokeBorder(.white.opacity(0.13)))
    }
}

private struct GlassButton: ButtonStyle {
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
                .foregroundStyle(.white.opacity(0.92))
                .padding(.horizontal, 12)
                .frame(height: 24)
                .background(Pill(fill: configuration.isPressed ? 0.22 : hovering && isEnabled ? 0.16 : 0.1))
                .opacity(isEnabled ? 1 : 0.45)
                .contentShape(Capsule())
                .onHover { hovering = $0 }
                .animation(.easeOut(duration: 0.12), value: hovering)
        }
    }
}

/// Two or three choices side by side; the chosen one sits on a lit pill that slides between them.
private struct Segments<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [(Value, String)]
    @Namespace private var pill

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options.indices, id: \.self) { index in
                let chosen = options[index].0 == selection
                Button { selection = options[index].0 } label: {
                    Text(options[index].1)
                        .font(tiktok(12, "Medium"))
                        .foregroundStyle(.white.opacity(chosen ? 0.95 : 0.55))
                        .padding(.horizontal, 11)
                        .frame(height: 22)
                        .background {
                            if chosen { Pill(fill: 0.2).matchedGeometryEffect(id: "pill", in: pill) }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(Pill(fill: 0.06))
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: selection)
    }
}

private struct GlassSwitch: View {
    @Binding var isOn: Bool

    var body: some View {
        Button { isOn.toggle() } label: {
            Capsule()
                .fill(isOn ? accent : .white.opacity(0.14))
                .overlay(Capsule().strokeBorder(.white.opacity(isOn ? 0.2 : 0.12)))
                .frame(width: 34, height: 20)
                .overlay(alignment: isOn ? .trailing : .leading) {
                    Circle().fill(.white)
                        .frame(width: 16, height: 16)
                        .shadow(color: .black.opacity(0.3), radius: 1.5, y: 1)
                        .padding(2)
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .animation(.spring(response: 0.25, dampingFraction: 0.8), value: isOn)
    }
}

/// A slim track with a white knob, and its value on the right.
private struct GlassSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let label: (Double) -> String
    @Environment(\.isEnabled) private var isEnabled
    private let width: CGFloat = 124
    private let knob: CGFloat = 14

    var body: some View {
        let fraction = (min(max(value, range.lowerBound), range.upperBound) - range.lowerBound) / (range.upperBound - range.lowerBound)
        let travel = width - knob
        HStack(spacing: 10) {
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.14)).frame(height: 4)
                Capsule().fill(.white.opacity(0.75)).frame(width: knob / 2 + fraction * travel, height: 4)
                Circle().fill(.white)
                    .frame(width: knob, height: knob)
                    .shadow(color: .black.opacity(0.3), radius: 1.5, y: 1)
                    .offset(x: fraction * travel)
            }
            .frame(width: width, height: 22)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
                guard isEnabled else { return }
                let share = min(max((drag.location.x - knob / 2) / travel, 0), 1)
                let stepped = ((range.lowerBound + share * (range.upperBound - range.lowerBound)) / step).rounded() * step
                let next = min(max(stepped, range.lowerBound), range.upperBound)
                if abs(next - value) > step / 100 { value = next }
            })
            Text(label(value))
                .font(tiktok(12))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.6))
                .frame(width: 40, alignment: .trailing)
        }
    }
}

/// A pill showing the current choice; clicking it opens the list.
private struct GlassMenu<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [(Value, String)]

    var body: some View {
        Menu {
            Picker("", selection: $selection) {
                ForEach(options.indices, id: \.self) { Text(options[$0].1).tag(options[$0].0) }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            HStack(spacing: 4) {
                Text(options.first { $0.0 == selection }?.1 ?? "").lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 8, weight: .bold)).opacity(0.55)
            }
            .font(tiktok(12, "Medium"))
            .foregroundStyle(.white.opacity(0.92))
            .padding(.horizontal, 9)
            .frame(height: 24)
            .background(Pill())
            .contentShape(Capsule())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
    }
}

/// One hotkey: the switch that puts it in play, the key (click to set it, then press it), the gesture that works it,
/// what the words are for, and a line under it when it clashes with another binding or has to wait one out.
private struct HotkeyRow: View {
    @Binding var hotkey: Hotkey
    let capturing: Bool
    let conflict: Bool
    let waits: Bool
    let capture: () -> Void
    let remove: () -> Void
    @State private var hoveringRemove = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                GlassSwitch(isOn: $hotkey.enabled)
                Group {
                    Button(action: capture) {
                        Text(capturing ? "Press…" : hotkey.label)
                            .foregroundStyle(capturing ? accent : .white.opacity(0.92))
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                            .frame(width: 44)
                    }
                    .buttonStyle(GlassButton())
                    .tip("Click, then press a key or a lone modifier")
                    GlassMenu(selection: $hotkey.gesture, options: Hotkey.gestureNames).frame(width: 102)
                    GlassMenu(selection: $hotkey.action, options: Hotkey.actionNames).frame(width: 112)
                }
                .opacity(hotkey.enabled ? 1 : 0.45)
                Spacer(minLength: 0)
                Button(action: remove) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white.opacity(hoveringRemove ? 0.9 : 0.45))
                        .frame(width: 18, height: 18)
                        .background(Circle().fill(.white.opacity(hoveringRemove ? 0.14 : 0)))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .onHover { hoveringRemove = $0 }
                .tip("Remove")
            }
            if conflict {
                note("Same key and gesture as another", color: accent)
            } else if waits {
                note("Waits a moment for a double-tap", color: .white.opacity(0.45))
            }
        }
        .padding(.vertical, 6)
        .frame(minHeight: Row<EmptyView>.height)
        .animation(.easeOut(duration: 0.2), value: conflict || waits)
    }

    private func note(_ text: String, color: Color) -> some View {
        Text(text).font(tiktok(11.5)).foregroundStyle(color).lineLimit(1).padding(.leading, 2)
    }
}
