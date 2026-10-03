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
            HStack { Spacer(minLength: 0); corner }
                .frame(height: AppModel.notesFooter, alignment: .top)
        }
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.2), value: model.notesEditing)
    }

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

