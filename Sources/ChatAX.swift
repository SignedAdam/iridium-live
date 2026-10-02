import AppKit
import ApplicationServices

/// Reading and driving another app through accessibility: window frames, finding its message box and Send button,
/// putting text in and pressing Send.
///
/// Accessibility reports geometry in points with the origin at the top left of the main screen, y downward; AppKit
/// uses the bottom left of the same screen, y upward. Everything here converts at the edge and works in AppKit points
/// from then on, so a display running "More space" or "Larger text" needs no special case: points are points, and the
/// windows we draw pick up each screen's backing scale themselves.
@MainActor
enum AX {
    /// The flip line: the top of the screen the global origin is measured from.
    static var originTop: CGFloat { NSScreen.screens.first?.frame.maxY ?? 0 }

    static func appKit(_ rect: CGRect) -> NSRect {
        NSRect(x: rect.minX, y: originTop - rect.maxY, width: rect.width, height: rect.height)
    }

    static func accessibility(_ point: NSPoint) -> CGPoint {
        CGPoint(x: point.x, y: originTop - point.y)
    }

    static var trusted: Bool { AXIsProcessTrusted() }

    static func attribute(_ element: AXUIElement, _ name: String) -> AnyObject? {
        var value: AnyObject?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }

    static func string(_ element: AXUIElement, _ name: String) -> String? {
        attribute(element, name) as? String
    }

    static func children(_ element: AXUIElement) -> [AXUIElement] {
        (attribute(element, kAXChildrenAttribute as String) as? [AXUIElement]) ?? []
    }

    static func role(_ element: AXUIElement) -> String {
        string(element, kAXRoleAttribute as String) ?? ""
    }

    /// An element's frame in AppKit screen points.
    static func frame(_ element: AXUIElement) -> NSRect? {
        guard let positionValue = attribute(element, kAXPositionAttribute as String),
              let sizeValue = attribute(element, kAXSizeAttribute as String) else { return nil }
        var origin = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &origin),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size) else { return nil }
        return appKit(CGRect(origin: origin, size: size))
    }

    static func application(_ pid: pid_t) -> AXUIElement {
        AXUIElementCreateApplication(pid)
    }

    /// The window the app is working in: its focused window, or its main one.
    static func focusedWindow(of pid: pid_t) -> AXUIElement? {
        let app = application(pid)
        for name in [kAXFocusedWindowAttribute, kAXMainWindowAttribute] {
            if let value = attribute(app, name as String), CFGetTypeID(value) == AXUIElementGetTypeID() {
                let window = value as! AXUIElement
                if attribute(window, kAXMinimizedAttribute as String) as? Bool != true { return window }
            }
        }
        return nil
    }

    /// The deepest element of `pid` under a point on screen.
    static func element(at point: NSPoint, of pid: pid_t) -> AXUIElement? {
        let spot = accessibility(point)
        var found: AXUIElement?
        guard AXUIElementCopyElementAtPosition(application(pid), Float(spot.x), Float(spot.y), &found) == .success else {
            return nil
        }
        return found
    }

    /// Walks up from `element` to the first ancestor whose role is one of `roles`, `element` included.
    static func ancestor(of element: AXUIElement, roles: Set<String>, levels: Int = 6) -> AXUIElement? {
        var current = element
        for _ in 0...levels {
            if roles.contains(role(current)) { return current }
            guard let parent = attribute(current, kAXParentAttribute as String),
                  CFGetTypeID(parent) == AXUIElementGetTypeID() else { return nil }
            current = parent as! AXUIElement
        }
        return nil
    }

    static let textRoles: Set<String> = [kAXTextAreaRole as String, kAXTextFieldRole as String,
                                         kAXComboBoxRole as String]
    static let buttonRoles: Set<String> = [kAXButtonRole as String, kAXMenuButtonRole as String,
                                           kAXRadioButtonRole as String]
}

/// One element of an app's accessibility tree, as Detect sees it.
struct AXNode {
    var role = ""
    var subrole = ""
    var identifier = ""
    var label = ""   // title, description or help: what the control calls itself
    var frame = NSRect.zero
    var depth = 0
}

/// What Detect made of an app's window.
struct Detection {
    var window = NSRect.zero
    var box: AXNode?
    var send: AXNode?
}

@MainActor
enum Detector {
    private static let maxNodes = 4000
    private static let maxDepth = 24

    /// Reads the app's focused window once and picks out the message box (the largest text area low in the window)
    /// and the Send button: one called "send", else the button sitting just past the end of the box, level with it.
    /// Apps that only show Send once something is typed (WhatsApp keeps a voice-message button there meanwhile) give
    /// the right place all the same, because the button is found again by position when a message is sent.
    static func detect(pid: pid_t) -> Detection? {
        guard let window = AX.focusedWindow(of: pid), let frame = AX.frame(window), frame.width > 1 else { return nil }
        var result = Detection(window: frame)
        let nodes = walk(window)
        let texts = nodes.filter { AX.textRoles.contains($0.role) && $0.frame.width > 40 && $0.frame.height > 10 }
        // The composer is the widest text area in the bottom half of the window; a chat app only has one down there.
        let low = texts.filter { $0.frame.midY < frame.midY }
        result.box = (low.isEmpty ? texts : low).max { area($0) < area($1) }
        if let box = result.box {
            let buttons = nodes.filter { AX.buttonRoles.contains($0.role) && $0.frame.width > 8 }
            let band = max(box.frame.height, 30)
            let level = buttons.filter { abs($0.frame.midY - box.frame.midY) <= band }
            let named = level.filter { $0.label.localizedCaseInsensitiveContains("send")
                || $0.identifier.localizedCaseInsensitiveContains("send") }
            let past = level.filter { $0.frame.minX >= box.frame.maxX - 4 }
            result.send = named.min { $0.frame.minX < $1.frame.minX } ?? past.min { $0.frame.minX < $1.frame.minX }
        }
        return result
    }

    private static func area(_ node: AXNode) -> CGFloat { node.frame.width * node.frame.height }

    /// Every element of the window, breadth first, with a cap so a deep tree cannot stall the app.
    private static func walk(_ root: AXUIElement) -> [AXNode] {
        var nodes: [AXNode] = []
        var queue: [(AXUIElement, Int)] = [(root, 0)]
        while !queue.isEmpty, nodes.count < maxNodes {
            let (element, depth) = queue.removeFirst()
            let node = AXNode(role: AX.role(element),
                              subrole: AX.string(element, kAXSubroleAttribute as String) ?? "",
                              identifier: AX.string(element, kAXIdentifierAttribute as String) ?? "",
                              label: AX.string(element, kAXTitleAttribute as String)
                                  ?? AX.string(element, kAXDescriptionAttribute as String)
                                  ?? AX.string(element, kAXHelpAttribute as String) ?? "",
                              frame: AX.frame(element) ?? .zero,
                              depth: depth)
            nodes.append(node)
            guard depth < maxDepth else { continue }
            for child in AX.children(element) { queue.append((child, depth + 1)) }
        }
        return nodes
    }
}

/// Putting the finished text into an app's message box and sending it.
@MainActor
enum Inserter {
    /// Text goes in through accessibility where the box takes a written selection: the box is focused, then the text
    /// replaces the (empty) selection at the cursor, keeping whatever was already typed. Every other box gets the
    /// pasteboard, which every app understands. (A box's whole value written through accessibility can look accepted
    /// yet never reach the app: WhatsApp's composer stays empty and keeps its voice button where Send would be.)
    /// True once the box really holds the text; false when it never came to, after a second and a half at most.
    static func insert(_ text: String, at centre: NSPoint, of pid: pid_t, how: ChatAppProfile.Insertion) async -> Bool {
        guard !text.isEmpty, let box = box(at: centre, of: pid) else { return false }
        if how == .accessibility, write(text, into: box) { return true }
        return await paste(text, into: box)
    }

    /// The message box under a point: the text area itself, or the nearest one around what is there.
    static func box(at centre: NSPoint, of pid: pid_t) -> AXUIElement? {
        guard let hit = AX.element(at: centre, of: pid) else { return nil }
        return AX.ancestor(of: hit, roles: AX.textRoles) ?? hit
    }

    /// Focuses the box and writes the text at its cursor; true when the box really took it.
    static func write(_ text: String, into box: AXUIElement) -> Bool {
        var settable: DarwinBoolean = false
        guard AXUIElementIsAttributeSettable(box, kAXSelectedTextAttribute as CFString, &settable) == .success,
              settable.boolValue else { return false }
        AXUIElementSetAttributeValue(box, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        let before = AX.string(box, kAXValueAttribute as String) ?? ""
        return AXUIElementSetAttributeValue(box, kAXSelectedTextAttribute as CFString, text as CFString) == .success
            && AX.string(box, kAXValueAttribute as String) != before
    }

    /// The text on the pasteboard and ⌘V to the app; the clipboard is put back once the app has taken the text (or
    /// given up on it), never before, so the paste cannot pick up the old clipboard instead.
    private static func paste(_ text: String, into box: AXUIElement) async -> Bool {
        AXUIElementSetAttributeValue(box, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        let before = AX.string(box, kAXValueAttribute as String) ?? ""
        let pasteboard = NSPasteboard.general
        let saved = pasteboard.pasteboardItems?.compactMap { item -> [NSPasteboard.PasteboardType: Data] in
            Dictionary(uniqueKeysWithValues: item.types.compactMap { type in item.data(forType: type).map { (type, $0) } })
        } ?? []
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        let source = CGEventSource(stateID: .combinedSessionState)
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: down)  // V
            event?.flags = .maskCommand
            event?.setIntegerValueField(.eventSourceUserData, value: HotkeyMonitor.ownEvents)
            event?.post(tap: .cghidEventTap)
        }
        let landed = await changes(box, from: before, within: .milliseconds(1500))
        pasteboard.clearContents()
        for contents in saved {
            let item = NSPasteboardItem()
            for (type, data) in contents { item.setData(data, forType: type) }
            pasteboard.writeObjects([item])
        }
        return landed
    }

    /// True as soon as the box reads something other than `before`; false when `limit` passes first. A box that
    /// cannot be read counts as unchanged.
    static func changes(_ box: AXUIElement, from before: String, within limit: Duration) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now + limit
        while (AX.string(box, kAXValueAttribute as String) ?? before) == before {
            guard clock.now < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return true
    }

    /// Sends what is in the box: the app's own Send button pressed through accessibility, or Return into it.
    static func send(how: ChatAppProfile.Send, button centre: NSPoint?, of pid: pid_t) -> Bool {
        if how == .press, let centre, let hit = AX.element(at: centre, of: pid),
           let button = AX.ancestor(of: hit, roles: AX.buttonRoles) ?? (AX.role(hit).isEmpty ? nil : hit) {
            return AXUIElementPerformAction(button, kAXPressAction as CFString) == .success
        }
        let source = CGEventSource(stateID: .combinedSessionState)
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: 36, keyDown: down)  // Return
            event?.flags = []
            event?.setIntegerValueField(.eventSourceUserData, value: HotkeyMonitor.ownEvents)
            event?.post(tap: .cghidEventTap)
        }
        return true
    }
}

/// Watches one app's windows so the dock can follow them: moves, resizes, minimising, the focused window changing and
/// the app hiding all come back as one call to `onChange`. A slow tick covers apps that stay quiet during a live drag.
@MainActor
final class WindowWatcher {
    var onChange: () -> Void = {}
    private var observer: AXObserver?
    private var application: AXUIElement?
    private var window: AXUIElement?
    private var ticker: Timer?

    private static let applicationNotifications = [kAXFocusedWindowChangedNotification, kAXMainWindowChangedNotification,
                                                   kAXApplicationHiddenNotification, kAXApplicationShownNotification,
                                                   kAXFocusedUIElementChangedNotification]
    private static let windowNotifications = [kAXMovedNotification, kAXResizedNotification,
                                              kAXWindowMiniaturizedNotification, kAXWindowDeminiaturizedNotification,
                                              kAXUIElementDestroyedNotification]

    /// Starts over on `pid`, watching its app element and its focused window.
    func watch(pid: pid_t, window: AXUIElement?) {
        if observer == nil || self.pid != pid {
            stop()
            self.pid = pid
            var made: AXObserver?
            guard AXObserverCreate(pid, { _, _, _, refcon in
                guard let refcon else { return }
                MainActor.assumeIsolated { Unmanaged<WindowWatcher>.fromOpaque(refcon).takeUnretainedValue().onChange() }
            }, &made) == .success, let made else { return }
            observer = made
            application = AX.application(pid)
            CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(made), .defaultMode)
            for name in Self.applicationNotifications { add(name, to: application) }
        }
        if let window, self.window == nil || !CFEqual(self.window, window) {
            for name in Self.windowNotifications { remove(name, from: self.window) }
            self.window = window
            for name in Self.windowNotifications { add(name, to: window) }
        }
        if ticker == nil {
            ticker = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { _ in
                MainActor.assumeIsolated { self.onChange() }
            }
        }
    }

    func stop() {
        ticker?.invalidate()
        ticker = nil
        if let observer {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        }
        observer = nil
        application = nil
        window = nil
        pid = nil
    }

    private var pid: pid_t?

    private func add(_ name: String, to element: AXUIElement?) {
        guard let observer, let element else { return }
        AXObserverAddNotification(observer, element, name as CFString, Unmanaged.passUnretained(self).toOpaque())
    }

    private func remove(_ name: String, from element: AXUIElement?) {
        guard let observer, let element else { return }
        AXObserverRemoveNotification(observer, element, name as CFString)
    }
}
