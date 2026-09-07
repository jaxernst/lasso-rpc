#!/usr/bin/env python3
"""Resolve released source and promote verified container digests without replacing versions."""
import argparse
import base64
import json
import os
from pathlib import Path
import re
import subprocess


def command(*args):
    return subprocess.check_output(args, text=True).strip()


def api(path):
    return json.loads(command("gh", "api", path))


def identity(tag):
    if not re.fullmatch(r"v[0-9]+\.[0-9]+\.[0-9]+", tag):
        raise ValueError("Select a stable release tag such as v0.3.4")
    repo = os.environ["GITHUB_REPOSITORY"]
    release = api(f"repos/{repo}/releases/tags/{tag}")
    if release["draft"] or release["prerelease"]:
        raise ValueError("Container publication requires a published stable source release")
    sha = api(f"repos/{repo}/commits/{tag}")["sha"]
    source = api(f"repos/{repo}/contents/mix.exs?ref={sha}")
    version = re.search(r'version:\s*"([^"]+)"', base64.b64decode(source["content"]).decode()).group(1)
    if tag != "v" + version:
        raise ValueError("Tag and application version disagree")
    runs = api(f"repos/{repo}/actions/workflows/ci.yml/runs?head_sha={sha}&status=success&per_page=100")["workflow_runs"]
    if not any(r["head_sha"] == sha and r["event"] == "push" and r["head_branch"] == "main" and r["conclusion"] == "success" for r in runs):
        raise ValueError("The exact released commit needs a successful main-branch CI run")
    return {"tag": tag, "version": version, "revision": sha, "image": "ghcr.io/" + repo.lower(), "source": "https://github.com/" + repo}


def output(values):
    with open(os.environ["GITHUB_OUTPUT"], "a") as stream:
        for key, value in values.items():
            stream.write(f"{key}={value}\n")


def descriptor(reference):
    return json.loads(command("docker", "buildx", "imagetools", "inspect", reference, "--format", "{{json .Manifest}}"))


def checked_digest(value):
    if not re.fullmatch(r"sha256:[a-f0-9]{64}", value):
        raise ValueError("Invalid image digest")
    return value


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=["prepare", "assemble", "promote"])
    parser.add_argument("--tag", required=True)
    parser.add_argument("--directory", default=".")
    args = parser.parse_args()
    meta = identity(args.tag)
    directory = Path(args.directory)
    if args.action == "prepare":
        output(meta)
        return
    if args.action == "assemble":
        platforms = [json.loads((directory / f"image-{arch}.json").read_text()) for arch in ["amd64", "arm64"]]
        for arch, image in zip(["amd64", "arm64"], platforms):
            if image["architecture"] != arch or image["revision"] != meta["revision"]:
                raise ValueError("Platform builds must use the same released source")
            checked_digest(image["digest"])
        candidate = meta["image"] + ":candidate-" + os.environ["GITHUB_RUN_ID"] + "-" + os.environ["GITHUB_RUN_ATTEMPT"]
        command("docker", "buildx", "imagetools", "create", "--tag", candidate, *[meta["image"] + "@" + p["digest"] for p in platforms])
        meta.update(digest=checked_digest(descriptor(candidate)["digest"]), platforms=platforms)
        meta["workflow_revision"] = os.environ["GITHUB_SHA"]
        meta["workflow_run"] = meta["source"] + "/actions/runs/" + os.environ["GITHUB_RUN_ID"]
        (directory / "container-release.json").write_text(json.dumps(meta, indent=2) + "\n")
        output({"image": meta["image"], "digest": meta["digest"]})
        return
    saved = json.loads((directory / "container-release.json").read_text())
    if any(saved[key] != meta[key] for key in ["tag", "version", "revision", "image"]):
        raise ValueError("Released source identity changed during publication")
    digest = checked_digest(saved["digest"])
    for arch in ["amd64", "arm64"]:
        result = json.loads((directory / f"verification-{arch}.json").read_text())
        if result["result"] != "pass" or result["image"] != meta["image"] + "@" + digest or result["revision"] != meta["revision"] or result["architecture"] != arch:
            raise ValueError("Both native architectures must pass anonymous distribution verification")
    version_ref = meta["image"] + ":" + meta["tag"]
    # Only a confirmed absent manifest allows creating a version tag.
    probe = subprocess.run(["docker", "buildx", "imagetools", "inspect", version_ref, "--format", "{{json .Manifest}}"], text=True, capture_output=True)
    if probe.returncode == 0:
        if json.loads(probe.stdout)["digest"] != digest:
            raise ValueError("Version tag already exists with a different digest; publish a new version")
    elif "not found" in probe.stderr.lower() or "manifest unknown" in probe.stderr.lower():
        command("docker", "buildx", "imagetools", "create", "--tag", version_ref, meta["image"] + "@" + digest)
    else:
        raise RuntimeError("Cannot establish whether the version exists: " + probe.stderr)
    if descriptor(version_ref)["digest"] != digest:
        raise ValueError("Published version digest differs from verified image")
    latest = api(f"repos/{os.environ['GITHUB_REPOSITORY']}/releases/latest")["tag_name"]
    if latest == meta["tag"]:
        command("docker", "buildx", "imagetools", "create", "--tag", meta["image"] + ":latest", meta["image"] + "@" + digest)
    recipe = Path("deployment/compose.release.yml").read_text()
    recipe = re.sub(r"ghcr.io/jaxernst/lasso-rpc:v[0-9]+\.[0-9]+\.[0-9]+", meta["image"] + ":" + meta["tag"], recipe)
    (directory / "compose.yml").write_text(recipe)
    report = f'''# Container distribution verification: {meta['tag']}

- Image: `{version_ref}`
- Immutable reference: `{meta['image']}@{digest}`
- Application source: `{meta['revision']}`
- Publication tooling: `{saved['workflow_revision']}`
- Native platforms: Linux AMD64 and ARM64
- [Publication and verification run]({saved['workflow_run']})

Both native runners pulled the multi-platform image without registry credentials and passed the downloadable Compose installation checks. The attached JSON reports list the checks and exact image identity. These cover controlled upstream requests, HTTP failover, WebSocket RPC and newHeads delivery, configuration reload rejection, saved history across container replacement, and read-only profile mounts. This is finite release verification, not a security certification or capacity guarantee.

The signed attestation identifies the publication workflow. Each platform's BuildKit provenance records the pinned public Git source used for its build; SBOMs are included in the OCI index. Verify the attestation with:

```sh
gh attestation verify oci://{meta['image']}@{digest} --repo {os.environ['GITHUB_REPOSITORY']}
```

The Compose attachment defaults to the version tag. For digest-pinned deployment, set `LASSO_IMAGE={meta['image']}@{digest}` in `.env`.
'''
    (directory / "container-verification.md").write_text(report)
    assets = [directory / name for name in ["compose.yml", "container-release.json", "container-verification.md", "verification-amd64.json", "verification-arm64.json"]]
    # Version identity was checked above; a retry may replace identical release evidence.
    command("gh", "release", "upload", meta["tag"], "--repo", os.environ["GITHUB_REPOSITORY"], "--clobber", *map(str, assets))
    print(meta["image"] + "@" + digest)


if __name__ == "__main__":
    main()
