-- Keeping Cadence — Neon-native schema (multi-team build, 2026-06-21)
--
-- Architecture: browser -> Neon Data API (PostgREST) using Neon Auth JWTs.
-- No custom server. Reads are direct table GETs guarded by RLS; writes go
-- through RPC functions (POST /rpc/<name>) that enforce the teams rules and the
-- plan-vs-actuals split.
--
-- Model: every account is equal — there is no manager/user role. An account can
-- OWN many teams (it created them) and JOIN many teams (by invite), at the same
-- time. A schedule belongs to a team; the team's owner authors the plan, and an
-- assigned member fills in actual hours.
--
-- Apply once (Neon SQL Editor or psql). Safe to re-run (idempotent-ish): it
-- drops the app tables first, so a clean rebuild. After applying, hit
-- "Refresh schema cache" on the Data API page so the new RPCs are exposed.
--
-- IDENTITY — how an RPC/policy learns "who is the signed-in user":
--   On this Neon project, the JWT identity only resolves while running as the
--   `authenticated` role (RLS policies, SECURITY INVOKER functions). Inside a
--   SECURITY DEFINER function (which runs as the table owner) auth.uid() and the
--   request.jwt.claims GUC are BOTH unavailable. So we read the user id exactly
--   once, in the invoker context, via public.current_uid(), and thread it down
--   to the privileged SECURITY DEFINER workers as a parameter.
--
--   public.current_uid()  — SECURITY INVOKER; returns the JWT `sub`. Tries Neon's
--     auth.uid() first, then falls back to request.jwt.claims->>'sub' (which the
--     authenticated role can always read), so it works even if the `authenticated`
--     role was never granted access to the Neon `auth` schema.
--
-- STRUCTURE:
--   public.<rpc>(...)            SECURITY INVOKER wrapper. Captures current_uid()
--                                and calls the matching kc_private worker. These
--                                are the only functions the client/Data API calls.
--   kc_private._<rpc>(p_uid,...) SECURITY DEFINER worker. Original privileged
--                                logic; trusts p_uid (passed by the wrapper from
--                                the verified JWT).
--   kc_private is NOT in the Data API's "Exposed schemas" (public only), so the
--   workers — which trust their p_uid argument — can never be called directly.
--   DO NOT add kc_private to the exposed schemas.

create extension if not exists pgcrypto;  -- gen_random_uuid()

-- Clean rebuild: drop app tables (and the old single-team objects) first.
drop table if exists weeks, schedules, team_invites, team_members, teams, profiles cascade;
drop schema if exists kc_private cascade;
-- save_plan/save_actuals gained a p_known_updated_at arg and now return timestamptz
-- (optimistic concurrency). plpgsql bodies aren't tracked as dependencies, so the
-- old void-returning wrappers survive the kc_private drop — remove them explicitly
-- so a re-apply doesn't leave a stale overload.
drop function if exists save_plan(uuid, date, jsonb);
drop function if exists save_actuals(uuid, date, jsonb);
create schema kc_private;  -- internal workers + RLS helpers; never exposed by the Data API

-- ===========================================================================
-- Tables (RLS on; SELECT via policy, writes via the RPCs below)
-- ===========================================================================

-- App data per Neon Auth user. No role — every account can own and join teams.
-- Email is denormalized here (set at init) so the client never needs
-- neon_auth."user" (which is updated asynchronously).
create table profiles (
  user_id     text primary key,            -- = the JWT `sub` (current_uid())
  email       text,
  created_at  timestamptz not null default now()
);

-- A team, owned by its creator. An account can own many.
create table teams (
  id          uuid primary key default gen_random_uuid(),
  owner_id    text not null,
  name        text not null,
  join_token  uuid not null default gen_random_uuid(),  -- secret; builds the invite link
  plan        text not null default 'free' check (plan in ('free', 'pro')),  -- set only by the billing webhook
  created_at  timestamptz not null default now()
);
create index idx_teams_owner on teams(owner_id);

-- Membership (many-to-many: an account joins many teams). Email is denormalized
-- so an owner can show a roster without reading other profiles. The owner is the
-- team's owner (teams.owner_id) and is not stored as a member row.
create table team_members (
  team_id     uuid not null references teams(id) on delete cascade,
  user_id     text not null,
  email       text,
  created_at  timestamptz not null default now(),
  primary key (team_id, user_id)
);
create index idx_team_members_user on team_members(user_id);

-- A schedule "tab" belongs to a team. The team owner authors the plan; an
-- assigned member fills actual hours.
create table schedules (
  id                uuid primary key default gen_random_uuid(),
  team_id           uuid not null references teams(id) on delete cascade,
  assigned_user_id  text,
  name              text not null,
  color_var         text not null default 'accent',
  created_at        timestamptz not null default now()
);
create index idx_schedules_team     on schedules(team_id);
create index idx_schedules_assigned on schedules(assigned_user_id);

-- One row per (schedule, week). days jsonb = the client's 7-day array.
create table weeks (
  schedule_id  uuid not null references schedules(id) on delete cascade,
  week_start   date not null,
  days         jsonb not null,
  updated_at   timestamptz not null default now(),
  primary key (schedule_id, week_start)
);

-- Invite an email to a specific team; the invitee accepts to join it.
create table team_invites (
  id          uuid primary key default gen_random_uuid(),
  team_id     uuid not null references teams(id) on delete cascade,
  email       text not null,
  status      text not null default 'pending' check (status in ('pending','accepted','declined')),
  created_at  timestamptz not null default now(),
  unique (team_id, email)
);
create index idx_invites_email on team_invites(email) where status = 'pending';

-- ===========================================================================
-- current_uid() — the one place identity is read, in the invoker context.
-- ===========================================================================
create or replace function current_uid()
returns text language plpgsql stable security invoker set search_path = public as $$
  declare v text; claims text;
begin
  -- Preferred: Neon's accessor (works when the authenticated role has auth-schema access).
  begin v := auth.uid()::text; exception when others then v := null; end;
  if v is not null and v <> '' then return v; end if;
  -- Fallback: read the JWT `sub` straight from the PostgREST claims GUC. The
  -- authenticated role can always read this; it needs no access to the auth schema.
  claims := current_setting('request.jwt.claims', true);
  if claims is null or claims = '' then return null; end if;
  return nullif((claims::json) ->> 'sub', '');
end $$;

-- ===========================================================================
-- RLS helpers — SECURITY DEFINER so they bypass RLS on the tables they read,
-- which keeps the membership policies from recursing into each other. They take
-- the uid as a parameter (current_uid() is evaluated in the policy's invoker
-- context and passed in). Live in kc_private so they are never exposed.
-- ===========================================================================
create or replace function kc_private.owned_team_ids(p_uid text)
returns setof uuid language sql security definer set search_path = public stable as $$
  select id from teams where owner_id = p_uid;
$$;

create or replace function kc_private.my_team_ids(p_uid text)
returns setof uuid language sql security definer set search_path = public stable as $$
  select id from teams where owner_id = p_uid
  union
  select team_id from team_members where user_id = p_uid;
$$;

alter table profiles      enable row level security;
alter table teams         enable row level security;
alter table team_members  enable row level security;
alter table schedules     enable row level security;
alter table weeks         enable row level security;
alter table team_invites  enable row level security;

create policy profiles_select on profiles for select to authenticated
  using ( user_id = current_uid() );

create policy teams_select on teams for select to authenticated
  using ( id in (select kc_private.my_team_ids(current_uid())) );

create policy team_members_select on team_members for select to authenticated
  using ( user_id = current_uid() or team_id in (select kc_private.owned_team_ids(current_uid())) );

create policy schedules_select on schedules for select to authenticated
  using ( assigned_user_id = current_uid() or team_id in (select kc_private.owned_team_ids(current_uid())) );

-- A week is visible iff its schedule is (schedules RLS already restricts that).
create policy weeks_select on weeks for select to authenticated
  using ( exists (select 1 from schedules s where s.id = weeks.schedule_id) );

create policy invites_select on team_invites for select to authenticated
  using ( team_id in (select kc_private.owned_team_ids(current_uid()))
          or ( status = 'pending'
               and email = (select email from profiles where user_id = current_uid()) ) );

-- ===========================================================================
-- Payload validation (defense-in-depth). The client already normalises days /
-- actuals, but the Data API lets ANY authenticated caller POST /rpc/save_plan
-- with an arbitrary body, so the DB must not trust the blob: a hostile or buggy
-- client could otherwise store multi-megabyte or malformed jsonb that other
-- members' clients then ingest. PT422/PT413 map to those HTTP statuses in the
-- Data API (PostgREST) and carry the message to the caller.
-- ===========================================================================
create or replace function kc_private._require_days(p_days jsonb)
returns void language plpgsql immutable set search_path = public as $$
begin
  if p_days is null or jsonb_typeof(p_days) <> 'array' then
    raise exception 'days must be a JSON array' using errcode = 'PT422';
  end if;
  if jsonb_array_length(p_days) <> 7 then
    raise exception 'days must have exactly 7 entries' using errcode = 'PT422';
  end if;
  if pg_column_size(p_days) > 16384 then
    raise exception 'days payload too large' using errcode = 'PT413';
  end if;
  -- Each day is an object with only the expected keys; blocks (if present) is a
  -- bounded array (a day has at most 32 half-hour slots; 48 leaves slack).
  if exists (
    select 1 from jsonb_array_elements(p_days) as e(v)
    where jsonb_typeof(e.v) <> 'object'
       or exists (select 1 from jsonb_object_keys(e.v) as k(key) where k.key not in ('blocks', 'actualHours'))
       or (e.v ? 'blocks' and jsonb_typeof(e.v -> 'blocks') <> 'array')
       or (e.v ? 'blocks' and jsonb_array_length(e.v -> 'blocks') > 48)
  ) then
    raise exception 'invalid day object' using errcode = 'PT422';
  end if;
end $$;

create or replace function kc_private._require_actuals(p_actuals jsonb)
returns void language plpgsql immutable set search_path = public as $$
begin
  if p_actuals is null or jsonb_typeof(p_actuals) <> 'array' then
    raise exception 'actuals must be a JSON array' using errcode = 'PT422';
  end if;
  if jsonb_array_length(p_actuals) <> 7 then
    raise exception 'actuals must have exactly 7 entries' using errcode = 'PT422';
  end if;
  if pg_column_size(p_actuals) > 4096 then
    raise exception 'actuals payload too large' using errcode = 'PT413';
  end if;
  if exists (
    select 1 from jsonb_array_elements(p_actuals) as e(v)
    where jsonb_typeof(e.v) not in ('string', 'number', 'null')
  ) then
    raise exception 'invalid actuals entry' using errcode = 'PT422';
  end if;
end $$;

-- ===========================================================================
-- Billing / free-tier limit. The paywall lives in Postgres like every other
-- rule: a free team caps how many members it can hold; 'pro' (set only by the
-- Stripe webhook, via a privileged connection — never a user-callable RPC)
-- lifts the cap. Enforced at every point a member is actually added, so it can't
-- be bypassed by hitting an RPC directly.
-- ===========================================================================
create or replace function kc_private._member_limit_for(p_plan text)
returns int language sql immutable as $$
  select case when p_plan = 'pro' then 1000000 else 3 end;   -- free = up to 3 joined members
$$;

-- Raise (PT402 -> HTTP 402 Payment Required) if the team is at its member cap.
create or replace function kc_private._guard_member_limit(p_team_id uuid)
returns void language plpgsql security definer set search_path = public as $$
  declare v_plan text; v_count int; v_limit int;
begin
  select plan into v_plan from teams where id = p_team_id;
  v_limit := kc_private._member_limit_for(v_plan);
  select count(*) into v_count from team_members where team_id = p_team_id;
  if v_count >= v_limit then
    raise exception 'team member limit reached — upgrade to add more' using errcode = 'PT402';
  end if;
end $$;

-- ===========================================================================
-- Workers (kc_private, SECURITY DEFINER) — original privileged logic; they trust
-- p_uid, which the public wrappers derive from the verified JWT.
-- ===========================================================================

create or replace function kc_private._init_profile(p_uid text, p_email text)
returns public.profiles language plpgsql security definer set search_path = public as $$
  declare r public.profiles;
begin
  insert into profiles (user_id, email)
  values (p_uid, lower(p_email))
  on conflict (user_id) do update set email = excluded.email;
  if not exists (select 1 from teams where owner_id = p_uid) then
    insert into teams (owner_id, name)
    values (p_uid, left(coalesce(nullif(split_part(lower(p_email), '@', 1), ''), 'My team'), 80));
  end if;
  select * into r from profiles where user_id = p_uid;
  return r;
end $$;

create or replace function kc_private._create_team(p_uid text, p_name text)
returns public.teams language plpgsql security definer set search_path = public as $$
  declare tm public.teams;
begin
  insert into teams (owner_id, name)
  values (p_uid, left(coalesce(nullif(trim(p_name), ''), 'Team'), 80))
  returning * into tm;
  return tm;
end $$;

create or replace function kc_private._rename_team(p_uid text, p_team_id uuid, p_name text)
returns public.teams language plpgsql security definer set search_path = public as $$
  declare tm public.teams;
begin
  update teams set name = left(coalesce(nullif(trim(p_name), ''), name), 80)
    where id = p_team_id and owner_id = p_uid
    returning * into tm;
  if tm is null then raise exception 'not your team'; end if;
  return tm;
end $$;

create or replace function kc_private._delete_team(p_uid text, p_team_id uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  delete from teams where id = p_team_id and owner_id = p_uid;
end $$;

create or replace function kc_private._invite_to_team(p_uid text, p_team_id uuid, p_email text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not exists (select 1 from teams where id = p_team_id and owner_id = p_uid) then
    raise exception 'not your team';
  end if;
  perform kc_private._guard_member_limit(p_team_id);  -- early feedback before inviting
  insert into team_invites (team_id, email) values (p_team_id, lower(p_email))
  on conflict (team_id, email) do update set status = 'pending', created_at = now();
end $$;

create or replace function kc_private._accept_invite(p_uid text, p_invite_id uuid)
returns void language plpgsql security definer set search_path = public as $$
  declare inv team_invites; my_email text;
begin
  select email into my_email from profiles where user_id = p_uid;
  select * into inv from team_invites
    where id = p_invite_id and email = my_email and status = 'pending';
  if inv is null then raise exception 'invite not found'; end if;
  perform kc_private._guard_member_limit(inv.team_id);  -- authoritative check at join time
  insert into team_members (team_id, user_id, email)
    values (inv.team_id, p_uid, my_email)
    on conflict (team_id, user_id) do update set email = excluded.email;
  update team_invites set status = 'accepted' where id = inv.id;
end $$;

create or replace function kc_private._decline_invite(p_uid text, p_invite_id uuid)
returns void language plpgsql security definer set search_path = public as $$
  declare my_email text;
begin
  select email into my_email from profiles where user_id = p_uid;
  update team_invites set status = 'declined'
    where id = p_invite_id and email = my_email and status = 'pending';
end $$;

create or replace function kc_private._create_schedule(p_uid text, p_team_id uuid, p_name text,
                                                       p_color text, p_assigned_user_id text)
returns public.schedules language plpgsql security definer set search_path = public as $$
  declare s public.schedules; assignee text := null;
begin
  if not exists (select 1 from teams where id = p_team_id and owner_id = p_uid) then
    raise exception 'not your team';
  end if;
  if p_assigned_user_id is not null then
    if not exists (select 1 from team_members where team_id = p_team_id and user_id = p_assigned_user_id) then
      raise exception 'assignee is not on this team';
    end if;
    assignee := p_assigned_user_id;
  end if;
  insert into schedules (team_id, assigned_user_id, name, color_var)
  values (p_team_id, assignee, left(coalesce(p_name, 'Schedule'), 80), left(coalesce(p_color, 'accent'), 32))
  returning * into s;
  return s;
end $$;

create or replace function kc_private._update_schedule(p_uid text, p_schedule_id uuid, p_name text,
                                                       p_color text, p_assigned_user_id text,
                                                       p_clear_assignee boolean)
returns public.schedules language plpgsql security definer set search_path = public as $$
  declare s public.schedules; tid uuid;
begin
  select team_id into tid from schedules where id = p_schedule_id;
  if tid is null or not exists (select 1 from teams where id = tid and owner_id = p_uid) then
    raise exception 'not your schedule';
  end if;
  if p_clear_assignee then
    update schedules set assigned_user_id = null where id = p_schedule_id;
  elsif p_assigned_user_id is not null then
    if not exists (select 1 from team_members where team_id = tid and user_id = p_assigned_user_id) then
      raise exception 'assignee is not on this team';
    end if;
    update schedules set assigned_user_id = p_assigned_user_id where id = p_schedule_id;
  end if;
  update schedules set name = coalesce(left(p_name, 80), name), color_var = coalesce(left(p_color, 32), color_var)
    where id = p_schedule_id;
  select * into s from schedules where id = p_schedule_id;
  return s;
end $$;

-- p_known_updated_at = the weeks.updated_at the client last saw for this row.
-- If the stored row is newer, another device wrote in between: raise 'stale write'
-- (PT409) instead of silently clobbering. Passing null skips the check (first
-- write for the week, or a client that opts out). Returns the new updated_at so
-- the caller can keep its optimistic token fresh without a re-read.
create or replace function kc_private._save_plan(p_uid text, p_schedule_id uuid, p_week_start date,
                                                 p_days jsonb, p_known_updated_at timestamptz default null)
returns timestamptz language plpgsql security definer set search_path = public as $$
  declare existing jsonb; merged jsonb; has_assignee boolean; tid uuid; aid text;
          cur_upd timestamptz; new_upd timestamptz;
begin
  perform kc_private._require_days(p_days);
  select team_id, assigned_user_id into tid, aid from schedules where id = p_schedule_id;
  if tid is null or not exists (select 1 from teams where id = tid and owner_id = p_uid) then
    raise exception 'not your schedule';
  end if;
  select updated_at into cur_upd from weeks where schedule_id = p_schedule_id and week_start = p_week_start;
  if p_known_updated_at is not null and cur_upd is not null and cur_upd > p_known_updated_at then
    raise exception 'stale write' using errcode = 'PT409';
  end if;
  has_assignee := aid is not null;
  if has_assignee then
    -- a member owns the actuals, so carry over each day's existing actualHours
    existing := (select days from weeks where schedule_id = p_schedule_id and week_start = p_week_start);
    select jsonb_agg(
             (p_days -> idx) || jsonb_build_object('actualHours',
               coalesce(existing -> idx ->> 'actualHours', p_days -> idx ->> 'actualHours', ''))
             order by idx)
      into merged
      from generate_series(0, jsonb_array_length(p_days) - 1) as t(idx);
  else
    merged := p_days;  -- no assignee: the owner controls both plan and actuals
  end if;
  -- clock_timestamp() (not now()) so updated_at reflects the real instant of the
  -- write: two writes in the same transaction still get distinct, increasing
  -- stamps, which is what the optimistic-concurrency check above compares.
  insert into weeks (schedule_id, week_start, days, updated_at)
    values (p_schedule_id, p_week_start, merged, clock_timestamp())
    on conflict (schedule_id, week_start) do update set days = excluded.days, updated_at = clock_timestamp()
    returning updated_at into new_upd;
  return new_upd;
end $$;

create or replace function kc_private._save_actuals(p_uid text, p_schedule_id uuid, p_week_start date,
                                                    p_actuals jsonb, p_known_updated_at timestamptz default null)
returns timestamptz language plpgsql security definer set search_path = public as $$
  declare existing jsonb; merged jsonb; cur_upd timestamptz; new_upd timestamptz;
begin
  perform kc_private._require_actuals(p_actuals);
  if not exists (select 1 from schedules where id = p_schedule_id and assigned_user_id = p_uid) then
    raise exception 'not assigned to you';
  end if;
  select days, updated_at into existing, cur_upd from weeks where schedule_id = p_schedule_id and week_start = p_week_start;
  if existing is null then raise exception 'no plan for this week yet'; end if;
  if p_known_updated_at is not null and cur_upd is not null and cur_upd > p_known_updated_at then
    raise exception 'stale write' using errcode = 'PT409';
  end if;
  select jsonb_agg(
           (existing -> idx) || jsonb_build_object('actualHours',
             coalesce(p_actuals ->> idx, existing -> idx ->> 'actualHours', ''))
           order by idx)
    into merged
    from generate_series(0, jsonb_array_length(existing) - 1) as t(idx);
  update weeks set days = merged, updated_at = clock_timestamp()
    where schedule_id = p_schedule_id and week_start = p_week_start
    returning updated_at into new_upd;
  return new_upd;
end $$;

create or replace function kc_private._delete_schedule(p_uid text, p_schedule_id uuid)
returns void language plpgsql security definer set search_path = public as $$
  declare tid uuid;
begin
  select team_id into tid from schedules where id = p_schedule_id;
  if tid is not null and exists (select 1 from teams where id = tid and owner_id = p_uid) then
    delete from schedules where id = p_schedule_id;
  end if;
end $$;

create or replace function kc_private._remove_member(p_uid text, p_team_id uuid, p_user_id text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not exists (select 1 from teams where id = p_team_id and owner_id = p_uid) then
    raise exception 'not your team';
  end if;
  update schedules set assigned_user_id = null
    where team_id = p_team_id and assigned_user_id = p_user_id;
  delete from team_members where team_id = p_team_id and user_id = p_user_id;
end $$;

create or replace function kc_private._leave_team(p_uid text, p_team_id uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  update schedules set assigned_user_id = null
    where team_id = p_team_id and assigned_user_id = p_uid;
  delete from team_members where team_id = p_team_id and user_id = p_uid;
end $$;

create or replace function kc_private._team_invite_link(p_uid text, p_team_id uuid)
returns text language plpgsql security definer set search_path = public as $$
  declare tok uuid;
begin
  select join_token into tok from teams where id = p_team_id and owner_id = p_uid;
  if tok is null then raise exception 'not your team'; end if;
  return tok::text;
end $$;

create or replace function kc_private._regenerate_team_link(p_uid text, p_team_id uuid)
returns text language plpgsql security definer set search_path = public as $$
  declare tok uuid;
begin
  update teams set join_token = gen_random_uuid()
    where id = p_team_id and owner_id = p_uid
    returning join_token into tok;
  if tok is null then raise exception 'not your team'; end if;
  return tok::text;
end $$;

create or replace function kc_private._join_by_token(p_uid text, p_token uuid)
returns json language plpgsql security definer set search_path = public as $$
  declare tm teams; my_email text;
begin
  select * into tm from teams where join_token = p_token;
  if tm is null then raise exception 'invalid or expired invite link'; end if;
  select email into my_email from profiles where user_id = p_uid;
  if tm.owner_id <> p_uid then
    -- only counts against the cap when actually adding a new member (not a re-join)
    if not exists (select 1 from team_members where team_id = tm.id and user_id = p_uid) then
      perform kc_private._guard_member_limit(tm.id);
    end if;
    insert into team_members (team_id, user_id, email)
    values (tm.id, p_uid, my_email)
    on conflict (team_id, user_id) do update set email = excluded.email;
  end if;
  return json_build_object('id', tm.id, 'name', tm.name, 'owner_id', tm.owner_id);
end $$;

-- ===========================================================================
-- Public wrappers (SECURITY INVOKER) — the only RPCs the Data API exposes. Each
-- reads current_uid() in the authenticated context and hands it to its worker.
-- Signatures match what the client calls (POST /rpc/<name>, these arg names).
-- ===========================================================================

create or replace function init_profile(p_email text)
returns public.profiles language plpgsql security invoker set search_path = public as $$
begin return kc_private._init_profile(current_uid(), p_email); end $$;

create or replace function create_team(p_name text)
returns public.teams language plpgsql security invoker set search_path = public as $$
begin return kc_private._create_team(current_uid(), p_name); end $$;

create or replace function rename_team(p_team_id uuid, p_name text)
returns public.teams language plpgsql security invoker set search_path = public as $$
begin return kc_private._rename_team(current_uid(), p_team_id, p_name); end $$;

create or replace function delete_team(p_team_id uuid)
returns void language plpgsql security invoker set search_path = public as $$
begin perform kc_private._delete_team(current_uid(), p_team_id); end $$;

create or replace function invite_to_team(p_team_id uuid, p_email text)
returns void language plpgsql security invoker set search_path = public as $$
begin perform kc_private._invite_to_team(current_uid(), p_team_id, p_email); end $$;

create or replace function accept_invite(p_invite_id uuid)
returns void language plpgsql security invoker set search_path = public as $$
begin perform kc_private._accept_invite(current_uid(), p_invite_id); end $$;

create or replace function decline_invite(p_invite_id uuid)
returns void language plpgsql security invoker set search_path = public as $$
begin perform kc_private._decline_invite(current_uid(), p_invite_id); end $$;

create or replace function create_schedule(p_team_id uuid, p_name text, p_color text default 'accent',
                                           p_assigned_user_id text default null)
returns public.schedules language plpgsql security invoker set search_path = public as $$
begin return kc_private._create_schedule(current_uid(), p_team_id, p_name, p_color, p_assigned_user_id); end $$;

create or replace function update_schedule(p_schedule_id uuid, p_name text default null,
                                           p_color text default null,
                                           p_assigned_user_id text default null,
                                           p_clear_assignee boolean default false)
returns public.schedules language plpgsql security invoker set search_path = public as $$
begin return kc_private._update_schedule(current_uid(), p_schedule_id, p_name, p_color,
                                         p_assigned_user_id, p_clear_assignee); end $$;

create or replace function save_plan(p_schedule_id uuid, p_week_start date, p_days jsonb,
                                     p_known_updated_at timestamptz default null)
returns timestamptz language plpgsql security invoker set search_path = public as $$
begin return kc_private._save_plan(current_uid(), p_schedule_id, p_week_start, p_days, p_known_updated_at); end $$;

create or replace function save_actuals(p_schedule_id uuid, p_week_start date, p_actuals jsonb,
                                        p_known_updated_at timestamptz default null)
returns timestamptz language plpgsql security invoker set search_path = public as $$
begin return kc_private._save_actuals(current_uid(), p_schedule_id, p_week_start, p_actuals, p_known_updated_at); end $$;

create or replace function delete_schedule(p_schedule_id uuid)
returns void language plpgsql security invoker set search_path = public as $$
begin perform kc_private._delete_schedule(current_uid(), p_schedule_id); end $$;

create or replace function remove_member(p_team_id uuid, p_user_id text)
returns void language plpgsql security invoker set search_path = public as $$
begin perform kc_private._remove_member(current_uid(), p_team_id, p_user_id); end $$;

create or replace function leave_team(p_team_id uuid)
returns void language plpgsql security invoker set search_path = public as $$
begin perform kc_private._leave_team(current_uid(), p_team_id); end $$;

create or replace function team_invite_link(p_team_id uuid)
returns text language plpgsql security invoker set search_path = public as $$
begin return kc_private._team_invite_link(current_uid(), p_team_id); end $$;

create or replace function regenerate_team_link(p_team_id uuid)
returns text language plpgsql security invoker set search_path = public as $$
begin return kc_private._regenerate_team_link(current_uid(), p_team_id); end $$;

create or replace function join_by_token(p_token uuid)
returns json language plpgsql security invoker set search_path = public as $$
begin return kc_private._join_by_token(current_uid(), p_token); end $$;

-- ===========================================================================
-- Grants for the Data API roles. Reads = SELECT (RLS-filtered); every write goes
-- through a public wrapper. kc_private is granted to authenticated so the
-- wrappers/policies can call into it, but it is NEVER exposed by the Data API
-- (exposed schemas = public only), so its workers can't be called directly.
-- ===========================================================================
grant usage on schema public to authenticated;
grant usage on schema kc_private to authenticated;
grant select on profiles, team_members, schedules, weeks, team_invites to authenticated;
-- teams: every column except join_token (the invite secret; owners fetch it via RPC)
grant select (id, owner_id, name, plan, created_at) on teams to authenticated;
grant execute on all functions in schema public to authenticated;
grant execute on all functions in schema kc_private to authenticated;

notify pgrst, 'reload schema';
