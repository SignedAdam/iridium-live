import AppKit
import Observation
import SwiftUI

/// Live captions: white text with a black outline at the top or bottom of the screen, click-through, on every Space.
/// Font, size, position, opacity and how long they stay come from the settings. Long phrases show their newest words.
@MainActor
final class Captions {
    private static let maxLines: CGFloat = 2
    private let panel: NSPanel
    private let caption = CaptionModel()
    private let screen: NSScreen
    private var settings: Settings
    private var font = NSFont.boldSystemFont(ofSize: 48)
    private var latest = ""
    private var generation = 0

    init(screen: NSScreen, settings: Settings) {
        self.screen = screen
        self.settings = settings
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        let host = NSHostingView(rootView: CaptionView(caption: caption))
        host.sizingOptions = []
        panel.contentView = host
        apply(settings)
        panel.orderFrontRegardless()
    }

    func apply(_ settings: Settings) {
        self.settings = settings
        font = Self.font(named: settings.captionFont, size: settings.captionSize)
        let area = screen.visibleFrame
        let width = (area.width * 0.8).rounded()
        let height = ceil(font.ascender - font.descender + font.leading) * Self.maxLines + 28
        let y = settings.captionPosition == .top ? area.maxY - height - 16 : area.minY + 110
        panel.setFrame(NSRect(x: area.midX - width / 2, y: y, width: width, height: height), display: true)
        caption.font = Font(font)
        caption.stroke = max(1.5, settings.captionSize * 0.065)
        caption.alignment = settings.captionPosition == .top ? .top : .bottom
        caption.opacity = settings.captionOpacity
        if !settings.captionsShown { caption.visible = false }
        caption.text = tail(of: latest)
    }

    func show(_ text: String) {
        latest = text
        guard settings.captionsShown else { return }
        caption.text = tail(of: text)
        caption.visible = true
        generation += 1
        let shown = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + settings.captionSeconds) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.generation == shown else { return }
                self.caption.visible = false
            }
        }
    }

    /// The newest words that fit in two lines: live captions follow the speaker, so old words scroll off the front.
    private func tail(of text: String) -> String {
        let words = text.split(separator: " ")
        let limit = ceil(font.ascender - font.descender + font.leading) * Self.maxLines + 1
        let width = panel.frame.width - 16
        var start = 0
        while start < words.count - 1 {
            let candidate = (start > 0 ? "… " : "") + words[start...].joined(separator: " ")
            let size = NSAttributedString(string: candidate, attributes: [.font: font]).boundingRect(
                with: NSSize(width: width, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading])
            if size.height <= limit { return candidate }
            start += 1
        }
        return words.last.map(String.init) ?? ""
    }

    private static func font(named name: String, size: CGFloat) -> NSFont {
        let system = NSFont.systemFont(ofSize: size, weight: .bold)
        let font: NSFont? = switch name {
        case "SF Pro": system
        case "SF Pro Rounded": system.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: size) }
        case "New York": system.fontDescriptor.withDesign(.serif).flatMap { NSFont(descriptor: $0, size: size) }
        case "Menlo": NSFont(name: "Menlo-Bold", size: size)
        default: NSFont(name: "TikTokSans-Bold", size: size)
        }
        return font ?? system
    }
}

@MainActor @Observable
final class CaptionModel {
    var text = ""
    var visible = false
    var font = Font.system(size: 48, weight: .bold)
    var stroke: CGFloat = 3
    var alignment = VerticalAlignment.top
    var opacity = 1.0
}

struct CaptionView: View {
    let caption: CaptionModel

    var body: some View {
        OutlinedText(text: caption.text, font: caption.font, stroke: caption.stroke)
            .padding(8)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: Alignment(horizontal: .center, vertical: caption.alignment))
            .opacity(caption.visible ? caption.opacity : 0)
            .animation(.easeOut(duration: caption.visible ? 0.12 : 0.4), value: caption.visible)
    }
}

/// White text with a black outline all round (eight offset copies behind it) and a soft shadow, so it reads on any
/// background.
struct OutlinedText: View {
    let text: String
    let font: Font
    let stroke: CGFloat

    var body: some View {
        ZStack {
            ForEach(0..<8, id: \.self) { index in
                let angle = Double(index) * .pi / 4
                Text(text).foregroundStyle(.black).offset(x: cos(angle) * stroke, y: sin(angle) * stroke)
            }
            Text(text).foregroundStyle(.white)
        }
        .font(font)
        .multilineTextAlignment(.center)
        .shadow(color: .black.opacity(0.5), radius: 10, y: 2)
    }
}
