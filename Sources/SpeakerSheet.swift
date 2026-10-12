import AppKit
import SwiftUI
@preconcurrency import MeetingKit

struct SpeakerSheet: View {
    let meeting: Meeting
    let meetings: MeetingsModel
    let close: @MainActor () -> Void
    @State private var names: [String: String] = [:]
    @State private var merges: [String: String] = [:]

    var body: some View {
        ZStack {
            Color.black.opacity(0.45)
                .ignoresSafeArea()
                .onTapGesture { close() }
            card
                .frame(width: 480)
                .glass(16)
        }
        .onAppear { names = meeting.speakerNames }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Speakers")
                .font(tiktok(15, "Medium"))
                .foregroundStyle(.white.opacity(0.95))
            Text("Rename speakers, or merge one the transcription split off by mistake into the right person.")
                .font(tiktok(12))
                .foregroundStyle(.white.opacity(0.78))
                .fixedSize(horizontal: false, vertical: true)
            if let transcript = meeting.transcript {
                let ids = transcript.speakerIDs
                VStack(spacing: 8) {
                    ForEach(Array(ids.enumerated()), id: \.element) { index, id in
                        row(id: id, index: index, ids: ids, transcript: transcript)
                    }
                }
            }
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                Button("Cancel") { close() }
                    .buttonStyle(GlassButton())
                Button("Save") { save() }
                    .buttonStyle(AccentButton())
            }
        }
        .padding(20)
    }

    private func row(id: String, index: Int, ids: [String], transcript: Transcript) -> some View {
        HStack(spacing: 9) {
            Circle().fill(speakerTint(index)).frame(width: 10, height: 10)
            VStack(alignment: .leading, spacing: 1) {
                Text(id)
                    .font(tiktok(11.5))
                    .foregroundStyle(.white.opacity(0.9))
                    .lineLimit(1)
                Text(lineCount(id, in: transcript))
                    .font(tiktok(10.5))
                    .foregroundStyle(.white.opacity(0.78))
            }
            .frame(width: 92, alignment: .leading)
            if let target = merges[id] {
                Text("Merges into \(label(target))")
                    .font(tiktok(12.5))
                    .foregroundStyle(.white.opacity(0.9))
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button("Keep") { merges[id] = nil }
                    .buttonStyle(GlassButton())
            } else {
                TextField(id, text: Binding(get: { names[id] ?? "" }, set: { names[id] = $0 }))
                    .textFieldStyle(.plain)
                    .font(tiktok(12.5))
                    .foregroundStyle(.white.opacity(0.95))
                    .padding(.horizontal, 9)
                    .frame(height: 26)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.white.opacity(0.08))
                        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.white.opacity(0.1))))
                    .frame(maxWidth: .infinity)
                mergeButton(id: id, ids: ids)
            }
        }
    }

    private func mergeButton(id: String, ids: [String]) -> some View {
        let targets = ids.filter { $0 != id && merges[$0] == nil }
        return Button("Merge") {
            let items = targets.map { target in
                MenuItem(id: target, title: "Into \(label(target))", action: { stageMerge(id, into: target) })
            }
            guard !items.isEmpty else { return }
            MenuPanel.show(items, at: NSEvent.mouseLocation)
        }
        .buttonStyle(GlassButton())
        .disabled(targets.isEmpty)
    }

    private func label(_ id: String) -> String {
        let name = names[id]?.trimmingCharacters(in: .whitespaces) ?? ""
        return name.isEmpty ? id : name
    }

    private func lineCount(_ id: String, in transcript: Transcript) -> String {
        let count = transcript.turns.filter { $0.speakerID == id }.count
        return count == 1 ? "1 line" : "\(count) lines"
    }

    private func stageMerge(_ source: String, into target: String) {
        for (from, to) in merges where to == source { merges[from] = target }
        merges[source] = target
    }

    private func save() {
        applySpeakerEdits(names: names, merges: merges, in: meeting.id, meetings: meetings)
        close()
    }
}

@MainActor
func applySpeakerEdits(names: [String: String], merges: [String: String], in id: UUID, meetings: MeetingsModel) {
    for (source, target) in merges { meetings.mergeSpeaker(source, into: target, in: id) }
    for (speaker, name) in names where merges[speaker] == nil { meetings.renameSpeaker(speaker, to: name, in: id) }
}
