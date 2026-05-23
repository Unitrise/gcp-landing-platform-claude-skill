# GitHub Actions CI/CD

One workflow per client, triggered by changes under `clients/<id>/**` or to any shared package. Uses Workload Identity Federation (no JSON service account keys).

## One-time setup

After `terraform apply` for the shared infrastructure, two values are needed as GitHub Actions secrets at the repository level:

| Secret | Value | Source |
|--------|-------|--------|
| `GCP_PROJECT_ID` | Project ID | From the user |
| `WIF_PROVIDER` | Full WIF provider name | `terraform output wif_provider` |
| `DEPLOY_SA_EMAIL` | Deploy service account email | `terraform output deploy_bot_email` |
| `CLOUDFLARE_API_TOKEN` | Cloudflare token | From Cloudflare dashboard (Zone:DNS:Edit) |

Configure them once at `Settings → Secrets and variables → Actions → New repository secret`.

## Per-client deploy workflow

### `.github/workflows/deploy-acme-corp.yml`

```yaml
name: Deploy acme-corp

on:
  push:
    branches: [main]
    paths:
      - 'clients/acme-corp/**'
      - 'packages/**'                 # Redeploy when shared packages change
      - '.github/workflows/deploy-acme-corp.yml'
  workflow_dispatch:                   # Allow manual runs from the Actions tab

# Cancel in-progress runs for the same client when a new commit lands
concurrency:
  group: deploy-acme-corp
  cancel-in-progress: true

env:
  CLIENT_ID: acme-corp
  GCP_REGION: us-central1

jobs:
  deploy:
    runs-on: ubuntu-latest

    # Required for OIDC token exchange with GCP
    permissions:
      contents: read
      id-token: write

    steps:
      # -----------------------------------------------------------------------
      # Checkout + setup
      # -----------------------------------------------------------------------
      - uses: actions/checkout@v4

      - uses: pnpm/action-setup@v4
        with:
          version: 9

      - uses: actions/setup-node@v4
        with:
          node-version: 22
          cache: 'pnpm'

      - name: Install workspace dependencies
        run: pnpm install --frozen-lockfile

      # -----------------------------------------------------------------------
      # Authenticate to GCP via Workload Identity Federation
      # No JSON keys — GitHub's OIDC token is exchanged for a short-lived
      # GCP access token tied to the deploy-bot service account
      # -----------------------------------------------------------------------
      - id: auth
        uses: google-github-actions/auth@v2
        with:
          workload_identity_provider: ${{ secrets.WIF_PROVIDER }}
          service_account: ${{ secrets.DEPLOY_SA_EMAIL }}

      - uses: google-github-actions/setup-gcloud@v2
        with:
          project_id: ${{ secrets.GCP_PROJECT_ID }}

      # Configure Docker to push to Artifact Registry using the WIF token
      - name: Configure Docker for Artifact Registry
        run: gcloud auth configure-docker ${{ env.GCP_REGION }}-docker.pkg.dev --quiet

      # -----------------------------------------------------------------------
      # Read Terraform outputs we need (API URL, bucket names, DB secret name)
      # These are stable per client so we could also hardcode them; reading
      # from Terraform keeps the workflow generic
      # -----------------------------------------------------------------------
      - name: Read deploy targets
        id: targets
        run: |
          echo "landing_bucket=${{ secrets.GCP_PROJECT_ID }}-${CLIENT_ID}-landing" >> $GITHUB_OUTPUT
          echo "dashboard_bucket=${{ secrets.GCP_PROJECT_ID }}-${CLIENT_ID}-dashboard" >> $GITHUB_OUTPUT
          echo "cloud_run_service=${CLIENT_ID}-api" >> $GITHUB_OUTPUT
          echo "image=${GCP_REGION}-docker.pkg.dev/${{ secrets.GCP_PROJECT_ID }}/apis/${CLIENT_ID}-api:${GITHUB_SHA::7}" >> $GITHUB_OUTPUT

      # -----------------------------------------------------------------------
      # Build & deploy the LANDING PAGE
      # -----------------------------------------------------------------------
      - name: Build landing
        env:
          # Inject the API URL at build time; the bundle calls this URL at runtime
          VITE_API_URL: https://api.acme.com
        run: |
          pnpm --filter @clients/${CLIENT_ID}-landing build

      - name: Sync landing to GCS
        run: |
          gsutil -m rsync -d -r \
            clients/${CLIENT_ID}/landing/dist \
            gs://${{ steps.targets.outputs.landing_bucket }}
          # Set cache headers — long cache for hashed assets, short for index.html
          gsutil -m setmeta -h "Cache-Control:public,max-age=31536000,immutable" \
            "gs://${{ steps.targets.outputs.landing_bucket }}/assets/**"
          gsutil setmeta -h "Cache-Control:public,max-age=300" \
            "gs://${{ steps.targets.outputs.landing_bucket }}/index.html"

      # Purge Cloudflare cache so the new index.html is served immediately
      - name: Purge Cloudflare cache (landing)
        run: |
          curl -sS -X POST \
            -H "Authorization: Bearer ${{ secrets.CLOUDFLARE_API_TOKEN }}" \
            -H "Content-Type: application/json" \
            "https://api.cloudflare.com/client/v4/zones/${{ secrets.CF_ZONE_ACME }}/purge_cache" \
            -d '{"files":["https://acme.com/index.html","https://acme.com/"]}'

      # -----------------------------------------------------------------------
      # Build & push the API Docker image, then deploy to Cloud Run
      # -----------------------------------------------------------------------
      - name: Build & push API image
        uses: docker/build-push-action@v6
        with:
          context: .                                     # Monorepo root — Dockerfile pulls workspace files
          file: clients/${{ env.CLIENT_ID }}/api/Dockerfile
          tags: ${{ steps.targets.outputs.image }}
          push: true
          # Build cache speeds up subsequent runs (saved to Artifact Registry)
          cache-from: type=registry,ref=${{ steps.targets.outputs.image }}-cache
          cache-to: type=registry,ref=${{ steps.targets.outputs.image }}-cache,mode=max

      - name: Apply database migrations
        env:
          # The DB password lives in Secret Manager; pull it with gcloud
          DATABASE_URL: ${{ secrets.ACME_DATABASE_URL }}
        run: |
          pnpm --filter @clients/${CLIENT_ID}-api prisma migrate deploy

      - name: Deploy API to Cloud Run
        uses: google-github-actions/deploy-cloudrun@v2
        with:
          service: ${{ steps.targets.outputs.cloud_run_service }}
          image: ${{ steps.targets.outputs.image }}
          region: ${{ env.GCP_REGION }}
          # Tag this revision with the commit SHA for easy rollback
          tag: r-${{ github.sha }}
          # All other config (env vars, VPC) is on the service already from Terraform

      # -----------------------------------------------------------------------
      # Build & deploy the DASHBOARD
      # -----------------------------------------------------------------------
      - name: Build dashboard
        env:
          VITE_API_URL: https://api.acme.com
        run: |
          pnpm --filter @clients/${CLIENT_ID}-dashboard build

      - name: Sync dashboard to GCS
        run: |
          gsutil -m rsync -d -r \
            clients/${CLIENT_ID}/dashboard/dist \
            gs://${{ steps.targets.outputs.dashboard_bucket }}
          gsutil -m setmeta -h "Cache-Control:public,max-age=31536000,immutable" \
            "gs://${{ steps.targets.outputs.dashboard_bucket }}/assets/**"
          gsutil setmeta -h "Cache-Control:public,max-age=300" \
            "gs://${{ steps.targets.outputs.dashboard_bucket }}/index.html"

      - name: Purge Cloudflare cache (dashboard)
        run: |
          curl -sS -X POST \
            -H "Authorization: Bearer ${{ secrets.CLOUDFLARE_API_TOKEN }}" \
            -H "Content-Type: application/json" \
            "https://api.cloudflare.com/client/v4/zones/${{ secrets.CF_ZONE_ACME }}/purge_cache" \
            -d '{"files":["https://admin.acme.com/index.html","https://admin.acme.com/"]}'

      # -----------------------------------------------------------------------
      # Smoke test: hit the health endpoint and the landing page
      # -----------------------------------------------------------------------
      - name: Smoke test
        run: |
          curl -fsSL https://api.acme.com/health
          curl -fsSL https://acme.com | grep -q "</html>"
```

## Matrix variant for many clients

When client count grows past ~5, replace the per-client workflow files with a matrix workflow that detects which clients changed:

### `.github/workflows/deploy-changed-clients.yml`

```yaml
name: Deploy changed clients

on:
  push:
    branches: [main]

jobs:
  detect-changes:
    runs-on: ubuntu-latest
    outputs:
      clients: ${{ steps.detect.outputs.clients }}
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 2  # So we can diff against the previous commit

      - name: Detect changed client folders
        id: detect
        run: |
          # Find all clients/* folders that changed in this push
          changed=$(git diff --name-only HEAD^ HEAD | \
            grep -oP '^clients/\K[^/]+' | sort -u | jq -R . | jq -sc .)

          # Also redeploy everyone if shared packages changed
          if git diff --name-only HEAD^ HEAD | grep -q '^packages/'; then
            changed=$(ls clients | grep -v '^_' | jq -R . | jq -sc .)
          fi

          echo "clients=${changed}" >> $GITHUB_OUTPUT

  deploy:
    needs: detect-changes
    if: needs.detect-changes.outputs.clients != '[]' && needs.detect-changes.outputs.clients != ''
    runs-on: ubuntu-latest
    strategy:
      fail-fast: false  # One client's failure shouldn't block the others
      matrix:
        client: ${{ fromJson(needs.detect-changes.outputs.clients) }}

    permissions:
      contents: read
      id-token: write

    steps:
      # Same steps as the per-client workflow above, but parameterized by
      # ${{ matrix.client }} instead of a hardcoded env.CLIENT_ID
      - uses: actions/checkout@v4
      # ... etc
```

This single workflow scales to any number of clients without needing one file each.

## Rollback strategy

Cloud Run revisions are immutable — deploying a new image creates a new revision while keeping all previous ones available. To roll back:

```bash
# List revisions
gcloud run revisions list --service=acme-corp-api --region=us-central1

# Route 100% of traffic back to a previous revision
gcloud run services update-traffic acme-corp-api \
  --region=us-central1 \
  --to-revisions=acme-corp-api-00042-abc=100
```

For staged rollouts, deploy with `--tag` and split traffic gradually:

```bash
gcloud run services update-traffic acme-corp-api \
  --region=us-central1 \
  --to-tags=r-newsha=10,r-oldsha=90
```

## Secret management

Database connection strings are kept in Secret Manager, not in workflow files. The Cloud Run service reads them at boot via the `--update-secrets` flag (set initially by Terraform). For migrations during CI, fetch the secret on demand:

```yaml
- name: Get database URL from Secret Manager
  id: db
  run: |
    DB_URL=$(gcloud secrets versions access latest --secret=acme-corp-db-url)
    echo "::add-mask::$DB_URL"
    echo "url=$DB_URL" >> $GITHUB_OUTPUT

- name: Run migrations
  env:
    DATABASE_URL: ${{ steps.db.outputs.url }}
  run: pnpm --filter @clients/acme-corp-api prisma migrate deploy
```

The `::add-mask::` directive prevents the secret from appearing in workflow logs.

## Cost of CI/CD itself

GitHub Actions free tier: 2000 minutes/month on private repos. A typical deploy runs in 3–5 minutes per client, so even 10 clients deploying twice daily fits inside the free tier with margin.

If the project grows beyond that, the cheapest scaling path is GitHub Actions paid minutes ($0.008/min on Linux) rather than migrating to Cloud Build (more expensive for this workload).
