import AppKit

/// One way of starting dictation from anywhere: a key (a lone modifier such as right ⌘, or a key with modifiers such
/// as ⌥ Space), the gesture that works it, and what the words are for. Several hotkeys may share one key as long as
/// their gestures differ, so the same key can type while held and keep notes when double-tapped.
struct Hotkey: Codable, Equatable, Identifiable {
    enum Action: String, Codable, CaseIterable { case insert, note }
    enum Gesture: String, Codable, CaseIterable { case hold, doubleTap, press }

    /// A key as the recogniser sees it: the same key code and modifiers are the same key, whatever the gestures on it.
    struct Key: Hashable {
        var keyCode: UInt16
        var modifiers: UInt
    }

    var id = UUID()
    var keyCode: UInt16
    var modifiers: UInt = 0  // device-independent modifier flags, for a key with modifiers
    var keyName = ""         // what the key itself is called, for a key with modifiers
    var gesture = Gesture.hold
    var action = Action.insert
    var enabled = true

    /// The lone-modifier keys, by key code: right and left are different keys.
    static let modifierKeys: [UInt16: (name: String, flag: NSEvent.ModifierFlags)] = [
        54: ("Right ⌘", .command), 55: ("Left ⌘", .command), 61: ("Right ⌥", .option), 58: ("Left ⌥", .option),
        60: ("Right ⇧", .shift), 56: ("Left ⇧", .shift), 62: ("Right ⌃", .control), 59: ("Left ⌃", .control),
        63: ("fn", .function),
    ]

    var isLoneModifier: Bool { Self.modifierKeys[keyCode] != nil }

    var key: Key { Key(keyCode: keyCode, modifiers: isLoneModifier ? 0 : modifiers) }

    var label: String {
        if let lone = Self.modifierKeys[keyCode] { return lone.name }
        let flags = NSEvent.ModifierFlags(rawValue: modifiers)
        let symbols = [(NSEvent.ModifierFlags.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘")]
            .filter { flags.contains($0.0) }.map(\.1).joined()
        return symbols + (symbols.isEmpty ? "" : " ") + keyName
    }

    static let actionNames: [(Action, String)] = [(.insert, "Type it"), (.note, "Add to notes")]
    static let gestureNames: [(Gesture, String)] = [(.hold, "Hold"), (.doubleTap, "Double-tap"), (.press, "Toggle")]

    /// The hotkeys that cannot be told apart: an enabled binding whose key and gesture another enabled binding
    /// already claimed. The first one wins, the later ones are these and do nothing.
    static func conflicting(in hotkeys: [Hotkey]) -> Set<UUID> {
        var taken: [Key: Set<Gesture>] = [:]
        var losers = Set<UUID>()
        for hotkey in hotkeys where hotkey.enabled {
            if taken[hotkey.key, default: []].insert(hotkey.gesture).inserted == false { losers.insert(hotkey.id) }
        }
        return losers
    }

    /// The press bindings that have to wait out the double-tap window before they act, because an enabled double-tap
    /// binding shares their key and a first tap may still turn into a second one.
    static func waitingForDoubleTap(in hotkeys: [Hotkey]) -> Set<UUID> {
        let doubled = Set(hotkeys.filter { $0.enabled && $0.gesture == .doubleTap }.map(\.key))
        return Set(hotkeys.filter { $0.enabled && $0.gesture == .press && doubled.contains($0.key) }.map(\.id))
    }
}

/// The hotkeys as they come out of a save, the older shape included: a binding used to carry a `mode` instead of a
/// gesture, and `both` meant two gestures on one key, so it becomes two bindings.
struct SavedHotkeys: Decodable {
    let hotkeys: [Hotkey]

    init(hotkeys: [Hotkey]) { self.hotkeys = hotkeys }

    init(from decoder: Decoder) throws {
        var saved = try decoder.unkeyedContainer()
        var migrated: [Hotkey] = []
        while !saved.isAtEnd {
            migrated += try saved.decode(Saved.self).hotkeys
        }
        hotkeys = migrated
    }

    /// Every field a hotkey ever had, all optional: a save from any version decodes.
    private struct Saved: Decodable {
        var id: UUID?
        var keyCode: UInt16
        var modifiers: UInt?
        var keyName: String?
        var gesture: Hotkey.Gesture?
        var mode: String?
        var action: Hotkey.Action?
        var enabled: Bool?

        /// What this entry means today: a gesture of its own, or the one or two that its old mode stood for.
        var hotkeys: [Hotkey] {
            func binding(_ gesture: Hotkey.Gesture, id: UUID) -> Hotkey {
                Hotkey(id: id, keyCode: keyCode, modifiers: modifiers ?? 0, keyName: keyName ?? "",
                       gesture: gesture, action: action ?? .insert, enabled: enabled ?? true)
            }
            let id = id ?? UUID()
            if let gesture { return [binding(gesture, id: id)] }
            switch mode {
            case "toggle": return [binding(.press, id: id)]
            case "both": return [binding(.hold, id: id), binding(.doubleTap, id: UUID())]
            default: return [binding(.hold, id: id)]
            }
        }
    }
}

/// Watches the keyboard everywhere for the hotkeys (an event tap, so key combinations are kept from the app you
/// are in; this needs Accessibility access) and turns presses into start, stop and cancel:
/// - hold: recording lasts while the key is down. When the key also carries a tap gesture the recording starts
///   provisionally on the way down, so the first words are kept, and is cancelled again if the key comes up before
///   the hold threshold: that press was a tap after all.
/// - double-tap: two taps inside the window latch recording on; the next press of that key stops it.
/// - press: one tap starts, the next stops. On a key that also has a double-tap binding the tap waits out the
///   double-tap window first.
/// A lone modifier only counts when pressed on its own: pressing another key while it is down (⌘C) cancels it.
@MainActor
final class HotkeyMonitor {
    static let ownEvents: Int64 = 0x50484F4E  // marks the keys we type ourselves, so they never count as presses
    private static let holdThreshold = 0.3   // a press shorter than this is a tap
    private static let doubleTapWindow = 0.4

    var hotkeys: [Hotkey] = []
    var onStart: (Hotkey.Action) -> Void = { _ in }
    var onStop: () -> Void = {}
    /// Drops the recording in progress and everything it heard: a provisional hold that turned out to be a tap.
    var onCancel: () -> Void = {}
    var isRecording: () -> Bool = { false }
    /// While set, the next key pressed becomes a hotkey instead of acting as one (Esc cancels with nil).
    var onCapture: ((Hotkey?) -> Void)?
    private(set) var isListening = false

    /// The recording this monitor started: which key is behind it, by which gesture, whether it is only provisional
    /// (a hold that may yet turn out to be a tap) and whether it stays on until the key is pressed again.
    private struct Session {
        var key: Hotkey.Key
        var gesture: Hotkey.Gesture
        var provisional: Bool
        var latched: Bool
    }

    private var tap: CFMachPort?
    private var session: Session?
    private var down: (key: Hotkey.Key, at: Date, acted: Bool)?  // the hotkey key held right now
    private var interrupted = false   // another key went down while a lone modifier was held
    private var pendingTap: (key: Hotkey.Key, at: Date)?  // a tap that may still become a double tap
    private var captureModifier: UInt16?
    private var waiting: Timer?

    /// Starts watching; false while macOS has not granted Accessibility access. With `prompt`, macOS also shows its
    /// own dialog asking for it, which only a click of ours should bring up.
    @discardableResult
    func listen(prompt: Bool = true) -> Bool {
        guard tap == nil else { return true }
        let trusted = prompt ? AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
                             : AXIsProcessTrusted()
        guard trusted else { return false }
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
        waiting?.invalidate()
        waiting = nil
        return true
    }

    /// Starts watching as soon as Accessibility access is there, without asking for it (the setup window does):
    /// at launch, and then once a second until it is granted.
    func listenWhenAllowed(_ started: @escaping @MainActor () -> Void) {
        if listen(prompt: false) { return started() }
        guard waiting == nil else { return }
        waiting = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.listen(prompt: false) else { return }
                started()
            }
        }
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
            let key = Hotkey.Key(keyCode: code, modifiers: 0)
            guard !bindings(for: key).isEmpty else { return false }
            flags.contains(lone.flag) ? keyDown(key) : keyUp(key)
            return false  // modifiers always reach the app: they are part of its shortcuts too
        }
        if type == .keyDown, let pressed = down, Hotkey.modifierKeys[pressed.key.keyCode] != nil {
            interrupt(pressed)  // ⌘C and friends: the lone modifier was a shortcut, not a hotkey
            return false
        }
        let key = Hotkey.Key(keyCode: code, modifiers: flags.subtracting(.function).rawValue)
        guard !bindings(for: key).isEmpty else { return false }
        if type == .keyDown {
            if event.getIntegerValueField(.keyboardEventAutorepeat) == 0 { keyDown(key) }
        } else if type == .keyUp {
            keyUp(key)
        }
        return true
    }

    /// The bindings that act on a key: enabled, and the first of any that claim the same gesture.
    private func bindings(for key: Hotkey.Key) -> [Hotkey] {
        let losers = Hotkey.conflicting(in: hotkeys)
        return hotkeys.filter { $0.enabled && $0.key == key && !losers.contains($0.id) }
    }

    private func keyDown(_ key: Hotkey.Key) {
        let bindings = bindings(for: key)
        guard !bindings.isEmpty else { return }
        down = (key, Date(), acted: false)
        interrupted = false
        if let session, session.latched, session.key == key {
            stop()  // a latched recording ends on the next press of its key
            down?.acted = true
            return
        }
        if let double = bindings.first(where: { $0.gesture == .doubleTap }), let pending = pendingTap,
           pending.key == key, Date().timeIntervalSince(pending.at) < Self.doubleTapWindow {
            pendingTap = nil
            down?.acted = true
            isRecording() ? stop() : start(double, provisional: false, latched: true)
            return
        }
        if let hold = bindings.first(where: { $0.gesture == .hold }) {
            start(hold, provisional: bindings.contains { $0.gesture != .hold }, latched: false)
        }
        // A press or a double tap is only known once the key comes up again.
    }

    private func keyUp(_ key: Hotkey.Key) {
        guard let pressed = down, pressed.key == key else { return }
        down = nil
        if interrupted {
            interrupted = false  // the key was part of a shortcut: its gesture is off
            return
        }
        guard !pressed.acted else { return }
        let bindings = bindings(for: key)
        let tapGestures = bindings.contains { $0.gesture != .hold }
        if let session, session.gesture == .hold, session.key == key {
            if Date().timeIntervalSince(pressed.at) >= Self.holdThreshold || !tapGestures {
                stop()
                return
            }
            cancel()  // too short for a hold, and the key has a tap gesture: that was a tap
        }
        tapped(key, bindings)
    }

    /// A tap: on a key with a double-tap binding it is kept for a moment, in case a second one follows.
    private func tapped(_ key: Hotkey.Key, _ bindings: [Hotkey]) {
        let press = bindings.first { $0.gesture == .press }
        guard bindings.contains(where: { $0.gesture == .doubleTap }) else {
            if let press { toggle(press) }
            return
        }
        let at = Date()
        pendingTap = (key, at)
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.doubleTapWindow) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.pendingTap?.at == at else { return }
                self.pendingTap = nil
                if let press { self.toggle(press) }
            }
        }
    }

    /// Another key went down while a lone-modifier hotkey was held: the hold is dropped, a provisional one without
    /// a trace, and the release that follows does nothing.
    private func interrupt(_ pressed: (key: Hotkey.Key, at: Date, acted: Bool)) {
        interrupted = true
        guard let session, session.gesture == .hold, session.key == pressed.key else { return }
        if session.provisional, Date().timeIntervalSince(pressed.at) < Self.holdThreshold {
            cancel()
        } else {
            stop()
        }
    }

    private func toggle(_ hotkey: Hotkey) {
        isRecording() ? stop() : start(hotkey, provisional: false, latched: false)
    }

    private func start(_ hotkey: Hotkey, provisional: Bool, latched: Bool) {
        guard !isRecording() else { return }
        session = Session(key: hotkey.key, gesture: hotkey.gesture, provisional: provisional, latched: latched)
        onStart(hotkey.action)
    }

    private func stop() {
        session = nil
        pendingTap = nil
        onStop()
    }

    private func cancel() {
        session = nil
        onCancel()
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
