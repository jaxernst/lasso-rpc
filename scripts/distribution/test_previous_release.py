"""Guard release ordering and fail-closed evidence lookup without network access."""
import json
import subprocess
import unittest
from unittest.mock import patch

import previous_release


class PreviousReleaseTest(unittest.TestCase):
    def resolve(self, tags, record=None, tag="v0.10.0"):
        pages = [[dict(tag_name=t, draft=d, prerelease=p) for t, d, p in tags]]
        responses = [json.dumps(pages)]
        if isinstance(record, Exception):
            responses.append(record)
        elif record is not None:
            responses.append(json.dumps(record))
        with patch.object(previous_release, "command", side_effect=responses) as command:
            result = previous_release.resolve("jaxernst/lasso-rpc", tag, "amd64")
        return result, command

    def record(self):
        return dict(tag="v0.9.0", version="0.9.0", image="ghcr.io/jaxernst/lasso-rpc",
                    digest="sha256:" + "b" * 64,
                    platforms=[dict(architecture="amd64", digest="sha256:" + "a" * 64)])

    def test_numeric_order_excludes_current_newer_drafts_and_prereleases(self):
        tags = [(t, False, False) for t in ["v0.8.9", "v0.10.0", "v0.11.0", "v0.9.0", "v0.10.0-rc.1"]]
        tags += [("v0.9.9", True, False), ("v0.9.8", False, True)]
        result, command = self.resolve(tags, self.record())
        self.assertEqual(result["version"], "0.9.0")
        self.assertEqual(result["image"], "ghcr.io/jaxernst/lasso-rpc@sha256:" + "a" * 64)
        self.assertIn("--paginate", command.call_args_list[0].args)
        self.assertIn("v0.9.0", command.call_args_list[1].args)

    def test_first_release_skips_without_reading_an_asset(self):
        result, command = self.resolve([("v0.10.0", False, False)])
        self.assertEqual(result["image"], "")
        self.assertIn("skipped", result["summary"])
        self.assertEqual(command.call_count, 1)

    def test_unreadable_previous_record_fails(self):
        with self.assertRaises(subprocess.CalledProcessError):
            self.resolve([("v0.9.0", False, False)], subprocess.CalledProcessError(1, "gh"))

    def test_invalid_identity_architecture_or_digest_fails(self):
        for field, value in [("tag", "v0.8.0"), ("version", "0.8.0"),
                             ("image", "other"), ("platforms", []),
                             ("platforms", [dict(architecture="amd64", digest="mutable")])]:
            with self.subTest(field=field, value=value), self.assertRaises(ValueError):
                record = self.record()
                record[field] = value
                self.resolve([("v0.9.0", False, False)], record)


if __name__ == "__main__":
    unittest.main()
