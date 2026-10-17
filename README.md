# Aux

A native macOS menu bar app for Apple Music and Discord Rich Presence. SwiftUI and AppKit, with no web view, JavaScript runtime, or third-party packages.

## Download

**[Download Aux for macOS](https://github.com/ShrootBuck/aux/releases/latest/download/Aux.dmg)** · [All releases](https://github.com/ShrootBuck/aux/releases)

One download supports Apple Silicon and Intel Macs running macOS 14 or later. Open the disk image and drag Aux into Applications. A ZIP download is also available on the release page.

These free builds are not Apple-notarized. If macOS blocks Aux and you trust the download, use **System Settings → Privacy & Security → Open Anyway** after attempting to launch it. [Apple's instructions](https://support.apple.com/102445).

## Build from source

Requires macOS 14 or later and a Swift 6 toolchain (Xcode or Command Line Tools).

```sh
git clone https://github.com/ShrootBuck/aux.git
cd aux
./scripts/build.sh
```

The release bundle is written to `build/Aux.app`. The build script compiles the app, generates its icon, and signs it locally. It does not launch Aux. Use `./scripts/build.sh debug` for a debug build.

The default signature is ad hoc. To sign with your own installed identity, set `AUX_SIGN_IDENTITY` when building. The default build targets your Mac; `./scripts/build.sh release universal` builds for both Apple Silicon and Intel. Public releases are built and packaged by [GitHub Actions](docs/RELEASING.md).

## Use

1. Install Aux from the downloaded disk image (or move a source-built `build/Aux.app` to Applications), then open it. Aux lives in the menu bar; all of its UI stays in the menu bar popover. Quit an older running copy before opening a newly built version.
2. Open Apple Music and the Discord desktop app on the same Mac.
3. Click Aux's waveform in the menu bar and choose **Connect Music**. Allow Aux to control Music when macOS asks. If access was denied, enable Music for Aux in System Settings → Privacy & Security → Automation.
4. Play a song in Apple Music and leave **Share on Discord** enabled in Aux. Discord's activity privacy settings must also allow your activity to be displayed.
5. This build includes Aux's public Discord Application ID. No ID entry is needed. Aux does not require a bot token, client secret, or Discord password.

Aux is registered in the [Discord Developer Portal](https://discord.com/developers/applications/1560471305843646565/information) with public application ID `1560471305843646565`. The shared ID is hardcoded in `Sources/Aux/SettingsStore.swift`.

The panel shows album artwork, track information, elapsed time, and a sharing switch. Aux only reads Music; it has no playback controls. Right-click the menu bar icon for sharing, settings, and quit. Settings open inside the same popover, including opt-in launch at login. Appearance always follows macOS.

## Presence and artwork

- The status headline can show the song, artist, or Apple Music. The status contains only the artist; the album remains on the artwork.
- Pausing silently disconnects from Discord without sending a clear-activity command. Aux stays disconnected while paused and reconnects when playback resumes. Discord controls when the old card disappears; there is no promised 10-second expiry.
- Disabling sharing clears the activity. Sleep, quitting, track changes, seeks, and Discord restarts have explicit lifecycle handling.
- Song links require a matching title, artist, album, and available duration. Cover artwork can fall back to an exact artist-and-album match from either song or album search results when Apple omits the recording or its title or duration differs from your library.
- Public Apple artwork and listening links can be included in the Discord activity. A failed artwork lookup does not block song text.
- Enable **Settings → Artwork → Share local artwork** to prefer the actual cover in your Music library, including custom covers and imported tracks. Aux sends a small JPEG to its own artwork service at `artwork.zaydkrunz.com`. Apple's catalog remains a fallback and supplies listening links. This remains opt-in for new installations.
- When Music's playing-track object has no artwork, Aux checks matching library entries from the same album. Album artist must match when available; otherwise the track artist must match. Aux checks that playback has not changed before using the recovered cover.
- Library artwork publishes as soon as hosting finishes; catalog lookup does not delay it. Aux verifies the image through Discord's media proxy after the activity is accepted. Failed checks report the HTTP/network error and retry after 10, 30, 90, then 300 seconds, without re-uploading the cover. Checks run in the background so pause and track changes remain responsive.
- The server decodes and re-encodes each JPEG to strip metadata, limits dimensions to 700 pixels and size to 250 KB, and serves immutable `/covers/<sha256>.jpg` URLs derived from the stored bytes. Identical covers share one file. A persistent local cache reuses uploaded covers across tracks and app restarts.
- Each installation automatically receives a revocable upload credential, saved with owner-only permissions under `~/Library/Application Support/Aux/`. No shared upload secret is bundled with the app. Server-side limits apply per installation, client address, and globally; a storage cap protects the shared server. Registration is anonymous and rate-limited, not proof of a person's identity.
- Cover URLs are public to anyone who has them. Turning sharing off stops uploads and removes the hosted cover from the activity; previously uploaded files remain hosted. Aux sends no song title, artist, album name, or original filename to the artwork server. Cloudflare and the server receive the connection's IP address; the service stores salted address hashes for rate limiting. Request logs contain method, path, and status, not credentials or bodies.
- The service runs on the existing Coolify server and Cloudflare Tunnel, with covers and SQLite state on a persistent volume. Cloudflare can cache image responses; the origin owns the files. No R2 or Catbox dependency remains. Deployment and recovery details are in [the artwork service runbook](server/artwork/README.md).

Preferences use macOS UserDefaults. Catalog matches, hosted artwork URLs, and the installation credential are stored under `~/Library/Application Support/Aux/`. There is no Aux account or listening-history database. Apple catalog requests disclose queried song metadata to Apple; Discord receives the activity while sharing is enabled.

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

`--preview` displays fictional sample content in the menu bar popover without polling Music or publishing to Discord. Use `open build/Aux.app --args --show` to launch the live development build with its popover open. All launches use the menu bar only.

Automated checks cover core logic, both Mac architectures, and the packaged downloads. They do not validate live Music/Discord sessions. Generated app bundles are attached to releases and excluded from the source repository.

## Maintainers

Publish a version from **Actions → Release → Run workflow**. Enter a new version and GitHub builds and publishes the downloads. See [the release guide](docs/RELEASING.md) for the full process and permanent website download links.
