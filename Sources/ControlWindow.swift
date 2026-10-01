import AppKit
import Observation
import SwiftUI

/// The control's window: borderless, floating on every Space, never activating the app. It may take the keyboard,
/// but only when a click needs it (the notes text).
final class ControlWindow: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// Hosts SwiftUI so that controls answer the first click even though the window is never key.
final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Owns the control's window. The window keeps its bottom centre fixed and follows the glass: it grows at once when
/// the glass will grow, and shrinks only after the glass has finished shrinking, so the SwiftUI animation always has
/// room and the window never covers more of the screen than the glass needs for long.
@MainActor
final class ControlWindowController {
    let window: ControlWindow
    private let model: AppModel
    private var shrink: DispatchWorkItem?

    /// The whole control's opacity (applied to the window, so the blur behind the glass fades with it).
    var opacity: CGFloat {
        didSet { window.animator().alphaValue = opacity }
    }

    init(model: AppModel, notes: NotesEditor, screen: NSScreen) {
        self.model = model
        opacity = model.settings.controlOpacity
        let size = Self.windowSize(model.glassSize)
        let area = screen.visibleFrame
        let origin = NSPoint(x: (area.midX - size.width / 2).rounded(), y: area.minY + 28 - floatingMargin)
        window = ControlWindow(contentRect: NSRect(origin: origin, size: size), styleMask: [.borderless, .nonactivatingPanel],
                               backing: .buffered, defer: false)
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false  // the system shadow draws a dark rim around glass; the glass casts its own
        window.becomesKeyOnlyIfNeeded = true
        window.acceptsMouseMovedEvents = true
        // The SwiftUI canvas is always the size of the largest the glass can get, pinned bottom-centre in the window.
        // Resizing the window then only uncovers or clips the canvas: SwiftUI never lays out again for it, so the glass
        // cannot jump for a frame while the window and the layout catch up with each other.
        let host = FirstClickHostingView(rootView: ControlView(model: model, notes: notes, mover: WindowMover(window)))
        host.sizingOptions = []
        host.setFrameSize(Self.windowSize(AppModel.maxGlassSize))
        window.contentView = CanvasHolder(canvas: host, size: size)
        follow()

        // Arrive softly: fade in while rising a few points.
        window.alphaValue = 0
        window.setFrameOrigin(NSPoint(x: origin.x, y: origin.y - 10))
        window.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.5
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            window.animator().alphaValue = opacity
            window.animator().setFrameOrigin(origin)
        }
    }

    private static func windowSize(_ glass: CGSize) -> NSSize {
        NSSize(width: glass.width + 2 * floatingMargin, height: glass.height + 2 * floatingMargin)
    }

    private func follow() {
        withObservationTracking { _ = model.glassSize } onChange: { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.fit()
                    self?.follow()
                }
            }
        }
    }

    private func fit() {
        let wanted = Self.windowSize(model.glassSize)
        let current = window.frame.size
        shrink?.cancel()
        resize(to: NSSize(width: max(current.width, wanted.width), height: max(current.height, wanted.height)))
        guard wanted != window.frame.size else { return }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.resize(to: wanted) }
        }
        shrink = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7, execute: work)
    }

    private func resize(to size: NSSize) {
        let frame = window.frame
        window.setFrame(NSRect(x: (frame.midX - size.width / 2).rounded(), y: frame.minY, width: size.width, height: size.height),
                        display: true)
    }
}

/// Holds the SwiftUI canvas at its own size, bottom-centred, whatever size the window is. (Autoresizing masks can't
/// be trusted with this: they split a width change in proportion to the margins, and once both margins are zero the
/// whole change lands on one side and the glass slides off-centre.)
final class CanvasHolder: NSView {
    private let canvas: NSView

    init(canvas: NSView, size: NSSize) {
        self.canvas = canvas
        super.init(frame: NSRect(origin: .zero, size: size))
        addSubview(canvas)
        place()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        place()
    }

    private func place() {
        canvas.setFrameOrigin(NSPoint(x: ((bounds.width - canvas.frame.width) / 2).rounded(), y: 0))
    }
}
