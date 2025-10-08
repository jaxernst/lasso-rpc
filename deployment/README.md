## Deployment Scripts

This directory contains code-first deployment tooling for Fly.io Machines.

Contents:

- `provision.mjs`: Creates the app, sets secrets, provisions per-region volumes, and launches Machines.
- `roll.mjs`: Blue/green rollout script that updates Machines to a new image with zero downtime.
- `entrypoint.sh` (optional): Seeds `/data/chains.yml` from the image on first boot.

Usage prerequisites:

- Environment variables: `FLY_API_TOKEN`, `FLY_APP_NAME`, `IMAGE_REF`.
- Optional: `REGIONS` (comma-separated), `MACHINE_COUNT`, `VOLUME_SIZE_GB`, `SECRETS_JSON`.
