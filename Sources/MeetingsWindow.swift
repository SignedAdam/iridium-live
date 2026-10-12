import AppKit
import SwiftUI
@preconcurrency import MeetingKit

@MainActor
enum MeetingsWindow {
    private static var open: NSWindow?
    private static var keeper: MeetingsWindowDelegate?
    static let frameName = "IridiumMeetingsWindow"
    static var escape: (@MainActor () -> Bool)?

    static func show(on screen: NSScreen, model: AppModel, meetings: MeetingsModel, select id: UUID? = nil) {
        if let id { meetings.selectedID = id }
        if let open {
            NSApp.activate(ignoringOtherApps: true)
            open.makeKeyAndOrderFront(nil)
            return
        }
        let size = NSSize(width: 1180, height: 760)
        let area = screen.visibleFrame
        let window = MeetingsPanel(contentRect: NSRect(x: (area.midX - size.width / 2).rounded(),
                                                       y: (area.midY - size.height / 2).rounded(),
                                                       width: size.width, height: size.height),
                                   styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                                   backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.title = "Meetings"
        window.isOpaque = false
        window.isReleasedWhenClosed = false
        window.backgroundColor = .clear
        window.isMovableByWindowBackground = true
        window.appearance = NSAppearance(named: .darkAqua)
        window.minSize = NSSize(width: 900, height: 600)
        window.collectionBehavior = [.fullScreenNone]
        if !window.setFrameUsingName(frameName) { window.setFrame(window.frame, display: false) }
        window.setFrameAutosaveName(frameName)
        let host = NSHostingView(rootView: MeetingsView(model: model, meetings: meetings))
        host.sizingOptions = []
        window.contentView = host
        let delegate = MeetingsWindowDelegate()
        window.delegate = delegate
        keeper = delegate
        open = window

        let target = window.frame
        window.setFrame(target.offsetBy(dx: 0, dy: -8), display: false)
        window.alphaValue = 0
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            window.animator().alphaValue = Look.shared.opacity
            window.animator().setFrame(target, display: true)
        }
        followLook(window)
    }

    static func close() {
        open?.close()
        open?.delegate = nil
        open = nil
        keeper = nil
        escape = nil
    }

    static func fadeOut(_ window: NSWindow) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            window.animator().alphaValue = 0
        } completionHandler: {
            MainActor.assumeIsolated { close() }
        }
    }
}

private final class MeetingsPanel: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func cancelOperation(_ sender: Any?) {
        if MainActor.assumeIsolated({ MeetingsWindow.escape?() }) == true { return }
        performClose(nil)
    }
}

private final class MeetingsWindowDelegate: NSObject, NSWindowDelegate {
    private var leaving = false

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard !leaving else { return true }
        leaving = true
        MainActor.assumeIsolated { MeetingsWindow.fadeOut(sender) }
        return false
    }
}

struct MeetingsView: View {
    let model: AppModel
    let meetings: MeetingsModel
    let ui: MeetingsUI
    @State private var query = ""
    @State private var archived = false

    init(model: AppModel, meetings: MeetingsModel, ui: MeetingsUI = MeetingsUI()) {
        self.model = model
        self.meetings = meetings
        self.ui = ui
    }

    private var shown: [Meeting] {
        let wanted = query.trimmingCharacters(in: .whitespaces)
        return meetings.meetings.filter { meeting in
            meeting.isArchived == archived
                && (wanted.isEmpty || meeting.searchableText.localizedCaseInsensitiveContains(wanted))
        }
    }

    private var selected: Meeting? {
        guard let id = meetings.selectedID else { return nil }
        return meetings.meetings.first { $0.id == id }
    }

    var body: some View {
        ZStack {
            Glass(cornerRadius: 12)
            VStack(spacing: 0) {
                titleBar
                line
                HStack(spacing: 0) {
                    sidebar.frame(width: 312)
                    Rectangle().fill(.white.opacity(0.08)).frame(width: 1)
                    detail.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            if let meeting = selected {
                MeetingOverlays(meeting: meeting, meetings: meetings, ui: ui)
            }
        }
        .ignoresSafeArea()
        .font(tiktok(12))
        .foregroundStyle(.white.opacity(0.9))
        .overlayPreferenceValue(TipKey.self) { tips in
            TipLayer(tips: tips, bar: 0...0, barOnTop: true)
        }
    }

    private var line: some View {
        Rectangle().fill(.white.opacity(0.08)).frame(height: 1)
    }

    private var titleBar: some View {
        HStack(spacing: 10) {
            Text("Meetings")
                .font(tiktok(15, "Medium"))
                .foregroundStyle(.white.opacity(0.95))
            Text("\(shown.count)")
                .font(tiktok(11.5, "Medium"))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.78))
                .padding(.horizontal, 7)
                .frame(height: 18)
                .background(Pill(fill: 0.07))
            Spacer(minLength: 0)
        }
        .padding(.leading, 76)
        .padding(.trailing, 14)
        .frame(height: 40)
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.6))
                TextField("Search meetings", text: $query)
                    .textFieldStyle(.plain)
                    .font(tiktok(13))
                if !query.isEmpty {
                    Button { query = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.6))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(.white.opacity(0.08)))
            .padding(.horizontal, 12)
            .padding(.top, 12)

            Segments(selection: $archived, options: [(false, "Active"), (true, "Archived")])
                .padding(.horizontal, 12)
                .padding(.top, 8)
                .padding(.bottom, 4)

            if shown.isEmpty {
                empty
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2, pinnedViews: .sectionHeaders) {
                        ForEach(days, id: \.day) { group in
                            Section {
                                ForEach(group.meetings) { meeting in
                                    MeetingRow(meeting: meeting,
                                               selected: meetings.selectedID == meeting.id,
                                               progress: meetings.progress[meeting.id],
                                               select: { meetings.selectedID = meeting.id },
                                               items: { rowItems(meeting) })
                                }
                            } header: {
                                Text(group.title.uppercased())
                                    .kerning(0.8)
                                    .font(tiktok(10.5, "Medium"))
                                    .foregroundStyle(.white.opacity(0.78))
                                    .padding(.horizontal, 10)
                                    .padding(.top, 10)
                                    .padding(.bottom, 4)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 12)
                }
                .scrollIndicators(.visible)
            }
        }
    }

    private var empty: some View {
        VStack(spacing: 8) {
            Image(systemName: archived ? "archivebox" : "waveform")
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(.white.opacity(0.8))
            Text(emptyTitle)
                .font(tiktok(13, "Medium"))
                .foregroundStyle(.white.opacity(0.92))
            Text(emptyText)
                .font(tiktok(12))
                .foregroundStyle(.white.opacity(0.78))
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyTitle: String {
        if !query.trimmingCharacters(in: .whitespaces).isEmpty { return "Nothing matches" }
        return archived ? "No archived meetings" : "No meetings yet"
    }

    private var emptyText: String {
        if !query.trimmingCharacters(in: .whitespaces).isEmpty { return "Try another word from a title or transcript." }
        return archived ? "Archived meetings show up here." : "Record a meeting to see it here."
    }

    @ViewBuilder private var detail: some View {
        if let meeting = selected {
            MeetingDetail(meeting: meeting, meetings: meetings, ui: ui).id(meeting.id)
        } else {
            VStack(spacing: 12) {
                Image(systemName: "waveform")
                    .font(.system(size: 28, weight: .light))
                    .foregroundStyle(.white.opacity(0.8))
                Text("Select a meeting")
                    .font(tiktok(15, "Medium"))
                    .foregroundStyle(.white.opacity(0.95))
                Text("Pick a recording to see its transcript, summary, actions and chat.")
                    .font(tiktok(12.5))
                    .foregroundStyle(.white.opacity(0.78))
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var days: [(day: Date, title: String, meetings: [Meeting])] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: shown) { calendar.startOfDay(for: $0.startedAt) }
        return grouped.keys.sorted(by: >).map { day in
            (day, dayTitle(day), grouped[day]!.sorted { $0.startedAt > $1.startedAt })
        }
    }

    private func dayTitle(_ day: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return "Today" }
        if calendar.isDateInYesterday(day) { return "Yesterday" }
        if let days = calendar.dateComponents([.day], from: day, to: Date()).day, days < 7 {
            return day.formatted(.dateTime.weekday(.wide))
        }
        return day.formatted(.dateTime.day().month(.wide).year())
    }

    private func rowItems(_ meeting: Meeting) -> [MenuItem] {
        var items: [MenuItem] = [
            MenuItem(id: "open", title: "Open", symbol: "arrow.up.right.square",
                     action: { meetings.selectedID = meeting.id }),
            MenuItem(id: "transcribe", title: meeting.state == .done ? "Re-transcribe" : "Transcribe",
                     symbol: "text.viewfinder", action: { meetings.transcribe(meeting.id) }),
            MeetingEngines.chooserItem(for: meeting) { meetings.transcribe(meeting.id, engineID: $0) },
        ]
        if meeting.state == .done, meetings.canSummarize {
            items.append(MenuItem(id: "summarize", title: "Summarize", symbol: "sparkles",
                                  action: { meetings.summarize(meeting.id) }))
        }
        if meeting.transcript != nil {
            items.append(MenuItem(id: "copy", title: "Copy transcript", symbol: "doc.on.doc", action: {
                guard let text = meetings.copyText(meeting.id) else { return }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }))
            items.append(.separator())
            for format in TranscriptExportFormat.allCases {
                items.append(MenuItem(id: "export." + format.rawValue, title: "Export \(format.displayName)",
                                      symbol: "square.and.arrow.up", action: { exportMeeting(meeting, as: format) }))
            }
        }
        items.append(.separator())
        items.append(MenuItem(id: "reveal", title: "Reveal in Finder", symbol: "folder", action: {
            guard let folder = meetings.folderURL(meeting.id) else { return }
            NSWorkspace.shared.activateFileViewerSelecting([folder])
        }))
        items.append(MenuItem(id: "archive", title: meeting.isArchived ? "Unarchive" : "Archive",
                              symbol: meeting.isArchived ? "tray.and.arrow.up" : "archivebox",
                              action: { meetings.setArchived(meeting.id, !meeting.isArchived) }))
        items.append(MenuItem(id: "delete", title: "Delete", symbol: "trash", destructive: true,
                              action: { meetings.delete(meeting.id) }))
        return items
    }

    private func exportMeeting(_ meeting: Meeting, as format: TranscriptExportFormat) {
        MeetingExport.save(meeting.id, as: format, meetings: meetings)
    }
}

private struct MeetingRow: View {
    let meeting: Meeting
    let selected: Bool
    let progress: Double?
    let select: @MainActor () -> Void
    let items: @MainActor () -> [MenuItem]
    @State private var hovering = false

    var body: some View {
        Button(action: select) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(meeting.title)
                        .font(tiktok(13, "Medium"))
                        .foregroundStyle(.white.opacity(0.95))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if meeting.hasMic {
                        Image(systemName: "mic.fill").font(.system(size: 9)).foregroundStyle(.white.opacity(0.8))
                    }
                    if meeting.hasSystem {
                        Image(systemName: "speaker.wave.2.fill").font(.system(size: 9)).foregroundStyle(.white.opacity(0.8))
                    }
                }
                HStack(spacing: 8) {
                    Text(meeting.startedAt.formatted(date: .omitted, time: .shortened))
                        .monospacedDigit()
                    Text(formatTimecode(meeting.duration))
                        .monospacedDigit()
                    Spacer(minLength: 4)
                    Text(stateText)
                        .foregroundStyle(meeting.state == .failed ? accent : .white.opacity(0.78))
                }
                .font(tiktok(11.5))
                .foregroundStyle(.white.opacity(0.78))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(.white.opacity(selected ? 0.12 : hovering ? 0.06 : 0))
                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(.white.opacity(selected ? 0.18 : 0))))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .onRightClick { items() }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }

    private var stateText: String {
        switch meeting.state {
        case .done: "Transcribed"
        case .running: progress.map { "Transcribing \(Int($0 * 100))%" } ?? "Transcribing"
        case .failed: "Failed"
        case .none: "Not transcribed"
        }
    }
}
