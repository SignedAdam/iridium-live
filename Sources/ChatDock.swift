import AppKit
import Observation
import SwiftUI

struct ChatTarget: Equatable {
    var bundleID: String
    var name: String
    var collects: Bool
}

@MainActor @Observable
final class DockState {
    var profile = ChatAppProfile()
    var recording = false
    var finishing = false
    var level = 0.0
    var elapsed = 0.0
    var live = ""
    var collected = ""
    var attached = false
    var ready = false

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

struct ChatPane {
    var left: CGFloat
    var right: CGFloat
    var rowTop: CGFloat
}

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
    private var delivered = true
    private var detected: Set<String> = []
    private var boxEmpty = true
    private var pane: (pid: pid_t, insets: ChatPane)?
    private static let latch = 0.3

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

    func handle(_ event: EngineEvent) {
        if event.kind == "ready" { state.ready = true }
        guard model.chatTarget != nil else { return }
        switch event.kind {
        case "level": state.level = event.value
        case "partial": state.live = event.text
        case "final":
            if let edit = event.edit { state.collected = edit.text }
            if !event.text.isEmpty {
                state.collected = state.collected.isEmpty ? event.text : state.collected + " " + event.text
            }
            state.live = ""
        case "state":
            if !event.recording, state.recording {
                state.recording = false
                state.finishing = true
            }
        case "session": finish(with: event.text)
        case "work":
            if !event.pending { finish(with: state.collected) }
        default: break
        }
    }

    func editProfiles(on screen: NSScreen) {
        ChatAppsPanel.show(apps: apps, on: screen, detect: { [weak self] bundleID in self?.detect(bundleID) ?? nil })
    }

    @discardableResult func detect(_ bundleID: String) -> Detection? {
        guard let index = apps.index(of: bundleID),
              let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first,
              let detection = Detector.detect(pid: app.processIdentifier), let box = detection.box else { return nil }
        var profile = apps.apps[index]
        let window = detection.window
        profile.box = AnchoredRect.measure(box.frame, in: window, corner: .bottomLeft)
        if let send = detection.send {
            profile.sendButton = AnchoredRect.measure(send.frame, in: window, corner: .bottomRight)
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

    func press() {
        if state.recording {
            pressStarted = nil
            stop()
            return
        }
        guard let current, model.ready, model.chatTarget == nil, !model.recording else { return }
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

    func release() {
        guard let started = pressStarted else { return }
        pressStarted = nil
        if Date().timeIntervalSince(started) >= Self.latch { stop() }
    }

    private func stop() {
        elapsedTimer?.invalidate()
        elapsedTimer = nil
        state.recording = false
        state.finishing = true
        model.stopRecording()
    }

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
                guard inserted, profile.autoSend else { return }
                try? await Task.sleep(for: .milliseconds(150))
                _ = Inserter.send(how: profile.send, button: send.map { NSPoint(x: $0.midX, y: $0.midY) }, of: pid)
            }
        }
        model.chatTarget = nil
        state.reset()
        update()
    }

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
            detected.insert(profile.bundleID)
            if detect(profile.bundleID) != nil { return }
        }
        current = (profile, app.processIdentifier, frame)
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
            let style = current.profile.overlayStyle
            if style.attached, !watcher.dragging { pane = Self.readPane(current).map { (current.pid, $0) } }
            let across = style.attached ? pane.flatMap { $0.pid == current.pid ? $0.insets : nil } : nil
            if state.attached != (across != nil) { state.attached = across != nil }
            let rect: NSRect
            if let across {
                let left = window.minX + across.left
                rect = NSRect(x: left, y: window.minY + across.rowTop + style.gap,
                              width: window.maxX - across.right - left, height: style.height)
            } else {
                let box = current.profile.box.resolve(in: window)
                let width = style.width > 0 ? style.width : box.width
                rect = NSRect(x: box.minX, y: box.maxY + style.gap, width: width, height: style.height)
            }
            let snapped = pixels(rect)
            if overlayPanel.frame != snapped { overlayPanel.setFrame(snapped, display: true) }
            if !overlayPanel.isVisible { overlayPanel.orderFrontRegardless() }
        } else if overlayPanel.isVisible {
            overlayPanel.orderOut(nil)
        }
    }

    private static func readPane(_ current: (profile: ChatAppProfile, pid: pid_t, window: NSRect)) -> ChatPane? {
        let window = current.window
        let box = current.profile.box.resolve(in: window)
        guard let field = Inserter.box(at: NSPoint(x: box.midX, y: box.midY), of: current.pid),
              AX.textRoles.contains(AX.role(field)), let fieldFrame = AX.frame(field),
              let parent = AX.attribute(field, kAXParentAttribute as String), CFGetTypeID(parent) == AXUIElementGetTypeID()
        else { return nil }
        let container = parent as! AXUIElement
        guard let frame = AX.frame(container), frame.width > fieldFrame.width + 40 else { return nil }
        let row = AX.children(container).compactMap { AX.frame($0) }
            .filter { $0.height < frame.height / 2 && $0.minY < fieldFrame.maxY && $0.maxY > fieldFrame.minY }
        let rowTop = row.map(\.maxY).max() ?? fieldFrame.maxY
        return ChatPane(left: frame.minX - window.minX, right: window.maxX - frame.maxX, rowTop: rowTop - window.minY)
    }

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

