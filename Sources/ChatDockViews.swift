import SwiftUI

struct DockButton: View {
    let state: DockState
    let press: () -> Void
    let release: () -> Void
    @State private var holding = false
    @State private var hovering = false
    @State private var pulse = false

    var body: some View {
        let style = state.profile.buttonStyle
        let recording = state.recording
        GeometryReader { geometry in
            let side = min(geometry.size.width, geometry.size.height)
            let shape = RoundedRectangle(cornerRadius: min(style.cornerRadius, side / 2), style: .continuous)
            ZStack {
                shape
                    .fill((recording ? style.activeFill : style.fill).color)
                    .overlay(shape.strokeBorder(.white.opacity(hovering ? 0.35 : 0.14)))
                    .shadow(color: .black.opacity(style.shadow), radius: 4, y: 1)
                    .overlay {
                        if recording {
                            shape.strokeBorder((style.activeFill).color.opacity(0.55), lineWidth: 3)
                                .scaleEffect(pulse ? 1.22 : 1)
                                .opacity(pulse ? 0 : 0.9)
                        }
                    }
                Image(systemName: recording ? "stop.fill" : style.symbol)
                    .font(.system(size: style.symbolSize, weight: .semibold))
                    .foregroundStyle(style.symbolColour.color)
                    .scaleEffect(1 + (recording ? min(state.level, 1) * 0.12 : 0))
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .opacity(state.ready || recording ? 1 : 0.45)
            .scaleEffect(holding ? 0.9 : 1)
            .contentShape(shape)
            .onHover { hovering = $0 }
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    guard !holding else { return }
                    holding = true
                    press()
                }
                .onEnded { _ in
                    holding = false
                    release()
                })
            .animation(.spring(response: 0.22, dampingFraction: 0.7), value: holding)
            .animation(.easeOut(duration: 0.18), value: recording)
            .animation(.easeOut(duration: 0.12), value: hovering)
            .animation(.easeOut(duration: 0.12), value: state.level)
            .onChange(of: recording) { _, now in
                pulse = false
                guard now else { return }
                withAnimation(.easeOut(duration: 1.1).repeatForever(autoreverses: false)) { pulse = true }
            }
        }
    }
}

struct DockOverlay: View {
    let state: DockState

    var body: some View {
        let style = state.profile.overlayStyle
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Circle()
                    .fill(state.finishing ? style.textColour.color.opacity(0.45) : style.accentColour.color)
                    .frame(width: 8, height: 8)
                    .opacity(state.recording ? 0.35 + 0.65 * min(1, 0.25 + state.level) : 1)
                Text(state.finishing ? "Finishing" : time)
                    .font(tiktok(style.fontSize - 1, "Medium"))
                    .monospacedDigit()
                    .foregroundStyle(style.textColour.color.opacity(0.75))
                Levels(level: state.level, colour: style.accentColour.color, live: state.recording)
                Spacer(minLength: 0)
                Text(state.profile.mode == .collect ? "Collecting" : "Typing")
                    .font(tiktok(style.fontSize - 2, "Medium"))
                    .foregroundStyle(style.textColour.color.opacity(0.78))
            }
            Text(state.transcript.isEmpty ? "Listening…" : state.transcript)
                .font(tiktok(style.fontSize))
                .foregroundStyle(style.textColour.color.opacity(state.transcript.isEmpty ? 0.6 : 0.95))
                .lineLimit(3)
                .truncationMode(.head)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .animation(.easeOut(duration: 0.12), value: state.transcript)
        }
        .padding(.horizontal, state.attached ? 16 : 12)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background { background(style) }
        .opacity(style.opacity)
    }

    @ViewBuilder private func background(_ style: DockOverlayStyle) -> some View {
        if state.attached {
            let shape = UnevenRoundedRectangle(topLeadingRadius: style.cornerRadius, bottomLeadingRadius: 0,
                                               bottomTrailingRadius: 0, topTrailingRadius: style.cornerRadius,
                                               style: .continuous)
            shape
                .fill(LinearGradient(stops: [.init(color: style.background.color, location: 0),
                                             .init(color: style.background.color, location: 0.3),
                                             .init(color: style.joinColour.color, location: 1)],
                                     startPoint: .top, endPoint: .bottom))
                .overlay(shape.strokeBorder(LinearGradient(colors: [.white.opacity(0.14), .clear],
                                                           startPoint: .top, endPoint: .center)))
        } else {
            RoundedRectangle(cornerRadius: style.cornerRadius, style: .continuous)
                .fill(style.background.color)
                .overlay(RoundedRectangle(cornerRadius: style.cornerRadius, style: .continuous)
                    .strokeBorder(.white.opacity(0.12)))
                .shadow(color: .black.opacity(0.3), radius: 10, y: 3)
        }
    }

    private var time: String {
        let seconds = Int(state.elapsed)
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

private struct Levels: View {
    let level: Double
    let colour: Color
    let live: Bool

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<5, id: \.self) { bar in
                let reach = Double(bar + 1) / 5
                let lit = live && level >= reach * 0.8
                Capsule()
                    .fill(colour.opacity(lit ? 0.95 : 0.22))
                    .frame(width: 2.5, height: 4 + CGFloat(bar) * 2)
            }
        }
        .frame(height: 14, alignment: .center)
        .animation(.easeOut(duration: 0.1), value: level)
    }
}

