import AppKit
import SwiftUI

/// The first-launch window: one step per thing the app needs, each with what it is for, where it stands now, and the
/// one button that settles it. Nothing here is required — the window can be closed at any point and dictation runs
/// with whatever has been granted. It comes back on a later launch only while the microphone or Accessibility access
/// is missing. One at a time.
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
        // The window follows the content's height (a key being typed adds a row), so nothing is ever cut off.
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
        panel.animator().alphaValue = 1
    }
}

/// A borderless panel that takes the keyboard without making the app active, so a key can be pasted into it.
private final class KeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

private struct OnboardingView: View {
    @Bindable var setup: Setup
    let done: () -> Void
    @State private var editing: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Iridium Live")
                    .font(tiktok(17, "Medium"))
                    .foregroundStyle(.white.opacity(0.95))
                Text("Four things, all optional. Skip any of them and only that part waits.")
                    .font(tiktok(12))
                    .foregroundStyle(.white.opacity(0.5))
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
            Step(title: "AI cleanup", detail: keysDetail, done: setup.keys.values.contains(true)) {
                if !setup.importable().isEmpty {
                    Button("Import from ~/.env", action: setup.importFromDotEnv).buttonStyle(PanelButton(prominent: false))
                }
            }
            VStack(spacing: 0) {
                ForEach(ApiKey.all) { key in
                    KeyRow(key: key, stored: setup.keys[key.id] == true,
                           editing: Binding(get: { editing == key.id },
                                            set: { editing = $0 ? key.id : nil }),
                           save: { setup.store($0, for: key) })
                }
            }
            .padding(.leading, 26)
            Step(title: "Open at login", detail: setup.isBundled ? "Start Iridium Live with the Mac."
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
        .background(Glass(cornerRadius: 18, tint: 1))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .padding(10)
        .shadow(color: .black.opacity(0.35), radius: 14, y: 6)
    }

    private var microphoneDetail: String {
        switch setup.microphone {
        case .granted: "Granted."
        case .denied: "Turned off. Switch Iridium Live back on under Microphone."
        case .notAsked: "Everything you dictate is transcribed on this Mac."
        }
    }

    private var accessibilityDetail: String {
        setup.accessibility ? "Granted." : "Needed to type into other apps and to watch your hotkeys."
    }

    private var keysDetail: String {
        let held = ApiKey.all.filter { setup.keys[$0.id] == true }.map(\.name)
        return held.isEmpty ? "A key for Groq or OpenRouter lets cleanup run off this Mac."
                            : "\(held.joined(separator: " and ")) ready."
    }
}

/// One step: a mark that fills in when it is settled, what it is for, and its control on the right.
private struct Step<Control: View>: View {
    let title: String
    let detail: String
    let done: Bool
    @ViewBuilder let control: Control

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 14))
                .foregroundStyle(done ? .white.opacity(0.9) : .white.opacity(0.28))
                .frame(width: 14, height: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(tiktok(13.5, "Medium")).foregroundStyle(.white.opacity(0.92))
                Text(detail).font(tiktok(11.5)).foregroundStyle(.white.opacity(0.5))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            control.padding(.top, 1)
        }
    }
}

/// A key: its name, whether one is held, and the field that takes a new one. The key itself is never shown back.
private struct KeyRow: View {
    let key: ApiKey
    let stored: Bool
    @Binding var editing: Bool
    let save: (String?) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Text(key.name).font(tiktok(12)).foregroundStyle(.white.opacity(0.7)).frame(width: 84, alignment: .leading)
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
                Text(stored ? "Stored in the keychain" : "Not set")
                    .font(tiktok(11.5)).foregroundStyle(.white.opacity(stored ? 0.45 : 0.3))
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

/// The settings switch, in the panel's own idiom.
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

/// The panel's buttons: the one that moves things on stands out, the rest stay quiet.
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
