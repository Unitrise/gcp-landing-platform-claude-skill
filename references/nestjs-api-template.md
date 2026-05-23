# NestJS API template

> **Prerequisite:** the API has already been scaffolded with `pnpm dlx @nestjs/cli new api --strict --skip-git --package-manager pnpm` and the Prisma/Firebase/Pino dependencies have been installed via `pnpm add`. See `references/cli-scaffolding.md` for the full command sequence. The code samples below are *customizations* applied to the scaffolded output, not files to create from scratch — `nest new` already produces `main.ts`, `app.module.ts`, `package.json`, `tsconfig.json`, etc. Edit those rather than rewriting them.

The API runs as a single Docker container on Cloud Run. It extends `@platform/api-core` for everything reusable (auth, leads module, validation, logging) and only adds client-specific logic on top.

## Container image

### `clients/_template/api/Dockerfile`

```dockerfile
# Multi-stage build keeps the runtime image small (~120MB final)

# ---------------------------------------------------------------------------
# Stage 1: Install dependencies (cached unless package.json changes)
# ---------------------------------------------------------------------------
FROM node:22-alpine AS deps

WORKDIR /app

# Copy workspace metadata first for better Docker layer caching
COPY package.json pnpm-lock.yaml pnpm-workspace.yaml ./
COPY packages/api-core/package.json packages/api-core/
COPY packages/shared-types/package.json packages/shared-types/
COPY clients/__CLIENT_ID__/api/package.json clients/__CLIENT_ID__/api/

# Install pnpm and dependencies for the relevant workspace only
RUN npm install -g pnpm@9
RUN pnpm install --frozen-lockfile --filter @clients/__CLIENT_ID__-api...

# ---------------------------------------------------------------------------
# Stage 2: Build the TypeScript output
# ---------------------------------------------------------------------------
FROM node:22-alpine AS builder

WORKDIR /app

COPY --from=deps /app/node_modules ./node_modules
COPY --from=deps /app/packages/api-core/node_modules ./packages/api-core/node_modules
COPY --from=deps /app/packages/shared-types/node_modules ./packages/shared-types/node_modules
COPY --from=deps /app/clients/__CLIENT_ID__/api/node_modules ./clients/__CLIENT_ID__/api/node_modules

COPY packages/api-core ./packages/api-core
COPY packages/shared-types ./packages/shared-types
COPY clients/__CLIENT_ID__/api ./clients/__CLIENT_ID__/api
COPY tsconfig.base.json ./

RUN npm install -g pnpm@9
RUN pnpm --filter @clients/__CLIENT_ID__-api build

# Generate the Prisma client for the runtime image
RUN pnpm --filter @clients/__CLIENT_ID__-api prisma generate

# ---------------------------------------------------------------------------
# Stage 3: Minimal runtime image
# ---------------------------------------------------------------------------
FROM node:22-alpine AS runtime

WORKDIR /app

# Non-root user for safety
RUN addgroup -S app && adduser -S app -G app

ENV NODE_ENV=production
ENV PORT=8080

# Copy only the built output and production dependencies
COPY --from=builder --chown=app:app /app/clients/__CLIENT_ID__/api/dist ./dist
COPY --from=builder --chown=app:app /app/clients/__CLIENT_ID__/api/node_modules ./node_modules
COPY --from=builder --chown=app:app /app/clients/__CLIENT_ID__/api/prisma ./prisma
COPY --from=builder --chown=app:app /app/clients/__CLIENT_ID__/api/package.json ./

USER app

EXPOSE 8080
CMD ["node", "dist/main.js"]
```

The `__CLIENT_ID__` placeholder is replaced by `scripts/new-client.sh` when scaffolding a customer.

## Application entry point

### `clients/_template/api/src/main.ts`

```typescript
/**
 * NestJS bootstrap.
 *
 * Cloud Run sets PORT in the environment; the app must listen on it.
 * All other config is read from environment variables that Terraform sets
 * via Cloud Run env vars (DATABASE_URL, FIREBASE_PROJECT_ID, ALLOWED_ORIGINS).
 */

import { NestFactory } from '@nestjs/core';
import { ValidationPipe } from '@nestjs/common';
import { configureSecurity, configureLogging } from '@platform/api-core';
import { AppModule } from './app.module.js';

async function bootstrap() {
  // Cloud Run requires listening on 0.0.0.0 so the platform health check works
  const app = await NestFactory.create(AppModule, { bufferLogs: true });

  // Structured logging via pino — replaces NestJS default logger
  configureLogging(app);

  // Helmet, CORS, rate limiting — all in one shared helper
  configureSecurity(app, {
    allowedOrigins: (process.env.ALLOWED_ORIGINS ?? '').split(','),
  });

  // Reject any body that doesn't match the DTO schema
  app.useGlobalPipes(new ValidationPipe({ whitelist: true, transform: true }));

  const port = Number(process.env.PORT ?? 8080);
  await app.listen(port, '0.0.0.0');
}

bootstrap();
```

### `clients/_template/api/src/app.module.ts`

```typescript
/**
 * Root module — composes shared platform modules with client-specific ones.
 *
 * To add client-specific endpoints (custom integrations, webhooks, etc.),
 * create a new module under `./client/` and import it here. Do NOT modify
 * `@platform/api-core` — extend, don't fork.
 */

import { Module } from '@nestjs/common';
import { AuthModule, LeadsModule, HealthModule } from '@platform/api-core';
import { PrismaModule } from './prisma/prisma.module.js';

@Module({
  imports: [
    PrismaModule,    // Provides PrismaService to the rest of the app
    AuthModule,      // Firebase JWT verification guard + decorators
    LeadsModule,     // POST /leads (public), GET /leads (authed)
    HealthModule,    // /health endpoint for Cloud Run probes
    // Add client-specific modules here:
    // ClientCustomModule,
  ],
})
export class AppModule {}
```

## Shared `api-core` package

The reusable pieces live in `packages/api-core/src/`. The most important files:

### `packages/api-core/src/auth/firebase-auth.guard.ts`

```typescript
/**
 * NestJS guard that verifies a Firebase ID token from the Authorization header.
 *
 * Used by the dashboard which signs in via Firebase Auth in the browser,
 * sends the resulting ID token as `Authorization: Bearer <token>`, and the
 * API verifies it server-side before returning leads data.
 */

import {
  CanActivate,
  ExecutionContext,
  Injectable,
  UnauthorizedException,
} from '@nestjs/common';
import { initializeApp, applicationDefault, getApps } from 'firebase-admin/app';
import { getAuth } from 'firebase-admin/auth';

@Injectable()
export class FirebaseAuthGuard implements CanActivate {
  constructor() {
    // Initialize Firebase Admin once — uses Application Default Credentials
    // which on Cloud Run resolve to the attached service account
    if (getApps().length === 0) {
      initializeApp({
        credential: applicationDefault(),
        projectId: process.env.FIREBASE_PROJECT_ID,
      });
    }
  }

  async canActivate(context: ExecutionContext): Promise<boolean> {
    const request = context.switchToHttp().getRequest();
    const authHeader = request.headers.authorization ?? '';
    const token = authHeader.replace(/^Bearer\s+/i, '');

    if (!token) {
      throw new UnauthorizedException('Missing bearer token');
    }

    try {
      const decoded = await getAuth().verifyIdToken(token);
      // Attach to request for downstream handlers
      request.user = { uid: decoded.uid, email: decoded.email };
      return true;
    } catch (err) {
      throw new UnauthorizedException('Invalid or expired token');
    }
  }
}
```

### `packages/api-core/src/leads/leads.controller.ts`

```typescript
/**
 * Base leads controller — extended (or used as-is) by each client API.
 *
 * - `POST /leads` is PUBLIC. The landing page submits unauthenticated leads.
 *   Protection comes from: CORS lock on ALLOWED_ORIGINS, Cloudflare Turnstile,
 *   per-IP rate limiting, and strict body validation.
 *
 * - `GET /leads` and `GET /leads/:id` require Firebase auth (dashboard only).
 */

import {
  Body,
  Controller,
  Get,
  Param,
  Post,
  Query,
  UseGuards,
} from '@nestjs/common';
import { LeadInputSchema, LeadInput } from '@platform/shared-types';
import { ZodPipe } from '../validation/zod.pipe.js';
import { FirebaseAuthGuard } from '../auth/firebase-auth.guard.js';
import { LeadsService } from './leads.service.js';

@Controller('leads')
export class LeadsController {
  constructor(private readonly leads: LeadsService) {}

  // Public: landing page form submission
  @Post()
  async create(@Body(new ZodPipe(LeadInputSchema)) body: LeadInput) {
    return this.leads.create(body);
  }

  // Authed: dashboard list view
  @Get()
  @UseGuards(FirebaseAuthGuard)
  async list(
    @Query('page') page = '1',
    @Query('pageSize') pageSize = '50',
  ) {
    return this.leads.list({
      page: Number(page),
      pageSize: Number(pageSize),
    });
  }

  // Authed: dashboard detail view
  @Get(':id')
  @UseGuards(FirebaseAuthGuard)
  async getOne(@Param('id') id: string) {
    return this.leads.getOne(id);
  }
}
```

### `packages/api-core/src/leads/leads.service.ts`

```typescript
/**
 * Lead persistence + business rules.
 *
 * Uses the client API's PrismaService (injected via the LeadsRepository
 * abstraction so api-core stays decoupled from any single Prisma schema).
 */

import { Injectable, NotFoundException } from '@nestjs/common';
import type { LeadInput } from '@platform/shared-types';
import { LeadsRepository } from './leads.repository.js';

@Injectable()
export class LeadsService {
  constructor(private readonly repo: LeadsRepository) {}

  // Capture a new lead from the landing page
  async create(input: LeadInput) {
    return this.repo.insert({
      ...input,
      // Submission timestamp is server-side; never trust the client's clock
      submittedAt: new Date(),
    });
  }

  async list({ page, pageSize }: { page: number; pageSize: number }) {
    const safePage = Math.max(1, page);
    const safeSize = Math.min(100, Math.max(1, pageSize));
    return this.repo.list({
      skip: (safePage - 1) * safeSize,
      take: safeSize,
    });
  }

  async getOne(id: string) {
    const lead = await this.repo.findById(id);
    if (!lead) throw new NotFoundException(`Lead ${id} not found`);
    return lead;
  }
}
```

## Prisma setup

### `clients/_template/api/prisma/schema.prisma`

```prisma
// Per-client Prisma schema. Clients can extend this with their own tables
// for custom integrations (CRM links, scheduled callbacks, etc.).

generator client {
  provider = "prisma-client-js"
}

datasource db {
  provider = "postgresql"
  url      = env("DATABASE_URL")
}

// Base Lead table — every client has this
model Lead {
  id            String   @id @default(cuid())
  // Contact info from the form
  name          String
  email         String
  phone         String?
  company       String?
  message       String   @db.Text
  // Server-side metadata
  submittedAt   DateTime @default(now())
  ipAddress     String?
  userAgent     String?
  // Allows tagging/filtering in the dashboard
  status        LeadStatus @default(NEW)
  // Free-form fields for client-specific data captured by custom form fields
  customFields  Json?

  @@index([submittedAt])
  @@index([status])
}

enum LeadStatus {
  NEW
  CONTACTED
  QUALIFIED
  CONVERTED
  REJECTED
}
```

After scaffolding a client, run:

```bash
cd clients/<id>/api
pnpm prisma migrate dev --name init
```

This creates the initial migration. CI/CD applies migrations on every deploy via `prisma migrate deploy`.

## Health endpoint for Cloud Run

Cloud Run pings `/health` to determine readiness. The shared `HealthModule` exports a minimal endpoint:

```typescript
// packages/api-core/src/health/health.controller.ts
@Controller('health')
export class HealthController {
  // Returns 200 immediately — Cloud Run only needs to know the container is up
  @Get()
  check() {
    return { status: 'ok', timestamp: new Date().toISOString() };
  }
}
```

For deeper checks (DB connectivity), add a `/health/deep` endpoint in the client API that runs `SELECT 1` against Postgres.

## Local development

```bash
# Start a local Postgres for development (not the shared VM)
docker run --rm -d \
  --name dev-postgres \
  -e POSTGRES_PASSWORD=dev \
  -p 5432:5432 \
  postgres:16-alpine

# Run the API in watch mode
cd clients/<id>/api
DATABASE_URL=postgresql://postgres:dev@localhost:5432/postgres \
FIREBASE_PROJECT_ID=<your-firebase-project> \
ALLOWED_ORIGINS=http://localhost:5173 \
  pnpm dev
```

The dashboard and landing page run on their own dev servers and hit `http://localhost:8080` for the API.
