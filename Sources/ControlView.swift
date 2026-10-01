import AppKit
import SwiftUI

/// Room around the glass inside its window, for the glass's own shadow.
let floatingMargin: CGFloat = 28

/// The whole control: one glass body whose bottom is the bar. Opening the notes or the settings grows it upward and
/// wider in one spring; switching between them slides the panes past each other (notes sit left of settings, like
/// their buttons) while the glass settles to the new pane's height. Panes keep their full width and are uncovered by
/// the growing glass rather than squeezed. Drag anywhere that is not a control to move it.
struct ControlView: View {
    @Bindable var model: AppModel
    let notes: NotesEditor
    let mover: WindowMover

    var body: some View {
        let size = model.glassSize
        VStack(spacing: 0) {
            ZStack(alignment: .bottom) {
                pane(.notes) { NotesPane(model: model, editor: notes).frame(height: model.notesHeight) }
                pane(.history) { HistoryPane(model: model).frame(height: AppModel.historyHeight) }
                pane(.settings) { SettingsPane(model: model).frame(height: AppModel.settingsHeight) }
            }
            .frame(width: AppModel.paneWidth)
            .frame(height: max(0, model.paneHeight - AppModel.seam), alignment: .bottom)
            .clipped()
            Rectangle().fill(.white.opacity(0.12))
                .frame(height: model.pane == nil ? 0 : AppModel.seam)
                .padding(.horizontal, 18)
            MemoryBanner(model: model)
                .frame(height: model.memoryWarning ? AppModel.bannerHeight : 0)
                .clipped()
            ControlBar(model: model)
        }
        .frame(width: size.width, height: size.height, alignment: .bottom)
        .background(Glass(cornerRadius: AppModel.barSize.height / 2, tint: model.settings.glassTint))
        .clipShape(RoundedRectangle(cornerRadius: AppModel.barSize.height / 2, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: AppModel.barSize.height / 2, style: .continuous))
        .gesture(DragGesture(minimumDistance: 2).onChanged { _ in mover.drag() }.onEnded { _ in mover.end() })
        .shadow(color: .black.opacity(0.32), radius: 16, y: 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .padding(floatingMargin)
        .animation(.spring(response: 0.42, dampingFraction: 0.86), value: model.pane)
        .animation(.easeOut(duration: 0.22), value: model.notesHeight)
        .animation(.spring(response: 0.42, dampingFraction: 0.86), value: model.memoryWarning)
    }

    /// A pane shows only while selected; the others wait just off to its side, faded out.
    private func pane(_ which: AppModel.Pane, @ViewBuilder content: () -> some View) -> some View {
        let shown = model.pane == which
        let side: CGFloat = which.rawValue < (model.pane?.rawValue ?? which.rawValue) ? -1 : 1
        return content()
            .opacity(shown ? 1 : 0)
            .offset(x: shown || model.pane == nil ? 0 : side * 40)
            .allowsHitTesting(shown)
    }
}

/// A red line above the bar while memory is tight, whatever else is open: the engine may slow down or be stopped by
/// the system. Clicking it opens settings, where the memory figures are.
struct MemoryBanner: View {
    @Bindable var model: AppModel

    var body: some View {
        Button(action: { if model.pane != .settings { model.toggleSettings() } }) {
            HStack(spacing: 6) {
                Image(systemName: "memorychip").font(.system(size: 11, weight: .semibold))
                Text(text).font(tiktok(12, "Medium"))
            }
            .foregroundStyle(accent)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Memory is tight. Click for details.")
    }

    private var text: String {
        guard let memory = model.memory else { return "Memory is low" }
        let used = Double(memory.physical - min(memory.physical, memory.available)) / 1_073_741_824
        return String(format: "Memory is low · %.1f of %.0f GB in use", used, Double(memory.physical) / 1_073_741_824)
    }
}

/// The notes pane: the editor, a placeholder while empty, the outline of the text area while you edit, and a slim
/// indicator of where you are whenever there is more text than fits.
struct NotesPane: View {
    @Bindable var model: AppModel
    let editor: NotesEditor

    var body: some View {
        let outline = RoundedRectangle(cornerRadius: 12, style: .continuous)
        NotesEditorView(editor: editor)
            .background {
                outline.fill(.white.opacity(model.notesEditing ? 0.045 : 0))
                    .overlay(outline.strokeBorder(.white.opacity(model.notesEditing ? 0.22 : 0), lineWidth: 1))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
            }
            .overlay(alignment: .topLeading) {
                if model.notesEmpty {
                    Text("Speak for notes")
                        .font(tiktok(15))
                        .foregroundStyle(.white.opacity(0.34))
                        .padding(.leading, NotesEditor.inset.width + 5)
                        .padding(.top, NotesEditor.inset.height)
                        .allowsHitTesting(false)
                }
            }
            .overlay(alignment: .trailing) {
                ScrollIndicator(metrics: model.notesScroll)
                    .padding(.trailing, 5)
                    .padding(.vertical, 12)
            }
            .animation(.easeOut(duration: 0.2), value: model.notesEditing)
    }
}

/// A slim thumb on the right edge: how much of the text is visible and where. Only there when the text overflows.
struct ScrollIndicator: View {
    let metrics: ScrollMetrics

    var body: some View {
        GeometryReader { geometry in
            let track = geometry.size.height
            let thumb = max(18, track * metrics.visibleFraction)
            Capsule().fill(.white.opacity(0.38))
                .frame(width: 3, height: thumb)
                .offset(y: (track - thumb) * metrics.position)
        }
        .frame(width: 3)
        .opacity(metrics.overflows ? 1 : 0)
        .animation(.easeOut(duration: 0.2), value: metrics.overflows)
        .allowsHitTesting(false)
    }
}

/// Moves the control's window with the pointer, for drags on the glass that no control claims.
@MainActor
final class WindowMover {
    private weak var window: NSWindow?
    private var start: (mouse: NSPoint, origin: NSPoint)?

    init(_ window: NSWindow) {
        self.window = window
    }

    func drag() {
        guard let window else { return }
        let mouse = NSEvent.mouseLocation  // screen coordinates: steady while the window moves under the pointer
        let start = self.start ?? (mouse, window.frame.origin)
        self.start = start
        window.setFrameOrigin(NSPoint(x: start.origin.x + mouse.x - start.mouse.x, y: start.origin.y + mouse.y - start.mouse.y))
    }

    func end() {
        start = nil
    }
}
