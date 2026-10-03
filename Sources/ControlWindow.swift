import AppKit
import Observation
import SwiftUI

final class ControlWindow: NSPanel {
    override var canBecomeKey: Bool { true }
}

final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

@MainActor
final class ControlWindowController {
    private static let positionKey = "barCenter"

    let window: ControlWindow
    private let model: AppModel
    private let holder: CanvasHolder
    private var shrink: DispatchWorkItem?

    var opacity: CGFloat {
        didSet { if !model.settings.controlHidden { window.animator().alphaValue = opacity } }
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
        window.hasShadow = false
        window.becomesKeyOnlyIfNeeded = true
        window.acceptsMouseMovedEvents = true
        let mover = WindowMover(window)
        let host = FirstClickHostingView(rootView: ControlView(model: model, notes: notes, mover: mover))
        host.sizingOptions = []
        host.setFrameSize(Self.windowSize(AppModel.maxGlassSize))
        holder = CanvasHolder(canvas: host, size: size, pinTop: model.opensDown)
        window.contentView = holder
        mover.onEnd = { [weak self] in self?.settle() }
        follow()
        followLevel()
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil,
                                               queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.recover() }
        }

        window.alphaValue = 0
        guard !model.settings.controlHidden else { return }
        window.setFrameOrigin(NSPoint(x: target.minX, y: target.minY - 10))
        window.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.5
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            window.animator().alphaValue = opacity
            window.animator().setFrame(target, display: true)
        }
    }

    private func followLevel() {
        let (away, behindModels) = withObservationTracking {
            (Setup.shared.inSystemSettings || model.modelsWindowActive, model.modelsWindowActive)
        } onChange: { [weak self] in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.followLevel() } }
        }
        window.level = away ? .normal : .floating
        if behindModels, window.isVisible, let models = ModelsPanel.window {
            window.order(.below, relativeTo: models.windowNumber)
        }
    }

    func setHidden(_ hidden: Bool) {
        if hidden {
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.18
                window.animator().alphaValue = 0
            }, completionHandler: { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.model.settings.controlHidden else { return }
                    self.window.orderOut(nil)
                }
            })
        } else {
            window.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.25
                window.animator().alphaValue = opacity
            }
        }
    }

    private static func windowSize(_ glass: CGSize) -> NSSize {
        NSSize(width: glass.width + 2 * floatingMargin, height: glass.height + 2 * floatingMargin)
    }

    private static func frame(barCenter center: NSPoint, size: NSSize, opensDown: Bool) -> NSRect {
        let half = AppModel.barSize.height / 2 + floatingMargin
        let y = opensDown ? center.y + half - size.height : center.y - half
        return NSRect(x: (center.x - size.width / 2).rounded(), y: y.rounded(), width: size.width, height: size.height)
    }

    private var barCenter: NSPoint {
        let frame = window.frame
        let half = AppModel.barSize.height / 2 + floatingMargin
        return NSPoint(x: frame.midX, y: model.opensDown ? frame.maxY - half : frame.minY + half)
    }

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

    private func settle() {
        let center = barCenter
        UserDefaults.standard.set([Double(center.x), Double(center.y)], forKey: Self.positionKey)
        place(barCenter: center)
    }

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

