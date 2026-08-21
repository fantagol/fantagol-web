-- ================================================================
-- FANTAGOL
-- Schedule Preserve Record Initialization Hotfix
--
-- Scope:
--   activate_league_roster_internal only
--
-- Fix:
--   Avoid dereferencing v_generated_schedule in the preserve path.
--
-- Invariants preserved:
--   * roster hash regeneration gate unchanged
--   * schedule generation unchanged
--   * schedule preservation semantics unchanged
--   * league-round rebase semantics unchanged
--   * historical schedule versions untouched
-- ================================================================
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
  v_requires_round_rebase boolean := false;
  v_first_league_round_id uuid;
  v_generated_schedule record;
  v_schedule_action text;
  v_effective_schedule_version integer;
  v_actor_type text := lower(nullif(btrim(event_actor_type), ''));
  v_activation_reason text := upper(
    coalesce(nullif(btrim(activation_reason), ''), 'MANUAL_ADMIN_LOCK')
  );
  v_round_offset integer := 0;
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
   * Preserve canonical league_round IDs and avoid unnecessary rewrites.
   *
   * The common path already has a complete 1..N materialization. In that
   * case no round number is touched. A rebase is performed only if:
   *   * an earlier round must be excluded;
   *   * a future round is missing;
   *   * the existing numbering differs from the canonical playable order.
   */
  with canonical_rounds as (
    select
      fr.id as fantagol_round_id,
      row_number() over (
        order by fr.sequence, fr.lock_at, fr.id
      )::integer as canonical_number
    from public.fantagol_rounds fr
    where fr.edition_id = v_league.edition_id
      and fr.active = true
      and fr.sequence >= v_start_round.sequence
      and fr.status <> 'cancelled'
  )
  select
    exists (
      select 1
      from public.league_rounds lr
      join public.fantagol_rounds fr
        on fr.id = lr.fantagol_round_id
      where lr.league_id = target_league_id
        and fr.edition_id = v_league.edition_id
        and fr.sequence < v_start_round.sequence
        and lr.enabled = true
    )
    or exists (
      select 1
      from canonical_rounds cr
      left join public.league_rounds lr
        on lr.league_id = target_league_id
       and lr.fantagol_round_id = cr.fantagol_round_id
      where lr.id is null
         or lr.league_round_number <> cr.canonical_number
    )
  into v_requires_round_rebase;

  select count(*)::integer
  into v_inserted_count
  from public.fantagol_rounds fr
  where fr.edition_id = v_league.edition_id
    and fr.active = true
    and fr.sequence >= v_start_round.sequence
    and fr.status <> 'cancelled'
    and not exists (
      select 1
      from public.league_rounds lr
      where lr.league_id = target_league_id
        and lr.fantagol_round_id = fr.id
    );

  if v_requires_round_rebase then
    /*
     * Dynamic parking is strictly above the current maximum. This makes the
     * operation safe even after prior rebases and subsequent reopen/lock
     * cycles; a fixed offset could collide with already parked rows.
     */
    select coalesce(max(lr.league_round_number), 0) + 1000
    into v_round_offset
    from public.league_rounds lr
    where lr.league_id = target_league_id;

    update public.league_rounds lr
    set league_round_number = lr.league_round_number + v_round_offset
    where lr.league_id = target_league_id;

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
      row_number() over (
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
  else
    /* Common path: preserve every existing round number and ID. */
    update public.league_rounds lr
    set
      enabled = true,
      status = case
        when lr.status in ('live', 'scoring', 'official', 'archived')
          then lr.status
        when lr.fantagol_round_id = v_start_round.id
         and clock_timestamp() >= v_start_round.opens_at
         and clock_timestamp() < v_start_round.lock_at
          then 'predictions_open'
        else 'scheduled'
      end
    from public.fantagol_rounds fr
    where lr.league_id = target_league_id
      and fr.id = lr.fantagol_round_id
      and fr.edition_id = v_league.edition_id
      and fr.sequence >= v_start_round.sequence
      and fr.status <> 'cancelled';
  end if;

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

    v_effective_schedule_version :=
      v_generated_schedule.schedule_version;

    v_schedule_action :=
      case
        when v_existing_schedule.id is null
          then 'league_schedules_generated'
        else 'league_schedules_regenerated'
      end;
  else
    v_schedule_action := 'league_schedules_preserved';
    v_effective_schedule_version :=
      v_existing_schedule.version;
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
      'league_round_rebase_applied', v_requires_round_rebase,
      'new_league_rounds_inserted', v_inserted_count,
      'start_fantagol_round_id', v_start_round.id,
      'start_sequence', v_start_round.sequence,
      'first_lock_at', v_start_round.lock_at,
      'schedule_version', v_effective_schedule_version
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
      'league_round_rebase_applied', v_requires_round_rebase,
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

