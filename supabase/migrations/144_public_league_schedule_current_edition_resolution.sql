begin;

-- ============================================================================
-- FANTAGOL
-- MIGRATION 143
-- PUBLIC LEAGUE SCHEDULE CURRENT EDITION RESOLUTION
-- ============================================================================

create or replace function public.resolve_public_league_schedule_rpc(
  target_edition_id uuid default null,
  reference_at timestamptz default now()
)
returns table(
  starts_from_fantagol_round_id uuid,
  starts_from_round_sequence integer,
  starts_from_round_name text,
  first_useful_kickoff_at timestamptz,
  automatic_join_close_at timestamptz,
  inactivity_evaluation_round_id uuid,
  inactivity_evaluation_at timestamptz,
  schedule_version integer
)
language plpgsql
stable
security definer
set search_path to public
as $function$
declare
  v_edition_id uuid;
begin
  if auth.uid() is null then
    raise exception using
      errcode = 'P0001',
      message = 'AUTH_REQUIRED';
  end if;

  v_edition_id := target_edition_id;

  if v_edition_id is null then
    select ce.id
    into v_edition_id
    from public.competition_editions ce
    join public.competitions c
      on c.id = ce.competition_id
    where ce.active = true
      and ce.status in ('scheduled', 'active')
      and c.enabled = true
    order by
      case ce.status
        when 'active' then 0
        else 1
      end,
      ce.starts_at,
      ce.created_at,
      ce.id
    limit 1;
  end if;

  if v_edition_id is null then
    raise exception using
      errcode = 'P0001',
      message = 'NO_ACTIVE_COMPETITION_EDITION';
  end if;

  return query
  select *
  from public.resolve_public_league_schedule_internal(
    v_edition_id,
    coalesce(reference_at, now())
  );
end;
$function$;

comment on function public.resolve_public_league_schedule_rpc(uuid, timestamptz)
is
  'Returns the backend-authoritative public league schedule preview. When target_edition_id is null, the current active or scheduled enabled competition edition is resolved automatically.';

revoke all
on function public.resolve_public_league_schedule_rpc(uuid, timestamptz)
from public;

revoke all
on function public.resolve_public_league_schedule_rpc(uuid, timestamptz)
from anon;

grant execute
on function public.resolve_public_league_schedule_rpc(uuid, timestamptz)
to authenticated;

grant execute
on function public.resolve_public_league_schedule_rpc(uuid, timestamptz)
to service_role;

do $verification$
declare
  v_argument_defaults_count integer;
  v_function_arguments text;
begin
  select
    p.pronargdefaults,
    pg_get_function_arguments(p.oid)
  into
    v_argument_defaults_count,
    v_function_arguments
  from pg_proc p
  join pg_namespace n
    on n.oid = p.pronamespace
  where n.nspname = 'public'
    and p.proname = 'resolve_public_league_schedule_rpc'
    and p.proargtypes = '2950 1184'::oidvector;

  if not found then
    raise exception
      'PUBLIC_LEAGUE_SCHEDULE_RPC_SIGNATURE_MISSING';
  end if;

  if v_argument_defaults_count <> 2 then
    raise exception
      'PUBLIC_LEAGUE_SCHEDULE_RPC_DEFAULT_ARGUMENT_COUNT_INVALID: %',
      v_argument_defaults_count;
  end if;

  if position(
    'target_edition_id uuid DEFAULT NULL::uuid'
    in v_function_arguments
  ) = 0 then
    raise exception
      'PUBLIC_LEAGUE_SCHEDULE_RPC_TARGET_EDITION_DEFAULT_MISSING: %',
      v_function_arguments;
  end if;

  if position(
    'reference_at timestamp with time zone DEFAULT now()'
    in v_function_arguments
  ) = 0 then
    raise exception
      'PUBLIC_LEAGUE_SCHEDULE_RPC_REFERENCE_DEFAULT_MISSING: %',
      v_function_arguments;
  end if;

  if not has_function_privilege(
    'authenticated',
    'public.resolve_public_league_schedule_rpc(uuid,timestamp with time zone)',
    'EXECUTE'
  ) then
    raise exception
      'PUBLIC_LEAGUE_SCHEDULE_RPC_AUTHENTICATED_GRANT_MISSING';
  end if;

  if has_function_privilege(
    'anon',
    'public.resolve_public_league_schedule_rpc(uuid,timestamp with time zone)',
    'EXECUTE'
  ) then
    raise exception
      'PUBLIC_LEAGUE_SCHEDULE_RPC_ANON_EXECUTE_NOT_REVOKED';
  end if;

  raise notice
    'PUBLIC_LEAGUE_SCHEDULE_CURRENT_EDITION_RESOLUTION_OK';
end;
$verification$;

commit;