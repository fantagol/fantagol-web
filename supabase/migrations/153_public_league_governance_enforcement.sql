begin;

create or replace function public.remove_league_member_rpc(
  target_league_id uuid,
  target_member_id uuid,
  removal_reason text default null
)
returns void
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_user_id uuid := auth.uid();
  v_admin_member_id uuid;
  v_target public.league_members%rowtype;
  v_league_visibility text;
begin
  if v_user_id is null then
    raise exception using
      errcode = 'P0001',
      message = 'AUTH_REQUIRED';
  end if;

  v_admin_member_id :=
    public.get_active_admin_member_id(
      target_league_id,
      v_user_id
    );

  if v_admin_member_id is null then
    raise exception using
      errcode = 'P0001',
      message = 'ACTIVE_ADMIN_REQUIRED';
  end if;

  select l.visibility
  into v_league_visibility
  from public.leagues l
  where l.id = target_league_id
  for update;

  if not found then
    raise exception using
      errcode = 'P0001',
      message = 'LEAGUE_NOT_FOUND';
  end if;

  /*
   * Public league governance contract:
   *
   * A public-league administrator never has discretionary authority to remove
   * a participant. Any future removal for objective and system-certified
   * conditions must be performed through a dedicated system-only contract.
   */
  if v_league_visibility = 'public' then
    raise exception using
      errcode = 'P0001',
      message = 'PUBLIC_LEAGUE_ADMIN_MEMBER_REMOVAL_FORBIDDEN';
  end if;

  select lm.*
  into v_target
  from public.league_members lm
  where lm.id = target_member_id
    and lm.league_id = target_league_id
    and lm.status = 'active'
  for update;

  if v_target.id is null then
    raise exception using
      errcode = 'P0001',
      message = 'TARGET_ACTIVE_MEMBER_NOT_FOUND';
  end if;

  if v_target.role = 'admin' then
    raise exception using
      errcode = 'P0001',
      message = 'ADMIN_CANNOT_REMOVE_SELF';
  end if;

  update public.league_members
  set
    status = 'removed',
    role = 'member'
  where id = target_member_id;

  perform public.write_league_admin_event(
    target_league_id,
    v_admin_member_id,
    v_user_id,
    'member',
    'member_removed',
    target_member_id,
    null,
    jsonb_build_object(
      'reason', nullif(trim(removal_reason), ''),
      'return_requires_admin', true,
      'calendar_changed', false,
      'future_missing_predictions_score', 0
    )
  );
end;
$function$;

comment on function public.remove_league_member_rpc(uuid, uuid, text) is
'Removes an active member from a private league through an authenticated active administrator. Public-league administrator removals are forbidden; objective public-league removals require a separate system-certified contract.';

revoke all on function public.remove_league_member_rpc(uuid, uuid, text) from public;
grant execute on function public.remove_league_member_rpc(uuid, uuid, text) to authenticated;
grant execute on function public.remove_league_member_rpc(uuid, uuid, text) to service_role;


create or replace function public.delete_league_permanently_rpc(
  p_league_id uuid,
  p_confirmation_name text
)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_user_id uuid := auth.uid();
  v_league public.leagues%rowtype;
  v_admin_member_id uuid;

  v_members_count bigint := 0;
  v_historical_non_admin_members_count bigint := 0;
  v_rounds_count bigint := 0;
  v_started_rounds_count bigint := 0;
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

  if v_league.visibility = 'public' then
    /*
     * Historical membership is authoritative.
     *
     * The league can be deleted only when no participant other than the
     * administrator has ever joined, regardless of the participant's current
     * membership status.
     */
    select count(*)
    into v_historical_non_admin_members_count
    from public.league_members lm
    where lm.league_id = p_league_id
      and lm.id <> v_admin_member_id;

    if v_historical_non_admin_members_count > 0 then
      raise exception using
        errcode = 'P0001',
        message = 'PUBLIC_LEAGUE_DELETE_REQUIRES_NO_HISTORICAL_PARTICIPANTS';
    end if;

    /*
     * A public competition is considered started when any canonical start
     * marker exists or when a league round has produced its first official
     * score. After that moment the league must follow its lifecycle and cannot
     * be permanently deleted.
     */
    select count(*)
    into v_started_rounds_count
    from public.league_rounds lr
    where lr.league_id = p_league_id
      and lr.first_official_score_at is not null;

    if v_league.started_at is not null
       or v_league.first_useful_kickoff_at is not null
       or v_started_rounds_count > 0
    then
      raise exception using
        errcode = 'P0001',
        message = 'PUBLIC_LEAGUE_DELETE_FORBIDDEN_AFTER_COMPETITION_START';
    end if;
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
   * Strategy versions reference league members through changed_by_member_id
   * with ON DELETE SET NULL.
   *
   * Deleting league_members first would issue an UPDATE against the immutable
   * strategy_versions table. Remove the versions explicitly before the league
   * cascade.
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

comment on function public.delete_league_permanently_rpc(uuid, text) is
'Permanently deletes a league after authenticated active-admin confirmation. A public league is deletable only before competition start and only when no other participant has ever joined.';

revoke all on function public.delete_league_permanently_rpc(uuid, text) from public;
grant execute on function public.delete_league_permanently_rpc(uuid, text) to authenticated;
grant execute on function public.delete_league_permanently_rpc(uuid, text) to service_role;


/*
 * Installation assertions.
 *
 * These checks certify the presence of the governance guards in the effective
 * PostgreSQL function definitions and abort the migration if any guard is lost.
 */
do $verification$
declare
  v_remove_definition text;
  v_delete_definition text;
begin
  select pg_get_functiondef(
    'public.remove_league_member_rpc(uuid,uuid,text)'::regprocedure
  )
  into v_remove_definition;

  select pg_get_functiondef(
    'public.delete_league_permanently_rpc(uuid,text)'::regprocedure
  )
  into v_delete_definition;

  if position(
    'PUBLIC_LEAGUE_ADMIN_MEMBER_REMOVAL_FORBIDDEN'
    in v_remove_definition
  ) = 0 then
    raise exception
      'PUBLIC_LEAGUE_ADMIN_MEMBER_REMOVAL_GUARD_NOT_INSTALLED';
  end if;

  if position(
    'PUBLIC_LEAGUE_DELETE_REQUIRES_NO_HISTORICAL_PARTICIPANTS'
    in v_delete_definition
  ) = 0 then
    raise exception
      'PUBLIC_LEAGUE_HISTORICAL_PARTICIPANT_DELETE_GUARD_NOT_INSTALLED';
  end if;

  if position(
    'PUBLIC_LEAGUE_DELETE_FORBIDDEN_AFTER_COMPETITION_START'
    in v_delete_definition
  ) = 0 then
    raise exception
      'PUBLIC_LEAGUE_COMPETITION_START_DELETE_GUARD_NOT_INSTALLED';
  end if;

  if position(
    'first_official_score_at is not null'
    in lower(v_delete_definition)
  ) = 0 then
    raise exception
      'PUBLIC_LEAGUE_CERTIFIED_ROUND_START_GUARD_NOT_INSTALLED';
  end if;
end;
$verification$;

commit;


select
  p.oid::regprocedure::text as function_signature,
  pg_get_functiondef(p.oid) like
    '%PUBLIC_LEAGUE_ADMIN_MEMBER_REMOVAL_FORBIDDEN%'
    as has_public_admin_removal_guard
from pg_proc p
join pg_namespace n
  on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname = 'remove_league_member_rpc';

select
  p.oid::regprocedure::text as function_signature,
  pg_get_functiondef(p.oid) like
    '%PUBLIC_LEAGUE_DELETE_REQUIRES_NO_HISTORICAL_PARTICIPANTS%'
    as has_historical_participant_guard,
  pg_get_functiondef(p.oid) like
    '%PUBLIC_LEAGUE_DELETE_FORBIDDEN_AFTER_COMPETITION_START%'
    as has_competition_start_guard,
  pg_get_functiondef(p.oid) like
    '%first_official_score_at is not null%'
    as has_certified_round_guard
from pg_proc p
join pg_namespace n
  on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname = 'delete_league_permanently_rpc';

select
  has_function_privilege(
    'authenticated',
    'public.remove_league_member_rpc(uuid,uuid,text)',
    'EXECUTE'
  ) as authenticated_can_remove_private_member,
  has_function_privilege(
    'authenticated',
    'public.delete_league_permanently_rpc(uuid,text)',
    'EXECUTE'
  ) as authenticated_can_request_league_delete;

\echo MILESTONE_12_9_5_9_PUBLIC_LEAGUE_GOVERNANCE_ENFORCEMENT_READY
