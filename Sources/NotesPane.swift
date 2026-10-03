import SwiftUI

struct NotesPane: View {
    @Bindable var model: AppModel
    let editor: NotesEditor

    var body: some View {
        if model.notesView == .library {
            MyNotes(model: model, editor: editor)
        } else {
            NoteEditorPane(model: model, editor: editor)
        }
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

