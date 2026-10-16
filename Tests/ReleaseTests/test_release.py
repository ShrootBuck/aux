import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("release", Path(__file__).parents[2] / "scripts/release.py")
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)
SHA = "a" * 40


class ReleaseGuards(unittest.TestCase):
    def test_published_version_cannot_be_replaced(self):
        published = {"tag_name": "v0.1.1", "draft": False, "prerelease": False}
        with patch.object(release, "releases", return_value=[published]), patch.object(release, "run", return_value="") as run, patch.dict(release.os.environ, {"GITHUB_REF": "refs/heads/main"}):
            with self.assertRaisesRegex(SystemExit, "already published"):
                release.publish("0.1.1")
            self.assertFalse(any(call.args[0] == "gh" for call in run.call_args_list))

    def test_draft_for_another_commit_cannot_be_reused(self):
        draft = {"tag_name": "v0.1.1", "draft": True, "target_commitish": "b" * 40}
        with patch.object(release, "releases", return_value=[draft]), patch.object(release, "run", return_value=""), patch.object(release, "revision", return_value=SHA), patch.dict(release.os.environ, {"GITHUB_REF": "refs/heads/main"}):
            with self.assertRaisesRegex(SystemExit, "different commit"):
                release.preflight("0.1.1")

    def test_older_release_cannot_replace_latest(self):
        newer = {"tag_name": "v0.2.0", "draft": False, "prerelease": False}
        with patch.object(release, "releases", return_value=[newer]), patch.object(release, "run", return_value=""), patch.dict(release.os.environ, {"GITHUB_REF": "refs/heads/main"}):
            with self.assertRaisesRegex(SystemExit, "newer"):
                release.preflight("0.1.2")

    def test_incomplete_upload_stays_a_draft(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            dist = root / "dist"
            dist.mkdir()
            (root / "build/release").mkdir(parents=True)
            for name in ("Aux.dmg", "Aux.zip"):
                (dist / name).write_bytes(b"packaged app")
            with patch.object(release, "ROOT", root), patch.object(release, "DIST", dist), patch.object(release, "revision", return_value=SHA):
                release.manifest("0.1.1")
                draft = {"tag_name": "v0.1.1", "draft": True, "assets": []}
                with patch.object(release, "preflight", return_value=draft), patch.object(release, "releases", return_value=[draft]), patch.object(release, "run", return_value="") as run:
                    with self.assertRaisesRegex(SystemExit, "missing or unexpected assets"):
                        release.publish("0.1.1")
                    self.assertFalse(any(call.args[:3] == ("gh", "release", "edit") for call in run.call_args_list))


if __name__ == "__main__":
    unittest.main()
