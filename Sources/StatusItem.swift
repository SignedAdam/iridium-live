import AppKit
import Observation
import SwiftUI

/// Iridium Live in the menu bar: a waveform, red while recording. A click opens the app's own glass menu under it
/// (recording, show or hide the control, the panes, unloading, quitting); a second click closes it.
@MainActor
final class StatusItem: NSObject {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let model: AppModel

    init(model: AppModel) {
        self.model = model
        super.init()
        item.button?.target = self
        item.button?.action = #selector(open)
        item.button?.sendAction(on: [.leftMouseDown, .rightMouseDown])
        item.button?.toolTip = "Iridium Live"
        follow()
    }

    @objc private func open() {
        guard !MenuPanel.justClosed, let button = item.button, let window = button.window else { return }
        MenuPanel.show(statusMenuItems(model), under: window.convertToScreen(button.convert(button.bounds, to: nil)))
    }

    private func follow() {
        withObservationTracking { draw(recording: model.recording) } onChange: { [weak self] in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.follow() } }
        }
    }

    private func draw(recording: Bool) {
        var symbol = NSImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
        if recording { symbol = symbol.applying(NSImage.SymbolConfiguration(paletteColors: [NSColor(accent)])) }
        let image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Iridium Live")?
            .withSymbolConfiguration(symbol)
        image?.isTemplate = !recording  // the menu bar's own colour, until it is recording
        item.button?.image = image
    }
}
