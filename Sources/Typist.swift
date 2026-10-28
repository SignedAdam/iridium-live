import AppKit
import Synchronization

@MainActor
protocol KeySink: AnyObject {
    /// Called when keys still waiting were thrown away (the app in front changed before they could be sent).
    var onDropped: () -> Void { get set }
    /// The app in front takes text as one paste per sentence, rather than typed as it is heard.
    var pastesHere: Bool { get }
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
        guard isEnabled, final || !sink.pastesHere else { return }
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

/// Types by posting key events, all at once, so corrections land instantly. Apps in `pasteApps` get text as one paste
/// instead: a text field drawn by a web page can lose keys that arrive faster than it redraws, but takes a paste whole.
/// The clipboard holds the text only until the app has read it, then gets its own contents back; whatever was asked
/// for meanwhile waits its turn, and is dropped if another app comes to the front first.
@MainActor
final class KeyboardSink: KeySink {
    private static let chunk = 20 // UTF-16 units one key event carries
    private static let transient = NSPasteboard.PasteboardType("org.nspasteboard.TransientType") // kept out of clipboard histories

    private enum Key {
        case backspace
        case text([UniChar])
        case paste
    }

    private enum Step {
        case keys([Key])
        case paste(String)
    }

    var onDropped: () -> Void = {}
    var pasteApps: Set<String> = []
    private let source = CGEventSource(stateID: .combinedSessionState)
    private let pasteboard: NSPasteboard
    private var waiting: [(step: Step, app: pid_t?)] = []
    private var pasting = false

    init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
    }

    static func requestAccess() -> Bool {
        AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    var pastesHere: Bool {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier.map(pasteApps.contains) ?? false
    }

    func backspace(_ count: Int) {
        guard count > 0 else { return }
        send(.keys(Array(repeating: .backspace, count: count)))
    }

    func type(_ text: String) {
        guard !text.isEmpty else { return }
        if pastesHere { return send(.paste(text)) }
        var keys: [Key] = []
        var units: [UniChar] = []
        for character in text {
            let next = Array(String(character).utf16)
            if units.count + next.count > Self.chunk { keys.append(.text(units)); units = [] }
            units += next
        }
        if !units.isEmpty { keys.append(.text(units)) }
        send(.keys(keys))
    }

    private func send(_ step: Step) {
        waiting.append((step, Self.frontmost()))
        if !pasting { drain() }
    }

    private func drain() {
        while !waiting.isEmpty {
            let (step, app) = waiting.removeFirst()
            guard app == nil || Self.frontmost() == app else { return drop() }
            switch step {
            case .keys(let keys):
                keys.forEach(post)
            case .paste(let text):
                pasting = true
                Task {
                    let landed = await paste(text)
                    pasting = false
                    if landed { drain() } else { drop() }
                }
                return
            }
        }
    }

    private func drop() {
        waiting.removeAll()
        onDropped()
    }

    /// Puts `text` on the clipboard, presses Command-V and waits for the app to read it; the clipboard gets its own
    /// contents back either way. False when no app asked for the text.
    private func paste(_ text: String) async -> Bool {
        let saved = pasteboard.pasteboardItems?.map { item in
            item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
        } ?? []
        let offer = PasteOffer(text)
        let item = NSPasteboardItem()
        item.setDataProvider(offer, forTypes: [.string])
        item.setData(Data(), forType: Self.transient)
        pasteboard.clearContents()
        pasteboard.writeObjects([item])
        post(.paste)
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(2)
        while !offer.taken, clock.now < deadline { try? await Task.sleep(for: .milliseconds(10)) }
        let taken = offer.taken
        if taken { try? await Task.sleep(for: .milliseconds(150)) } // the app may read after a clipboard history did
        pasteboard.clearContents()
        pasteboard.writeObjects(saved.map { contents in
            let item = NSPasteboardItem()
            for (type, data) in contents { item.setData(data, forType: type) }
            return item
        })
        return taken
    }

    private func post(_ key: Key) {
        for down in [true, false] {
            let event: CGEvent?
            switch key {
            case .backspace:
                event = CGEvent(keyboardEventSource: source, virtualKey: 51, keyDown: down)
                event?.flags = []
            case .text(let units):
                event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down)
                event?.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
                event?.flags = []
            case .paste:
                event = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: down)
                event?.flags = .maskCommand
            }
            event?.setIntegerValueField(.eventSourceUserData, value: HotkeyMonitor.ownEvents)
            event?.post(tap: .cghidEventTap)
        }
    }

    private static func frontmost() -> pid_t? {
        NSWorkspace.shared.frontmostApplication?.processIdentifier
    }
}

/// The text of one paste, handed over only when an app reads the clipboard, which is how the paste knows it landed.
private final class PasteOffer: NSObject, NSPasteboardItemDataProvider, Sendable {
    private let text: String
    private let read = Mutex(false)

    init(_ text: String) {
        self.text = text
    }

    var taken: Bool { read.withLock { $0 } }

    func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
        item.setString(text, forType: type)
        read.withLock { $0 = true }
    }
}

