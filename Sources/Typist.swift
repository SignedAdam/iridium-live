import AppKit

/// Where keystrokes go.
@MainActor
protocol KeySink {
    func backspace(_ count: Int)
    func type(_ text: String)
}

/// Types each phrase into the focused app as it firms up. Off until switched on. Every update is the whole phrase so
/// far: only the new part is keyed in, and a later version that disagrees with what was typed is fixed with
/// backspaces.
@MainActor
final class Typist {
    var isEnabled = false {
        didSet {  // switching off (or on) starts clean: nothing already typed is ever touched again
            typed = ""
            owesSpace = false
        }
    }
    private let sink: KeySink
    private var typed = ""         // the current phrase, as typed so far
    private var owesSpace = false  // phrases are joined by one space

    init(sink: KeySink) {
        self.sink = sink
    }

    func sync(_ target: String, final: Bool) {
        guard isEnabled else { return }
        // A case-only change (the phrase turned out to continue a sentence) is not worth retyping.
        let kept = typed.commonPrefix(with: target, options: .caseInsensitive).count
        let added = String(target.dropFirst(kept))
        sink.backspace(typed.count - kept)
        sink.type((typed.isEmpty && owesSpace && !added.isEmpty ? " " : "") + added)
        typed = String(typed.prefix(kept)) + added
        if final {
            owesSpace = owesSpace || !typed.isEmpty
            typed = ""
        }
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
