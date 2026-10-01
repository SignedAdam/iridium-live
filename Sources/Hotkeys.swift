import AppKit

/// A key that starts and stops dictation from anywhere. Either a lone modifier (right ⌘, left ⌥, fn, …) or a key
/// with modifiers (⌥ Space).
struct Hotkey: Codable, Equatable, Identifiable {
    enum Action: String, Codable, CaseIterable { case insert, note }
    enum Mode: String, Codable, CaseIterable { case toggle, hold, both }

    var id = UUID()
    var keyCode: UInt16
    var modifiers: UInt = 0  // device-independent modifier flags, for a key with modifiers
    var keyName = ""         // what the key itself is called, for a key with modifiers
    var action = Action.insert
    var mode = Mode.both

    /// The lone-modifier keys, by key code: right and left are different keys.
    static let modifierKeys: [UInt16: (name: String, flag: NSEvent.ModifierFlags)] = [
        54: ("Right ⌘", .command), 55: ("Left ⌘", .command), 61: ("Right ⌥", .option), 58: ("Left ⌥", .option),
        60: ("Right ⇧", .shift), 56: ("Left ⇧", .shift), 62: ("Right ⌃", .control), 59: ("Left ⌃", .control),
        63: ("fn", .function),
    ]

    var isLoneModifier: Bool { Self.modifierKeys[keyCode] != nil }

    var label: String {
        if let lone = Self.modifierKeys[keyCode] { return lone.name }
        let flags = NSEvent.ModifierFlags(rawValue: modifiers)
        let symbols = [(NSEvent.ModifierFlags.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘")]
            .filter { flags.contains($0.0) }.map(\.1).joined()
        return symbols + (symbols.isEmpty ? "" : " ") + keyName
    }

    static let actionNames: [(Action, String)] = [(.insert, "Type it"), (.note, "Add to notes")]
    static let modeNames: [(Mode, String)] = [(.toggle, "Press to toggle"), (.hold, "Hold to talk"), (.both, "Hold or double-tap")]
}

/// Watches the keyboard everywhere for the hotkeys (an event tap, so key combinations are kept from the app you
/// are in; this needs Accessibility access) and turns presses into start and stop:
/// - toggle: a press starts, the next press stops;
/// - hold: recording lasts while the key is down;
/// - both: holding works like hold; two quick taps latch it on until the next press.
/// A lone modifier only counts when pressed on its own: pressing another key while it is down (⌘C) cancels it.
@MainActor
final class HotkeyMonitor {
    static let ownEvents: Int64 = 0x50484F4E  // marks the keys we type ourselves, so they never count as presses
    private static let holdThreshold = 0.3   // a press shorter than this is a tap
    private static let doubleTapWindow = 0.4

    var hotkeys: [Hotkey] = []
    var onStart: (Hotkey.Action) -> Void = { _ in }
    var onStop: () -> Void = {}
    var isRecording: () -> Bool = { false }
    /// While set, the next key pressed becomes a hotkey instead of acting as one (Esc cancels with nil).
    var onCapture: ((Hotkey?) -> Void)?
    private(set) var isListening = false

    private var tap: CFMachPort?
    private var session: UUID?        // the hotkey whose press started the current recording
    private var latched = false       // `both`: double-tapped on, until the next press
    private var down: (id: UUID, at: Date)?
    private var interrupted = false   // another key went down while a lone modifier was held
    private var tapPending: (id: UUID, at: Date)?  // `both`: a short tap that may become a double tap
    private var captureModifier: UInt16?

    /// Starts watching; false when macOS has not granted Accessibility access yet (the prompt is shown).
    @discardableResult
    func listen() -> Bool {
        guard tap == nil else { return true }
        guard AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary) else { return false }
        let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue) | (1 << CGEventType.flagsChanged.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, info in
            let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(info!).takeUnretainedValue()
            let swallow = MainActor.assumeIsolated { monitor.handle(type, event) }
            return swallow ? nil : Unmanaged.passUnretained(event)
        }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                          eventsOfInterest: CGEventMask(mask), callback: callback,
                                          userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return false }
        self.tap = tap
        CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        isListening = true
        return true
    }

    /// True when the event is one of ours to keep from the app in front.
    func handle(_ type: CGEventType, _ event: CGEvent) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return false
        }
        guard event.getIntegerValueField(.eventSourceUserData) != Self.ownEvents else { return false }
        let code = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = NSEvent.ModifierFlags(rawValue: UInt(event.flags.rawValue)).intersection([.command, .option, .shift, .control, .function])
        if onCapture != nil { return capture(type, code, flags, event) }

        if type == .flagsChanged, let lone = Hotkey.modifierKeys[code] {
            let pressed = flags.contains(lone.flag)
            guard let hotkey = hotkeys.first(where: { $0.keyCode == code }) else { return false }
            pressed ? press(hotkey) : release(hotkey)
            return false  // modifiers always reach the app: they are part of its shortcuts too
        }
        if type == .keyDown, let pressed = down, hotkeys.first(where: { $0.id == pressed.id })?.isLoneModifier == true {
            interrupted = true  // ⌘C and friends: the lone modifier was a shortcut, not a hotkey
            if session != nil, !latched { stop() }
            return false
        }
        let combo = flags.subtracting(.function)
        guard let hotkey = hotkeys.first(where: { !$0.isLoneModifier && $0.keyCode == code && $0.modifiers == combo.rawValue }) else {
            return false
        }
        if type == .keyDown {
            if event.getIntegerValueField(.keyboardEventAutorepeat) == 0 { press(hotkey) }
        } else if type == .keyUp {
            release(hotkey)
        }
        return true
    }

    private func press(_ hotkey: Hotkey) {
        down = (hotkey.id, Date())
        interrupted = false
        switch hotkey.mode {
        case .toggle:
            if !hotkey.isLoneModifier { toggle(hotkey) }  // a lone modifier toggles on release, once it is clear it was alone
        case .hold:
            if !isRecording() { start(hotkey) }
        case .both:
            if latched, session == hotkey.id {
                stop()
            } else if let pending = tapPending, pending.id == hotkey.id, Date().timeIntervalSince(pending.at) < Self.doubleTapWindow {
                tapPending = nil
                latched = true  // second tap: stays on until the next press
            } else if !isRecording() {
                start(hotkey)
            }
        }
    }

    private func release(_ hotkey: Hotkey) {
        guard let pressed = down, pressed.id == hotkey.id else { return }
        down = nil
        let held = Date().timeIntervalSince(pressed.at)
        switch hotkey.mode {
        case .toggle:
            if hotkey.isLoneModifier, !interrupted { toggle(hotkey) }
        case .hold:
            if session == hotkey.id { stop() }
        case .both:
            guard session == hotkey.id, !latched else { return }
            if held >= Self.holdThreshold || interrupted {
                stop()
            } else {
                // A short tap: on only if a second one follows quickly; otherwise it was nothing.
                let at = Date()
                tapPending = (hotkey.id, at)
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.doubleTapWindow) { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self, self.tapPending?.at == at else { return }
                        self.tapPending = nil
                        if !self.latched, self.session == hotkey.id { self.stop() }
                    }
                }
            }
        }
    }

    private func toggle(_ hotkey: Hotkey) {
        isRecording() ? stop() : start(hotkey)
    }

    private func start(_ hotkey: Hotkey) {
        session = hotkey.id
        latched = false
        onStart(hotkey.action)
    }

    private func stop() {
        session = nil
        latched = false
        tapPending = nil
        onStop()
    }

    /// The next key becomes a hotkey: a key with modifiers on key down, a lone modifier once released untouched.
    private func capture(_ type: CGEventType, _ code: UInt16, _ flags: NSEvent.ModifierFlags, _ event: CGEvent) -> Bool {
        switch type {
        case .flagsChanged where Hotkey.modifierKeys[code] != nil:
            if flags.contains(Hotkey.modifierKeys[code]!.flag) {
                captureModifier = code
            } else if captureModifier == code {
                finishCapture(Hotkey(keyCode: code))
            }
            return false
        case .keyDown:
            captureModifier = nil
            if code == 53, flags.isEmpty { finishCapture(nil); return true }  // Esc
            let name = Self.keyName(code: code, characters: NSEvent(cgEvent: event)?.charactersIgnoringModifiers ?? "?")
            finishCapture(Hotkey(keyCode: code, modifiers: flags.subtracting(.function).rawValue, keyName: name))
            return true
        default:
            return onCapture != nil
        }
    }

    private func finishCapture(_ hotkey: Hotkey?) {
        let done = onCapture
        onCapture = nil
        captureModifier = nil
        done?(hotkey)
    }

    private static func keyName(code: UInt16, characters: String) -> String {
        let named: [UInt16: String] = [49: "Space", 36: "Return", 48: "Tab", 51: "Delete", 53: "Esc", 123: "←", 124: "→",
                                       125: "↓", 126: "↑", 122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
                                       98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12"]
        return named[code] ?? characters.uppercased()
    }
}
