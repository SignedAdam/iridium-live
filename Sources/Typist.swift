import AppKit

@MainActor
protocol KeySink {
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

    @discardableResult
    func revise(to polished: String) -> Bool {
        guard isEnabled, !session.isEmpty, !disturbed, !broken, polished != session,
              typedInto == nil || frontmost() == typedInto else { return false }
        let kept = session.commonPrefix(with: polished).count
        let drop = session.count - kept
        guard drop <= Self.reach, polished.count - kept <= Self.reach else { return false }
        sink.backspace(drop)
        sink.type(String(polished.dropFirst(kept)))
        session = polished
        typed = ""
        if polished.isEmpty { owesSpace = owedAtStart }
        return true
    }
}

@MainActor
struct KeyboardSink: KeySink {
    private let source = CGEventSource(stateID: .combinedSessionState)

    static func requestAccess() -> Bool {
        AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    func backspace(_ count: Int) {
        for _ in 0..<max(count, 0) {
            for down in [true, false] { post(CGEvent(keyboardEventSource: source, virtualKey: 51, keyDown: down)) }
        }
    }

    func type(_ text: String) {
        var chunk: [UniChar] = []
        for character in text {
            let units = Array(String(character).utf16)
            if chunk.count + units.count > 20 { typeChunk(chunk); chunk = [] }
            chunk += units
        }
        if !chunk.isEmpty { typeChunk(chunk) }
    }

    private func typeChunk(_ units: [UniChar]) {
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down)
            event?.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
            post(event)
        }
    }

    private func post(_ event: CGEvent?) {
        event?.flags = []
        event?.setIntegerValueField(.eventSourceUserData, value: HotkeyMonitor.ownEvents)
        event?.post(tap: .cghidEventTap)
    }
}

