-- ============================================================
-- FANTAGOL
-- Migration 058
-- League Permanent Deletion
-- Strategy Version Cascade Ordering Hotfix
-- ============================================================

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
  v_strategy_versions_count bigint := 0;
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

  select count(*)
  into v_strategy_versions_count
  from public.strategy_versions sv
  join public.strategies s
    on s.id = sv.strategy_id
  where s.league_id = p_league_id;

  update public.profiles
  set last_active_league_id = null
  where last_active_league_id = p_league_id;

  /*
   * Strategy versions reference league members through
   * changed_by_member_id with ON DELETE SET NULL.
   *
   * Deleting league_members first would therefore issue an UPDATE
   * against the immutable strategy_versions table.
   *
   * Remove the versions explicitly before the league cascade.
   */
  perform set_config(
    'fantagol.allow_strategy_version_delete',
    'on',
    true
  );

  delete from public.strategy_versions sv
  using public.strategies s
  where sv.strategy_id = s.id
    and s.league_id = p_league_id;

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
    'strategies_removed', v_strategies_count,
    'strategy_versions_removed', v_strategy_versions_count
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
'Permanently deletes a league and its dependent graph. Strategy versions are removed before league members to avoid immutable-history UPDATEs caused by changed_by_member_id ON DELETE SET NULL.';
