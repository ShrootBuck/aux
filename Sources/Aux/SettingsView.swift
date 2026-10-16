import SwiftUI
import AppKit
import AuxCore

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var settings: SettingsStore
    @ViewState private var section = "Connection"
    @ViewState private var applicationID = ""
    @ViewState private var copied = false
    @Environment(\.colorScheme) private var scheme

    init(model: AppModel) { self.model = model; settings = model.settings }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 13) {
                AuxMark().frame(width: 38, height: 44)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Aux").font(.system(size: 25, weight: .bold, design: .rounded)).tracking(-0.6)
                    Text("Settings").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer()
                Text("0.1.0").font(.system(size: 11, design: .monospaced)).foregroundStyle(.tertiary)
            }.padding(.bottom, 23)
            Picker("Section", selection: $section) {
                ForEach(["Connection", "Presence", "General"], id: \.self) { Text($0).tag($0) }
            }.pickerStyle(.segmented).labelsHidden().padding(.bottom, 23)

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    switch section {
                    case "Connection": connection
                    case "Presence": presence
                    default: general
                    }
                }.padding(.bottom, 4)
            }.scrollIndicators(.hidden)
            Spacer(minLength: 12)
            HStack(spacing: 6) {
                Circle().fill(model.statusColor).frame(width: 5, height: 5)
                Text(model.statusTitle).font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Button(copied ? "Copied" : "Copy diagnostics") {
                    let text = "Aux 0.1.0\nmacOS \(ProcessInfo.processInfo.operatingSystemVersionString)\nMusic: \(model.snapshot.state.rawValue)\nMusic access: \(model.permissionDenied ? "denied" : (settings.musicAccessRequested ? "requested" : "not requested"))\nDiscord: \(model.publication.connection.rawValue)\nSharing enabled: \(settings.sharingEnabled)\nAccepted activity: \(model.publication.accepted != nil)\nArtwork: \(model.artworkStatus)\nError: \(model.musicError ?? model.publication.message ?? "none")"
                    NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
                    copied = true
                }.buttonStyle(.plain).font(.system(size: 10)).foregroundStyle(.secondary)
            }.padding(.top, 13).overlay(alignment: .top) { Divider() }
        }
        .padding(27).frame(width: 540, height: 585)
        .background(Color(nsColor: .windowBackgroundColor))
        .tint(model.accent)
        .preferredColorScheme(settings.appearance.colorScheme)
        .onAppear { applicationID = settings.applicationID; settings.refreshLoginStatus() }
    }

    private var connection: some View {
        Group {
            sectionCard("Apple Music", symbol: "music.note") {
                HStack {
                    Text(!settings.musicAccessRequested ? "Playback access" : (model.permissionDenied ? "Access denied" : (model.musicError == nil ? "Access requested" : "Needs attention")))
                        .font(.system(size: 12))
                    Spacer()
                    Button(model.permissionDenied ? "Open Settings" : "Connect") {
                        if model.permissionDenied { model.openAutomationSettings() } else { model.connectMusic(); model.openMusic() }
                    }.controlSize(.small).disabled(model.isPreview)
                }
                Text("Aux reads the current track and sends playback commands to Music.")
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            sectionCard("Discord", symbol: "antenna.radiowaves.left.and.right") {
                Text("Application ID").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    TextField("17–20 digit application ID", text: $applicationID)
                        .textFieldStyle(.roundedBorder).font(.system(size: 12, design: .monospaced))
                        .onSubmit(saveID)
                        .accessibilityLabel("Discord application ID")
                    Button("Save", action: saveID).buttonStyle(.borderedProminent).controlSize(.small)
                        .disabled(!idIsValid || applicationID.trimmingCharacters(in: .whitespacesAndNewlines) == settings.applicationID || model.isPreview)
                }
                if !idIsValid {
                    Text("Use the numeric application ID from the General Information page.").font(.system(size: 10)).foregroundStyle(.orange)
                }
                HStack {
                    Link("Create an application ↗", destination: URL(string: "https://discord.com/developers/applications")!)
                        .font(.system(size: 11, weight: .medium))
                    Spacer()
                    if settings.hasApplicationID { Button("Reconnect") { model.retryDiscord() }.controlSize(.small) }
                }
                Text("Create an app named Aux, then paste its Application ID here. Discord must be running on this Mac with activity sharing enabled.")
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
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
                Picker("When paused", selection: $settings.pauseBehavior) { ForEach(PauseBehavior.allCases, id: \.self) { Text($0.label).tag($0) } }
                Toggle("Include album name", isOn: $settings.showAlbum)
            }
            sectionCard("Artwork", symbol: "square.stack") {
                HStack {
                    Text("Apple storefront")
                    Spacer()
                    Picker("Apple storefront", selection: $settings.country) {
                        ForEach(storefronts, id: \.code) { Text($0.name).tag($0.code) }
                    }.labelsHidden().frame(width: 165)
                }
                Divider()
                Toggle("Upload unmatched local covers", isOn: $settings.uploadArtwork)
                Text("Sends cover images to Catbox for 1 hour when Apple has no matching artwork, so Discord can display them. Off by default.")
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if !model.artworkStatus.isEmpty { Text(model.artworkStatus).font(.system(size: 10)).foregroundStyle(.tertiary) }
            }
        }.font(.system(size: 12)).toggleStyle(.switch).controlSize(.small).disabled(model.isPreview)
    }
    private var general: some View {
        Group {
            sectionCard("Appearance", symbol: "circle.lefthalf.filled") {
                Picker("Theme", selection: $settings.appearance) { ForEach(AppAppearance.allCases, id: \.self) { Text($0.label).tag($0) } }
                    .pickerStyle(.segmented).labelsHidden()
            }
            sectionCard("Startup", symbol: "power") {
                Toggle("Launch Aux at login", isOn: Binding(get: { settings.launchAtLogin }, set: { settings.setLaunchAtLogin($0) }))
                    .toggleStyle(.switch).controlSize(.small).disabled(model.isPreview)
                if let error = settings.loginError { Text(error).font(.system(size: 11)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
            }
            sectionCard("About Aux", symbol: "info.circle") {
                Text("Apple Music → Discord").font(.system(size: 13, weight: .medium))
                Text("Made for macOS. Your settings and artwork cache stay on this Mac. Catalog lookups go to Apple; playback status goes to Discord when sharing is enabled.")
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var idIsValid: Bool {
        let value = applicationID.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty || DiscordPublisher.validApplicationID(value)
    }
    private func saveID() {
        guard idIsValid, !model.isPreview else { return }
        applicationID = applicationID.trimmingCharacters(in: .whitespacesAndNewlines)
        settings.applicationID = applicationID
        model.retryDiscord()
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
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .background(.primary.opacity(scheme == .dark ? 0.04 : 0.025), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.primary.opacity(0.06), lineWidth: 0.5))
    }
}
