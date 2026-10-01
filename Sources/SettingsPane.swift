import SwiftUI

/// Settings, inside the control's glass. Every change applies at once and is saved.
struct SettingsPane: View {
    @Bindable var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Section("Memory") {
                    MemoryLine(reading: model.memory, cleanupOn: model.settings.cleanupEnabled)
                    Row("Free memory now") {
                        Button("Unload models", action: model.onUnload)
                            .disabled(model.speech.state == "unloaded")
                    }
                }
                Section("Speech") {
                    Row("Model") {
                        Segments(selection: $model.settings.speechModel, options: Settings.speechModels)
                    }
                    StatusLine(status: model.speech)
                }
                Section("Hotkeys") {
                    ForEach($model.settings.hotkeys) { $hotkey in
                        HotkeyRow(hotkey: $hotkey, capturing: model.capturingHotkey == hotkey.id,
                                  capture: { model.onCaptureHotkey(hotkey.id) },
                                  remove: { model.settings.hotkeys.removeAll { $0.id == hotkey.id } })
                    }
                    HStack {
                        Button("Add hotkey") {
                            let hotkey = Hotkey(keyCode: 54)
                            model.settings.hotkeys.append(hotkey)
                            model.onCaptureHotkey(hotkey.id)
                        }
                        Spacer()
                        if !model.hotkeysListening, !model.settings.hotkeys.isEmpty {
                            Text("Needs Accessibility access").font(tiktok(12)).foregroundStyle(accent)
                        }
                    }
                    .frame(height: 26)
                }
                Section("Typing") {
                    Row("Type after") {
                        ValueSlider(value: $model.settings.typingHold, range: 0.2...3, step: 0.1) { String(format: "%.1f s", $0) }
                    }
                }
                Section("AI cleanup") {
                    Row("Clean up what you say") {
                        Toggle("", isOn: $model.settings.cleanupEnabled).toggleStyle(.switch).controlSize(.mini).labelsHidden()
                    }
                    Row("Model") {
                        Segments(selection: $model.settings.cleanupModel, options: Settings.cleanupModels)
                    }
                    .disabled(!model.settings.cleanupEnabled)
                    .opacity(model.settings.cleanupEnabled ? 1 : 0.45)
                    if model.settings.cleanupEnabled {
                        StatusLine(status: model.cleanup, lastMs: model.lastCleanupMs)
                    }
                }
                Section("Recordings") {
                    Row("Save the audio") {
                        Toggle("", isOn: $model.settings.saveAudio).toggleStyle(.switch).controlSize(.mini).labelsHidden()
                    }
                    Row("New file after silence of") {
                        ValueSlider(value: $model.settings.audioSplitSeconds, range: 0.5...10, step: 0.5) { String(format: "%.1f s", $0) }
                    }
                    .disabled(!model.settings.saveAudio)
                    .opacity(model.settings.saveAudio ? 1 : 0.45)
                    HStack {
                        Button("Open recordings folder", action: model.onOpenRecordings)
                        Spacer()
                        if let last = model.lastRecording {
                            Text("Last: \(last.file) · \(Int(last.seconds.rounded())) s")
                                .font(tiktok(12))
                                .foregroundStyle(.white.opacity(0.5))
                        }
                    }
                    .frame(height: 26)
                }
                Section("Captions") {
                    Row("Show captions") {
                        Toggle("", isOn: $model.settings.captionsShown).toggleStyle(.switch).controlSize(.mini).labelsHidden()
                    }
                    Group {
                        Row("Position") {
                            Segments(selection: $model.settings.captionPosition,
                                     options: [(Settings.CaptionPosition.top, "Top"), (.bottom, "Bottom")])
                        }
                        Row("Font") {
                            Picker("", selection: $model.settings.captionFont) {
                                ForEach(Settings.captionFonts, id: \.self) { Text($0).tag($0) }
                            }
                            .labelsHidden()
                            .frame(width: 150)
                        }
                        Row("Size") {
                            ValueSlider(value: $model.settings.captionSize, range: 24...96, step: 1) { String(format: "%.0f pt", $0) }
                        }
                        Row("Stay for") {
                            ValueSlider(value: $model.settings.captionSeconds, range: 1...10, step: 0.5) { String(format: "%.1f s", $0) }
                        }
                        Row("Opacity") {
                            ValueSlider(value: $model.settings.captionOpacity, range: 0.2...1, step: 0.05) { String(format: "%.0f%%", $0 * 100) }
                        }
                    }
                    .disabled(!model.settings.captionsShown)
                    .opacity(model.settings.captionsShown ? 1 : 0.45)
                }
                Section("Look") {
                    Row("Glass tint") {
                        ValueSlider(value: $model.settings.glassTint, range: 0...1, step: 0.05) { String(format: "%.0f%%", $0 * 100) }
                    }
                    Row("Opacity") {
                        ValueSlider(value: $model.settings.controlOpacity, range: 0.3...1, step: 0.05) { String(format: "%.0f%%", $0 * 100) }
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
        }
        .scrollIndicators(.visible)
        .font(tiktok(13))
        .foregroundStyle(.white.opacity(0.88))
        .tint(.white)
        .controlSize(.small)
    }
}

private struct Section<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased())
                .font(tiktok(10.5, "Medium"))
                .kerning(0.8)
                .foregroundStyle(.white.opacity(0.42))
            content
        }
    }
}

private struct Row<Control: View>: View {
    let title: String
    @ViewBuilder let control: Control

    init(_ title: String, @ViewBuilder control: () -> Control) {
        self.title = title
        self.control = control()
    }

    var body: some View {
        HStack {
            Text(title)
            Spacer(minLength: 12)
            control
        }
        .frame(height: 26)
    }
}

private struct Segments<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [(Value, String)]

    var body: some View {
        Picker("", selection: $selection) {
            ForEach(options.indices, id: \.self) { Text(options[$0].1).tag(options[$0].0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(width: 190)
    }
}

private struct ValueSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let label: (Double) -> String

    var body: some View {
        HStack(spacing: 10) {
            // Stepped by rounding rather than `step:`, which draws a row of tick marks under the slider.
            Slider(value: Binding(get: { value }, set: { value = ($0 / step).rounded() * step }), in: range).frame(width: 136)
            Text(label(value))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.6))
                .frame(width: 44, alignment: .trailing)
        }
    }
}

/// What a model is doing, in a few words.
private struct StatusLine: View {
    let status: ModelStatus
    var lastMs: Double?

    var body: some View {
        Text(text)
            .font(tiktok(12))
            .foregroundStyle(status.state == "error" ? accent : .white.opacity(0.5))
            .frame(maxWidth: .infinity, alignment: .trailing)
            .animation(.easeOut(duration: 0.2), value: text)
    }

    private var text: String {
        switch status.state {
        case "downloading": "Downloading · \(Int(status.progress * 100))%"
        case "loading": "Loading…"
        case "unloaded": "Unloaded · loads again when you record"
        case "ready": lastMs.map { "Ready · last phrase \(Int($0)) ms" } ?? "Ready"
        case "error": "Couldn’t load: \(status.message)"
        default: "Off"
        }
    }
}

/// One hotkey: the key (click to set it, then press it), what it does, and how it is pressed.
private struct HotkeyRow: View {
    @Binding var hotkey: Hotkey
    let capturing: Bool
    let capture: () -> Void
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Button(action: capture) {
                Text(capturing ? "Press a key…" : hotkey.label)
                    .font(tiktok(12, "Medium"))
                    .frame(width: 84)
            }
            .help("Click, then press the key you want: a single modifier (like right ⌘) or a key with modifiers")
            Picker("", selection: $hotkey.action) {
                ForEach(Hotkey.actionNames, id: \.0) { Text($0.1).tag($0.0) }
            }
            .labelsHidden()
            .frame(width: 104)
            Picker("", selection: $hotkey.mode) {
                ForEach(Hotkey.modeNames, id: \.0) { Text($0.1).tag($0.0) }
            }
            .labelsHidden()
            .frame(width: 140)
            Button(action: remove) {
                Image(systemName: "minus.circle").font(.system(size: 13))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white.opacity(0.55))
            .help("Remove this hotkey")
        }
        .frame(height: 26)
    }
}

/// Memory in use, and a clear warning when it gets tight.
private struct MemoryLine: View {
    let reading: MemoryReading?
    let cleanupOn: Bool

    var body: some View {
        if let reading {
            VStack(alignment: .leading, spacing: 4) {
                Text("PhononLive \(gigabytes(reading.total)) · of that, the speech engine \(gigabytes(reading.engine))")
                    .monospacedDigit()
                Text("Mac \(gigabytes(reading.physical - min(reading.physical, reading.available))) of \(gigabytes(reading.physical)) in use")
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.6))
                if reading.warning {
                    Text(cleanupOn ? "Memory is tight. Turning AI cleanup off frees about 2.5 GB." : "Memory is tight. Close other apps to keep dictation smooth.")
                        .foregroundStyle(accent)
                }
            }
            .font(tiktok(12))
        } else {
            Text("Measuring…").font(tiktok(12)).foregroundStyle(.white.opacity(0.5))
        }
    }

    private func gigabytes(_ bytes: UInt64) -> String {
        String(format: "%.1f GB", Double(bytes) / 1_073_741_824)
    }
}
