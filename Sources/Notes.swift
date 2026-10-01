import AppKit
import SwiftUI

/// The notes text, as an AppKit editor (SwiftUI's text editing has no control over undo, cursor or shortcuts at this
/// level). Hosted in SwiftUI by `NotesEditorView`; reports its size, emptiness, editing state and scroll position to
/// the model. Every change is kept by `NotesStore`.
@MainActor
final class NotesEditor: NSObject, NSTextViewDelegate {
    static let inset = NSSize(width: 18, height: 14)
    private static let maxTextHeight: CGFloat = 240
    private static let followSlack: CGFloat = 24  // this close to the end counts as "at the end"

    let view = FadingScrollView(frame: NSRect(x: 0, y: 0, width: AppModel.paneWidth, height: 50))
    private let text = NotesTextView()
    private let model: AppModel
    private let store: NotesStore
    private let attributes: [NSAttributedString.Key: Any]
    private let lineHeight: CGFloat
    private var startsParagraph = false
    private var glides = 0  // follow-the-end scroll animations in flight

    /// Only the notes on screen take clicks; hidden notes give up the keyboard.
    var isActive = false {
        didSet {
            text.isActive = isActive
            if !isActive, text.window?.firstResponder === text { text.window?.makeFirstResponder(nil) }
        }
    }

    init(model: AppModel, store: NotesStore) {
        self.model = model
        self.store = store
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
        text.textStorage?.setAttributedString(NSAttributedString(string: store.initialText, attributes: attributes))
        text.delegate = self
        text.onFocusChange = { [unowned self] in reportEditing() }
        view.documentView = text

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

    /// The next phrase begins a new line (a new recording).
    func startParagraph() {
        startsParagraph = true
    }

    /// Add a finished phrase at the end, leaving the cursor, the selection and any edit in progress where they are.
    func append(_ phrase: String) {
        guard let storage = text.textStorage, !phrase.isEmpty else { return }
        store.recordPhrase(phrase)
        let following = isAtEnd
        var piece = phrase
        if let last = storage.string.last {
            piece = startsParagraph ? (last == "\n" ? "" : "\n") + phrase : (last.isWhitespace ? "" : " ") + phrase
        }
        startsParagraph = false
        // Dictated text is not an edit: ⌘Z steps back through what you typed, and a phrase landing mid-edit never
        // joins your typing's undo step.
        text.breakUndoCoalescing()
        text.undoManager?.disableUndoRegistration()
        storage.replaceCharacters(in: NSRange(location: storage.length, length: 0),
                                  with: NSAttributedString(string: piece, attributes: attributes))
        text.undoManager?.enableUndoRegistration()
        text.didChangeText()
        if following { followEnd(animated: true) }
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
        store.changed(text.string)
        report()
    }

    private var isAtEnd: Bool {  // at the end, or on the way there: a glide in flight still counts
        glides > 0 || view.contentView.documentVisibleRect.maxY >= text.frame.height - Self.followSlack
    }

    /// The height the notes want: the text view's own laid-out height (text plus insets, at its real width), from one
    /// line up to `maxTextHeight`; past that the text scrolls.
    private func report() {
        guard let layout = text.layoutManager, let container = text.textContainer else { return }
        layout.ensureLayout(for: container)
        text.sizeToFit()
        let height = min(max(text.frame.height, lineHeight + 2 * Self.inset.height), Self.maxTextHeight + 2 * Self.inset.height)
        if model.notesHeight != height.rounded(.up) { model.notesHeight = height.rounded(.up) }
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

/// Scrolls with its top and bottom edges fading into the glass, so lines never end on a hard cut.
final class FadingScrollView: NSScrollView {
    private static let fadeHeight: CGFloat = 14
    private let fade = CAGradientLayer()

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

/// The notes text view: plain, editable from the first click, with the text cursor under the pointer even before it
/// has the keyboard, the standard editing shortcuts handled here (the app has no menu bar to route them) and a short
/// context menu. While empty it is part of the handle: dragging moves the control, a click still starts typing.
final class NotesTextView: NSTextView {
    var onFocusChange: () -> Void = {}
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
    }

    override func cursorUpdate(with event: NSEvent) { NSCursor.iBeam.set() }
    override func mouseEntered(with event: NSEvent) { NSCursor.iBeam.set() }
    override func mouseMoved(with event: NSEvent) { NSCursor.iBeam.set() }
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
        case "z" where modifiers.contains(.shift): undoManager?.redo()
        case "z": undoManager?.undo()
        default: return super.performKeyEquivalent(with: event)
        }
        return true
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        menu.addItem(withTitle: "Cut", action: #selector(cut(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Copy", action: #selector(copy(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Paste", action: #selector(pasteAsPlainText(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Select All", action: #selector(selectAll(_:)), keyEquivalent: "")
        return menu
    }
}
