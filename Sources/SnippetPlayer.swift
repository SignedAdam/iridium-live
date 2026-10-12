import AppKit
import SwiftUI
@preconcurrency import MeetingKit

struct SnippetPlayerView: View {
    @Bindable var player: MeetingPlayer
    let lineID: UUID
    let lineRange: ClosedRange<TimeInterval>

    @State private var selection: ClosedRange<TimeInterval>?
    @State private var window: ClosedRange<TimeInterval>?
    @State private var waveform: SnippetWaveform?
    @State private var drag: DragTarget?
    @State private var pinned: DragTarget?
    @State private var resumePoint: TimeInterval?
    @State private var hovering = false

    private static let leadPad: TimeInterval = 0.25
    private static let tailPad: TimeInterval = 0.4
    private static let minLength: TimeInterval = 0.3
    private static let nudge: TimeInterval = 5
    private static let barCount = 160
    private static let stripHeight: CGFloat = 38
    private static let grabRadius: CGFloat = 8

    private enum DragTarget: Equatable { case start, end, tap }

    private struct ResetKey: Equatable {
        let lineID: UUID
        let lineRange: ClosedRange<TimeInterval>
        let duration: TimeInterval
    }

    private struct WaveformKey: Hashable {
        let url: URL?
        let window: ClosedRange<TimeInterval>?
    }

    private var fileEnd: TimeInterval {
        player.duration > 0 ? player.duration : .greatestFiniteMagnitude
    }

    private var isReady: Bool { player.loadedURL != nil && player.duration > 0 && selection != nil }

    private var isActive: Bool { player.isPlaying && player.playbackEnd != nil }

    private var lineSelection: ClosedRange<TimeInterval> {
        var low = max(0, lineRange.lowerBound - Self.leadPad)
        var high = min(fileEnd, lineRange.upperBound + Self.tailPad)
        if high - low < Self.minLength {
            high = min(fileEnd, low + Self.minLength)
            low = max(0, high - Self.minLength)
        }
        return low...max(low, high)
    }

    private var isModified: Bool {
        guard let selection else { return false }
        let line = lineSelection
        return abs(selection.lowerBound - line.lowerBound) > 0.01
            || abs(selection.upperBound - line.upperBound) > 0.01
    }

    var body: some View {
        HStack(spacing: 8) {
            playButton
            nudgeButton("-5s", tip: "Start 5 seconds earlier",
                        enabled: isReady && (selection?.lowerBound ?? 0) > 0) { extendStart() }
            VStack(spacing: 3) {
                strip
                labels
            }
            .frame(maxWidth: .infinity)
            nudgeButton("+5s", tip: "End 5 seconds later",
                        enabled: isReady && (selection?.upperBound ?? 0) < player.duration) { extendEnd() }
            resetButton
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.white.opacity(hovering ? 0.08 : 0.05))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.white.opacity(0.1))))
        .opacity(isReady ? 1 : 0.55)
        .onHover { inside in withAnimation(.easeOut(duration: 0.16)) { hovering = inside } }
        .onChange(of: ResetKey(lineID: lineID, lineRange: lineRange, duration: player.duration), initial: true) {
            resetToLine(reloadWaveform: true)
        }
        .task(id: WaveformKey(url: player.loadedURL, window: window)) { await loadWaveform() }
        .task(id: pinned) { await growWhilePinned() }
        .onDisappear { if player.playbackEnd != nil { player.pause() } }
    }

    private var playButton: some View {
        Button { togglePlayback() } label: {
            Image(systemName: isActive ? "pause.fill" : "play.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.92))
                .offset(x: isActive ? 0 : 1)
                .frame(width: 30, height: 30)
                .background(Circle().fill(.white.opacity(0.1)).overlay(Circle().strokeBorder(.white.opacity(0.13))))
                .contentShape(Circle())
        }
        .buttonStyle(Pressable())
        .disabled(!isReady)
        .tip(isActive ? "Pause line" : "Play line")
    }

    private func nudgeButton(_ title: String, tip: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(tiktok(11, "Medium"))
                .foregroundStyle(.white.opacity(0.92))
                .padding(.horizontal, 8)
                .frame(height: 22)
                .background(Pill())
                .opacity(enabled ? 1 : 0.4)
                .contentShape(Capsule())
        }
        .buttonStyle(Pressable())
        .disabled(!enabled)
        .tip(tip)
    }

    private var resetButton: some View {
        let enabled = isReady && isModified
        return Button { resetToLine(reloadWaveform: false) } label: {
            Image(systemName: "arrow.uturn.backward")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white.opacity(0.92))
                .frame(width: 22, height: 22)
                .background(Circle().fill(.white.opacity(0.1)))
                .opacity(enabled ? 1 : 0.4)
                .contentShape(Circle())
        }
        .buttonStyle(Pressable())
        .disabled(!enabled)
        .tip("Reset to the line range")
    }

    private var labels: some View {
        HStack(spacing: 6) {
            if let selection {
                Text("\(formatTimecode(selection.lowerBound)) to \(formatTimecode(selection.upperBound))")
                Spacer(minLength: 4)
                Text(Self.formatLength(selection.upperBound - selection.lowerBound))
            } else {
                Spacer(minLength: 0)
            }
        }
        .font(tiktok(10.5))
        .monospacedDigit()
        .foregroundStyle(.white.opacity(0.78))
        .lineLimit(1)
    }

    private var strip: some View {
        let snapshot = StripSnapshot(window: window, selection: selection,
                                     waveform: isReady ? waveform : nil,
                                     playhead: isReady ? player.currentTime : nil)
        return GeometryReader { geometry in
            let width = geometry.size.width
            ZStack(alignment: .topLeading) {
                Canvas { context, size in snapshot.draw(in: &context, size: size) }
                if isReady, let selection, let window {
                    handleHitArea(at: snapshot.x(selection.lowerBound, in: window, width: width), height: geometry.size.height)
                    handleHitArea(at: snapshot.x(selection.upperBound, in: window, width: width), height: geometry.size.height)
                }
            }
            .contentShape(Rectangle())
            .gesture(stripGesture(width: width))
        }
        .frame(height: Self.stripHeight)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func handleHitArea(at x: CGFloat, height: CGFloat) -> some View {
        Color.clear
            .frame(width: Self.grabRadius * 2, height: height)
            .contentShape(Rectangle())
            .pointerStyle(.columnResize)
            .offset(x: x - Self.grabRadius)
    }

    private func stripGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { gesture in
                guard isReady, let selection, let window, width > 0 else { return }
                let target: DragTarget
                if let drag {
                    target = drag
                } else {
                    target = grabTarget(at: gesture.startLocation.x, selection: selection, window: window, width: width)
                    drag = target
                    if target != .tap {
                        if isActive { player.pause() }
                        resumePoint = nil
                    }
                }
                let moment = time(at: gesture.location.x, in: window, width: width)
                switch target {
                case .tap:
                    return
                case .start:
                    let low = min(max(moment, window.lowerBound), selection.upperBound - Self.minLength)
                    self.selection = max(0, low)...selection.upperBound
                    pinned = gesture.location.x <= 2 && window.lowerBound > 0 ? .start : nil
                case .end:
                    let high = max(min(moment, window.upperBound), selection.lowerBound + Self.minLength)
                    self.selection = selection.lowerBound...min(fileEnd, high)
                    pinned = gesture.location.x >= width - 2 && window.upperBound < player.duration ? .end : nil
                }
            }
            .onEnded { gesture in
                defer { drag = nil; pinned = nil }
                guard drag == .tap, isReady, let selection, let window, width > 0,
                      abs(gesture.translation.width) < 4 else { return }
                let moment = time(at: gesture.location.x, in: window, width: width)
                guard selection.contains(moment) else { return }
                player.seek(to: moment)
                if !isActive { resumePoint = moment }
            }
    }

    private func grabTarget(at x: CGFloat, selection: ClosedRange<TimeInterval>,
                            window: ClosedRange<TimeInterval>, width: CGFloat) -> DragTarget {
        let span = window.upperBound - window.lowerBound
        let startX = CGFloat((selection.lowerBound - window.lowerBound) / span) * width
        let endX = CGFloat((selection.upperBound - window.lowerBound) / span) * width
        let toStart = abs(x - startX), toEnd = abs(x - endX)
        guard min(toStart, toEnd) <= Self.grabRadius else { return .tap }
        if toStart <= Self.grabRadius && toEnd <= Self.grabRadius { return x < (startX + endX) / 2 ? .start : .end }
        return toStart < toEnd ? .start : .end
    }

    private func time(at x: CGFloat, in window: ClosedRange<TimeInterval>, width: CGFloat) -> TimeInterval {
        window.lowerBound + Double(x / width) * (window.upperBound - window.lowerBound)
    }

    private func togglePlayback() {
        guard isReady, let selection else { return }
        if isActive {
            player.pause()
            resumePoint = player.currentTime
            return
        }
        var start = selection.lowerBound
        if let resume = resumePoint, resume >= selection.lowerBound, resume < selection.upperBound - 0.05 { start = resume }
        resumePoint = nil
        player.play(from: start, until: selection.upperBound, rewindTo: selection.lowerBound)
    }

    private func extendStart() {
        guard let selection else { return }
        apply(max(0, selection.lowerBound - Self.nudge)...selection.upperBound)
    }

    private func extendEnd() {
        guard let selection else { return }
        apply(selection.lowerBound...min(fileEnd, selection.upperBound + Self.nudge))
    }

    private func apply(_ range: ClosedRange<TimeInterval>) {
        if isActive { player.pause() }
        resumePoint = nil
        selection = range
        let context = contextWindow(for: range)
        if let window {
            self.window = min(window.lowerBound, context.lowerBound)...max(window.upperBound, context.upperBound)
        } else {
            window = context
        }
    }

    private func resetToLine(reloadWaveform: Bool) {
        if player.playbackEnd != nil { player.pause() }
        drag = nil
        pinned = nil
        resumePoint = nil
        let range = lineSelection
        selection = range
        window = contextWindow(for: range)
        if reloadWaveform { waveform = nil }
    }

    private func contextWindow(for range: ClosedRange<TimeInterval>) -> ClosedRange<TimeInterval> {
        let pad = max(6, 0.6 * (range.upperBound - range.lowerBound))
        let low = max(0, range.lowerBound - pad)
        return low...max(low, min(fileEnd, range.upperBound + pad))
    }

    private func growWhilePinned() async {
        guard let edge = pinned else { return }
        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(50))
            guard !Task.isCancelled, pinned == edge, let window, let selection else { return }
            let step = max(0.5, (window.upperBound - window.lowerBound) * 0.04)
            switch edge {
            case .start:
                let low = max(0, window.lowerBound - step)
                guard low < window.lowerBound else { pinned = nil; return }
                self.window = low...window.upperBound
                self.selection = low...selection.upperBound
            case .end:
                let high = min(player.duration, window.upperBound + step)
                guard high > window.upperBound else { pinned = nil; return }
                self.window = window.lowerBound...high
                self.selection = selection.lowerBound...high
            case .tap:
                return
            }
        }
    }

    private func loadWaveform() async {
        guard let url = player.loadedURL, player.duration > 0, let window, waveform?.window != window else { return }
        if waveform != nil {
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
        }
        guard let loaded = await SnippetWaveform.load(url: url, window: window, count: Self.barCount),
              !Task.isCancelled else { return }
        waveform = loaded
    }

    private static func formatLength(_ length: TimeInterval) -> String {
        length < 60 ? String(format: "%.1fs", length) : formatTimecode(length)
    }
}

private struct StripSnapshot {
    let window: ClosedRange<TimeInterval>?
    let selection: ClosedRange<TimeInterval>?
    let waveform: SnippetWaveform?
    let playhead: TimeInterval?

    func x(_ moment: TimeInterval, in window: ClosedRange<TimeInterval>, width: CGFloat) -> CGFloat {
        let span = window.upperBound - window.lowerBound
        return span > 0 ? CGFloat((moment - window.lowerBound) / span) * width : 0
    }

    func draw(in context: inout GraphicsContext, size: CGSize) {
        context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.white.opacity(0.05)))
        guard let window, window.upperBound > window.lowerBound else {
            drawPlaceholder(in: &context, size: size)
            return
        }
        let width = size.width, height = size.height

        if let selection {
            let startX = x(selection.lowerBound, in: window, width: width)
            let endX = x(selection.upperBound, in: window, width: width)
            context.fill(Path(CGRect(x: startX, y: 0, width: max(0, endX - startX), height: height)),
                         with: .color(accent.opacity(0.26)))
        }

        if let waveform, !waveform.peaks.isEmpty,
           waveform.window.lowerBound < window.upperBound, waveform.window.upperBound > window.lowerBound {
            let bin = (waveform.window.upperBound - waveform.window.lowerBound) / Double(waveform.peaks.count)
            let maxHeight = height - 8
            for (index, peak) in waveform.peaks.enumerated() {
                let moment = waveform.window.lowerBound + Double(index) * bin
                let startX = x(moment, in: window, width: width), endX = x(moment + bin, in: window, width: width)
                guard endX >= 0, startX <= width else { continue }
                let barWidth = max(1, endX - startX - 1)
                let barHeight = max(1.5, CGFloat(peak) * maxHeight)
                let inside = selection?.contains(moment + bin / 2) ?? false
                context.fill(Path(roundedRect: CGRect(x: startX, y: (height - barHeight) / 2, width: barWidth, height: barHeight),
                                  cornerRadius: min(barWidth, barHeight) / 2),
                             with: .color(.white.opacity(inside ? 0.88 : 0.3)))
            }
        } else {
            drawPlaceholder(in: &context, size: size)
        }

        if let selection {
            for moment in [selection.lowerBound, selection.upperBound] {
                let handleX = x(moment, in: window, width: width)
                context.fill(Path(roundedRect: CGRect(x: handleX - 1.5, y: 2, width: 3, height: height - 4), cornerRadius: 1.5),
                             with: .color(.white.opacity(0.92)))
            }
        }

        if let playhead, window.contains(playhead) {
            let headX = x(playhead, in: window, width: width)
            context.fill(Path(CGRect(x: headX - 0.75, y: 0, width: 1.5, height: height)), with: .color(.white))
        }
    }

    private func drawPlaceholder(in context: inout GraphicsContext, size: CGSize) {
        var path = Path()
        path.move(to: CGPoint(x: 6, y: size.height / 2))
        path.addLine(to: CGPoint(x: size.width - 6, y: size.height / 2))
        context.stroke(path, with: .color(.white.opacity(0.14)),
                       style: StrokeStyle(lineWidth: 1, lineCap: .round, dash: [2, 4]))
    }
}
