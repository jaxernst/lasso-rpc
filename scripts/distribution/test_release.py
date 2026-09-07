"""Publication guards for immutable versions and verified platform identities."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

import release


class PromotionTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.directory = Path(self.temp.name)
        self.digest = "sha256:" + "a" * 64
        self.meta = {"tag": "v0.3.4", "version": "0.3.4", "revision": "b" * 40, "image": "ghcr.io/jaxernst/lasso-rpc", "source": "https://github.com/jaxernst/lasso-rpc"}
        self.saved = dict(self.meta, digest=self.digest, workflow_revision="c" * 40, workflow_run="https://github.com/jaxernst/lasso-rpc/actions/runs/1")
        (self.directory / "container-release.json").write_text(json.dumps(self.saved))
        for arch in ["amd64", "arm64"]:
            result = {"result": "pass", "image": self.meta["image"] + "@" + self.digest, "revision": self.meta["revision"], "architecture": arch}
            (self.directory / f"verification-{arch}.json").write_text(json.dumps(result))
        self.addCleanup(patch.stopall)
        patch.dict(os.environ, {"GITHUB_REPOSITORY": "jaxernst/lasso-rpc"}).start()
        patch("sys.argv", ["release.py", "promote", "--tag", "v0.3.4", "--directory", str(self.directory)]).start()
        patch.object(release, "identity", return_value=self.meta).start()
        patch.object(release, "descriptor", return_value={"digest": self.digest}).start()
        self.commands = patch.object(release, "command", return_value="").start()
        self.api = patch.object(release, "api", return_value={"tag_name": "v0.3.4"}).start()
        self.probe = patch.object(release.subprocess, "run", return_value=subprocess.CompletedProcess([], 1, "", "manifest unknown")).start()

    def test_refuses_replacing_an_existing_version_with_different_content(self):
        self.probe.return_value = subprocess.CompletedProcess([], 0, json.dumps({"digest": "sha256:" + "d" * 64}), "")
        with self.assertRaisesRegex(ValueError, "already exists"):
            release.main()
        self.commands.assert_not_called()

    def test_registry_permission_failure_is_not_treated_as_an_absent_version(self):
        self.probe.return_value = subprocess.CompletedProcess([], 1, "", "403 Forbidden")
        with self.assertRaisesRegex(RuntimeError, "Cannot establish"):
            release.main()
        self.commands.assert_not_called()

    def test_failed_platform_cannot_be_promoted(self):
        file = self.directory / "verification-arm64.json"
        data = json.loads(file.read_text())
        data["result"] = "fail"
        file.write_text(json.dumps(data))
        with self.assertRaisesRegex(ValueError, "Both native"):
            release.main()
        self.commands.assert_not_called()

    def test_verification_of_another_digest_does_not_authorize_publication(self):
        file = self.directory / "verification-amd64.json"
        data = json.loads(file.read_text())
        data["image"] = self.meta["image"] + "@sha256:" + "d" * 64
        file.write_text(json.dumps(data))
        with self.assertRaisesRegex(ValueError, "Both native"):
            release.main()
        self.commands.assert_not_called()

    def test_older_release_rerun_does_not_move_latest_backwards(self):
        self.api.return_value = {"tag_name": "v0.3.5"}
        release.main()
        self.assertFalse(any(self.meta["image"] + ":latest" in call.args for call in self.commands.call_args_list))
        self.assertTrue(any(self.meta["image"] + ":v0.3.4" in call.args for call in self.commands.call_args_list))

    def test_same_digest_retry_preserves_the_version_tag(self):
        self.probe.return_value = subprocess.CompletedProcess([], 0, json.dumps({"digest": self.digest}), "")
        release.main()
        self.assertFalse(any(self.meta["image"] + ":v0.3.4" in call.args for call in self.commands.call_args_list))
        self.assertTrue(any(call.args[:3] == ("gh", "release", "upload") for call in self.commands.call_args_list))


if __name__ == "__main__":
    unittest.main()
