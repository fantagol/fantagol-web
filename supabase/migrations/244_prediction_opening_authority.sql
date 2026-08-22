-- ================================================================
-- FANTAGOL
-- MIGRATION 244
-- PREDICTION OPENING AUTHORITY
-- R7-R7A-R4
-- ================================================================
-- ================================================================
-- CANONICAL PREDICTION OPENING AUTHORITY
-- ================================================================

create or replace function public.advance_prediction_opening_internal(
  p_fantagol_round_id uuid
)
returns table(
  fantagol_round_id uuid,
  round_opened boolean,
  league_rounds_opened integer,
  resulting_status text,
  reason text
)
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
  v_round public.fantagol_rounds%rowtype;
  v_now timestamptz := clock_timestamp();
  v_ready boolean := false;
  v_round_opened integer := 0;
  v_league_rounds_opened integer := 0;
begin
  if p_fantagol_round_id is null then
    raise exception using
      errcode = 'P0001',
      message = 'FANTAGOL_ROUND_ID_REQUIRED';
  end if;

  perform pg_advisory_xact_lock(
    hashtextextended(
      'fantagol:prediction-opening:' ||
      p_fantagol_round_id::text,
      0
    )
  );

  select fr.*
  into v_round
  from public.fantagol_rounds fr
  where fr.id = p_fantagol_round_id
  for update;

  if v_round.id is null then
    raise exception using
      errcode = 'P0001',
      message = 'FANTAGOL_ROUND_NOT_FOUND';
  end if;

  if not v_round.active
     or v_round.status = 'cancelled' then
    return query
    select
      p_fantagol_round_id,
      false,
      0,
      v_round.status,
      'round_not_eligible';
    return;
  end if;

  if v_round.status <> 'scheduled' then
    return query
    select
      p_fantagol_round_id,
      false,
      0,
      v_round.status,
      'round_not_scheduled';
    return;
  end if;

  if v_now < v_round.opens_at then
    return query
    select
      p_fantagol_round_id,
      false,
      0,
      v_round.status,
      'opening_time_not_reached';
    return;
  end if;

  if v_now >= v_round.lock_at then
    return query
    select
      p_fantagol_round_id,
      false,
      0,
      v_round.status,
      'opening_window_closed';
    return;
  end if;

  select coalesce(
    public.surprise_reference_ready_internal(
      p_fantagol_round_id
    ),
    false
  )
  into v_ready;

  if not v_ready then
    return query
    select
      p_fantagol_round_id,
      false,
      0,
      v_round.status,
      'surprise_reference_not_ready';
    return;
  end if;

  update public.fantagol_rounds fr
  set status = 'predictions_open'
  where fr.id = p_fantagol_round_id
    and fr.status = 'scheduled';

  get diagnostics v_round_opened = row_count;

  update public.league_rounds lr
  set status = 'predictions_open'
  where lr.fantagol_round_id = p_fantagol_round_id
    and lr.enabled = true
    and lr.status = 'scheduled';

  get diagnostics v_league_rounds_opened = row_count;

  return query
  select
    p_fantagol_round_id,
    v_round_opened = 1,
    v_league_rounds_opened,
    'predictions_open'::text,
    'predictions_opened'::text;
end;
$function$;

revoke all
on function public.advance_prediction_opening_internal(uuid)
from public, anon, authenticated;

grant execute
on function public.advance_prediction_opening_internal(uuid)
to service_role;

comment on function public.advance_prediction_opening_internal(uuid)
is
  'Canonical idempotent authority for scheduled -> predictions_open. Requires timing window and immutable Surprise Reference READY.';

-- ================================================================
-- SURPRISE-AWARE MATERIALIZATION
-- ================================================================

CREATE OR REPLACE FUNCTION public.materialize_league_rounds_core(target_league_id uuid, expected_visibility text)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_league public.leagues%rowtype;
  v_start_round public.fantagol_rounds%rowtype;
  v_visibility text;
  v_error_prefix text;
  v_affected_count integer := 0;
begin
  if target_league_id is null then
    raise exception using
      errcode = 'P0001',
      message = 'LEAGUE_REQUIRED';
  end if;

  v_visibility := lower(nullif(trim(expected_visibility), ''));

  if v_visibility is null
     or v_visibility not in ('public', 'private') then
    raise exception using
      errcode = 'P0001',
      message = 'INVALID_LEAGUE_VISIBILITY';
  end if;

  v_error_prefix :=
    case
      when v_visibility = 'public' then 'PUBLIC_LEAGUE'
      else 'PRIVATE_LEAGUE'
    end;

  select l.*
  into v_league
  from public.leagues l
  where l.id = target_league_id;

  if v_league.id is null then
    raise exception using
      errcode = 'P0001',
      message = 'LEAGUE_NOT_FOUND';
  end if;

  if v_league.visibility <> v_visibility then
    return 0;
  end if;

  if v_league.starts_from_fantagol_round_id is null then
    raise exception using
      errcode = 'P0001',
      message = v_error_prefix || '_START_ROUND_REQUIRED';
  end if;

  select fr.*
  into v_start_round
  from public.fantagol_rounds fr
  where fr.id = v_league.starts_from_fantagol_round_id
    and fr.edition_id = v_league.edition_id
    and fr.active = true;

  if v_start_round.id is null then
    raise exception using
      errcode = 'P0001',
      message = v_error_prefix || '_START_ROUND_NOT_FOUND';
  end if;

  insert into public.league_rounds (
    league_id,
    fantagol_round_id,
    league_round_number,
    status,
    enabled
  )
  select
    v_league.id,
    fr.id,
    row_number() over (
      order by fr.sequence
    )::integer,
    case
      when fr.id = v_start_round.id
       and clock_timestamp() >= fr.opens_at
       and clock_timestamp() < fr.lock_at
       and public.surprise_reference_ready_internal(fr.id)
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
  on conflict on constraint league_rounds_league_fantagol_unique
  do update
  set
    enabled = true,
    status =
      case
        when excluded.fantagol_round_id = v_start_round.id
         and clock_timestamp() >= v_start_round.opens_at
         and clock_timestamp() < v_start_round.lock_at
         and public.surprise_reference_ready_internal(v_start_round.id)
         and public.league_rounds.status = 'scheduled'
          then 'predictions_open'
        else public.league_rounds.status
      end;

  get diagnostics v_affected_count = row_count;

  return v_affected_count;
end;
$function$;
-- ================================================================
-- SURPRISE-AWARE ACTIVATION
-- ================================================================

CREATE OR REPLACE FUNCTION public.activate_league_roster_internal(target_league_id uuid, generation_authority_member_id uuid, event_actor_member_id uuid DEFAULT NULL::uuid, event_actor_user_id uuid DEFAULT NULL::uuid, event_actor_type text DEFAULT 'system'::text, regenerate_schedules boolean DEFAULT true, activation_reason text DEFAULT 'MANUAL_ADMIN_LOCK'::text)
 RETURNS TABLE(league_id uuid, starts_from_fantagol_round_id uuid, generated_league_rounds integer, first_league_round_id uuid)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$

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
         and public.surprise_reference_ready_internal(fr.id)
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
         and public.surprise_reference_ready_internal(v_start_round.id)
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
-- ================================================================
-- SURPRISE-AWARE REBASE
-- ================================================================

CREATE OR REPLACE FUNCTION public.rebase_fantagol_round_schedule_internal(p_fantagol_round_id uuid)
 RETURNS TABLE(fantagol_round_id uuid, previous_opens_at timestamp with time zone, previous_lock_at timestamp with time zone, previous_starts_at timestamp with time zone, previous_ends_at timestamp with time zone, rebased_opens_at timestamp with time zone, rebased_lock_at timestamp with time zone, rebased_starts_at timestamp with time zone, rebased_ends_at timestamp with time zone, previous_status text, rebased_status text, match_count integer, changed boolean)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_round public.fantagol_rounds%rowtype;

  v_starts_at timestamptz;
  v_ends_at timestamptz;
  v_match_count integer;

  v_previous_round_ends_at timestamptz;
  v_candidate_opens_at timestamptz;
  v_opens_at timestamptz;

  v_status text;
  v_changed boolean;

  v_now timestamptz := clock_timestamp();
begin
  if p_fantagol_round_id is null then
    raise exception using
      errcode = 'P0001',
      message = 'FANTAGOL_ROUND_REQUIRED';
  end if;

  select *
  into v_round
  from public.fantagol_rounds
  where id = p_fantagol_round_id
  for update;

  if not found then
    raise exception using
      errcode = 'P0001',
      message = 'FANTAGOL_ROUND_NOT_FOUND';
  end if;

  select
    w.starts_at,
    w.ends_at,
    w.match_count
  into
    v_starts_at,
    v_ends_at,
    v_match_count
  from public.compute_fantagol_round_match_window(
    p_fantagol_round_id
  ) w;

  if v_match_count <> v_round.target_match_count then
    raise exception using
      errcode = 'P0001',
      message = 'FANTAGOL_ROUND_MATCH_COUNT_MISMATCH',
      detail = format(
        'round_id=%s expected=%s actual=%s',
        p_fantagol_round_id,
        v_round.target_match_count,
        v_match_count
      );
  end if;

  if v_starts_at is null
     or v_ends_at is null
     or v_ends_at < v_starts_at then
    raise exception using
      errcode = 'P0001',
      message = 'FANTAGOL_ROUND_MATCH_WINDOW_INVALID';
  end if;

  select previous_round.ends_at
  into v_previous_round_ends_at
  from public.fantagol_rounds previous_round
  where previous_round.edition_id = v_round.edition_id
    and previous_round.active = true
    and previous_round.sequence < v_round.sequence
  order by previous_round.sequence desc
  limit 1;

  v_candidate_opens_at :=
    case
      when v_previous_round_ends_at is not null
       and v_previous_round_ends_at < v_starts_at
        then v_previous_round_ends_at
      else v_starts_at - interval '7 days'
    end;

  -- Once an opening window has already started, a provider schedule
  -- correction must never take that access away by moving opens_at later.
  v_opens_at :=
    case
      when v_round.opens_at <= v_now
        then least(v_round.opens_at, v_candidate_opens_at)
      else v_candidate_opens_at
    end;

  -- Preserve terminal/certified lifecycle states.
  v_status :=
    case
      when v_round.status in (
        'final_official',
        'recalculated',
        'cancelled'
      )
        then v_round.status

      when v_now < v_opens_at
        then 'scheduled'

      when v_now < v_starts_at
       and public.surprise_reference_ready_internal(p_fantagol_round_id)
        then 'predictions_open'

      when v_now < v_starts_at
        then 'scheduled'

      when v_now <= v_ends_at
        then 'live'

      else 'final_calculable'
    end;

  v_changed :=
    v_round.opens_at is distinct from v_opens_at
    or v_round.lock_at is distinct from v_starts_at
    or v_round.starts_at is distinct from v_starts_at
    or v_round.ends_at is distinct from v_ends_at
    or v_round.status is distinct from v_status;

  if v_changed then
    update public.fantagol_rounds
    set
      opens_at = v_opens_at,
      lock_at = v_starts_at,
      starts_at = v_starts_at,
      ends_at = v_ends_at,
      status = v_status
    where id = p_fantagol_round_id;
  end if;

  return query
  select
    p_fantagol_round_id,
    v_round.opens_at,
    v_round.lock_at,
    v_round.starts_at,
    v_round.ends_at,
    v_opens_at,
    v_starts_at,
    v_starts_at,
    v_ends_at,
    v_round.status,
    v_status,
    v_match_count,
    v_changed;
end;
$function$;