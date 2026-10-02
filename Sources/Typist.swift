import AppKit

/// Where keystrokes go.
@MainActor
protocol KeySink {
    func backspace(_ count: Int)
    func type(_ text: String)
}

/// Types each phrase into the focused app as it firms up. Off until switched on. Every update is the whole phrase so
/// far: only the new part is keyed in, and a later version that disagrees with what was typed is fixed with
/// backspaces. It also keeps the whole of what it typed since the recording began, so the pass over the finished
/// recording can be put in as well — but only while nothing has happened in between that our backspaces could eat.
@MainActor
final class Typist {
    /// The most that may be taken back after the fact. A sentence or two of the end is a correction; more than that
    /// is a rewrite the speaker did not ask for, and the text stands as it was typed.
    private static let reach = 400

    var isEnabled = false {
        didSet {  // switching off (or on) starts clean: nothing already typed is ever touched again
            typed = ""
            owesSpace = false
            session = ""
        }
    }
    private let sink: KeySink
    private var typed = ""         // the current phrase, as typed so far
    private var owesSpace = false  // phrases are joined by one space
    private var session = ""       // everything typed since the recording began, as it stands in the app
    private var disturbed = true   // someone else used the keyboard or the mouse since we last typed
    private var typedInto: pid_t?  // the app our keys went to
    private var watcher: Any?

    /// Which app has the keyboard, so a session typed into one app is never revised in another. Replaced in tests.
    var frontmost: () -> pid_t? = { NSWorkspace.shared.frontmostApplication?.processIdentifier }

    init(sink: KeySink) {
        self.sink = sink
        // Anything the speaker does themselves — a key, a click — may have moved the insertion point or ended the
        // line we typed, so backspaces would eat something that is not ours. Our own events carry our mark.
        watcher = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown,
                                                               .otherMouseDown]) { [weak self] event in
            MainActor.assumeIsolated {
                guard event.cgEvent?.getIntegerValueField(.eventSourceUserData) != HotkeyMonitor.ownEvents else { return }
                self?.disturbed = true
            }
        }
    }

    /// A recording started: what it types is one block, which its polished version may replace at the end.
    func startSession() {
        session = ""
        disturbed = false
    }

    /// Another keystroke or click of the speaker's own, for the tests: after one, nothing is revised.
    func interrupted() {
        disturbed = true
    }

    func sync(_ target: String, final: Bool) {
        guard isEnabled else { return }
        // A case-only change (the phrase turned out to continue a sentence) is not worth retyping.
        let kept = typed.commonPrefix(with: target, options: .caseInsensitive).count
        let added = String(target.dropFirst(kept))
        let space = typed.isEmpty && owesSpace && !added.isEmpty ? " " : ""
        sink.backspace(typed.count - kept)
        sink.type(space + added)
        session = String(session.dropLast(typed.count - kept)) + space + added
        typed = String(typed.prefix(kept)) + added
        typedInto = frontmost()
        disturbed = false
        if final {
            owesSpace = owesSpace || !typed.isEmpty
            typed = ""
        }
    }

    /// The whole recording came back polished: put the difference in, from where the two texts part company to the
    /// end, with backspaces and typing. It only happens while the text is still ours to touch — nothing typed or
    /// clicked by the speaker since, the same app still in front, and a change that reaches back no further than
    /// `reach`. Otherwise what was typed stands, which is what the speaker already read.
    @discardableResult
    func revise(to polished: String) -> Bool {
        guard isEnabled, !session.isEmpty, !disturbed, polished != session,
              typedInto == nil || frontmost() == typedInto else { return false }
        let kept = session.commonPrefix(with: polished).count
        let drop = session.count - kept
        guard drop <= Self.reach, polished.count - kept <= Self.reach else { return false }
        sink.backspace(drop)
        sink.type(String(polished.dropFirst(kept)))
        session = polished
        typed = ""
        return true
    }
}

/// Real key events, posted to whichever app has focus. Needs Accessibility access.
@MainActor
struct KeyboardSink: KeySink {
    private let source = CGEventSource(stateID: .combinedSessionState)

    /// Whether this process may post key events; asks macOS to show the Accessibility prompt when it may not.
    static func requestAccess() -> Bool {
        AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    func backspace(_ count: Int) {
        for _ in 0..<max(count, 0) {
            for down in [true, false] { post(CGEvent(keyboardEventSource: source, virtualKey: 51, keyDown: down)) }
        }
    }

    /// One key event carries at most 20 UTF-16 units, so the text goes out in whole-character chunks under that.
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
        event?.flags = []  // a held modifier must not turn the text into shortcuts
        event?.setIntegerValueField(.eventSourceUserData, value: HotkeyMonitor.ownEvents)  // never mistaken for a hotkey press
        event?.post(tap: .cghidEventTap)
    }
}
