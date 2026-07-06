# Keeping Cadence

A weekly schedule app for groups of people. Plot each person's hours on a shared
timeline, log actual hours worked, and share read-only views with anyone.

Live at: https://app.keepingcadence.com

## Shape

- **Front-end** — a single self-contained `app.html` (HTML + CSS + vanilla JS,
  no build step). Works fully offline using `localStorage` + URL-hash share
  links. Served as a static page on **Vercel**.
- **Cloud (accounts + teams)** — the browser talks **directly to Neon**: **Neon
  Auth** for login, the **Neon Data API** (PostgREST) for reads, and Postgres
  **RPC functions** for writes, all guarded by **row-level security**. There is
  **no custom server**. Accounts add cross-device sync and a manager/member team
  model (invite people, assign schedules, split plan vs. actual hours). See
  **[BACKEND.md](BACKEND.md)** for setup and **[NEON-REBUILD.md](NEON-REBUILD.md)**
  for the architecture and build status.

Cloud is configured in the `CLOUD` block near the top of `app.html`'s script
(`authBase` + `dataApi`). Signed out, the app stays fully local; anonymous
sharing always uses the client-side `#s=` hash link (no server involved).

## Tests

The load-bearing pure logic — time math, legacy-data migration, day
normalisation, and the `#s=` share-link round-trip — is covered by a
dependency-free smoke test. It reads `app.html`'s inline `<script>`, runs it in a
Node `vm` behind a minimal DOM/localStorage stub, and asserts the pure core:

```bash
node test/smoke.js
```

CI runs it on every push and pull request (`.github/workflows/test.yml`).
