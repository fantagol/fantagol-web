begin;

do $$
declare
  v_canonical_args text;
  v_wrapper_args text;
begin
  select
    pg_get_function_arguments(p.oid)
  into v_canonical_args
  from pg_proc p
  join pg_namespace n
    on n.oid = p.pronamespace
  where n.nspname = 'public'
    and p.proname =
      'get_my_dashboard_matchups_rpc'
    and pg_get_function_identity_arguments(p.oid)
      like '%uuid%'
  order by p.oid desc
  limit 1;

  if v_canonical_args is null then
    raise exception
      'R43_CANONICAL_DASHBOARD_RPC_MISSING';
  end if;

  if v_canonical_args not ilike
       '%p_league_round_id uuid%'
  then
    raise exception
      'R43_CANONICAL_ARGUMENT_UNEXPECTED: %',
      v_canonical_args;
  end if;

  select
    pg_get_function_arguments(p.oid)
  into v_wrapper_args
  from pg_proc p
  join pg_namespace n
    on n.oid = p.pronamespace
  where n.nspname = 'public'
    and p.proname =
      'get_my_dashboard_matchups_live_rpc'
    and pg_get_function_identity_arguments(p.oid)
      like '%uuid%'
  order by p.oid desc
  limit 1;

  if v_wrapper_args is null then
    raise exception
      'R43_LIVE_DASHBOARD_WRAPPER_MISSING';
  end if;
end
$$;


/*
 * PostgreSQL does not permit renaming an input argument through
 * CREATE OR REPLACE when the identity signature is unchanged.
 *
 * Therefore the faulty wrapper is dropped and immediately
 * recreated with the canonical PostgREST argument name.
 */
drop function
if exists
public.get_my_dashboard_matchups_live_rpc(uuid);


create function
public.get_my_dashboard_matchups_live_rpc(
  p_league_round_id uuid
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_base jsonb;
begin
  if auth.uid() is null then
    raise exception 'AUTH_REQUIRED';
  end if;

  /*
   * Canonical RPC retains all membership,
   * visibility and matchup authority.
   */
  v_base :=
    public.get_my_dashboard_matchups_rpc(
      p_league_round_id
    );

  return
    public.decorate_dashboard_live_clock_internal(
      v_base
    );
end;
$$;


revoke all
on function
public.get_my_dashboard_matchups_live_rpc(uuid)
from public;


grant execute
on function
public.get_my_dashboard_matchups_live_rpc(uuid)
to authenticated;


/*
 * Ask PostgREST/Supabase to refresh named argument metadata.
 */
notify pgrst, 'reload schema';

commit;