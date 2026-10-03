import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct MyNotes: View {
    @Bindable var model: AppModel
    let editor: NotesEditor

    var body: some View {
        let library = editor.library
        VStack(spacing: 0) {
            header(library)
            if library.notes.isEmpty {
                Text("No saved notes.")
                    .font(tiktok(13))
                    .foregroundStyle(.white.opacity(0.34))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(library.sorted) { note in
                            Row(note: note, library: library, current: note.id == library.currentNote?.id,
                                open: { open(note) }, menu: { items(for: note) })
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 10)
                }
                .scrollIndicators(.visible)
            }
        }
        .foregroundStyle(.white.opacity(0.9))
    }

    private func header(_ library: NotesLibrary) -> some View {
        HStack(spacing: 8) {
            Action(symbol: "chevron.left", tip: "Back to the note") { model.notesView = .editor }
            Text("My notes").font(tiktok(13, "Medium"))
            Spacer()
            Action(symbol: "square.and.pencil", tip: "New note") {
                editor.run(.newNote)
                model.notesView = .editor
            }
            Action(symbol: "folder", tip: "Open folder") { NSWorkspace.shared.open(library.folder) }
            Action(symbol: "square.and.arrow.up", tip: "Export all") { exportAll(library) }
        }
        .padding(.horizontal, 12)
        .padding(.top, 12)
        .padding(.bottom, 6)
    }

    private func open(_ note: SavedNote) {
        editor.library.open(note.id)
        model.notesView = .editor
    }

    private func items(for note: SavedNote) -> [MenuItem] {
        let library = editor.library
        return [
            MenuItem(id: "open", title: "Open", symbol: "doc.text") { open(note) },
            MenuItem(id: "rename", title: "Rename", symbol: "pencil") { library.naming = note.id },
            MenuItem(id: "favorite", title: "Favourite", symbol: "star", checked: note.favorite) {
                library.toggleFavorite(note.id)
            },
            MenuItem(id: "export", title: "Export…", symbol: "square.and.arrow.up") { export(note, library) },
            MenuItem(id: "finder", title: "Show in Finder", symbol: "folder") {
                NSWorkspace.shared.activateFileViewerSelecting([library.url(of: note)])
            },
            .separator(),
            MenuItem(id: "delete", title: "Delete", symbol: "trash", destructive: true) { library.delete(note.id) },
        ]
    }

    private func export(_ note: SavedNote, _ library: NotesLibrary) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = note.file
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? library.export(note, to: url)
    }

    private func exportAll(_ library: NotesLibrary) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Export"
        panel.message = "Export notes to"
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? library.exportAll(to: url.appendingPathComponent("Iridium Live Notes"))
    }

    private struct Row: View {
        let note: SavedNote
        let library: NotesLibrary
        let current: Bool
        let open: () -> Void
        let menu: @MainActor () -> [MenuItem]
        @State private var hovering = false

        var body: some View {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        if library.naming == note.id {
                            NoteNameField(library: library, note: note, width: 180)
                        } else {
                            Text(note.name)
                                .font(tiktok(13, "Medium"))
                                .lineLimit(1)
                                .onTapGesture(count: 2) { library.naming = note.id }
                        }
                        if note.favorite {
                            Image(systemName: "star.fill").font(.system(size: 8)).foregroundStyle(.white.opacity(0.55))
                        }
                    }
                    Text(note.preview.isEmpty ? "Empty" : note.preview)
                        .font(tiktok(11.5))
                        .foregroundStyle(.white.opacity(note.preview.isEmpty ? 0.25 : 0.45))
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Text(when(note.modified))
                    .font(tiktok(10.5))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.38))
                HStack(spacing: 2) {
                    Action(symbol: note.favorite ? "star.fill" : "star", tip: "Favourite") {
                        library.toggleFavorite(note.id)
                    }
                    Action(symbol: "trash", tip: "Delete") { library.delete(note.id) }
                }
                .opacity(hovering ? 1 : 0)
                .allowsHitTesting(hovering)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(.white.opacity(current ? 0.07 : hovering ? 0.05 : 0)))
            .contentShape(Rectangle())
            .onTapGesture { if library.naming != note.id { open() } }
            .onHover { hovering = $0 }
            .onRightClick(menu)
            .animation(.easeOut(duration: 0.12), value: hovering)
        }

        private func when(_ date: Date) -> String {
            Calendar.current.isDateInToday(date)
                ? date.formatted(date: .omitted, time: .shortened)
                : date.formatted(.dateTime.day().month(.abbreviated))
        }
    }

    private struct Action: View {
        let symbol: String
        let tip: String
        let action: () -> Void
        @State private var hovering = false

        var body: some View {
            Button(action: action) {
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(hovering ? 0.95 : 0.5))
                    .frame(width: 20, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .tip(tip)
        }
    }
}

