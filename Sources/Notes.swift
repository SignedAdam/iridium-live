import AppKit
import SwiftUI

/// The notes text, as an AppKit editor (SwiftUI's text editing has no control over undo, cursor or shortcuts at this
/// level). Hosted in SwiftUI by `NotesEditorView`; reports its size, emptiness, editing state and scroll position to
/// the model. Every change is kept by `NotesLibrary`, in whichever note is open.
@MainActor
final class NotesEditor: NSObject, NSTextViewDelegate, @preconcurrency NSTextStorageDelegate {
    static let inset = NSSize(width: 18, height: 14)
    private static let maxTextHeight: CGFloat = 240
    private static let followSlack: CGFloat = 24  // this close to the end counts as "at the end"

    let view = FadingScrollView(frame: NSRect(x: 0, y: 0, width: AppModel.paneWidth, height: 50))
    private let text = NotesTextView()
    private let model: AppModel
    let library: NotesLibrary
    private let attributes: [NSAttributedString.Key: Any]
    private let lineHeight: CGFloat
    private var startsParagraph = false
    private var glides = 0  // follow-the-end scroll animations in flight
    private var hiding: Task<Void, Never>?
    private var block: NSRange?     // what the recording in progress has appended, while it is still ours to replace
    private var applying = false    // our own edit is going in: it is not the speaker touching the block

    /// Only the notes on screen take clicks and set the pointer; hidden notes give up the keyboard. Once faded out the
    /// editor is hidden outright, so no text cursor shows over the pane that replaced it.
    var isActive = false {
        didSet {
            text.isActive = isActive
            if !isActive, text.window?.firstResponder === text { text.window?.makeFirstResponder(nil) }
            hiding?.cancel()
            if isActive {
                view.isHidden = false
            } else {
                hiding = Task { [weak self] in
                    try? await Task.sleep(for: .milliseconds(500))
                    guard !Task.isCancelled, let self, !self.isActive else { return }
                    self.view.isHidden = true
                }
            }
        }
    }

    init(model: AppModel, library: NotesLibrary) {
        self.model = model
        self.library = library
        let font = NSFont(name: "TikTokSans-Regular", size: 15) ?? .systemFont(ofSize: 15)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 3  // Return starts the next line, with no gap between paragraphs
        attributes = [.font: font, .foregroundColor: NSColor.white.withAlphaComponent(0.92), .paragraphStyle: paragraph]
        lineHeight = ceil(font.ascender - font.descender + font.leading + paragraph.lineSpacing)
        super.init()

        view.drawsBackground = false
        view.borderType = .noBorder
        view.hasVerticalScroller = false  // the SwiftUI indicator shows position, always, whenever there is more
        view.contentView.postsBoundsChangedNotifications = true
        text.frame = NSRect(origin: .zero, size: view.contentSize)
        text.minSize = .zero
        text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        text.isVerticallyResizable = true
        text.isHorizontallyResizable = false
        text.autoresizingMask = .width
        text.textContainer?.widthTracksTextView = true
        text.textContainer?.containerSize = NSSize(width: view.contentSize.width, height: .greatestFiniteMagnitude)
        text.textContainerInset = Self.inset
        text.drawsBackground = false
        text.isRichText = false
        text.allowsUndo = true
        text.isAutomaticQuoteSubstitutionEnabled = false
        text.isAutomaticDashSubstitutionEnabled = false
        text.isContinuousSpellCheckingEnabled = false
        text.insertionPointColor = .white
        text.selectedTextAttributes = [.backgroundColor: NSColor.white.withAlphaComponent(0.24)]
        text.typingAttributes = attributes
        text.textStorage?.setAttributedString(NSAttributedString(string: library.initialText, attributes: attributes))
        text.textStorage?.delegate = self
        text.delegate = self
        text.onFocusChange = { [unowned self] in reportEditing() }
        text.onCommand = { [unowned self] command in run(command) }
        text.canCleanUp = { [model] in model.settings.cleanupEnabled && !model.cleaningNote }
        library.onOpen = { [unowned self] text in show(text) }
        view.documentView = text
        view.isHidden = true  // until the notes pane opens
        view.rim = Self.inset

        let center = NotificationCenter.default
        center.addObserver(forName: NSView.boundsDidChangeNotification, object: view.contentView, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reportScroll() }
        }
        // A new size wraps the text differently and shows a different share of it: measure again.
        view.contentView.postsFrameChangedNotifications = true
        center.addObserver(forName: NSView.frameDidChangeNotification, object: view.contentView, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.report() }
        }
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.reportEditing() }
            }
        }
        report()
    }

    /// The end of the note the next phrase lands after, for the cleanup model to read: enough of it to carry a
    /// sentence the dictation may correct, never enough to be worth sending whole.
    var dictationContext: String {
        String(text.string.suffix(2000))
    }

    /// The next phrase begins a new line (a new recording), and a new block: what this recording appends is tracked
    /// as one stretch, so the whole of it can be replaced once it has been polished.
    func startParagraph() {
        startsParagraph = true
        block = nil
    }

    /// Add a finished phrase at the end, leaving the cursor, the selection and any edit in progress where they are.
    /// The note being edited keeps a record of the phrase it came from, so it can be traced back and heard again.
    func append(_ entry: HistoryEntry) {
        let phrase = entry.text
        guard let storage = text.textStorage, !phrase.isEmpty else { return }
        library.record(entry)
        let following = isAtEnd
        var piece = phrase
        if let last = storage.string.last {
            piece = startsParagraph ? (last == "\n" ? "" : "\n") + phrase : (last.isWhitespace ? "" : " ") + phrase
        }
        startsParagraph = false
        let start = storage.length + (piece as NSString).length - (phrase as NSString).length
        // Dictated text is not an edit: ⌘Z steps back through what you typed, and a phrase landing mid-edit never
        // joins your typing's undo step.
        applying = true
        text.breakUndoCoalescing()
        text.undoManager?.disableUndoRegistration()
        storage.replaceCharacters(in: NSRange(location: storage.length, length: 0),
                                  with: NSAttributedString(string: piece, attributes: attributes))
        text.undoManager?.enableUndoRegistration()
        applying = false
        let from = block?.location ?? start
        block = NSRange(location: from, length: storage.length - from)
        text.didChangeText()
        if following { followEnd(animated: true) }
    }

    /// The recording is over and the whole of it came back polished, or a spoken correction changed it mid-recording:
    /// it replaces exactly what it appended, where it stands, as long as the speaker has not edited inside that block
    /// since. Like the phrases themselves, this is not an undo step. With `keepingBlock` the block stays tracked, so
    /// the phrases still to come join it. Says whether the text was replaced.
    @discardableResult
    func replaceDictated(with polished: String, keepingBlock: Bool = false) -> Bool {
        guard let range = block, let storage = text.textStorage, !polished.isEmpty || keepingBlock,
              NSMaxRange(range) <= storage.length else { return false }
        block = keepingBlock ? NSRange(location: range.location, length: (polished as NSString).length) : nil
        guard (storage.string as NSString).substring(with: range) != polished else {
            if keepingBlock { block = range }
            return false
        }
        let following = isAtEnd
        let selection = text.selectedRange()
        applying = true
        text.breakUndoCoalescing()
        text.undoManager?.disableUndoRegistration()
        storage.replaceCharacters(in: range, with: NSAttributedString(string: polished, attributes: attributes))
        text.undoManager?.enableUndoRegistration()
        applying = false
        if selection.location >= NSMaxRange(range) {  // the cursor was past the block: it keeps its place in the text
            let moved = selection.location + (polished as NSString).length - range.length
            text.setSelectedRange(NSRange(location: min(moved, storage.length), length: 0))
        }
        text.didChangeText()
        if following { followEnd(animated: true) }
        return true
    }

    /// "Clean up note": the model's version of the whole note, in one undoable edit, so ⌘Z brings the note back as
    /// it was.
    func replaceAll(with cleaned: String) {
        guard let storage = text.textStorage, !cleaned.isEmpty, cleaned != text.string else { return }
        let whole = NSRange(location: 0, length: storage.length)
        applying = true
        text.breakUndoCoalescing()
        if text.shouldChangeText(in: whole, replacementString: cleaned) {
            storage.replaceCharacters(in: whole, with: NSAttributedString(string: cleaned, attributes: attributes))
            text.didChangeText()
            text.breakUndoCoalescing()
        }
        applying = false
        block = nil
    }

    /// The block the current recording appended moves with whatever the speaker does around it, and is given up as
    /// soon as they edit inside it: from then on the text is theirs, and polishing leaves it alone.
    func textStorage(_ storage: NSTextStorage, didProcessEditing edited: NSTextStorageEditActions,
                     range: NSRange, changeInLength delta: Int) {
        guard edited.contains(.editedCharacters), !applying, let current = block else { return }
        let before = NSRange(location: range.location, length: range.length - delta)  // the range as it was edited
        if NSMaxRange(before) <= current.location {
            block = NSRange(location: current.location + delta, length: current.length)
        } else if before.location < NSMaxRange(current) {
            block = nil
        }
    }

    /// Show another note's text. It is not an edit: it starts its own undo history and is not written back.
    private func show(_ note: String) {
        text.undoManager?.removeAllActions()
        text.textStorage?.setAttributedString(NSAttributedString(string: note, attributes: attributes))
        text.typingAttributes = attributes
        text.setSelectedRange(NSRange(location: (note as NSString).length, length: 0))
        block = nil
        startsParagraph = true
        report()
        followEnd(animated: false)
    }

    /// The notes' own menu, beyond editing the text.
    func run(_ command: NotesCommand) {
        switch command {
        case let .saveSelection(selection):
            name(library.saveSelection(selection))
        case .save:
            if library.currentNote == nil { name(library.save(text.string)) } else { library.flush() }
        case .newNote:
            library.newNote(from: text.string)
        case .cleanUp:
            model.cleanUpNote(text.string)
        case .myNotes:
            model.showMyNotes()
        }
    }

    /// A note just made: its name is put up for typing, with the keyboard on it.
    private func name(_ note: SavedNote) {
        view.window?.makeKey()
        library.naming = note.id
    }

    /// Glide to the newest text.
    func followEnd(animated: Bool) {
        let clip = view.contentView
        let target = NSPoint(x: 0, y: max(0, text.frame.height - clip.bounds.height))
        guard animated else {
            clip.scroll(to: target)
            view.reflectScrolledClipView(clip)
            return
        }
        glides += 1
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.3
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            clip.animator().setBoundsOrigin(target)
        }, completionHandler: {
            MainActor.assumeIsolated {
                self.glides -= 1
                self.view.reflectScrolledClipView(clip)
            }
        })
    }

    func textDidChange(_ notification: Notification) {
        text.typingAttributes = attributes
        library.changed(text.string)
        report()
    }

    private var isAtEnd: Bool {  // at the end, or on the way there: a glide in flight still counts
        glides > 0 || view.contentView.documentVisibleRect.maxY >= text.frame.height - Self.followSlack
    }

    /// The height the notes want: the laid-out text plus insets, from one line up to `maxTextHeight`, past which the
    /// text scrolls. Measured from the layout, never from the text view, which a scroll view keeps at least as tall as
    /// what is visible (so a pane that was once tall would stay tall).
    private func report() {
        guard let layout = text.layoutManager, let container = text.textContainer else { return }
        layout.ensureLayout(for: container)
        let textHeight = min(max(layout.usedRect(for: container).height, lineHeight), Self.maxTextHeight)
        let height = ceil(textHeight + 2 * Self.inset.height)
        if model.notesHeight != height { model.notesHeight = height }
        if model.notesEmpty != text.string.isEmpty { model.notesEmpty = text.string.isEmpty }
        reportScroll()
    }

    private func reportScroll() {
        let visible = view.contentView.documentVisibleRect
        let total = max(text.frame.height, 1)
        let hidden = max(total - visible.height, 0)
        // Under 2 pt of difference is rounding, not more text.
        let metrics = hidden < 2 ? ScrollMetrics()
            : ScrollMetrics(visibleFraction: visible.height / total, position: min(1, max(0, visible.minY / hidden)))
        if model.notesScroll != metrics { model.notesScroll = metrics }
    }

    private func reportEditing() {
        model.notesEditing = text.window?.isKeyWindow == true && text.window?.firstResponder === text
    }
}

/// Hosts the notes editor in SwiftUI. The editor outlives this view, so text, cursor and undo survive tab switches.
struct NotesEditorView: NSViewRepresentable {
    let editor: NotesEditor

    func makeNSView(context: Context) -> FadingScrollView { editor.view }
    func updateNSView(_ view: FadingScrollView, context: Context) {}
}

/// Scrolls with its top and bottom edges fading into the glass, so lines never end on a hard cut. Its rim, outside the
/// text, belongs to the glass: clicks there fall through, so the control drags from its edges even over the notes.
final class FadingScrollView: NSScrollView {
    private static let fadeHeight: CGFloat = 14
    private let fade = CAGradientLayer()
    var rim = NSSize.zero

    override func hitTest(_ point: NSPoint) -> NSView? {
        let inside = bounds.insetBy(dx: rim.width, dy: rim.height).contains(convert(point, from: superview))
        return inside ? super.hitTest(point) : nil
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        fade.colors = [CGColor.clear, CGColor.black, CGColor.black, CGColor.clear]
        layer?.mask = fade
        fitFade()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        fitFade()
    }

    private func fitFade() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fade.frame = bounds
        let edge = min(0.5, Self.fadeHeight / max(bounds.height, 1))
        fade.locations = [0, NSNumber(value: edge), NSNumber(value: 1 - edge), 1]
        CATransaction.commit()
    }
}

/// What the notes' right-click menu asks for, beyond editing the text.
enum NotesCommand {
    case saveSelection(String)
    case save
    case newNote
    case cleanUp
    case myNotes
}

/// The notes text view: plain, editable from the first click, with the text cursor under the pointer even before it
/// has the keyboard, the standard editing shortcuts handled here (the app has no menu bar to route them) and the
/// notes' own menu on a right click. While empty it is part of the handle: dragging moves the control, a click still
/// starts typing.
final class NotesTextView: NSTextView {
    var onFocusChange: () -> Void = {}
    var onCommand: (NotesCommand) -> Void = { _ in }
    var canCleanUp: () -> Bool = { false }  // the cleanup model is on, and no note is being cleaned already
    var isActive = false
    private var pointerArea: NSTrackingArea?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        isActive ? super.hitTest(point) : nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let pointerArea { removeTrackingArea(pointerArea) }
        let area = NSTrackingArea(rect: .zero, options: [.cursorUpdate, .mouseMoved, .mouseEnteredAndExited, .activeAlways,
                                                         .inVisibleRect], owner: self)
        addTrackingArea(area)
        pointerArea = area
        window?.invalidateCursorRects(for: self)  // the text area moved with the view
    }

    /// Where the text itself is: inside the editor's rim, which belongs to the glass (clicks there fall through to
    /// drag the control), and within sight. Only there does the pointer become a text cursor.
    private var textArea: NSRect {
        guard let scroll = enclosingScrollView as? FadingScrollView else { return visibleRect }
        let inner = scroll.bounds.insetBy(dx: scroll.rim.width, dy: scroll.rim.height)
        return convert(inner, from: scroll).intersection(visibleRect)
    }

    /// NSTextView claims the text cursor for the whole view, rim included: claim it for the text area instead.
    override func resetCursorRects() {
        guard isActive else { return }
        addCursorRect(textArea, cursor: .iBeam)
    }

    private func pointer(at event: NSEvent) {
        let inside = isActive && textArea.contains(convert(event.locationInWindow, from: nil))
        (inside ? NSCursor.iBeam : NSCursor.arrow).set()
    }

    override func cursorUpdate(with event: NSEvent) { pointer(at: event) }
    override func mouseEntered(with event: NSEvent) { pointer(at: event) }
    override func mouseMoved(with event: NSEvent) { pointer(at: event) }
    override func mouseExited(with event: NSEvent) { NSCursor.arrow.set() }

    override func mouseDown(with event: NSEvent) {
        guard string.isEmpty, let window else { return super.mouseDown(with: event) }
        let start = event.locationInWindow
        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            if next.type == .leftMouseUp {
                window.makeKey()
                window.makeFirstResponder(self)
                return
            }
            if hypot(next.locationInWindow.x - start.x, next.locationInWindow.y - start.y) > 3 {
                window.performDrag(with: event)
                return
            }
        }
    }

    override func becomeFirstResponder() -> Bool {
        defer { onFocusChange() }
        return super.becomeFirstResponder()
    }

    override func resignFirstResponder() -> Bool {
        defer { onFocusChange() }
        return super.resignFirstResponder()
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard window?.firstResponder === self, modifiers.subtracting(.shift) == .command,
              let key = event.charactersIgnoringModifiers?.lowercased() else { return super.performKeyEquivalent(with: event) }
        switch key {
        case "c": copy(nil)
        case "x": cut(nil)
        case "v": pasteAsPlainText(nil)
        case "a": selectAll(nil)
        case "s": onCommand(.save)
        case "n": onCommand(.newNote)
        case "z" where modifiers.contains(.shift): undoManager?.redo()
        case "z": undoManager?.undo()
        default: return super.performKeyEquivalent(with: event)
        }
        return true
    }

    /// The notes' own menu: editing the text, and what can be done with the note itself.
    override func rightMouseDown(with event: NSEvent) {
        guard isActive, let window else { return super.rightMouseDown(with: event) }
        MenuPanel.show(menuItems(), at: window.convertPoint(toScreen: event.locationInWindow))
    }

    override func menu(for event: NSEvent) -> NSMenu? { nil }

    private func menuItems() -> [MenuItem] {
        let selection = (string as NSString).substring(with: selectedRange())
        let pasteable = NSPasteboard.general.canReadObject(forClasses: [NSString.self])
        var items = [
            MenuItem(id: "cut", title: "Cut", symbol: "scissors", shortcut: "⌘X", enabled: !selection.isEmpty) {
                [weak self] in self?.cut(nil)
            },
            MenuItem(id: "copy", title: "Copy", symbol: "doc.on.doc", shortcut: "⌘C", enabled: !selection.isEmpty) {
                [weak self] in self?.copy(nil)
            },
            MenuItem(id: "paste", title: "Paste", symbol: "doc.on.clipboard", shortcut: "⌘V", enabled: pasteable) {
                [weak self] in self?.pasteAsPlainText(nil)
            },
            MenuItem(id: "all", title: "Select All", symbol: "selection.pin.in.out", shortcut: "⌘A", enabled: !string.isEmpty) {
                [weak self] in self?.selectAll(nil)
            },
            .separator(),
        ]
        if !selection.isEmpty {
            items.append(MenuItem(id: "selection", title: "Save selection as note", symbol: "text.badge.plus") {
                [weak self] in self?.onCommand(.saveSelection(selection))
            })
        }
        items.append(MenuItem(id: "save", title: "Save note", symbol: "square.and.arrow.down", shortcut: "⌘S") {
            [weak self] in self?.onCommand(.save)
        })
        items.append(MenuItem(id: "new", title: "New note", symbol: "square.and.pencil", shortcut: "⌘N") {
            [weak self] in self?.onCommand(.newNote)
        })
        items.append(MenuItem(id: "cleanup", title: "Clean up note", symbol: "wand.and.sparkles",
                              enabled: !string.isEmpty && canCleanUp()) {
            [weak self] in self?.onCommand(.cleanUp)
        })
        items.append(MenuItem(id: "library", title: "My notes", symbol: "list.bullet") {
            [weak self] in self?.onCommand(.myNotes)
        })
        return items
    }
}
