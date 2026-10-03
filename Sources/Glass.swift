import AppKit
import SwiftUI

let accent = Color(red: 1.0, green: 0.29, blue: 0.31)

func tiktok(_ size: CGFloat, _ weight: String = "Regular") -> Font { .custom("TikTokSans-\(weight)", size: size) }

struct BehindWindowBlur: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = ClickThroughBlur()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        view.appearance = NSAppearance(named: .vibrantDark)
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

final class ClickThroughBlur: NSVisualEffectView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

struct Glass: View {
    let cornerRadius: CGFloat
    let tint: Double

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        GeometryReader { geometry in
            let height = max(geometry.size.height, 1)
            ZStack(alignment: .top) {
                BehindWindowBlur()
                Color.black.opacity(tint * 0.75)
                LinearGradient(colors: [.white.opacity(0.13), .white.opacity(0.03), .clear], startPoint: .top, endPoint: .bottom)
                    .frame(height: min(30, height))
            }
            .clipShape(shape)
            .overlay(shape.strokeBorder(LinearGradient(stops: [
                .init(color: .white.opacity(0.45), location: 0),
                .init(color: .white.opacity(0.1), location: min(0.6, 34 / height)),
                .init(color: .white.opacity(0.16), location: 1),
            ], startPoint: .top, endPoint: .bottom), lineWidth: 1))
        }
    }
}

struct Pressable: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.88 : 1)
            .animation(.spring(response: 0.2, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

struct IconToggle: View {
    let symbol: String
    let isOn: Bool
    var badge = false
    let tip: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(isOn ? 1 : hovering ? 0.75 : 0.42))
                .frame(width: 32, height: 32)
                .background {
                    Circle().fill(.white.opacity(isOn ? 0.2 : hovering ? 0.08 : 0))
                        .overlay(Circle().strokeBorder(.white.opacity(isOn ? 0.3 : 0)))
                        .padding(1)
                }
                .overlay(alignment: .topTrailing) {
                    if badge { Circle().fill(accent).frame(width: 7, height: 7).offset(x: -5, y: 5) }
                }
                .contentShape(Circle())
        }
        .buttonStyle(Pressable())
        .onHover { hovering = $0 }
        .tip(tip)
        .animation(.easeOut(duration: 0.15), value: isOn)
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

struct Tip {
    let text: String
    let anchor: Anchor<CGRect>
}

struct TipKey: PreferenceKey {
    static var defaultValue: [Tip] { [] }
    static func reduce(value: inout [Tip], nextValue: () -> [Tip]) { value += nextValue() }
}

extension View {
    func tip(_ text: String) -> some View { modifier(TipSource(text: text)) }
}

private struct TipSource: ViewModifier {
    let text: String
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .onHover { hovering = $0 }
            .anchorPreference(key: TipKey.self, value: .bounds) { hovering ? [Tip(text: text, anchor: $0)] : [] }
    }
}

struct TipLayer: View {
    let tips: [Tip]
    let bar: ClosedRange<CGFloat>
    let barOnTop: Bool
    @State private var size = CGSize.zero

    var body: some View {
        GeometryReader { proxy in
            if let tip = tips.last {
                let rect = proxy[tip.anchor]
                let edge = size.width / 2 - floatingMargin + 4
                let gap = size.height / 2 + 4
                Text(tip.text)
                    .font(tiktok(11.5, "Medium"))
                    .foregroundStyle(.white.opacity(0.95))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 3)
                    .frame(minHeight: 20)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color(white: 0.12).opacity(0.94))
                        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.white.opacity(0.18))))
                    .fixedSize()
                    .onGeometryChange(for: CGSize.self, of: { $0.size }) { size = $0 }
                    .position(x: min(max(rect.midX, edge), proxy.size.width - edge),
                              y: bar.contains(rect.midY) ? (barOnTop ? -gap : proxy.size.height + gap) : rect.maxY + gap)
                    .allowsHitTesting(false)
            }
        }
    }
}

