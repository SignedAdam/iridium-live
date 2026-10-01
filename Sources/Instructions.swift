import AppKit
import SwiftUI

/// A small glass window for the cleanup model's extra instructions: whatever you write is added to its rules for
/// every phrase. Save (⌘Return) keeps them; Cancel (Esc) leaves them as they were. One at a time.
@MainActor
final class InstructionsPanel {
    private static var open: InstructionsPanel?
    private let panel: KeyPanel

    /// Shows the editor centred on `screen`, holding `text`; `save` receives the new instructions.
    static func show(text: String, on screen: NSScreen, save: @escaping @MainActor (String) -> Void) {
        if let open { open.panel.makeKeyAndOrderFront(nil); return }
        open = InstructionsPanel(text: text, screen: screen, save: save)
    }

    private init(text: String, screen: NSScreen, save: @escaping @MainActor (String) -> Void) {
        let size = NSSize(width: 440, height: 320)
        let area = screen.visibleFrame
        panel = KeyPanel(contentRect: NSRect(x: (area.midX - size.width / 2).rounded(), y: (area.midY - size.height / 2).rounded(),
                                             width: size.width, height: size.height),
                         styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = true
        let close = {
            InstructionsPanel.open?.panel.orderOut(nil)
            InstructionsPanel.open = nil
        }
        panel.contentView = NSHostingView(rootView: InstructionsEditor(text: text, save: { save($0); close() }, cancel: close))
        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)
        panel.animator().alphaValue = 1
    }
}

/// A borderless panel that takes the keyboard without making the app active, like the notes.
private final class KeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

private struct InstructionsEditor: View {
    @State var text: String
    let save: (String) -> Void
    let cancel: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Cleanup instructions")
                .font(tiktok(15, "Medium"))
                .foregroundStyle(.white.opacity(0.95))
            Text("Added to the model's rules for every phrase. Write them as you would to a person.")
                .font(tiktok(12))
                .foregroundStyle(.white.opacity(0.5))
                .fixedSize(horizontal: false, vertical: true)
            TextEditor(text: $text)
                .font(tiktok(13))
                .foregroundStyle(.white.opacity(0.92))
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.white.opacity(0.06)))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.white.opacity(focused ? 0.22 : 0.1)))
                .overlay(alignment: .topLeading) {
                    if text.isEmpty {
                        Text("Use British spelling. Never use exclamation marks.")
                            .font(tiktok(13))
                            .foregroundStyle(.white.opacity(0.3))
                            .padding(.horizontal, 13)
                            .padding(.vertical, 8)
                            .allowsHitTesting(false)
                    }
                }
                .focused($focused)
            HStack(spacing: 8) {
                Spacer()
                Button("Cancel", action: cancel).buttonStyle(PanelButton(prominent: false)).keyboardShortcut(.cancelAction)
                Button("Save") { save(text.trimmingCharacters(in: .whitespacesAndNewlines)) }
                    .buttonStyle(PanelButton(prominent: true))
                    .keyboardShortcut(.return, modifiers: .command)
            }
        }
        .padding(18)
        .background(Glass(cornerRadius: 18, tint: 1))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .padding(10)
        .shadow(color: .black.opacity(0.35), radius: 14, y: 6)
        .onAppear { focused = true }
    }
}

/// The modal's two buttons: Save stands out, Cancel stays quiet.
private struct PanelButton: ButtonStyle {
    let prominent: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(tiktok(12.5, "Medium"))
            .foregroundStyle(prominent ? Color.black.opacity(0.85) : .white.opacity(0.85))
            .padding(.horizontal, 14)
            .frame(height: 26)
            .background(Capsule().fill(prominent ? .white.opacity(configuration.isPressed ? 0.75 : 0.92) : .white.opacity(configuration.isPressed ? 0.18 : 0.1)))
            .contentShape(Capsule())
    }
}
