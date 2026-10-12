import AppKit
import SwiftUI

@MainActor
final class OnboardingPanel {
    private static var open: OnboardingPanel?
    private let panel: KeyPanel
    private let setup = Setup.shared

    static func show(on screen: NSScreen) {
        if let open { open.panel.makeKeyAndOrderFront(nil); return }
        open = OnboardingPanel(screen: screen)
    }

    private init(screen: NSScreen) {
        let width: CGFloat = 460
        let area = screen.visibleFrame
        panel = KeyPanel(contentRect: NSRect(x: 0, y: 0, width: width, height: 400),
                         styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = true
        setup.watch()
        let close = { @MainActor [panel, setup] in
            setup.seen()
            setup.unwatch()
            panel.orderOut(nil)
            OnboardingPanel.open = nil
        }
        let controller = NSHostingController(rootView: OnboardingView(setup: setup, done: close)
            .frame(width: width)
            .fixedSize(horizontal: false, vertical: true))
        controller.sizingOptions = [.preferredContentSize]
        panel.contentViewController = controller
        let size = controller.view.fittingSize
        panel.setFrame(NSRect(x: (area.midX - size.width / 2).rounded(), y: (area.midY - size.height / 2).rounded(),
                              width: size.width, height: size.height), display: true)
        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)
        followLook(panel)
        followSystemSettings()
    }

    private func followSystemSettings() {
        let away = withObservationTracking { setup.inSystemSettings } onChange: { [weak self] in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.followSystemSettings() } }
        }
        guard panel.isVisible, (panel.level == .normal) != away else { return }
        panel.level = away ? .normal : .floating
        if !away { panel.orderFrontRegardless() }
    }
}

private final class KeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

private struct OnboardingView: View {
    @Bindable var setup: Setup
    let done: () -> Void
    @State private var editing: String?
    @State private var keysLater = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Iridium Live")
                    .font(tiktok(17, "Medium"))
                    .foregroundStyle(.white.opacity(0.95))
                Text("Microphone and Accessibility are needed. The rest is optional.")
                    .font(tiktok(12))
                    .foregroundStyle(.white.opacity(0.78))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Step(title: "Microphone", detail: microphoneDetail, done: setup.microphone == .granted) {
                if setup.microphone != .granted {
                    Button(setup.microphone == .notAsked ? "Allow" : "Open Settings", action: setup.askForMicrophone)
                        .buttonStyle(PanelButton(prominent: true))
                }
            }
            Step(title: "Accessibility", detail: accessibilityDetail, done: setup.accessibility) {
                if !setup.accessibility {
                    Button("Allow", action: setup.askForAccessibility).buttonStyle(PanelButton(prominent: true))
                }
            }
            Step(title: "AI cleanup", detail: keysDetail, done: hasCleanupKey, optional: true) {
                if !hasCleanupKey {
                    Button(keysLater ? "Set up now" : "Set up later") {
                        withAnimation(.easeOut(duration: 0.2)) { keysLater.toggle() }
                    }
                    .buttonStyle(PanelButton(prominent: false))
                }
            }
            if !keysLater {
                VStack(spacing: 0) {
                    ForEach(ApiKey.cleanup) { key in
                        KeyRow(key: key, stored: setup.keys[key.id] == true,
                               editing: Binding(get: { editing == key.id },
                                                set: { editing = $0 ? key.id : nil }),
                               save: { setup.store($0, for: key) })
                    }
                }
                .padding(.leading, 26)
                .transition(.opacity)
            }
            Step(title: "System audio", detail: systemAudioDetail, done: setup.systemAudio, optional: true) {
                if !setup.systemAudio {
                    Button("Allow", action: setup.askForSystemAudio).buttonStyle(PanelButton(prominent: false))
                }
            }
            Step(title: "Open at login", detail: setup.isBundled ? "Open Iridium Live when you log in."
                                                                 : "Needs the app in /Applications.",
                 done: setup.openAtLogin) {
                GlassToggle(isOn: setup.openAtLogin) { setup.setOpenAtLogin($0) }
                    .disabled(!setup.isBundled)
            }
            if let trouble = setup.trouble {
                Text(trouble).font(tiktok(11.5)).foregroundStyle(accent).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            HStack {
                Spacer()
                Button("Done", action: done).buttonStyle(PanelButton(prominent: true)).keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .glass(18)
        .padding(10)
    }

    private var microphoneDetail: String {
        switch setup.microphone {
        case .granted: "Granted."
        case .denied: "Off. Turn on Iridium Live in System Settings."
        case .notAsked: "Speech is transcribed on this Mac."
        }
    }

    private var accessibilityDetail: String {
        setup.accessibility ? "Granted." : "Needed for typing and hotkeys."
    }

    private var keysDetail: String {
        let held = ApiKey.cleanup.filter { setup.keys[$0.id] == true }.map(\.name)
        if !held.isEmpty { return "\(held.joined(separator: " and ")) ready." }
        return keysLater ? "Add keys later in Settings, Setup."
                         : "A Groq or OpenRouter key turns on AI cleanup."
    }

    private var hasCleanupKey: Bool { ApiKey.cleanup.contains { setup.keys[$0.id] == true } }

    private var systemAudioDetail: String {
        setup.systemAudio ? "Granted." : "Lets meetings record the other side."
    }
}

private struct Step<Control: View>: View {
    static var settled: Color { Color(red: 0.45, green: 0.88, blue: 0.6) }

    let title: String
    let detail: String
    let done: Bool
    var optional = false
    @ViewBuilder let control: Control

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 14))
                .foregroundStyle(done ? Self.settled : .white.opacity(0.28))
                .shadow(color: Self.settled.opacity(done ? 0.55 : 0), radius: 5)
                .frame(width: 14, height: 18)
                .animation(.easeOut(duration: 0.3), value: done)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 7) {
                    Text(title).font(tiktok(13.5, "Medium")).foregroundStyle(.white.opacity(0.92))
                    if optional {
                        Text("Optional")
                            .font(tiktok(10, "Medium"))
                            .foregroundStyle(.white.opacity(0.78))
                            .padding(.horizontal, 6)
                            .frame(height: 16)
                            .background(Capsule().strokeBorder(.white.opacity(0.22)))
                    }
                }
                Text(detail).font(tiktok(11.5)).foregroundStyle(.white.opacity(0.78))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            control.padding(.top, 1)
        }
    }
}

private struct KeyRow: View {
    let key: ApiKey
    let stored: Bool
    @Binding var editing: Bool
    let save: (String?) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Text(key.name).font(tiktok(12)).foregroundStyle(.white.opacity(0.85)).frame(width: 84, alignment: .leading)
            if editing {
                SecureField(key.site, text: $text)
                    .textFieldStyle(.plain)
                    .font(tiktok(12))
                    .foregroundStyle(.white.opacity(0.9))
                    .padding(.horizontal, 9)
                    .frame(height: 24)
                    .background(Capsule().fill(.white.opacity(0.08)).overlay(Capsule().strokeBorder(.white.opacity(0.16))))
                    .focused($focused)
                    .onSubmit { commit() }
                Button("Save", action: commit).buttonStyle(PanelButton(prominent: true))
            } else {
                Text(stored ? "In the keychain" : "Not set")
                    .lineLimit(1)
                    .fixedSize()
                    .font(tiktok(11.5)).foregroundStyle(.white.opacity(0.78))
                Spacer(minLength: 0)
                Button(stored ? "Change" : "Set") { text = ""; editing = true }
                    .buttonStyle(PanelButton(prominent: false))
                if stored {
                    Button("Remove") { save(nil) }.buttonStyle(PanelButton(prominent: false))
                }
            }
        }
        .frame(height: 30)
        .onChange(of: editing) { _, now in focused = now }
    }

    private func commit() {
        save(text)
        text = ""
        editing = false
    }
}

private struct GlassToggle: View {
    let isOn: Bool
    let set: (Bool) -> Void

    var body: some View {
        Button { set(!isOn) } label: {
            Capsule()
                .fill(isOn ? .white.opacity(0.85) : .white.opacity(0.12))
                .overlay(Capsule().strokeBorder(.white.opacity(0.16)))
                .frame(width: 38, height: 22)
                .overlay(alignment: isOn ? .trailing : .leading) {
                    Circle()
                        .fill(isOn ? Color.black.opacity(0.75) : .white.opacity(0.75))
                        .frame(width: 16, height: 16)
                        .padding(3)
                }
        }
        .buttonStyle(.plain)
        .animation(.spring(response: 0.25, dampingFraction: 0.8), value: isOn)
    }
}

private struct PanelButton: ButtonStyle {
    let prominent: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(tiktok(12, "Medium"))
            .foregroundStyle(prominent ? Color.black.opacity(0.85) : .white.opacity(0.85))
            .padding(.horizontal, 12)
            .frame(height: 24)
            .background(Capsule().fill(prominent ? .white.opacity(configuration.isPressed ? 0.75 : 0.92)
                                                 : .white.opacity(configuration.isPressed ? 0.18 : 0.1)))
            .contentShape(Capsule())
    }
}

