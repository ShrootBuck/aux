import Foundation
import SwiftUI
import ServiceManagement
import AuxCore

@MainActor
final class SettingsStore: ObservableObject {
    private let defaults: UserDefaults
    var onChange: (() -> Void)?
    static let applicationID = "1560471305843646565"
    @Published var sharingEnabled: Bool { didSet { save("sharingEnabled", sharingEnabled) } }
    @Published var musicAccessRequested: Bool { didSet { save("musicAccessRequested", musicAccessRequested) } }
    @Published var headline: PresenceHeadline { didSet { save("headline", headline.rawValue) } }
    @Published var country: String { didSet { save("country", country) } }
    @Published var shareLocalArtwork: Bool { didSet { save("shareLocalArtwork", shareLocalArtwork) } }
    @Published var launchAtLogin = false
    @Published var loginError: String?

    init(preview: Bool = false) {
        defaults = preview ? UserDefaults(suiteName: "com.zayd.aux.preview")! : .standard
        sharingEnabled = defaults.object(forKey: "sharingEnabled") as? Bool ?? true
        musicAccessRequested = defaults.bool(forKey: "musicAccessRequested")
        headline = PresenceHeadline(rawValue: defaults.string(forKey: "headline") ?? "") ?? .song
        country = defaults.string(forKey: "country") ?? Locale.current.region?.identifier ?? "US"
        shareLocalArtwork = defaults.bool(forKey: "shareLocalArtwork")
        refreshLoginStatus()
    }
    private func save(_ key: String, _ value: Any) { defaults.set(value, forKey: key); onChange?() }
    var options: PresenceOptions { .init(enabled: sharingEnabled, headline: headline) }
    var didLaunchBefore: Bool { defaults.bool(forKey: "didLaunchBefore") }
    func markLaunched() { defaults.set(true, forKey: "didLaunchBefore") }
    func refreshLoginStatus() { launchAtLogin = SMAppService.mainApp.status == .enabled }
    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginError = SMAppService.mainApp.status == .requiresApproval ? "Allow Aux under System Settings → General → Login Items." : nil
        } catch { loginError = error.localizedDescription }
        refreshLoginStatus()
    }
}
