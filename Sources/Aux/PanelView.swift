import SwiftUI
import AuxCore

struct AuxMark: View {
    var color: Color = .accentColor
    var body: some View {
        HStack(spacing: 3) {
            ForEach(Array([11.0, 22, 30, 17].enumerated()), id: \.offset) { _, height in
                Capsule().fill(color).frame(width: 4, height: height)
            }
        }
        .accessibilityHidden(true)
    }
}

struct QuietButtonStyle: ButtonStyle {
    @Environment(\.colorScheme) private var scheme
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.primary.opacity(configuration.isPressed ? 0.5 : 0.8))
            .padding(7)
            .background(.primary.opacity(configuration.isPressed ? 0.08 : 0), in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
    }
}

struct PanelView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var settings: SettingsStore
    var openSettings: () -> Void = {}
    @Environment(\.colorScheme) private var scheme

    init(model: AppModel, openSettings: @escaping () -> Void = {}) {
        self.model = model; settings = model.settings; self.openSettings = openSettings
    }

    var body: some View {
        VStack(spacing: 0) {
            header.padding(.horizontal, 22).padding(.top, 17).padding(.bottom, 14)
            ScrollView {
                VStack(spacing: 0) {
                    cover.padding(.top, 2).padding(.bottom, 18)
                    if let track = model.snapshot.track {
                        trackInfo(track)
                        progress(track).padding(.top, 12).padding(.bottom, 22)
                    } else {
                        emptyState.padding(.bottom, 20)
                    }
                    sharing
                    if let error = model.musicError, !model.permissionDenied {
                        Text(error).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).padding(.top, 10)
                    }
                }
                .padding(.horizontal, 22)
                .padding(.bottom, 10)
            }
            .scrollIndicators(.hidden)
            .frame(height: panelBodyHeight)
        }
        .frame(width: 368)
        .background {
            ZStack(alignment: .top) {
                Color(nsColor: .windowBackgroundColor)
                Color.accentColor.opacity(0.035)
                    .mask(LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom))
                Ellipse().fill(Color.accentColor.opacity(scheme == .dark ? 0.08 : 0.07)).frame(width: 290, height: 250).blur(radius: 65).offset(y: 50)
            }
        }
    }
    private var panelBodyHeight: CGFloat {
        let preferred: CGFloat = model.snapshot.track == nil ? 420 : 485
        return min(preferred, max(260, (NSScreen.main?.visibleFrame.height ?? 900) - 140))
    }

    private var header: some View {
        HStack(spacing: 7) {
            AuxMark().scaleEffect(0.6).frame(width: 19, height: 20)
            Text("aux").font(.system(size: 24, weight: .bold, design: .rounded)).tracking(-1.1)
            Spacer()
            Button(action: openSettings) { Image(systemName: "gearshape").font(.system(size: 15)) }
                .buttonStyle(QuietButtonStyle()).help("Settings · ⌘,").accessibilityLabel("Settings")
        }
    }

    private var cover: some View {
        Group {
            if let artwork = model.artwork {
                Image(nsImage: artwork).resizable().aspectRatio(contentMode: .fit)
            } else if model.isPreview, model.snapshot.track != nil {
                PreviewCover()
            } else {
                ZStack {
                    LinearGradient(colors: [Color(white: scheme == .dark ? 0.20 : 0.91), Color(white: scheme == .dark ? 0.11 : 0.80)], startPoint: .topLeading, endPoint: .bottomTrailing)
                    ForEach(0..<5) { i in Circle().stroke(.primary.opacity(0.035), lineWidth: 1).frame(width: CGFloat(90 + i * 36)) }
                    Circle().fill(.primary.opacity(0.06)).frame(width: 84, height: 84)
                    Image(systemName: "music.note").font(.system(size: 35, weight: .light)).foregroundStyle(.secondary.opacity(0.7))
                }
            }
        }
        .frame(width: model.snapshot.track == nil ? 218 : 278, height: model.snapshot.track == nil ? 218 : 278)
        .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(.white.opacity(scheme == .dark ? 0.10 : 0.35), lineWidth: 0.5))
        .shadow(color: .black.opacity(scheme == .dark ? 0.34 : 0.18), radius: 17, x: 0, y: 10)
        .frame(maxWidth: .infinity)
        .accessibilityLabel(model.snapshot.track.map { "Artwork for \($0.album)" } ?? "No artwork")
    }

    private func trackInfo(_ track: Track) -> some View {
        VStack(spacing: 5) {
            Text(track.title).font(.system(size: 21, weight: .semibold)).tracking(-0.5)
                .lineLimit(2).multilineTextAlignment(.center).help(track.title)
            Text(track.artist.isEmpty ? "Unknown artist" : track.artist).font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
                .lineLimit(1).help(track.artist)
            if !track.album.isEmpty { Text(track.album).font(.system(size: 11)).foregroundStyle(.tertiary).lineLimit(1).help(track.album) }
        }
        .frame(maxWidth: .infinity).frame(minHeight: 67)
        .accessibilityElement(children: .combine)
    }

    private func progress(_ track: Track) -> some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            HStack(spacing: 7) {
                if model.snapshot.state == .paused { Text("Paused"); Text("·") }
                Text(formatTime(model.snapshot.position(at: context.date)))
                if track.duration > 0 { Text("/"); Text(formatTime(track.duration)) }
            }
            .font(.system(size: 11, weight: .medium, design: .monospaced))
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity)
            .accessibilityElement(children: .combine)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Text(!settings.musicAccessRequested || model.permissionDenied ? "Connect Apple Music" : "Nothing playing")
                .font(.system(size: 20, weight: .semibold)).tracking(-0.4)
            if !settings.musicAccessRequested || model.permissionDenied {
                Text(model.permissionDenied ? "Allow Music access in Automation settings." : "Allow Aux to read your current track.")
                    .font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            Button {
                if model.permissionDenied { model.openAutomationSettings() }
                else if !settings.musicAccessRequested { model.connectMusic() }
                else { model.openMusic() }
            } label: {
                Label(model.permissionDenied ? "Open System Settings" : (!settings.musicAccessRequested ? "Connect Music" : "Open Music"), systemImage: model.permissionDenied ? "lock.open" : "music.note")
                    .font(.system(size: 12, weight: .medium)).padding(.horizontal, 10).padding(.vertical, 5)
            }
            .buttonStyle(.borderedProminent).padding(.top, 5)
        }
        .frame(maxWidth: .infinity)
    }

    private var sharing: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 10) {
                Image(systemName: "antenna.radiowaves.left.and.right").font(.system(size: 18, weight: .medium))
                    .foregroundStyle(settings.sharingEnabled ? Color.accentColor : .secondary)
                    .frame(width: 30)
                VStack(alignment: .leading, spacing: 5) {
                    Text("Share on Discord").font(.system(size: 12, weight: .semibold))
                    if !model.isSharing && settings.sharingEnabled {
                        Text(model.statusTitle).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 3)
                Toggle("Share on Discord", isOn: $settings.sharingEnabled).labelsHidden().toggleStyle(.switch).controlSize(.small)
                    .disabled(model.isPreview)
            }

        }
        .padding(14)
        .background(.primary.opacity(scheme == .dark ? 0.045 : 0.035), in: RoundedRectangle(cornerRadius: 13))
        .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(.primary.opacity(0.045), lineWidth: 0.5))
    }


}

func formatTime(_ seconds: TimeInterval) -> String {
    let value = max(0, Int(seconds.isFinite ? seconds : 0))
    return "\(value / 60):\(String(format: "%02d", value % 60))"
}

/// Original procedural artwork for development previews; never sent to Discord.
struct PreviewCover: View {
    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Color(red: 0.94, green: 0.88, blue: 0.72)
                Circle().fill(LinearGradient(colors: [Color(red: 0.99, green: 0.61, blue: 0.25), Color(red: 0.85, green: 0.23, blue: 0.20)], startPoint: .top, endPoint: .bottom))
                    .frame(width: proxy.size.width * 0.72).offset(y: -12)
                ForEach(0..<22) { i in
                    Rectangle().fill(Color(red: 0.30, green: 0.36, blue: 0.30).opacity(0.08 + Double(i) * 0.014))
                        .frame(height: CGFloat(i) * 0.30 + 1).offset(y: CGFloat(i) * 6 + 2)
                }
                VStack(alignment: .leading) {
                    Text("ASTER").font(.system(size: proxy.size.width * 0.065, weight: .bold, design: .monospaced)).tracking(6)
                    Spacer()
                    Text("SOFT FOCUS").font(.system(size: proxy.size.width * 0.035, weight: .medium, design: .monospaced)).tracking(3)
                }
                .foregroundStyle(Color(red: 0.16, green: 0.20, blue: 0.17)).padding(proxy.size.width * 0.085).frame(maxWidth: .infinity, alignment: .leading)
            }.clipped()
        }
    }
}
