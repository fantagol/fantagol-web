-- FANTAGOL
-- Migration 191
-- Canonical League Display Name Read Contracts.
--
-- Mission:
-- propagate the display name chosen during league creation or membership join
-- to every active non-simulation presentation contract.
--
-- Canonical resolution:
--   1. league_member_profiles.display_name
--   2. league_members.display_name legacy fallback
--   3. Club FantaGol defensive fallback
--
-- This migration does not:
--   - modify competitive scores or rankings;
--   - rewrite simulations, snapshots or certifications;
--   - modify avatar, kit, motto or Hall of Fame semantics;
--   - modify frontend code;
--   - remove legacy columns.

create or replace function
public.resolve_league_member_display_name(
  target_league_member_id uuid
)
returns text
language sql
stable
security definer
set search_path = public, pg_temp
as $function$
  select coalesce(
    nullif(btrim(lmp.display_name), ''),
    nullif(btrim(lm.display_name), ''),
    'Club FantaGol'
  )::text
  from public.league_members lm
  left join public.league_member_profiles lmp
    on lmp.league_member_id = lm.id
  where lm.id = target_league_member_id;
$function$;

revoke all
on function public.resolve_league_member_display_name(uuid)
from public, anon, authenticated;

grant execute
on function public.resolve_league_member_display_name(uuid)
to authenticated, service_role;

comment on function
public.resolve_league_member_display_name(uuid) is
  'Resolves the canonical competitive display name for one League Member. League-scoped profile first, legacy membership fallback second.';

do $patch$
declare
  v_signature regprocedure;
  v_definition text;
  v_patched text;
  v_change_count integer;
begin
  ------------------------------------------------------------------
  -- get_my_leagues_rpc()
  ------------------------------------------------------------------

  v_signature := 'public.get_my_leagues_rpc()'::regprocedure;

  select pg_get_functiondef(v_signature)
  into v_definition;

  if v_definition ilike
     '%resolve_league_member_display_name(lm.id)%' then
    raise notice
      'CANONICAL_DISPLAY_NAME_CONTRACT_ALREADY_PRESENT=%',
      v_signature::text;
  else
    v_patched := replace(
      v_definition,
      'lm.display_name,',
      'public.resolve_league_member_display_name(lm.id),'
    );

    if v_patched = v_definition then
      raise exception
        'CANONICAL_PATCH_TARGET_NOT_FOUND: %',
        v_signature::text;
    end if;

    execute v_patched;

    raise notice
      'CANONICAL_DISPLAY_NAME_CONTRACT_PATCHED=%',
      v_signature::text;
  end if;

  ------------------------------------------------------------------
  -- get_current_league_members_rpc(uuid)
  ------------------------------------------------------------------

  v_signature :=
    'public.get_current_league_members_rpc(uuid)'::regprocedure;

  select pg_get_functiondef(v_signature)
  into v_definition;

  v_patched := v_definition;

  v_patched := replace(
    v_patched,
    'lm.display_name,',
    'public.resolve_league_member_display_name(lm.id),'
  );

  v_patched := replace(
    v_patched,
    'coalesce(c.name, lm.display_name, ''Club FantaGol'') as club_name',
    'public.resolve_league_member_display_name(lm.id) as club_name'
  );

  if v_patched = v_definition then
    if v_definition ilike
       '%resolve_league_member_display_name(lm.id)%' then
      raise notice
        'CANONICAL_DISPLAY_NAME_CONTRACT_ALREADY_PRESENT=%',
        v_signature::text;
    else
      raise exception
        'CANONICAL_PATCH_TARGET_NOT_FOUND: %',
        v_signature::text;
    end if;
  else
    execute v_patched;

    raise notice
      'CANONICAL_DISPLAY_NAME_CONTRACT_PATCHED=%',
      v_signature::text;
  end if;

  ------------------------------------------------------------------
  -- get_my_dashboard_matchups_rpc(uuid)
  ------------------------------------------------------------------

  v_signature :=
    'public.get_my_dashboard_matchups_rpc(uuid)'::regprocedure;

  select pg_get_functiondef(v_signature)
  into v_definition;

  v_patched := v_definition;

  v_patched := replace(
    v_patched,
    'hm.display_name as home_display_name',
    'public.resolve_league_member_display_name(hm.id) as home_display_name'
  );

  v_patched := replace(
    v_patched,
    'am.display_name as away_display_name',
    'public.resolve_league_member_display_name(am.id) as away_display_name'
  );

  v_patched := replace(
    v_patched,
    'then am.display_name',
    'then public.resolve_league_member_display_name(am.id)'
  );

  v_patched := replace(
    v_patched,
    'then hm.display_name',
    'then public.resolve_league_member_display_name(hm.id)'
  );

  if v_patched = v_definition then
    if v_definition ilike
       '%resolve_league_member_display_name(hm.id)%'
       and v_definition ilike
       '%resolve_league_member_display_name(am.id)%' then
      raise notice
        'CANONICAL_DISPLAY_NAME_CONTRACT_ALREADY_PRESENT=%',
        v_signature::text;
    else
      raise exception
        'CANONICAL_PATCH_TARGET_NOT_FOUND: %',
        v_signature::text;
    end if;
  else
    execute v_patched;

    raise notice
      'CANONICAL_DISPLAY_NAME_CONTRACT_PATCHED=%',
      v_signature::text;
  end if;

  ------------------------------------------------------------------
  -- get_my_league_context_rpc(uuid)
  ------------------------------------------------------------------

  v_signature :=
    'public.get_my_league_context_rpc(uuid)'::regprocedure;

  select pg_get_functiondef(v_signature)
  into v_definition;

  v_patched := replace(
    v_definition,
    'lm.display_name::text as display_name',
    'public.resolve_league_member_display_name(lm.id)::text as display_name'
  );

  if v_patched = v_definition then
    if v_definition ilike
       '%resolve_league_member_display_name(lm.id)%' then
      raise notice
        'CANONICAL_DISPLAY_NAME_CONTRACT_ALREADY_PRESENT=%',
        v_signature::text;
    else
      raise exception
        'CANONICAL_PATCH_TARGET_NOT_FOUND: %',
        v_signature::text;
    end if;
  else
    execute v_patched;

    raise notice
      'CANONICAL_DISPLAY_NAME_CONTRACT_PATCHED=%',
      v_signature::text;
  end if;

  ------------------------------------------------------------------
  -- get_public_league_context_rpc(uuid)
  ------------------------------------------------------------------

  v_signature :=
    'public.get_public_league_context_rpc(uuid)'::regprocedure;

  select pg_get_functiondef(v_signature)
  into v_definition;

  v_patched := v_definition;

  v_patched := replace(
    v_patched,
    '''display_name'', lm.display_name',
    '''display_name'', public.resolve_league_member_display_name(lm.id)'
  );

  v_patched := replace(
    v_patched,
    'lower(lm.display_name)',
    'lower(public.resolve_league_member_display_name(lm.id))'
  );

  if v_patched = v_definition then
    if v_definition ilike
       '%resolve_league_member_display_name(lm.id)%' then
      raise notice
        'CANONICAL_DISPLAY_NAME_CONTRACT_ALREADY_PRESENT=%',
        v_signature::text;
    else
      raise exception
        'CANONICAL_PATCH_TARGET_NOT_FOUND: %',
        v_signature::text;
    end if;
  else
    execute v_patched;

    raise notice
      'CANONICAL_DISPLAY_NAME_CONTRACT_PATCHED=%',
      v_signature::text;
  end if;

  ------------------------------------------------------------------
  -- get_league_member_statistics_rpc(uuid)
  ------------------------------------------------------------------

  v_signature :=
    'public.get_league_member_statistics_rpc(uuid)'::regprocedure;

  select pg_get_functiondef(v_signature)
  into v_definition;

  v_patched := replace(
    v_definition,
    'coalesce(c.name, lm.display_name, ''Club FantaGol'')::text',
    'public.resolve_league_member_display_name(lm.id)::text'
  );

  if v_patched = v_definition then
    if v_definition ilike
       '%resolve_league_member_display_name(lm.id)%' then
      raise notice
        'CANONICAL_DISPLAY_NAME_CONTRACT_ALREADY_PRESENT=%',
        v_signature::text;
    else
      raise exception
        'CANONICAL_PATCH_TARGET_NOT_FOUND: %',
        v_signature::text;
    end if;
  else
    execute v_patched;

    raise notice
      'CANONICAL_DISPLAY_NAME_CONTRACT_PATCHED=%',
      v_signature::text;
  end if;

  ------------------------------------------------------------------
  -- get_member_deep_statistics_rpc(uuid,uuid)
  ------------------------------------------------------------------

  v_signature :=
    'public.get_member_deep_statistics_rpc(uuid,uuid)'::regprocedure;

  select pg_get_functiondef(v_signature)
  into v_definition;

  v_patched := replace(
    v_definition,
    'coalesce(c.name,lm.display_name,''Club FantaGol'')::text as club_name',
    'public.resolve_league_member_display_name(lm.id)::text as club_name'
  );

  if v_patched = v_definition then
    if v_definition ilike
       '%resolve_league_member_display_name(lm.id)%' then
      raise notice
        'CANONICAL_DISPLAY_NAME_CONTRACT_ALREADY_PRESENT=%',
        v_signature::text;
    else
      raise exception
        'CANONICAL_PATCH_TARGET_NOT_FOUND: %',
        v_signature::text;
    end if;
  else
    execute v_patched;

    raise notice
      'CANONICAL_DISPLAY_NAME_CONTRACT_PATCHED=%',
      v_signature::text;
  end if;

  ------------------------------------------------------------------
  -- get_my_archived_leagues_rpc()
  ------------------------------------------------------------------

  v_signature :=
    'public.get_my_archived_leagues_rpc()'::regprocedure;

  select pg_get_functiondef(v_signature)
  into v_definition;

  v_patched := replace(
    v_definition,
    'lm.display_name::text as display_name',
    'public.resolve_league_member_display_name(lm.id)::text as display_name'
  );

  if v_patched = v_definition then
    if v_definition ilike
       '%resolve_league_member_display_name(lm.id)%' then
      raise notice
        'CANONICAL_DISPLAY_NAME_CONTRACT_ALREADY_PRESENT=%',
        v_signature::text;
    else
      raise exception
        'CANONICAL_PATCH_TARGET_NOT_FOUND: %',
        v_signature::text;
    end if;
  else
    execute v_patched;

    raise notice
      'CANONICAL_DISPLAY_NAME_CONTRACT_PATCHED=%',
      v_signature::text;
  end if;

  ------------------------------------------------------------------
  -- get_league_admin_events_rpc(uuid,integer)
  ------------------------------------------------------------------

  v_signature :=
    'public.get_league_admin_events_rpc(uuid,integer)'::regprocedure;

  select pg_get_functiondef(v_signature)
  into v_definition;

  v_patched := v_definition;

  v_patched := replace(
    v_patched,
    'actor.display_name,',
    'public.resolve_league_member_display_name(actor.id),'
  );

  v_patched := replace(
    v_patched,
    'target.display_name,',
    'public.resolve_league_member_display_name(target.id),'
  );

  if v_patched = v_definition then
    if v_definition ilike
       '%resolve_league_member_display_name(actor.id)%'
       and v_definition ilike
       '%resolve_league_member_display_name(target.id)%' then
      raise notice
        'CANONICAL_DISPLAY_NAME_CONTRACT_ALREADY_PRESENT=%',
        v_signature::text;
    else
      raise exception
        'CANONICAL_PATCH_TARGET_NOT_FOUND: %',
        v_signature::text;
    end if;
  else
    execute v_patched;

    raise notice
      'CANONICAL_DISPLAY_NAME_CONTRACT_PATCHED=%',
      v_signature::text;
  end if;

  ------------------------------------------------------------------
  -- build_zero_standings_preview_internal(uuid)
  --
  -- This function projects the canonical name once inside each
  -- active_members CTE. Downstream alias am must continue reading
  -- am.display_name because am has league_member_id, not id.
  ------------------------------------------------------------------

  v_signature :=
    'public.build_zero_standings_preview_internal(uuid)'::regprocedure;

  select pg_get_functiondef(v_signature)
  into v_definition;

  v_patched := v_definition;

  -- Repair the previously deployed invalid automatic substitution.
  v_patched := replace(
    v_patched,
    'public.resolve_league_member_display_name(am.id)',
    'am.display_name'
  );

  -- Canonicalize only the source projection in each active_members CTE.
  v_patched := regexp_replace(
    v_patched,
    'coalesce\([[:space:]]*nullif\(btrim\(c\.name\),[[:space:]]*''''\),[[:space:]]*nullif\(btrim\(lm\.display_name\),[[:space:]]*''''\),[[:space:]]*''Club FantaGol''[[:space:]]*\)::text as display_name',
    'public.resolve_league_member_display_name(lm.id)::text as display_name',
    'gi'
  );

  if v_patched = v_definition then
    if v_definition ilike
       '%resolve_league_member_display_name(lm.id)::text as display_name%'
       and v_definition not ilike
       '%resolve_league_member_display_name(am.id)%' then
      raise notice
        'CANONICAL_DISPLAY_NAME_CONTRACT_ALREADY_PRESENT=%',
        v_signature::text;
    else
      raise exception
        'CANONICAL_PATCH_TARGET_NOT_FOUND: %',
        v_signature::text;
    end if;
  else
    execute v_patched;

    raise notice
      'CANONICAL_DISPLAY_NAME_CONTRACT_PATCHED=%',
      v_signature::text;
  end if;
end;
$patch$;

-- Public league catalog is a view, so it is replaced explicitly while
-- preserving the existing column order and contract.
create or replace view public.public_league_catalog_v1 as
select
  l.id as league_id,
  l.name as league_name,
  l.edition_id,

  coalesce(
    nullif(to_jsonb(ce.*) ->> 'label', ''),
    nullif(to_jsonb(ce.*) ->> 'name', ''),
    ce.id::text
  ) as edition_label,

  l.owner_id as admin_user_id,
  admin_member.display_name as admin_display_name,

  coalesce(
    member_counts.active_member_count,
    0
  ) as active_member_count,

  l.roster_status,

  case
    when l.first_scored_at is not null
      or (
        start_round.lock_at is not null
        and clock_timestamp() >= start_round.lock_at
      )
      then 'started'

    when coalesce(
      member_counts.active_member_count,
      0
    ) >= l.max_participants
      then 'full'

    when l.public_registrations_open = false
      or l.roster_status <> 'open'
      or l.lifecycle_status not in ('draft', 'open')
      then 'closed'

    else 'open'
  end as join_status,

  l.visibility,
  l.starts_from_fantagol_round_id,
  start_round.name as starts_from_round_name,
  start_round.sequence as starts_from_round_sequence,
  l.first_useful_kickoff_at,
  l.automatic_join_close_at,
  l.lifecycle_status,
  l.status as league_status,
  l.created_at,
  l.max_participants,
  l.public_registrations_open,

  greatest(
    l.max_participants -
      coalesce(
        member_counts.active_member_count,
        0
      ),
    0
  ) as available_slots,

  (
    l.first_scored_at is not null
    or (
      start_round.lock_at is not null
      and clock_timestamp() >= start_round.lock_at
    )
  ) as competition_started

from public.leagues l

join public.competition_editions ce
  on ce.id = l.edition_id

left join public.fantagol_rounds start_round
  on start_round.id =
    l.starts_from_fantagol_round_id

left join lateral (
  select
    public.resolve_league_member_display_name(
      lm.id
    ) as display_name
  from public.league_members lm
  where lm.league_id = l.id
    and lm.role = 'admin'
    and lm.status = 'active'
  order by lm.id
  limit 1
) admin_member
  on true

left join lateral (
  select
    count(*)::integer as active_member_count
  from public.league_members lm
  where lm.league_id = l.id
    and lm.status = 'active'
) member_counts
  on true

where l.visibility = 'public'
  and l.status = 'active'
  and l.lifecycle_status <> 'archived'
  and ce.active = true
  and ce.status in ('scheduled', 'active');

comment on view public.public_league_catalog_v1 is
  'Public league catalog with canonical league-scoped administrator display names.';

do $certification$
declare
  v_missing_profiles bigint;
  v_parity_failures bigint;
  v_unpatched_contracts text[];
begin
  select count(*)
  into v_missing_profiles
  from public.league_members lm
  left join public.league_member_profiles lmp
    on lmp.league_member_id = lm.id
  where lmp.id is null;

  if v_missing_profiles <> 0 then
    raise exception using
      errcode = 'P0001',
      message =
        'CANONICAL_DISPLAY_NAME_MISSING_PROFILES',
      detail =
        jsonb_build_object(
          'missing_profile_count',
          v_missing_profiles
        )::text;
  end if;

  select count(*)
  into v_parity_failures
  from public.league_members lm
  join public.league_member_profiles lmp
    on lmp.league_member_id = lm.id
  where public.resolve_league_member_display_name(
    lm.id
  ) is distinct from coalesce(
    nullif(btrim(lmp.display_name), ''),
    nullif(btrim(lm.display_name), ''),
    'Club FantaGol'
  );

  if v_parity_failures <> 0 then
    raise exception using
      errcode = 'P0001',
      message =
        'CANONICAL_DISPLAY_NAME_RESOLVER_PARITY_FAILED',
      detail =
        jsonb_build_object(
          'parity_failure_count',
          v_parity_failures
        )::text;
  end if;

  select array_agg(
    p.oid::regprocedure::text
    order by p.oid::regprocedure::text
  )
  into v_unpatched_contracts
  from pg_proc p
  join pg_namespace n
    on n.oid = p.pronamespace
  where n.nspname = 'public'
    and p.oid::regprocedure = any(
      array[
        'public.get_my_leagues_rpc()'::regprocedure,
        'public.get_current_league_members_rpc(uuid)'::regprocedure,
        'public.get_my_dashboard_matchups_rpc(uuid)'::regprocedure,
        'public.get_my_league_context_rpc(uuid)'::regprocedure,
        'public.get_public_league_context_rpc(uuid)'::regprocedure,
        'public.get_league_member_statistics_rpc(uuid)'::regprocedure,
        'public.get_member_deep_statistics_rpc(uuid,uuid)'::regprocedure,
        'public.get_my_archived_leagues_rpc()'::regprocedure,
        'public.get_league_admin_events_rpc(uuid,integer)'::regprocedure,
        'public.build_zero_standings_preview_internal(uuid)'::regprocedure
      ]
    )
    and pg_get_functiondef(p.oid) not ilike
      '%resolve_league_member_display_name%';

  if v_unpatched_contracts is not null then
    raise exception using
      errcode = 'P0001',
      message =
        'CANONICAL_DISPLAY_NAME_UNPATCHED_CONTRACTS',
      detail =
        jsonb_build_object(
          'functions',
          v_unpatched_contracts
        )::text;
  end if;

  if pg_get_viewdef(
    'public.public_league_catalog_v1'::regclass,
    true
  ) not ilike '%resolve_league_member_display_name%' then
    raise exception using
      errcode = 'P0001',
      message =
        'CANONICAL_DISPLAY_NAME_PUBLIC_CATALOG_NOT_PATCHED';
  end if;
end;
$certification$;

select
  case
    when to_regprocedure(
      'public.resolve_league_member_display_name(uuid)'
    ) is not null
     and not exists (
       select 1
       from public.league_members lm
       left join public.league_member_profiles lmp
         on lmp.league_member_id = lm.id
       where lmp.id is null
     )
     and pg_get_viewdef(
       'public.public_league_catalog_v1'::regclass,
       true
     ) ilike '%resolve_league_member_display_name%'
      then 'PASS'
    else 'FAIL'
  end as canonical_league_display_name_read_contracts_certification;
