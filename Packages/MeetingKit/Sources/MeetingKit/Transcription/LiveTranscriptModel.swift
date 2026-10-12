import Foundation
import Observation
import Speech

@MainActor
@Observable
public final class LiveTranscriptModel {
    public enum Status: Equatable {
        case idle
        case preparing(String)
        case listening
        case finishing
        case ended
        case unavailable(String)
    }

    public private(set) var transcript = LiveTranscript()
    public private(set) var status: Status = .idle
    public private(set) var startedAt: Date?
    public private(set) var meetingID: UUID?
    public var otherName = ""

    public static let defaultOtherLabel = "Them"
    public var otherLabel: String { namedOther ?? Self.defaultOtherLabel }
    public var namedOther: String? {
        let name = otherName.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    private var streams: [LiveStreamTranscriber] = []
    private var runTask: Task<Void, Never>?
    private var session = UUID()

    func begin(kinds: [AudioStreamKind], languageHint: String?) -> [AudioStreamKind: LiveStreamTranscriber] {
        stopStreams(cancel: true)
        let id = UUID()
        let start = Date()
        session = id
        startedAt = start
        meetingID = nil
        transcript = LiveTranscript()
        otherName = ""
        status = .preparing("Starting live transcript…")
        let created = kinds.map { LiveStreamTranscriber(kind: $0, sessionStart: start) }
        streams = created
        runTask = Task { [weak self] in await self?.run(created, languageHint: languageHint, session: id) }
        return Dictionary(uniqueKeysWithValues: created.map { ($0.kind, $0) })
    }

    func end(meetingID: UUID?) {
        self.meetingID = meetingID
        guard !streams.isEmpty else { return }
        stopStreams(cancel: false)
        switch status {
        case .preparing, .listening: status = .finishing
        default: break
        }
    }

    func cancel() {
        stopStreams(cancel: true)
        session = UUID()
        startedAt = nil
        status = .idle
    }

    private func stopStreams(cancel: Bool) {
        streams.forEach { $0.finish() }
        streams = []
        if cancel { runTask?.cancel() }
    }

    private func run(_ streams: [LiveStreamTranscriber], languageHint: String?, session id: UUID) async {
        do {
            guard SpeechTranscriber.isAvailable else {
                throw AudioError("On-device speech recognition isn't available on this Mac.")
            }
            let locale = await SpeechAnalyzerEngine.bestLocale(for: languageHint)
            let probe = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [probe]) {
                if session == id, case .preparing = status { status = .preparing("Downloading the speech model…") }
                try await request.downloadAndInstall()
            }
            if session == id, case .preparing = status { status = .listening }

            try await withThrowingTaskGroup(of: Void.self) { group in
                for stream in streams {
                    let kind = stream.kind
                    let (updates, sink) = AsyncStream.makeStream(of: LiveUpdate.self)
                    group.addTask {
                        defer { sink.finish() }
                        try await stream.run(locale: locale) { text, words, start, end, isFinal in
                            sink.yield(LiveUpdate(text: text, words: words, start: start, end: end, isFinal: isFinal))
                        }
                    }
                    group.addTask { @MainActor [weak self] in
                        for await u in updates {
                            guard let self, self.session == id else { continue }
                            self.transcript.apply(kind: kind, text: u.text, words: u.words,
                                                  start: u.start, end: u.end, isFinal: u.isFinal)
                        }
                        guard let self, self.session == id else { return }
                        self.transcript.discardPending(kind)
                    }
                }
                try await group.waitForAll()
            }
            if session == id, !Task.isCancelled { status = .ended }
        } catch {
            guard session == id, !Task.isCancelled else { return }
            status = .unavailable("Live transcript unavailable: \(error.localizedDescription)")
        }
    }
}

private struct LiveUpdate: Sendable {
    let text: String
    let words: [LiveTranscript.Word]
    let start: TimeInterval
    let end: TimeInterval
    let isFinal: Bool
}
