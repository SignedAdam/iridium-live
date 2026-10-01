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

/// Owns the control's window. The bar is the anchor: it stays where you put it (remembered across restarts) while the
/// glass opens away from it, up or, near the top of the screen, down. The window follows the glass: it grows at once
/// when the glass will grow, and shrinks only after the glass has finished shrinking, so the SwiftUI animation always
/// has room and the window never covers more of the screen than the glass needs for long.
@MainActor
final class ControlWindowController {
    private static let positionKey = "barCenter"

    let window: ControlWindow
    private let model: AppModel
    private let holder: CanvasHolder
    private var shrink: DispatchWorkItem?

    /// The whole control's opacity (applied to the window, so the blur behind the glass fades with it).
    var opacity: CGFloat {
        didSet { window.animator().alphaValue = opacity }
    }

    init(model: AppModel, notes: NotesEditor, screen: NSScreen) {
        self.model = model
        opacity = model.settings.controlOpacity
        let center = Self.savedBarCenter() ?? Self.defaultBarCenter(on: screen)
        model.opensDown = Self.opensDown(barCenter: center)
        let size = Self.windowSize(model.glassSize)
        let target = Self.frame(barCenter: center, size: size, opensDown: model.opensDown)
        window = ControlWindow(contentRect: target, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false  // the system shadow draws a dark rim around glass; the glass casts its own
        window.becomesKeyOnlyIfNeeded = true
        window.acceptsMouseMovedEvents = true
        // The SwiftUI canvas is always the size of the largest the glass can get, pinned to the window's bar side.
        // Resizing the window then only uncovers or clips the canvas: SwiftUI never lays out again for it, so the glass
        // cannot jump for a frame while the window and the layout catch up with each other.
        let mover = WindowMover(window)
        let host = FirstClickHostingView(rootView: ControlView(model: model, notes: notes, mover: mover))
        host.sizingOptions = []
        host.setFrameSize(Self.windowSize(AppModel.maxGlassSize))
        holder = CanvasHolder(canvas: host, size: size, pinTop: model.opensDown)
        window.contentView = holder
        mover.onEnd = { [weak self] in self?.settle() }
        follow()
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil,
                                               queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.recover() }
        }

        // Arrive softly: fade in while rising a few points.
        window.alphaValue = 0
        window.setFrameOrigin(NSPoint(x: target.minX, y: target.minY - 10))
        window.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.5
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            window.animator().alphaValue = opacity
            window.animator().setFrame(target, display: true)  // a window's frame animates; its origin alone does not
        }
    }

    private static func windowSize(_ glass: CGSize) -> NSSize {
        NSSize(width: glass.width + 2 * floatingMargin, height: glass.height + 2 * floatingMargin)
    }

    /// The window that puts the bar's centre at `center`, with the glass opening away from it.
    private static func frame(barCenter center: NSPoint, size: NSSize, opensDown: Bool) -> NSRect {
        let half = AppModel.barSize.height / 2 + floatingMargin
        let y = opensDown ? center.y + half - size.height : center.y - half
        return NSRect(x: (center.x - size.width / 2).rounded(), y: y.rounded(), width: size.width, height: size.height)
    }

    /// Where the bar's centre is now, on screen.
    private var barCenter: NSPoint {
        let frame = window.frame
        let half = AppModel.barSize.height / 2 + floatingMargin
        return NSPoint(x: frame.midX, y: model.opensDown ? frame.maxY - half : frame.minY + half)
    }

    /// Up, unless the glass at its tallest would not fit above the bar and there is more room below.
    private static func opensDown(barCenter center: NSPoint) -> Bool {
        guard let area = (NSScreen.screens.first { $0.frame.contains(center) } ?? NSScreen.main)?.visibleFrame else { return false }
        let reach = AppModel.maxGlassSize.height - AppModel.barSize.height + floatingMargin
        let above = area.maxY - (center.y + AppModel.barSize.height / 2)
        let below = center.y - AppModel.barSize.height / 2 - area.minY
        return above < reach && below > above
    }

    private static func defaultBarCenter(on screen: NSScreen) -> NSPoint {
        let area = screen.visibleFrame
        return NSPoint(x: area.midX, y: area.minY + 28 + AppModel.barSize.height / 2)
    }

    /// The saved position, while it is still on a screen (a display may have gone since).
    private static func savedBarCenter() -> NSPoint? {
        guard let saved = UserDefaults.standard.array(forKey: positionKey) as? [Double], saved.count == 2 else { return nil }
        let center = NSPoint(x: saved[0], y: saved[1])
        return onScreen(center) ? center : nil
    }

    private static func onScreen(_ center: NSPoint) -> Bool {
        let bar = NSRect(x: center.x - AppModel.barSize.width / 2, y: center.y - AppModel.barSize.height / 2,
                         width: AppModel.barSize.width, height: AppModel.barSize.height)
        return NSScreen.screens.contains { $0.visibleFrame.intersects(bar.insetBy(dx: 40, dy: 20)) }
    }

    /// After a drag: remember where the bar is, and open toward whichever side now has room.
    private func settle() {
        let center = barCenter
        UserDefaults.standard.set([Double(center.x), Double(center.y)], forKey: Self.positionKey)
        place(barCenter: center)
    }

    /// A display came or went: if the bar is no longer on a screen, bring it back to the default place.
    private func recover() {
        let center = barCenter
        place(barCenter: Self.onScreen(center) ? center : Self.defaultBarCenter(on: NSScreen.main ?? window.screen!))
    }

    private func place(barCenter center: NSPoint) {
        let down = Self.opensDown(barCenter: center)
        if down != model.opensDown {
            model.opensDown = down
            holder.pinTop = down
        }
        window.setFrame(Self.frame(barCenter: center, size: window.frame.size, opensDown: down), display: true)
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
        window.setFrame(Self.frame(barCenter: barCenter, size: size, opensDown: model.opensDown), display: true)
    }
}

/// Holds the SwiftUI canvas at its own size, centred and pinned to the bar's side of the window (bottom, or top when
/// the glass opens downward), whatever size the window is. (Autoresizing masks can't be trusted with this: they split
/// a width change in proportion to the margins, and once both margins are zero the whole change lands on one side and
/// the glass slides off-centre.)
final class CanvasHolder: NSView {
    private let canvas: NSView
    var pinTop: Bool {
        didSet { place() }
    }

    init(canvas: NSView, size: NSSize, pinTop: Bool) {
        self.canvas = canvas
        self.pinTop = pinTop
        super.init(frame: NSRect(origin: .zero, size: size))
        addSubview(canvas)
        place()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        place()
    }

    private func place() {
        canvas.setFrameOrigin(NSPoint(x: ((bounds.width - canvas.frame.width) / 2).rounded(),
                                      y: pinTop ? bounds.height - canvas.frame.height : 0))
    }
}
