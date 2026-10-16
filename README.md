# Aux

A native macOS menu bar app for Apple Music and Discord Rich Presence. SwiftUI and AppKit, with no web view, JavaScript runtime, or third-party packages.

## Build

Requires macOS 14 or later and a Swift 6 toolchain (Xcode or Command Line Tools).

```sh
git clone https://github.com/ShrootBuck/aux.git
cd aux
./scripts/build.sh
```

The release bundle is written to `build/Aux.app`. The build script compiles the app, generates its icon, and signs it locally. It does not launch Aux. Use `./scripts/build.sh debug` for a debug build.

The default signature is ad hoc for local use. To sign with your own installed identity, set `AUX_SIGN_IDENTITY` when building. Notarization and distribution packaging are not configured. The bundle targets the architecture of the machine building it.

## Use

1. Move `build/Aux.app` to Applications, then open it. Aux lives in the menu bar; it does not normally open a Dock window. Quit an older running copy before opening a newly built version.
2. Open Apple Music and the Discord desktop app on the same Mac.
3. Click Aux's waveform in the menu bar and choose **Connect Music**. Allow Aux to control Music when macOS asks. If access was denied, enable Music for Aux in System Settings → Privacy & Security → Automation.
4. Play a song in Apple Music and leave **Share on Discord** enabled in Aux. Discord's activity privacy settings must also allow your activity to be displayed.
5. This build includes Aux's public Discord Application ID. No ID entry is needed. You can override it in Settings → Connection if you want to use another application. Aux does not require a bot token, client secret, or Discord password.

Aux is registered in the [Discord Developer Portal](https://discord.com/developers/applications/1560471305843646565/information) with public application ID `1560471305843646565`. The default is stored in `Resources/Info.plist`; a saved application ID takes precedence.

The panel includes album artwork, playback controls, seeking, a sharing switch, connection status, and a preview of the last activity Discord acknowledged. Right-click the menu bar icon for sharing, settings, and quit. Settings also include light/dark/system appearance and opt-in launch at login.

## Presence and artwork

- The status headline can show the song, artist, or application. Album details are optional.
- Pausing hides the activity by default. Alternatively, retain the paused track for up to five minutes without an advancing timer.
- Disabling sharing clears the activity. Sleep, quitting, track changes, seeks, and Discord restarts have explicit lifecycle handling.
- Local artwork stays on your Mac. Aux queries Apple's catalog using track metadata and only uses results matching the title, artist, album, and available duration.
- Public Apple artwork and listening links can be included in the Discord activity. A failed artwork lookup does not block song text.
- Uploading local covers is off by default. If enabled in Settings, unmatched covers are uploaded to Catbox Litterbox as public images with a one-hour expiry.

Preferences use macOS UserDefaults. Catalog matches are cached under `~/Library/Application Support/Aux/`. There is no analytics, Aux account, backend, or listening-history database. Apple catalog requests disclose the queried song metadata to Apple; Discord receives the activity while sharing is enabled.

## Source

- `Sources/Aux/`: menu bar app, player panel, settings, and lifecycle coordination.
- `Sources/AuxCore/`: direct Apple Events, playback timeline, catalog matching, artwork, and Discord's local Unix socket protocol.
- `Tests/AuxCoreTests/`: timeline, payload, matching, rate-budget, and socket framing tests.
- `Resources/`: app metadata and Apple Events entitlement.
- `scripts/`: build wrapper and original vector icon generator.

Music observation and local Discord socket operations run outside the main actor. Enrichment runs independently with cancellation and stale-result guards. IPC includes bounded reads and writes, reconnect backoff, acknowledgement tracking, and a publication budget.

The sibling Deno project informed the small Apple Music → Discord pipeline. The Qt project's public documentation informed pause, artwork, connection, and privacy behavior. Aux's implementation is native Swift; no Qt application code is incorporated.

## Development

```sh
./scripts/swift.sh build
./scripts/swift.sh test
open build/Aux.app --args --preview
```

`--preview` displays fictional sample content without polling Music or publishing to Discord. `--window` shows the live panel as a standalone development window. Normal launches use the menu bar only.

Status: local development build. Live Music/Discord integration and final UI behavior have not been validated. A successful build is not evidence of end-to-end behavior. Generated app bundles are excluded from the source repository.
