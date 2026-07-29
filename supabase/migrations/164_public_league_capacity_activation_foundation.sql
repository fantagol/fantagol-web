-- ============================================================================
-- 164_public_league_capacity_activation_foundation.sql
--
-- FantaGol Milestone 12.9.5.12
--
-- Goals:
--   * Extract the canonical roster activation engine from the admin RPC.
--   * Automatically activate a public league exactly when it reaches capacity.
--   * Resolve the first still-playable Fantagol round at activation time.
--   * Preserve existing league_round IDs and prediction references.
--   * Reopen public registrations when an admin reopens the roster.
--   * Preserve the dormant 24-hour automatic-close foundation for a future season.
-- ============================================================================

begin;

-- ============================================================================
-- 1. INTERNAL CANONICAL ACTIVATION CORE
-- ============================================================================

create or replace function public.activate_league_roster_internal(
  target_league_id uuid,
  generation_authority_member_id uuid,
  event_actor_member_id uuid default null,
  event_actor_user_id uuid default null,
  event_actor_type text default 'system',
  regenerate_schedules boolean default true,
  activation_reason text default 'MANUAL_ADMIN_LOCK'
)
returns table(
  league_id uuid,
  starts_from_fantagol_round_id uuid,
  generated_league_rounds integer,
  first_league_round_id uuid
)
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
  v_league public.leagues%rowtype;
  v_active_member_ids uuid[];
  v_active_member_count integer;
  v_active_vice_count integer;
  v_current_roster_hash text;
  v_existing_schedule public.league_schedule_versions%rowtype;
  v_start_round public.fantagol_rounds%rowtype;
  v_inserted_count integer := 0;
  v_first_league_round_id uuid;
  v_generated_schedule record;
  v_schedule_action text;
  v_actor_type text := lower(nullif(btrim(event_actor_type), ''));
  v_activation_reason text := upper(
    coalesce(nullif(btrim(activation_reason), ''), 'MANUAL_ADMIN_LOCK')
  );
  v_round_offset integer := 1000000;
begin
  if target_league_id is null then
    raise exception using
      errcode = 'P0001',
      message = 'LEAGUE_ID_REQUIRED';
  end if;

  if generation_authority_member_id is null then
    raise exception using
      errcode = 'P0001',
      message = 'ACTIVE_ADMIN_REQUIRED';
  end if;

  if v_actor_type not in ('member', 'system') then
    raise exception using
      errcode = 'P0001',
      message = 'INVALID_EVENT_ACTOR_TYPE';
  end if;

  if v_activation_reason not in (
    'MANUAL_ADMIN_LOCK',
    'PUBLIC_CAPACITY_REACHED',
    'PUBLIC_AUTOMATIC_DEADLINE'
  ) then
    raise exception using
      errcode = 'P0001',
      message = 'INVALID_LEAGUE_ACTIVATION_REASON';
  end if;

  select l.*
  into v_league
  from public.leagues l
  where l.id = target_league_id
  for update;

  if v_league.id is null then
    raise exception using
      errcode = 'P0001',
      message = 'LEAGUE_NOT_FOUND';
  end if;

  if v_league.lifecycle_status in ('completed', 'archived') then
    raise exception using
      errcode = 'P0001',
      message = 'LEAGUE_NOT_LOCKABLE';
  end if;

  if v_league.first_scored_at is not null then
    raise exception using
      errcode = 'P0001',
      message = 'LEAGUE_ALREADY_SCORED';
  end if;

  if not exists (
    select 1
    from public.league_members lm
    where lm.id = generation_authority_member_id
      and lm.league_id = target_league_id
      and lm.role = 'admin'
      and lm.status = 'active'
  ) then
    raise exception using
      errcode = 'P0001',
      message = 'ACTIVE_ADMIN_REQUIRED';
  end if;

  if v_actor_type = 'member' then
    if event_actor_member_id is null
       or event_actor_user_id is null
       or not exists (
         select 1
         from public.league_members lm
         where lm.id = event_actor_member_id
           and lm.league_id = target_league_id
           and lm.user_id = event_actor_user_id
           and lm.status = 'active'
       ) then
      raise exception using
        errcode = 'P0001',
        message = 'ACTIVE_EVENT_ACTOR_REQUIRED';
    end if;
  end if;

  select array_agg(lm.id order by lm.id)
  into v_active_member_ids
  from public.league_members lm
  where lm.league_id = target_league_id
    and lm.status = 'active';

  v_active_member_count := coalesce(cardinality(v_active_member_ids), 0);

  if v_active_member_count < 2 then
    raise exception using
      errcode = 'P0001',
      message = 'MINIMUM_TWO_ACTIVE_MEMBERS_REQUIRED';
  end if;

  select count(*)::integer
  into v_active_vice_count
  from public.league_members lm
  where lm.league_id = target_league_id
    and lm.role = 'vice'
    and lm.status = 'active';

  if v_league.vice_required and v_active_vice_count <> 1 then
    raise exception using
      errcode = 'P0001',
      message = 'ACTIVE_VICE_REQUIRED';
  end if;

  if v_activation_reason = 'PUBLIC_CAPACITY_REACHED' then
    if v_league.visibility <> 'public' then
      raise exception using
        errcode = 'P0001',
        message = 'PUBLIC_LEAGUE_REQUIRED';
    end if;

    if v_league.max_participants is null
       or v_active_member_count <> v_league.max_participants then
      raise exception using
        errcode = 'P0001',
        message = 'PUBLIC_LEAGUE_CAPACITY_NOT_REACHED';
    end if;
  end if;

  /*
   * Canonical activation-time start resolution.
   *
   * Creation-time schedule data is only provisional. The first competitive
   * round is the first active, non-final round whose lock is still in the
   * future at the exact activation transaction.
   */
  select fr.*
  into v_start_round
  from public.fantagol_rounds fr
  where fr.edition_id = v_league.edition_id
    and fr.active = true
    and fr.lock_at > clock_timestamp()
    and fr.status not in (
      'cancelled',
      'final_official',
      'recalculated'
    )
  order by fr.lock_at, fr.sequence, fr.id
  limit 1;

  if v_start_round.id is null then
    raise exception using
      errcode = 'P0001',
      message = 'NO_FUTURE_FANTAGOL_ROUND_AVAILABLE';
  end if;

  /*
   * Preserve canonical league_round IDs.
   *
   * Existing rounds may have been provisionally materialized when the league
   * was created. Move every current number into a temporary positive range,
   * then:
   *   * disable rounds before the activation start;
   *   * assign future playable rounds the canonical 1..N numbering;
   *   * preserve all row IDs and therefore every existing foreign key.
   */
  update public.league_rounds lr
  set league_round_number = lr.league_round_number + (v_round_offset * 2)
  where lr.league_id = target_league_id
    and lr.league_round_number < v_round_offset;

  update public.league_rounds lr
  set
    enabled = false,
    status = case
      when lr.status in ('official', 'archived', 'cancelled')
        then lr.status
      else 'cancelled'
    end
  from public.fantagol_rounds fr
  where lr.league_id = target_league_id
    and fr.id = lr.fantagol_round_id
    and fr.edition_id = v_league.edition_id
    and fr.sequence < v_start_round.sequence;

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
    v_round_offset + row_number() over (
      order by fr.sequence, fr.lock_at, fr.id
    )::integer,
    case
      when fr.id = v_start_round.id
       and clock_timestamp() >= fr.opens_at
       and clock_timestamp() < fr.lock_at
        then 'predictions_open'
      else 'scheduled'
    end,
    true
  from public.fantagol_rounds fr
  where fr.edition_id = v_league.edition_id
    and fr.active = true
    and fr.sequence >= v_start_round.sequence
    and fr.status <> 'cancelled'
  order by fr.sequence, fr.lock_at, fr.id
  on conflict on constraint league_rounds_league_fantagol_unique
  do update
  set
    league_round_number = excluded.league_round_number,
    enabled = true,
    status = case
      when public.league_rounds.status in (
        'live',
        'scoring',
        'official',
        'archived'
      )
        then public.league_rounds.status
      else excluded.status
    end;

  get diagnostics v_inserted_count = row_count;

  with canonical_numbers as (
    select
      lr.id,
      row_number() over (
        order by fr.sequence, fr.lock_at, fr.id
      )::integer as canonical_number
    from public.league_rounds lr
    join public.fantagol_rounds fr
      on fr.id = lr.fantagol_round_id
    where lr.league_id = target_league_id
      and lr.enabled = true
      and fr.edition_id = v_league.edition_id
      and fr.sequence >= v_start_round.sequence
      and fr.status <> 'cancelled'
  )
  update public.league_rounds lr
  set league_round_number = cn.canonical_number
  from canonical_numbers cn
  where lr.id = cn.id;

  select lr.id
  into v_first_league_round_id
  from public.league_rounds lr
  where lr.league_id = target_league_id
    and lr.fantagol_round_id = v_start_round.id
    and lr.enabled = true
  limit 1;

  if v_first_league_round_id is null then
    raise exception using
      errcode = 'P0001',
      message = 'LEAGUE_START_ROUND_NOT_MATERIALIZED';
  end if;

  v_current_roster_hash :=
    public.compute_league_roster_hash(v_active_member_ids);

  select lsv.*
  into v_existing_schedule
  from public.league_schedule_versions lsv
  where lsv.league_id = target_league_id
    and lsv.active = true
  order by lsv.version desc
  limit 1
  for update;

  if v_existing_schedule.id is null
     or v_existing_schedule.roster_hash <> v_current_roster_hash
     or regenerate_schedules then

    select *
    into v_generated_schedule
    from public.generate_league_competitions(
      target_league_id,
      generation_authority_member_id,
      case
        when v_existing_schedule.id is null then
          case v_activation_reason
            when 'PUBLIC_CAPACITY_REACHED'
              then 'Initial schedule generated when public capacity was reached'
            when 'PUBLIC_AUTOMATIC_DEADLINE'
              then 'Initial schedule generated by automatic public deadline'
            else 'Initial roster lock schedule generation'
          end
        when v_existing_schedule.roster_hash <> v_current_roster_hash
          then 'Mandatory regeneration because active roster changed'
        else 'Admin requested schedule regeneration'
      end
    );

    v_schedule_action :=
      case
        when v_existing_schedule.id is null
          then 'league_schedules_generated'
        else 'league_schedules_regenerated'
      end;
  else
    v_schedule_action := 'league_schedules_preserved';
  end if;

  update public.leagues
  set
    starts_from_fantagol_round_id = v_start_round.id,
    first_useful_kickoff_at = v_start_round.starts_at,
    roster_status = 'locked',
    roster_locked_at = clock_timestamp(),
    lifecycle_status = 'locked',
    started_at = coalesce(started_at, v_start_round.starts_at),
    public_registrations_open = case
      when visibility = 'public' then false
      else public_registrations_open
    end
  where id = target_league_id;

  perform public.write_league_admin_event(
    target_league_id,
    event_actor_member_id,
    event_actor_user_id,
    v_actor_type,
    v_schedule_action,
    null,
    v_first_league_round_id,
    jsonb_build_object(
      'activation_reason', v_activation_reason,
      'active_member_count', v_active_member_count,
      'has_bye', mod(v_active_member_count, 2) = 1,
      'roster_hash', v_current_roster_hash,
      'regeneration_requested', regenerate_schedules,
      'start_fantagol_round_id', v_start_round.id,
      'start_sequence', v_start_round.sequence,
      'first_lock_at', v_start_round.lock_at,
      'schedule_version',
        case
          when v_schedule_action = 'league_schedules_preserved'
            then v_existing_schedule.version
          else v_generated_schedule.schedule_version
        end
    )
  );

  perform public.write_league_admin_event(
    target_league_id,
    event_actor_member_id,
    event_actor_user_id,
    v_actor_type,
    'roster_locked',
    null,
    v_first_league_round_id,
    jsonb_build_object(
      'activation_reason', v_activation_reason,
      'active_member_count', v_active_member_count,
      'start_fantagol_round_id', v_start_round.id,
      'start_sequence', v_start_round.sequence,
      'first_lock_at', v_start_round.lock_at,
      'generated_league_rounds', v_inserted_count,
      'h2h_schedules_ready', true,
      'public_registrations_open',
        case when v_league.visibility = 'public' then false else null end
    )
  );

  return query
  select
    target_league_id,
    v_start_round.id,
    v_inserted_count,
    v_first_league_round_id;
end;
$function$;

revoke all on function public.activate_league_roster_internal(
  uuid,
  uuid,
  uuid,
  uuid,
  text,
  boolean,
  text
) from public, anon, authenticated;

grant execute on function public.activate_league_roster_internal(
  uuid,
  uuid,
  uuid,
  uuid,
  text,
  boolean,
  text
) to service_role;


-- ============================================================================
-- 2. ADMIN RPC WRAPPER
-- ============================================================================

create or replace function public.lock_league_roster_rpc(
  target_league_id uuid,
  regenerate_schedules boolean default true
)
returns table(
  league_id uuid,
  starts_from_fantagol_round_id uuid,
  generated_league_rounds integer,
  first_league_round_id uuid
)
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
  v_user_id uuid := auth.uid();
  v_admin_member_id uuid;
begin
  if v_user_id is null then
    raise exception using
      errcode = 'P0001',
      message = 'AUTH_REQUIRED';
  end if;

  v_admin_member_id :=
    public.get_active_admin_member_id(target_league_id, v_user_id);

  if v_admin_member_id is null then
    raise exception using
      errcode = 'P0001',
      message = 'ACTIVE_ADMIN_REQUIRED';
  end if;

  return query
  select *
  from public.activate_league_roster_internal(
    target_league_id,
    v_admin_member_id,
    v_admin_member_id,
    v_user_id,
    'member',
    regenerate_schedules,
    'MANUAL_ADMIN_LOCK'
  );
end;
$function$;

revoke all on function public.lock_league_roster_rpc(uuid, boolean)
from public, anon;

grant execute on function public.lock_league_roster_rpc(uuid, boolean)
to authenticated;


-- ============================================================================
-- 3. PUBLIC JOIN WITH CAPACITY ACTIVATION
-- ============================================================================

create or replace function public.join_public_league_rpc(
  target_league_id uuid,
  member_display_name text
)
returns table(
  joined_league_id uuid,
  membership_id uuid,
  join_result text
)
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
  v_user_id uuid := auth.uid();
  v_league public.leagues%rowtype;
  v_existing_member public.league_members%rowtype;
  v_start_round_lock_at timestamptz;
  v_edition_visible boolean;
  v_active_member_count integer;
  v_join record;
  v_error_message text;
  v_admin_member_id uuid;
  v_active_schedule_exists boolean;
begin
  if v_user_id is null then
    raise exception using
      errcode = 'P0001',
      message = 'AUTH_REQUIRED';
  end if;

  if target_league_id is null then
    raise exception using
      errcode = 'P0001',
      message = 'PUBLIC_LEAGUE_NOT_FOUND';
  end if;

  if nullif(trim(member_display_name), '') is null then
    raise exception using
      errcode = 'P0001',
      message = 'DISPLAY_NAME_REQUIRED';
  end if;

  select l.*
  into v_league
  from public.leagues l
  where l.id = target_league_id
  for update;

  if v_league.id is null
     or v_league.status <> 'active'
     or v_league.lifecycle_status = 'archived' then
    raise exception using
      errcode = 'P0001',
      message = 'PUBLIC_LEAGUE_NOT_FOUND';
  end if;

  if v_league.visibility <> 'public' then
    raise exception using
      errcode = 'P0001',
      message = 'PUBLIC_LEAGUE_NOT_PUBLIC';
  end if;

  select exists (
    select 1
    from public.competition_editions ce
    join public.competitions c
      on c.id = ce.competition_id
    where ce.id = v_league.edition_id
      and ce.active = true
      and ce.status in ('scheduled', 'active')
      and c.enabled = true
  )
  into v_edition_visible;

  if not coalesce(v_edition_visible, false) then
    raise exception using
      errcode = 'P0001',
      message = 'PUBLIC_LEAGUE_NOT_JOINABLE';
  end if;

  select lm.*
  into v_existing_member
  from public.league_members lm
  where lm.league_id = v_league.id
    and lm.user_id = v_user_id
  limit 1
  for update;

  -- Existing active membership remains idempotent after closure/full/start.
  if v_existing_member.id is null
     or v_existing_member.status <> 'active' then

    if v_existing_member.status = 'removed' then
      raise exception using
        errcode = 'P0001',
        message = 'LEAGUE_MEMBER_REMOVED_REQUIRES_REINSTATEMENT';
    end if;

    if v_league.public_registrations_open is distinct from true then
      raise exception using
        errcode = 'P0001',
        message = 'PUBLIC_LEAGUE_REGISTRATIONS_CLOSED';
    end if;

    if v_league.roster_status <> 'open'
       or v_league.lifecycle_status not in ('draft', 'open') then
      raise exception using
        errcode = 'P0001',
        message = 'PUBLIC_LEAGUE_ROSTER_LOCKED';
    end if;

    select fr.lock_at
    into v_start_round_lock_at
    from public.fantagol_rounds fr
    where fr.id = v_league.starts_from_fantagol_round_id
      and fr.edition_id = v_league.edition_id
    limit 1;

    if v_league.first_scored_at is not null
       or v_start_round_lock_at is null
       or clock_timestamp() >= v_start_round_lock_at then
      /*
       * A creation-time round may already have expired while recruitment
       * remains intentionally open. In that case a later round is still valid.
       */
      if not exists (
        select 1
        from public.fantagol_rounds fr
        where fr.edition_id = v_league.edition_id
          and fr.active = true
          and fr.lock_at > clock_timestamp()
          and fr.status not in (
            'cancelled',
            'final_official',
            'recalculated'
          )
      ) then
        raise exception using
          errcode = 'P0001',
          message = 'PUBLIC_LEAGUE_COMPETITION_STARTED';
      end if;
    end if;

    select count(*)::integer
    into v_active_member_count
    from public.league_members lm
    where lm.league_id = v_league.id
      and lm.status = 'active';

    if v_league.max_participants is null
       or v_league.max_participants < 2
       or v_league.max_participants > 20 then
      raise exception using
        errcode = 'P0001',
        message = 'PUBLIC_LEAGUE_INVALID_MAX_PARTICIPANTS';
    end if;

    if v_active_member_count >= v_league.max_participants then
      raise exception using
        errcode = 'P0001',
        message = 'PUBLIC_LEAGUE_FULL';
    end if;
  end if;

  begin
    select *
    into v_join
    from public.join_league_membership_internal(
      v_league.id,
      v_user_id,
      member_display_name,
      'public_catalog',
      v_user_id,
      clock_timestamp()
    );
  exception
    when others then
      get stacked diagnostics
        v_error_message = message_text;

      if v_error_message =
         'LEAGUE_MEMBER_REMOVED_REQUIRES_REINSTATEMENT' then
        raise exception using
          errcode = 'P0001',
          message = 'LEAGUE_MEMBER_REMOVED_REQUIRES_REINSTATEMENT';

      elsif v_error_message = 'LEAGUE_ROSTER_CLOSED' then
        raise exception using
          errcode = 'P0001',
          message = 'PUBLIC_LEAGUE_ROSTER_LOCKED';

      elsif v_error_message in (
        'LEAGUE_NOT_FOUND',
        'LEAGUE_NOT_JOINABLE'
      ) then
        raise exception using
          errcode = 'P0001',
          message = 'PUBLIC_LEAGUE_NOT_JOINABLE';

      else
        raise;
      end if;
  end;

  /*
   * The league row remains transaction-locked from the initial SELECT FOR
   * UPDATE, so the post-join capacity decision is serialized.
   */
  select count(*)::integer
  into v_active_member_count
  from public.league_members lm
  where lm.league_id = v_league.id
    and lm.status = 'active';

  select lm.id
  into v_admin_member_id
  from public.league_members lm
  where lm.league_id = v_league.id
    and lm.role = 'admin'
    and lm.status = 'active'
  order by lm.joined_at, lm.id
  limit 1;

  select exists (
    select 1
    from public.league_schedule_versions lsv
    where lsv.league_id = v_league.id
      and lsv.active = true
  )
  into v_active_schedule_exists;

  if v_join.join_result <> 'already_active'
     and v_league.roster_status = 'open'
     and v_active_schedule_exists = false
     and v_active_member_count = v_league.max_participants then

    perform *
    from public.activate_league_roster_internal(
      v_league.id,
      v_admin_member_id,
      null,
      null,
      'system',
      true,
      'PUBLIC_CAPACITY_REACHED'
    );
  end if;

  return query
  select
    v_join.league_id,
    v_join.membership_id,
    v_join.join_result;
end;
$function$;

revoke all on function public.join_public_league_rpc(uuid, text)
from public, anon;

grant execute on function public.join_public_league_rpc(uuid, text)
to authenticated, service_role;


-- ============================================================================
-- 4. PUBLIC-AWARE ROSTER REOPEN
-- ============================================================================

create or replace function public.reopen_league_roster_rpc(
  target_league_id uuid
)
returns void
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
  v_user_id uuid := auth.uid();
  v_admin_member_id uuid;
  v_league public.leagues%rowtype;
  v_start_round public.fantagol_rounds%rowtype;
begin
  if v_user_id is null then
    raise exception using
      errcode = 'P0001',
      message = 'AUTH_REQUIRED';
  end if;

  v_admin_member_id :=
    public.get_active_admin_member_id(target_league_id, v_user_id);

  if v_admin_member_id is null then
    raise exception using
      errcode = 'P0001',
      message = 'ACTIVE_ADMIN_REQUIRED';
  end if;

  select l.*
  into v_league
  from public.leagues l
  where l.id = target_league_id
  for update;

  if v_league.id is null then
    raise exception using
      errcode = 'P0001',
      message = 'LEAGUE_NOT_FOUND';
  end if;

  if v_league.roster_status <> 'locked'
     or v_league.lifecycle_status <> 'locked' then
    raise exception using
      errcode = 'P0001',
      message = 'LEAGUE_ROSTER_NOT_LOCKED';
  end if;

  if v_league.first_scored_at is not null then
    raise exception using
      errcode = 'P0001',
      message = 'LEAGUE_ALREADY_SCORED';
  end if;

  select fr.*
  into v_start_round
  from public.fantagol_rounds fr
  where fr.id = v_league.starts_from_fantagol_round_id
  limit 1;

  if v_start_round.id is null then
    raise exception using
      errcode = 'P0001',
      message = 'LEAGUE_START_ROUND_NOT_FOUND';
  end if;

  if clock_timestamp() >= v_start_round.lock_at then
    raise exception using
      errcode = 'P0001',
      message = 'LEAGUE_ALREADY_STARTED';
  end if;

  update public.leagues
  set
    roster_status = 'open',
    roster_locked_at = null,
    lifecycle_status = 'open',
    reopened_at = clock_timestamp(),
    public_registrations_open = case
      when visibility = 'public' then true
      else public_registrations_open
    end
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
      'h2h_schedule_revalidation_required_on_next_lock', true,
      'public_registrations_open',
        case when v_league.visibility = 'public' then true else null end
    )
  );
end;
$function$;

revoke all on function public.reopen_league_roster_rpc(uuid)
from public, anon;

grant execute on function public.reopen_league_roster_rpc(uuid)
to authenticated;


-- ============================================================================
-- 5. POST-INSTALL CONTRACT ASSERTIONS
-- ============================================================================

do $assertions$
begin
  if to_regprocedure(
    'public.activate_league_roster_internal(uuid,uuid,uuid,uuid,text,boolean,text)'
  ) is null then
    raise exception 'ACTIVATION_CORE_NOT_INSTALLED';
  end if;

  if has_function_privilege(
    'authenticated',
    'public.activate_league_roster_internal(uuid,uuid,uuid,uuid,text,boolean,text)',
    'EXECUTE'
  ) then
    raise exception 'ACTIVATION_CORE_EXPOSED_TO_AUTHENTICATED';
  end if;

  if not has_function_privilege(
    'authenticated',
    'public.lock_league_roster_rpc(uuid,boolean)',
    'EXECUTE'
  ) then
    raise exception 'ADMIN_LOCK_RPC_NOT_EXECUTABLE';
  end if;

  if not has_function_privilege(
    'authenticated',
    'public.join_public_league_rpc(uuid,text)',
    'EXECUTE'
  ) then
    raise exception 'PUBLIC_JOIN_RPC_NOT_EXECUTABLE';
  end if;
end;
$assertions$;

commit;
