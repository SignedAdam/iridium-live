import SwiftUI

/// The notes pane: the editor, a placeholder while empty, the outline of the text area while you edit, and a slim
/// indicator of where you are whenever there is more text than fits.
struct NotesPane: View {
    @Bindable var model: AppModel
    let editor: NotesEditor

    var body: some View {
        let outline = RoundedRectangle(cornerRadius: 12, style: .continuous)
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
            .animation(.easeOut(duration: 0.2), value: model.notesEditing)
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
