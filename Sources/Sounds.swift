import AVFoundation

/// The sounds of a dictation: start, release, and done once its text is typed (Resources/Sounds, from Freesound, CC0).
@MainActor
final class Sounds {
    enum Cue: String, CaseIterable { case start, stop, done }

    var isOn = false {
        didSet { if isOn != oldValue { load() } }
    }
    private var players: [Cue: AVAudioPlayer] = [:]

    func play(_ cue: Cue) {
        guard let player = players[cue] else { return }
        player.currentTime = 0
        player.play()
    }

    /// All three in order, as a dictation would play them: for hearing them when switched on in Settings.
    func preview() {
        play(.start)
        for (cue, after) in [(Cue.stop, 1.6), (.done, 2.6)] {
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(after))
                self?.play(cue)
            }
        }
    }

    private func load() {
        players = [:]
        guard isOn else { return }
        let folder = AppResources.directory.appendingPathComponent("Sounds")
        for cue in Cue.allCases {
            guard let player = try? AVAudioPlayer(contentsOf: folder.appendingPathComponent("\(cue.rawValue).wav")) else { continue }
            player.volume = 0.6
            player.prepareToPlay()
            players[cue] = player
        }
    }
}
