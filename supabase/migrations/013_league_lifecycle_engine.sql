-- ============================================================================
-- FANTAGOL 013 — LEAGUE LIFECYCLE ENGINE
-- Application Game Foundation / League Governance Runtime
-- ============================================================================
-- Scope:
--   * align legacy league RPCs with admin/vice/member domain
--   * controlled league creation and joining
--   * vice assignment / revocation
--   * roster lock / reopen
--   * automatic League Round generation from first useful FantaGol Round
--   * voluntary leave, free return, admin removal, admin reinstatement
--   * append-only public governance audit
--   * updated_at / version triggers on governance entities
--
-- Explicitly NOT included here:
--   * Fantacalcio / One-to-One pairing algorithms (migration 014)
--   * prediction write RPCs
--   * scoring / certification runtime
-- ============================================================================

begin;

-- --------------------------------------------------------------------------
-- 1. Extend the public governance event vocabulary.
-- --------------------------------------------------------------------------

alter table public.league_admin_events
  drop constraint if exists league_admin_events_action_type_check;

alter table public.league_admin_events
  add constraint league_admin_events_action_type_check
  check (
    action_type = any (array[
      'league_created'::text,
      'member_joined'::text,
      'member_rejoined'::text,
      'roster_locked'::text,
      'roster_reopened'::text,
      'league_started'::text,
      'league_archived'::text,
      'vice_assigned'::text,
      'vice_revoked'::text,
      'admin_resigned'::text,
      'admin_demoted_for_inactivity'::text,
      'vice_promoted_to_admin'::text,
      'admin_assigned_from_ranking'::text,
      'admin_assigned_by_seniority'::text,
      'member_removed'::text,
      'member_reinstated'::text,
      'member_withdrawn'::text,
      'prediction_recovery_opened'::text,
      'prediction_recovery_used'::text,
      'prediction_recovery_revoked'::text,
      'prediction_recovery_expired'::text,
      'postponed_match_detected'::text,
      'postponed_match_reopened'::text,
      'postponed_match_excluded'::text,
      'calculation_preview_created'::text,
      'calculation_preview_failed'::text,
      'round_certification_committed'::text,
      'round_certification_superseded'::text,
      'scoring_profile_changed'::text,
      'league_settings_changed'::text
    ])
  );

-- --------------------------------------------------------------------------
-- 2. Governance update/version triggers.
-- Existing shared trigger functions are reused.
-- --------------------------------------------------------------------------

drop trigger if exists set_leagues_updated_at on public.leagues;
create trigger set_leagues_updated_at
before update on public.leagues
for each row execute function public.set_updated_at();

drop trigger if exists increment_leagues_version on public.leagues;
create trigger increment_leagues_version
before update on public.leagues
for each row execute function public.increment_row_version();

drop trigger if exists set_league_rounds_updated_at on public.league_rounds;
create trigger set_league_rounds_updated_at
before update on public.league_rounds
for each row execute function public.set_updated_at();

drop trigger if exists increment_league_rounds_version on public.league_rounds;
create trigger increment_league_rounds_version
before update on public.league_rounds
for each row execute function public.increment_row_version();

-- --------------------------------------------------------------------------
-- 3. Internal helpers.
-- --------------------------------------------------------------------------

create or replace function public.get_active_admin_member_id(
  p_league_id uuid,
  p_user_id uuid
)
returns uuid
language sql
stable
security definer
set search_path to public
as $function$
  select lm.id
  from public.league_members lm
  where lm.league_id = p_league_id
    and lm.user_id = p_user_id
    and lm.role = 'admin'
    and lm.status = 'active'
  limit 1;
$function$;

create or replace function public.write_league_admin_event(
  p_league_id uuid,
  p_actor_member_id uuid,
  p_actor_user_id uuid,
  p_actor_type text,
  p_action_type text,
  p_target_member_id uuid default null,
  p_league_round_id uuid default null,
  p_details jsonb default '{}'::jsonb
)
returns uuid
language plpgsql
security definer
set search_path to public
as $function$
declare
  v_event_id uuid;
begin
  insert into public.league_admin_events (
    league_id,
    actor_member_id,
    actor_user_id,
    actor_type,
    action_type,
    target_member_id,
    league_round_id,
    details
  )
  values (
    p_league_id,
    p_actor_member_id,
    p_actor_user_id,
    p_actor_type,
    p_action_type,
    p_target_member_id,
    p_league_round_id,
    coalesce(p_details, '{}'::jsonb)
  )
  returning id into v_event_id;

  return v_event_id;
end;
$function$;

-- --------------------------------------------------------------------------
-- 4. Create league — preserves the existing frontend contract.
-- --------------------------------------------------------------------------

create or replace function public.create_league_rpc(
  league_name text,
  member_display_name text
)
returns table(league_id uuid, invite_code text)
language plpgsql
security definer
set search_path to public
as $function$
declare
  v_user_id uuid := auth.uid();
  v_league_id uuid;
  v_invite_code text;
  v_club_id uuid;
  v_admin_member_id uuid;
  v_edition_id uuid;
begin
  if v_user_id is null then
    raise exception using errcode = 'P0001', message = 'AUTH_REQUIRED';
  end if;

  if nullif(trim(league_name), '') is null then
    raise exception using errcode = 'P0001', message = 'LEAGUE_NAME_REQUIRED';
  end if;

  if nullif(trim(member_display_name), '') is null then
    raise exception using errcode = 'P0001', message = 'DISPLAY_NAME_REQUIRED';
  end if;

  select ce.id
  into v_edition_id
  from public.competition_editions ce
  join public.competitions c on c.id = ce.competition_id
  where ce.active = true
    and ce.status in ('scheduled', 'active')
    and c.enabled = true
  order by
    case ce.status when 'active' then 0 else 1 end,
    ce.starts_at,
    ce.created_at
  limit 1;

  if v_edition_id is null then
    raise exception using errcode = 'P0001', message = 'NO_ACTIVE_COMPETITION_EDITION';
  end if;

  select c.id
  into v_club_id
  from public.clubs c
  where c.owner_id = v_user_id
  limit 1;

  if v_club_id is null then
    insert into public.clubs (owner_id, name)
    values (v_user_id, 'FantaGol Club')
    returning id into v_club_id;
  end if;

  loop
    v_invite_code :=
      'FG-' || upper(substring(md5(random()::text || clock_timestamp()::text), 1, 6));

    exit when not exists (
      select 1
      from public.leagues l
      where l.invite_code = v_invite_code
    );
  end loop;

  insert into public.leagues (
    name,
    owner_id,
    invite_code,
    status,
    edition_id,
    lifecycle_status,
    roster_status,
    vice_required
  )
  values (
    trim(league_name),
    v_user_id,
    v_invite_code,
    'active',
    v_edition_id,
    'open',
    'open',
    true
  )
  returning id into v_league_id;

  insert into public.league_members (
    league_id,
    user_id,
    club_id,
    display_name,
    role,
    status
  )
  values (
    v_league_id,
    v_user_id,
    v_club_id,
    trim(member_display_name),
    'admin',
    'active'
  )
  returning id into v_admin_member_id;

  update public.profiles
  set last_active_league_id = v_league_id
  where id = v_user_id;

  perform public.write_league_admin_event(
    v_league_id,
    v_admin_member_id,
    v_user_id,
    'member',
    'league_created',
    v_admin_member_id,
    null,
    jsonb_build_object(
      'edition_id', v_edition_id,
      'initial_role', 'admin',
      'lifecycle_status', 'open',
      'roster_status', 'open'
    )
  );

  return query select v_league_id, v_invite_code;
end;
$function$;

-- --------------------------------------------------------------------------
-- 5. Join / return to league — preserves the existing frontend contract.
--
-- New membership:
--   allowed only while roster is open and league has not started.
-- Existing LEFT membership:
--   can return freely; missed rounds remain lost.
-- Existing REMOVED membership:
--   cannot self-rejoin; admin reinstatement is required.
-- --------------------------------------------------------------------------

create or replace function public.join_league_rpc(
  target_invite_code text,
  member_display_name text
)
returns table(joined_league_id uuid)
language plpgsql
security definer
set search_path to public
as $function$
declare
  v_user_id uuid := auth.uid();
  v_league public.leagues%rowtype;
  v_club_id uuid;
  v_existing_member public.league_members%rowtype;
  v_member_id uuid;
  v_action_type text;
begin
  if v_user_id is null then
    raise exception using errcode = 'P0001', message = 'AUTH_REQUIRED';
  end if;

  if nullif(trim(target_invite_code), '') is null then
    raise exception using errcode = 'P0001', message = 'INVITE_CODE_REQUIRED';
  end if;

  if nullif(trim(member_display_name), '') is null then
    raise exception using errcode = 'P0001', message = 'DISPLAY_NAME_REQUIRED';
  end if;

  select l.*
  into v_league
  from public.leagues l
  where upper(l.invite_code) = upper(trim(target_invite_code))
    and l.status = 'active'
    and l.lifecycle_status not in ('completed', 'archived')
  limit 1
  for update;

  if v_league.id is null then
    raise exception using errcode = 'P0001', message = 'INVALID_OR_EXPIRED_INVITE_CODE';
  end if;

  select lm.*
  into v_existing_member
  from public.league_members lm
  where lm.league_id = v_league.id
    and lm.user_id = v_user_id
  limit 1
  for update;

  if v_existing_member.id is not null then
    if v_existing_member.status = 'removed' then
      raise exception using errcode = 'P0001', message = 'ADMIN_REINSTATEMENT_REQUIRED';
    end if;

    if v_existing_member.status = 'active' then
      update public.profiles
      set last_active_league_id = v_league.id
      where id = v_user_id;

      return query select v_league.id;
      return;
    end if;

    update public.league_members
    set
      status = 'active',
      display_name = trim(member_display_name)
    where id = v_existing_member.id
    returning id into v_member_id;

    v_action_type := 'member_rejoined';
  else
    if v_league.roster_status <> 'open'
       or v_league.lifecycle_status not in ('draft', 'open') then
      raise exception using errcode = 'P0001', message = 'LEAGUE_ROSTER_CLOSED';
    end if;

    select c.id
    into v_club_id
    from public.clubs c
    where c.owner_id = v_user_id
    limit 1;

    if v_club_id is null then
      insert into public.clubs (owner_id, name)
      values (v_user_id, 'FantaGol Club')
      returning id into v_club_id;
    end if;

    insert into public.league_members (
      league_id,
      user_id,
      club_id,
      display_name,
      role,
      status
    )
    values (
      v_league.id,
      v_user_id,
      v_club_id,
      trim(member_display_name),
      'member',
      'active'
    )
    returning id into v_member_id;

    v_action_type := 'member_joined';
  end if;

  update public.profiles
  set last_active_league_id = v_league.id
  where id = v_user_id;

  perform public.write_league_admin_event(
    v_league.id,
    v_member_id,
    v_user_id,
    'member',
    v_action_type,
    v_member_id,
    null,
    jsonb_build_object(
      'missed_rounds_recovered', false,
      'calendar_changed', false
    )
  );

  return query select v_league.id;
end;
$function$;

-- --------------------------------------------------------------------------
-- 6. Read current memberships — preserves the existing frontend contract.
-- --------------------------------------------------------------------------

create or replace function public.get_my_leagues_rpc()
returns table(
  membership_id uuid,
  league_id uuid,
  league_name text,
  invite_code text,
  display_name text,
  role text,
  status text
)
language sql
security definer
set search_path to public
as $function$
  select
    lm.id,
    l.id,
    l.name,
    l.invite_code,
    lm.display_name,
    lm.role,
    lm.status
  from public.league_members lm
  join public.leagues l on l.id = lm.league_id
  where lm.user_id = auth.uid()
    and lm.status = 'active'
    and l.status = 'active'
    and l.lifecycle_status <> 'archived'
  order by l.created_at desc;
$function$;

-- --------------------------------------------------------------------------
-- 7. Assign / revoke vice.
-- --------------------------------------------------------------------------

create or replace function public.assign_league_vice_rpc(
  target_league_id uuid,
  target_member_id uuid
)
returns void
language plpgsql
security definer
set search_path to public
as $function$
declare
  v_user_id uuid := auth.uid();
  v_admin_member_id uuid;
  v_target public.league_members%rowtype;
begin
  if v_user_id is null then
    raise exception using errcode = 'P0001', message = 'AUTH_REQUIRED';
  end if;

  v_admin_member_id := public.get_active_admin_member_id(target_league_id, v_user_id);
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

  select lm.*
  into v_target
  from public.league_members lm
  where lm.id = target_member_id
    and lm.league_id = target_league_id
    and lm.status = 'active'
  for update;

  if v_target.id is null then
    raise exception using errcode = 'P0001', message = 'TARGET_ACTIVE_MEMBER_NOT_FOUND';
  end if;

  if v_target.role = 'admin' then
    raise exception using errcode = 'P0001', message = 'ADMIN_CANNOT_BE_VICE';
  end if;

  update public.league_members
  set role = 'member'
  where league_id = target_league_id
    and role = 'vice'
    and status = 'active'
    and id <> target_member_id;

  update public.league_members
  set role = 'vice'
  where id = target_member_id;

  perform public.write_league_admin_event(
    target_league_id,
    v_admin_member_id,
    v_user_id,
    'member',
    'vice_assigned',
    target_member_id,
    null,
    jsonb_build_object('previous_role', v_target.role)
  );
end;
$function$;

create or replace function public.revoke_league_vice_rpc(
  target_league_id uuid
)
returns void
language plpgsql
security definer
set search_path to public
as $function$
declare
  v_user_id uuid := auth.uid();
  v_admin_member_id uuid;
  v_vice_member_id uuid;
begin
  if v_user_id is null then
    raise exception using errcode = 'P0001', message = 'AUTH_REQUIRED';
  end if;

  v_admin_member_id := public.get_active_admin_member_id(target_league_id, v_user_id);
  if v_admin_member_id is null then
    raise exception using errcode = 'P0001', message = 'ACTIVE_ADMIN_REQUIRED';
  end if;

  select lm.id
  into v_vice_member_id
  from public.league_members lm
  where lm.league_id = target_league_id
    and lm.role = 'vice'
    and lm.status = 'active'
  limit 1
  for update;

  if v_vice_member_id is null then
    raise exception using errcode = 'P0001', message = 'ACTIVE_VICE_NOT_FOUND';
  end if;

  update public.league_members
  set role = 'member'
  where id = v_vice_member_id;

  perform public.write_league_admin_event(
    target_league_id,
    v_admin_member_id,
    v_user_id,
    'member',
    'vice_revoked',
    v_vice_member_id,
    null,
    '{}'::jsonb
  );
end;
$function$;

-- --------------------------------------------------------------------------
-- 8. Lock roster and generate League Rounds.
--
-- First lock:
--   * requires active admin, active vice when configured, >= 2 active members
--   * chooses the first active FantaGol Round whose lock_at is still future
--   * creates all remaining League Rounds for the same edition
--
-- Re-lock after a permitted reopen:
--   * preserves existing League Rounds
--   * H2H calendar keep/regenerate choice belongs to migration 014
-- --------------------------------------------------------------------------

create or replace function public.lock_league_roster_rpc(
  target_league_id uuid
)
returns table(
  league_id uuid,
  starts_from_fantagol_round_id uuid,
  generated_league_rounds integer,
  first_league_round_id uuid
)
language plpgsql
security definer
set search_path to public
as $function$
declare
  v_user_id uuid := auth.uid();
  v_admin_member_id uuid;
  v_league public.leagues%rowtype;
  v_active_member_count integer;
  v_active_vice_count integer;
  v_start_round public.fantagol_rounds%rowtype;
  v_inserted_count integer := 0;
  v_first_league_round_id uuid;
begin
  if v_user_id is null then
    raise exception using errcode = 'P0001', message = 'AUTH_REQUIRED';
  end if;

  v_admin_member_id := public.get_active_admin_member_id(target_league_id, v_user_id);
  if v_admin_member_id is null then
    raise exception using errcode = 'P0001', message = 'ACTIVE_ADMIN_REQUIRED';
  end if;

  select l.*
  into v_league
  from public.leagues l
  where l.id = target_league_id
  for update;

  if v_league.id is null then
    raise exception using errcode = 'P0001', message = 'LEAGUE_NOT_FOUND';
  end if;

  if v_league.lifecycle_status in ('completed', 'archived') then
    raise exception using errcode = 'P0001', message = 'LEAGUE_NOT_LOCKABLE';
  end if;

  if v_league.first_scored_at is not null then
    raise exception using errcode = 'P0001', message = 'LEAGUE_ALREADY_SCORED';
  end if;

  select count(*)::integer
  into v_active_member_count
  from public.league_members lm
  where lm.league_id = target_league_id
    and lm.status = 'active';

  if v_active_member_count < 2 then
    raise exception using errcode = 'P0001', message = 'MINIMUM_TWO_ACTIVE_MEMBERS_REQUIRED';
  end if;

  select count(*)::integer
  into v_active_vice_count
  from public.league_members lm
  where lm.league_id = target_league_id
    and lm.role = 'vice'
    and lm.status = 'active';

  if v_league.vice_required and v_active_vice_count <> 1 then
    raise exception using errcode = 'P0001', message = 'ACTIVE_VICE_REQUIRED';
  end if;

  if v_league.starts_from_fantagol_round_id is not null then
    select fr.*
    into v_start_round
    from public.fantagol_rounds fr
    where fr.id = v_league.starts_from_fantagol_round_id
      and fr.edition_id = v_league.edition_id
      and fr.active = true;

    if v_start_round.id is null or now() >= v_start_round.lock_at then
      raise exception using errcode = 'P0001', message = 'LEAGUE_FIRST_ROUND_ALREADY_STARTED';
    end if;
  else
    select fr.*
    into v_start_round
    from public.fantagol_rounds fr
    where fr.edition_id = v_league.edition_id
      and fr.active = true
      and fr.lock_at > now()
      and fr.status not in ('cancelled', 'final_official', 'recalculated')
    order by fr.lock_at, fr.sequence
    limit 1;

    if v_start_round.id is null then
      raise exception using errcode = 'P0001', message = 'NO_FUTURE_FANTAGOL_ROUND_AVAILABLE';
    end if;
  end if;

  insert into public.league_rounds (
    league_id,
    fantagol_round_id,
    league_round_number,
    status,
    enabled
  )
  select
    target_league_id,
    fr.id,
    row_number() over (order by fr.sequence)::integer,
    case
      when fr.id = v_start_round.id and now() >= fr.opens_at and now() < fr.lock_at
        then 'predictions_open'
      else 'scheduled'
    end,
    true
  from public.fantagol_rounds fr
  where fr.edition_id = v_league.edition_id
    and fr.active = true
    and fr.sequence >= v_start_round.sequence
    and fr.status <> 'cancelled'
  order by fr.sequence
  on conflict (league_id, fantagol_round_id) do nothing;

  get diagnostics v_inserted_count = row_count;

  select lr.id
  into v_first_league_round_id
  from public.league_rounds lr
  where lr.league_id = target_league_id
    and lr.fantagol_round_id = v_start_round.id
  limit 1;

  update public.leagues
  set
    starts_from_fantagol_round_id = v_start_round.id,
    roster_status = 'locked',
    roster_locked_at = now(),
    lifecycle_status = 'locked',
    started_at = coalesce(started_at, v_start_round.starts_at)
  where id = target_league_id;

  perform public.write_league_admin_event(
    target_league_id,
    v_admin_member_id,
    v_user_id,
    'member',
    'roster_locked',
    null,
    v_first_league_round_id,
    jsonb_build_object(
      'active_member_count', v_active_member_count,
      'start_fantagol_round_id', v_start_round.id,
      'start_sequence', v_start_round.sequence,
      'first_lock_at', v_start_round.lock_at,
      'generated_league_rounds', v_inserted_count,
      'existing_rounds_preserved', true,
      'h2h_schedule_generation_required', true
    )
  );

  return query
  select target_league_id, v_start_round.id, v_inserted_count, v_first_league_round_id;
end;
$function$;

-- --------------------------------------------------------------------------
-- 9. Reopen roster before the first kickoff / lock and before scoring.
-- Existing League Rounds are deliberately preserved.
-- --------------------------------------------------------------------------

create or replace function public.reopen_league_roster_rpc(
  target_league_id uuid
)
returns void
language plpgsql
security definer
set search_path to public
as $function$
declare
  v_user_id uuid := auth.uid();
  v_admin_member_id uuid;
  v_league public.leagues%rowtype;
  v_start_round public.fantagol_rounds%rowtype;
begin
  if v_user_id is null then
    raise exception using errcode = 'P0001', message = 'AUTH_REQUIRED';
  end if;

  v_admin_member_id := public.get_active_admin_member_id(target_league_id, v_user_id);
  if v_admin_member_id is null then
    raise exception using errcode = 'P0001', message = 'ACTIVE_ADMIN_REQUIRED';
  end if;

  select l.*
  into v_league
  from public.leagues l
  where l.id = target_league_id
  for update;

  if v_league.id is null then
    raise exception using errcode = 'P0001', message = 'LEAGUE_NOT_FOUND';
  end if;

  if v_league.roster_status <> 'locked'
     or v_league.lifecycle_status <> 'locked' then
    raise exception using errcode = 'P0001', message = 'LEAGUE_ROSTER_NOT_LOCKED';
  end if;

  if v_league.first_scored_at is not null then
    raise exception using errcode = 'P0001', message = 'LEAGUE_ALREADY_SCORED';
  end if;

  select fr.*
  into v_start_round
  from public.fantagol_rounds fr
  where fr.id = v_league.starts_from_fantagol_round_id
  limit 1;

  if v_start_round.id is null then
    raise exception using errcode = 'P0001', message = 'LEAGUE_START_ROUND_NOT_FOUND';
  end if;

  if now() >= v_start_round.lock_at then
    raise exception using errcode = 'P0001', message = 'LEAGUE_ALREADY_STARTED';
  end if;

  update public.leagues
  set
    roster_status = 'open',
    roster_locked_at = null,
    lifecycle_status = 'open',
    reopened_at = now()
  where id = target_league_id;

  perform public.write_league_admin_event(
    target_league_id,
    v_admin_member_id,
    v_user_id,
    'member',
    'roster_reopened',
    null,
    null,
    jsonb_build_object(
      'first_lock_at', v_start_round.lock_at,
      'league_rounds_preserved', true,
      'h2h_schedule_revalidation_required_on_next_lock', true
    )
  );
end;
$function$;

-- --------------------------------------------------------------------------
-- 10. Voluntary leave and free return.
-- The member remains in historical schedules; future missing predictions score 0.
-- --------------------------------------------------------------------------

create or replace function public.leave_league_rpc(
  target_league_id uuid
)
returns void
language plpgsql
security definer
set search_path to public
as $function$
declare
  v_user_id uuid := auth.uid();
  v_member public.league_members%rowtype;
begin
  if v_user_id is null then
    raise exception using errcode = 'P0001', message = 'AUTH_REQUIRED';
  end if;

  select lm.*
  into v_member
  from public.league_members lm
  where lm.league_id = target_league_id
    and lm.user_id = v_user_id
    and lm.status = 'active'
  for update;

  if v_member.id is null then
    raise exception using errcode = 'P0001', message = 'ACTIVE_MEMBERSHIP_NOT_FOUND';
  end if;

  if v_member.role = 'admin' then
    raise exception using errcode = 'P0001', message = 'ADMIN_MUST_TRANSFER_ROLE_BEFORE_LEAVING';
  end if;

  update public.league_members
  set status = 'left'
  where id = v_member.id;

  update public.profiles
  set last_active_league_id = null
  where id = v_user_id
    and last_active_league_id = target_league_id;

  perform public.write_league_admin_event(
    target_league_id,
    v_member.id,
    v_user_id,
    'member',
    'member_withdrawn',
    v_member.id,
    null,
    jsonb_build_object(
      'return_requires_admin', false,
      'calendar_changed', false,
      'future_missing_predictions_score', 0
    )
  );
end;
$function$;

-- --------------------------------------------------------------------------
-- 11. Admin removal / expulsion and controlled reinstatement.
-- --------------------------------------------------------------------------

create or replace function public.remove_league_member_rpc(
  target_league_id uuid,
  target_member_id uuid,
  removal_reason text default null
)
returns void
language plpgsql
security definer
set search_path to public
as $function$
declare
  v_user_id uuid := auth.uid();
  v_admin_member_id uuid;
  v_target public.league_members%rowtype;
begin
  if v_user_id is null then
    raise exception using errcode = 'P0001', message = 'AUTH_REQUIRED';
  end if;

  v_admin_member_id := public.get_active_admin_member_id(target_league_id, v_user_id);
  if v_admin_member_id is null then
    raise exception using errcode = 'P0001', message = 'ACTIVE_ADMIN_REQUIRED';
  end if;

  select lm.*
  into v_target
  from public.league_members lm
  where lm.id = target_member_id
    and lm.league_id = target_league_id
    and lm.status = 'active'
  for update;

  if v_target.id is null then
    raise exception using errcode = 'P0001', message = 'TARGET_ACTIVE_MEMBER_NOT_FOUND';
  end if;

  if v_target.role = 'admin' then
    raise exception using errcode = 'P0001', message = 'ADMIN_CANNOT_REMOVE_SELF';
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

create or replace function public.reinstate_league_member_rpc(
  target_league_id uuid,
  target_member_id uuid
)
returns void
language plpgsql
security definer
set search_path to public
as $function$
declare
  v_user_id uuid := auth.uid();
  v_admin_member_id uuid;
  v_target public.league_members%rowtype;
begin
  if v_user_id is null then
    raise exception using errcode = 'P0001', message = 'AUTH_REQUIRED';
  end if;

  v_admin_member_id := public.get_active_admin_member_id(target_league_id, v_user_id);
  if v_admin_member_id is null then
    raise exception using errcode = 'P0001', message = 'ACTIVE_ADMIN_REQUIRED';
  end if;

  select lm.*
  into v_target
  from public.league_members lm
  where lm.id = target_member_id
    and lm.league_id = target_league_id
    and lm.status = 'removed'
  for update;

  if v_target.id is null then
    raise exception using errcode = 'P0001', message = 'REMOVED_MEMBER_NOT_FOUND';
  end if;

  update public.league_members
  set
    status = 'active',
    role = 'member'
  where id = target_member_id;

  perform public.write_league_admin_event(
    target_league_id,
    v_admin_member_id,
    v_user_id,
    'member',
    'member_reinstated',
    target_member_id,
    null,
    jsonb_build_object(
      'missed_rounds_recovered', false,
      'calendar_changed', false
    )
  );
end;
$function$;

-- --------------------------------------------------------------------------
-- 12. Legacy delete RPC aligned to lifecycle/archive semantics.
-- --------------------------------------------------------------------------

create or replace function public.delete_league_rpc(
  target_league_id uuid
)
returns void
language plpgsql
security definer
set search_path to public
as $function$
declare
  v_user_id uuid := auth.uid();
  v_admin_member_id uuid;
begin
  if v_user_id is null then
    raise exception using errcode = 'P0001', message = 'AUTH_REQUIRED';
  end if;

  v_admin_member_id := public.get_active_admin_member_id(target_league_id, v_user_id);
  if v_admin_member_id is null then
    raise exception using errcode = 'P0001', message = 'ACTIVE_ADMIN_REQUIRED';
  end if;

  perform public.write_league_admin_event(
    target_league_id,
    v_admin_member_id,
    v_user_id,
    'member',
    'league_archived',
    null,
    null,
    jsonb_build_object('legacy_status', 'deleted')
  );

  update public.leagues
  set
    status = 'deleted',
    lifecycle_status = 'archived'
  where id = target_league_id;

  update public.league_members
  set
    status = case when role = 'admin' then status else 'removed' end,
    role = case when role = 'admin' then role else 'member' end
  where league_id = target_league_id;

  update public.profiles
  set last_active_league_id = null
  where last_active_league_id = target_league_id;
end;
$function$;

-- --------------------------------------------------------------------------
-- 13. Harden execution privileges.
-- --------------------------------------------------------------------------

revoke all on function public.get_active_admin_member_id(uuid, uuid) from public;
revoke all on function public.write_league_admin_event(uuid, uuid, uuid, text, text, uuid, uuid, jsonb) from public;

revoke all on function public.create_league_rpc(text, text) from public;
revoke all on function public.join_league_rpc(text, text) from public;
revoke all on function public.get_my_leagues_rpc() from public;
revoke all on function public.assign_league_vice_rpc(uuid, uuid) from public;
revoke all on function public.revoke_league_vice_rpc(uuid) from public;
revoke all on function public.lock_league_roster_rpc(uuid) from public;
revoke all on function public.reopen_league_roster_rpc(uuid) from public;
revoke all on function public.leave_league_rpc(uuid) from public;
revoke all on function public.remove_league_member_rpc(uuid, uuid, text) from public;
revoke all on function public.reinstate_league_member_rpc(uuid, uuid) from public;
revoke all on function public.delete_league_rpc(uuid) from public;

grant execute on function public.create_league_rpc(text, text) to authenticated;
grant execute on function public.join_league_rpc(text, text) to authenticated;
grant execute on function public.get_my_leagues_rpc() to authenticated;
grant execute on function public.assign_league_vice_rpc(uuid, uuid) to authenticated;
grant execute on function public.revoke_league_vice_rpc(uuid) to authenticated;
grant execute on function public.lock_league_roster_rpc(uuid) to authenticated;
grant execute on function public.reopen_league_roster_rpc(uuid) to authenticated;
grant execute on function public.leave_league_rpc(uuid) to authenticated;
grant execute on function public.remove_league_member_rpc(uuid, uuid, text) to authenticated;
grant execute on function public.reinstate_league_member_rpc(uuid, uuid) to authenticated;
grant execute on function public.delete_league_rpc(uuid) to authenticated;

-- Internal helpers remain callable only by privileged roles and SECURITY DEFINER RPCs.
grant execute on function public.get_active_admin_member_id(uuid, uuid) to postgres, service_role;
grant execute on function public.write_league_admin_event(uuid, uuid, uuid, text, text, uuid, uuid, jsonb) to postgres, service_role;

-- --------------------------------------------------------------------------
-- 14. Migration audit.
-- --------------------------------------------------------------------------

insert into public.competition_audit_log (
  actor_id,
  action,
  aggregate_type,
  aggregate_id,
  before_json,
  after_json,
  reason
)
select
  null,
  'league_lifecycle_engine_installed',
  'competition_edition',
  ce.id,
  null,
  jsonb_build_object(
    'migration', '013_league_lifecycle_engine',
    'rpc_contracts_preserved', true,
    'league_round_generation', true,
    'voluntary_return', true,
    'admin_reinstatement', true,
    'h2h_schedule_engine_pending', true
  ),
  'Install Application Game Foundation league lifecycle runtime'
from public.competition_editions ce
where ce.active = true
order by ce.starts_at
limit 1;

commit;
