import AppKit
import SwiftUI

/// Room around the glass inside its window, for the glass's own shadow.
let floatingMargin: CGFloat = 28

/// The whole control: one glass body around the bar. Opening the notes or the settings grows it, away from the bar and
/// wider, in one spring: upward, or downward when the control sits too high on the screen for the tallest pane to fit
/// above. Switching panes slides them past each other (notes sit left of settings, like their buttons) while the glass
/// settles to the new pane's height. Panes keep their full width and are uncovered by the growing glass rather than
/// squeezed. Drag anywhere that is not a control to move it.
struct ControlView: View {
    @Bindable var model: AppModel
    let notes: NotesEditor
    let mover: WindowMover

    var body: some View {
        let size = model.glassSize
        let down = model.opensDown
        let barRegion = AppModel.barSize.height + model.linesHeight
        VStack(spacing: 0) {
            if down {
                bar
                lines
                seam
                panes
            } else {
                panes
                seam
                lines
                bar
            }
        }
        .frame(width: size.width, height: size.height, alignment: down ? .top : .bottom)
        .background(Glass(cornerRadius: AppModel.barSize.height / 2, tint: model.settings.glassTint))
        .clipShape(RoundedRectangle(cornerRadius: AppModel.barSize.height / 2, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: AppModel.barSize.height / 2, style: .continuous))
        .gesture(DragGesture(minimumDistance: 2).onChanged { _ in mover.drag() }.onEnded { _ in mover.end() })
        .overlayPreferenceValue(TipKey.self) { tips in
            TipLayer(tips: tips, bar: down ? 0...barRegion : (size.height - barRegion)...size.height, barOnTop: down)
        }
        .shadow(color: .black.opacity(0.32), radius: 16, y: 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: down ? .top : .bottom)
        .padding(floatingMargin)
        .animation(.spring(response: 0.42, dampingFraction: 0.86), value: model.pane)
        .animation(.easeOut(duration: 0.22), value: model.notesHeight)
        .animation(.spring(response: 0.42, dampingFraction: 0.86), value: model.linesHeight)
    }

    /// The bar; right-click it for the control's own menu (unload, notes, my notes, history, settings).
    private var bar: some View {
        ControlBar(model: model).onRightClick { barMenuItems(model) }
    }

    /// The panes, stacked; only the open one shows, flush against the bar.
    private var panes: some View {
        let edge: Alignment = model.opensDown ? .top : .bottom
        return ZStack(alignment: edge) {
            pane(.notes) {
                NotesPane(model: model, editor: notes)
                    .frame(width: AppModel.paneWidth,
                           height: model.notesView == .library ? AppModel.libraryHeight : model.notesHeight + AppModel.notesFooter)
            }
            pane(.history) { HistoryPane(model: model).frame(width: AppModel.paneWidth, height: AppModel.historyHeight) }
            pane(.settings) { SettingsPane(model: model).frame(width: AppModel.paneWidth, height: AppModel.settingsHeight) }
        }
        .frame(width: AppModel.paneWidth)
        .frame(height: max(0, model.paneHeight - AppModel.seam), alignment: edge)
        .clipped()
    }

    private var seam: some View {
        Rectangle().fill(.white.opacity(0.12))
            .frame(height: model.pane == nil ? 0 : AppModel.seam)
            .padding(.horizontal, 18)
    }

    /// Narrow strips whose line nearest the bar hangs into the bar's empty margin: not clipped, so lines fade.
    private var lines: some View {
        StatusLines(model: model).frame(height: model.linesHeight, alignment: model.opensDown ? .bottom : .top)
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

/// The lines beside the bar, whatever else is open: what the control is doing (where the words go while recording,
/// "Finishing" while the engine works through what it heard after a stop) and, in red, that memory is tight; the
/// memory line sits nearest the bar. Only labels: drags pass through them to the glass (the settings button carries
/// a red dot too).
struct StatusLines: View {
    @Bindable var model: AppModel

    var body: some View {
        let down = model.opensDown
        VStack(spacing: AppModel.lineSpacing - 15) {
            if down { memoryLine }
            if let activity = model.activity {
                HStack(spacing: 6) {
                    if model.recording {
                        Image(systemName: model.typingNow ? "keyboard" : "note.text").font(.system(size: 10, weight: .semibold))
                    } else {
                        Spinner().frame(width: 10, height: 10)
                    }
                    Text(activity).font(tiktok(12, "Medium")).lineLimit(1)
                }
                .frame(height: 15)
                .foregroundStyle(.white.opacity(0.85))
                .transition(.opacity)
            }
            if !down { memoryLine }
        }
        .padding(down ? .bottom : .top, 3)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: down ? .bottom : .top)
        .allowsHitTesting(false)
    }

    @ViewBuilder private var memoryLine: some View {
        if model.memoryWarning {
            HStack(spacing: 6) {
                Image(systemName: "memorychip").font(.system(size: 11, weight: .semibold))
                Text(memoryText).font(tiktok(12, "Medium"))
            }
            .frame(height: 15)
            .foregroundStyle(accent)
            .transition(.opacity)
        }
    }

    private var memoryText: String {
        guard let memory = model.memory else { return "Memory is low" }
        let used = Double(memory.physical - min(memory.physical, memory.available)) / 1_073_741_824
        return String(format: "Memory is low: %.1f of %.0f GB in use", used, Double(memory.physical) / 1_073_741_824)
    }
}

/// A small arc going round: work in progress.
struct Spinner: View {
    var body: some View {
        TimelineView(.animation) { context in
            Circle().trim(from: 0, to: 0.7)
                .stroke(.white.opacity(0.85), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                .rotationEffect(.degrees(360 * context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 0.9) / 0.9))
        }
    }
}

/// Moves the control's window with the pointer, for drags on the glass that no control claims; says when a drag ends.
@MainActor
final class WindowMover {
    private weak var window: NSWindow?
    private var start: (mouse: NSPoint, origin: NSPoint)?
    var onEnd: () -> Void = {}

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
        guard start != nil else { return }
        start = nil
        onEnd()
    }
}
