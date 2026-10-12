import AppKit
import Observation
import SwiftUI

struct MenuItem: Identifiable {
    let id: String
    var title: String
    var symbol: String? = nil
    var shortcut: String? = nil
    var destructive = false
    var enabled = true
    var checked = false
    var detail: (@MainActor () -> AnyView)? = nil
    var action: @MainActor () -> Void
    var isSeparator = false

    static func separator() -> MenuItem {
        MenuItem(id: "separator." + UUID().uuidString, title: "", action: {}, isSeparator: true)
    }
}

@MainActor
@Observable
final class MenuHover {
    var id: String?
}

@MainActor
enum MenuPanel {
    static let hovered = MenuHover()
    private static let edge: CGFloat = 6
    private static var panel: NSPanel?
    private static var card: NSPanel?
    private static var monitors: [Any] = []
    private static var observers: [NSObjectProtocol] = []
    private static var spaceObserver: NSObjectProtocol?

    static func show(_ items: [MenuItem], at screenPoint: NSPoint) {
        present(items, near: screenPoint) { size, area in
            var x = screenPoint.x
            var y = screenPoint.y - size.height
            if x + size.width > area.maxX - edge { x = screenPoint.x - size.width }
            if y < area.minY + edge { y = screenPoint.y }
            return NSPoint(x: x, y: y)
        }
    }

    static func show(_ items: [MenuItem], under screenRect: NSRect) {
        present(items, near: NSPoint(x: screenRect.midX, y: screenRect.midY)) { size, area in
            var x = screenRect.minX
            var y = screenRect.minY - size.height - 4
            if x + size.width > area.maxX - edge { x = screenRect.maxX - size.width }
            if y < area.minY + edge { y = screenRect.maxY + 4 }
            return NSPoint(x: x, y: y)
        }
    }

    static var justClosed: Bool { closedAt.map { Date().timeIntervalSince($0) < 0.3 } ?? false }
    private static var closedAt: Date?

    static func dismiss() {
        for monitor in monitors { NSEvent.removeMonitor(monitor) }
        monitors = []
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
        if let spaceObserver { NSWorkspace.shared.notificationCenter.removeObserver(spaceObserver) }
        spaceObserver = nil
        hovered.id = nil
        card?.orderOut(nil)
        card = nil
        if panel != nil { closedAt = Date() }
        panel?.orderOut(nil)
        panel = nil
    }

    static func hover(_ item: MenuItem?, rowTop: CGFloat) {
        hovered.id = item?.id
        show(card: item, rowTop: rowTop)
    }

    private static func present(_ items: [MenuItem], near anchor: NSPoint, place: (NSSize, NSRect) -> NSPoint) {
        dismiss()
        let host = FirstClickHostingView(rootView: MenuContent(items: items))
        var size = host.fittingSize
        size.width = min(max(size.width.rounded(.up), 160), 340)
        size.height = size.height.rounded(.up)
        let panel = makePanel()
        panel.contentView = host
        let area = screen(near: anchor).visibleFrame
        var origin = place(size, area)
        origin.x = min(max(origin.x, area.minX + edge), max(area.minX + edge, area.maxX - size.width - edge))
        origin.y = min(max(origin.y, area.minY + edge), max(area.minY + edge, area.maxY - size.height - edge))
        panel.setFrame(NSRect(origin: origin.rounded, size: size), display: false)
        panel.orderFrontRegardless()
        Self.panel = panel
        watch()
    }

    private static func show(card item: MenuItem?, rowTop: CGFloat) {
        guard let panel, let item, let detail = item.detail else {
            card?.orderOut(nil)
            card = nil
            return
        }
        let host = FirstClickHostingView(rootView: MenuCard(content: detail()))
        var size = host.fittingSize
        size.width = min(max(size.width.rounded(.up), 120), 280)
        size.height = size.height.rounded(.up)
        let panel2 = card ?? makePanel()
        panel2.contentView = host
        let area = screen(near: NSPoint(x: panel.frame.midX, y: panel.frame.midY)).visibleFrame
        var x = panel.frame.maxX + 8
        if x + size.width > area.maxX - edge { x = panel.frame.minX - size.width - 8 }
        x = min(max(x, area.minX + edge), max(area.minX + edge, area.maxX - size.width - edge))
        var y = panel.frame.maxY - rowTop - size.height
        y = min(max(y, area.minY + edge), max(area.minY + edge, area.maxY - size.height - edge))
        panel2.setFrame(NSRect(origin: NSPoint(x: x, y: y).rounded, size: size), display: false)
        panel2.order(.above, relativeTo: panel.windowNumber)
        card = panel2
    }

    static func choose(_ item: MenuItem) {
        let action = item.action
        dismiss()
        Task { @MainActor in action() }
    }

    private static func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.acceptsMouseMovedEvents = true
        panel.hidesOnDeactivate = false
        return panel
    }

    private static func screen(near point: NSPoint) -> NSScreen {
        NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main ?? NSScreen.screens[0]
    }

    private static func watch() {
        let mouse: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        if let outside = NSEvent.addLocalMonitorForEvents(matching: mouse, handler: { event in
            MainActor.assumeIsolated {
                if event.window !== panel, event.window !== card { dismiss() }
            }
            return event
        }) {
            monitors.append(outside)
        }
        if let elsewhere = NSEvent.addGlobalMonitorForEvents(matching: mouse, handler: { _ in
            MainActor.assumeIsolated { dismiss() }
        }) {
            monitors.append(elsewhere)
        }
        if let escape = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { event in
            guard event.keyCode == 53 else { return event }
            MainActor.assumeIsolated { dismiss() }
            return nil
        }) {
            monitors.append(escape)
        }
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification,
                                                                object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { dismiss() }
        })
        spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification,
                                                                          object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { dismiss() }
        }
    }
}

private extension NSPoint {
    var rounded: NSPoint { NSPoint(x: x.rounded(), y: y.rounded()) }
}

private struct MenuContent: View {
    let items: [MenuItem]
    @State private var tops: [String: CGFloat] = [:]
    @State private var shown = false

    private var checkable: Bool { items.contains { $0.checked } }
    private var symbolic: Bool { items.contains { $0.symbol != nil } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(items) { item in
                if item.isSeparator {
                    Rectangle()
                        .fill(.white.opacity(0.11))
                        .frame(height: 1)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                } else {
                    row(item)
                }
            }
        }
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .coordinateSpace(name: "menu")
        .background(Glass(cornerRadius: 12, tint: 1))
        .opacity(shown ? 1 : 0)
        .scaleEffect(shown ? 1 : 0.96, anchor: .top)
        .onAppear { withAnimation(.easeOut(duration: 0.1)) { shown = true } }
    }

    private func row(_ item: MenuItem) -> some View {
        let lit = MenuPanel.hovered.id == item.id && item.enabled
        return HStack(spacing: 8) {
            if symbolic {
                Image(systemName: item.symbol ?? "")
                    .font(.system(size: 11.5, weight: .medium))
                    .frame(width: 14, alignment: .center)
            }
            Text(item.title)
                .font(tiktok(13))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
            Spacer(minLength: 14)
            if let shortcut = item.shortcut {
                Text(shortcut)
                    .font(tiktok(12))
                    .foregroundStyle(.white.opacity(0.75))
                    .fixedSize()
            }
            if checkable {
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .bold))
                    .frame(width: 11, alignment: .center)
                    .opacity(item.checked ? 0.9 : 0)
            }
        }
        .foregroundStyle(item.destructive ? AnyShapeStyle(accent) : AnyShapeStyle(Color.white.opacity(0.92)))
        .opacity(item.enabled ? 1 : 0.35)
        .padding(.horizontal, 9)
        .frame(height: 26)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(.white.opacity(lit ? 0.1 : 0)))
        .padding(.horizontal, 5)
        .contentShape(Rectangle())
        .onGeometryChange(for: CGFloat.self, of: { $0.frame(in: .named("menu")).minY }) { tops[item.id] = $0 }
        .onHover { inside in
            guard item.enabled else { return }
            if inside {
                MenuPanel.hover(item, rowTop: tops[item.id] ?? 0)
            } else if MenuPanel.hovered.id == item.id {
                MenuPanel.hover(nil, rowTop: 0)
            }
        }
        .onTapGesture { if item.enabled { MenuPanel.choose(item) } }
    }
}

private struct MenuCard: View {
    let content: AnyView

    var body: some View {
        content
            .font(tiktok(12))
            .foregroundStyle(.white.opacity(0.88))
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Glass(cornerRadius: 10, tint: 1))
    }
}

extension View {
    func onRightClick(_ items: @escaping @MainActor () -> [MenuItem]) -> some View {
        overlay(RightClickCatcher(items: items))
    }
}

private struct RightClickCatcher: NSViewRepresentable {
    let items: @MainActor () -> [MenuItem]

    func makeNSView(context: Context) -> RightClickView {
        let view = RightClickView()
        view.items = items
        return view
    }

    func updateNSView(_ view: RightClickView, context: Context) {
        view.items = items
    }
}

final class RightClickView: NSView {
    var items: (@MainActor () -> [MenuItem])?

    override func hitTest(_ point: NSPoint) -> NSView? {
        NSApp.currentEvent?.type == .rightMouseDown ? super.hitTest(point) : nil
    }

    override func rightMouseDown(with event: NSEvent) {
        MainActor.assumeIsolated {
            guard let items = items?(), !items.isEmpty else { return }
            MenuPanel.show(items, at: NSEvent.mouseLocation)
        }
    }
}

struct GlassDropdown<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [(Value, String)]
    let detail: (@MainActor (Value) -> AnyView)?
    @State private var hovering = false
    @State private var box = ViewBox()

    init(selection: Binding<Value>, options: [(Value, String)], detail: (@MainActor (Value) -> AnyView)? = nil) {
        _selection = selection
        self.options = options
        self.detail = detail
    }

    var body: some View {
        Button(action: open) {
            HStack(spacing: 4) {
                Text(options.first { $0.0 == selection }?.1 ?? "").lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 8, weight: .bold)).opacity(0.8)
            }
            .font(tiktok(12, "Medium"))
            .foregroundStyle(.white.opacity(0.92))
            .padding(.horizontal, 9)
            .frame(height: 24)
            .background(Capsule().fill(.white.opacity(hovering ? 0.16 : 0.1)).overlay(Capsule().strokeBorder(.white.opacity(0.13))))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .background(ScreenRectReader(box: box))
    }

    private func open() {
        guard let rect = box.screenRect else { return }
        MenuPanel.show(dropdownItems(options, selection: $selection, detail: detail), under: rect)
    }
}

@MainActor
func dropdownItems<Value: Hashable>(_ options: [(Value, String)], selection: Binding<Value>,
                                    detail: (@MainActor (Value) -> AnyView)? = nil) -> [MenuItem] {
    var items: [MenuItem] = []
    for option in options {
        let value: Value = option.0
        var card: (@MainActor () -> AnyView)?
        if let make = detail { card = { make(value) } }
        let choose: @MainActor () -> Void = { selection.wrappedValue = value }
        items.append(MenuItem(id: String(describing: value), title: option.1, checked: value == selection.wrappedValue,
                              detail: card, action: choose))
    }
    return items
}

@MainActor
private final class ViewBox {
    weak var view: NSView?

    var screenRect: NSRect? {
        guard let view, let window = view.window else { return nil }
        return window.convertToScreen(view.convert(view.bounds, to: nil))
    }
}

private struct ScreenRectReader: NSViewRepresentable {
    let box: ViewBox

    func makeNSView(context: Context) -> NSView {
        let view = PassthroughView()
        box.view = view
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        box.view = view
    }

    private final class PassthroughView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

@MainActor
func installEditMenu(in app: NSApplication) {
    let edit = NSMenu(title: "Edit")
    edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
    edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
    edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
    edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
    edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
    edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
    let menu = NSMenu()
    menu.addItem(NSMenuItem())
    menu.addItem(withTitle: "Edit", action: nil, keyEquivalent: "").submenu = edit
    app.mainMenu = menu
}

@MainActor
func barMenuItems(_ model: AppModel) -> [MenuItem] {
    [
        MenuItem(id: "unload", title: "Unload models", symbol: "eject", enabled: model.speech.state != "unloaded",
                 action: { model.onUnload() }),
        .separator(),
        MenuItem(id: "notes", title: "Notes", symbol: "square.and.pencil", action: { model.toggleNotes() }),
        MenuItem(id: "library", title: "My notes", symbol: "books.vertical", action: { model.showMyNotes() }),
        MenuItem(id: "meeting", title: model.meetingRecording ? "Stop meeting" : "Record meeting",
                 symbol: model.meetingRecording ? "stop.circle" : "person.2.wave.2",
                 action: { model.toggleMeetingRecording() }),
        MenuItem(id: "meetings", title: "Meetings", symbol: "rectangle.stack", action: { model.openMeetings() }),
        MenuItem(id: "history", title: "History", symbol: "clock.arrow.circlepath", action: { model.toggleHistory() }),
        MenuItem(id: "settings", title: "Settings", symbol: "slider.horizontal.3", action: { model.toggleSettings() }),
        .separator(),
        MenuItem(id: "hide", title: "Hide control", symbol: "eye.slash", action: { model.hideControl() }),
        MenuItem(id: "quit", title: "Quit Iridium Live", symbol: "power", action: { model.quit() }),
    ]
}

@MainActor
func statusMenuItems(_ model: AppModel) -> [MenuItem] {
    let hidden = model.settings.controlHidden
    let shown: (@escaping @MainActor () -> Void) -> @MainActor () -> Void = { open in { model.showControl(); open() } }
    return [
        MenuItem(id: "record", title: model.recording ? "Stop recording" : "Start recording",
                 symbol: model.recording ? "stop.circle" : "record.circle", enabled: model.ready || model.recording,
                 action: { model.toggleRecording() }),
        MenuItem(id: "meeting", title: model.meetingRecording ? "Stop meeting" : "Record meeting",
                 symbol: model.meetingRecording ? "stop.circle" : "person.2.wave.2",
                 action: shown { model.toggleMeetingRecording() }),
        .separator(),
        MenuItem(id: "control", title: hidden ? "Show control" : "Hide control", symbol: hidden ? "eye" : "eye.slash",
                 action: { hidden ? model.showControl() : model.hideControl() }),
        MenuItem(id: "notes", title: "Notes", symbol: "square.and.pencil", action: shown { model.toggleNotes() }),
        MenuItem(id: "library", title: "My notes", symbol: "books.vertical", action: shown { model.showMyNotes() }),
        MenuItem(id: "meetings", title: "Meetings", symbol: "rectangle.stack", action: { model.openMeetings() }),
        MenuItem(id: "history", title: "History", symbol: "clock.arrow.circlepath", action: shown { model.toggleHistory() }),
        MenuItem(id: "settings", title: "Settings", symbol: "slider.horizontal.3", action: shown { model.toggleSettings() }),
        .separator(),
        MenuItem(id: "unload", title: "Unload models", symbol: "eject", enabled: model.speech.state != "unloaded",
                 action: { model.onUnload() }),
        .separator(),
        MenuItem(id: "quit", title: "Quit Iridium Live", symbol: "power", action: { model.quit() }),
    ]
}

