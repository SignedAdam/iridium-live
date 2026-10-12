import AppKit
import SwiftUI
@preconcurrency import MeetingKit

let speakerTints: [Color] = [
    Color(red: 1.00, green: 0.62, blue: 0.55),
    Color(red: 0.98, green: 0.80, blue: 0.52),
    Color(red: 0.64, green: 0.85, blue: 0.70),
    Color(red: 0.55, green: 0.82, blue: 0.86),
    Color(red: 0.60, green: 0.74, blue: 0.95),
    Color(red: 0.74, green: 0.68, blue: 0.96),
    Color(red: 0.88, green: 0.66, blue: 0.86),
    Color(red: 0.95, green: 0.68, blue: 0.74),
]

func speakerTint(_ index: Int) -> Color {
    speakerTints[((index % speakerTints.count) + speakerTints.count) % speakerTints.count]
}

struct TranscriptLine: Equatable {
    let id: UUID
    let speaker: String
    let colorIndex: Int
    let range: ClosedRange<TimeInterval>
}

enum TextTrait { case bold, italic, underline }

@MainActor @Observable
final class TranscriptEditor: NSObject {
    private(set) var activeLine: TranscriptLine?
    private(set) var isBold = false
    private(set) var isItalic = false
    private(set) var isUnderline = false
    private(set) var showDeletedToast = false

    @ObservationIgnored private let onEdit: (_ change: (inout Transcript) -> Void) -> Void
    @ObservationIgnored weak var textView: TranscriptTextView?
    @ObservationIgnored let undo = UndoManager()

    @ObservationIgnored private var rendered: Transcript?
    @ObservationIgnored private var scheduled: Transcript?
    @ObservationIgnored private var segments: [Segment] = []
    @ObservationIgnored private var dirty: Set<UUID> = []
    @ObservationIgnored private var rebuilding = false
    @ObservationIgnored private var commitTask: Task<Void, Never>?
    @ObservationIgnored private var toastTask: Task<Void, Never>?

    struct Segment {
        let id: UUID
        var paragraphStart: Int
        var bodyStart: Int
        var bodyLength: Int
        var bodyEnd: Int { bodyStart + bodyLength }
        var body: NSRange { NSRange(location: bodyStart, length: bodyLength) }
        var paragraph: NSRange { NSRange(location: paragraphStart, length: bodyEnd - paragraphStart) }
    }

    init(onEdit: @escaping (_ change: (inout Transcript) -> Void) -> Void) {
        self.onEdit = onEdit
    }

    func show(_ transcript: Transcript) {
        guard transcript != rendered, transcript != scheduled else { return }
        scheduled = transcript
        Task { @MainActor [weak self] in
            guard let self, self.scheduled == transcript else { return }
            self.scheduled = nil
            var incoming = transcript
            let pending = self.takePendingEdits()
            for edit in pending { incoming.updateTurn(id: edit.id, text: edit.text, styles: edit.styles) }
            self.render(incoming)
            if !pending.isEmpty { self.persist(incoming.turns) }
        }
    }

    var activeParagraphRange: NSRange? { activeIndex.map { segments[$0].paragraph } }
    var activeColor: NSColor { NSColor(speakerTint(activeLine?.colorIndex ?? 0)) }

    private var activeIndex: Int? {
        guard let id = activeLine?.id else { return nil }
        return segments.firstIndex { $0.id == id }
    }

    private func bodyAttributes(_ style: TextStyleRun) -> [NSAttributedString.Key: Any] {
        TranscriptDocument.bodyAttributes(style, para: TranscriptDocument.paragraphStyle(for: rendered))
    }

    private func render(_ transcript: Transcript) {
        rendered = transcript
        dirty = []
        guard let view = textView, let storage = view.textStorage else { return }
        let origin = view.enclosingScrollView?.contentView.bounds.origin
        let selection = view.selectedRange()
        let (document, built) = TranscriptDocument.build(transcript)
        rebuilding = true
        storage.setAttributedString(document)
        segments = built
        view.setSelectedRange(NSRange(location: min(selection.location, storage.length), length: 0))
        rebuilding = false
        if let origin { view.enclosingScrollView?.contentView.scroll(to: origin) }
        if let index = activeIndex { setActive(line(at: index)) } else { setActive(nil) }
        view.needsDisplay = true
    }

    private func line(at index: Int) -> TranscriptLine? {
        guard let transcript = rendered, transcript.turns.indices.contains(index) else { return nil }
        let turn = transcript.turns[index]
        return TranscriptLine(id: turn.id, speaker: transcript.name(for: turn.speakerID),
                              colorIndex: transcript.speakerIDs.firstIndex(of: turn.speakerID) ?? 0,
                              range: turn.start...max(turn.start, turn.end))
    }

    private func setActive(_ line: TranscriptLine?) {
        if activeLine != line { activeLine = line }
    }

    func deactivate() {
        commit()
        setActive(nil)
        textView?.needsDisplay = true
    }

    func deleteActiveLine() {
        guard let id = activeLine?.id else { return }
        commit()
        guard let before = rendered else { return }
        var after = before
        after.deleteTurn(id: id)
        apply(after, replacing: before, actionName: "Delete Line")
        setActive(nil)
        flashDeletedToast()
    }

    func undoLastChange() {
        commit()
        if undo.canUndo { undo.undo() }
        showDeletedToast = false
    }

    func redoLastChange() {
        if undo.canRedo { undo.redo() }
    }

    func toggle(_ trait: TextTrait) {
        guard let view = textView, let storage = view.textStorage, let index = activeIndex else { return }
        let selection = view.selectedRange()
        let target = NSIntersectionRange(selection, segments[index].body)
        if selection.length == 0 || target.length == 0 {
            var style = Self.style(of: view.typingAttributes)
            style.toggle(trait, on: !style.has(trait))
            view.typingAttributes = bodyAttributes(style)
            refreshFormatState()
            return
        }
        var allOn = true
        storage.enumerateAttributes(in: target) { attributes, _, stop in
            if !Self.style(of: attributes).has(trait) { allOn = false; stop.pointee = true }
        }
        guard view.shouldChangeText(in: target, replacementString: nil) else { return }
        storage.beginEditing()
        storage.enumerateAttributes(in: target) { attributes, range, _ in
            var style = Self.style(of: attributes)
            style.toggle(trait, on: !allOn)
            storage.setAttributes(self.bodyAttributes(style), range: range)
        }
        storage.endEditing()
        view.didChangeText()
        refreshFormatState()
    }

    func commit() {
        commitTask?.cancel()
        commitTask = nil
        let pending = takePendingEdits()
        guard !pending.isEmpty, var transcript = rendered else { return }
        for edit in pending { transcript.updateTurn(id: edit.id, text: edit.text, styles: edit.styles) }
        rendered = transcript
        persist(transcript.turns)
    }

    private struct PendingEdit { let id: UUID; let text: String; let styles: [TextStyleRun] }

    private func takePendingEdits() -> [PendingEdit] {
        defer { dirty = [] }
        guard let storage = textView?.textStorage, let transcript = rendered else { return [] }
        return segments.compactMap { segment in
            guard dirty.contains(segment.id), let turn = transcript.turns.first(where: { $0.id == segment.id }) else { return nil }
            let text = (storage.string as NSString).substring(with: segment.body)
            let styles = styleRuns(in: segment.body)
            guard text != turn.text || styles != (turn.styles ?? []) else { return nil }
            return PendingEdit(id: segment.id, text: text, styles: styles)
        }
    }

    private func persist(_ turns: [SpeakerTurn]) {
        onEdit { $0.turns = turns }
    }

    private func apply(_ new: Transcript, replacing old: Transcript, actionName: String) {
        if !undo.isUndoing && !undo.isRedoing { undo.removeAllActions() }
        persist(new.turns)
        render(new)
        undo.registerUndo(withTarget: self) { target in
            MainActor.assumeIsolated { target.apply(old, replacing: new, actionName: actionName) }
        }
        undo.setActionName(actionName)
    }

    private func flashDeletedToast() {
        showDeletedToast = true
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled else { return }
            self?.showDeletedToast = false
        }
    }

    private func scheduleCommit() {
        commitTask?.cancel()
        commitTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            self?.commit()
        }
    }

    private func normalize(_ segment: Segment) {
        guard let storage = textView?.textStorage, segment.bodyLength > 0 else { return }
        storage.beginEditing()
        storage.enumerateAttributes(in: segment.body) { attributes, range, _ in
            storage.setAttributes(self.bodyAttributes(Self.style(of: attributes)), range: range)
        }
        storage.endEditing()
    }

    private func styleRuns(in range: NSRange) -> [TextStyleRun] {
        guard let storage = textView?.textStorage else { return [] }
        var runs: [TextStyleRun] = []
        storage.enumerateAttributes(in: range) { attributes, found, _ in
            let style = Self.style(of: attributes)
            guard style.bold || style.italic || style.underline else { return }
            let location = found.location - range.location
            if let last = runs.last, last.location + last.length == location,
               last.bold == style.bold, last.italic == style.italic, last.underline == style.underline {
                runs[runs.count - 1].length += found.length
            } else {
                runs.append(TextStyleRun(location: location, length: found.length,
                                         bold: style.bold, italic: style.italic, underline: style.underline))
            }
        }
        return runs
    }

    private static func style(of attributes: [NSAttributedString.Key: Any]) -> TextStyleRun {
        let font = attributes[.font] as? NSFont
        let bold = font.map { $0.fontDescriptor.symbolicTraits.contains(.bold) || $0.fontName.contains("Bold") } ?? false
        let italic = ((attributes[.obliqueness] as? CGFloat) ?? 0) != 0
        let underline = ((attributes[.underlineStyle] as? Int) ?? 0) != 0
        return TextStyleRun(location: 0, length: 0, bold: bold, italic: italic, underline: underline)
    }

    private func refreshFormatState() {
        guard let view = textView, let storage = view.textStorage else { return }
        let selection = view.selectedRange()
        let attributes = selection.length > 0 && selection.location < storage.length
            ? storage.attributes(at: selection.location, effectiveRange: nil)
            : view.typingAttributes
        let style = Self.style(of: attributes)
        if isBold != style.bold { isBold = style.bold }
        if isItalic != style.italic { isItalic = style.italic }
        if isUnderline != style.underline { isUnderline = style.underline }
    }

    private func segmentIndex(containing range: NSRange) -> Int? {
        segments.firstIndex { range.location >= $0.paragraphStart && NSMaxRange(range) <= $0.bodyEnd }
    }
}

extension TranscriptEditor: NSTextViewDelegate, NSTextStorageDelegate {
    func textView(_ view: NSTextView, shouldChangeTextIn range: NSRange, replacementString text: String?) -> Bool {
        if rebuilding { return true }
        guard segments.contains(where: { range.location >= $0.bodyStart && NSMaxRange(range) <= $0.bodyEnd }) else {
            return false
        }
        if let text, text.contains(where: \.isNewline) {
            let flat = text.components(separatedBy: .newlines).filter { !$0.isEmpty }.joined(separator: " ")
            Task { @MainActor in view.insertText(flat, replacementRange: range) }
            return false
        }
        return true
    }

    func textView(_ view: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.cancelOperation(_:)):
            deactivate()
            return true
        default:
            return false
        }
    }

    func undoManager(for view: NSTextView) -> UndoManager? { undo }

    func textViewDidChangeSelection(_ notification: Notification) {
        guard !rebuilding, let view = textView, let storage = view.textStorage else { return }
        let selection = view.selectedRange()
        if let index = segmentIndex(containing: selection) {
            if activeLine?.id != segments[index].id {
                commit()
                setActive(line(at: index))
                view.needsDisplay = true
                let paragraph = segments[index].paragraph
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                    MainActor.assumeIsolated { view.scrollRangeToVisible(paragraph) }
                }
            }
            let body = segments[index].body
            if selection.length == 0 {
                let attributes = selection.location > body.location && selection.location <= storage.length
                    ? storage.attributes(at: selection.location - 1, effectiveRange: nil)
                    : bodyAttributes(TextStyleRun(location: 0, length: 0))
                view.typingAttributes = bodyAttributes(Self.style(of: attributes))
            }
        }
        refreshFormatState()
    }

    func textDidChange(_ notification: Notification) {
        guard !rebuilding else { return }
        for segment in segments where dirty.contains(segment.id) { normalize(segment) }
        textView?.needsDisplay = true
        refreshFormatState()
        scheduleCommit()
    }

    nonisolated func textStorage(_ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions,
                                 range editedRange: NSRange, changeInLength delta: Int) {
        MainActor.assumeIsolated {
            storageEdited(editedRange, delta: editedMask.contains(.editedCharacters) ? delta : 0)
        }
    }

    private func storageEdited(_ range: NSRange, delta: Int) {
        guard !rebuilding else { return }
        let location = range.location
        guard let index = segments.firstIndex(where: { location >= $0.bodyStart && location <= $0.bodyEnd }) else { return }
        dirty.insert(segments[index].id)
        guard delta != 0 else { return }
        segments[index].bodyLength += delta
        for other in segments.indices where other > index {
            segments[other].paragraphStart += delta
            segments[other].bodyStart += delta
        }
    }
}

@MainActor
enum TranscriptDocument {
    static let bodySize: CGFloat = 13
    private static let shortParagraph = paragraphStyle(column: 48)
    private static let longParagraph = paragraphStyle(column: 64)

    static func font(_ weight: String, _ size: CGFloat) -> NSFont {
        NSFont(name: "TikTokSans-\(weight)", size: size) ?? .systemFont(ofSize: size, weight: weight == "Bold" ? .bold : .regular)
    }

    static func paragraphStyle(for transcript: Transcript?) -> NSParagraphStyle {
        (transcript?.turns.last?.start ?? 0) >= 3600 ? longParagraph : shortParagraph
    }

    static func build(_ transcript: Transcript) -> (NSAttributedString, [TranscriptEditor.Segment]) {
        let out = NSMutableAttributedString()
        let turns = transcript.turns
        let speakerIDs = transcript.speakerIDs
        let showHours = (turns.last?.start ?? 0) >= 3600
        let para = paragraphStyle(for: transcript)
        let timeAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .regular),
            .foregroundColor: NSColor.white.withAlphaComponent(0.75),
            .paragraphStyle: para,
        ]
        let nameFont = font("Bold", bodySize)
        var segments: [TranscriptEditor.Segment] = []

        for (index, turn) in turns.enumerated() {
            let paragraphStart = out.length
            let color = NSColor(speakerTint(speakerIDs.firstIndex(of: turn.speakerID) ?? 0))
            out.append(NSAttributedString(string: formatTimecode(turn.start, includeHours: showHours) + "\t",
                                          attributes: timeAttributes))
            out.append(NSAttributedString(string: transcript.name(for: turn.speakerID) + ": ",
                                          attributes: [.font: nameFont, .foregroundColor: color, .paragraphStyle: para]))
            let bodyStart = out.length
            let body = NSMutableAttributedString(string: turn.text,
                                                 attributes: bodyAttributes(TextStyleRun(location: 0, length: 0), para: para))
            for run in turn.styles ?? [] where NSMaxRange(NSRange(location: run.location, length: run.length)) <= body.length {
                body.setAttributes(bodyAttributes(run, para: para), range: NSRange(location: run.location, length: run.length))
            }
            out.append(body)
            segments.append(.init(id: turn.id, paragraphStart: paragraphStart, bodyStart: bodyStart, bodyLength: body.length))
            if index < turns.count - 1 {
                out.append(NSAttributedString(string: "\n",
                                              attributes: bodyAttributes(TextStyleRun(location: 0, length: 0), para: para)))
            }
        }
        return (out, segments)
    }

    static func bodyAttributes(_ style: TextStyleRun, para: NSParagraphStyle) -> [NSAttributedString.Key: Any] {
        var attributes: [NSAttributedString.Key: Any] = [
            .font: font(style.bold ? "Bold" : "Regular", bodySize),
            .foregroundColor: NSColor.white.withAlphaComponent(style.bold ? 1 : 0.9),
            .paragraphStyle: para,
        ]
        if style.italic { attributes[.obliqueness] = CGFloat(0.2) }
        if style.underline { attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue }
        return attributes
    }

    private static func paragraphStyle(column: CGFloat) -> NSParagraphStyle {
        let para = NSMutableParagraphStyle()
        para.lineSpacing = 3
        para.paragraphSpacing = 9
        para.headIndent = column
        para.tabStops = [NSTextTab(textAlignment: .left, location: column)]
        para.defaultTabInterval = column
        para.lineBreakMode = .byWordWrapping
        return para
    }
}

private extension TextStyleRun {
    func has(_ trait: TextTrait) -> Bool {
        switch trait {
        case .bold: bold
        case .italic: italic
        case .underline: underline
        }
    }

    mutating func toggle(_ trait: TextTrait, on: Bool) {
        switch trait {
        case .bold: bold = on
        case .italic: italic = on
        case .underline: underline = on
        }
    }
}

final class TranscriptTextView: NSTextView {
    weak var editor: TranscriptEditor?

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        guard let editor, let range = editor.activeParagraphRange,
              let manager = layoutManager, let container = textContainer else { return }
        let glyphs = manager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        var box = NSRect.null
        manager.enumerateLineFragments(forGlyphRange: glyphs) { _, used, _, _, _ in box = box.union(used) }
        if box.isNull { box = manager.extraLineFragmentUsedRect }
        guard !box.isNull else { return }
        let origin = textContainerOrigin
        box = NSRect(x: origin.x - 10, y: box.minY + origin.y - 5,
                     width: container.size.width + 20, height: box.height + 10)
        NSColor.white.withAlphaComponent(0.07).setFill()
        NSBezierPath(roundedRect: box, xRadius: 8, yRadius: 8).fill()
        editor.activeColor.withAlphaComponent(0.9).setFill()
        NSBezierPath(roundedRect: NSRect(x: box.minX, y: box.minY + 5, width: 2.5, height: box.height - 10),
                     xRadius: 1.25, yRadius: 1.25).fill()
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self, let editor else { return super.performKeyEquivalent(with: event) }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        switch (flags, event.charactersIgnoringModifiers?.lowercased()) {
        case ([.command], "b"): editor.toggle(.bold); return true
        case ([.command], "i"): editor.toggle(.italic); return true
        case ([.command], "u"): editor.toggle(.underline); return true
        case ([.command], "z"): editor.undoLastChange(); return true
        case ([.command, .shift], "z"): editor.redoLastChange(); return true
        default: return super.performKeyEquivalent(with: event)
        }
    }
}

struct TranscriptDocumentView: NSViewRepresentable {
    let editor: TranscriptEditor
    let transcript: Transcript
    let bottomInset: CGFloat

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.automaticallyAdjustsContentInsets = false

        let view = TranscriptTextView()
        view.editor = editor
        view.delegate = editor
        view.textStorage?.delegate = editor
        view.isEditable = true
        view.isSelectable = true
        view.isRichText = true
        view.importsGraphics = false
        view.allowsUndo = true
        view.isAutomaticLinkDetectionEnabled = false
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.isContinuousSpellCheckingEnabled = false
        view.drawsBackground = false
        view.backgroundColor = .clear
        view.insertionPointColor = .white
        view.textContainerInset = NSSize(width: 20, height: 16)
        view.textContainer?.lineFragmentPadding = 0
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.textContainer?.widthTracksTextView = true
        editor.textView = view

        scroll.documentView = view
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        if scroll.contentInsets.bottom != bottomInset {
            scroll.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: bottomInset, right: 0)
        }
        editor.show(transcript)
    }
}
