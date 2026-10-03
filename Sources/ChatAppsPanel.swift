import AppKit
import SwiftUI

/// The chat apps editor: the apps on the left, everything about the chosen one on the right. Changes apply as they
/// are made and are saved to `chat-apps.json`. One at a time, like the instructions editor.
@MainActor
final class ChatAppsPanel {
    private static var open: ChatAppsPanel?
    private let panel: ChatAppsKeyPanel

    static func show(apps: ChatApps, on screen: NSScreen, detect: @escaping @MainActor (String) -> Detection?) {
        if let open { open.panel.makeKeyAndOrderFront(nil); return }
        open = ChatAppsPanel(apps: apps, screen: screen, detect: detect)
    }

    private init(apps: ChatApps, screen: NSScreen, detect: @escaping @MainActor (String) -> Detection?) {
        let size = NSSize(width: 680, height: 560)
        let area = screen.visibleFrame
        panel = ChatAppsKeyPanel(contentRect: NSRect(x: (area.midX - size.width / 2).rounded(),
                                                     y: (area.midY - size.height / 2).rounded(),
                                                     width: size.width, height: size.height),
                                 styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = true
        let close = {
            ChatAppsPanel.open?.panel.orderOut(nil)
            ChatAppsPanel.open = nil
        }
        let host = NSHostingView(rootView: ChatAppsEditor(apps: apps, detect: detect, close: close)
            .frame(width: size.width, height: size.height))
        host.sizingOptions = []
        panel.contentView = host
        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)
        panel.animator().alphaValue = 1
    }
}

/// Borderless, but it takes the keyboard for the text fields without making the app active.
private final class ChatAppsKeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

private struct ChatAppsEditor: View {
    @Bindable var apps: ChatApps
    let detect: @MainActor (String) -> Detection?
    let close: () -> Void
    @State private var chosen: String = ""
    @State private var note: String?

    var body: some View {
        HStack(spacing: 0) {
            list
            Rectangle().fill(.white.opacity(0.08)).frame(width: 1)
            editor
        }
        .background(Glass(cornerRadius: 18, tint: 1))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .padding(10)
        .shadow(color: .black.opacity(0.35), radius: 14, y: 6)
        .font(tiktok(13))
        .foregroundStyle(.white.opacity(0.88))
        .onAppear { if chosen.isEmpty { chosen = apps.apps.first?.bundleID ?? "" } }
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("CHAT APPS")
                .font(tiktok(10.5, "Medium"))
                .kerning(0.8)
                .foregroundStyle(.white.opacity(0.42))
                .padding(.horizontal, 16)
                .padding(.top, 18)
                .padding(.bottom, 10)
            ScrollView {
                VStack(spacing: 2) {
                    ForEach($apps.apps) { $profile in
                        AppRow(profile: $profile, chosen: chosen == profile.bundleID) { chosen = profile.bundleID }
                    }
                }
                .padding(.horizontal, 8)
            }
            Divider().overlay(.white.opacity(0.08))
            AddAppButton { bundleID, name in
                apps.add(bundleID: bundleID, name: name)
                chosen = bundleID
            }
            .padding(10)
        }
        .frame(width: 196)
    }

    @ViewBuilder private var editor: some View {
        if let index = apps.apps.firstIndex(where: { $0.bundleID == chosen }) {
            let profile = $apps.apps[index]
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Text(profile.wrappedValue.name)
                        .font(tiktok(15, "Medium"))
                        .foregroundStyle(.white.opacity(0.95))
                    Text(profile.wrappedValue.bundleID)
                        .font(tiktok(11))
                        .foregroundStyle(.white.opacity(0.35))
                    Spacer(minLength: 0)
                    Button("Remove") {
                        let id = profile.wrappedValue.bundleID
                        chosen = apps.apps.first { $0.bundleID != id }?.bundleID ?? ""
                        apps.remove(bundleID: id)
                    }
                    .buttonStyle(DockAction(prominent: false))
                    Button("Done", action: close)
                        .buttonStyle(DockAction(prominent: true))
                        .keyboardShortcut(.cancelAction)
                }
                .padding(.horizontal, 18)
                .padding(.top, 18)
                .padding(.bottom, 12)
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        dictation(profile)
                        places(profile)
                        buttonLook(profile)
                        overlayLook(profile)
                    }
                    .padding(.horizontal, 18)
                    .padding(.bottom, 18)
                }
                .scrollIndicators(.visible)
            }
        } else {
            VStack(spacing: 10) {
                Text("No app chosen").foregroundStyle(.white.opacity(0.5))
                Button("Done", action: close).buttonStyle(DockAction(prominent: true))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func dictation(_ profile: Binding<ChatAppProfile>) -> some View {
        DockGroup("Dictation") {
            DockRow("Words") {
                DockChoice(selection: profile.mode, options: [(ChatAppProfile.Mode.stream, "Stream"),
                                                              (.collect, "Collect")])
            }
            DockRow("Send automatically") {
                DockToggle(isOn: profile.autoSend)
            }
            DockRow("Send by") {
                DockChoice(selection: profile.send, options: [(ChatAppProfile.Send.press, "Send button"),
                                                              (.returnKey, "Return")])
            }
            DockRow("Insert by") {
                DockChoice(selection: profile.insertion, options: [(ChatAppProfile.Insertion.accessibility, "Direct"),
                                                                   (.paste, "Paste")])
            }
            DockRow("Hide captions") {
                DockToggle(isOn: profile.hideCaptions)
            }
        }
    }

    private func places(_ profile: Binding<ChatAppProfile>) -> some View {
        DockGroup("Places", detail: note) {
            DockRow("Find positions") {
                Button("Detect") {
                    let id = profile.wrappedValue.bundleID
                    if let found = detect(id) {
                        note = "Box \(rect(found.box?.frame)), Send \(rect(found.send?.frame))"
                    } else {
                        note = NSRunningApplication.runningApplications(withBundleIdentifier: id).isEmpty
                            ? "\(profile.wrappedValue.name) is not running" : "Nothing found"
                    }
                }
                .buttonStyle(DockAction(prominent: false))
            }
            RectRow("Record button", rect: profile.button)
            RectRow("Message box", rect: profile.box)
            RectRow("App’s Send button", rect: profile.sendButton)
            DockRow("Cover voice button") {
                DockToggle(isOn: profile.overVoiceButton)
            }
        }
    }

    private func buttonLook(_ profile: Binding<ChatAppProfile>) -> some View {
        let style = profile.buttonStyle
        return DockGroup("Button") {
            DockRow("Symbol") {
                HStack(spacing: 8) {
                    Image(systemName: style.wrappedValue.symbol)
                        .font(.system(size: 13))
                        .foregroundStyle(style.wrappedValue.symbolColour.color)
                        .frame(width: 18)
                    DockText(text: style.symbol, width: 150)
                }
            }
            DockRow("Symbol size") { DockNumber(value: style.symbolSize) }
            DockRow("Corner radius") { DockNumber(value: style.cornerRadius) }
            DockRow("Fill") { DockColour(colour: style.fill) }
            DockRow("While recording") { DockColour(colour: style.activeFill) }
            DockRow("Symbol colour") { DockColour(colour: style.symbolColour) }
            DockRow("Shadow") { DockNumber(value: style.shadow, step: 0.05) }
        }
    }

    private func overlayLook(_ profile: Binding<ChatAppProfile>) -> some View {
        let style = profile.overlayStyle
        return DockGroup("Overlay") {
            DockRow("Shape") {
                DockChoice(selection: style.attached, options: [(true, "Across the chat"), (false, "Card")])
            }
            if !style.wrappedValue.attached { DockRow("Width") { DockNumber(value: style.width) } }
            DockRow("Height") { DockNumber(value: style.height) }
            DockRow("Gap above the input") { DockNumber(value: style.gap) }
            DockRow("Text size") { DockNumber(value: style.fontSize) }
            DockRow("Corner radius") { DockNumber(value: style.cornerRadius) }
            DockRow("Opacity") { DockNumber(value: style.opacity, step: 0.05) }
            DockRow("Background") { DockColour(colour: style.background) }
            if style.wrappedValue.attached { DockRow("Fade colour") { DockColour(colour: style.joinColour) } }
            DockRow("Text") { DockColour(colour: style.textColour) }
            DockRow("Accent") { DockColour(colour: style.accentColour) }
        }
    }

    private func rect(_ rect: NSRect?) -> String {
        guard let rect else { return "none" }
        return String(format: "%.0f,%.0f %.0f×%.0f", rect.minX, rect.minY, rect.width, rect.height)
    }
}

/// One app in the list: its switch, its name, and whether it is the one being edited.
private struct AppRow: View {
    @Binding var profile: ChatAppProfile
    let chosen: Bool
    let choose: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            DockToggle(isOn: $profile.enabled)
            VStack(alignment: .leading, spacing: 1) {
                Text(profile.name.isEmpty ? profile.bundleID : profile.name)
                    .font(tiktok(12.5, "Medium"))
                    .lineLimit(1)
                Text(profile.isPlaced ? "Ready" : "Needs Detect")
                    .font(tiktok(10.5))
                    .foregroundStyle(profile.isPlaced ? .white.opacity(0.4) : accent)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill(.white.opacity(chosen ? 0.14 : hovering ? 0.07 : 0)))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: choose)
    }
}

/// Adds an app by picking one of the apps running now.
private struct AddAppButton: View {
    let add: (String, String) -> Void
    @State private var box = DockViewBox()

    var body: some View {
        Button {
            let running = NSWorkspace.shared.runningApplications
                .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != nil }
                .sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }
            let items = running.map { app in
                MenuItem(id: app.bundleIdentifier ?? "", title: app.localizedName ?? app.bundleIdentifier ?? "",
                         action: { add(app.bundleIdentifier ?? "", app.localizedName ?? "") })
            }
            if let rect = box.screenRect { MenuPanel.show(items, under: rect) }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "plus").font(.system(size: 9, weight: .bold))
                Text("Add app")
            }
            .font(tiktok(12, "Medium"))
            .foregroundStyle(.white.opacity(0.8))
            .frame(maxWidth: .infinity)
            .frame(height: 26)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                .foregroundStyle(.white.opacity(0.22)))
        }
        .buttonStyle(.plain)
        .background(DockScreenRect(box: box))
    }
}

/// One rectangle of a profile: the corner it hangs from and its four numbers.
private struct RectRow: View {
    let title: String
    @Binding var rect: AnchoredRect

    init(_ title: String, rect: Binding<AnchoredRect>) {
        self.title = title
        _rect = rect
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(title).font(tiktok(12.5, "Medium"))
                Spacer(minLength: 0)
                GlassDropdown(selection: $rect.corner, options: Corner.allCases.map { ($0, $0.name) })
                    .frame(width: 112)
            }
            HStack(spacing: 6) {
                DockNumber(value: $rect.x, caption: "x")
                DockNumber(value: $rect.y, caption: "y")
                DockNumber(value: $rect.width, caption: "w")
                DockNumber(value: $rect.height, caption: "h")
            }
        }
        .padding(.vertical, 7)
    }
}

// MARK: - The modal's own controls

/// A titled block of rows, with hairlines between them, like the settings pane's sections.
private struct DockGroup<Content: View>: View {
    let title: String
    var detail: String?
    @ViewBuilder let content: Content

    init(_ title: String, detail: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.detail = detail
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Text(title.uppercased())
                    .font(tiktok(10.5, "Medium"))
                    .kerning(0.8)
                    .foregroundStyle(.white.opacity(0.42))
                if let detail {
                    Text(detail).font(tiktok(10.5)).foregroundStyle(.white.opacity(0.5)).lineLimit(1)
                }
            }
            .padding(.leading, 12)
            Group(subviews: content) { rows in
                VStack(spacing: 0) {
                    ForEach(rows) { row in
                        if row.id != rows.first?.id { Rectangle().fill(.white.opacity(0.07)).frame(height: 1) }
                        row
                    }
                }
            }
            .padding(.horizontal, 12)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.white.opacity(0.055)))
        }
    }
}

private struct DockRow<Control: View>: View {
    let title: String
    @ViewBuilder let control: Control

    init(_ title: String, @ViewBuilder control: () -> Control) {
        self.title = title
        self.control = control()
    }

    var body: some View {
        HStack(spacing: 12) {
            Text(title).font(tiktok(12.5))
            Spacer(minLength: 0)
            control
        }
        .padding(.vertical, 6)
        .frame(minHeight: 34)
    }
}

/// A number in a small field: typed in, or nudged with the arrow keys the field already answers.
private struct DockNumber: View {
    @Binding var value: Double
    var step = 1.0
    var caption: String?
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 4) {
            if let caption {
                Text(caption).font(tiktok(10.5)).foregroundStyle(.white.opacity(0.4))
            }
            TextField("", text: $text)
                .textFieldStyle(.plain)
                .font(tiktok(12, "Medium"))
                .monospacedDigit()
                .multilineTextAlignment(.trailing)
                .foregroundStyle(.white.opacity(0.92))
                .focused($focused)
                .frame(width: 52)
                .padding(.horizontal, 7)
                .frame(height: 24)
                .background(Capsule().fill(.white.opacity(focused ? 0.16 : 0.1))
                    .overlay(Capsule().strokeBorder(.white.opacity(0.13))))
                .onChange(of: text) { _, now in
                    if let parsed = Double(now.replacingOccurrences(of: ",", with: ".")) { value = parsed }
                }
                .onChange(of: value) { _, now in if !focused { text = format(now) } }
                .onAppear { text = format(value) }
        }
    }

    private func format(_ value: Double) -> String {
        step < 1 ? String(format: "%.2f", value) : String(format: "%g", (value * 10).rounded() / 10)
    }
}

/// A short string in a field: the SF Symbol name.
private struct DockText: View {
    @Binding var text: String
    var width: CGFloat = 120
    @FocusState private var focused: Bool

    var body: some View {
        TextField("", text: $text)
            .textFieldStyle(.plain)
            .font(tiktok(12, "Medium"))
            .foregroundStyle(.white.opacity(0.92))
            .focused($focused)
            .frame(width: width)
            .padding(.horizontal, 9)
            .frame(height: 24)
            .background(Capsule().fill(.white.opacity(focused ? 0.16 : 0.1))
                .overlay(Capsule().strokeBorder(.white.opacity(0.13))))
    }
}

/// A colour as its hex, with a swatch of it.
private struct DockColour: View {
    @Binding var colour: Colour
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(colour.color)
                .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(.white.opacity(0.2)))
                .frame(width: 22, height: 18)
            TextField("", text: $text)
                .textFieldStyle(.plain)
                .font(tiktok(12, "Medium"))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.92))
                .focused($focused)
                .frame(width: 86)
                .padding(.horizontal, 9)
                .frame(height: 24)
                .background(Capsule().fill(.white.opacity(focused ? 0.16 : 0.1))
                    .overlay(Capsule().strokeBorder(.white.opacity(0.13))))
                .onChange(of: text) { _, now in
                    let digits = now.drop { $0 == "#" }
                    if digits.count == 6 || digits.count == 8, UInt64(digits, radix: 16) != nil { colour = Colour(now) }
                }
                .onChange(of: colour) { _, now in if !focused { text = now.hex } }
                .onAppear { text = colour.hex }
        }
    }
}

private struct DockToggle: View {
    @Binding var isOn: Bool

    var body: some View {
        Button { isOn.toggle() } label: {
            Capsule()
                .fill(isOn ? accent : .white.opacity(0.14))
                .overlay(Capsule().strokeBorder(.white.opacity(isOn ? 0.2 : 0.12)))
                .frame(width: 34, height: 20)
                .overlay(alignment: isOn ? .trailing : .leading) {
                    Circle().fill(.white)
                        .frame(width: 16, height: 16)
                        .shadow(color: .black.opacity(0.3), radius: 1.5, y: 1)
                        .padding(2)
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .animation(.spring(response: 0.25, dampingFraction: 0.8), value: isOn)
    }
}

private struct DockChoice<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [(Value, String)]
    @Namespace private var pill

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options.indices, id: \.self) { index in
                let chosen = options[index].0 == selection
                Button { selection = options[index].0 } label: {
                    Text(options[index].1)
                        .font(tiktok(12, "Medium"))
                        .foregroundStyle(.white.opacity(chosen ? 0.95 : 0.55))
                        .padding(.horizontal, 11)
                        .frame(height: 22)
                        .background {
                            if chosen {
                                Capsule().fill(.white.opacity(0.2))
                                    .overlay(Capsule().strokeBorder(.white.opacity(0.13)))
                                    .matchedGeometryEffect(id: "pill", in: pill)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(Capsule().fill(.white.opacity(0.06)))
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: selection)
    }
}

private struct DockAction: ButtonStyle {
    let prominent: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(tiktok(12.5, "Medium"))
            .foregroundStyle(prominent ? Color.black.opacity(0.85) : .white.opacity(0.85))
            .padding(.horizontal, 14)
            .frame(height: 26)
            .background(Capsule().fill(prominent
                ? .white.opacity(configuration.isPressed ? 0.75 : 0.92)
                : .white.opacity(configuration.isPressed ? 0.18 : 0.1)))
            .contentShape(Capsule())
    }
}

/// Remembers where a control is on screen, so a menu can be put under it.
@MainActor
private final class DockViewBox {
    weak var view: NSView?

    var screenRect: NSRect? {
        guard let view, let window = view.window else { return nil }
        return window.convertToScreen(view.convert(view.bounds, to: nil))
    }
}

private struct DockScreenRect: NSViewRepresentable {
    let box: DockViewBox

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        box.view = view
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        box.view = view
    }
}
