# gcp-landing-platform — Claude Code skill

A Claude Code skill that captures the architecture, defaults, and templates for building **isolated per-customer landing page + admin dashboard stacks on Google Cloud Platform**, optimized for near-zero hosting cost.

When triggered, this skill guides Claude Code to:

1. **Use official CLI scaffolders** (`nest new`, `pnpm create vite`, `prisma init`, `tailwindcss init`, `shadcn init`) to bootstrap every project — never hand-writing package.json, tsconfig, or build configs
2. Produce a pnpm monorepo with shared packages (`api-core`, `ui-kit`, `dashboard-core`, `shared-types`) and per-client folders
3. Provision GCP infrastructure with Terraform — per-client module plus shared `e2-micro` VM running Postgres in Docker
4. Apply customizations (NestJS modules, Vite config tweaks, contact form, dashboard shell) on top of the scaffolded baseline
5. Wire CI/CD via GitHub Actions with Workload Identity Federation
6. Provide a `new-client.sh` script that copies the customized `_template/` for each new customer

## Installing into Claude Code

There are three ways to install this skill, in order of convenience.

### Option 1: One-liner from GitHub (recommended, after first-time setup)

Once you've pushed this skill to your own GitHub repo (see *First-time GitHub setup* below), install it from any project with a single command:

```bash
# User-wide install (available in every project)
curl -fsSL https://raw.githubusercontent.com/<YOU>/<REPO>/main/gcp-landing-platform/install.sh | bash

# Project-only install (current directory)
curl -fsSL https://raw.githubusercontent.com/<YOU>/<REPO>/main/gcp-landing-platform/install.sh | bash -s -- --project
```

To make this even easier, add a shell alias to your `~/.zshrc` or `~/.bashrc`:

```bash
alias install-landing-skill='curl -fsSL https://raw.githubusercontent.com/<YOU>/<REPO>/main/gcp-landing-platform/install.sh | bash'
```

Then from any project: `install-landing-skill` or `install-landing-skill --project`.

### Option 2: From an unzipped copy

If you've downloaded the `.zip` package:

```bash
unzip gcp-landing-platform.zip
bash gcp-landing-platform/install.sh              # user-wide
bash gcp-landing-platform/install.sh --project    # project-only
```

The script handles both scopes and won't double-install — re-running updates the skill in place.

### Option 3: Manual copy

If you prefer to skip the installer:

```bash
# User-wide
cp -r gcp-landing-platform ~/.claude/skills/

# Project-only
mkdir -p .claude/skills && cp -r gcp-landing-platform .claude/skills/
```

Either way, restart Claude Code (or open a fresh session) so the skill is picked up.

## First-time GitHub setup (for the one-liner)

The one-liner needs the skill hosted somewhere Claude Code can `curl` from. The simplest path: a public GitHub repo.

1. **Create a repo on GitHub** — e.g. `<your-username>/claude-skills`. It can be public, or private if you're comfortable using GitHub PATs.

2. **Push the skill folder:**

   ```bash
   git clone https://github.com/<you>/claude-skills.git
   cd claude-skills
   cp -r /path/to/gcp-landing-platform .
   git add gcp-landing-platform
   git commit -m "Add gcp-landing-platform skill"
   git push
   ```

3. **Edit `install.sh`** so the one-liner can find the repo. Open `gcp-landing-platform/install.sh` and set:

   ```bash
   REPO_OWNER="${SKILL_REPO_OWNER:-<your-username>}"
   REPO_NAME="${SKILL_REPO_NAME:-claude-skills}"
   ```

   Or skip editing and pass them as env vars on the curl invocation:

   ```bash
   SKILL_REPO_OWNER=<you> SKILL_REPO_NAME=claude-skills \
     curl -fsSL https://raw.githubusercontent.com/<you>/claude-skills/main/gcp-landing-platform/install.sh | bash
   ```

4. Commit and push the edit. The one-liner now works from any machine.

## Scope: user-wide vs project

- **User-wide** (`~/.claude/skills/`) — Claude Code loads the skill in every project on your machine. Best for skills you always want available.
- **Project-only** (`.claude/skills/` in the project root) — only loaded when Claude Code runs in this project. Useful when a skill is repo-specific or when you want different versions per project.

The installer defaults to user-wide; pass `--project` for project-only.

## What triggers the skill

The skill triggers whenever you ask Claude Code about:

- Building a landing page with a contact form and dashboard
- Cheap GCP hosting for client websites
- Per-customer marketing sites with lead collection
- Cloud Run + GCS + Postgres architectures
- CI/CD for client-facing sites
- "How would I set up [some kind of landing-page-plus-dashboard thing] on GCP"

It triggers even if you don't explicitly say "use the gcp-landing-platform skill."

## Architectural decisions baked in

These are the choices the skill embodies. They've been made deliberately and the skill will guide Claude Code toward them:

| Decision | Why |
|----------|-----|
| Per-client isolation (no multi-tenancy in the API) | Each customer has different design + business logic. Cloud Run cost scales the same either way. |
| Shared `e2-micro` Postgres VM | Always-free tier; one database per client gives full isolation without per-client database server cost. |
| Direct VPC Egress for Cloud Run → Postgres | Free, GA. Replaces the ~$8/month Serverless VPC Connector. |
| Cloudflare in front of GCS buckets | Free SSL + CDN on custom domains. Replaces the ~$18/month Cloud Load Balancer base cost. |
| Firebase Auth on the dashboard | Free, easy Google sign-in. NestJS API verifies the JWT server-side. |
| GitHub Actions + Workload Identity Federation | Free for typical scale, no static service account keys. |
| Terraform with GCS backend | Reproducible, declarative, free state storage. |
| pnpm workspaces | Best UX for monorepos with shared packages. |

## Files in this skill

- `SKILL.md` — Main skill entry point; metadata, when-to-use, workflow
- `references/cli-scaffolding.md` — **Read first.** Canonical CLI commands for bootstrapping every project
- `references/repo-structure.md` — Full monorepo layout (the end-state of following cli-scaffolding.md)
- `references/postgres-shared-vm.md` — Shared VM Terraform + bootstrap script + backups
- `references/terraform-client-module.md` — Per-client Terraform module
- `references/nestjs-api-template.md` — NestJS customizations applied after `nest new`
- `references/dashboard-and-landing.md` — Vite/React customizations applied after `pnpm create vite`
- `references/github-actions-workflow.md` — CI/CD with WIF
- `scripts/new-client.sh` — Scaffolding script for new clients

## Cost reality check

For 5–10 small customers (a few hundred leads/month each) in `us-central1`:

- Cloud Run: $0 (free tier covers it)
- GCS landing + dashboard buckets: ~$0.50/month total
- Shared `e2-micro` VM: $0 (always-free)
- Direct VPC Egress, Secret Manager, Artifact Registry: pennies
- **Total: under $5/month infrastructure**, plus customer domain renewals

When a customer grows past "low traffic" or needs HA, migrate just that one to a dedicated Cloud SQL instance (~$8/month). Everyone else stays on the shared VM.

## Adapting the skill

The skill encodes opinions; if you want to change them, edit `SKILL.md` and the relevant reference files. Specifically:

- Want a different region? Edit the `Region` line in `SKILL.md`'s defaults and the Terraform region variables.
- Want Cloud SQL instead of the shared VM? Replace `postgres-shared-vm.md` with a Cloud SQL setup; the per-client module's `postgres_host` input still works.
- Want a different frontend framework (Next.js, SolidStart)? Edit `dashboard-and-landing.md` — the rest of the architecture is framework-independent.
