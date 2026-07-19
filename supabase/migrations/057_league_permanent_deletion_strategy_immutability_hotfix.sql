-- ============================================================
-- FANTAGOL
-- Migration 057
-- League Permanent Deletion
-- Strategy Version Immutability Hotfix
-- ============================================================

create or replace function public.protect_strategy_version_immutability()
returns trigger
language plpgsql
security definer
set search_path = public
as $function$
begin
  if tg_op = 'DELETE'
     and current_setting(
       'fantagol.allow_strategy_version_delete',
       true
     ) = 'on'
  then
    return old;
  end if;

  raise exception using
    errcode = 'P0001',
    message = 'STRATEGY_VERSION_IMMUTABLE';
end;
$function$;

comment on function public.protect_strategy_version_immutability()
is
'Prevents UPDATE and DELETE of append-only Strategy version history. DELETE is permitted only inside the controlled permanent-league-deletion transaction.';


create or replace function public.delete_league_permanently_rpc(
  p_league_id uuid,
  p_confirmation_name text
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $function$
declare
  v_user_id uuid := auth.uid();
  v_league public.leagues%rowtype;
  v_admin_member_id uuid;

  v_members_count bigint := 0;
  v_rounds_count bigint := 0;
  v_fixtures_count bigint := 0;
  v_predictions_count bigint := 0;
  v_strategies_count bigint := 0;
begin
  if v_user_id is null then
    raise exception using
      errcode = 'P0001',
      message = 'AUTH_REQUIRED';
  end if;

  select *
  into v_league
  from public.leagues
  where id = p_league_id
  for update;

  if not found then
    raise exception using
      errcode = 'P0001',
      message = 'LEAGUE_NOT_FOUND';
  end if;

  v_admin_member_id :=
    public.get_active_admin_member_id(
      p_league_id,
      v_user_id
    );

  if v_admin_member_id is null then
    raise exception using
      errcode = 'P0001',
      message = 'ACTIVE_ADMIN_REQUIRED';
  end if;

  if p_confirmation_name is null
     or btrim(p_confirmation_name) <> v_league.name
  then
    raise exception using
      errcode = 'P0001',
      message = 'LEAGUE_NAME_CONFIRMATION_MISMATCH';
  end if;

  select count(*)
  into v_members_count
  from public.league_members
  where league_id = p_league_id;

  select count(*)
  into v_rounds_count
  from public.league_rounds
  where league_id = p_league_id;

  select count(*)
  into v_fixtures_count
  from public.league_fixtures
  where league_id = p_league_id;

  select count(*)
  into v_predictions_count
  from public.predictions
  where league_id = p_league_id;

  select count(*)
  into v_strategies_count
  from public.strategies
  where league_id = p_league_id;

  update public.profiles
  set last_active_league_id = null
  where last_active_league_id = p_league_id;

  perform set_config(
    'fantagol.allow_strategy_version_delete',
    'on',
    true
  );

  delete from public.leagues
  where id = p_league_id;

  if not found then
    raise exception using
      errcode = 'P0001',
      message = 'LEAGUE_DELETE_FAILED';
  end if;

  return jsonb_build_object(
    'deleted', true,
    'league_id', p_league_id,
    'league_name', v_league.name,
    'members_removed', v_members_count,
    'rounds_removed', v_rounds_count,
    'fixtures_removed', v_fixtures_count,
    'predictions_removed', v_predictions_count,
    'strategies_removed', v_strategies_count
  );
end;
$function$;

revoke all
on function public.delete_league_permanently_rpc(uuid, text)
from public;

revoke all
on function public.delete_league_permanently_rpc(uuid, text)
from anon;

revoke all
on function public.delete_league_permanently_rpc(uuid, text)
from service_role;

grant execute
on function public.delete_league_permanently_rpc(uuid, text)
to authenticated;

comment on function public.delete_league_permanently_rpc(uuid, text)
is
'Permanently deletes a league and cascade-dependent data. Requires authenticated active league admin and exact league-name confirmation. Enables strategy-version deletion only for the current transaction.';
