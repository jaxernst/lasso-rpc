# Releasing Lasso RPC

Source releases and container publication are separate steps. A container is built
from an exact published Git commit and promoted only after both native platforms
pass installation checks. A green build alone is not distribution verification.

## Prepare and verify the source release

1. Start from a clean checkout; review the changes since the previous release.
2. Update `mix.exs`, the README version badge, and the changelog/version comparison
   links together. Describe any configuration or storage compatibility changes.
3. Review public setup, API, configuration, deployment, and security guidance.
   Keep private operational material, credentials, `.env` files, local data, and
   generated build artifacts out of the commit.
4. Run `mix format` before committing Elixir changes. Run the repository CI checks
   and any focused regressions needed for the change. Container publication reuses
   successful CI for the exact release commit; it does not repeat the full suite.
5. Merge the release PR and require the merged commit's CI to pass before tagging.
6. Create an annotated version tag and publish the GitHub source release with its
   finalized changelog and compatibility notes. Keep previous tags unchanged.

```sh
git tag -a vX.Y.Z RELEASE_COMMIT -m 'Lasso RPC vX.Y.Z'
git push jaxernst refs/tags/vX.Y.Z
gh release create vX.Y.Z --repo jaxernst/lasso-rpc --verify-tag \
  --title 'Lasso RPC vX.Y.Z' --notes-file release-notes.md
```

A release containing `publish-container.yml` starts container publication when
published. To publish an existing source release, or retry explicitly:

```sh
gh workflow run publish-container.yml --repo jaxernst/lasso-rpc --ref main -f tag=vX.Y.Z
gh run list --repo jaxernst/lasso-rpc --workflow publish-container.yml
```

## Container publication contract

The workflow has five stages:

1. **Resolve source:** require a stable published release, a matching application
   version, and successful main-branch CI at the exact tagged commit.
2. **Build:** native Linux AMD64 and ARM64 runners build the pinned public Git
   source, embedding version/revision labels, BuildKit provenance, and SBOMs.
   Platform images are pushed by digest using the workflow's `GITHUB_TOKEN`.
3. **Assemble:** combine the recorded digests into a candidate multi-platform
   index and sign a GitHub publication attestation for that index. The source
   revision and publication-tooling revision are recorded separately.
4. **Verify:** fresh native runners pull that index without registry credentials,
   verify its signed attestation, and run `scripts/distribution/verify.py` against
   the downloadable Compose recipe. Failures preserve available JSON evidence.
5. **Promote:** create the version tag only after both architectures pass. An
   existing version with a different digest is rejected. `latest` moves only when
   the selected version is GitHub's current latest release. Attach `compose.yml`,
   the release manifest, and verification reports to the source release.

The acceptance suite requires Docker Compose, Python 3, and Node.js 22 or newer
for its built-in WebSocket client. These are verification-tool dependencies;
end users need Docker Compose and the downloaded configuration.

### First publication and package access

GHCR packages initially default to private. After the first candidate is built,
open the repository-linked `lasso-rpc` package settings and make that specific OSS
package public. Do not change visibility of other packages. Then rerun failed
verification jobs. An authenticated push is not evidence that a user can pull.

If package access or runner capacity blocks a stage, retain the run and report the
actual blocker. Do not bypass anonymous verification or publish version tags to
make a failed run appear complete.

### Retries and immutable versions

A failed verification can be rerun against its already assembled digest using
GitHub's **Re-run failed jobs**. Rerunning all jobs rebuilds images and may yield a
different digest. If a version was already promoted, a rebuild with different
contents requires a new source version; never overwrite the existing version.
Use the run's retained platform digests, `container-release.json`, and native
verification reports to distinguish build, access, acceptance, and promotion
failures. Candidate tags are not supported installation references.

## Verify the delivered artifact

Download the source archive and compare its contents to the tag. For the container,
use the immutable reference recorded in `container-release.json`:

```sh
docker pull ghcr.io/jaxernst/lasso-rpc@sha256:DIGEST
gh attestation verify oci://ghcr.io/jaxernst/lasso-rpc@sha256:DIGEST \
  --repo jaxernst/lasso-rpc
```

Follow the public setup instructions from an empty directory, without a checkout
or existing Docker login. Verify health, an upstream-backed request such as
`eth_blockNumber` or `eth_getBalance`, and the browser dashboard. `eth_chainId`
can be answered locally and is not sufficient evidence of upstream connectivity.
The deterministic suite uses a controlled upstream so public-provider outages do
not masquerade as packaging failures; record live-provider checks separately.

Confirm custom profile mounts, environment substitution, reload rejection,
container replacement, history persistence, and rollback instructions against the
actual installed version. Inspect available SBOMs and dependency advisories;
record exclusions and limits rather than claiming zero vulnerabilities.

Link the image reference and attached verification evidence from the release
notes. Maintain an `Unreleased` changelog section for follow-ups. Document only
behavior established by source review or executed checks; keep broad capacity,
continuity, and security claims within their separately measured scope.
