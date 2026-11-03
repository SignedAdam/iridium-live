import AVFoundation

/// The sounds of a dictation: start, release, and done once its text is typed. Each cue is a few takes of the same
/// physical sound (Resources/Sounds/synth.py), played without repeating the last one, so a sound heard all day never
/// comes out identical twice.
@MainActor
final class Sounds {
    enum Cue: String, CaseIterable { case start, stop, done }

    var set = Settings.Sounds.off {
        didSet { if set != oldValue { load() } }
    }
    private var takes: [Cue: [AVAudioPlayer]] = [:]
    private var last: [Cue: Int] = [:]

    func play(_ cue: Cue) {
        guard let players = takes[cue], !players.isEmpty else { return }
        var pick = Int.random(in: 0..<players.count)
        if players.count > 1, pick == last[cue] { pick = (pick + 1) % players.count }
        last[cue] = pick
        players[pick].currentTime = 0
        players[pick].play()
    }

    /// All three in order, as a dictation would play them: for choosing a set in Settings.
    func preview() {
        play(.start)
        for (cue, after) in [(Cue.stop, 0.55), (.done, 1.25)] {
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(after))
                self?.play(cue)
            }
        }
    }

    private func load() {
        takes = [:]
        last = [:]
        guard set != .off else { return }
        let folder = AppResources.directory.appendingPathComponent("Sounds")
        for cue in Cue.allCases {
            takes[cue] = (1...8).compactMap { take in
                let player = try? AVAudioPlayer(contentsOf: folder.appendingPathComponent("\(set.rawValue)-\(cue.rawValue)-\(take).wav"))
                player?.prepareToPlay()
                return player
            }
        }
    }
}
