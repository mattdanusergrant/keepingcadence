# Improvement Plan — keepingcadence

> Generated 2026-07-02 from a full 12-repo portfolio audit (Claude Code session).
> Companion career report: ConductiveOS vault, `09_personal/2026-07-02-life-audit-and-career-plan.md`.

**What this is:** A live, offline-first weekly team-scheduling app (plan vs. actual hours, invites, shared read-only views) whose entire multi-tenant backend is Postgres RLS + RPC functions on Neon — no custom server, just a static single-file app on Vercel plus a 57-line Cloudflare Worker that proxies auth same-origin so the session cookie survives iOS/Safari ITP.

**Stack:** Vanilla JS + HTML/CSS (single-file app.html, no build step), Neon Postgres (RLS, plpgsql SECURITY INVOKER/DEFINER functions), Neon Auth (Better Auth) with cookie session + short-lived Data API JWT, Neon Data API (PostgREST), Cloudflare Workers (auth reverse proxy), Vercel (static hosting, host-based rewrites in vercel.json), localStorage offline cache + URL-hash share links, i18n (EN/ES) and Okabe–Ito colorblind-safe theming · **Maturity:** shipped-live · **Live:** https://app.keepingcadence.com
**Size:** ~3.5k lines total: app.html 2,628 (HTML/CSS/JS), db/schema.sql 505 (SQL), landing.html 298, infra/neon-auth-proxy.js 57

## What's genuinely good here

- Genuinely sophisticated no-server multi-tenant design: every write goes through public SECURITY INVOKER wrappers that capture current_uid() and delegate to SECURITY DEFINER workers in an unexposed kc_private schema (db/schema.sql) — a correct, well-reasoned privilege-separation pattern, including a column-level grant that hides teams.join_token from SELECT (schema.sql:501)
- The auth-proxy saga is real engineering: he diagnosed that Safari ITP/iOS WebKit drops even same-site-subdomain HttpOnly cookies, and fixed it with a same-origin chain (vercel.json rewrite -> CF Worker -> Neon), documenting every non-obvious header transform (strip x-forwarded-host, strip Partitioned, SameSite=None->Lax) in infra/neon-auth-proxy.js
- Documentation quality is exceptional for a personal repo: BACKEND.md is a real runbook (architecture diagram, RPC reference table, setup steps, verified-live checklist) and NEON-REBUILD.md preserves the two hardest-won debugging lessons as 'gotchas'
- Offline-first done properly: fully functional signed out, anonymous #s= hash share links with zero server involvement, localStorage draft cache, and a one-time key migration from the project's former name (app.html:840)
- Security was actually verified, not assumed: BACKEND.md records end-to-end live tests including RLS isolation between users and confirming kc_private workers are unreachable via the Data API
- Accessibility and i18n as defaults: always-on Okabe–Ito colorblind-safe palette, dark mode, bilingual EN/ES with 49 data-i18n hooks
- Clean, narrative commit history (51 commits) that tells the whole story: Supabase -> Vercel serverless -> full Neon-native rebuild with the old api/ layer explicitly decommissioned file-by-file


## Issues found

- Zero tests and zero CI (no .github/, no test/) for a 2,628-line live app with subtle merge logic — his own ronin-survivor repo proves he knows the dependency-free smoke-test + Actions pattern, so its absence here stands out
- flushSaves() (app.html:2166-2196) swallows every save error silently ('the local draft remains the source of truth') — the user is never told a cloud save failed, and there is no retry queue, so 'saved' can quietly mean 'local only'
- Last-write-wins concurrency: weeks.updated_at exists (db/schema.sql:101) but is never used for conflict detection, so two owner devices editing the same week silently clobber each other; cloudPull() (app.html:2218) wholesale replaces local state with server state
- Race in flushSaves: it captures state.weekStart once (app.html:2168) then awaits RPCs per schedule against live s.days objects — navigating to another week mid-flush can persist the new week's days under the old week_start key
- No server-side shape validation in kc_private._save_plan/_save_actuals (db/schema.sql:303-346): arbitrary or multi-megabyte jsonb is accepted for days, a junk-data/DoS vector on a free-tier DB
- dataJwtExp hardcodes a 13-minute TTL (app.html:2124) instead of decoding exp from the JWT it already has a decoder for (decodeJwtSub, app.html:2142)
- Open signups with email verification off (acknowledged in NEON-REBUILD.md) while the app is publicly live at a marketed domain
- No LICENSE file and a README with no screenshot or GIF — weak first impression for a repo whose product is visual


## Ranked improvements

### 1. Port the ronin-survivor smoke test + GitHub Actions CI to this repo  `impact 5/5 · effort M`  ✅ **done 2026-07-06**

> Shipped: `test/smoke.js` (22 assertions over the pure core — hhmm↔minutes round-trip, legacyRangeToBlocks, normalizeDay, migrateState across all three legacy shapes, encode/decode hash round-trip, escapeHtml, daySegments, toggleBlock, fmtHoursNumber) loaded in a Node `vm` behind a DOM/localStorage stub, plus `.github/workflows/test.yml` running it on push/PR. Deferred: the live SQL merge-assertion against a scratch Neon branch (needs DB credentials, not offline-runnable in CI here) and the flushSaves branching test (couples to too much module state to isolate cleanly — better paired with improvement #2's refactor).

**Why:** A live app with cloud-sync merge logic and zero automated checks is the repo's single biggest gap; he already built the exact pattern needed (dependency-free Node smoke test driving an inline <script> behind a DOM stub) in ronin-survivor's test/smoke.js and .github/workflows/test.yml.

**How:** Create test/smoke.js that loads app.html's script in Node behind a minimal DOM/localStorage stub and asserts the pure core: hhmmToMinutes/minutesToHhmm round-trip, legacyRangeToBlocks, normalizeDay, migrateState on legacy drafts, encodeStateToHash->decodeStateFromHash round-trip, and the flushSaves actuals/plan branching with a mocked rpc(). Add .github/workflows/test.yml running `node test/smoke.js` on push/PR. Also add a tiny SQL assertion file (or documented psql script) that exercises save_plan/save_actuals merge behavior against a scratch Neon branch.

**Career angle:** Directly answers the one question a hiring manager will ask of this repo ('where are the tests?') and demonstrates transferable CI discipline across projects.

### 2. Surface sync status and stop swallowing save failures  `impact 5/5 · effort M`  ✅ **done 2026-07-06**

> Shipped: `flushSaves` now returns a result and no longer swallows errors. A persisted dirty-set (`keepingcadence-dirty`) tracks unsynced schedule ids; the saved indicator reflects real cloud state — Saving… / Synced / "Offline — saved on this device" / "Sync failed" — with a Retry button (`#retrySyncBtn`) for the offline/error states. `cloudPull` no longer clobbers schedules still in the dirty-set, so an offline edit survives the next pull. EN/ES strings added. Verified in Chromium against a mocked Neon backend: edit→Synced, offline edit→Offline+retry+dirty, retry→Synced+clean.

**Why:** flushSaves() (app.html:2166) silently discards errors, so users can lose 'saved' work; trust is the whole product for a scheduling app.

**How:** Give flushSaves a result: track per-schedule success/failure, keep a dirty-set of unsynced schedule ids in localStorage, and extend renderSavedIndicator (app.html:1737) to show synced / pending / offline / error states with a retry. Re-attempt the dirty set inside cloudRefresh (app.html:2321) before pulling, and block cloudPull from overwriting schedules still marked dirty.

**Career angle:** Shows product-grade reliability thinking (offline queues, user-visible state) — a staple interview topic for full-stack roles.

### 3. Write the architecture up as a portfolio case study / blog post  `impact 5/5 · effort S`

**Why:** NEON-REBUILD.md's two gotchas (JWT identity is NULL inside SECURITY DEFINER; iOS WebKit refusing even same-site-subdomain cookies) are genuinely blog-worthy, rare, searchable knowledge — currently buried in a repo nobody visits.

**How:** Turn BACKEND.md + NEON-REBUILD.md into one narrative page ('A multi-tenant SaaS with no server: Postgres RLS, PostgREST, and a 57-line auth proxy') on mattdanusergrant.com, with the architecture diagram, the invoker/definer wrapper pattern from db/schema.sql, and the cookie saga from infra/neon-auth-proxy.js. Link it from this repo's README and pin the repo on GitHub.

**Career angle:** Pure career leverage: converts the repo's strongest asset (the docs) into discoverable proof of senior-level debugging and architecture skills; likely to rank for Neon/PostgREST searches.

### 4. Add optimistic concurrency to week saves  `impact 4/5 · effort M`  ✅ **done 2026-07-06**

> Shipped: `save_plan`/`save_actuals` (and their kc_private workers) take a `p_known_updated_at` and return the new `updated_at`. If the stored row is newer than the token, they raise `stale write` (PT409) instead of clobbering. `updated_at` now uses `clock_timestamp()` so concurrent writes get strictly increasing stamps. Client: `cloudPull` records the token per (schedule, week), `flushSaves` sends it and stores the returned stamp; on a stale write it drops its token, clears the dirty flag (no loop), reloads the winning version, and toasts "changed on another device". Verified against real Postgres 16 (`db/test.sql`) and in Chromium (token sent, 409→reload+toast, no loop).

**Why:** weeks.updated_at (db/schema.sql:101) is stored but unused; two devices or an owner+member editing concurrently silently clobber each other under last-write-wins.

**How:** Extend save_plan/save_actuals (and their kc_private workers) with a p_known_updated_at parameter; if the row's updated_at is newer, either raise a 'stale write' error the client turns into a re-pull-and-merge, or return the winning row. Client: store updated_at per (schedule, week) during cloudPull (app.html:2218) and pass it in flushSaves.

**Career angle:** Concurrency control in a distributed-ish system is a classic senior-engineer signal, implemented here in ~40 lines of SQL+JS.

### 5. Fix the flushSaves week-capture race  `impact 4/5 · effort S`  ✅ **done 2026-07-06**

> Shipped: `flushSaves` now takes a synchronous snapshot before its first `await` — the week plus a deep copy of each schedule's days — and iterates the snapshot, so navigating to another week mid-flush can no longer persist the new week's hours under the old `week_start`. Verified in Chromium: started a (delayed) flush on one week, switched weeks while it was in flight, and the save still landed on the original week.

**Why:** flushSaves reads state.weekStart once but awaits network calls against live schedule objects (app.html:2168-2196); switching weeks mid-flush can write the new week's days under the old week key.

**How:** In cloudPush's debounce (app.html:2161), snapshot an immutable payload per schedule — {id, name, colorVar, week: state.weekStart, days: structuredClone(s.days), access} — and have flushSaves iterate the snapshot instead of state.schedules.

### 6. Validate write payloads server-side in kc_private workers  `impact 3/5 · effort S`  ✅ **done 2026-07-06**

> Shipped: `kc_private._require_days` / `_require_actuals` run at the top of the save workers — require a 7-element JSON array, cap `pg_column_size` (16KB days / 4KB actuals), whitelist day-object keys (`blocks`/`actualHours`), require `blocks` to be a bounded array, and restrict actuals entries to string/number/null (PT422/PT413 to the caller). Added `left()` length caps on team names (80), schedule names (80), and color_var (32) in `_init_profile`/`_create_team`/`_rename_team`/`_create_schedule`/`_update_schedule`. All exercised by `db/test.sql` against real Postgres.

**Why:** _save_plan/_save_actuals (db/schema.sql:303-346) accept arbitrary jsonb; a hostile or buggy client can store oversized or malformed days blobs that other members' clients then ingest.

**How:** In _save_plan: require jsonb_typeof(p_days)='array' and jsonb_array_length(p_days)=7, cap pg_column_size(p_days) (e.g. 16KB), and whitelist day-object keys; same for p_actuals in _save_actuals. Add length caps on team/schedule names in _create_team/_create_schedule.

**Career angle:** Defense-in-depth at the database layer rounds out the security story the schema already tells.

### 7. Ship billing with the one serverless function already scoped  `impact 3/5 · effort L`

**Why:** BACKEND.md's Deferred section already designed it: Stripe needs a webhook receiver, the only server this architecture would ever add — this is the entire gap between side project and product.

**How:** Add api/billing.js on Vercel (checkout session + webhook), a plan column on teams (db/schema.sql), and enforce a free-tier limit (e.g. members-per-team) inside kc_private._invite_to_team/_join_by_token so the paywall lives in Postgres like every other rule.

**Career angle:** A live app with real paying users, however few, is a categorically stronger portfolio and negotiation asset than a live demo.

### 8. Add LICENSE, screenshots, and an architecture diagram image to README  `impact 3/5 · effort S`

**Why:** The README is accurate but visually blank; the repo sells a visual product and a clever architecture with zero images, and has no license.

**How:** Add MIT LICENSE; capture two screenshots (week timeline + All view) and a light/dark pair of landing.html; render the BACKEND.md ASCII diagram as an SVG; embed all in README.md above the fold.

**Career angle:** First-impression polish for anyone (recruiter, hiring manager) who lands on the repo — cheap and directly portfolio-facing.


## Skills this repo proves (for hiring managers)

- Postgres authorization engineering: row-level security policies, SECURITY INVOKER/DEFINER privilege separation, unexposed private schemas, column-level grants to hide secrets — real multi-tenant access control written in SQL, not a framework
- Web auth internals at a depth most seniors lack: HttpOnly cookie semantics, SameSite/Partitioned attributes, Safari ITP / Firefox ETP / iOS WebKit cookie persistence rules, JWT minting and refresh-on-401 flows
- Edge/infra composition: Cloudflare Worker reverse proxy with surgical header rewriting, Vercel host-based routing and rewrites, custom-domain DNS across two providers
- PostgREST/Data-API architecture: designing a full CRUD + teams product where the API surface is the database schema itself
- Offline-first client design: localStorage as source of truth, debounced cloud push, focus-triggered pull with edit guards, stateless hash-based sharing, data migration across a product rename
- Disciplined vanilla JS: 2,600 lines, zero dependencies, zero build step, consistent escapeHtml hygiene on all 13 innerHTML sinks
- Technical writing: BACKEND.md and NEON-REBUILD.md read like good internal design docs — architecture, rationale, failure post-mortems, and operational runbooks
- Product/design execution: bilingual landing page, colorblind-safe always-on palette, invite-link growth loop, plan-vs-actuals domain modeling enforced identically in SQL and client


## Career signals

- Shipped and live at a custom domain (app.keepingcadence.com + marketing site, both returning 200) with real auth, real multi-tenant data, and a documented end-to-end verification pass that included negative security tests (RLS isolation, private-schema unreachability)
- Execution speed: the entire Neon-native rebuild — schema, RLS, client integration, teams, invites, landing page, auth-proxy debugging — landed in roughly 8 days of commits (2026-06-14 to 06-22)
- Documentation habit is top-decile for a solo dev: failure post-mortems ('learned the hard way' comments in the Worker), runbooks, and RPC reference tables — exactly what staff-level engineers are paid to produce
- Cost-conscious architecture: deliberately built to run at $0/month (Neon free tier, static Vercel, one free Worker) while remaining honest in docs about the one place a server would ever be needed (Stripe webhooks)
- Commit messages are clean, scoped, and narrative ('Builder: Keeping Cadence — restore session from the cookie, not localStorage'), showing the ConductiveOS agentic workflow produces professional git hygiene
- Gaps a hiring manager would notice: no tests or CI in this repo (despite having built exactly that in ronin-survivor), no LICENSE, silent error swallowing in the sync path, and the repo undersells itself visually (no screenshots)


## Monetization angles

- Per-team subscription via the one Stripe serverless function already scoped in BACKEND.md's Deferred section: free for solo/local use, paid for teams above N members — the paywall enforced in the same Postgres RPCs as every other rule
- Return to the original niche (the repo began as 'nanny-schedule'): nanny/caregiver hour tracking for families and agencies — agencies pay per caregiver, plan-vs-actuals maps exactly to their billing disputes
- Hourly-worker micro-business timesheets: sell CSV/payroll export and week-history reporting as the paid tier on top of the free scheduler
- Sell the architecture itself: package the schema + Worker + client as a 'zero-server SaaS on Neon' starter template or paid tutorial — the documentation is already most of the course material


## Standout artifacts to show off

- db/schema.sql — a complete multi-tenant backend in 505 lines of SQL: RLS policies, the current_uid() invoker-context identity pattern, public wrapper -> kc_private SECURITY DEFINER worker split, and a column-level grant hiding the invite secret; showable to any backend hiring manager as-is
- infra/neon-auth-proxy.js — 57 lines whose comments document a correct diagnosis of iOS WebKit/ITP cookie behavior and the exact header transforms that fix it; a senior-level debugging story in one file
- NEON-REBUILD.md — the two-gotcha post-mortem (SECURITY DEFINER identity NULL; cross-site cookie logout-on-refresh) is the kind of write-up interviewers ask for and rarely get
- BACKEND.md — runbook-grade architecture doc with diagram, RPC reference table, setup guide, and a dated 'verified live' checklist including security negative tests
- The live product itself (app.keepingcadence.com + keepingcadence.com landing) — offline-first, bilingual, colorblind-safe, on custom domains, at $0/month infra cost


## Cross-repo connections

- ConductiveOS: every commit is prefixed 'Builder:' — this repo is the strongest evidence that his agentic personal-OS workflow ships real products; the KC rebuild deserves a case-study note in the vault and makes ConductiveOS itself a credible AI-workflow portfolio piece
- mattdanusergrant (personal site): publish the NEON-REBUILD.md gotchas as a case study/blog post and link the live app — the repo's docs are 80% of a great article already, and the case-study-forge pattern used for design tests applies directly
- ronin-survivor: lift its test/smoke.js + .github/workflows CI pattern (dependency-free Node harness for an inline single-file <script>) almost verbatim to cover app.html's pure functions and sync logic
- Reusable auth/backend template: extract infra/neon-auth-proxy.js + the db/schema.sql wrapper/worker RLS pattern into a 'Neon serverless SaaS starter' any future app can adopt — jabberjawbreaker or daily-dividend-lab get accounts/sync nearly for free
- daily-dividend-lab: if it needs per-user persistence or sharing, the identical Neon Auth + Data API + RLS stack applies with the KC schema as the template
- Landing/design system: landing.html's Okabe–Ito palette, dark-mode variables, and EN/ES toggle are a ready-made kit for mustdesigngames, mdgarage, and any game's marketing page
- Teams/invite-link mechanics (join_token, invite-by-email, roster RPCs) are a drop-in foundation for shared or multiplayer features in cartomancy or fortkickass


#LLM-generated
