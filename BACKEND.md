# Keeping Cadence — Backend (Neon, server-less)

The front-end (`app.html`) runs fully on its own. The cloud layer adds
**accounts, cross-device sync, and many-to-many teams** (any account can create
and join many teams, invite people, assign schedules, and split the plan from the
actual hours). It is **"max-Neon"**: the browser talks directly to Neon, with
**no custom server** — the only edge piece is a tiny stateless Cloudflare Worker
that proxies auth so the session cookie is first-party (see **Auth proxy** below).

```
Browser (static, on Vercel)
  ├── Neon Auth (Better Auth)   login → HttpOnly session cookie, proxied SAME-ORIGIN:
  │                             app.keepingcadence.com/__neonauth → CF Worker → Neon
  │                             → /token exchanges the cookie for a short-lived Data API JWT
  ├── Neon Data API (PostgREST) reads: GET /schedules,/weeks,/profiles,/teams,/team_invites (RLS-filtered, bearer JWT)
  └── Postgres RPCs (POST /rpc/*) writes: SECURITY INVOKER wrappers → SECURITY DEFINER workers
```

- **Login is an HttpOnly cookie.** Neon Auth returns no bearer token, so the
  durable session is the cookie; the client calls `/get-session` (cookie) on load
  to restore, and `/token` to mint a short-lived Data API JWT (refreshed on 401).
- **Reads** go straight to tables through the Data API; **row-level security**
  decides what each user can see.
- **Writes** never touch tables directly — they go through RPCs (details below)
  that enforce the teams rules and the plan-vs-actuals split.

> This replaced an earlier design (a Vercel `/api` serverless layer with
> scrypt+JWT auth). Those files (`api/*.js`, `package.json`) were removed.

## Identity — how an RPC/policy learns "who is signed in"

This is the non-obvious part. On this Neon project the JWT identity **only
resolves while running as the `authenticated` role** — i.e. in RLS policies and
`SECURITY INVOKER` functions. Inside a `SECURITY DEFINER` function (which runs as
the table owner) `auth.uid()` and the `request.jwt.claims` GUC are both
unavailable, so reading identity there returns NULL.

So the schema reads the user id **once, in the invoker context**, and threads it
down:

- **`public.current_uid()`** — `SECURITY INVOKER`; returns the JWT `sub`. Tries
  `auth.uid()`, falls back to `request.jwt.claims->>'sub'` (which the
  `authenticated` role can always read), so it works even if the project never
  granted `authenticated` access to the Neon `auth` schema.
- **RPCs** are thin `public` `SECURITY INVOKER` wrappers that capture
  `current_uid()` and call a matching `SECURITY DEFINER` worker in the **unexposed
  `kc_private` schema** (Data API exposes `public` only). Same RPC names/args as
  before — the client is unchanged. Because the workers trust their `p_uid`
  argument, they must never be exposed: **do not add `kc_private` to the Data
  API's exposed schemas.**
- **RLS policies** use `current_uid()` directly and call `kc_private`
  helpers (`owned_team_ids`/`my_team_ids`) with it as a parameter.

## Auth proxy — why the session cookie is same-origin

Neon Auth's session is an HttpOnly cookie set by the `…neon.tech` endpoint. Hit
directly, it's **cross-site** to `app.keepingcadence.com`, so Safari ITP / Firefox
ETP / iOS drop it on refresh (a same-site *subdomain* cookie wasn't enough — iOS
won't persist a cookie for a host the user never visited top-level). Fix: proxy
auth through the app's **own origin**:

```
app.keepingcadence.com/__neonauth/*
  → (vercel.json rewrite) → https://auth.keepingcadence.com/neondb/auth/*
  → (Cloudflare Worker, infra/neon-auth-proxy.js) → Neon Auth
```

The cookie lands on `app.keepingcadence.com` itself, which every browser keeps.
The Worker also strips `x-forwarded-host` (Vercel adds it; Neon rejects it →
`INVALID_HOSTNAME`) and rewrites the cookie to `SameSite=Lax` (no `Partitioned`).
The Data API stays on `neon.tech` — it uses the bearer JWT, no cookie.

## Accounts & teams

There are **no roles**. Every account is equal and can both **own** teams (it
created them) and **join** teams (by invite) — many of each, at the same time.
`init_profile(p_email)` also guarantees you a personal default team.

- A **team** is owned by its creator and groups **schedules**. The owner authors
  the **plan** and assigns each schedule to a member; members see the schedules
  assigned to them and fill in **actual hours only**.
- "Role" is therefore **per-team and derived**: you are the *owner* of a team you
  created and a *member* of a team you joined. The client tracks an **active
  team**; schedules belong to it, and a toolbar selector switches between teams.

The plan-vs-actuals split is enforced in Postgres: `save_plan` (team owner)
preserves a member's `actualHours`; `save_actuals` (assigned member) preserves
the plan. The client mirrors it. Anonymous, account-free sharing still uses the
client-side `#s=` hash link.

## Files

| Path | Purpose |
|---|---|
| `db/schema.sql` | The whole backend: tables (`profiles`, `teams`, `team_members`, `schedules`, `weeks`, `team_invites`) + RLS + `current_uid()` + the public invoker wrappers + the `kc_private` SECURITY DEFINER workers + Data API grants. A clean rebuild — drops the app tables first. Run once against the Neon project. |
| `app.html` | Front-end **and** the cloud client (the `CLOUD` block + auth / Data API / RPC calls). |
| `infra/neon-auth-proxy.js` | The Cloudflare Worker for the same-origin auth proxy (source of truth; deployed via the Cloudflare dashboard). |
| `vercel.json` | Host routing (app vs landing) + the `/__neonauth` → Worker rewrite. |
| `NEON-REBUILD.md` | Architecture history + the two identity/cookie gotchas, for context. |

## Setup

### 1. Neon project
1. Create a **dedicated** Neon project for Keeping Cadence at <https://neon.tech>.
2. Enable **Neon Auth** and the **Data API** (check **"Use Neon Auth"** so the
   `authenticated` role is wired). Set the Neon Auth app/display name + email
   sender to **"Keeping Cadence"**. Email/password required; email verification is
   an optional toggle (off = instant signup).
3. Apply the schema — paste `db/schema.sql` into the Neon **SQL Editor** (then hit
   **Refresh schema cache** on the Data API page so the RPCs are exposed).

### 2. Auth proxy (first-party cookie)
1. Deploy `infra/neon-auth-proxy.js` as a Cloudflare Worker; point `UPSTREAM` at
   the project's Neon Auth host.
2. Give the Worker the custom domain **`auth.keepingcadence.com`** (its zone must
   be in the same Cloudflare account as the Worker).
3. `vercel.json` already rewrites `/__neonauth/:path*` → that Worker.

### 3. Point the client at Neon
In `app.html`, the `CLOUD` block near the top of the script:
```js
const CLOUD = {
  enabled: true,
  authBase: 'https://app.keepingcadence.com/__neonauth',                       // same-origin proxy
  dataApi:  'https://<endpoint>.apirest.<region>.aws.neon.tech/<db>/rest/v1',   // Data API, direct
};
```
The Data API URL is public — security is enforced by Neon Auth + RLS. Set
`enabled: false` to ship the app fully local (no Account button).

### 4. Deploy the static site (Vercel)
Import the repo and deploy. No env vars or build step. `vercel.json` routes by
host: `app.keepingcadence.com` → the app (`app.html`); `keepingcadence.com` +
`www` → the marketing page (`landing.html`). The app is **not** `index.html` on
purpose so Vercel's host rewrites can run (a static `/` would be served before
them). Note: pushes don't auto-promote — promote the new deploy to Production.

## RPC reference (POST `/rpc/<name>`, JSON body uses these arg names)
Client-facing signatures (the public wrappers; identity comes from the session, not an argument):

| Function | Who | Effect |
|---|---|---|
| `init_profile(p_email)` | any signed-in | Create your profile on first sign-in (idempotent); guarantees a personal default team. |
| `create_team(p_name)` · `rename_team(p_team_id, p_name)` · `delete_team(p_team_id)` | any · owner | Create a team you own; rename / delete one you own (delete cascades). |
| `invite_to_team(p_team_id, p_email)` | owner | Invite by email. |
| `accept_invite(p_invite_id)` / `decline_invite(p_invite_id)` | invitee | Join / dismiss a pending invite. |
| `team_invite_link(p_team_id)` / `regenerate_team_link(p_team_id)` / `join_by_token(p_token)` | owner / owner / any signed-in | Fetch / rotate a team's invite-link token; join a team by token. |
| `create_schedule(p_team_id, p_name, p_color?, p_assigned_user_id?)` | owner | New schedule in that team. |
| `update_schedule(p_schedule_id, p_name?, p_color?, p_assigned_user_id?, p_clear_assignee?)` | owner | Rename / recolor / (re)assign. |
| `delete_schedule(p_schedule_id)` | owner | Delete (its weeks cascade). |
| `save_plan(p_schedule_id, p_week_start, p_days, p_known_updated_at?)` | owner | Write the week's plan; preserves a member's `actualHours`. Validates `p_days` shape (7-day array, ≤16KB, whitelisted keys). Returns the new `updated_at`; if `p_known_updated_at` is older than the stored row it raises `stale write` (PT409) instead of clobbering. |
| `save_actuals(p_schedule_id, p_week_start, p_actuals, p_known_updated_at?)` | assigned member | Write only the week's actual hours; preserves the plan. Validates `p_actuals` shape. Same optimistic-concurrency contract as `save_plan`. |
| `remove_member(p_team_id, p_user_id)` / `leave_team(p_team_id)` | owner / member | Remove a member / leave a team. |

## Verified live (2026-06-22)
End-to-end against live Neon: signup → `init_profile` → personal default team;
create schedule → save → read-back; team invite links; **RLS isolation** (a user
can't see another's teams/schedules); the `kc_private` workers are unreachable via
the Data API (no impersonation). Login persists across refresh on Firefox, Safari,
and iOS (same-origin cookie + cookie-based `restoreSession`).

## Deferred
**Billing (Stripe).** Neon can't receive webhooks, so subscriptions would need
one small serverless function (the only server this design would ever add).
Deferred until the product is monetized.
