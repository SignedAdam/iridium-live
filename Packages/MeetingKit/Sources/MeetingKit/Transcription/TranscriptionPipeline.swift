import Foundation

struct TranscriptionPipeline {
    var systemDiarizer: SystemChannelDiarizing?

    func transcribe(
        manifest: RecordingManifest,
        folder: URL,
        engine: TranscriptionEngine,
        options: TranscriptionOptions,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> Transcript {
        let preparer = AudioPreparer()
        let pads = manifest.streamLeadingSilence()
        var micURL = try manifest.stream(.mic).flatMap { try preparer.prepareStream($0, in: folder, leadingSilence: pads[.mic] ?? 0) }
        let systemURL = try manifest.stream(.system).flatMap { try preparer.prepareStream($0, in: folder, leadingSilence: pads[.system] ?? 0) }

        guard micURL != nil || systemURL != nil else { throw TranscriptionError.noAudio }

        if let mic = micURL, let systemURL,
           Self.detectSpeakerBleed(micURL: mic, systemURL: systemURL, preparer: preparer) {
            if let cleaned = Self.cancelEchoOffline(micURL: mic, systemURL: systemURL, folder: folder, preparer: preparer),
               !Self.detectSpeakerBleed(micURL: cleaned, systemURL: systemURL, preparer: preparer) {
                micURL = cleaned
            } else {
                return try await micOnlyPath(micURL: mic, systemURL: systemURL, folder: folder,
                                             engine: engine, options: options, progress: progress)
            }
        }

        if engine.supportsDiarization {
            return try await diarizingPath(micURL: micURL, systemURL: systemURL, folder: folder,
                                           engine: engine, options: options, progress: progress)
        } else {
            return try await channelPath(micURL: micURL, systemURL: systemURL, folder: folder,
                                         preparer: preparer, engine: engine, options: options, progress: progress)
        }
    }

    private func diarizingPath(
        micURL: URL?, systemURL: URL?, folder: URL,
        engine: TranscriptionEngine, options: TranscriptionOptions,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> Transcript {
        let preparer = AudioPreparer()
        let inputs = [micURL, systemURL].compactMap { $0 }
        let audioURL: URL
        if inputs.count == 1 {
            audioURL = inputs[0]
        } else {
            audioURL = try preparer.mix(inputs, to: folder.appendingPathComponent("combined-16k.wav"))
        }
        let raw = try await engine.transcribe(fileURL: audioURL, options: options, progress: progress)
        let turns = DiarizationMerger.makeTurns(words: raw.words,
                                                segments: raw.speakerSegments ?? [],
                                                fallback: "Speaker 1")
        return Transcript(turns: relabel(turns), language: raw.language, engineID: engine.id)
    }

    private func channelPath(
        micURL: URL?, systemURL: URL?, folder: URL, preparer: AudioPreparer,
        engine: TranscriptionEngine, options: TranscriptionOptions,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> Transcript {
        var language: String?

        let steps = [micURL, systemURL].compactMap { $0 }.count
        var completed = 0
        func stepProgress(_ base: Int) -> @Sendable (Double) -> Void {
            { p in progress((Double(base) + p) / Double(max(1, steps))) }
        }

        var micWords: [TranscriptWord] = []
        if let micURL {
            let raw = try await engine.transcribe(fileURL: micURL, options: options, progress: stepProgress(completed))
            micWords = raw.words
            language = language ?? raw.language
            completed += 1
        }

        var systemWords: [TranscriptWord] = []
        var systemChannels: [(speaker: String, words: [TranscriptWord])] = []
        if let systemURL {
            let raw = try await engine.transcribe(fileURL: systemURL, options: options, progress: stepProgress(completed))
            systemWords = raw.words
            language = language ?? raw.language
            if let diarizer = systemDiarizer,
               let segments = try? await diarizer.diarizeSystemChannel(fileURL: systemURL), !segments.isEmpty {
                let assigned = DiarizationMerger.assignSpeakers(words: raw.words, segments: segments, fallback: "Speaker 1")
                systemChannels.append(("", assigned))
            } else {
                systemChannels.append(("Speaker 1", raw.words))
            }
            completed += 1
        }

        let lag = Self.estimateLag(micWords: micWords, systemWords: systemWords)
        let alignedSystemWords = Self.shifted(systemWords, by: lag)
        let alignedSystemChannels = systemChannels.map { (speaker: $0.speaker, words: Self.shifted($0.words, by: lag)) }
        let cleanedMic = Self.suppressEcho(micWords: micWords, systemWords: alignedSystemWords)

        var channels: [(speaker: String, words: [TranscriptWord])] = []
        if !cleanedMic.isEmpty {
            channels.append((AudioStreamKind.mic.defaultSpeakerLabel, cleanedMic))
        }
        channels.append(contentsOf: alignedSystemChannels)

        let merged = DiarizationMerger.mergeChannels(channels)
        let turns = DiarizationMerger.buildTurns(from: merged)
        progress(1.0)
        return Transcript(turns: relabel(turns), language: language, engineID: engine.id)
    }

    private func micOnlyPath(
        micURL: URL, systemURL: URL, folder: URL,
        engine: TranscriptionEngine, options: TranscriptionOptions,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> Transcript {
        let raw = try await engine.transcribe(fileURL: micURL, options: options, progress: progress)

        let diarized: [TranscriptWord]
        if engine.supportsDiarization, let segments = raw.speakerSegments, !segments.isEmpty {
            diarized = DiarizationMerger.assignSpeakers(words: raw.words, segments: segments, fallback: "Speaker 1")
        } else if let diarizer = systemDiarizer,
                  let segments = try? await diarizer.diarizeSystemChannel(fileURL: micURL), !segments.isEmpty {
            diarized = DiarizationMerger.assignSpeakers(words: raw.words, segments: segments, fallback: "Speaker 1")
        } else {
            diarized = raw.words.map { var w = $0; if w.speakerID == nil { w.speakerID = "Speaker 1" }; return w }
        }

        let labeled = labelLocalSpeaker(diarized, systemURL: systemURL)
        let turns = DiarizationMerger.buildTurns(from: labeled)
        progress(1.0)
        return Transcript(turns: relabel(turns), language: raw.language, engineID: engine.id)
    }

    private func labelLocalSpeaker(_ words: [TranscriptWord], systemURL: URL) -> [TranscriptWord] {
        guard let sys = try? AudioPreparer().loadMonoFloats(systemURL), sys.sampleRate > 0 else { return words }
        let frame = 0.05
        let env = SpeakerBleed.envelope(sys.samples, sys.sampleRate)
        guard let peak = env.max(), peak > 0 else { return words }
        let gate = max(0.01, peak * 0.08)
        func systemActive(at t: TimeInterval) -> Bool {
            let i = Int(t / frame)
            return i >= 0 && i < env.count && env[i] > gate
        }
        var total: [String: Double] = [:]
        var during: [String: Double] = [:]
        for w in words {
            guard let s = w.speakerID else { continue }
            let dur = max(0, w.end - w.start)
            total[s, default: 0] += dur
            if systemActive(at: (w.start + w.end) / 2) { during[s, default: 0] += dur }
        }
        guard total.count >= 2,
              let meID = total.min(by: { a, b in
                  (during[a.key, default: 0] / max(0.01, a.value)) < (during[b.key, default: 0] / max(0.01, b.value))
              })?.key else { return words }
        return words.map { var w = $0; if w.speakerID == meID { w.speakerID = AudioStreamKind.mic.defaultSpeakerLabel }; return w }
    }

    static func detectSpeakerBleed(micURL: URL, systemURL: URL, preparer: AudioPreparer) -> Bool {
        guard let mic = try? preparer.loadMonoFloats(micURL), mic.sampleRate > 0,
              let sys = try? preparer.loadMonoFloats(systemURL), sys.sampleRate > 0 else { return false }
        return SpeakerBleed.isBleeding(mic.samples, mic.sampleRate, sys.samples, sys.sampleRate)
    }

    static func cancelEchoOffline(micURL: URL, systemURL: URL, folder: URL, preparer: AudioPreparer) -> URL? {
        guard let mic = try? preparer.loadMonoFloats(micURL), mic.sampleRate > 0,
              let sys = try? preparer.loadMonoFloats(systemURL), sys.sampleRate == mic.sampleRate,
              let outcome = EchoCanceller.cancel(mic: mic.samples, reference: sys.samples, sampleRate: mic.sampleRate)
        else { return nil }
        let outURL = folder.appendingPathComponent("mic-clean-16k.wav")
        guard (try? preparer.writeMonoFloats(outcome.samples, to: outURL)) != nil else { return nil }
        return outURL
    }

    static func estimateLag(micWords: [TranscriptWord], systemWords: [TranscriptWord]) -> Double {
        guard micWords.count >= 20, systemWords.count >= 20 else { return 0 }
        var sysByText: [String: [Double]] = [:]
        for w in systemWords {
            let t = normalizeWord(w.text)
            if t.count >= 3 { sysByText[t, default: []].append(w.start) }
        }
        let bin = 0.2
        var hist: [Int: Int] = [:]
        for w in micWords {
            let t = normalizeWord(w.text)
            guard t.count >= 3, let times = sysByText[t] else { continue }
            for st in times where abs(w.start - st) <= 10 {
                hist[Int(((w.start - st) / bin).rounded()), default: 0] += 1
            }
        }
        guard let peak = hist.max(by: { $0.value < $1.value }), peak.value >= 12 else { return 0 }
        return Double(peak.key) * bin
    }

    private static func shifted(_ words: [TranscriptWord], by lag: Double) -> [TranscriptWord] {
        guard lag != 0 else { return words }
        return words.map { var w = $0; w.start += lag; w.end += lag; return w }
    }

    static func suppressEcho(micWords: [TranscriptWord], systemWords: [TranscriptWord]) -> [TranscriptWord] {
        guard !micWords.isEmpty, !systemWords.isEmpty else { return micWords }
        let window = 1.0
        let sys = systemWords.map { (start: $0.start, text: normalizeWord($0.text)) }
        let flags = micWords.map { w -> Bool in
            let nt = normalizeWord(w.text)
            guard !nt.isEmpty else { return false }
            return sys.contains { abs($0.start - w.start) <= window && $0.text == nt }
        }
        var drop = [Bool](repeating: false, count: micWords.count)
        var i = 0
        while i < flags.count {
            if flags[i] {
                var j = i
                while j < flags.count, flags[j] { j += 1 }
                if j - i >= 2 { for k in i..<j { drop[k] = true } }
                i = j
            } else { i += 1 }
        }
        return zip(micWords, drop).compactMap { $0.1 ? nil : $0.0 }
    }

    private static func normalizeWord(_ s: String) -> String {
        String(s.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
    }

    private func relabel(_ turns: [SpeakerTurn]) -> [SpeakerTurn] {
        var mapping: [String: String] = [:]
        var nextIndex = 1
        return turns.map { turn in
            var t = turn
            if turn.speakerID == AudioStreamKind.mic.defaultSpeakerLabel {
                t.speakerID = AudioStreamKind.mic.defaultSpeakerLabel
            } else if let mapped = mapping[turn.speakerID] {
                t.speakerID = mapped
            } else {
                let label = "Speaker \(nextIndex)"
                nextIndex += 1
                mapping[turn.speakerID] = label
                t.speakerID = label
            }
            return t
        }
    }
}

protocol SystemChannelDiarizing: Sendable {
    func diarizeSystemChannel(fileURL: URL) async throws -> [DiarizationSegment]
}
