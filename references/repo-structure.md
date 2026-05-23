# Repo structure

> **This is the end-state layout**, produced by following `references/cli-scaffolding.md`. Don't create these files by hand — use `pnpm init`, `pnpm dlx @nestjs/cli new`, `pnpm create vite`, etc. to generate them. This document describes the final shape and explains the purpose of each piece so Claude Code knows where things belong after scaffolding.

The repository is a pnpm monorepo. Two top-level concepts:

- `packages/` — shared, reusable code consumed by every client
- `clients/` — one folder per customer; fully isolated application code

Plus `infra/` for Terraform and `scripts/` for tooling.

## Full tree

```
landing-platform/
├── package.json                          # Workspace root; defines pnpm scripts
├── pnpm-workspace.yaml                   # Declares packages/* and clients/*/* as workspaces
├── tsconfig.base.json                    # Shared TypeScript config extended by every package
├── .eslintrc.cjs                         # Shared ESLint config
├── .prettierrc                           # Shared Prettier config
├── .gitignore
├── README.md                             # Top-level explanation of the platform
│
├── packages/                             # Shared, reusable building blocks
│   ├── api-core/                         # NestJS base modules every client API extends
│   │   ├── src/
│   │   │   ├── auth/                     # Firebase JWT guard, current-user decorator
│   │   │   ├── leads/                    # Base leads module (controller + service + repo interface)
│   │   │   ├── validation/               # Zod pipe, exception filters
│   │   │   ├── logging/                  # Structured logger setup (pino)
│   │   │   └── index.ts                  # Public exports
│   │   ├── package.json
│   │   ├── tsconfig.json
│   │   └── README.md
│   │
│   ├── ui-kit/                           # Reusable React components
│   │   ├── src/
│   │   │   ├── components/               # Button, Input, Card, Section, Form, IconButton
│   │   │   ├── hooks/                    # useForm, useDebouncedValue, useMediaQuery
│   │   │   ├── tokens/                   # Design tokens (spacing, typography scales)
│   │   │   └── index.ts
│   │   ├── package.json
│   │   ├── tsconfig.json
│   │   └── README.md
│   │
│   ├── dashboard-core/                   # Auth-aware dashboard shell + leads UI
│   │   ├── src/
│   │   │   ├── auth/                     # Firebase Auth provider, login screen, sign-out
│   │   │   ├── shell/                    # Sidebar, header, layout wrapper
│   │   │   ├── leads/                    # LeadsTable, LeadDetail, CSV export
│   │   │   ├── hooks/                    # useLeads, useAuthedFetch, useFilter
│   │   │   └── index.ts
│   │   ├── package.json
│   │   ├── tsconfig.json
│   │   └── README.md
│   │
│   └── shared-types/                     # Zod schemas + TS types shared client/server
│       ├── src/
│       │   ├── lead.schema.ts            # Lead, LeadInput, LeadStatus
│       │   ├── api.schema.ts             # API request/response envelopes
│       │   └── index.ts
│       ├── package.json
│       ├── tsconfig.json
│       └── README.md
│
├── clients/                              # One folder per customer — fully isolated
│   ├── _template/                        # Source-of-truth template; copied by new-client.sh
│   │   ├── client.config.ts              # Branding, domain, GCS bucket name, Firebase config
│   │   ├── landing/                      # Vite + React static site
│   │   │   ├── src/
│   │   │   │   ├── App.tsx               # Composes sections from ui-kit
│   │   │   │   ├── sections/             # Hero, Features, Testimonials, Contact, CTA, FAQ
│   │   │   │   ├── assets/               # Logo, hero image, OG image
│   │   │   │   └── main.tsx
│   │   │   ├── public/
│   │   │   ├── index.html
│   │   │   ├── vite.config.ts
│   │   │   ├── tailwind.config.ts
│   │   │   ├── package.json
│   │   │   └── README.md
│   │   ├── api/                          # NestJS service in Docker
│   │   │   ├── src/
│   │   │   │   ├── main.ts               # Bootstrap; reads PORT from env
│   │   │   │   ├── app.module.ts         # Wires api-core modules + client-specific modules
│   │   │   │   └── client/               # Client-specific custom logic (empty by default)
│   │   │   ├── prisma/
│   │   │   │   ├── schema.prisma         # Inherits base schema; client can extend
│   │   │   │   └── migrations/
│   │   │   ├── Dockerfile
│   │   │   ├── .dockerignore
│   │   │   ├── package.json
│   │   │   ├── tsconfig.json
│   │   │   └── README.md
│   │   ├── dashboard/                    # Vite + React static site
│   │   │   ├── src/
│   │   │   │   ├── App.tsx               # Wraps dashboard-core shell
│   │   │   │   ├── routes/               # Custom routes if the client needs them
│   │   │   │   └── main.tsx
│   │   │   ├── index.html
│   │   │   ├── vite.config.ts
│   │   │   ├── tailwind.config.ts
│   │   │   ├── package.json
│   │   │   └── README.md
│   │   └── README.md                     # Per-client documentation
│   │
│   ├── acme-corp/                        # Example: a real customer
│   │   ├── client.config.ts
│   │   ├── landing/
│   │   ├── api/
│   │   ├── dashboard/
│   │   └── README.md
│   │
│   └── client-two/
│       └── ...
│
├── infra/
│   ├── terraform/
│   │   ├── shared/                       # VPC, Postgres VM, Artifact Registry, WIF, DNS zone
│   │   │   ├── main.tf
│   │   │   ├── variables.tf
│   │   │   ├── outputs.tf
│   │   │   └── README.md
│   │   ├── modules/
│   │   │   └── client-stack/             # Per-client module: bucket, Cloud Run, DB, secrets
│   │   │       ├── main.tf
│   │   │       ├── variables.tf
│   │   │       ├── outputs.tf
│   │   │       └── README.md
│   │   ├── clients.tf                    # One `module "<id>"` block per client
│   │   ├── providers.tf
│   │   ├── backend.tf                    # GCS backend for state
│   │   └── README.md
│   └── vm-bootstrap/                     # Cloud-init / startup script for the Postgres VM
│       ├── startup.sh
│       └── docker-compose.yml
│
├── scripts/
│   ├── new-client.sh                     # Scaffolds clients/<id>/ from _template/
│   ├── deploy-client.sh                  # Manual deploy (CI/CD also calls these steps)
│   └── README.md
│
└── .github/
    └── workflows/
        ├── deploy-acme-corp.yml          # One workflow per client (or matrix-driven)
        ├── deploy-client-two.yml
        └── deploy-shared-infra.yml       # Updates shared resources (VM, Artifact Registry)
```

## Key configuration files

### `pnpm-workspace.yaml`

```yaml
packages:
  - 'packages/*'
  - 'clients/*/landing'
  - 'clients/*/api'
  - 'clients/*/dashboard'
```

This declares every shared package AND every client's landing, api, and dashboard as a workspace member, so pnpm hoists shared dependencies and links local packages by symlink.

### Root `package.json`

```json
{
  "name": "landing-platform",
  "private": true,
  "scripts": {
    "build": "pnpm -r build",
    "lint": "pnpm -r lint",
    "test": "pnpm -r test",
    "new-client": "bash scripts/new-client.sh"
  },
  "devDependencies": {
    "typescript": "^5.5.0",
    "@types/node": "^22.0.0",
    "eslint": "^9.0.0",
    "prettier": "^3.3.0"
  },
  "packageManager": "pnpm@9.10.0"
}
```

### `tsconfig.base.json`

```json
{
  "compilerOptions": {
    "target": "ES2022",
    "module": "ESNext",
    "moduleResolution": "Bundler",
    "strict": true,
    "esModuleInterop": true,
    "skipLibCheck": true,
    "forceConsistentCasingInFileNames": true,
    "resolveJsonModule": true,
    "isolatedModules": true,
    "declaration": true,
    "declarationMap": true,
    "sourceMap": true
  }
}
```

## How shared packages are consumed

Inside `clients/acme-corp/api/package.json`:

```json
{
  "name": "@clients/acme-corp-api",
  "dependencies": {
    "@platform/api-core": "workspace:*",
    "@platform/shared-types": "workspace:*"
  }
}
```

The `workspace:*` protocol tells pnpm to link the local package by symlink rather than fetching from a registry. Changes to `packages/api-core` are reflected immediately in any client API that imports from it.

## Conventions for the `_template` folder

The `_template` folder is the source of truth for new clients. When the user wants to add a customer:

1. `scripts/new-client.sh <id>` copies `_template/` to `clients/<id>/`
2. The script does a find-and-replace to substitute `__CLIENT_ID__` with the actual ID in package names, GCS bucket names, Cloud Run service names, etc.
3. The user customizes `client.config.ts` (branding, domain), the landing page sections, and any custom API logic
4. The user adds a `module "<id>"` block in `infra/terraform/clients.tf`
5. CI/CD picks up changes to `clients/<id>/**` and deploys

Keep `_template/` lean — it should embody the architectural defaults, not have many client-specific examples. Real customizations belong in real client folders.
