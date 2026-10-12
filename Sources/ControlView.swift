import AppKit
import SwiftUI

let floatingMargin: CGFloat = 28

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
        .background(Glass(cornerRadius: AppModel.barSize.height / 2))
        .clipShape(RoundedRectangle(cornerRadius: AppModel.barSize.height / 2, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: AppModel.barSize.height / 2, style: .continuous))
        .gesture(DragGesture(minimumDistance: 2).onChanged { _ in mover.drag() }.onEnded { _ in mover.end() })
        .overlayPreferenceValue(TipKey.self) { tips in
            TipLayer(tips: tips, bar: down ? 0...barRegion : (size.height - barRegion)...size.height, barOnTop: down)
        }
        .shadow(color: Glass.shadowColour, radius: Glass.shadowRadius, y: Glass.shadowDrop)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: down ? .top : .bottom)
        .padding(floatingMargin)
        .animation(.spring(response: 0.42, dampingFraction: 0.86), value: model.pane)
        .animation(.easeOut(duration: 0.22), value: model.notesHeight)
        .animation(.spring(response: 0.42, dampingFraction: 0.86), value: model.linesHeight)
    }

    private var bar: some View {
        ControlBar(model: model).onRightClick { barMenuItems(model) }
    }

    private var panes: some View {
        let edge: Alignment = model.opensDown ? .top : .bottom
        return ZStack(alignment: edge) {
            pane(.notes) {
                NotesPane(model: model, editor: notes)
                    .frame(width: AppModel.paneWidth,
                           height: model.notesView == .library ? AppModel.libraryHeight : model.notesHeight + AppModel.notesHeader)
            }
            pane(.meeting) { MeetingPane(model: model).frame(width: AppModel.paneWidth, height: AppModel.meetingHeight) }
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

    private var lines: some View {
        StatusLines(model: model).frame(height: model.linesHeight, alignment: model.opensDown ? .bottom : .top)
    }

    private func pane(_ which: AppModel.Pane, @ViewBuilder content: () -> some View) -> some View {
        let shown = model.pane == which
        let side: CGFloat = which.rawValue < (model.pane?.rawValue ?? which.rawValue) ? -1 : 1
        return content()
            .opacity(shown ? 1 : 0)
            .offset(x: shown || model.pane == nil ? 0 : side * 40)
            .allowsHitTesting(shown)
    }
}

struct StatusLines: View {
    @Bindable var model: AppModel

    var body: some View {
        let down = model.opensDown
        VStack(spacing: AppModel.lineSpacing - 15) {
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
        }
        .padding(down ? .bottom : .top, 3)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: down ? .bottom : .top)
        .allowsHitTesting(false)
    }
}

struct Spinner: View {
    var body: some View {
        TimelineView(.animation) { context in
            Circle().trim(from: 0, to: 0.7)
                .stroke(.white.opacity(0.85), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                .rotationEffect(.degrees(360 * context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 0.9) / 0.9))
        }
    }
}

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
        let mouse = NSEvent.mouseLocation
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

