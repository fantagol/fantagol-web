-- Migration 254: Strategy Schedule Continuity Authority
--
-- Goal:
--   Make Strategy continuity a hard postcondition of every newly activated
--   League Schedule version.
--
-- Existing authority reused:
--   public.materialize_round_strategy_defaults_rpc(uuid)
--
-- Continuity precedence remains owned by migration 198:
--   1. preserve current official Strategy;
--   2. preserve/rebind previous official Strategy after schedule regeneration;
--   3. preserve complete workspace where valid;
--   4. materialize deterministic default when no valid user Strategy exists.
--
-- Permanent invariant:
--   For every active member that has ten official Predictions, every current
--   non-BYE Fantacalcio / One-to-One fixture side must have one terminal
--   Strategy with a valid immutable submitted Strategy Version.
--
-- Recovery:
--   Members without ten official Predictions are outside this invariant.
--   Therefore an active Prediction Recovery member remains incomplete until
--   Prediction completion, exactly as intended.
--
-- Transactionality:
--   The constraint trigger is DEFERRABLE INITIALLY DEFERRED. It executes only
--   after the schedule generator has finished creating all fixtures. Any
--   reconciliation or invariant failure aborts the surrounding schedule
--   transaction.


create or replace function public.assert_round_strategy_continuity_internal(
  p_league_round_id uuid,
  p_schedule_version_id uuid
)
returns table (
  league_round_id uuid,
  schedule_version_id uuid,
  expected_strategy_side_count integer,
  terminal_strategy_side_count integer,
  breach_count integer
)
language plpgsql
security definer
set search_path = public, pg_temp
as $function$
declare
  v_round public.league_rounds%rowtype;
  v_schedule public.league_schedule_versions%rowtype;

  v_expected integer := 0;
  v_terminal integer := 0;
  v_breaches integer := 0;
begin
  if p_league_round_id is null then
    raise exception using
      errcode = 'P0001',
      message = 'STRATEGY_CONTINUITY_ROUND_REQUIRED';
  end if;

  if p_schedule_version_id is null then
    raise exception using
      errcode = 'P0001',
      message = 'STRATEGY_CONTINUITY_SCHEDULE_REQUIRED';
  end if;

  select lr.*
  into v_round
  from public.league_rounds lr
  where lr.id = p_league_round_id;

  if not found then
    raise exception using
      errcode = 'P0001',
      message = 'STRATEGY_CONTINUITY_ROUND_NOT_FOUND';
  end if;

  select lsv.*
  into v_schedule
  from public.league_schedule_versions lsv
  where lsv.id = p_schedule_version_id
    and lsv.league_id = v_round.league_id;

  if not found then
    raise exception using
      errcode = 'P0001',
      message = 'STRATEGY_CONTINUITY_SCHEDULE_NOT_FOUND';
  end if;

  with complete_members as (
    select
      lm.id as league_member_id
    from public.league_members lm
    join public.predictions p
      on p.league_member_id = lm.id
     and p.league_round_id = p_league_round_id
     and p.submitted_version is not null
     and p.official_submitted_at is not null
     and p.status in ('submitted', 'locked')
    where lm.league_id = v_round.league_id
      and lm.status = 'active'
    group by lm.id
    having count(*) = 10
  ),

  expected_sides as (
    select
      lf.id as league_fixture_id,
      lf.mode,
      lf.home_member_id as league_member_id
    from public.league_fixtures lf
    join complete_members cm
      on cm.league_member_id = lf.home_member_id
    where lf.league_round_id = p_league_round_id
      and lf.schedule_version_id = p_schedule_version_id
      and lf.mode in ('fantacalcio', 'one_to_one')
      and lf.is_bye = false

    union all

    select
      lf.id,
      lf.mode,
      lf.away_member_id
    from public.league_fixtures lf
    join complete_members cm
      on cm.league_member_id = lf.away_member_id
    where lf.league_round_id = p_league_round_id
      and lf.schedule_version_id = p_schedule_version_id
      and lf.mode in ('fantacalcio', 'one_to_one')
      and lf.is_bye = false
      and lf.away_member_id is not null
  ),

  resolved as (
    select
      es.league_fixture_id,
      es.mode,
      es.league_member_id,

      s.id as strategy_id,
      s.submitted_version,

      sv.id as submitted_payload_id

    from expected_sides es

    left join public.strategies s
      on s.league_fixture_id = es.league_fixture_id
     and s.league_member_id = es.league_member_id
     and s.league_round_id = p_league_round_id
     and s.status in ('submitted', 'locked')

    left join public.strategy_versions sv
      on sv.strategy_id = s.id
     and sv.version = s.submitted_version
     and sv.status in ('submitted', 'locked')
  )

  select
    count(*)::integer,

    count(*) filter (
      where strategy_id is not null
        and submitted_version is not null
        and submitted_payload_id is not null
    )::integer,

    count(*) filter (
      where strategy_id is null
         or submitted_version is null
         or submitted_payload_id is null
    )::integer

  into
    v_expected,
    v_terminal,
    v_breaches

  from resolved;

  if v_breaches <> 0 then
    raise exception using
      errcode = 'P0001',
      message = 'STRATEGY_SCHEDULE_CONTINUITY_BREACH',
      detail = format(
        'league_round_id=%s schedule_version_id=%s expected=%s terminal=%s breaches=%s',
        p_league_round_id,
        p_schedule_version_id,
        v_expected,
        v_terminal,
        v_breaches
      );
  end if;

  return query
  select
    p_league_round_id,
    p_schedule_version_id,
    v_expected,
    v_terminal,
    v_breaches;
end;
$function$;


create or replace function public.terminalize_closed_round_strategy_continuity_internal(
  p_league_round_id uuid,
  p_schedule_version_id uuid
)
returns table (
  league_round_id uuid,
  expected_strategy_count integer,
  locked_strategy_count integer,
  restored_official_strategy_count integer,
  auto_submitted_strategy_count integer,
  already_terminal_strategy_count integer,
  terminalized_at timestamptz
)
language plpgsql
security definer
set search_path = public, pg_temp
as $function$
declare
  v_now timestamptz := now();

  v_round_status text;
  v_league_id uuid;
  v_match_set_version integer;

  v_expected integer := 0;
  v_locked integer := 0;
  v_restored integer := 0;
  v_auto_submitted integer := 0;
  v_terminal integer := 0;

  v_item record;
  v_strategy public.strategies%rowtype;

  v_payload jsonb;

  v_submission_version integer;
  v_locked_version integer;
begin
  if p_league_round_id is null then
    raise exception using
      errcode = 'P0001',
      message = 'STRATEGY_CONTINUITY_ROUND_REQUIRED';
  end if;

  if p_schedule_version_id is null then
    raise exception using
      errcode = 'P0001',
      message = 'STRATEGY_CONTINUITY_SCHEDULE_REQUIRED';
  end if;

  perform pg_advisory_xact_lock(
    hashtextextended(
      'strategy-continuity-terminalize:' ||
      p_league_round_id::text,
      0
    )
  );

  select
    lr.league_id,
    lr.status,
    fr.official_match_set_version

  into
    v_league_id,
    v_round_status,
    v_match_set_version

  from public.league_rounds lr

  join public.fantagol_rounds fr
    on fr.id = lr.fantagol_round_id

  where lr.id = p_league_round_id
    and lr.enabled = true

  for update of lr;

  if not found then
    raise exception using
      errcode = 'P0001',
      message = 'STRATEGY_CONTINUITY_ROUND_NOT_FOUND';
  end if;

  if v_round_status not in (
    'predictions_locked',
    'live',
    'waiting_postponed',
    'final_calculable',
    'scoring',
    'official',
    'recalculated',
    'archived'
  ) then
    raise exception using
      errcode = 'P0001',
      message = 'STRATEGY_CONTINUITY_ROUND_NOT_CLOSED',
      detail = format(
        'round_status=%s',
        v_round_status
      );
  end if;

  if v_match_set_version is null then
    raise exception using
      errcode = 'P0001',
      message = 'STRATEGY_CONTINUITY_MATCH_SET_MISSING';
  end if;

  for v_item in
    with complete_members as (
      select
        lm.id as league_member_id

      from public.league_members lm

      join public.predictions p
        on p.league_member_id = lm.id
       and p.league_round_id = p_league_round_id
       and p.submitted_version is not null
       and p.official_submitted_at is not null
       and p.status in (
         'submitted',
         'locked'
       )

      where lm.league_id = v_league_id
        and lm.status = 'active'

      group by lm.id

      having count(*) = 10
    ),

    sides as (
      select
        lf.id as league_fixture_id,
        lf.mode,
        lf.home_member_id as league_member_id

      from public.league_fixtures lf

      join complete_members cm
        on cm.league_member_id =
           lf.home_member_id

      where lf.league_round_id =
            p_league_round_id
        and lf.schedule_version_id =
            p_schedule_version_id
        and lf.mode in (
          'fantacalcio',
          'one_to_one'
        )
        and lf.is_bye = false

      union all

      select
        lf.id,
        lf.mode,
        lf.away_member_id

      from public.league_fixtures lf

      join complete_members cm
        on cm.league_member_id =
           lf.away_member_id

      where lf.league_round_id =
            p_league_round_id
        and lf.schedule_version_id =
            p_schedule_version_id
        and lf.mode in (
          'fantacalcio',
          'one_to_one'
        )
        and lf.is_bye = false
        and lf.away_member_id is not null
    )

    select *
    from sides
    order by
      mode,
      league_fixture_id,
      league_member_id

  loop
    v_expected := v_expected + 1;

    select s.*
    into v_strategy

    from public.strategies s

    where s.league_fixture_id =
          v_item.league_fixture_id
      and s.league_member_id =
          v_item.league_member_id
      and s.league_round_id =
          p_league_round_id

    for update;

    if not found then
      raise exception using
        errcode = 'P0001',
        message = 'STRATEGY_CONTINUITY_WORKSPACE_MISSING',
        detail = format(
          'league_round_id=%s fixture=%s member=%s mode=%s',
          p_league_round_id,
          v_item.league_fixture_id,
          v_item.league_member_id,
          v_item.mode
        );
    end if;

    if v_strategy.status = 'locked' then
      if v_strategy.submitted_version is null then
        raise exception using
          errcode = 'P0001',
          message = 'STRATEGY_CONTINUITY_LOCKED_WITHOUT_OFFICIAL';
      end if;

      v_terminal := v_terminal + 1;
      continue;
    end if;

    if v_strategy.status = 'void' then
      raise exception using
        errcode = 'P0001',
        message = 'STRATEGY_CONTINUITY_UNEXPECTED_VOID',
        detail = format(
          'strategy_id=%s member=%s mode=%s',
          v_strategy.id,
          v_item.league_member_id,
          v_item.mode
        );
    end if;

    if v_strategy.submitted_version is not null then

      select sv.payload
      into v_payload

      from public.strategy_versions sv

      where sv.strategy_id =
            v_strategy.id
        and sv.version =
            v_strategy.submitted_version;

      if v_payload is null then
        raise exception using
          errcode = 'P0001',
          message = 'STRATEGY_CONTINUITY_OFFICIAL_VERSION_MISSING',
          detail = format(
            'strategy_id=%s submitted_version=%s',
            v_strategy.id,
            v_strategy.submitted_version
          );
      end if;

      perform public.validate_strategy_submission_payload(
        v_item.mode,
        v_payload,
        p_league_round_id
      );

      v_locked_version :=
        v_strategy.version + 1;

      insert into public.strategy_versions (
        strategy_id,
        version,
        payload,
        status,
        source,
        changed_by_user_id,
        changed_by_member_id,
        changed_at,
        metadata
      )
      values (
        v_strategy.id,
        v_locked_version,
        v_payload,
        'locked',
        v_strategy.source,
        null,
        null,
        v_now,
        jsonb_build_object(
          'operation',
          'continuity_restore_official_and_lock',
          'mode',
          v_item.mode,
          'schema_version',
          case
            when jsonb_typeof(
              v_payload -> 'schema_version'
            ) = 'number'
            then (
              v_payload ->> 'schema_version'
            )::integer
            else null
          end,
          'match_set_version',
          v_match_set_version,
          'official_submitted_version',
          v_strategy.submitted_version,
          'workspace_source_version',
          v_strategy.version,
          'league_round_id',
          p_league_round_id,
          'league_fixture_id',
          v_item.league_fixture_id
        )
      );

      update public.strategies s
      set
        status = 'locked',
        version = v_locked_version,
        locked_at = v_now
      where s.id = v_strategy.id;

      v_locked := v_locked + 1;
      v_restored := v_restored + 1;

      continue;
    end if;

    select sv.payload
    into v_payload

    from public.strategy_versions sv

    where sv.strategy_id =
          v_strategy.id
      and sv.version =
          v_strategy.version;

    if v_payload is null then
      raise exception using
        errcode = 'P0001',
        message = 'STRATEGY_CONTINUITY_WORKSPACE_VERSION_MISSING',
        detail = format(
          'strategy_id=%s workspace_version=%s',
          v_strategy.id,
          v_strategy.version
        );
    end if;

    begin
      perform public.validate_strategy_submission_payload(
        v_item.mode,
        v_payload,
        p_league_round_id
      );
    exception
      when sqlstate 'P0001' then
        raise exception using
          errcode = 'P0001',
          message = 'STRATEGY_CONTINUITY_WORKSPACE_INVALID',
          detail = format(
            'strategy_id=%s member=%s mode=%s validation_error=%s',
            v_strategy.id,
            v_item.league_member_id,
            v_item.mode,
            sqlerrm
          );
    end;

    v_submission_version :=
      v_strategy.version + 1;

    v_locked_version :=
      v_strategy.version + 2;

    insert into public.strategy_versions (
      strategy_id,
      version,
      payload,
      status,
      source,
      changed_by_user_id,
      changed_by_member_id,
      changed_at,
      metadata
    )
    values (
      v_strategy.id,
      v_submission_version,
      v_payload,
      'submitted',
      v_strategy.source,
      null,
      null,
      v_now,
      jsonb_build_object(
        'operation',
        'continuity_auto_submit_complete_workspace',
        'mode',
        v_item.mode,
        'schema_version',
        case
          when jsonb_typeof(
            v_payload -> 'schema_version'
          ) = 'number'
          then (
            v_payload ->> 'schema_version'
          )::integer
          else null
        end,
        'match_set_version',
        v_match_set_version,
        'workspace_source_version',
        v_strategy.version,
        'official_submitted_version',
        v_submission_version,
        'league_round_id',
        p_league_round_id,
        'league_fixture_id',
        v_item.league_fixture_id
      )
    );

    insert into public.strategy_versions (
      strategy_id,
      version,
      payload,
      status,
      source,
      changed_by_user_id,
      changed_by_member_id,
      changed_at,
      metadata
    )
    values (
      v_strategy.id,
      v_locked_version,
      v_payload,
      'locked',
      v_strategy.source,
      null,
      null,
      v_now,
      jsonb_build_object(
        'operation',
        'continuity_lock_auto_submitted_strategy',
        'mode',
        v_item.mode,
        'schema_version',
        case
          when jsonb_typeof(
            v_payload -> 'schema_version'
          ) = 'number'
          then (
            v_payload ->> 'schema_version'
          )::integer
          else null
        end,
        'match_set_version',
        v_match_set_version,
        'official_submitted_version',
        v_submission_version,
        'league_round_id',
        p_league_round_id,
        'league_fixture_id',
        v_item.league_fixture_id
      )
    );

    update public.strategies s
    set
      status = 'locked',
      version = v_locked_version,
      submitted_version = v_submission_version,
      submitted_at = v_now,
      official_submitted_at = v_now,
      locked_at = v_now
    where s.id = v_strategy.id;

    v_auto_submitted :=
      v_auto_submitted + 1;

    v_locked :=
      v_locked + 1;
  end loop;

  return query
  select
    p_league_round_id,
    v_expected,
    v_locked,
    v_restored,
    v_auto_submitted,
    v_terminal,
    v_now;
end;
$function$;

create or replace function public.reconcile_schedule_strategy_continuity_internal(
  p_league_id uuid,
  p_schedule_version_id uuid
)
returns table (
  league_round_id uuid,
  eligible_member_mode_count integer,
  preserved_official_count integer,
  preserved_complete_workspace_count integer,
  created_default_count integer,
  replaced_incomplete_count integer,
  rebound_fixture_count integer,
  skipped_without_predictions_count integer,
  skipped_bye_count integer,
  expected_strategy_side_count integer,
  terminal_strategy_side_count integer,
  breach_count integer
)
language plpgsql
security definer
set search_path = public, pg_temp
as $function$
declare
  v_schedule public.league_schedule_versions%rowtype;
  v_round record;
  v_materialized record;
  v_assertion record;
begin
  if p_league_id is null then
    raise exception using
      errcode = 'P0001',
      message = 'STRATEGY_CONTINUITY_LEAGUE_REQUIRED';
  end if;

  if p_schedule_version_id is null then
    raise exception using
      errcode = 'P0001',
      message = 'STRATEGY_CONTINUITY_SCHEDULE_REQUIRED';
  end if;

  perform pg_advisory_xact_lock(
    hashtextextended(
      'strategy-schedule-continuity:' || p_league_id::text,
      0
    )
  );

  select lsv.*
  into v_schedule
  from public.league_schedule_versions lsv
  where lsv.id = p_schedule_version_id
    and lsv.league_id = p_league_id;

  if not found then
    raise exception using
      errcode = 'P0001',
      message = 'STRATEGY_CONTINUITY_SCHEDULE_NOT_FOUND';
  end if;

  if v_schedule.active is not true
     or not exists (
       select 1
       from public.league_schedule_versions current_lsv
       where current_lsv.league_id = p_league_id
         and current_lsv.id = p_schedule_version_id
         and current_lsv.active = true
     ) then
    return;
  end if;

  for v_round in
    select distinct
      lr.id
    from public.league_rounds lr
    join public.league_fixtures lf
      on lf.league_round_id = lr.id
     and lf.schedule_version_id = p_schedule_version_id
    where lr.league_id = p_league_id
      and lr.enabled = true
    order by lr.id
  loop

    select *
    into v_materialized
    from public.materialize_round_strategy_defaults_rpc(
      v_round.id
    );

    if exists (
      select 1
      from public.league_rounds lr
      where lr.id = v_round.id
        and lr.status in (
          'predictions_locked',
          'live',
          'waiting_postponed',
          'final_calculable',
          'scoring',
          'official',
          'recalculated',
          'archived'
        )
    ) then
      perform 1
      from public.terminalize_closed_round_strategy_continuity_internal(
        v_round.id,
        p_schedule_version_id
      );
    end if;

    select *
    into v_assertion
    from public.assert_round_strategy_continuity_internal(
      v_round.id,
      p_schedule_version_id
    );

    return query
    select
      v_round.id,

      coalesce(
        v_materialized.eligible_member_mode_count,
        0
      ),

      coalesce(
        v_materialized.preserved_official_count,
        0
      ),

      coalesce(
        v_materialized.preserved_complete_workspace_count,
        0
      ),

      coalesce(
        v_materialized.created_default_count,
        0
      ),

      coalesce(
        v_materialized.replaced_incomplete_count,
        0
      ),

      coalesce(
        v_materialized.rebound_fixture_count,
        0
      ),

      coalesce(
        v_materialized.skipped_without_predictions_count,
        0
      ),

      coalesce(
        v_materialized.skipped_bye_count,
        0
      ),

      coalesce(
        v_assertion.expected_strategy_side_count,
        0
      ),

      coalesce(
        v_assertion.terminal_strategy_side_count,
        0
      ),

      coalesce(
        v_assertion.breach_count,
        0
      );
  end loop;
end;
$function$;


create or replace function public.enforce_schedule_strategy_continuity()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $function$
begin
  if new.active is not true then
    return new;
  end if;

  if not exists (
    select 1
    from public.league_schedule_versions lsv
    where lsv.id = new.id
      and lsv.league_id = new.league_id
      and lsv.active = true
  ) then
    return new;
  end if;

  perform 1
  from public.reconcile_schedule_strategy_continuity_internal(
    new.league_id,
    new.id
  );

  return new;
end;
$function$;


drop trigger if exists enforce_schedule_strategy_continuity
on public.league_schedule_versions;


create constraint trigger enforce_schedule_strategy_continuity
after insert or update
on public.league_schedule_versions
deferrable initially deferred
for each row
execute function public.enforce_schedule_strategy_continuity();


revoke all
on function public.terminalize_closed_round_strategy_continuity_internal(uuid, uuid)
from public, anon, authenticated;

grant execute
on function public.terminalize_closed_round_strategy_continuity_internal(uuid, uuid)
to service_role;

revoke all
on function public.assert_round_strategy_continuity_internal(uuid, uuid)
from public, anon, authenticated;


revoke all
on function public.reconcile_schedule_strategy_continuity_internal(uuid, uuid)
from public, anon, authenticated;


revoke all
on function public.enforce_schedule_strategy_continuity()
from public, anon, authenticated;


grant execute
on function public.assert_round_strategy_continuity_internal(uuid, uuid)
to service_role;


grant execute
on function public.reconcile_schedule_strategy_continuity_internal(uuid, uuid)
to service_role;


comment on function public.assert_round_strategy_continuity_internal(uuid, uuid)
is
'Hard Strategy continuity invariant for one League Round and Schedule Version. Every active non-BYE fixture side belonging to a member with ten official Predictions must resolve to a submitted/locked Strategy and immutable submitted Strategy Version.';


comment on function public.reconcile_schedule_strategy_continuity_internal(uuid, uuid)
is
'Reconciles Strategy state after an active League Schedule version is materialized. Reuses the canonical migration-198 default/rebind authority and then enforces a fail-closed continuity invariant.';


comment on function public.enforce_schedule_strategy_continuity()
is
'Deferred active-schedule continuity boundary. Runs after fixture generation but before transaction commit so schedule regeneration cannot commit while complete Prediction members lack terminal current-fixture Strategies.';