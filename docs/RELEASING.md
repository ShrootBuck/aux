# Releasing Aux

## Publish a version

1. Commit and push the intended changes to `main`.
2. Open [Actions → Release](https://github.com/ShrootBuck/aux/actions/workflows/release.yml).
3. Click **Run workflow**, leave the branch on **main**, and enter a new version such as `0.1.2`.
4. Click **Run workflow**. GitHub handles the rest.

The equivalent command is:

```sh
gh workflow run release.yml --repo ShrootBuck/aux --ref main -f version=0.1.2
```

Use the next patch number for fixes (`0.1.1` → `0.1.2`), the next minor number for features (`0.1.2` → `0.2.0`), and `1.0.0` when you decide the app is ready for that milestone. Do not reuse a published version. You do not edit the app's version by hand; the workflow stamps the chosen version into the downloadable bundle and Settings reads it from there.

## What happens automatically

- Validates the version, branch, existing tags, and any previous release.
- Runs the core tests and compiles the app on both Apple Silicon and Intel runners.
- Builds both architectures and combines them into one universal app for macOS 14+.
- Adds the icon, version, build number, source commit, and Apple Events entitlement, then applies an ad-hoc signature.
- Creates a disk image with Aux, an Applications shortcut, and first-launch instructions. Also creates a ZIP of the same app.
- Extracts the ZIP and mounts the disk image read-only to check both bundles' signatures, architectures, and versions. It never launches Music, Discord, or the app.
- Creates SHA-256 checksums and a `release.json` file with source and build metadata.
- Uploads everything to a draft, verifies all assets arrived, then publishes the release and makes it Latest. GitHub generates the changelog links.

The source commit is fixed when you start the workflow. Later commits to `main` do not silently enter an in-progress release. A failed build cannot publish a release. If uploading fails, rerun that same workflow run; it can resume a draft for the same commit. A published release is never overwritten by these scripts. To fix a published version, ship a newer version.

`Checks` also runs on pushes to `main` and pull requests. The macOS runner and Xcode version are explicit, and third-party actions and packaging dependencies are pinned. No Apple credentials or paid services are configured.

## Download links

- Release page: <https://github.com/ShrootBuck/aux/releases/latest>
- Website download button: <https://github.com/ShrootBuck/aux/releases/latest/download/Aux.dmg>
- ZIP alternative: <https://github.com/ShrootBuck/aux/releases/latest/download/Aux.zip>

These links resolve to the newest published release. They start working after the first successful publication. GitHub Release downloads are public; users do not need to build the app or sign in. The separate Actions artifact is a temporary backup for maintainers, not the user download link.

## Free distribution and macOS approval

The app is **ad-hoc signed, not Developer ID signed or Apple-notarized**. That keeps this process free, but it does not establish an Apple-verified developer identity. On first launch, macOS may block it. A user who trusts the download can approve Aux under **System Settings → Privacy & Security → Open Anyway** after attempting to open it. [Apple's instructions](https://support.apple.com/102445) cover this process. Do not tell users to disable Gatekeeper or strip quarantine attributes.

Normal updates mean quitting Aux, downloading the new release, and replacing the app in Applications. Preferences remain in macOS UserDefaults. This release pipeline does not implement automatic in-app updates; that would be a separate feature.

If you later join the [Apple Developer Program](https://developer.apple.com/programs/), replace the ad-hoc signing step with Developer ID signing and add notarization and stapling before packaging. Store the signing key and notarization credentials in GitHub's encrypted secrets, never in source. The public download links and release flow can stay the same.

## Local packaging

On a Mac with a Swift 6 toolchain and Python 3.10+:

```sh
./scripts/package.sh 0.1.2
```

Outputs are `dist/Aux.dmg`, `dist/Aux.zip`, `dist/SHA256SUMS.txt`, and `dist/release.json`. This does not upload anything. Packaging installs its small pinned Python tools into `.venv-release/`; none are shipped inside Aux. Use GitHub Actions for public releases so the recorded checks and source revision travel with the release.
