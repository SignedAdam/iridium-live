import SwiftUI

/// The notes pane: the note being edited, or the list of saved notes once "My notes" is open.
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

/// The note being edited: the editor, a placeholder while empty, the outline of the text area while you edit, a slim
/// indicator of where you are whenever there is more text than fits, and, in a slim footer of its own under the text,
/// the note's name and the way into "My notes".
struct NoteEditorPane: View {
    @Bindable var model: AppModel
    let editor: NotesEditor
    @State private var hovering = false

    var body: some View {
        let outline = RoundedRectangle(cornerRadius: 12, style: .continuous)
        VStack(spacing: 0) {
            NotesEditorView(editor: editor)
                .background {
                    outline.fill(.white.opacity(model.notesEditing ? 0.045 : 0))
                        .overlay(outline.strokeBorder(.white.opacity(model.notesEditing ? 0.22 : 0), lineWidth: 1))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                }
                .overlay(alignment: .topLeading) {
                    if model.notesEmpty {
                        Text("Speak for notes")
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
            HStack { Spacer(minLength: 0); corner }
                .frame(height: AppModel.notesFooter, alignment: .top)
        }
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.2), value: model.notesEditing)
    }

    /// The name of the note, dim, with the way into the saved notes beside it once the pointer is here. While a note
    /// has just been saved its name is a field instead, ready to be typed over.
    private var corner: some View {
        let library = editor.library
        let naming = library.naming.flatMap { library.note($0) }
        return HStack(spacing: 5) {
            if let naming {
                NoteNameField(library: library, note: naming)
            } else {
                Text(library.currentName)
                    .font(tiktok(10.5, "Medium"))
                    .foregroundStyle(.white.opacity(hovering ? 0.5 : 0.28))
                    .lineLimit(1)
            }
            Image(systemName: "list.bullet")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white.opacity(0.75))
                .frame(width: 18, height: 16)
                .contentShape(Rectangle())
                .onTapGesture { model.showMyNotes() }
                .tip("My notes")
                .opacity(hovering || naming != nil ? 1 : 0)
                .allowsHitTesting(hovering || naming != nil)
        }
        .padding(.leading, 7)
        .padding(.trailing, 3)
        .background(Capsule().fill(.black.opacity(hovering || naming != nil ? 0.22 : 0)))
        .padding(.trailing, 11)
        .animation(.easeOut(duration: 0.14), value: hovering)
    }
}

/// Names a note the moment it is made: focused with its name whole, so typing replaces it. Return or clicking away
/// keeps what was typed, Escape leaves the name as it was.
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

/// A slim thumb on the right edge: how much of the text is visible and where. Only there when the text overflows.
struct ScrollIndicator: View {
    let metrics: ScrollMetrics

    var body: some View {
        GeometryReader { geometry in
            let track = geometry.size.height
            let thumb = max(18, track * metrics.visibleFraction)
            Capsule().fill(.white.opacity(0.38))
                .frame(width: 3, height: thumb)
                .offset(y: (track - thumb) * metrics.position)
        }
        .frame(width: 3)
        .opacity(metrics.overflows ? 1 : 0)
        .animation(.easeOut(duration: 0.2), value: metrics.overflows)
        .allowsHitTesting(false)
    }
}
