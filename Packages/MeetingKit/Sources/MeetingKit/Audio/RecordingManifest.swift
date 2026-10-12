import Foundation

public struct AudioSegmentInfo: Codable, Equatable, Sendable, Identifiable {
    public var index: Int
    public var fileName: String
    public var startTime: TimeInterval
    public var duration: TimeInterval
    public var finalized: Bool

    public var id: Int { index }

    public init(index: Int, fileName: String, startTime: TimeInterval, duration: TimeInterval = 0, finalized: Bool = false) {
        self.index = index
        self.fileName = fileName
        self.startTime = startTime
        self.duration = duration
        self.finalized = finalized
    }
}

public struct StreamManifest: Codable, Equatable, Sendable {
    public var kind: AudioStreamKind
    public var sampleRate: Double
    public var channelCount: Int
    public var segments: [AudioSegmentInfo]
    public var unavailableReason: String?
    public var startOffset: TimeInterval

    public init(kind: AudioStreamKind, sampleRate: Double, channelCount: Int, segments: [AudioSegmentInfo] = [], unavailableReason: String? = nil, startOffset: TimeInterval = 0) {
        self.kind = kind
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.segments = segments
        self.unavailableReason = unavailableReason
        self.startOffset = startOffset
    }

    public var totalDuration: TimeInterval {
        segments.reduce(0) { $0 + $1.duration }
    }

    enum CodingKeys: String, CodingKey {
        case kind, sampleRate, channelCount, segments, unavailableReason, startOffset
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decode(AudioStreamKind.self, forKey: .kind)
        sampleRate = try c.decode(Double.self, forKey: .sampleRate)
        channelCount = try c.decode(Int.self, forKey: .channelCount)
        segments = try c.decode([AudioSegmentInfo].self, forKey: .segments)
        unavailableReason = try c.decodeIfPresent(String.self, forKey: .unavailableReason)
        startOffset = try c.decodeIfPresent(TimeInterval.self, forKey: .startOffset) ?? 0
    }
}

public struct RecordingManifest: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var sessionID: String
    public var title: String?
    public var startedAt: Date
    public var endedAt: Date?
    public var streams: [StreamManifest]

    public init(
        sessionID: String,
        title: String? = nil,
        startedAt: Date,
        endedAt: Date? = nil,
        streams: [StreamManifest] = [],
        schemaVersion: Int = 1
    ) {
        self.schemaVersion = schemaVersion
        self.sessionID = sessionID
        self.title = title
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.streams = streams
    }

    public var isInterrupted: Bool { endedAt == nil }

    public var duration: TimeInterval {
        streams.map(\.totalDuration).max() ?? 0
    }

    public func stream(_ kind: AudioStreamKind) -> StreamManifest? {
        streams.first { $0.kind == kind }
    }

    public func streamLeadingSilence() -> [AudioStreamKind: TimeInterval] {
        let present = streams.filter { !$0.segments.isEmpty }
        guard present.count > 1 else { return [:] }
        var out: [AudioStreamKind: TimeInterval] = [:]
        if present.contains(where: { $0.startOffset > 0.05 }) {
            let minOffset = present.map(\.startOffset).min() ?? 0
            for s in present { out[s.kind] = max(0, s.startOffset - minOffset) }
        } else {
            let maxDur = present.map(\.totalDuration).max() ?? 0
            for s in present {
                let pad = maxDur - s.totalDuration
                out[s.kind] = pad > 0.1 ? pad : 0
            }
        }
        return out
    }

    public mutating func upsertStream(_ stream: StreamManifest) {
        if let i = streams.firstIndex(where: { $0.kind == stream.kind }) {
            streams[i] = stream
        } else {
            streams.append(stream)
        }
    }

    public mutating func appendSegment(_ segment: AudioSegmentInfo, to kind: AudioStreamKind) {
        guard let i = streams.firstIndex(where: { $0.kind == kind }) else { return }
        if let j = streams[i].segments.firstIndex(where: { $0.index == segment.index }) {
            streams[i].segments[j] = segment
        } else {
            streams[i].segments.append(segment)
        }
    }
}
