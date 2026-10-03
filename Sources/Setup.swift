import AVFoundation
import AppKit
import ApplicationServices
import Observation
import Security
import ServiceManagement

@MainActor @Observable
final class Setup {
    enum Access: Equatable { case granted, denied, notAsked }

    static let shared = Setup()

    private(set) var microphone = Access.notAsked
    private(set) var accessibility = false
    private(set) var keys: [String: Bool] = [:]
    private(set) var openAtLogin = false
    private(set) var trouble: String?

    private var timer: Timer?
    private var watchers = 0

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

    private static let seenKey = "setupSeen"

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

    func askForMicrophone() {
        guard microphone == .notAsked else { return openPane("Privacy_Microphone") }
        AVCaptureDevice.requestAccess(for: .audio) { _ in
            Task { @MainActor in self.refresh() }
        }
    }

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
        DispatchQueue.main.async { NSWorkspace.shared.open(url) }
    }

    func store(_ value: String?, for key: ApiKey) {
        let status = Keychain.shared.set(value, for: key.id)
        trouble = status == errSecSuccess ? nil : "The keychain refused the \(key.name) key (\(status))."
        refresh()
    }

    var isBundled: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    func setOpenAtLogin(_ wanted: Bool) {
        guard isBundled else { return trouble = "Open at login works only for the app in /Applications." }
        do {
            if wanted { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            trouble = nil
        } catch {
            trouble = "Could not \(wanted ? "add" : "remove") the login item: \(error.localizedDescription)"
        }
        refresh()
    }
}

