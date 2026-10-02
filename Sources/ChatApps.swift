import AppKit
import Observation
import SwiftUI

/// A colour kept as `#RRGGBB` or `#RRGGBBAA`, so a profile can be edited by hand.
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

/// The corner of the app's window a rectangle is measured from, so resizing the window keeps the rectangle where it
/// belongs.
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

/// A rectangle in points, held as the gap from one corner of the app's window to its nearest edges, plus its size.
/// Everything is in AppKit screen points with the origin at the bottom left.
struct AnchoredRect: Codable, Equatable {
    var corner = Corner.bottomRight
    var x = 0.0       // from the corner's side to the rectangle's near vertical edge
    var y = 0.0       // from the corner's side to the rectangle's near horizontal edge
    var width = 0.0
    var height = 0.0

    var isSet: Bool { width > 0 && height > 0 }

    /// Where this rectangle lands for a window at `window`.
    func resolve(in window: NSRect) -> NSRect {
        NSRect(x: corner.isRight ? window.maxX - x - width : window.minX + x,
               y: corner.isTop ? window.maxY - y - height : window.minY + y,
               width: width, height: height)
    }

    /// The same rectangle written down against `window`, as Detect does it.
    static func measure(_ rect: NSRect, in window: NSRect, corner: Corner) -> AnchoredRect {
        AnchoredRect(corner: corner,
                     x: corner.isRight ? window.maxX - rect.maxX : rect.minX - window.minX,
                     y: corner.isTop ? window.maxY - rect.maxY : rect.minY - window.minY,
                     width: rect.width, height: rect.height)
    }
}

/// How the Iridium button beside an app's Send button looks.
struct DockButtonStyle: Codable, Equatable {
    var symbol = "mic.fill"
    var symbolSize = 15.0
    var cornerRadius = 17.0  // half the size is a circle, 0 a square
    var fill = Colour("#25D366")
    var activeFill = Colour("#FF4A4F")
    var symbolColour = Colour("#FFFFFF")
    var shadow = 0.35
}

/// How the panel above the message box looks while a dictation runs.
struct DockOverlayStyle: Codable, Equatable {
    var width = 360.0
    var height = 86.0
    var gap = 10.0  // above the message box
    var fontSize = 13.0
    var cornerRadius = 14.0
    var opacity = 1.0
    var background = Colour("#0B141AEE")
    var textColour = Colour("#E9EDEF")
    var accentColour = Colour("#25D366")
}

/// One chat app: where its message box and Send button are, how the dock looks on it, and what dictating there does.
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
    var sendButton = AnchoredRect()  // the app's own Send button, for auto-send
    var buttonStyle = DockButtonStyle()
    var overlayStyle = DockOverlayStyle()

    var id: String { bundleID }

    /// The dock can only show once Detect (or a hand edit) has filled in both rectangles.
    var isPlaced: Bool { button.isSet && box.isSet }

    static func seed(bundleID: String, name: String) -> ChatAppProfile {
        ChatAppProfile(bundleID: bundleID, name: name)
    }

    /// WhatsApp's green, on a circle the size of its own composer buttons.
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

    /// Telegram's blue, on a slightly smaller circle, with its darker navy panel. Telegram draws its own interface
    /// and shows accessibility nothing inside its window, so Detect finds nothing there: its rectangles are typed
    /// in by hand, and its message goes in through the pasteboard and is sent with Return.
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

/// The chat apps as saved in `chat-apps.json`, next to the notes. The file is the whole truth: positions, styles and
/// switches all come from it, and it is written back whenever anything changes, so it can equally well be edited by
/// hand.
@MainActor @Observable
final class ChatApps {
    var enabled = true {
        didSet { if enabled != oldValue { changed() } }
    }
    var apps: [ChatAppProfile] = [] {
        didSet { if apps != oldValue { changed() } }
    }
    /// Called after every change, once the file is written: the dock puts itself where the profiles now say.
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

    /// Adds an app that is not in the file yet, with the default look.
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

/// A key that may be missing from a hand-edited file keeps the default.
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
    }
}
