import AppKit
import Observation
import SwiftUI

struct Colour: Codable, Equatable {
    var red = 1.0
    var green = 1.0
    var blue = 1.0
    var alpha = 1.0

    init(_ hex: String) {
        let digits = hex.drop { $0 == "#" }
        let value = UInt64(digits, radix: 16) ?? 0xFFFFFF
        let bytes: [Double] = digits.count == 8
            ? [Double((value >> 24) & 255), Double((value >> 16) & 255), Double((value >> 8) & 255), Double(value & 255)]
            : [Double((value >> 16) & 255), Double((value >> 8) & 255), Double(value & 255), 255]
        (red, green, blue, alpha) = (bytes[0] / 255, bytes[1] / 255, bytes[2] / 255, bytes[3] / 255)
    }

    init(from decoder: Decoder) throws {
        self.init(try decoder.singleValueContainer().decode(String.self))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(hex)
    }

    var hex: String {
        let parts = [red, green, blue, alpha].map { Int(($0 * 255).rounded()) }
        return "#" + (alpha >= 1 ? parts.dropLast() : parts[...]).map { String(format: "%02X", $0) }.joined()
    }

    var color: Color { Color(.sRGB, red: red, green: green, blue: blue, opacity: alpha) }
}

enum Corner: String, Codable, CaseIterable {
    case bottomLeft, bottomRight, topLeft, topRight

    var name: String {
        switch self {
        case .bottomLeft: "Bottom left"
        case .bottomRight: "Bottom right"
        case .topLeft: "Top left"
        case .topRight: "Top right"
        }
    }

    var isRight: Bool { self == .bottomRight || self == .topRight }
    var isTop: Bool { self == .topLeft || self == .topRight }
}

struct AnchoredRect: Codable, Equatable {
    var corner = Corner.bottomRight
    var x = 0.0
    var y = 0.0
    var width = 0.0
    var height = 0.0

    var isSet: Bool { width > 0 && height > 0 }

    func resolve(in window: NSRect) -> NSRect {
        NSRect(x: corner.isRight ? window.maxX - x - width : window.minX + x,
               y: corner.isTop ? window.maxY - y - height : window.minY + y,
               width: width, height: height)
    }

    static func measure(_ rect: NSRect, in window: NSRect, corner: Corner) -> AnchoredRect {
        AnchoredRect(corner: corner,
                     x: corner.isRight ? window.maxX - rect.maxX : rect.minX - window.minX,
                     y: corner.isTop ? window.maxY - rect.maxY : rect.minY - window.minY,
                     width: rect.width, height: rect.height)
    }
}

struct DockButtonStyle: Codable, Equatable {
    var symbol = "mic.fill"
    var symbolSize = 15.0
    var cornerRadius = 17.0
    var fill = Colour("#25D366")
    var activeFill = Colour("#FF4A4F")
    var symbolColour = Colour("#FFFFFF")
    var shadow = 0.35
}

struct DockOverlayStyle: Codable, Equatable {
    var width = 360.0
    var height = 86.0
    var gap = 10.0
    var fontSize = 13.0
    var cornerRadius = 14.0
    var opacity = 1.0
    var background = Colour("#0B141AEE")
    var textColour = Colour("#E9EDEF")
    var accentColour = Colour("#25D366")
    var attached = true
    var joinColour = Colour("#0A0A0A")
}

struct ChatAppProfile: Codable, Equatable, Identifiable {
    enum Mode: String, Codable { case stream, collect }
    enum Send: String, Codable { case press, returnKey }
    enum Insertion: String, Codable { case accessibility, paste }

    var bundleID = ""
    var name = ""
    var enabled = true
    var mode = Mode.stream
    var autoSend = false
    var send = Send.press
    var insertion = Insertion.accessibility
    var hideCaptions = true
    var button = AnchoredRect()
    var box = AnchoredRect(corner: .bottomLeft)
    var sendButton = AnchoredRect()
    var overVoiceButton = false
    var buttonStyle = DockButtonStyle()
    var overlayStyle = DockOverlayStyle()

    var id: String { bundleID }

    var isPlaced: Bool { button.isSet && box.isSet }

    static func seed(bundleID: String, name: String) -> ChatAppProfile {
        ChatAppProfile(bundleID: bundleID, name: name)
    }

    static let whatsApp: ChatAppProfile = {
        var profile = ChatAppProfile(bundleID: "net.whatsapp.WhatsApp", name: "WhatsApp")
        profile.buttonStyle = DockButtonStyle(symbol: "mic.fill", symbolSize: 15, cornerRadius: 17,
                                              fill: Colour("#25D366"), activeFill: Colour("#FF4A4F"),
                                              symbolColour: Colour("#FFFFFF"), shadow: 0.35)
        profile.overlayStyle = DockOverlayStyle(width: 360, height: 86, gap: 10, fontSize: 13, cornerRadius: 14,
                                                opacity: 1, background: Colour("#0B141AF2"),
                                                textColour: Colour("#E9EDEF"), accentColour: Colour("#25D366"))
        return profile
    }()

    static let telegram: ChatAppProfile = {
        var profile = ChatAppProfile(bundleID: "ru.keepcoder.Telegram", name: "Telegram")
        profile.insertion = .paste
        profile.send = .returnKey
        profile.buttonStyle = DockButtonStyle(symbol: "mic.fill", symbolSize: 14, cornerRadius: 15,
                                              fill: Colour("#2AABEE"), activeFill: Colour("#FF4A4F"),
                                              symbolColour: Colour("#FFFFFF"), shadow: 0.3)
        profile.overlayStyle = DockOverlayStyle(width: 340, height: 84, gap: 8, fontSize: 13, cornerRadius: 12,
                                                opacity: 1, background: Colour("#17212BF2"),
                                                textColour: Colour("#FFFFFF"), accentColour: Colour("#2AABEE"))
        return profile
    }()
}

@MainActor @Observable
final class ChatApps {
    var enabled = true {
        didSet { if enabled != oldValue { changed() } }
    }
    var apps: [ChatAppProfile] = [] {
        didSet { if apps != oldValue { changed() } }
    }
    @ObservationIgnored var onChange: () -> Void = {}

    @ObservationIgnored private let file: URL

    init(directory: URL) {
        file = directory.appendingPathComponent("chat-apps.json")
        if let data = try? Data(contentsOf: file), let saved = try? JSONDecoder().decode(Stored.self, from: data) {
            enabled = saved.enabled
            apps = saved.apps
        } else {
            apps = [.whatsApp, .telegram]
            write()
        }
    }

    func profile(for bundleID: String?) -> ChatAppProfile? {
        bundleID.flatMap { id in apps.first { $0.bundleID == id } }
    }

    func index(of bundleID: String) -> Int? {
        apps.firstIndex { $0.bundleID == bundleID }
    }

    func add(bundleID: String, name: String) {
        guard index(of: bundleID) == nil else { return }
        apps.append(.seed(bundleID: bundleID, name: name))
    }

    func remove(bundleID: String) {
        apps.removeAll { $0.bundleID == bundleID }
    }

    private func changed() {
        write()
        onChange()
    }

    private func write() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(Stored(enabled: enabled, apps: apps)) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }

    private struct Stored: Codable {
        var enabled = true
        var apps: [ChatAppProfile] = []

        init(enabled: Bool, apps: [ChatAppProfile]) {
            self.enabled = enabled
            self.apps = apps
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            enabled = container.value(.enabled, true)
            apps = container.value(.apps, [])
        }
    }
}

extension KeyedDecodingContainer {
    func value<T: Decodable>(_ key: Key, _ fallback: T) -> T {
        ((try? decodeIfPresent(T.self, forKey: key)) ?? nil) ?? fallback
    }
}

extension ChatAppProfile {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        bundleID = container.value(.bundleID, "")
        name = container.value(.name, "")
        enabled = container.value(.enabled, true)
        mode = container.value(.mode, Mode.stream)
        autoSend = container.value(.autoSend, false)
        send = container.value(.send, Send.press)
        insertion = container.value(.insertion, Insertion.accessibility)
        hideCaptions = container.value(.hideCaptions, true)
        button = container.value(.button, AnchoredRect())
        box = container.value(.box, AnchoredRect(corner: .bottomLeft))
        sendButton = container.value(.sendButton, AnchoredRect())
        overVoiceButton = container.value(.overVoiceButton, false)
        buttonStyle = container.value(.buttonStyle, DockButtonStyle())
        overlayStyle = container.value(.overlayStyle, DockOverlayStyle())
    }
}

extension AnchoredRect {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        corner = container.value(.corner, Corner.bottomRight)
        x = container.value(.x, 0)
        y = container.value(.y, 0)
        width = container.value(.width, 0)
        height = container.value(.height, 0)
    }
}

extension DockButtonStyle {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        symbol = container.value(.symbol, "mic.fill")
        symbolSize = container.value(.symbolSize, 15)
        cornerRadius = container.value(.cornerRadius, 17)
        fill = container.value(.fill, Colour("#25D366"))
        activeFill = container.value(.activeFill, Colour("#FF4A4F"))
        symbolColour = container.value(.symbolColour, Colour("#FFFFFF"))
        shadow = container.value(.shadow, 0.35)
    }
}

extension DockOverlayStyle {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        width = container.value(.width, 360)
        height = container.value(.height, 86)
        gap = container.value(.gap, 10)
        fontSize = container.value(.fontSize, 13)
        cornerRadius = container.value(.cornerRadius, 14)
        opacity = container.value(.opacity, 1)
        background = container.value(.background, Colour("#0B141AEE"))
        textColour = container.value(.textColour, Colour("#E9EDEF"))
        accentColour = container.value(.accentColour, Colour("#25D366"))
        attached = container.value(.attached, true)
        joinColour = container.value(.joinColour, Colour("#0A0A0A"))
    }
}

