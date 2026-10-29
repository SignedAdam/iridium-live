import SwiftUI

struct NotesPane: View {
    @Bindable var model: AppModel
    let editor: NotesEditor

    var body: some View {
        Group {
            if model.notesView == .library {
                MyNotes(model: model, editor: editor)
            } else {
                NoteEditorPane(model: model, editor: editor)
            }
        }
        .overlay(alignment: .bottom) {
            if let notice = editor.filing.notice {
                FilingNotice(notice: notice, filing: editor.filing).padding(.bottom, 8)
            }
        }
        .animation(.easeOut(duration: 0.18), value: editor.filing.notice)
    }
}

struct NoteEditorPane: View {
    @Bindable var model: AppModel
    let editor: NotesEditor

    var body: some View {
        let outline = RoundedRectangle(cornerRadius: 12, style: .continuous)
        VStack(spacing: 0) {
            NoteNameHeader(model: model, library: editor.library, saveAs: editor.save(named:))
                .frame(height: AppModel.notesHeader)
            NotesEditorView(editor: editor)
                .background {
                    outline.fill(.white.opacity(model.notesEditing ? 0.045 : 0))
                        .overlay(outline.strokeBorder(.white.opacity(model.notesEditing ? 0.22 : 0), lineWidth: 1))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                }
                .overlay(alignment: .topLeading) {
                    if model.notesEmpty {
                        Text("Dictate or type")
                            .font(tiktok(15))
                            .foregroundStyle(.white.opacity(0.34))
                            .padding(.leading, NotesEditor.inset.width + 5)
                            .padding(.top, NotesEditor.inset.height)
                            .allowsHitTesting(false)
                    }
                }
                .overlay(alignment: .trailing) {
                    ScrollIndicator(metrics: model.notesScroll)
                        .padding(.trailing, 5)
                        .padding(.vertical, 12)
                }
                .frame(height: model.notesHeight)
        }
        .animation(.easeOut(duration: 0.2), value: model.notesEditing)
    }
}

struct NoteNameHeader: View {
    let model: AppModel
    let library: NotesLibrary
    let saveAs: (String) -> Void
    @State private var name = ""
    @State private var hovering = false
    @State private var buttonHover = false
    @FocusState private var focused: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
        let framed = hovering || focused
        return HStack(spacing: 7) {
            TextField("", text: $name)
                .textFieldStyle(.plain)
                .font(tiktok(13, "Medium"))
                .foregroundStyle(.white.opacity(0.92))
                .lineLimit(1)
                .focused($focused)
                .padding(.horizontal, 7)
                .frame(height: 24)
                .background {
                    shape.fill(.white.opacity(framed ? (focused ? 0.13 : 0.07) : 0))
                        .overlay(shape.strokeBorder(.white.opacity(framed ? (focused ? 0.22 : 0.12) : 0), lineWidth: 1))
                }
                .onHover { hovering = $0 }
                .onSubmit { focused = false }
                .onExitCommand { cancel() }
                .onChange(of: focused) { _, now in if !now { commit() } }
            if let note = library.currentNote {
                NoteTags(note: note, library: library)
            }
            Image(systemName: "books.vertical")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white.opacity(buttonHover ? 1 : 0.75))
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
                .onTapGesture { model.showMyNotes() }
                .onHover { buttonHover = $0 }
                .tip("My notes")
        }
        .padding(.leading, 14)
        .padding(.trailing, 10)
        .padding(.top, 6)
        .onAppear {
            name = library.currentName
            claim()
        }
        .onChange(of: library.currentName) { _, now in if !focused { name = now } }
        .onChange(of: library.naming) { _, _ in claim() }
        .animation(.easeOut(duration: 0.12), value: framed)
    }

    private func claim() {
        guard let naming = library.naming, naming == library.currentNote?.id else { return }
        name = library.currentName
        focused = true
    }

    private func cancel() {
        name = library.currentName
        release()
        focused = false
    }

    private func commit() {
        guard let note = library.currentNote else {
            let typed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            if !typed.isEmpty, typed != library.currentName { saveAs(typed) }
            name = library.currentName
            release()
            return
        }
        release()
        library.rename(note.id, to: name)
        name = library.currentName
    }

    private func release() {
        if library.naming == library.currentNote?.id { library.naming = nil }
    }
}

struct NoteNameField: View {
    let library: NotesLibrary
    let note: SavedNote
    var width: CGFloat = 132
    @State private var name = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField("", text: $name)
            .textFieldStyle(.plain)
            .font(tiktok(11, "Medium"))
            .foregroundStyle(.white.opacity(0.95))
            .focused($focused)
            .frame(width: width)
            .padding(.horizontal, 7)
            .frame(height: 19)
            .background(Capsule().fill(.white.opacity(0.12)).overlay(Capsule().strokeBorder(.white.opacity(0.18))))
            .onAppear {
                name = note.name
                focused = true
            }
            .onSubmit { commit() }
            .onExitCommand { library.naming = nil }
            .onChange(of: focused) { _, now in if !now { commit() } }
    }

    private func commit() {
        guard library.naming == note.id else { return }
        library.rename(note.id, to: name)
        library.naming = nil
    }
}

struct ScrollIndicator: View {
    let metrics: ScrollMetrics

    var body: some View {
        GeometryReader { geometry in
            let track = geometry.size.height
            let thumb = max(18, track * metrics.visibleFraction)
            Capsule().fill(.white.opacity(0.55))
                .frame(width: 3, height: thumb)
                .offset(y: (track - thumb) * metrics.position)
        }
        .frame(width: 3)
        .opacity(metrics.overflows ? 1 : 0)
        .animation(.easeOut(duration: 0.2), value: metrics.overflows)
        .allowsHitTesting(false)
    }
}

/// The tags of one note as chips, with add, rename and remove.
struct NoteTags: View {
    let note: SavedNote
    let library: NotesLibrary
    var limit = 3
    @State private var adding = false
    @State private var renaming: String?
    @State private var typed = ""
    @State private var hovering = false
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(note.tags.prefix(limit)), id: \.self) { tag in
                if renaming == tag {
                    field(for: tag)
                } else {
                    Chip(tag: tag, onRemove: { library.removeTag(tag, from: note.id) })
                        .onTapGesture(count: 2) { start(renaming: tag) }
                }
            }
            if note.tags.count > limit {
                Text("+\(note.tags.count - limit)")
                    .font(tiktok(10))
                    .foregroundStyle(.white.opacity(0.6))
            }
            if adding {
                field(for: nil)
            } else if hovering || note.tags.isEmpty {
                Button { start(renaming: nil) } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.white.opacity(0.7))
                        .frame(width: 16, height: 16)
                        .background(Circle().fill(.white.opacity(0.1)))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .tip("Add a tag")
            }
        }
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }

    private func field(for tag: String?) -> some View {
        TextField("", text: $typed)
            .textFieldStyle(.plain)
            .font(tiktok(10.5, "Medium"))
            .foregroundStyle(.white.opacity(0.95))
            .focused($focused)
            .frame(width: 72)
            .padding(.horizontal, 7)
            .frame(height: 17)
            .background(Capsule().fill(.white.opacity(0.14)).overlay(Capsule().strokeBorder(.white.opacity(0.2))))
            .onSubmit { commit(tag) }
            .onExitCommand { stop() }
            .onChange(of: focused) { _, now in if !now { commit(tag) } }
            .onAppear { focused = true }
    }

    private func start(renaming tag: String?) {
        typed = tag ?? ""
        renaming = tag
        adding = tag == nil
    }

    private func commit(_ tag: String?) {
        let name = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty {
            if let tag { library.renameTag(tag, to: name, on: note.id) } else { library.addTag(name, to: note.id) }
        }
        stop()
    }

    private func stop() {
        adding = false
        renaming = nil
        typed = ""
    }

    private struct Chip: View {
        let tag: String
        let onRemove: () -> Void
        @State private var hovering = false

        var body: some View {
            HStack(spacing: 3) {
                Text(tag)
                    .font(tiktok(10.5, "Medium"))
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(1)
                if hovering {
                    Button(action: onRemove) {
                        Image(systemName: "xmark").font(.system(size: 7, weight: .bold))
                            .foregroundStyle(.white.opacity(0.8))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 7)
            .frame(height: 17)
            .background(Capsule().fill(.white.opacity(hovering ? 0.16 : 0.1))
                .overlay(Capsule().strokeBorder(.white.opacity(0.12))))
            .contentShape(Capsule())
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.12), value: hovering)
        }
    }
}

/// Says where a note take was filed and offers one undo.
struct FilingNotice: View {
    let notice: NoteFiling.Notice
    let filing: NoteFiling

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "tray.and.arrow.down")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white.opacity(0.8))
            Text(notice.text)
                .font(tiktok(11.5, "Medium"))
                .foregroundStyle(.white.opacity(0.92))
                .lineLimit(1)
            if notice.undoable {
                Button("Undo") { filing.undo() }
                    .buttonStyle(.plain)
                    .font(tiktok(11.5, "Medium"))
                    .foregroundStyle(accent)
                Button { filing.dismiss() } label: {
                    Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.white.opacity(0.6))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 26)
        .background(Capsule().fill(.black.opacity(0.82))
            .overlay(Capsule().strokeBorder(.white.opacity(0.16))))
        .transition(.opacity)
    }
}

