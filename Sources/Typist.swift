import AppKit

@MainActor
protocol KeySink: AnyObject {
    /// Called when keys still waiting were thrown away (the app in front changed before they could be sent).
    var onDropped: () -> Void { get set }
    func backspace(_ count: Int)
    func type(_ text: String)
}

@MainActor
final class Typist {
    private static let reach = 400

    var isEnabled = false {
        didSet {
            typed = ""
            owesSpace = false
            session = ""
        }
    }
    private let sink: KeySink
    private var typed = ""
    private var owesSpace = false
    private var owedAtStart = false
    private var session = ""
    private var disturbed = true
    private var broken = false
    private var typedInto: pid_t?
    private var watcher: Any?

    var frontmost: () -> pid_t? = { NSWorkspace.shared.frontmostApplication?.processIdentifier }

    init(sink: KeySink) {
        self.sink = sink
        watcher = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown,
                                                               .otherMouseDown]) { [weak self] event in
            MainActor.assumeIsolated {
                guard event.cgEvent?.getIntegerValueField(.eventSourceUserData) != HotkeyMonitor.ownEvents else { return }
                self?.disturbed = true
            }
        }
        sink.onDropped = { [weak self] in
            self?.typed = ""
            self?.broken = true
        }
    }

    func startSession() {
        session = ""
        disturbed = false
        broken = false
        owedAtStart = owesSpace
    }

    func interrupted() {
        disturbed = true
    }

    func sync(_ target: String, final: Bool) {
        guard isEnabled else { return }
        let kept = typed.commonPrefix(with: target, options: .caseInsensitive).count
        let added = String(target.dropFirst(kept))
        let space = typed.isEmpty && owesSpace && !added.isEmpty ? " " : ""
        sink.backspace(typed.count - kept)
        sink.type(space + added)
        session = String(session.dropLast(typed.count - kept)) + space + added
        typed = String(typed.prefix(kept)) + added
        typedInto = frontmost()
        if disturbed, session.count > space.count + added.count { broken = true }
        disturbed = false
        if final {
            owesSpace = owesSpace || !typed.isEmpty
            typed = ""
        }
    }

    /// Replaces what this recording typed with `polished`, from the first character that differs. The space owed to
    /// the text before the recording stays in front.
    @discardableResult
    func revise(to polished: String) -> Bool {
        let target = session.hasPrefix(" ") && !polished.isEmpty ? " " + polished : polished
        guard isEnabled, !session.isEmpty, !disturbed, !broken, target != session,
              typedInto == nil || frontmost() == typedInto else { return false }
        let kept = session.commonPrefix(with: target).count
        let drop = session.count - kept
        guard drop <= Self.reach, target.count - kept <= Self.reach else { return false }
        sink.backspace(drop)
        sink.type(String(target.dropFirst(kept)))
        session = target
        typed = ""
        if polished.isEmpty { owesSpace = owedAtStart }
        return true
    }
}

/// Types by posting key events, one key at a time and a frame apart: a text field drawn by a web page that redraws
/// after every change loses keys that arrive while it is still busy with the last one. Keys only ever reach the app
/// that was in front when they were asked for; if another app comes to the front first, the rest are dropped.
@MainActor
final class KeyboardSink: KeySink {
    private static let gap = Duration.milliseconds(20)
    private static let chunk = 20 // UTF-16 units one key event carries

    private enum Key {
        case backspace
        case text([UniChar])
    }

    var onDropped: () -> Void = {}
    private let source = CGEventSource(stateID: .combinedSessionState)
    private var waiting: [(key: Key, app: pid_t?)] = []
    private var sending = false

    static func requestAccess() -> Bool {
        AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    func backspace(_ count: Int) {
        send(Array(repeating: .backspace, count: max(count, 0)))
    }

    func type(_ text: String) {
        var keys: [Key] = []
        var units: [UniChar] = []
        for character in text {
            let next = Array(String(character).utf16)
            if units.count + next.count > Self.chunk { keys.append(.text(units)); units = [] }
            units += next
        }
        if !units.isEmpty { keys.append(.text(units)) }
        send(keys)
    }

    private func send(_ keys: [Key]) {
        guard !keys.isEmpty else { return }
        let app = Self.frontmost()
        waiting += keys.map { ($0, app) }
        guard !sending else { return }
        sending = true
        Task { await drain() }
    }

    private func drain() async {
        let activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .latencyCritical], reason: "Typing")
        defer {
            ProcessInfo.processInfo.endActivity(activity)
            sending = false
        }
        while !waiting.isEmpty {
            let (key, app) = waiting.removeFirst()
            guard app == nil || Self.frontmost() == app else {
                waiting.removeAll()
                onDropped()
                return
            }
            post(key)
            try? await Task.sleep(for: Self.gap)
        }
    }

    private func post(_ key: Key) {
        for down in [true, false] {
            let event: CGEvent?
            switch key {
            case .backspace:
                event = CGEvent(keyboardEventSource: source, virtualKey: 51, keyDown: down)
            case .text(let units):
                event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down)
                event?.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
            }
            event?.flags = []
            event?.setIntegerValueField(.eventSourceUserData, value: HotkeyMonitor.ownEvents)
            event?.post(tap: .cghidEventTap)
        }
    }

    private static func frontmost() -> pid_t? {
        NSWorkspace.shared.frontmostApplication?.processIdentifier
    }
}

