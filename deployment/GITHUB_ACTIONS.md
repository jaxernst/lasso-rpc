## GitHub Actions: CI/CD for Fly.io Machines

This doc describes a simple pipeline for staging and production using the scripts in `/deployment`.

### Secrets to add in GitHub repo settings → Secrets and variables → Actions

- `FLY_API_TOKEN` – from `fly auth token`
- `FLY_STAGING_APP` – e.g., `lasso-staging`
- `FLY_PROD_APP` – e.g., `lasso-prod`
- `SECRET_KEY_BASE_STAGING` – from `mix phx.gen.secret`
- `SECRET_KEY_BASE_PROD`
- Provider keys (if needed): `INFURA_API_KEY`, `ALCHEMY_API_KEY`

### Workflow: .github/workflows/deploy-staging.yml

```yaml
name: Deploy Staging
on:
  push:
    branches: [main]

jobs:
  build-and-deploy:
    runs-on: ubuntu-latest
    permissions:
      contents: read
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with:
          node-version: 20
      - name: Set up Fly CLI
        run: |
          curl -L https://fly.io/install.sh | sh
          echo "${HOME}/.fly/bin" >> $GITHUB_PATH
      - name: Docker login to Fly
        env:
          FLY_API_TOKEN: ${{ secrets.FLY_API_TOKEN }}
        run: |
          flyctl auth token | docker login registry.fly.io -u x -p $(cat -)
      - name: Build and push image
        env:
          FLY_APP_NAME: ${{ secrets.FLY_STAGING_APP }}
        run: |
          TAG=stg-${GITHUB_SHA::7}
          docker build -t registry.fly.io/$FLY_APP_NAME:$TAG .
          docker push registry.fly.io/$FLY_APP_NAME:$TAG
          echo "IMAGE_REF=registry.fly.io/$FLY_APP_NAME:$TAG" >> $GITHUB_ENV
      - name: Provision/Update Machines
        env:
          FLY_API_TOKEN: ${{ secrets.FLY_API_TOKEN }}
          FLY_APP_NAME: ${{ secrets.FLY_STAGING_APP }}
          IMAGE_REF: ${{ env.IMAGE_REF }}
          REGIONS: iad
          MACHINE_COUNT: 2
          VOLUME_SIZE_GB: 3
          SECRET_KEY_BASE: ${{ secrets.SECRET_KEY_BASE_STAGING }}
          INFURA_API_KEY: ${{ secrets.INFURA_API_KEY }}
          ALCHEMY_API_KEY: ${{ secrets.ALCHEMY_API_KEY }}
        run: |
          node deployment/provision.mjs
      - name: Blue/Green Rollout
        env:
          FLY_API_TOKEN: ${{ secrets.FLY_API_TOKEN }}
          FLY_APP_NAME: ${{ secrets.FLY_STAGING_APP }}
          IMAGE_REF: ${{ env.IMAGE_REF }}
        run: |
          node deployment/roll.mjs
```

### Workflow: .github/workflows/deploy-prod.yml (manual promotion)

```yaml
name: Deploy Production
on:
  workflow_dispatch:
    inputs:
      image_ref:
        description: Image ref to deploy (from staging)
        required: true

jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with:
          node-version: 20
      - name: Blue/Green Rollout to Prod
        env:
          FLY_API_TOKEN: ${{ secrets.FLY_API_TOKEN }}
          FLY_APP_NAME: ${{ secrets.FLY_PROD_APP }}
          IMAGE_REF: ${{ github.event.inputs.image_ref }}
        run: |
          node deployment/roll.mjs
```

### Notes

- Staging workflow also runs provisioning so it’s idempotent for first-time setup.
- For multiple staging regions, set `REGIONS=iad,sea`.
- If you want separate provision step only on first run, guard with `if: always()` and a label or use a separate workflow.
- Production is manual to keep a safe gate; you pass the exact `IMAGE_REF` tested in staging.

### First-time local deployment gotchas

- Ensure `FLY_API_TOKEN` is exported locally and that you ran `flyctl auth docker`.
- Build times on Apple Silicon vs amd64: Fly registry builds architecture-agnostic images; if you need amd64, build with `--platform linux/amd64`.
- If you don’t switch to `/deployment/entrypoint.sh` in Dockerfile, you must copy `config/chains.yml` to `/data/chains.yml` once per region.
- Verify health (`/api/health`) and at least one HTTP and WS call before blue/green.
