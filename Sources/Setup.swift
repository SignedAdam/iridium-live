import AVFoundation
import AppKit
import ApplicationServices
import Observation
import Security
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

    /// True while the user is in System Settings because a button here sent them: the app's floating windows step
    /// down to the normal level meanwhile, so Settings comes up in front of them rather than underneath. It ends
    /// with the grant they went for, or when they move on to any other app.
    private(set) var inSystemSettings = false
    private static let settingsApps: Set<String> = ["com.apple.systempreferences",
                                                    "com.apple.accessibility.universalAccessAuthWarn"]

    private init() {
        refresh()
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                                                          object: nil, queue: .main) { note in
            let app = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
            MainActor.assumeIsolated {
                guard let app, !Self.settingsApps.contains(app) else { return }
                Setup.shared.inSystemSettings = false
            }
        }
    }

    /// True until the first launch has been seen through, so the window comes back if it was dismissed early.
    private static let seenKey = "setupSeen"

    /// The onboarding window opens on the first launch, and after that only while something essential is missing.
    var needsOnboarding: Bool {
        !UserDefaults.standard.bool(forKey: Self.seenKey) || microphone != .granted || !accessibility
    }

    func seen() { UserDefaults.standard.set(true, forKey: Self.seenKey) }

    func refresh() {
        let heard = microphone == .granted, trusted = accessibility
        microphone = switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: .granted
        case .notDetermined: .notAsked
        default: .denied
        }
        accessibility = AXIsProcessTrusted()
        if inSystemSettings, (microphone == .granted && !heard) || (accessibility && !trusted) { inSystemSettings = false }
        let held = Keychain.shared.stored()
        keys = Dictionary(uniqueKeysWithValues: ApiKey.all.map { ($0.id, held.contains($0.id)) })
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
    /// appears the first time. `watch()` picks the grant up as soon as it is given. An entry made for an earlier build
    /// of the app (each build is signed on its own unless the stable certificate is in use) shows as switched on yet
    /// never applies to this one, so the first Allow of each build clears it. Only the first: a second click would
    /// clear the entry the first one just made, and macOS does not make it again.
    func askForAccessibility() {
        if isBundled, let bundleID = Bundle.main.bundleIdentifier, let build = Self.build,
           UserDefaults.standard.string(forKey: Self.clearedKey) != build {
            UserDefaults.standard.set(build, forKey: Self.clearedKey)
            let reset = Process()
            reset.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
            reset.arguments = ["reset", "Accessibility", bundleID]
            try? reset.run()
            reset.waitUntilExit()
        }
        let prompted = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        accessibility = prompted
        if !prompted { openPane("Privacy_Accessibility") }
    }

    private static let clearedKey = "accessibilityClearedFor"

    /// This build's code directory hash: what macOS tells one build of the app from another by.
    private static let build: String? = {
        var code: SecCode?
        var staticCode: SecStaticCode?
        var info: CFDictionary?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopySigningInformation(staticCode, [], &info) == errSecSuccess,
              let hash = (info as? [String: Any])?[kSecCodeInfoUnique as String] as? Data else { return nil }
        return hash.map { String(format: "%02x", $0) }.joined()
    }()

    func openPane(_ anchor: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") else { return }
        inSystemSettings = true
        DispatchQueue.main.async { NSWorkspace.shared.open(url) }  // once the windows have stepped down
    }

    // MARK: - Keys

    func store(_ value: String?, for key: ApiKey) {
        let status = Keychain.shared.set(value, for: key.id)
        trouble = status == errSecSuccess ? nil : "The keychain refused the \(key.name) key (\(status))."
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
