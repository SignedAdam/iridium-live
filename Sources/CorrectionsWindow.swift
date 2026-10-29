import AppKit
import SwiftUI

/// The window that shows how the cleanup model changed what was said, live and for anything in history.
@MainActor
enum CorrectionsWindow {
    private static var open: NSWindow?
    private static var keeper: CorrectionsWindowDelegate?
    static let frameName = "IridiumCorrectionsWindow"

    static func show(on screen: NSScreen, model: AppModel, select entry: HistoryEntry? = nil) {
        if let entry { CorrectionsChoice.shared.show(entry, in: model.history) }
        if let open {
            NSApp.activate(ignoringOtherApps: true)
            open.makeKeyAndOrderFront(nil)
            return
        }
        let size = NSSize(width: 1020, height: 700)
        let area = screen.visibleFrame
        let window = CorrectionsPanel(contentRect: NSRect(x: (area.midX - size.width / 2).rounded(),
                                                          y: (area.midY - size.height / 2).rounded(),
                                                          width: size.width, height: size.height),
                                      styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                                      backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.title = "Corrections"
        window.isOpaque = false
        window.isReleasedWhenClosed = false
        window.backgroundColor = .clear
        window.isMovableByWindowBackground = true
        window.appearance = NSAppearance(named: .darkAqua)
        window.minSize = NSSize(width: 820, height: 520)
        window.collectionBehavior = [.fullScreenNone]
        if !window.setFrameUsingName(frameName) { window.setFrame(window.frame, display: false) }
        window.setFrameAutosaveName(frameName)
        let host = NSHostingView(rootView: CorrectionsView(model: model))
        host.sizingOptions = []
        window.contentView = host
        let delegate = CorrectionsWindowDelegate()
        window.delegate = delegate
        keeper = delegate
        self.open = window

        let target = window.frame
        window.setFrame(target.offsetBy(dx: 0, dy: -8), display: false)
        window.alphaValue = 0
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            window.animator().alphaValue = Look.shared.opacity
            window.animator().setFrame(target, display: true)
        }
        followLook(window)
    }

    static func close() {
        open?.close()
        open?.delegate = nil
        open = nil
        keeper = nil
    }

    static func fadeOut(_ window: NSWindow) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            window.animator().alphaValue = 0
        } completionHandler: {
            MainActor.assumeIsolated { close() }
        }
    }
}

private final class CorrectionsPanel: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func cancelOperation(_ sender: Any?) {
        performClose(nil)
    }
}

private final class CorrectionsWindowDelegate: NSObject, NSWindowDelegate {
    private var leaving = false

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard !leaving else { return true }
        leaving = true
        MainActor.assumeIsolated { CorrectionsWindow.fadeOut(sender) }
        return false
    }
}
