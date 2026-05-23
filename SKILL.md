---
name: gcp-landing-platform
description: Architect and scaffold isolated per-customer landing page + admin dashboard stacks on GCP for under $10/month. Trigger whenever the user mentions a landing page, lead-capture site, marketing page with a contact form, customer-facing static site, admin dashboard for leads, lead management interface, cheap GCP hosting, Cloud Run + Cloud Storage architecture, multi-client website infrastructure, or CI/CD for client-facing sites — even when not explicitly asking for a "landing page architecture." Always uses official CLI scaffolders (nest new, pnpm create vite, prisma init, tailwindcss init, shadcn init) to bootstrap projects rather than hand-writing package.json, tsconfig, or build configs. Each customer gets their own isolated stack (custom design, dedicated NestJS API, dedicated dashboard, own Postgres database) sharing a single always-free e2-micro VM for Postgres. Prefer this skill over generic GCP hosting advice whenever the deliverable involves a marketing/contact page plus any kind of admin view.
---

# GCP Landing Platform

Scaffold and deploy isolated per-customer landing pages backed by a NestJS API and an admin dashboard for lead collection, on Google Cloud Platform, for under $10/month total across several customers.

## When this skill applies

The user is building one or more landing pages that need:

- A custom-designed public marketing/contact page
- A backend that collects leads from a form submission
- A dashboard for an admin (the user or their customer) to view those leads
- Isolation between customers — each customer's design, business logic, and data is separate

This skill applies equally to a single landing page or to a platform that produces many landing pages. The deliverable shape is the same: one isolated stack per customer, with cost pooling via shared infrastructure.

## Core architecture

Every customer gets their own isolated application stack. There is no multi-tenancy at the application layer. The only resource shared across customers is the Postgres host, and even there each customer has their own database with their own role and credentials.

### Per-customer resources

- **Landing page** — Vite + React static build, deployed to a dedicated GCS bucket, served via Cloudflare (free SSL + CDN). Each landing lives in its own folder under `clients/<id>/landing/` with its own design and copy.
- **Backend API** — NestJS in a Docker container, deployed to a dedicated Cloud Run service. Scales to zero. Holds the validation, integrations, and business logic specific to that one customer.
- **Admin dashboard** — Vite + React static build on GCS (gated by Firebase Auth client-side; the API verifies the JWT server-side). Reads leads from the customer's API.
- **Database** — One Postgres database and one role per customer, on the shared Postgres VM. Migrations managed by Prisma per-customer.
- **Custom domain** — Configured through the customer's registrar pointed at Cloudflare nameservers; Terraform manages the DNS records.

### Shared resources (the cost trick)

- **One e2-micro VM** running Postgres in Docker, in an always-free GCP region (`us-central1`, `us-east1`, or `us-west1`). All client databases live on this single instance.
- **One Artifact Registry** for Docker images, namespaced by client.
- **One Secret Manager** holding per-client connection strings, JWT signing keys, and third-party API credentials.
- **One VPC** with private networking so Cloud Run reaches the Postgres VM via Direct VPC Egress (free, GA — no Serverless VPC Connector required).
- **One GitHub Actions setup** with Workload Identity Federation for keyless GCP auth.

### Why this is cheap

- `e2-micro` VM: GCP always-free tier covers one such VM in the listed regions, including 30 GB of standard disk
- Cloud Run: 2M requests, 360k GB-s memory, 180k vCPU-s per month free per region; scales to zero when idle
- GCS: pennies per bucket for static files at landing-page scale
- Direct VPC Egress: free (replaces the ~$8/month Serverless VPC Connector)
- Cloudflare in front of GCS: replaces the ~$18/month Cloud Load Balancer base cost
- **Realistic total: under $5/month infrastructure for 5–10 small customers**, plus domain renewals (which the customer typically pays)

## Workflow when invoked

When the user asks you to design or scaffold this kind of architecture, follow this order. Do not stop to confirm every step — produce the deliverables and let the user redirect if needed.

### 1. Clarify scope briefly

Ask at most one question if it's genuinely ambiguous:

- Is this for the user's own product, or for external customers they're delivering to?
- Starting fresh, or migrating an existing landing page?

If the user has already given you enough context (e.g., they said "for my clients" or "for my SaaS"), skip this entirely and proceed.

### 2. Establish shared infrastructure first

Before the first client stack, provision the shared layer. Read `references/postgres-shared-vm.md` and apply the Terraform in that document to create:

- The VPC and a single private subnet
- The `e2-micro` VM with Postgres in Docker, persistent disk for `/var/lib/postgresql/data`, nightly `pg_dump` cron to a GCS backup bucket
- Artifact Registry for Docker images
- Workload Identity Federation pool and provider for GitHub Actions
- The Secret Manager scaffolding

### 3. Scaffold the monorepo using CLI tools

**Always use official CLI scaffolders rather than hand-writing project files.** Read `references/cli-scaffolding.md` for the exact command sequence. The high-level idea:

- `pnpm init` for the root and each shared package
- `pnpm dlx @nestjs/cli new api` for the NestJS API
- `pnpm create vite@latest landing -- --template react-ts` for the landing page
- `pnpm create vite@latest dashboard -- --template react-ts` for the dashboard
- `pnpm dlx tailwindcss init -p` to set up Tailwind in landing and dashboard
- `pnpm dlx prisma init` to set up Prisma in the API
- `pnpm dlx shadcn@latest init` to set up the component library in the dashboard

Run these commands directly in the user's terminal — do not paste hand-written equivalents of what these scaffolders would produce. The other reference files contain *customizations* to apply on top of the scaffolded output, not full project replacements.

### 4. Build the shared packages

After `pnpm init` for each shared package (see `cli-scaffolding.md` step 2), populate them with their first useful exports:

- `packages/api-core/` — NestJS modules every client API will extend: auth guard (verifies Firebase JWT), leads module base, validation pipes wired to Zod, structured logger
- `packages/ui-kit/` — reusable React components used by both landing pages and dashboards (Section, Button, Form, Input, Card, IconButton)
- `packages/dashboard-core/` — auth-aware dashboard shell, leads table, CSV export, filter hooks
- `packages/shared-types/` — Zod schemas for `Lead`, `Submission`, the API request/response contracts; consumed by both client and server

Each package gets its own README per the user's documentation preference.

### 5. Scaffold the first client

Run `scripts/new-client.sh <id>` (template in `scripts/new-client.sh`) to copy the per-client template into `clients/<id>/`. Then customize:

- Branding (colors, fonts, logo) in `clients/<id>/client.config.ts`
- Landing page section composition (which `ui-kit` components, in what order)
- Custom API endpoints if the customer needs more than the default `POST /leads`
- Add a `module "<id>"` block in `infra/terraform/clients.tf`

Run `terraform apply` to provision the per-client GCP resources (bucket, Cloud Run service, Postgres database + role, secrets, DNS records).

### 6. Wire CI/CD

Drop in the workflow from `references/github-actions-workflow.md`, parameterized with the client's ID. The first time a workflow runs, the user needs to set up Workload Identity Federation provider trust in the GitHub repo's secrets (one-time setup per repo).

### 7. Verify end-to-end

Submit a fake lead from the landing page, confirm it lands in the customer's Postgres database, and verify it appears in the dashboard. Run through this checklist before declaring the client live.

## Defaults and conventions

These are the assumptions baked into the architecture. Do not deviate unless the user explicitly overrides.

- **Region**: `us-central1`. The always-free `e2-micro` is available there. If the user needs EU data residency, use `europe-west1` and warn them that the VM falls out of the free tier; recommend a Cloud SQL `db-f1-micro` at ~$8/month as the cheapest alternative.
- **Database**: Postgres 16 in Docker on the shared VM. Prisma for migrations and TypeScript types. One database per client, one role per client, SSL required on connections.
- **API framework**: NestJS in TypeScript. `class-validator` plus Zod for input validation.
- **Frontend**: Vite + React + TypeScript + Tailwind. Static builds output to GCS buckets.
- **Auth on the dashboard**: Firebase Auth (free), Google sign-in by default. The NestJS API verifies the Firebase JWT in a guard.
- **DNS / SSL**: Cloudflare. User points their registrar at Cloudflare nameservers; Terraform manages the DNS records.
- **CI/CD**: GitHub Actions with Workload Identity Federation. Never use static service account JSON keys.
- **IaC**: Terraform. State in a GCS bucket with versioning and object locking enabled.
- **Package manager**: pnpm with workspaces.
- **Documentation**: Each package and each client folder has a `README.md` explaining its purpose and structure (per the user's documentation preference).
- **Code style**: Comments next to non-obvious functions and constants explaining intent (per the user's preference). Prefer extending existing components in `packages/ui-kit` over creating new ones.

## What NOT to do

These are tempting shortcuts the architecture has explicitly decided against. Do not regress to them.

- **Don't hand-write project files when a CLI scaffolder exists.** Use `nest new`, `pnpm create vite`, `pnpm dlx prisma init`, `pnpm dlx tailwindcss init`, `pnpm dlx shadcn@latest init` to bootstrap projects. Writing `package.json`, `tsconfig.json`, or `vite.config.ts` from scratch is brittle and gets out of date — the scaffolder output is the canonical starting point. See `references/cli-scaffolding.md`.
- **Don't use Cloud SQL** unless the user explicitly opts in. The ~$8/month minimum stacks per client and defeats the point. The shared `e2-micro` VM is the whole cost story.
- **Don't use the Serverless VPC Connector**. Direct VPC Egress is GA and free.
- **Don't put a Cloud Load Balancer in front of GCS buckets**. Cloudflare is free and equivalent at this scale.
- **Don't multi-tenant the API**. Each customer gets their own Cloud Run service. Cloud Run's pricing model makes the cost effectively the same as a shared service, but isolation prevents one customer's deploy breaking another.
- **Don't expose Postgres on a public IP**. Private VPC only; Cloud Run reaches it via Direct VPC Egress.
- **Don't use static service account JSON keys for GitHub Actions**. Workload Identity Federation is the only acceptable auth method.
- **Don't put landing-page logic inside the dashboard or vice versa**. They are separate deployables with separate concerns.
- **Don't skip the shared packages**. The whole structure depends on `api-core`, `ui-kit`, `dashboard-core`, and `shared-types` existing before clients are scaffolded.

## Reference files

Read the relevant file before producing code or configuration in that area:

- `references/cli-scaffolding.md` — **Read this first.** Canonical CLI commands to scaffold every project (NestJS, Vite, Tailwind, Prisma, shadcn) before writing any custom code
- `references/repo-structure.md` — Full monorepo layout with explanations of every directory and package
- `references/postgres-shared-vm.md` — Provisioning the `e2-micro` VM, Postgres in Docker, backups, private networking
- `references/terraform-client-module.md` — The per-client Terraform module and how to add new clients
- `references/nestjs-api-template.md` — NestJS API *customizations* applied after `nest new`: Dockerfile, modules, Prisma wiring, Firebase Auth guard
- `references/dashboard-and-landing.md` — Landing page and dashboard *customizations* applied after `pnpm create vite`: config-driven design, contact form, dashboard shell
- `references/github-actions-workflow.md` — Full CI/CD pipeline with Workload Identity Federation

## Scripts

- `scripts/new-client.sh` — Scaffolds a new client folder from the per-client template, given a client ID
