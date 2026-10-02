import AVFoundation
import AppKit
import ApplicationServices
import Observation
import ServiceManagement

/// What the app needs from the system and from the user, with its current state: the microphone it records from, the
/// Accessibility access that lets it type and watch hotkeys, the API keys for AI cleanup, and whether it starts with
/// the Mac. Everything here is optional — what is missing only costs the part of the app that needs it.
@MainActor @Observable
final class Setup {
    enum Access: Equatable { case granted, denied, notAsked }

    static let shared = Setup()

    private(set) var microphone = Access.notAsked
    private(set) var accessibility = false
    private(set) var keys: [String: Bool] = [:]  // key id to whether one is stored
    private(set) var openAtLogin = false
    /// What went wrong the last time something was set, for the line under the row.
    private(set) var trouble: String?

    private var timer: Timer?
    private var watchers = 0

    private init() { refresh() }

    /// True until the first launch has been seen through, so the window comes back if it was dismissed early.
    private static let seenKey = "setupSeen"

    /// The onboarding window opens on the first launch, and after that only while something essential is missing.
    var needsOnboarding: Bool {
        !UserDefaults.standard.bool(forKey: Self.seenKey) || microphone != .granted || !accessibility
    }

    func seen() { UserDefaults.standard.set(true, forKey: Self.seenKey) }

    func refresh() {
        microphone = switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: .granted
        case .notDetermined: .notAsked
        default: .denied
        }
        accessibility = AXIsProcessTrusted()
        keys = Dictionary(uniqueKeysWithValues: ApiKey.all.map { ($0.id, Keychain.shared.value(for: $0.id) != nil) })
        openAtLogin = isBundled && SMAppService.mainApp.status == .enabled
    }

    /// Grants can only be seen by looking: while a window shows them, they are read twice a second.
    func watch() {
        watchers += 1
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            MainActor.assumeIsolated { self.refresh() }
        }
    }

    func unwatch() {
        watchers -= 1
        guard watchers <= 0 else { return }
        watchers = 0
        timer?.invalidate()
        timer = nil
    }

    // MARK: - Microphone

    /// Asks for the microphone. The engine runs as our child process, so its recording is attributed to us and this
    /// is the only grant involved. Once the user has answered once, only System Settings can change it.
    func askForMicrophone() {
        guard microphone == .notAsked else { return openPane("Privacy_Microphone") }
        AVCaptureDevice.requestAccess(for: .audio) { _ in
            Task { @MainActor in self.refresh() }
        }
    }

    // MARK: - Accessibility

    /// Asks for Accessibility access: the system's own prompt, and the pane it leads to, since the prompt only
    /// appears the first time. `watch()` picks the grant up as soon as it is given.
    func askForAccessibility() {
        let prompted = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        accessibility = prompted
        if !prompted { openPane("Privacy_Accessibility") }
    }

    func openPane(_ anchor: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Keys

    func store(_ value: String?, for key: ApiKey) {
        let status = Keychain.shared.set(value, for: key.id)
        trouble = status == errSecSuccess ? nil : "The keychain refused the \(key.name) key (\(status))."
        refresh()
    }

    /// The keys `~/.env` holds that are not stored yet. Nothing is read from it unless the user asks.
    func importable() -> [ApiKey] {
        let found = ApiKey.inDotEnv()
        return ApiKey.all.filter { found[$0.id] != nil && keys[$0.id] != true }
    }

    /// Copies the keys from `~/.env` into the keychain, on the user's say-so.
    func importFromDotEnv() {
        let found = ApiKey.inDotEnv()
        for key in ApiKey.all where keys[key.id] != true {
            if let value = found[key.id] { Keychain.shared.set(value, for: key.id) }
        }
        refresh()
    }

    // MARK: - Open at login

    var isBundled: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    func setOpenAtLogin(_ wanted: Bool) {
        guard isBundled else { return trouble = "Open at login needs the installed app, not this build." }
        do {
            if wanted { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            trouble = nil
        } catch {
            trouble = "Could not \(wanted ? "add" : "remove") the login item: \(error.localizedDescription)"
        }
        refresh()
    }
}
