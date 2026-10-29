@preconcurrency import MeetingKit
import SwiftUI

extension ContainerValues {
    @Entry var sectionBreak = false
}

@MainActor
struct SettingsPane: View {
    @Bindable var model: AppModel
    @State private var editingKey: String?

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    speech
                    cleanup(proxy)
                    meetings
                    typing
                    hotkeys
                    notes
                    chatApps
                    captions
                    theme
                    recordings
                    memory
                    SetupSection(editing: $editingKey)
                }
                .padding(12)
            }
            .scrollIndicators(.visible)
        }
        .font(tiktok(13))
        .foregroundStyle(.white.opacity(0.88))
    }

    private var speech: some View {
        Section("Speech") {
            Row("Model", detail: status(model.speech), alert: model.speech.state == "error") {
                Segments(selection: $model.settings.speechModel, options: Settings.speechModels)
            }
        }
    }

    @ViewBuilder
    private func cleanup(_ proxy: ScrollViewProxy) -> some View {
        let openRouter = model.settings.cleanupProvider == "openrouter"
        let key = openRouter ? ApiKey.openRouter : ApiKey.groq
        let saved = model.settings.savedModelsByRecency
        let recent = Array(saved.prefix(3))
        let others = Array(saved.dropFirst(3))
        Section("AI cleanup") {
            Row("Clean up dictation",
                detail: model.settings.cleanupEnabled ? status(model.cleanup, lastMs: model.lastCleanupMs) : nil,
                alert: model.cleanup.state == "error") {
                GlassSwitch(isOn: $model.settings.cleanupEnabled)
            }
            Group {
                Row("Provider") {
                    Segments(selection: $model.settings.cleanupProvider,
                             options: Settings.cleanupProviders.map { ($0.id, $0.name) })
                }
                if Setup.shared.keys[key.id] != true {
                    Line(inset: 14) {
                        Text("No \(key.name) key").foregroundStyle(accent)
                        Spacer(minLength: 8)
                        Button("Add key") {
                            editingKey = key.id
                            withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo(key.id, anchor: .center) }
                        }
                        .buttonStyle(GlassButton())
                    }
                }
                if openRouter {
                    ForEach(recent) { item in
                        ModelRow(item: item, chosen: item.id == model.settings.cleanupModel) { choose(item) }
                            .transition(.opacity)
                    }
                    Line(inset: 14) {
                        if !others.isEmpty { ModelMenu(others: others, use: choose) }
                        Spacer(minLength: 0)
                        Button("Manage models", action: model.onManageModels).buttonStyle(GlassButton())
                    }
                } else {
                    Row("Model", inset: 14) {
                        let options = model.settings.cleanupModels(on: "groq")
                        GlassDropdown(selection: $model.settings.cleanupModel, options: options) { id in
                            AnyView(ModelStatsCard(name: options.first { $0.0 == id }?.1 ?? id, providerName: "Groq",
                                                   stats: ModelStats(provider: "groq", model: id), history: model.history))
                        }
                        .frame(width: 180)
                    }
                }
                Break().containerValue(\.sectionBreak, true)
                Row("Instructions", detail: instructionsPreview) {
                    Button(model.settings.cleanupInstructions.isEmpty ? "Add instructions" : "Edit", action: model.onEditInstructions)
                        .buttonStyle(GlassButton())
                }
                Row("Fix previous sentences on correction keywords") {
                    GlassSwitch(isOn: $model.settings.cleanupCorrections)
                }
                .tip(keywordsTip)
                if model.settings.cleanupCorrections {
                    Row("Sentences to read", inset: 14) {
                        GlassMenu(selection: $model.settings.cleanupContextSentences,
                                  options: [2, 3, 5, 8, 12].map { ($0, "\($0)") }).frame(width: 100)
                    }
                    .transition(.opacity)
                    Row("Sentences to fix", inset: 14) {
                        GlassMenu(selection: $model.settings.cleanupEditReach,
                                  options: [1, 2, 3, 4].map { ($0, "\($0)") }).frame(width: 100)
                    }
                    .transition(.opacity)
                }
                Row("Add quotes") {
                    GlassSwitch(isOn: $model.settings.cleanupQuotes)
                }
                Row("Clean up full recording on stop") {
                    GlassSwitch(isOn: $model.settings.cleanupPolish)
                }
                Break().containerValue(\.sectionBreak, true)
                Row("When cleanup fails") {
                    GlassMenu(selection: $model.settings.cleanupFailure,
                              options: [(.retry, "Retry"), (.notify, "Fail and notify"), (.raw, "Insert raw")])
                        .frame(width: 160)
                }
                if model.settings.cleanupFailure == .retry {
                    Row("Retries", inset: 14) {
                        GlassMenu(selection: $model.settings.cleanupRetries,
                                  options: [1, 2, 3, 5, 8].map { ($0, "\($0)") }).frame(width: 100)
                    }
                    .transition(.opacity)
                }
                Row("Benchmark mode") {
                    HStack(spacing: 8) {
                        Button("Results", action: model.onShowBenchmarks).buttonStyle(GlassButton())
                        GlassSwitch(isOn: $model.settings.cleanupBenchmark)
                    }
                }
            }
            .dimmed(!model.settings.cleanupEnabled)
            .animation(.easeOut(duration: 0.2), value: model.settings.cleanupCorrections)
            .animation(.easeOut(duration: 0.2), value: model.settings.cleanupFailure)
        }
    }

    @ViewBuilder
    private var meetings: some View {
        let engine = EngineFactory.options.first { $0.id == model.settings.meetingEngine }
        let engineKey = engine?.key.flatMap { ApiKey.named($0) }
        let summaryKey = ApiKey.named(model.settings.summaryKey)
        Section("Meetings") {
            Row("Engine", detail: engine.map { MeetingEngines.line($0) }) {
                EngineMenu(selection: $model.settings.meetingEngine).frame(width: 190)
            }
            if let engineKey {
                Row("\(engineKey.name) key", detail: keyDetail(engineKey), alert: !held(engineKey), inset: 14) {
                    KeyControl(key: engineKey, editing: $editingKey)
                }
                .transition(.opacity)
            }
            Row("Language") {
                GlassMenu(selection: $model.settings.meetingLanguage, options: Settings.meetingLanguages).frame(width: 150)
            }
            Row("When it ends", detail: model.settings.meetingAutoTranscribe
                ? nil : "The recording waits until you press Transcribe") {
                Segments(selection: $model.settings.meetingAutoTranscribe,
                         options: [(true, "Transcribe"), (false, "Later")])
            }
            Row("Live transcript", detail: "Words while you record, uses this Mac") {
                GlassSwitch(isOn: $model.settings.meetingLiveTranscript)
            }
            Break().containerValue(\.sectionBreak, true)
            Row("Microphone") {
                GlassSwitch(isOn: $model.settings.meetingMic)
            }
            if model.settings.meetingMic {
                Row("Input", inset: 14) {
                    GlassMenu(selection: microphoneChoice, options: microphoneOptions).frame(width: 190)
                }
                .transition(.opacity)
            }
            Row("System audio", detail: "Records the other side") {
                GlassSwitch(isOn: $model.settings.meetingSystem)
            }
            Break().containerValue(\.sectionBreak, true)
            Row("Summaries") {
                Segments(selection: $model.settings.summaryProvider,
                         options: Settings.summaryProviders.map { ($0.id, $0.name) })
            }
            Row("Model", inset: 14) {
                GlassMenu(selection: $model.settings.summaryModel,
                          options: model.settings.summaryModels(on: model.settings.summaryProvider)).frame(width: 190)
            }
            if let summaryKey {
                Row("\(summaryKey.name) key", detail: keyDetail(summaryKey), alert: !held(summaryKey), inset: 14) {
                    KeyControl(key: summaryKey, editing: $editingKey)
                }
            }
        }
        .animation(.easeOut(duration: 0.2), value: model.settings.meetingMic)
        .animation(.easeOut(duration: 0.2), value: model.settings.meetingAutoTranscribe)
        .animation(.easeOut(duration: 0.2), value: model.settings.meetingEngine)
        .animation(.easeOut(duration: 0.2), value: model.settings.summaryProvider)
    }

    private func held(_ key: ApiKey) -> Bool { Setup.shared.keys[key.id] == true }

    private func keyDetail(_ key: ApiKey) -> String? { held(key) ? "In the keychain" : "Needed" }

    private var microphoneChoice: Binding<String> {
        Binding(get: { model.settings.meetingMicrophone ?? "" },
                set: { model.settings.meetingMicrophone = $0.isEmpty ? nil : $0 })
    }

    private var microphoneOptions: [(String, String)] {
        [("", "System default")] + (model.meetings?.inputDevices ?? []).map { ($0.uid, $0.name) }
    }

    private var typing: some View {
        Section("Typing") {
            Row("Wait before typing") {
                GlassSlider(value: $model.settings.typingHold, range: 0.2...3, step: 0.1) { String(format: "%.1f s", $0) }
            }
            Row("Paste into", detail: "For apps that lose typed keys") {
                PasteApps(bundleIDs: $model.settings.pasteApps).frame(width: 150)
            }
        }
    }

    private var notes: some View {
        Section("Notes") {
            Row("File takes by topic",
                detail: model.settings.notesFiling ? filingDetail : nil,
                alert: model.settings.notesFiling && !held(ApiKey.named(model.settings.cleanupProvider) ?? ApiKey.openRouter)) {
                GlassSwitch(isOn: $model.settings.notesFiling)
            }
        }
    }

    private var filingDetail: String {
        let key = ApiKey.named(model.settings.cleanupProvider) ?? ApiKey.openRouter
        return held(key) ? "Sorts each take into notes and tags it" : "Needs the \(key.name) key"
    }

    private var hotkeys: some View {
        Section("Hotkeys") {
            let clashing = Hotkey.conflicting(in: model.settings.hotkeys)
            let waiting = Hotkey.waitingForDoubleTap(in: model.settings.hotkeys)
            ForEach($model.settings.hotkeys) { $hotkey in
                HotkeyRow(hotkey: $hotkey, capturing: model.capturingHotkey == hotkey.id,
                          conflict: clashing.contains(hotkey.id), waits: waiting.contains(hotkey.id),
                          capture: { model.onCaptureHotkey(hotkey.id) },
                          remove: { model.settings.hotkeys.removeAll { $0.id == hotkey.id } })
            }
            VStack(alignment: .leading, spacing: 6) {
                AddRow {
                    let hotkey = Hotkey(keyCode: 54)
                    model.settings.hotkeys.append(hotkey)
                    model.onCaptureHotkey(hotkey.id)
                }
                if !model.hotkeysListening, !model.settings.hotkeys.isEmpty {
                    Text("Needs Accessibility access").font(tiktok(12)).foregroundStyle(accent)
                }
            }
            .padding(.vertical, 6)
        }
    }

    @ViewBuilder
    private var chatApps: some View {
        if let chatApps = model.chatApps {
            Section("Chat apps") {
                Row("Button beside Send", detail: "Dictate into message box") {
                    GlassSwitch(isOn: Bindable(chatApps).enabled)
                }
                if chatApps.enabled {
                    ForEach(Bindable(chatApps).apps) { $profile in
                        Row(profile.name.isEmpty ? profile.bundleID : profile.name,
                            detail: profile.isPlaced ? nil : "Not set up", alert: !profile.isPlaced) {
                            HStack(spacing: 8) {
                                Button("Customise", action: model.onEditChatApps).buttonStyle(GlassButton())
                                GlassSwitch(isOn: $profile.enabled)
                            }
                        }
                        .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                } else {
                    Line {
                        Text(chatApps.apps.map { $0.name.isEmpty ? $0.bundleID : $0.name }.joined(separator: ", "))
                            .foregroundStyle(.white.opacity(0.78))
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.2), value: chatApps.enabled)
        }
    }

    private var captions: some View {
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
                Row("Show for") {
                    GlassSlider(value: $model.settings.captionSeconds, range: 1...10, step: 0.5) { String(format: "%.1f s", $0) }
                }
                Row("Opacity") {
                    GlassSlider(value: $model.settings.captionOpacity, range: 0.2...1, step: 0.05) { String(format: "%.0f%%", $0 * 100) }
                }
            }
            .dimmed(!model.settings.captionsShown)
        }
    }

    private var theme: some View {
        Section("Theme") {
            Row("Glass tint") {
                GlassSlider(value: $model.settings.glassTint, range: 0...1, step: 0.05) { String(format: "%.0f%%", $0 * 100) }
            }
            Row("Opacity") {
                GlassSlider(value: $model.settings.controlOpacity, range: 0.3...1, step: 0.05) { String(format: "%.0f%%", $0 * 100) }
            }
            Row("Compact", detail: "One thin line with small controls") {
                GlassSwitch(isOn: $model.settings.compactControl)
            }
        }
    }

    private var recordings: some View {
        Section("Recordings") {
            Row("Keep audio of every recording", detail: "Failed recordings keep theirs either way") {
                GlassSwitch(isOn: $model.settings.saveAudio)
            }
            Row("Folder", detail: model.lastRecording.map { "Latest \($0.file), \(Int($0.seconds.rounded())) s" }) {
                Button("Open", action: model.onOpenRecordings).buttonStyle(GlassButton())
            }
        }
    }

    private var memory: some View {
        Section("Memory") {
            Line {
                if let reading = model.memory {
                    HStack(spacing: 16) {
                        Figure("Iridium Live \(gigabytes(reading.total))")
                        Figure("Mac \(whole(reading.physical - min(reading.physical, reading.available))) of \(whole(reading.physical)) GB")
                    }
                }
                Spacer(minLength: 8)
                Button(model.speech.state == "unloaded" ? "Unloaded" : "Unload", action: model.onUnload)
                    .buttonStyle(GlassButton())
                    .disabled(model.speech.state == "unloaded")
            }
            Row("Unload after idle") {
                GlassMenu(selection: idleAfter, options: [(0, "Never")] + Settings.idleChoices).frame(width: 100)
            }
        }
    }

    private var idleAfter: Binding<Int> {
        Binding(get: { model.settings.autoUnload ? model.settings.autoUnloadMinutes : 0 },
                set: { minutes in
                    if minutes == 0 {
                        model.settings.autoUnload = false
                    } else {
                        model.settings.autoUnload = true
                        model.settings.autoUnloadMinutes = minutes
                    }
                })
    }

    private func choose(_ item: SavedModel) {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.9)) { model.use(item) }
    }

    private var keywordsTip: String {
        let words = model.correctionKeywords
        guard !words.isEmpty else { return "Keywords appear once the speech model is loaded" }
        let lines = stride(from: 0, to: words.count, by: 4).map { words[$0..<min($0 + 4, words.count)].joined(separator: ", ") }
        return (["Correction keywords:"] + lines).joined(separator: "\n")
    }

    private var instructionsPreview: String? {
        let text = model.settings.cleanupInstructions.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = text.split(separator: "\n").first else { return nil }
        return first.count > 48 ? String(first.prefix(47)) + "…" : String(first)
    }

    private func status(_ status: ModelStatus, lastMs: Double? = nil) -> String? {
        switch status.state {
        case "downloading": "Downloading \(Int(status.progress * 100))%"
        case "loading": "Loading…"
        case "unloaded": "Unloaded"
        case "error": status.model?.contains(":") == true ? status.message : "Couldn’t load: \(status.message)"
        case "ready": lastMs.map { "Last: \(Int($0)) ms" }
        default: nil
        }
    }

    private func gigabytes(_ bytes: UInt64) -> String {
        String(format: "%.1f GB", Double(bytes) / 1_073_741_824)
    }

    private func whole(_ bytes: UInt64) -> String {
        String(format: "%.0f", Double(bytes) / 1_073_741_824)
    }
}

@MainActor
private struct SetupSection: View {
    @Binding var editing: String?
    private let setup = Setup.shared

    var body: some View {
        Section("Setup") {
            Row("Microphone", detail: microphone, alert: setup.microphone == .denied) {
                if setup.microphone == .granted {
                    Figure("Granted")
                } else {
                    Button(setup.microphone == .notAsked ? "Allow" : "Open Settings", action: setup.askForMicrophone)
                        .buttonStyle(GlassButton())
                }
            }
            Row("Accessibility", detail: setup.accessibility ? nil : "Needed for typing and hotkeys.",
                alert: !setup.accessibility) {
                if setup.accessibility {
                    Figure("Granted")
                } else {
                    Button("Allow", action: setup.askForAccessibility).buttonStyle(GlassButton())
                }
            }
            Row("System audio", detail: setup.systemAudio ? nil : "Lets meetings record the other side.") {
                if setup.systemAudio {
                    Figure("Granted")
                } else {
                    Button("Allow", action: setup.askForSystemAudio).buttonStyle(GlassButton())
                }
            }
            ForEach(ApiKey.all) { key in
                Row("\(key.name) key", detail: setup.keys[key.id] == true ? "In the keychain" : nil) {
                    KeyControl(key: key, editing: $editing)
                }
                .id(key.id)
            }
            Row("Open at login", detail: setup.isBundled ? nil : "Needs the app in /Applications.") {
                GlassSwitch(isOn: Binding(get: { setup.openAtLogin }, set: { setup.setOpenAtLogin($0) }))
                    .disabled(!setup.isBundled)
            }
            if let trouble = setup.trouble {
                Row("Trouble", detail: trouble, alert: true) { EmptyView() }
            }
        }
        .onAppear { setup.watch() }
        .onDisappear { setup.unwatch() }
    }

    private var microphone: String? {
        switch setup.microphone {
        case .granted: nil
        case .denied: "Off. Turn on in System Settings."
        case .notAsked: "Not requested yet."
        }
    }
}

@MainActor
private struct KeyControl: View {
    let key: ApiKey
    @Binding var editing: String?
    private let setup = Setup.shared
    @State private var typed = ""

    var body: some View {
        if editing == key.id {
            HStack(spacing: 6) {
                SecureField(key.site, text: $typed)
                    .textFieldStyle(.plain)
                    .font(tiktok(12))
                    .padding(.horizontal, 9)
                    .frame(width: 150, height: 24)
                    .background(Pill(fill: 0.08))
                    .onSubmit(store)
                Button("Save", action: store).buttonStyle(GlassButton())
            }
        } else {
            HStack(spacing: 6) {
                Button(setup.keys[key.id] == true ? "Change" : "Set") { typed = ""; editing = key.id }
                    .buttonStyle(GlassButton())
                if setup.keys[key.id] == true {
                    Button("Remove") { setup.store(nil, for: key) }.buttonStyle(GlassButton())
                }
            }
        }
    }

    private func store() {
        setup.store(typed, for: key)
        typed = ""
        editing = nil
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
                .foregroundStyle(.white.opacity(0.78))
                .padding(.leading, 12)
            Group(subviews: content) { rows in
                let items = Array(rows)
                let lined = items.indices
                    .filter { $0 > 0 && !items[$0].containerValues.sectionBreak && !items[$0 - 1].containerValues.sectionBreak }
                    .map { items[$0].id }
                VStack(spacing: 0) {
                    ForEach(rows) { row in
                        if lined.contains(row.id) {
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

private struct Break: View {
    var body: some View {
        Rectangle().fill(.white.opacity(0.09)).frame(height: 1).padding(.vertical, 7)
    }
}

private struct Line<Content: View>: View {
    var inset: CGFloat = 0
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: 10) { content }
            .padding(.leading, inset)
            .padding(.vertical, 4)
            .frame(minHeight: Row<EmptyView>.height)
    }
}

private struct ModelRow: View {
    let item: SavedModel
    let chosen: Bool
    let use: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Text(item.shortName).lineLimit(1)
                Text(item.providerName)
                    .font(tiktok(12, "Light"))
                    .foregroundStyle(.white.opacity(0.78))
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if chosen {
                Image(systemName: "checkmark").font(.system(size: 12, weight: .semibold)).foregroundStyle(.white.opacity(0.95))
            } else {
                Button("Use", action: use).buttonStyle(GlassButton())
            }
        }
        .padding(.leading, 14)
        .padding(.vertical, 4)
        .frame(minHeight: Row<EmptyView>.height)
    }
}

private struct ModelMenu: View {
    let others: [SavedModel]
    let use: (SavedModel) -> Void
    @State private var hovering = false

    var body: some View {
        MenuTrigger { others.map { item in MenuItem(id: item.id, title: item.title) { use(item) } } } label: {
            HStack(spacing: 4) {
                Text("\(others.count) more")
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)).opacity(0.55)
            }
            .font(tiktok(12, "Medium"))
            .foregroundStyle(.white.opacity(0.92))
            .padding(.horizontal, 12)
            .frame(height: 24)
            .background(Pill(fill: hovering ? 0.16 : 0.1))
            .contentShape(Capsule())
        }
        .fixedSize()
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

private struct EngineMenu: View {
    @Binding var selection: String
    @State private var rect = MeetingRect()
    @State private var hovering = false

    var body: some View {
        Button(action: open) {
            HStack(spacing: 4) {
                Text(EngineFactory.name(for: selection)).lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 8, weight: .bold)).opacity(0.55)
            }
            .font(tiktok(12, "Medium"))
            .foregroundStyle(.white.opacity(0.92))
            .padding(.horizontal, 9)
            .frame(height: 24)
            .background(Pill(fill: hovering ? 0.16 : 0.1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .background(MeetingRectReader(box: rect))
    }

    private func open() {
        let items = MeetingEngines.settingsItems(selected: selection) { selection = $0 }
        if let frame = rect.screenRect {
            MenuPanel.show(items, under: frame)
        } else {
            MenuPanel.show(items, at: NSEvent.mouseLocation)
        }
    }
}

private struct Row<Control: View>: View {
    static var height: CGFloat { 30 }

    let title: String
    let detail: String?
    let alert: Bool
    let inset: CGFloat
    @ViewBuilder let control: Control

    init(_ title: String, detail: String? = nil, alert: Bool = false, inset: CGFloat = 0,
         @ViewBuilder control: () -> Control) {
        self.title = title
        self.detail = detail
        self.alert = alert
        self.inset = inset
        self.control = control()
    }

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let detail {
                    Text(detail)
                        .font(tiktok(11.5))
                        .foregroundStyle(alert ? accent : .white.opacity(0.78))
                        .lineLimit(2)
                        .transition(.opacity)
                }
            }
            Spacer(minLength: 0)
            control
        }
        .padding(.leading, inset)
        .padding(.vertical, 4)
        .frame(minHeight: Self.height)
        .animation(.easeOut(duration: 0.2), value: detail)
    }
}

private extension View {
    func dimmed(_ dimmed: Bool) -> some View {
        disabled(dimmed).opacity(dimmed ? 0.4 : 1).animation(.easeOut(duration: 0.15), value: dimmed)
    }
}

private struct Figure: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text).monospacedDigit().foregroundStyle(.white.opacity(0.85))
    }
}

struct Pill: View {
    var fill = 0.1
    var body: some View {
        Capsule().fill(.white.opacity(fill)).overlay(Capsule().strokeBorder(.white.opacity(0.13)))
    }
}

struct GlassButton: ButtonStyle {
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
                .opacity(isEnabled ? 1 : 0.38)
                .contentShape(Capsule())
                .onHover { hovering = $0 }
                .animation(.easeOut(duration: 0.12), value: hovering)
        }
    }
}

struct Segments<Value: Hashable>: View {
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
                        .foregroundStyle(.white.opacity(chosen ? 0.95 : 0.72))
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

struct GlassSwitch: View {
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
                .foregroundStyle(.white.opacity(0.85))
                .frame(width: 40, alignment: .trailing)
        }
    }
}

private struct GlassMenu<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [(Value, String)]
    var label: String? = nil

    var body: some View {
        MenuButton(title: label ?? options.first { $0.0 == selection }?.1 ?? "") {
            dropdownItems(options, selection: $selection)
        }
    }
}

/// The apps typing pastes into: those listed, ticked, then every other app now open; a click ticks or unticks one.
private struct PasteApps: View {
    @Binding var bundleIDs: [String]

    var body: some View {
        MenuButton(title: bundleIDs.isEmpty ? "None" : bundleIDs.map(Self.name).joined(separator: ", "), items: items)
    }

    private func items() -> [MenuItem] {
        let open = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
            .compactMap(\.bundleIdentifier).filter { $0 != Bundle.main.bundleIdentifier && !bundleIDs.contains($0) }
        let others = Set(open).sorted { Self.name($0).localizedCaseInsensitiveCompare(Self.name($1)) == .orderedAscending }
        let chosen = $bundleIDs
        var items: [MenuItem] = []
        for id in bundleIDs + others {
            let listed = bundleIDs.contains(id)
            var icon: (@MainActor () -> AnyView)?
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
                let image = NSWorkspace.shared.icon(forFile: url.path)
                icon = { AnyView(Image(nsImage: image).resizable().frame(width: 15, height: 15)) }
            }
            let toggle: @MainActor () -> Void = {
                if listed { chosen.wrappedValue.removeAll { $0 == id } } else { chosen.wrappedValue.append(id) }
            }
            items.append(MenuItem(id: id, title: Self.name(id), icon: icon, checked: listed, action: toggle))
        }
        return items
    }

    private static func name(_ id: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return id }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }
}

/// A capsule showing `title` that opens the glass menu of `items` under itself.
private struct MenuButton: View {
    let title: String
    let items: @MainActor () -> [MenuItem]
    @State private var hovering = false

    var body: some View {
        MenuTrigger(items: items) {
            HStack(spacing: 4) {
                Text(title).lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 8, weight: .bold)).opacity(0.55)
            }
            .font(tiktok(12, "Medium"))
            .foregroundStyle(.white.opacity(0.92))
            .padding(.horizontal, 9)
            .frame(height: 24)
            .background(Pill(fill: hovering ? 0.16 : 0.1))
            .contentShape(Capsule())
        }
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

private struct HotkeyRow: View {
    @Binding var hotkey: Hotkey
    let capturing: Bool
    let conflict: Bool
    let waits: Bool
    let capture: () -> Void
    let remove: () -> Void
    @State private var hovering = false
    @State private var hoveringRemove = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                GlassSwitch(isOn: $hotkey.enabled)
                HStack(spacing: 4) {
                    Button(action: capture) {
                        Text(capturing ? "Press a key" : hotkey.label).lineLimit(1)
                    }
                    .buttonStyle(Keycap(capturing: capturing))
                    .fixedSize()
                    .tip("Click, then press a key")
                    InlineMenu(selection: $hotkey.gesture, options: Hotkey.gestureNames(for: hotkey.action))
                    InlineMenu(selection: action, options: Hotkey.actionNames)
                }
                .opacity(hotkey.enabled ? 1 : 0.45)
                Spacer(minLength: 0)
                Button(action: remove) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white.opacity(hoveringRemove ? 0.95 : 0.6))
                        .frame(width: 18, height: 18)
                        .background(Circle().fill(.white.opacity(hoveringRemove ? 0.14 : 0)))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .opacity(hovering ? 1 : 0)
                .onHover { hoveringRemove = $0 }
                .tip("Remove")
            }
            if conflict {
                note("Already used by another hotkey", color: accent)
            } else if waits {
                note("Taps wait for a possible double-tap", color: .white.opacity(0.78))
            }
        }
        .padding(.vertical, 6)
        .frame(minHeight: Row<EmptyView>.height)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.2), value: conflict || waits)
        .animation(.easeOut(duration: 0.12), value: hovering)
    }

    private var action: Binding<Hotkey.Action> {
        Binding(get: { hotkey.action },
                set: { wanted in
                    hotkey.action = wanted
                    if wanted == .meeting, hotkey.gesture == .hold { hotkey.gesture = .press }
                })
    }

    private func note(_ text: String, color: Color) -> some View {
        Text(text).font(tiktok(11.5)).foregroundStyle(color).lineLimit(1).padding(.leading, 2)
    }
}

private struct Keycap: ButtonStyle {
    let capturing: Bool

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
        configuration.label
            .font(tiktok(12.5, "Medium"))
            .foregroundStyle(capturing ? accent : .white.opacity(0.96))
            .padding(.horizontal, 8)
            .frame(minWidth: 40, minHeight: 24)
            .background {
                shape.fill(LinearGradient(colors: [.white.opacity(0.24), .white.opacity(0.1)], startPoint: .top, endPoint: .bottom))
                    .overlay(shape.strokeBorder(capturing ? accent.opacity(0.8) : .white.opacity(0.24)))
                    .shadow(color: .black.opacity(0.5), radius: 0, y: configuration.isPressed ? 0 : 2)
            }
            .offset(y: configuration.isPressed ? 1.5 : 0)
            .contentShape(shape)
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
    }
}

private struct InlineMenu<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [(Value, String)]
    @State private var hovering = false

    var body: some View {
        MenuTrigger { dropdownItems(options, selection: $selection) } label: {
            HStack(spacing: 3) {
                Text(options.first { $0.0 == selection }?.1 ?? "").lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 7.5, weight: .bold)).opacity(0.6)
            }
            .font(tiktok(12.5))
            .foregroundStyle(.white.opacity(hovering ? 1 : 0.8))
            .padding(.horizontal, 5)
            .frame(height: 24)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(.white.opacity(hovering ? 0.09 : 0)))
            .contentShape(Rectangle())
        }
        .fixedSize()
        .onHover { hovering = $0 }
    }
}

private struct AddRow: View {
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "plus").font(.system(size: 10, weight: .bold))
                Text("Add hotkey")
            }
            .font(tiktok(12.5, "Medium"))
            .foregroundStyle(.white.opacity(hovering ? 0.95 : 0.75))
            .frame(maxWidth: .infinity)
            .frame(height: 28)
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(.white.opacity(hovering ? 0.35 : 0.2), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

