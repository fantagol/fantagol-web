-- ============================================================================
-- FANTAGOL MIGRATION 299
-- PUBLICATION AUTHORITY READER REPAIR
-- ============================================================================
-- Contract:
--   * round_simulation_publications(status='published', channel='realtime')
--     is the sole public visibility authority for round simulations.
--   * round_simulations.publishable remains internal readiness state only.
--   * preserve all public RPC signatures and payload shapes.
--   * exact deployed-definition hashes are guarded before rewrite.
-- ============================================================================

create or replace view public.current_realtime_published_round_simulation_v as
select rs.*
from public.round_simulation_publications rsp
join public.round_simulations rs
  on rs.id = rsp.simulation_id
 and rs.league_round_id = rsp.league_round_id
where rsp.channel = 'realtime'
  and rsp.status = 'published';

revoke all on table public.current_realtime_published_round_simulation_v
from public, anon, authenticated;

comment on view public.current_realtime_published_round_simulation_v is
'Canonical realtime public read authority. Resolves round_simulations exclusively through the current published row in round_simulation_publications.';

DO $r64$
declare
  v_def text;
  v_new text;
begin
  -- get_my_points_preview_rpc
  select pg_get_functiondef('public.get_my_points_preview_rpc(uuid)'::regprocedure)
  into v_def;
  if md5(v_def) <> 'bb964a08f9749eb82c59b15d47a83e0b' then
    raise exception 'R64_HASH_DRIFT get_my_points_preview_rpc md5=%', md5(v_def);
  end if;
  v_new := replace(
    v_def,
$old$
  select rs.*
  into v_simulation
  from public.round_simulations rs
  where rs.league_round_id = p_league_round_id
    and rs.publishable = true
    and rs.status in ('preview_ready', 'awaiting_certification', 'certified')
  order by rs.simulation_version desc
  limit 1;
$old$,
$new$
  select rs.*
  into v_simulation
  from public.current_realtime_published_round_simulation_v rs
  where rs.league_round_id = p_league_round_id
  limit 1;  if not found and exists (
    select 1
    from public.league_rounds lr
    join public.fantagol_rounds fr
      on fr.id = lr.fantagol_round_id
    where lr.id = p_league_round_id
      and now() < coalesce(fr.lock_at, fr.starts_at, 'infinity'::timestamptz)
  ) then
    select rs.*
    into v_simulation
    from public.round_simulations rs
    where rs.league_round_id = p_league_round_id
      and rs.publishable = true
      and rs.status in ('preview_ready', 'awaiting_certification', 'certified')
    order by rs.simulation_version desc
    limit 1;
  end if;
$new$
  );
  if v_new = v_def then raise exception 'R64_REWRITE_MISS get_my_points_preview_rpc'; end if;
  execute v_new;

  -- get_my_fantacalcio_preview_rpc
  select pg_get_functiondef('public.get_my_fantacalcio_preview_rpc(uuid)'::regprocedure)
  into v_def;
  if md5(v_def) <> '53a739f18b031be9b7eecc75f7f8ef44' then
    raise exception 'R64_HASH_DRIFT get_my_fantacalcio_preview_rpc md5=%', md5(v_def);
  end if;
  v_new := replace(
    v_def,
    'v_simulation public.latest_round_simulation_v%rowtype;',
    'v_simulation public.round_simulations%rowtype;'
  );
  if v_new = v_def then raise exception 'R64_REWRITE_MISS fantacalcio rowtype'; end if;
  v_def := v_new;
  v_new := replace(
    v_def,
$old$
  select lrs.*
  into v_simulation
  from public.latest_round_simulation_v lrs
  where lrs.league_round_id = p_league_round_id
    and lrs.digital_twin ? 'fantacalcio_preview'
  limit 1;
$old$,
$new$
  select rs.*
  into v_simulation
  from public.current_realtime_published_round_simulation_v rs
  where rs.league_round_id = p_league_round_id
    and rs.digital_twin ? 'fantacalcio_preview'
  limit 1;  if not found and exists (
    select 1
    from public.league_rounds lr
    join public.fantagol_rounds fr
      on fr.id = lr.fantagol_round_id
    where lr.id = p_league_round_id
      and now() < coalesce(fr.lock_at, fr.starts_at, 'infinity'::timestamptz)
  ) then
    select rs.*
    into v_simulation
    from public.round_simulations rs
    where rs.league_round_id = p_league_round_id
      and rs.publishable = true
      and rs.status in ('preview_ready', 'awaiting_certification', 'certified')
      and rs.digital_twin ? 'fantacalcio_preview'
    order by rs.simulation_version desc
    limit 1;
  end if;
$new$
  );
  if v_new = v_def then raise exception 'R64_REWRITE_MISS get_my_fantacalcio_preview_rpc'; end if;
  v_def := replace(v_new, 'v_simulation.simulation_id,', 'v_simulation.id,');
  if v_def = v_new then raise exception 'R64_REWRITE_MISS fantacalcio simulation_id'; end if;
  execute v_def;

  -- get_my_one_to_one_preview_rpc
  select pg_get_functiondef('public.get_my_one_to_one_preview_rpc(uuid)'::regprocedure)
  into v_def;
  if md5(v_def) <> '602e95309b704164d7a98e88c87d1ebf' then
    raise exception 'R64_HASH_DRIFT get_my_one_to_one_preview_rpc md5=%', md5(v_def);
  end if;
  v_new := replace(
    v_def,
$old$
  select rs.*
  into v_simulation
  from public.round_simulations rs
  where rs.league_round_id = p_league_round_id
    and rs.status in ('preview_ready', 'awaiting_certification', 'certified')
    and rs.digital_twin ? 'one_to_one_preview'
  order by rs.simulation_version desc
  limit 1;
$old$,
$new$
  select rs.*
  into v_simulation
  from public.current_realtime_published_round_simulation_v rs
  where rs.league_round_id = p_league_round_id
    and rs.digital_twin ? 'one_to_one_preview'
  limit 1;  if not found and exists (
    select 1
    from public.league_rounds lr
    join public.fantagol_rounds fr
      on fr.id = lr.fantagol_round_id
    where lr.id = p_league_round_id
      and now() < coalesce(fr.lock_at, fr.starts_at, 'infinity'::timestamptz)
  ) then
    select rs.*
    into v_simulation
    from public.round_simulations rs
    where rs.league_round_id = p_league_round_id
      and rs.status in ('preview_ready', 'awaiting_certification', 'certified')
      and rs.digital_twin ? 'one_to_one_preview'
    order by rs.simulation_version desc
    limit 1;
  end if;
$new$
  );
  if v_new = v_def then raise exception 'R64_REWRITE_MISS get_my_one_to_one_preview_rpc'; end if;
  execute v_new;

  -- get_my_standings_preview_rpc
  select pg_get_functiondef('public.get_my_standings_preview_rpc(uuid)'::regprocedure)
  into v_def;
  if md5(v_def) <> 'c3ed8f106565fa42986b0010fce11ac4' then
    raise exception 'R64_HASH_DRIFT get_my_standings_preview_rpc md5=%', md5(v_def);
  end if;
  v_new := replace(
    v_def,
$old$
  select rs.*
  into v_simulation
  from public.round_simulations rs
  where rs.league_round_id = p_league_round_id
    and rs.status in (
      'preview_ready',
      'awaiting_certification',
      'certified'
    )
    and rs.digital_twin ? 'standings_preview'
  order by
    rs.publishable desc,
    rs.simulation_version desc
  limit 1;
$old$,
$new$
  select rs.*
  into v_simulation
  from public.current_realtime_published_round_simulation_v rs
  where rs.league_round_id = p_league_round_id
    and rs.digital_twin ? 'standings_preview'
  limit 1;  if not found and exists (
    select 1
    from public.league_rounds lr
    join public.fantagol_rounds fr
      on fr.id = lr.fantagol_round_id
    where lr.id = p_league_round_id
      and now() < coalesce(fr.lock_at, fr.starts_at, 'infinity'::timestamptz)
  ) then
    select rs.*
    into v_simulation
    from public.round_simulations rs
    where rs.league_round_id = p_league_round_id
      and rs.status in (
        'preview_ready',
        'awaiting_certification',
        'certified'
      )
      and rs.digital_twin ? 'standings_preview'
    order by
      rs.publishable desc,
      rs.simulation_version desc
    limit 1;
  end if;
$new$
  );
  if v_new = v_def then raise exception 'R64_REWRITE_MISS get_my_standings_preview_rpc'; end if;
  execute v_new;

  -- get_my_ui_snapshot_rpc
  select pg_get_functiondef('public.get_my_ui_snapshot_rpc(uuid)'::regprocedure)
  into v_def;
  if md5(v_def) <> '96fe0ddf8627d258ee64da566277cd0a' then
    raise exception 'R64_HASH_DRIFT get_my_ui_snapshot_rpc md5=%', md5(v_def);
  end if;
  v_new := replace(
    v_def,
$old$
  select rs.*
  into v_simulation
  from public.round_simulations rs
  where rs.league_round_id = p_league_round_id
    and rs.status in (
      'preview_ready',
      'awaiting_certification',
      'certified'
    )
    and rs.digital_twin ? 'ui_snapshot'
  order by
    rs.publishable desc,
    rs.simulation_version desc
  limit 1;
$old$,
$new$
  select rs.*
  into v_simulation
  from public.current_realtime_published_round_simulation_v rs
  where rs.league_round_id = p_league_round_id
    and rs.digital_twin ? 'ui_snapshot'
  limit 1;  if not found and exists (
    select 1
    from public.league_rounds lr
    join public.fantagol_rounds fr
      on fr.id = lr.fantagol_round_id
    where lr.id = p_league_round_id
      and now() < coalesce(fr.lock_at, fr.starts_at, 'infinity'::timestamptz)
  ) then
    select rs.*
    into v_simulation
    from public.round_simulations rs
    where rs.league_round_id = p_league_round_id
      and rs.status in (
        'preview_ready',
        'awaiting_certification',
        'certified'
      )
      and rs.digital_twin ? 'ui_snapshot'
    order by
      rs.publishable desc,
      rs.simulation_version desc
    limit 1;
  end if;
$new$
  );
  if v_new = v_def then raise exception 'R64_REWRITE_MISS get_my_ui_snapshot_rpc'; end if;
  execute v_new;

  -- get_league_live_frontend_projection_rpc
  select pg_get_functiondef('public.get_league_live_frontend_projection_rpc(uuid)'::regprocedure)
  into v_def;
  if md5(v_def) <> 'c9c40d2343be8684381eba19f328a3ef' then
    raise exception 'R64_HASH_DRIFT get_league_live_frontend_projection_rpc md5=%', md5(v_def);
  end if;
  v_new := replace(
    v_def,
$old$
    select rs.*
    into v_simulation
    from public.round_simulations rs
    where rs.league_round_id = p_league_round_id
      and rs.publishable = true
      and rs.status in (
          'preview_ready',
          'awaiting_certification',
          'certified'
      )
      and rs.digital_twin ? 'points_preview'
      and rs.digital_twin ? 'fantacalcio_preview'
      and rs.digital_twin ? 'one_to_one_preview'
      and rs.digital_twin ? 'standings_preview'
      and rs.digital_twin ? 'ui_snapshot'
    order by
        rs.simulation_version desc,
        rs.created_at desc
    limit 1;
$old$,
$new$
    select rs.*
    into v_simulation
    from public.current_realtime_published_round_simulation_v rs
    where rs.league_round_id = p_league_round_id
      and rs.digital_twin ? 'points_preview'
      and rs.digital_twin ? 'fantacalcio_preview'
      and rs.digital_twin ? 'one_to_one_preview'
      and rs.digital_twin ? 'standings_preview'
      and rs.digital_twin ? 'ui_snapshot'
    limit 1;
$new$
  );
  if v_new = v_def then raise exception 'R64_REWRITE_MISS get_league_live_frontend_projection_rpc'; end if;
  execute v_new;
end
$r64$;

comment on function public.get_my_points_preview_rpc(uuid) is
'Returns Points from the canonical realtime publication from LIVE lock onward; preserves pre-LIVE preview fallback.';
comment on function public.get_my_fantacalcio_preview_rpc(uuid) is
'Returns Fantacalcio from the canonical realtime publication from LIVE lock onward; preserves pre-LIVE preview fallback.';
comment on function public.get_my_one_to_one_preview_rpc(uuid) is
'Returns One-to-One from the canonical realtime publication from LIVE lock onward; preserves pre-LIVE preview fallback.';
comment on function public.get_my_standings_preview_rpc(uuid) is
'Returns standings from realtime publication from LIVE lock onward, preserving pre-LIVE candidate fallback and zero bootstrap behavior.';
comment on function public.get_my_ui_snapshot_rpc(uuid) is
'Returns UI snapshot from realtime publication from LIVE lock onward; preserves pre-LIVE preview fallback.';
comment on function public.get_league_live_frontend_projection_rpc(uuid) is
'Returns the league frontend projection from the canonical realtime published round simulation.';