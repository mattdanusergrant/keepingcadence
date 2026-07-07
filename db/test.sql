-- Functional tests for the write-path guards added in schema.sql:
--   * #6 server-side payload validation (_require_days / _require_actuals)
--   * #4 optimistic concurrency (p_known_updated_at -> 'stale write' PT409)
--   * name/color length caps
--
-- Run against a scratch database that already has schema.sql applied:
--   psql -f db/schema.sql && psql -f db/test.sql
-- Any failed assertion aborts with a non-zero exit (ON_ERROR_STOP + raise).
-- These call the kc_private workers directly with an explicit p_uid, which is
-- what the public wrappers do after resolving the JWT — so the guard logic is
-- exercised without needing a real Neon Auth token.

\set ON_ERROR_STOP on
set client_min_messages = notice;

-- Fixtures: an owner, their team, an owned schedule, and a member-assigned one.
insert into profiles (user_id, email) values ('owner-1', 'owner@example.com') on conflict do nothing;
insert into profiles (user_id, email) values ('member-1', 'member@example.com') on conflict do nothing;

do $$
declare
  v_team   uuid;
  v_sched  uuid;   -- owner-authored, no assignee
  v_asgn   uuid;   -- assigned to member-1
  v_days   jsonb := (select jsonb_agg(jsonb_build_object('blocks', jsonb_build_array(360, 390), 'actualHours', ''))
                     from generate_series(1, 7));
  v_bad    jsonb;
  v_u1     timestamptz;
  v_u2     timestamptz;
  n        int;
  n2       int;
  ok       boolean;
begin
  -- --- setup ---------------------------------------------------------------
  v_team := (kc_private._create_team('owner-1', 'Test Team')).id;
  insert into team_members (team_id, user_id, email) values (v_team, 'member-1', 'member@example.com');
  v_sched := (kc_private._create_schedule('owner-1', v_team, 'Solo', 'h1', null)).id;
  v_asgn  := (kc_private._create_schedule('owner-1', v_team, 'Assigned', 'h2', 'member-1')).id;

  -- ========================================================================
  -- #6 — payload validation
  -- ========================================================================

  -- Valid 7-day payload is accepted and returns an updated_at.
  v_u1 := kc_private._save_plan('owner-1', v_sched, date '2026-07-06', v_days);
  if v_u1 is null then raise exception 'FAIL: valid save_plan returned null updated_at'; end if;

  -- Wrong length (6 days) is rejected.
  ok := false;
  begin
    perform kc_private._save_plan('owner-1', v_sched, date '2026-07-06',
      (select jsonb_agg(jsonb_build_object('blocks', '[]'::jsonb, 'actualHours', '')) from generate_series(1,6)));
  exception when others then ok := (sqlerrm like '%7 entries%'); end;
  if not ok then raise exception 'FAIL: 6-day payload was not rejected'; end if;

  -- Non-array is rejected.
  ok := false;
  begin perform kc_private._save_plan('owner-1', v_sched, date '2026-07-06', '{"nope":1}'::jsonb);
  exception when others then ok := (sqlerrm like '%JSON array%'); end;
  if not ok then raise exception 'FAIL: non-array days was not rejected'; end if;

  -- Unknown key in a day object is rejected (key whitelist).
  ok := false;
  begin
    v_bad := (select jsonb_agg(jsonb_build_object('blocks','[]'::jsonb,'actualHours','','evil','x')) from generate_series(1,7));
    perform kc_private._save_plan('owner-1', v_sched, date '2026-07-06', v_bad);
  exception when others then ok := (sqlerrm like '%invalid day object%'); end;
  if not ok then raise exception 'FAIL: unknown day key was not rejected'; end if;

  -- blocks-not-an-array is rejected.
  ok := false;
  begin
    v_bad := (select jsonb_agg(jsonb_build_object('blocks','oops','actualHours','')) from generate_series(1,7));
    perform kc_private._save_plan('owner-1', v_sched, date '2026-07-06', v_bad);
  exception when others then ok := (sqlerrm like '%invalid day object%'); end;
  if not ok then raise exception 'FAIL: non-array blocks was not rejected'; end if;

  -- Oversized payload is rejected (>16KB) — pack each day's blocks with junk numbers.
  ok := false;
  begin
    v_bad := (select jsonb_agg(jsonb_build_object(
               'blocks', (select jsonb_agg(g) from generate_series(1, 5000) g),
               'actualHours', '')) from generate_series(1,7));
    perform kc_private._save_plan('owner-1', v_sched, date '2026-07-06', v_bad);
  exception when others then ok := (sqlerrm like '%too large%' or sqlerrm like '%invalid day object%'); end;
  if not ok then raise exception 'FAIL: oversized payload was not rejected'; end if;

  -- actuals: valid path (member logs hours) after a plan exists.
  v_u2 := kc_private._save_plan('owner-1', v_asgn, date '2026-07-06', v_days);
  if kc_private._save_actuals('member-1', v_asgn, date '2026-07-06',
       '["8","8","8","8","8","",""]'::jsonb) is null then
    raise exception 'FAIL: valid save_actuals returned null';
  end if;

  -- actuals: wrong shape rejected.
  ok := false;
  begin perform kc_private._save_actuals('member-1', v_asgn, date '2026-07-06', '"notarray"'::jsonb);
  exception when others then ok := (sqlerrm like '%JSON array%'); end;
  if not ok then raise exception 'FAIL: non-array actuals was not rejected'; end if;

  -- actuals: object entry rejected (must be string/number/null).
  ok := false;
  begin perform kc_private._save_actuals('member-1', v_asgn, date '2026-07-06', '["8",{"x":1},"","","","",""]'::jsonb);
  exception when others then ok := (sqlerrm like '%invalid actuals entry%'); end;
  if not ok then raise exception 'FAIL: object actuals entry was not rejected'; end if;

  -- ========================================================================
  -- #4 — optimistic concurrency
  -- ========================================================================

  -- Passing the CURRENT updated_at succeeds and advances updated_at.
  v_u2 := kc_private._save_plan('owner-1', v_sched, date '2026-07-06', v_days, v_u1);
  if v_u2 <= v_u1 then raise exception 'FAIL: updated_at did not advance on save'; end if;

  -- Passing a STALE (older) updated_at is rejected as a stale write (PT409).
  ok := false;
  begin perform kc_private._save_plan('owner-1', v_sched, date '2026-07-06', v_days, v_u1);
  exception when others then ok := (sqlerrm like '%stale write%'); end;
  if not ok then raise exception 'FAIL: stale save_plan was not rejected'; end if;

  -- Passing null (opt-out) still wins even when the row is newer (back-compat).
  if kc_private._save_plan('owner-1', v_sched, date '2026-07-06', v_days, null) is null then
    raise exception 'FAIL: null-token save_plan should still succeed';
  end if;

  -- Stale actuals are rejected too.
  ok := false;
  begin perform kc_private._save_actuals('member-1', v_asgn, date '2026-07-06',
          '["1","1","1","1","1","",""]'::jsonb, timestamptz '2000-01-01');
  exception when others then ok := (sqlerrm like '%stale write%'); end;
  if not ok then raise exception 'FAIL: stale save_actuals was not rejected'; end if;

  -- ========================================================================
  -- length caps
  -- ========================================================================

  select length(name) into n from teams where id = (kc_private._create_team('owner-1', repeat('x', 500))).id;
  if n <> 80 then raise exception 'FAIL: team name not capped at 80 (got %)', n; end if;

  select length(name), length(color_var) into n, n2 from schedules
    where id = (kc_private._create_schedule('owner-1', v_team, repeat('y', 500), repeat('z', 200), null)).id;
  if n <> 80 then raise exception 'FAIL: schedule name not capped at 80 (got %)', n; end if;
  if n2 <> 32 then raise exception 'FAIL: schedule color not capped at 32 (got %)', n2; end if;

  -- ========================================================================
  -- #7 — free-tier member limit (paywall enforced in Postgres)
  -- ========================================================================
  declare
    v_pteam uuid;
  begin
    v_pteam := (kc_private._create_team('owner-1', 'Cap Test')).id;  -- free plan
    -- Fill to the free cap (3 members).
    insert into profiles (user_id, email) values ('m1','m1@x.com'),('m2','m2@x.com'),
      ('m3','m3@x.com'),('m4','m4@x.com') on conflict do nothing;
    insert into team_members (team_id, user_id, email) values
      (v_pteam,'m1','m1@x.com'),(v_pteam,'m2','m2@x.com'),(v_pteam,'m3','m3@x.com');

    -- A 4th invite on a free team is blocked (PT402).
    ok := false;
    begin perform kc_private._invite_to_team('owner-1', v_pteam, 'm4@x.com');
    exception when others then ok := (sqlerrm like '%member limit%'); end;
    if not ok then raise exception 'FAIL: free team allowed inviting past the cap'; end if;

    -- Joining past the cap is blocked at the authoritative point too.
    ok := false;
    begin perform kc_private._join_by_token('m4', (select join_token from teams where id = v_pteam));
    exception when others then ok := (sqlerrm like '%member limit%'); end;
    if not ok then raise exception 'FAIL: free team allowed joining past the cap'; end if;

    -- Upgrading to pro lifts the cap: the same join now succeeds.
    update teams set plan = 'pro' where id = v_pteam;
    perform kc_private._join_by_token('m4', (select join_token from teams where id = v_pteam));
    if (select count(*) from team_members where team_id = v_pteam) <> 4 then
      raise exception 'FAIL: pro upgrade did not lift the member cap';
    end if;
  end;

  raise notice 'ALL SQL TESTS PASSED';
end $$;
