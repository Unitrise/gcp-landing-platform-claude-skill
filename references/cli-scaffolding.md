# CLI scaffolding

**Always scaffold projects using their official CLI tools before writing any customizations.** Hand-writing `package.json`, `tsconfig.json`, build configs, and lockfiles is brittle — official scaffolders produce the current canonical structure for each framework, and the result is more maintainable.

The other reference files (`nestjs-api-template.md`, `dashboard-and-landing.md`) assume the project has already been scaffolded using the commands below. Their code samples are the *customizations on top* of the scaffolded baseline, not full project replacements.

## Order of operations

1. Bootstrap the monorepo root
2. Create shared packages with `pnpm init`
3. Scaffold the `_template/` apps using official CLIs (`nest new`, `pnpm create vite`)
4. Add Tailwind, Prisma, Firebase, shadcn/ui to the scaffolded apps
5. Wire up workspace dependencies (`workspace:*` protocol)
6. Apply the customizations described in `nestjs-api-template.md` and `dashboard-and-landing.md`

## Step 1: Monorepo root

```bash
mkdir landing-platform && cd landing-platform
git init
pnpm init

# Configure as a workspace root — edit package.json to set "private": true
# and add a "packageManager" field
node -e "
  const pkg = require('./package.json');
  pkg.private = true;
  pkg.packageManager = 'pnpm@9.10.0';
  pkg.scripts = {
    build: 'pnpm -r build',
    lint: 'pnpm -r lint',
    test: 'pnpm -r test',
    'new-client': 'bash scripts/new-client.sh'
  };
  require('fs').writeFileSync('./package.json', JSON.stringify(pkg, null, 2));
"

# pnpm workspace declaration — what counts as a workspace package
cat > pnpm-workspace.yaml <<'EOF'
packages:
  - 'packages/*'
  - 'clients/*/landing'
  - 'clients/*/api'
  - 'clients/*/dashboard'
EOF

# Shared TS config that every package extends
cat > tsconfig.base.json <<'EOF'
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
    "sourceMap": true
  }
}
EOF

# Shared dev tooling at the root
pnpm add -Dw typescript@latest @types/node@latest \
  eslint@latest prettier@latest \
  @typescript-eslint/parser @typescript-eslint/eslint-plugin
```

The `-w` flag installs at the workspace root rather than in a specific package.

## Step 2: Shared packages

Each shared package is initialized with `pnpm init` and then wired up manually — they're small and pure TS, so no framework scaffolding is needed.

```bash
mkdir -p packages/shared-types packages/api-core packages/ui-kit packages/dashboard-core

for pkg in shared-types api-core ui-kit dashboard-core; do
  cd packages/$pkg
  pnpm init
  # Rename to @platform/<pkg>
  node -e "
    const p = require('./package.json');
    p.name = '@platform/$pkg';
    p.private = true;
    p.main = './dist/index.js';
    p.types = './dist/index.d.ts';
    p.scripts = { build: 'tsc', lint: 'eslint src --ext .ts,.tsx' };
    require('fs').writeFileSync('./package.json', JSON.stringify(p, null, 2));
  "
  mkdir -p src
  cat > tsconfig.json <<EOF
{
  "extends": "../../tsconfig.base.json",
  "compilerOptions": { "outDir": "./dist", "rootDir": "./src" },
  "include": ["src/**/*"]
}
EOF
  echo "// Package entry point — re-export public API here" > src/index.ts
  cd ../..
done

# Add the dependencies these packages need
pnpm --filter @platform/shared-types add zod
pnpm --filter @platform/api-core add @nestjs/common @nestjs/core firebase-admin zod pino
pnpm --filter @platform/api-core add -D @types/node
pnpm --filter @platform/ui-kit add react react-dom
pnpm --filter @platform/ui-kit add -D @types/react @types/react-dom
pnpm --filter @platform/dashboard-core add react react-dom firebase @platform/shared-types
pnpm --filter @platform/dashboard-core add -D @types/react @types/react-dom
```

## Step 3: Scaffold the `_template/` apps

The `_template/` folder is the source of truth for new clients — it gets copied by `scripts/new-client.sh`. Scaffold it once using official CLIs.

```bash
mkdir -p clients/_template
cd clients/_template
```

### 3a. NestJS API

```bash
# Official NestJS CLI scaffolder. The --skip-git flag prevents creating
# a nested .git repo; --strict enables strict TS compiler options
pnpm dlx @nestjs/cli new api \
  --strict \
  --skip-git \
  --package-manager pnpm

cd api

# Rename the package and mark it as a workspace member
node -e "
  const p = require('./package.json');
  p.name = '@clients/__CLIENT_ID__-api';
  p.private = true;
  require('fs').writeFileSync('./package.json', JSON.stringify(p, null, 2));
"

# Add workspace dependencies — these are linked, not fetched from npm
pnpm add @platform/api-core@workspace:* @platform/shared-types@workspace:*

# Add Prisma — ORM and migration tool
pnpm add @prisma/client
pnpm add -D prisma
pnpm dlx prisma init --datasource-provider postgresql

# Firebase admin for server-side JWT verification
pnpm add firebase-admin

# Pino for structured logging
pnpm add pino nestjs-pino

cd ..
```

After scaffolding, the API folder has the standard NestJS layout. The customizations in `references/nestjs-api-template.md` (replacing `main.ts`, adding the `LeadsModule` from `api-core`, the Prisma module, etc.) go on top of this scaffold.

### 3b. Landing page (Vite + React + TypeScript)

```bash
# Vite has the cleanest scaffolder for React+TS — pnpm create runs it
pnpm create vite@latest landing -- --template react-ts

cd landing

# Rename and mark as workspace member
node -e "
  const p = require('./package.json');
  p.name = '@clients/__CLIENT_ID__-landing';
  p.private = true;
  require('fs').writeFileSync('./package.json', JSON.stringify(p, null, 2));
"

# Workspace deps
pnpm add @platform/ui-kit@workspace:* @platform/shared-types@workspace:*

# Tailwind — the CLI initializes the config files for us
pnpm add -D tailwindcss@latest postcss autoprefixer
pnpm dlx tailwindcss init -p

# Form helpers
pnpm add react-hook-form

pnpm install
cd ..
```

The Vite scaffolder produces a working dev server out of the box. Tailwind's `init -p` creates `tailwind.config.js` and `postcss.config.js` — both ready to use. Customizations from `references/dashboard-and-landing.md` (the `App.tsx`, sections, contact form) get applied on top.

### 3c. Dashboard (Vite + React + TypeScript + shadcn/ui)

```bash
pnpm create vite@latest dashboard -- --template react-ts

cd dashboard

node -e "
  const p = require('./package.json');
  p.name = '@clients/__CLIENT_ID__-dashboard';
  p.private = true;
  require('fs').writeFileSync('./package.json', JSON.stringify(p, null, 2));
"

pnpm add @platform/dashboard-core@workspace:* @platform/shared-types@workspace:* @platform/ui-kit@workspace:*

# Tailwind first — shadcn requires it
pnpm add -D tailwindcss@latest postcss autoprefixer
pnpm dlx tailwindcss init -p

# Firebase for client-side auth
pnpm add firebase

# React Router for dashboard navigation
pnpm add react-router-dom

# shadcn/ui — installs accessible component primitives you own and can edit.
# This matches the user preference: prefer existing reusable components,
# create new ones only when needed. shadcn gives a starting library to extend.
pnpm dlx shadcn@latest init

# After init, add specific components as needed:
pnpm dlx shadcn@latest add button input table card dialog form

pnpm install
cd ../..  # Back to repo root
```

The shadcn `init` command is interactive on first run — it asks about base color, CSS variables, and where to put components. Accept the defaults (or pre-configure with `components.json` before running) so it's reproducible.

## Step 4: Verify the scaffold builds

Before customizing, confirm the baseline works:

```bash
# Should install all workspace deps and link them
pnpm install

# Build the shared packages first (they're depended on by the apps)
pnpm --filter @platform/* build

# Build each app
pnpm --filter @clients/__CLIENT_ID__-api build
pnpm --filter @clients/__CLIENT_ID__-landing build
pnpm --filter @clients/__CLIENT_ID__-dashboard build
```

If all three builds succeed, the scaffold is good. Now apply the customizations.

## Step 5: Apply customizations

Following the other reference files:

- `references/nestjs-api-template.md` — replace `_template/api/src/main.ts`, add the `LeadsModule` wiring, add the `Dockerfile`, configure the Prisma schema
- `references/dashboard-and-landing.md` — replace `App.tsx` in both `landing` and `dashboard`, add the `client.config.ts`, wire the contact form to the API
- `references/postgres-shared-vm.md` — provision the shared infra
- `references/terraform-client-module.md` — provision the per-client resources
- `references/github-actions-workflow.md` — wire CI/CD

## Step 6: Save the scaffolded `_template/`

Once the template builds cleanly and customizations are in place, commit it. From that point forward, new clients are created by **copying** `_template/` via `scripts/new-client.sh` rather than re-running the CLI scaffolders. This keeps new-client creation fast (seconds, not minutes) and ensures every client starts from the same known-good baseline.

## Regenerating the template

When a major framework version drops (Vite 6, NestJS 11, etc.), refresh `_template/` by re-running the relevant scaffolder against a clean directory, then re-applying the customizations. Diff the new scaffolder output against the old one to learn what changed. A quarterly cadence is usually fine.

## Why use scaffolders instead of writing the files

- **Currency**: Scaffolders produce the latest canonical structure. A hand-written `tsconfig.json` from a year ago is probably suboptimal today.
- **Correctness**: Tools like `nest new` and `pnpm create vite` get the dev dependencies, scripts, and ESM/CJS config right. Subtle bugs in hand-written setups (e.g., wrong `moduleResolution`) are easy to introduce.
- **Less code in the skill**: The skill describes customizations rather than full project files, keeping it small and easier to maintain.
- **Framework idiom**: Each framework's scaffolder embodies the team's recommended conventions — directory layout, file names, test setup. Following those reduces friction for anyone who joins the project later.

## When to deviate

There are a few cases where the scaffolder output needs adjustment:

- **NestJS scaffolder produces CommonJS by default**. If pure ESM is needed, edit `tsconfig.json` to `"module": "NodeNext"` and `package.json` to `"type": "module"` after scaffolding. For most uses, leave it as CommonJS — fewer rough edges.
- **Vite scaffolder uses Babel by default**. For faster builds, swap to SWC: re-run with `--template react-swc-ts` or post-install `pnpm add -D @vitejs/plugin-react-swc` and update `vite.config.ts`.
- **shadcn/ui paths**. If the dashboard's `components.json` ends up with paths that don't match the project layout, edit it before adding more components — fixing paths after adding components requires editing each component's imports.
