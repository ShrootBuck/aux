#!/usr/bin/env python3
"""Release metadata and publication. Published versions are never overwritten."""
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parent.parent
DIST = ROOT / "dist"
REPO = os.environ.get("GITHUB_REPOSITORY", "ShrootBuck/aux")
ASSETS = ("Aux.dmg", "Aux.zip", "release.json", "SHA256SUMS.txt")


def run(*args):
    return subprocess.check_output(args, text=True, cwd=ROOT).strip()


def version_tuple(version):
    if not re.fullmatch(r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)", version):
        raise SystemExit("Enter a version like 0.1.1 (no v prefix).")
    return tuple(map(int, version.split(".")))


def revision():
    sha = os.environ.get("GITHUB_SHA") or run("git", "rev-parse", "HEAD")
    if not re.fullmatch(r"[a-f0-9]{40}", sha):
        raise SystemExit("Expected a full source commit SHA.")
    return sha


def releases():
    pages = json.loads(run("gh", "api", "--paginate", "--slurp", f"repos/{REPO}/releases?per_page=100"))
    return [release for page in pages for release in page]


def preflight(version):
    requested = version_tuple(version)
    if os.environ.get("GITHUB_REF", "refs/heads/main") != "refs/heads/main":
        raise SystemExit("Release from main, using the main branch in Run workflow.")
    if run("git", "status", "--porcelain"):
        raise SystemExit("Commit all changes before releasing.")
    tag = f"v{version}"
    draft = None
    for release in releases():
        if release["tag_name"] == tag:
            if not release["draft"]:
                raise SystemExit(f"{tag} is already published. Choose a new version; existing downloads stay immutable.")
            if release["target_commitish"] != revision():
                raise SystemExit("An unfinished draft uses this version for a different commit. Choose a new version.")
            draft = release
        if not release["draft"] and not release["prerelease"] and re.fullmatch(r"v[0-9]+\.[0-9]+\.[0-9]+", release["tag_name"]):
            if requested <= tuple(map(int, release["tag_name"][1:].split("."))):
                raise SystemExit("The version must be newer than every published stable release.")
    tags = run("git", "ls-remote", "--tags", "origin", f"refs/tags/{tag}", f"refs/tags/{tag}^{{}}")
    if tags:
        commit = json.loads(run("gh", "api", f"repos/{REPO}/commits/{tag}"))["sha"]
        if commit != revision():
            raise SystemExit("That tag already points at another commit. Choose a new version.")
    return draft


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def manifest(version):
    version_tuple(version)
    metadata = {
        "version": version, "commit": revision(), "minimum_macos": "14.0",
        "architectures": ["arm64", "x86_64"], "signing": "ad-hoc", "notarized": False,
        "files": {name: {"sha256": digest(DIST / name), "bytes": (DIST / name).stat().st_size} for name in ("Aux.dmg", "Aux.zip")},
    }
    if os.environ.get("GITHUB_RUN_ID"):
        metadata["workflow_url"] = f"https://github.com/{REPO}/actions/runs/{os.environ['GITHUB_RUN_ID']}"
    (DIST / "release.json").write_text(json.dumps(metadata, indent=2) + "\n")
    (DIST / "SHA256SUMS.txt").write_text("".join(f"{digest(DIST / name)}  {name}\n" for name in ASSETS if name != "SHA256SUMS.txt"))


def publish(version):
    draft = preflight(version)
    metadata = json.loads((DIST / "release.json").read_text())
    if metadata["version"] != version or metadata["commit"] != revision():
        raise SystemExit("Artifacts do not belong to the requested version and commit.")
    for name in ("Aux.dmg", "Aux.zip"):
        if digest(DIST / name) != metadata["files"][name]["sha256"]:
            raise SystemExit(f"Artifact checksum changed: {name}")
    notes = ROOT / "build/release/notes.md"
    notes.write_text(f"""## Download Aux {version}

**macOS 14 or later · Apple Silicon and Intel · Apple Music + Discord**

Download **Aux.dmg**, open it, and drag Aux to Applications. Aux.zip contains the same app if you prefer a ZIP download.

### First launch

This free build uses ad-hoc signing and **is not Apple-notarized**. If macOS blocks it and you trust this download, open **System Settings → Privacy & Security → Open Anyway** for Aux after attempting to launch it. [Apple's instructions](https://support.apple.com/102445). Do not disable Gatekeeper.

Open Apple Music and the Discord desktop app. Click Aux's waveform in the menu bar, choose **Connect Music**, and allow access. The Discord application ID is included.

### Updating

Quit Aux, replace the copy in Applications, and reopen it. Settings are preserved. Updates are currently downloaded manually.

Built from `{revision()}`. Both architectures pass the automated checks before publication. Checksums and build metadata are attached. These checks do not exercise live Music/Discord sessions.

""")
    tag = f"v{version}"
    paths = [str(DIST / name) for name in ASSETS]
    if draft:
        run("gh", "release", "upload", tag, *paths, "--clobber", "--repo", REPO)
    else:
        run("gh", "release", "create", tag, *paths, "--draft", "--target", revision(), "--title", f"Aux {version}", "--notes-file", str(notes), "--generate-notes", "--repo", REPO)
    saved = next(item for item in releases() if item["tag_name"] == tag)
    actual = {asset["name"]: asset for asset in saved["assets"]}
    if set(actual) != set(ASSETS):
        raise SystemExit("Draft has missing or unexpected assets; it has not been published.")
    for name in ASSETS:
        asset = actual[name]
        if asset["size"] != (DIST / name).stat().st_size:
            raise SystemExit(f"Upload size mismatch for {name}; draft retained.")
        if asset.get("digest") and asset["digest"] != f"sha256:{digest(DIST / name)}":
            raise SystemExit(f"Upload checksum mismatch for {name}; draft retained.")
    run("gh", "release", "edit", tag, "--draft=false", "--latest", "--repo", REPO)
    print(f"https://github.com/{REPO}/releases/tag/{tag}")


if __name__ == "__main__":
    os.chdir(ROOT)
    if len(sys.argv) != 3 or sys.argv[1] not in ("validate", "preflight", "manifest", "publish"):
        raise SystemExit("Usage: release.py validate|preflight|manifest|publish VERSION")
    command, version = sys.argv[1:]
    version_tuple(version)
    {"validate": version_tuple, "preflight": preflight, "manifest": manifest, "publish": publish}[command](version)
