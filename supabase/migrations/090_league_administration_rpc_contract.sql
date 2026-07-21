-- ============================================================================
-- FANTAGOL
-- Migration 090
-- League administration public RPC contract
--
-- Provides:
--   * authenticated member-safe scoring profile read model
--   * admin-only versioned scoring profile update
--   * authenticated league administration event read model
--
-- Notes:
--   * no direct client access to league_scoring_profiles is required
--   * scoring profile history remains immutable/versioned
--   * core point values remain fixed by table constraints
-- ============================================================================

begin;

-- --------------------------------------------------------------------------
-- 1. Read the active scoring profile of a league.
--    Any active member of the target league may read it.
-- --------------------------------------------------------------------------

create or replace function public.get_active_league_scoring_profile_rpc(
  target_league_id uuid
)
returns table(
  id uuid,
  league_id uuid,
  version integer,
  effective_from_league_round_id uuid,
  exact_points numeric,
  sign_points numeric,
  over_under_points numeric,
  goal_no_goal_points numeric,
  surprise_bonus_enabled boolean,
  goal_show_bonus_enabled boolean,
  grand_slam_bonus_enabled boolean,
  cantonata_malus_enabled boolean,
  opposite_sign_malus_enabled boolean,
  surprise_bonus_points numeric,
  goal_show_bonus_points numeric,
  grand_slam_bonus_points numeric,
  cantonata_malus_points numeric,
  opposite_sign_malus_points numeric,
  fantacalcio_rules jsonb,
  one_to_one_rules jsonb,
  created_by_member_id uuid,
  created_at timestamptz,
  reason text,
  active boolean
)
language plpgsql
security definer
set search_path to public
as $function$
declare
  v_user_id uuid := auth.uid();
begin
  if v_user_id is null then
    raise exception using errcode = 'P0001', message = 'AUTH_REQUIRED';
  end if;

  perform 1
  from public.league_members lm
  where lm.league_id = target_league_id
    and lm.user_id = v_user_id
    and lm.status = 'active';

  if not found then
    raise exception using errcode = 'P0001', message = 'ACTIVE_LEAGUE_MEMBER_REQUIRED';
  end if;

  return query
  select
    lsp.id,
    lsp.league_id,
    lsp.version,
    lsp.effective_from_league_round_id,
    lsp.exact_points,
    lsp.sign_points,
    lsp.over_under_points,
    lsp.goal_no_goal_points,
    lsp.surprise_bonus_enabled,
    lsp.goal_show_bonus_enabled,
    lsp.grand_slam_bonus_enabled,
    lsp.cantonata_malus_enabled,
    lsp.opposite_sign_malus_enabled,
    lsp.surprise_bonus_points,
    lsp.goal_show_bonus_points,
    lsp.grand_slam_bonus_points,
    lsp.cantonata_malus_points,
    lsp.opposite_sign_malus_points,
    lsp.fantacalcio_rules,
    lsp.one_to_one_rules,
    lsp.created_by_member_id,
    lsp.created_at,
    lsp.reason,
    lsp.active
  from public.league_scoring_profiles lsp
  where lsp.league_id = target_league_id
    and lsp.active = true
  order by lsp.version desc
  limit 1;
end;
$function$;

-- --------------------------------------------------------------------------
-- 2. Create a new active scoring profile version.
--    Only the active league admin may change bonus/malus toggles.
-- --------------------------------------------------------------------------

create or replace function public.update_league_scoring_profile_rpc(
  target_league_id uuid,
  enable_surprise_bonus boolean,
  enable_goal_show_bonus boolean,
  enable_grand_slam_bonus boolean,
  enable_cantonata_malus boolean,
  enable_opposite_sign_malus boolean,
  change_reason text default null
)
returns table(
  id uuid,
  league_id uuid,
  version integer,
  surprise_bonus_enabled boolean,
  goal_show_bonus_enabled boolean,
  grand_slam_bonus_enabled boolean,
  cantonata_malus_enabled boolean,
  opposite_sign_malus_enabled boolean,
  created_at timestamptz
)
language plpgsql
security definer
set search_path to public
as $function$
declare
  v_user_id uuid := auth.uid();
  v_admin_member_id uuid;
  v_current public.league_scoring_profiles%rowtype;
  v_new public.league_scoring_profiles%rowtype;
begin
  if v_user_id is null then
    raise exception using errcode = 'P0001', message = 'AUTH_REQUIRED';
  end if;

  v_admin_member_id :=
    public.get_active_admin_member_id(target_league_id, v_user_id);

  if v_admin_member_id is null then
    raise exception using errcode = 'P0001', message = 'ACTIVE_ADMIN_REQUIRED';
  end if;

  perform 1
  from public.leagues l
  where l.id = target_league_id
    and l.lifecycle_status not in ('completed', 'archived')
  for update;

  if not found then
    raise exception using errcode = 'P0001', message = 'LEAGUE_NOT_EDITABLE';
  end if;

  select lsp.*
  into v_current
  from public.league_scoring_profiles lsp
  where lsp.league_id = target_league_id
    and lsp.active = true
  order by lsp.version desc
  limit 1
  for update;

  if v_current.id is null then
    raise exception using errcode = 'P0001', message = 'ACTIVE_SCORING_PROFILE_NOT_FOUND';
  end if;

  if
    v_current.surprise_bonus_enabled = enable_surprise_bonus
    and v_current.goal_show_bonus_enabled = enable_goal_show_bonus
    and v_current.grand_slam_bonus_enabled = enable_grand_slam_bonus
    and v_current.cantonata_malus_enabled = enable_cantonata_malus
    and v_current.opposite_sign_malus_enabled = enable_opposite_sign_malus
  then
    return query
    select
      v_current.id,
      v_current.league_id,
      v_current.version,
      v_current.surprise_bonus_enabled,
      v_current.goal_show_bonus_enabled,
      v_current.grand_slam_bonus_enabled,
      v_current.cantonata_malus_enabled,
      v_current.opposite_sign_malus_enabled,
      v_current.created_at;
    return;
  end if;

  update public.league_scoring_profiles
  set active = false
  where id = v_current.id;

  insert into public.league_scoring_profiles (
    league_id,
    version,
    effective_from_league_round_id,
    exact_points,
    sign_points,
    over_under_points,
    goal_no_goal_points,
    surprise_bonus_enabled,
    goal_show_bonus_enabled,
    grand_slam_bonus_enabled,
    cantonata_malus_enabled,
    opposite_sign_malus_enabled,
    surprise_bonus_points,
    goal_show_bonus_points,
    grand_slam_bonus_points,
    cantonata_malus_points,
    opposite_sign_malus_points,
    fantacalcio_rules,
    one_to_one_rules,
    created_by_member_id,
    reason,
    active
  )
  values (
    target_league_id,
    v_current.version + 1,
    v_current.effective_from_league_round_id,
    v_current.exact_points,
    v_current.sign_points,
    v_current.over_under_points,
    v_current.goal_no_goal_points,
    enable_surprise_bonus,
    enable_goal_show_bonus,
    enable_grand_slam_bonus,
    enable_cantonata_malus,
    enable_opposite_sign_malus,
    v_current.surprise_bonus_points,
    v_current.goal_show_bonus_points,
    v_current.grand_slam_bonus_points,
    v_current.cantonata_malus_points,
    v_current.opposite_sign_malus_points,
    v_current.fantacalcio_rules,
    v_current.one_to_one_rules,
    v_admin_member_id,
    nullif(trim(change_reason), ''),
    true
  )
  returning *
  into v_new;

  perform public.write_league_admin_event(
    target_league_id,
    v_admin_member_id,
    v_user_id,
    'member',
    'league_settings_changed',
    null,
    null,
    jsonb_build_object(
      'setting_group', 'scoring_profile',
      'previous_version', v_current.version,
      'new_version', v_new.version,
      'surprise_bonus_enabled', v_new.surprise_bonus_enabled,
      'goal_show_bonus_enabled', v_new.goal_show_bonus_enabled,
      'grand_slam_bonus_enabled', v_new.grand_slam_bonus_enabled,
      'cantonata_malus_enabled', v_new.cantonata_malus_enabled,
      'opposite_sign_malus_enabled', v_new.opposite_sign_malus_enabled,
      'reason', nullif(trim(change_reason), '')
    )
  );

  return query
  select
    v_new.id,
    v_new.league_id,
    v_new.version,
    v_new.surprise_bonus_enabled,
    v_new.goal_show_bonus_enabled,
    v_new.grand_slam_bonus_enabled,
    v_new.cantonata_malus_enabled,
    v_new.opposite_sign_malus_enabled,
    v_new.created_at;
end;
$function$;

-- --------------------------------------------------------------------------
-- 3. League administration event read model.
--    Any active member may read the league history.
-- --------------------------------------------------------------------------

create or replace function public.get_league_admin_events_rpc(
  target_league_id uuid,
  result_limit integer default 50
)
returns table(
  event_id uuid,
  action_type text,
  actor_member_id uuid,
  actor_display_name text,
  target_member_id uuid,
  target_display_name text,
  league_round_id uuid,
  details jsonb,
  created_at timestamptz
)
language plpgsql
security definer
set search_path to public
as $function$
declare
  v_user_id uuid := auth.uid();
  v_limit integer := greatest(1, least(coalesce(result_limit, 50), 200));
begin
  if v_user_id is null then
    raise exception using errcode = 'P0001', message = 'AUTH_REQUIRED';
  end if;

  perform 1
  from public.league_members lm
  where lm.league_id = target_league_id
    and lm.user_id = v_user_id
    and lm.status = 'active';

  if not found then
    raise exception using errcode = 'P0001', message = 'ACTIVE_LEAGUE_MEMBER_REQUIRED';
  end if;

  return query
  select
    lae.id,
    lae.action_type,
    lae.actor_member_id,
    actor.display_name,
    lae.target_member_id,
    target.display_name,
    lae.league_round_id,
    lae.details,
    lae.created_at
  from public.league_admin_events lae
  left join public.league_members actor
    on actor.id = lae.actor_member_id
  left join public.league_members target
    on target.id = lae.target_member_id
  where lae.league_id = target_league_id
  order by lae.created_at desc
  limit v_limit;
end;
$function$;

-- --------------------------------------------------------------------------
-- 4. Privileges.
-- --------------------------------------------------------------------------

revoke all on function public.get_active_league_scoring_profile_rpc(uuid)
  from public;
revoke all on function public.update_league_scoring_profile_rpc(
  uuid, boolean, boolean, boolean, boolean, boolean, text
) from public;
revoke all on function public.get_league_admin_events_rpc(uuid, integer)
  from public;

grant execute on function public.get_active_league_scoring_profile_rpc(uuid)
  to authenticated;
grant execute on function public.update_league_scoring_profile_rpc(
  uuid, boolean, boolean, boolean, boolean, boolean, text
) to authenticated;
grant execute on function public.get_league_admin_events_rpc(uuid, integer)
  to authenticated;

commit;
