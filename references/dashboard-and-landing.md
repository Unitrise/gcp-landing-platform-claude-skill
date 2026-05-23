# Landing page and dashboard templates

> **Prerequisite:** both apps have already been scaffolded with `pnpm create vite@latest <name> -- --template react-ts`, and Tailwind has been initialized with `pnpm dlx tailwindcss init -p`. The dashboard additionally has shadcn/ui set up via `pnpm dlx shadcn@latest init`. See `references/cli-scaffolding.md` for the full command sequence. The code samples below replace specific scaffolded files (`src/App.tsx`, `vite.config.ts` adjustments) — they do not stand alone as full projects.

Both the landing page and the dashboard are Vite + React + TypeScript + Tailwind static builds. They differ in purpose: the landing page is a customer-facing marketing site that collects leads; the dashboard is the admin view of those leads.

Both consume shared packages so customizations stay surgical: the landing page mostly composes `@platform/ui-kit` sections, and the dashboard mostly extends `@platform/dashboard-core`.

## Landing page

### `clients/_template/landing/src/App.tsx`

```typescript
/**
 * Landing page composition.
 *
 * The default template renders a standard hero + features + contact layout.
 * To customize per client, edit this file: swap sections, reorder, add new ones.
 *
 * Per the user's reusable-component preference, prefer composing existing
 * `@platform/ui-kit` components over writing one-off layouts. Only create new
 * components when no existing one fits.
 */

import { ThemeProvider, Section } from '@platform/ui-kit';
import { clientConfig } from '../client.config.js';
import { Hero } from './sections/Hero.js';
import { Features } from './sections/Features.js';
import { Testimonials } from './sections/Testimonials.js';
import { ContactForm } from './sections/ContactForm.js';
import { Footer } from './sections/Footer.js';

export function App() {
  return (
    <ThemeProvider theme={clientConfig.theme}>
      <Hero
        title={clientConfig.copy.hero.title}
        subtitle={clientConfig.copy.hero.subtitle}
        cta={clientConfig.copy.hero.cta}
      />
      <Features items={clientConfig.copy.features} />
      <Testimonials items={clientConfig.copy.testimonials} />
      <Section id="contact">
        {/* ContactForm POSTs to the client's API; configured by VITE_API_URL */}
        <ContactForm apiUrl={import.meta.env.VITE_API_URL} />
      </Section>
      <Footer />
    </ThemeProvider>
  );
}
```

### `clients/_template/client.config.ts`

```typescript
/**
 * Per-client configuration consumed by both the landing page and the dashboard.
 *
 * Branding, domain, copy, and Firebase configuration all live here so swapping
 * customers is editing one file rather than hunting through the codebase.
 */

export const clientConfig = {
  // Identification
  id: '__CLIENT_ID__',
  domain: '__DOMAIN__',

  // Visual identity
  theme: {
    colors: {
      primary: '#6366F1',      // Brand accent
      secondary: '#06B6D4',    // Secondary accent
      background: '#0B0F14',   // Page background
      foreground: '#F5F5F5',   // Text on background
    },
    fonts: {
      sans: '"Inter", system-ui, sans-serif',
      display: '"Rubik", system-ui, sans-serif',
    },
    radius: '8px',
  },

  // Copy
  copy: {
    hero: {
      title: 'Replace me with the customer headline',
      subtitle: 'Replace me with the customer subhead',
      cta: { label: 'Get in touch', target: '#contact' },
    },
    features: [
      { icon: 'zap', title: 'Fast', body: 'Replace me.' },
      { icon: 'shield', title: 'Secure', body: 'Replace me.' },
      { icon: 'sparkles', title: 'Delightful', body: 'Replace me.' },
    ],
    testimonials: [
      // { quote: '...', author: '...', role: '...' },
    ],
  },

  // Backend
  api: {
    // Set in CI from Terraform output; used as VITE_API_URL at build time
    url: '',
  },

  // Firebase Auth for the dashboard
  firebase: {
    apiKey: '',
    authDomain: '',
    projectId: '',
  },
} as const;

export type ClientConfig = typeof clientConfig;
```

### Contact form submission

```typescript
// clients/_template/landing/src/sections/ContactForm.tsx

import { useState } from 'react';
import { Button, Input, Textarea } from '@platform/ui-kit';
import { LeadInputSchema } from '@platform/shared-types';

interface ContactFormProps {
  apiUrl: string;  // From VITE_API_URL — set at build time by CI
}

export function ContactForm({ apiUrl }: ContactFormProps) {
  const [status, setStatus] = useState<'idle' | 'sending' | 'sent' | 'error'>('idle');

  async function handleSubmit(event: React.FormEvent<HTMLFormElement>) {
    event.preventDefault();
    setStatus('sending');

    const formData = new FormData(event.currentTarget);
    const raw = Object.fromEntries(formData.entries());

    // Validate client-side using the shared schema before sending
    const parsed = LeadInputSchema.safeParse(raw);
    if (!parsed.success) {
      setStatus('error');
      return;
    }

    const response = await fetch(`${apiUrl}/leads`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(parsed.data),
    });

    setStatus(response.ok ? 'sent' : 'error');
  }

  if (status === 'sent') {
    return <p>Thanks — we'll be in touch shortly.</p>;
  }

  return (
    <form onSubmit={handleSubmit}>
      <Input name="name" label="Name" required />
      <Input name="email" type="email" label="Email" required />
      <Input name="phone" label="Phone" />
      <Input name="company" label="Company" />
      <Textarea name="message" label="Message" required />
      <Button type="submit" disabled={status === 'sending'}>
        {status === 'sending' ? 'Sending…' : 'Send'}
      </Button>
      {status === 'error' && <p>Something went wrong. Please try again.</p>}
    </form>
  );
}
```

## Dashboard

### `clients/_template/dashboard/src/App.tsx`

```typescript
/**
 * Dashboard composition.
 *
 * The shared `DashboardShell` from @platform/dashboard-core handles auth,
 * navigation, and layout. Per-client customizations go in `routes/` and are
 * passed in as children.
 */

import { DashboardShell, LeadsTable } from '@platform/dashboard-core';
import { clientConfig } from '../client.config.js';

export function App() {
  return (
    <DashboardShell
      clientId={clientConfig.id}
      clientName={clientConfig.copy.hero.title}
      apiUrl={import.meta.env.VITE_API_URL}
      firebaseConfig={clientConfig.firebase}
    >
      <LeadsTable />
      {/* Add client-specific routes here */}
    </DashboardShell>
  );
}
```

### Shared `dashboard-core` auth

```typescript
// packages/dashboard-core/src/auth/AuthProvider.tsx

/**
 * Wraps the dashboard in a Firebase Auth context.
 *
 * Renders a sign-in screen until the user is authenticated, then renders
 * the dashboard with the auth context available to every component.
 */

import { useEffect, useState, createContext, useContext } from 'react';
import { initializeApp, type FirebaseApp } from 'firebase/app';
import {
  getAuth,
  onAuthStateChanged,
  signInWithPopup,
  GoogleAuthProvider,
  signOut,
  type User,
} from 'firebase/auth';

interface AuthContextValue {
  user: User | null;
  loading: boolean;
  signIn: () => Promise<void>;
  signOut: () => Promise<void>;
  getIdToken: () => Promise<string | null>;  // Used by fetch hooks
}

const AuthContext = createContext<AuthContextValue | null>(null);

let firebaseApp: FirebaseApp | null = null;

export function AuthProvider({
  config,
  children,
}: {
  config: { apiKey: string; authDomain: string; projectId: string };
  children: React.ReactNode;
}) {
  const [user, setUser] = useState<User | null>(null);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    if (!firebaseApp) firebaseApp = initializeApp(config);
    const auth = getAuth(firebaseApp);
    return onAuthStateChanged(auth, (u) => {
      setUser(u);
      setLoading(false);
    });
  }, [config]);

  const value: AuthContextValue = {
    user,
    loading,
    signIn: async () => {
      await signInWithPopup(getAuth(firebaseApp!), new GoogleAuthProvider());
    },
    signOut: async () => {
      await signOut(getAuth(firebaseApp!));
    },
    getIdToken: async () => {
      return user ? user.getIdToken() : null;
    },
  };

  return <AuthContext.Provider value={value}>{children}</AuthContext.Provider>;
}

// Hook used by every authed component to grab the current user + token
export function useAuth() {
  const ctx = useContext(AuthContext);
  if (!ctx) throw new Error('useAuth must be used inside AuthProvider');
  return ctx;
}
```

### Authed fetch hook

```typescript
// packages/dashboard-core/src/hooks/useAuthedFetch.ts

/**
 * Wraps fetch with automatic Firebase ID token attachment.
 *
 * Every API request from the dashboard goes through this so the token
 * refresh logic (Firebase rotates tokens hourly) is centralized.
 */

import { useAuth } from '../auth/AuthProvider.js';

export function useAuthedFetch(apiUrl: string) {
  const { getIdToken } = useAuth();

  return async function authedFetch(path: string, init: RequestInit = {}) {
    const token = await getIdToken();
    const headers = new Headers(init.headers);
    if (token) headers.set('Authorization', `Bearer ${token}`);
    headers.set('Content-Type', 'application/json');

    return fetch(`${apiUrl}${path}`, { ...init, headers });
  };
}
```

### Leads table

```typescript
// packages/dashboard-core/src/leads/LeadsTable.tsx

/**
 * The default leads table — sortable, filterable, paginated, CSV-exportable.
 * Clients can wrap or replace it in their own `routes/`.
 */

import { useEffect, useState } from 'react';
import { useAuthedFetch } from '../hooks/useAuthedFetch.js';
import type { Lead } from '@platform/shared-types';

export function LeadsTable({ apiUrl }: { apiUrl: string }) {
  const fetcher = useAuthedFetch(apiUrl);
  const [leads, setLeads] = useState<Lead[]>([]);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    fetcher('/leads')
      .then((r) => r.json())
      .then((data) => {
        setLeads(data.items);
        setLoading(false);
      });
  }, []);

  if (loading) return <p>Loading…</p>;
  if (leads.length === 0) return <p>No leads yet.</p>;

  return (
    <table>
      <thead>
        <tr>
          <th>Name</th>
          <th>Email</th>
          <th>Company</th>
          <th>Submitted</th>
          <th>Status</th>
        </tr>
      </thead>
      <tbody>
        {leads.map((lead) => (
          <tr key={lead.id}>
            <td>{lead.name}</td>
            <td>{lead.email}</td>
            <td>{lead.company ?? '—'}</td>
            <td>{new Date(lead.submittedAt).toLocaleString()}</td>
            <td>{lead.status}</td>
          </tr>
        ))}
      </tbody>
    </table>
  );
}
```

### CSV export

```typescript
// packages/dashboard-core/src/leads/csv-export.ts

/**
 * Convert a leads array to a CSV string and trigger a browser download.
 *
 * Kept in shared dashboard-core because every client dashboard wants this
 * — it would be a copy-paste violation to inline it per client.
 */

import type { Lead } from '@platform/shared-types';

export function downloadLeadsCsv(leads: Lead[], filename = 'leads.csv') {
  const headers = ['Name', 'Email', 'Phone', 'Company', 'Submitted', 'Status', 'Message'];

  const rows = leads.map((lead) => [
    lead.name,
    lead.email,
    lead.phone ?? '',
    lead.company ?? '',
    new Date(lead.submittedAt).toISOString(),
    lead.status,
    // Escape CSV: wrap in quotes, double any internal quotes, replace newlines
    `"${lead.message.replace(/"/g, '""').replace(/\n/g, ' ')}"`,
  ]);

  const csv = [headers, ...rows].map((r) => r.join(',')).join('\n');

  // Trigger download via a temporary anchor element
  const blob = new Blob([csv], { type: 'text/csv;charset=utf-8' });
  const url = URL.createObjectURL(blob);
  const a = document.createElement('a');
  a.href = url;
  a.download = filename;
  a.click();
  URL.revokeObjectURL(url);
}
```

## Vite build configuration

### `clients/_template/landing/vite.config.ts`

```typescript
import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';

export default defineConfig({
  plugins: [react()],
  build: {
    outDir: 'dist',
    sourcemap: true,
    // Helps caching on Cloudflare/GCS — file content hashes change names
    rollupOptions: {
      output: {
        entryFileNames: 'assets/[name]-[hash].js',
        chunkFileNames: 'assets/[name]-[hash].js',
        assetFileNames: 'assets/[name]-[hash][extname]',
      },
    },
  },
  // VITE_API_URL is injected at build time by CI from Terraform outputs
});
```

The dashboard's `vite.config.ts` is identical except the build is in SPA mode (the bucket serves `index.html` for any 404, configured by Terraform's `not_found_page = "index.html"`).
