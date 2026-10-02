import AppKit
import Observation
import SwiftUI

/// The chat app a dictation is going to, while it runs.
struct ChatTarget: Equatable {
    var bundleID: String
    var name: String
    /// Collect: the words gather in the overlay and go in as one message at the end. Otherwise they are typed as
    /// they are spoken.
    var collects: Bool
}

/// What the floating button and the overlay show.
@MainActor @Observable
final class DockState {
    var profile = ChatAppProfile()
    var recording = false
    var finishing = false
    var level = 0.0
    var elapsed = 0.0
    var live = ""       // the phrase being spoken
    var collected = ""  // the finished phrases of this recording

    /// Everything heard so far, for the overlay.
    var transcript: String {
        [collected, live].filter { !$0.isEmpty }.joined(separator: " ")
    }

    func reset() {
        recording = false
        finishing = false
        level = 0
        elapsed = 0
        live = ""
        collected = ""
    }
}

/// The chat dock: an Iridium button beside a chat app's Send button while that app is in front, and, while it is
/// recording, a panel just above the app's message box. Where both go comes from the app's profile alone, measured
/// from a corner of its window, so moving or resizing the window keeps them in place.
@MainActor
final class ChatDock {
    let apps: ChatApps
    private let model: AppModel
    private let state = DockState()
    private let buttonPanel: NSPanel
    private let overlayPanel: NSPanel
    private let watcher = WindowWatcher()
    private var current: (profile: ChatAppProfile, pid: pid_t, window: NSRect)?
    private var pressStarted: Date?
    private var elapsedTimer: Timer?
    private var delivered = true     // the recording in progress has had its text put in
    private var detected: Set<String> = []  // apps Detect has already been run on by itself
    private var boxEmpty = true  // the app's message box, last read: whether the voice button is showing
    private static let latch = 0.3   // a press shorter than this leaves the recording running

    /// While a dictation into a chat app runs and its profile says so, the screen captions would only repeat what the
    /// overlay already shows.
    var hidesCaptions: Bool {
        model.chatTarget != nil && state.profile.hideCaptions
    }

    init(model: AppModel, directory: URL) {
        self.model = model
        apps = ChatApps(directory: directory)
        buttonPanel = Self.panel(clickThrough: false)
        overlayPanel = Self.panel(clickThrough: true)

        let state = self.state
        buttonPanel.contentView = FirstClickHostingView(rootView: DockButton(state: state, press: { [weak self] in
            self?.press()
        }, release: { [weak self] in
            self?.release()
        }))
        overlayPanel.contentView = NSHostingView(rootView: DockOverlay(state: state))

        apps.onChange = { [weak self] in self?.update() }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                                                          object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.update() }
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification,
                                                          object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.update() }
        }
        update()
    }

    /// The engine's side of a dictation started from the dock.
    func handle(_ event: EngineEvent) {
        guard model.chatTarget != nil else { return }
        switch event.kind {
        case "level": state.level = event.value
        case "partial": state.live = event.text
        case "final":
            state.collected = state.collected.isEmpty ? event.text : state.collected + " " + event.text
            state.live = ""
        case "state":
            if !event.recording, state.recording {
                state.recording = false
                state.finishing = true
            }
        case "session": finish(with: event.text)
        case "work":
            // Whatever happened (a cancelled recording, or an engine without the end-of-recording pass), the dock
            // must not be left waiting: the phrases it heard are the message.
            if !event.pending { finish(with: state.collected) }
        default: break
        }
    }

    /// Opens the chat apps editor.
    func editProfiles(on screen: NSScreen) {
        ChatAppsPanel.show(apps: apps, on: screen, detect: { [weak self] bundleID in self?.detect(bundleID) ?? nil })
    }

    /// Reads a running app's window once and writes the rectangles it found into its profile. The numbers stay
    /// editable afterwards; nothing else ever moves them.
    @discardableResult func detect(_ bundleID: String) -> Detection? {
        guard let index = apps.index(of: bundleID),
              let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first,
              let detection = Detector.detect(pid: app.processIdentifier), let box = detection.box else { return nil }
        var profile = apps.apps[index]
        let window = detection.window
        profile.box = AnchoredRect.measure(box.frame, in: window, corner: .bottomLeft)
        if let send = detection.send {
            profile.sendButton = AnchoredRect.measure(send.frame, in: window, corner: .bottomRight)
            // Our button sits just outside the app's Send button, on the side with room for it.
            let size = profile.buttonStyle.cornerRadius * 2
            let gap = 8.0
            let left = send.frame.minX - gap - size
            let rect = NSRect(x: left > window.minX + 4 ? left : send.frame.maxX + gap,
                              y: send.frame.midY - size / 2, width: size, height: size)
            profile.button = AnchoredRect.measure(rect, in: window, corner: .bottomRight)
        } else {
            let size = profile.buttonStyle.cornerRadius * 2
            let rect = NSRect(x: box.frame.maxX - size - 8, y: box.frame.midY - size / 2, width: size, height: size)
            profile.button = AnchoredRect.measure(rect, in: window, corner: .bottomRight)
        }
        apps.apps[index] = profile
        return detection
    }

    // MARK: - The button

    /// The button has gone down: a dictation into this app starts, unless one is already running, which this ends.
    func press() {
        if state.recording {
            pressStarted = nil
            stop()
            return
        }
        guard let current, model.chatTarget == nil, !model.recording else { return }
        pressStarted = Date()
        delivered = false
        state.reset()
        state.recording = true
        model.chatTarget = ChatTarget(bundleID: current.profile.bundleID, name: current.profile.name,
                                      collects: current.profile.mode == .collect)
        model.startRecording(for: nil)
        elapsedTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.state.elapsed += 0.1 }
        }
        place()
    }

    /// The button has come up: a hold ends the dictation here, a quick click leaves it running.
    func release() {
        guard let started = pressStarted else { return }
        pressStarted = nil
        // A quick press latches: the recording runs on until the button is clicked again.
        if Date().timeIntervalSince(started) >= Self.latch { stop() }
    }

    private func stop() {
        elapsedTimer?.invalidate()
        elapsedTimer = nil
        state.recording = false
        state.finishing = true
        model.stopRecording()
    }

    /// The recording is over: in Collect mode the whole message goes into the app's box, and Send is pressed when the
    /// profile says so.
    private func finish(with text: String) {
        guard !delivered, let target = model.chatTarget else { return }
        delivered = true
        elapsedTimer?.invalidate()
        elapsedTimer = nil
        let profile = apps.profile(for: target.bundleID) ?? state.profile
        let message = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: target.bundleID).first,
           let window = AX.focusedWindow(of: app.processIdentifier), let frame = AX.frame(window) {
            let pid = app.processIdentifier
            let box = profile.box.resolve(in: frame)
            let send = profile.sendButton.isSet ? profile.sendButton.resolve(in: frame) : nil
            let collects = target.collects
            Task {
                let inserted = collects
                    ? await Inserter.insert(message, at: NSPoint(x: box.midX, y: box.midY), of: pid, how: profile.insertion)
                    : !message.isEmpty
                // Send is pressed only once the text is in, and a moment after: an app may show its Send button only
                // while the box holds text (WhatsApp keeps its voice button there until then).
                guard inserted, profile.autoSend else { return }
                try? await Task.sleep(for: .milliseconds(150))
                _ = Inserter.send(how: profile.send, button: send.map { NSPoint(x: $0.midX, y: $0.midY) }, of: pid)
            }
        }
        model.chatTarget = nil
        state.reset()
        update()
    }

    // MARK: - Where the dock goes

    /// The app in front decides everything: its profile, its window, and whether the dock shows at all.
    private func update() {
        guard apps.enabled, AX.trusted,
              let app = NSWorkspace.shared.frontmostApplication,
              let profile = apps.profile(for: app.bundleIdentifier), profile.enabled,
              let window = AX.focusedWindow(of: app.processIdentifier),
              let frame = AX.frame(window), frame.width > 80, frame.height > 80
        else {
            current = nil
            watcher.stop()
            hide()
            return
        }
        watcher.onChange = { [weak self] in self?.update() }
        watcher.watch(pid: app.processIdentifier, window: window)
        if !profile.isPlaced, !detected.contains(profile.bundleID) {
            // Nothing has been measured yet: read the window once, then leave the numbers alone for good.
            detected.insert(profile.bundleID)
            if detect(profile.bundleID) != nil { return }  // the saved profile change comes straight back here
        }
        current = (profile, app.processIdentifier, frame)
        // While a dictation runs the look stays the one it started with, whatever is being edited elsewhere.
        if !state.recording, !state.finishing { state.profile = profile }
        place()
    }

    private func place() {
        guard let current, current.profile.isPlaced else { hide(); return }
        let window = current.window
        let button = pixels(buttonFrame(current))
        if buttonPanel.frame != button { buttonPanel.setFrame(button, display: true) }
        if !buttonPanel.isVisible { buttonPanel.orderFrontRegardless() }

        let showsOverlay = state.recording || state.finishing
        if showsOverlay {
            let box = current.profile.box.resolve(in: window)
            let style = current.profile.overlayStyle
            let width = style.width > 0 ? style.width : box.width
            let rect = pixels(NSRect(x: box.minX, y: box.maxY + style.gap, width: width, height: style.height))
            overlayPanel.setFrame(rect, display: true)
            if !overlayPanel.isVisible { overlayPanel.orderFrontRegardless() }
        } else if overlayPanel.isVisible {
            overlayPanel.orderOut(nil)
        }
    }

    /// Where the button goes: its own place, or, with "Over the app's voice button", centred on that button while the
    /// message box is empty. Once the box holds text the app shows Send there instead, and the button steps back to
    /// its own place so Send stays in reach. The box is read between drags only: what it holds cannot change mid-drag.
    private func buttonFrame(_ current: (profile: ChatAppProfile, pid: pid_t, window: NSRect)) -> NSRect {
        let own = current.profile.button.resolve(in: current.window)
        guard current.profile.overVoiceButton, current.profile.sendButton.isSet else { return own }
        if !watcher.dragging {
            let box = current.profile.box.resolve(in: current.window)
            boxEmpty = Inserter.box(at: NSPoint(x: box.midX, y: box.midY), of: current.pid).map { element in
                (AX.attribute(element, kAXNumberOfCharactersAttribute as String) as? Int).map { $0 == 0 } ?? true
            } ?? true
        }
        guard boxEmpty else { return own }
        let voice = current.profile.sendButton.resolve(in: current.window)
        return NSRect(x: voice.midX - own.width / 2, y: voice.midY - own.height / 2, width: own.width, height: own.height)
    }

    private func hide() {
        if buttonPanel.isVisible { buttonPanel.orderOut(nil) }
        if overlayPanel.isVisible { overlayPanel.orderOut(nil) }
    }

    /// A frame snapped to whole pixels on the screen it lands on, so edges and symbols stay crisp at any scale.
    private func pixels(_ rect: NSRect) -> NSRect {
        let screen = NSScreen.screens.first { $0.frame.intersects(rect) } ?? NSScreen.main
        let scale = screen?.backingScaleFactor ?? 2
        func snap(_ value: CGFloat) -> CGFloat { (value * scale).rounded() / scale }
        return NSRect(x: snap(rect.minX), y: snap(rect.minY), width: snap(rect.width), height: snap(rect.height))
    }

    private static func panel(clickThrough: Bool) -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered,
                            defer: false)
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = clickThrough
        return panel
    }
}
