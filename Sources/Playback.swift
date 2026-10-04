import AVFoundation
import Observation

@MainActor @Observable
final class PhrasePlayer {
    enum Availability { case playable, notSaved, missing }

    static let shared = PhrasePlayer()

    private(set) var playing: UUID?
    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private var timer: Task<Void, Never>?
    @ObservationIgnored private var queue: [(url: URL, start: Double, end: Double)] = []

    static func availability(_ entry: HistoryEntry) -> Availability {
        guard let audio = entry.audio, !audio.isEmpty else { return .notSaved }
        return audio.allSatisfy { $0.url != nil } ? .playable : .missing
    }

    func toggle(_ entry: HistoryEntry) {
        let again = playing == entry.id
        stop()
        guard !again else { return }
        queue = (entry.audio ?? []).compactMap { ref in ref.url.map { ($0, ref.start, ref.end) } }
        guard !queue.isEmpty else { return }
        playing = entry.id
        next()
    }

    func stop() {
        timer?.cancel()
        timer = nil
        player?.stop()
        player = nil
        queue = []
        playing = nil
    }

    private func next() {
        guard !queue.isEmpty else { return stop() }
        let part = queue.removeFirst()
        guard let player = try? AVAudioPlayer(contentsOf: part.url) else { return next() }
        self.player = player
        player.currentTime = max(0, part.start)
        player.play()
        let id = playing
        timer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0, part.end - part.start)))
            guard !Task.isCancelled, let self, self.playing == id else { return }
            self.next()
        }
    }
}
