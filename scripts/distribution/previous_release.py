#!/usr/bin/env python3
"""Resolve the preceding stable release's recorded native container image."""
import argparse
import json
import os
from pathlib import Path
import re

from release import checked_digest, command, output


def version(tag):
    if re.fullmatch(r"v[0-9]+\.[0-9]+\.[0-9]+", tag):
        return tuple(map(int, tag[1:].split(".")))
    return None


def resolve(repo, tag, architecture):
    current = version(tag)
    if current is None:
        raise ValueError("Select a stable release tag such as v0.8.2")
    pages = json.loads(command("gh", "api", "--paginate", "--slurp", f"repos/{repo}/releases?per_page=100"))
    candidates = [r for page in pages for r in page
                  if not r["draft"] and not r["prerelease"]
                  and version(r["tag_name"]) is not None
                  and version(r["tag_name"]) < current]
    if not candidates:
        return {"image": "", "version": "", "summary": "Previous-release upgrade check skipped: no older published stable release found."}
    previous = max(candidates, key=lambda r: version(r["tag_name"]))["tag_name"]
    record = json.loads(command("gh", "release", "download", previous, "--repo", repo,
                                "--pattern", "container-release.json", "--output", "-"))
    image = "ghcr.io/" + repo.lower()
    if record["tag"] != previous or record["version"] != previous[1:] or record["image"] != image:
        raise ValueError("Previous release record identity does not match the selected release")
    platforms = [p for p in record["platforms"] if p["architecture"] == architecture]
    if len(platforms) != 1:
        raise ValueError("Previous release record must contain exactly one matching architecture")
    reference = image + "@" + checked_digest(platforms[0]["digest"])
    return {"image": reference, "version": record["version"],
            "summary": f"Previous-release upgrade, policy-off rollback and forward recovery will be checked against {previous} ({architecture}): {reference}"}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", default=os.environ.get("GITHUB_REPOSITORY", "jaxernst/lasso-rpc"))
    parser.add_argument("--tag", required=True)
    parser.add_argument("--architecture", required=True, choices=["amd64", "arm64"])
    args = parser.parse_args()
    result = resolve(args.repo, args.tag, args.architecture)
    print(json.dumps(result, indent=2))
    if os.environ.get("GITHUB_OUTPUT"):
        output({"image": result["image"], "version": result["version"]})
    if os.environ.get("GITHUB_STEP_SUMMARY"):
        with Path(os.environ["GITHUB_STEP_SUMMARY"]).open("a") as stream:
            stream.write(result["summary"] + "\n")


if __name__ == "__main__":
    main()
