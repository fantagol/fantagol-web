-- ============================================================================
-- FANTAGOL
-- Migration 255: Official Standings Read Contract
--
-- Separate official standings from LIVE / Digital Twin preview standings.
--
-- Authority:
--   round_certifications.status = 'official'
--   round_certifications.active = true
--
-- Current provisional simulations are never exposed by this RPC.
-- Before the first official certification, return canonical zero standings.
-- ============================================================================

begin;

create or replace function public.get_my_official_standings_rpc(
  p_league_id uuid
)
returns table (
  league_id uuid,
  league_round_id uuid,
  league_round_number integer,
  certification_id uuid,
  certification_version integer,
  certification_status text,
  committed_at timestamptz,
  standings_snapshot jsonb,
  bootstrap boolean
)
language plpgsql
stable
security definer
set search_path to public, pg_temp
as $function$
declare
  v_user_id uuid;
  v_member_id uuid;

  /*
   * Single RECORD authority.
   *
   * Do not mix scalar INTO targets with a %ROWTYPE composite.
   */
  v_official record;

  v_bootstrap_round_id uuid;
  v_bootstrap jsonb;
begin
  if p_league_id is null then
    raise exception using
      errcode = 'P0001',
      message = 'LEAGUE_REQUIRED';
  end if;

  v_user_id := auth.uid();

  if v_user_id is null then
    raise exception using
      errcode = 'P0001',
      message = 'AUTHENTICATION_REQUIRED';
  end if;

  select lm.id
  into v_member_id
  from public.league_members lm
  where lm.league_id = p_league_id
    and lm.user_id = v_user_id
    and lm.status = 'active'
  limit 1;

  if v_member_id is null then
    raise exception using
      errcode = 'P0001',
      message = 'ACTIVE_LEAGUE_MEMBERSHIP_REQUIRED';
  end if;

  /*
   * Latest immutable official certification only.
   *
   * A newer preview_ready / awaiting_certification simulation
   * cannot influence this selector.
   */
  select
    lr.id as league_round_id,
    lr.league_round_number,
    rc.id as certification_id,
    rc.certification_version,
    rc.status as certification_status,
    rc.committed_at,
    rc.standings_snapshot
  into v_official
  from public.round_certifications rc
  join public.league_rounds lr
    on lr.id = rc.league_round_id
  where lr.league_id = p_league_id
    and rc.status = 'official'
    and rc.active = true
  order by
    lr.league_round_number desc,
    rc.certification_version desc
  limit 1;

  if v_official.certification_id is not null then
    return query
    select
      p_league_id,
      v_official.league_round_id::uuid,
      v_official.league_round_number::integer,
      v_official.certification_id::uuid,
      v_official.certification_version::integer,
      v_official.certification_status::text,
      v_official.committed_at::timestamptz,
      v_official.standings_snapshot::jsonb,
      false;

    return;
  end if;

  /*
   * No certification exists yet.
   * Use the canonical zero standings builder only for bootstrap.
   */
  select lr.id
  into v_bootstrap_round_id
  from public.league_rounds lr
  where lr.league_id = p_league_id
    and lr.enabled = true
  order by lr.league_round_number asc
  limit 1;

  if v_bootstrap_round_id is null then
    raise exception using
      errcode = 'P0001',
      message = 'LEAGUE_ROUND_NOT_FOUND';
  end if;

  v_bootstrap :=
    public.build_zero_standings_preview_internal(
      v_bootstrap_round_id
    );

  return query
  select
    p_league_id,
    null::uuid,
    null::integer,
    null::uuid,
    null::integer,
    'bootstrap'::text,
    null::timestamptz,
    v_bootstrap,
    true;
end;
$function$;

revoke all
on function public.get_my_official_standings_rpc(uuid)
from public, anon;

grant execute
on function public.get_my_official_standings_rpc(uuid)
to authenticated, service_role;

comment on function public.get_my_official_standings_rpc(uuid)
is
'Returns standings exclusively from the latest active official Round Certification visible to the authenticated league member. LIVE and provisional Round Simulations are excluded. Before the first certification, returns canonical zero standings.';

commit;