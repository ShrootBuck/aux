import Foundation
import SwiftUI
import ServiceManagement
import AuxCore

enum AppAppearance: String, CaseIterable {
    case system, light, dark
    var label: String { rawValue.capitalized }
    var colorScheme: ColorScheme? { self == .system ? nil : (self == .dark ? .dark : .light) }
}

@MainActor
final class SettingsStore: ObservableObject {
    private let defaults: UserDefaults
    var onChange: (() -> Void)?
    @Published var applicationID: String { didSet { save("applicationID", applicationID) } }
    @Published var sharingEnabled: Bool { didSet { save("sharingEnabled", sharingEnabled) } }
    @Published var musicAccessRequested: Bool { didSet { save("musicAccessRequested", musicAccessRequested) } }
    @Published var pauseBehavior: PauseBehavior { didSet { save("pauseBehavior", pauseBehavior.rawValue) } }
    @Published var headline: PresenceHeadline { didSet { save("headline", headline.rawValue) } }
    @Published var showAlbum: Bool { didSet { save("showAlbum", showAlbum) } }
    @Published var appearance: AppAppearance { didSet { save("appearance", appearance.rawValue) } }
    @Published var country: String { didSet { save("country", country) } }
    @Published var uploadArtwork: Bool { didSet { save("uploadArtwork", uploadArtwork) } }
    @Published var launchAtLogin = false
    @Published var loginError: String?

    init(preview: Bool = false) {
        defaults = preview ? UserDefaults(suiteName: "com.zayd.aux.preview")! : .standard
        applicationID = defaults.string(forKey: "applicationID")
            ?? Bundle.main.object(forInfoDictionaryKey: "AuxDiscordApplicationID") as? String
            ?? ""
        sharingEnabled = defaults.object(forKey: "sharingEnabled") as? Bool ?? true
        musicAccessRequested = defaults.bool(forKey: "musicAccessRequested")
        pauseBehavior = PauseBehavior(rawValue: defaults.string(forKey: "pauseBehavior") ?? "") ?? .hide
        headline = PresenceHeadline(rawValue: defaults.string(forKey: "headline") ?? "") ?? .song
        showAlbum = defaults.object(forKey: "showAlbum") as? Bool ?? true
        appearance = AppAppearance(rawValue: defaults.string(forKey: "appearance") ?? "") ?? .system
        country = defaults.string(forKey: "country") ?? Locale.current.region?.identifier ?? "US"
        uploadArtwork = defaults.bool(forKey: "uploadArtwork")
        refreshLoginStatus()
    }
    private func save(_ key: String, _ value: Any) { defaults.set(value, forKey: key); onChange?() }
    var options: PresenceOptions { .init(enabled: sharingEnabled, pauseBehavior: pauseBehavior, headline: headline, showAlbum: showAlbum) }
    var hasApplicationID: Bool { DiscordPublisher.validApplicationID(applicationID) }
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
