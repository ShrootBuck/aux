import SwiftUI
import AppKit
import AuxCore

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var settings: SettingsStore
    @ViewState private var copied = false
    @Environment(\.colorScheme) private var scheme
    private var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev" }

    init(model: AppModel) { self.model = model; settings = model.settings }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Button { model.showingSettings = false } label: {
                    Image(systemName: "chevron.left").font(.system(size: 14, weight: .semibold))
                }
                .buttonStyle(QuietButtonStyle()).help("Back").accessibilityLabel("Back to player")
                Text("Settings").font(.system(size: 18, weight: .semibold))
                Spacer()
                Text(version).font(.system(size: 11, design: .monospaced)).foregroundStyle(.tertiary)
            }.padding(.bottom, 16)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    connection
                    presence
                    sectionCard("Startup", symbol: "power") {
                        Toggle("Launch Aux at login", isOn: Binding(get: { settings.launchAtLogin }, set: { settings.setLaunchAtLogin($0) }))
                            .toggleStyle(.switch).controlSize(.small).disabled(model.isPreview)
                        if let error = settings.loginError {
                            Text(error).font(.system(size: 11)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }.padding(.bottom, 4)
            }.scrollIndicators(.hidden)
            Spacer(minLength: 12)
            HStack(spacing: 6) {
                Circle().fill(model.statusColor).frame(width: 5, height: 5)
                Text(model.statusTitle).font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Button(copied ? "Copied" : "Copy diagnostics") {
                    let text = "Aux \(version)\nmacOS \(ProcessInfo.processInfo.operatingSystemVersionString)\nMusic: \(model.snapshot.state.rawValue)\nMusic access: \(model.musicAccessTitle)\nDiscord: \(model.publication.connection.rawValue)\nSharing enabled: \(settings.sharingEnabled)\nAccepted activity: \(model.publication.accepted != nil)\nArtwork: \(model.artworkStatus)\nError: \(model.musicError ?? model.publication.message ?? "none")"
                    NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
                    copied = true
                }.buttonStyle(.plain).font(.system(size: 10)).foregroundStyle(.secondary)
            }.padding(.top, 13).overlay(alignment: .top) { Divider() }
        }
        .padding(18).frame(width: 368, height: min(640, max(360, (NSScreen.main?.visibleFrame.height ?? 900) - 80)))
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { settings.refreshLoginStatus() }
    }

    private var connection: some View {
        Group {
            sectionCard("Apple Music", symbol: "music.note") {
                HStack {
                    Text(model.musicAccessTitle).font(.system(size: 12))
                    Spacer()
                    if !model.musicConnected {
                        Button(model.permissionDenied ? "Open Settings" : "Connect") {
                            if model.permissionDenied { model.openAutomationSettings() } else { model.connectMusic(); model.openMusic() }
                        }.controlSize(.small).disabled(model.isPreview)
                    } else {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    }
                }
                Text("Aux reads the current track and artwork from Music.")
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            sectionCard("Discord", symbol: "antenna.radiowaves.left.and.right") {
                HStack {
                    Text(model.publication.connection == .paused ? "Disconnected while paused" : (model.publication.connection == .connected ? "Connected" : "Waiting for Discord"))
                        .font(.system(size: 12))
                    Spacer()
                    Button("Reconnect") { model.retryDiscord() }.controlSize(.small)
                        .disabled(model.isPreview || model.publication.connection == .paused)
                }
                if let user = model.publication.userName { Label("Connected as \(user)", systemImage: "checkmark.circle.fill").font(.system(size: 11)).foregroundStyle(.green) }
                if let message = model.publication.message { Text(message).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            }
        }
    }
    private var presence: some View {
        Group {
            sectionCard("Activity", symbol: "waveform") {
                Toggle("Share on Discord", isOn: $settings.sharingEnabled)
                Divider()
                Picker("Listening to", selection: $settings.headline) { ForEach(PresenceHeadline.allCases, id: \.self) { Text($0.label).tag($0) } }
            }
            sectionCard("Artwork", symbol: "square.stack") {
                HStack {
                    Text("Apple storefront")
                    Spacer()
                    Picker("Apple storefront", selection: $settings.country) {
                        ForEach(storefronts, id: \.code) { Text($0.name).tag($0.code) }
                    }.labelsHidden().frame(width: 165)
                }
                Toggle("Share local artwork", isOn: $settings.shareLocalArtwork)
                Text("Prefer your Music library's cover on Discord by uploading a small copy to Catbox. Fall back to Apple's catalog if unavailable. Anyone with its link can view it. Turning this off stops uploads; existing copies remain on Catbox.")
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if !model.artworkStatus.isEmpty { Text(model.artworkStatus).font(.system(size: 10)).foregroundStyle(.tertiary) }
            }
        }.font(.system(size: 12)).toggleStyle(.switch).controlSize(.small).disabled(model.isPreview)
    }
    private var storefronts: [(code: String, name: String)] {
        let common = [("US", "United States"), ("GB", "United Kingdom"), ("CA", "Canada"), ("AU", "Australia"), ("TR", "Türkiye"), ("JP", "Japan"), ("DE", "Germany"), ("FR", "France")]
        return common.contains(where: { $0.0 == settings.country }) ? common : [(settings.country, settings.country)] + common
    }
    private func sectionCard<Content: View>(_ title: String, symbol: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: symbol).font(.system(size: 12, weight: .semibold))
            VStack(alignment: .leading, spacing: 12, content: content)
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .background(.primary.opacity(scheme == .dark ? 0.04 : 0.025), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.primary.opacity(0.06), lineWidth: 0.5))
    }
}
