import Foundation

public enum AudioStreamKind: String, Codable, CaseIterable, Sendable {
    case mic
    case system

    public var displayName: String {
        switch self {
        case .mic: return "Microphone"
        case .system: return "System Audio"
        }
    }

    public var defaultSpeakerLabel: String {
        switch self {
        case .mic: return "Me"
        case .system: return "Speaker"
        }
    }

    public var fileBaseName: String { rawValue }
}
