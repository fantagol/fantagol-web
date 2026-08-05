-- ============================================================================
-- FANTAGOL
-- Migration 198
-- Strategy Default Fallback and Availability Contract
--
-- Certified aggregate alignment:
--
-- - strategies is the lifecycle aggregate;
-- - mode is inherited from league_fixtures.mode;
-- - strategies has no payload and no strategy_type column;
-- - workspace and official payloads live only in strategy_versions;
-- - one Strategy aggregate is identified by league_fixture_id +
--   league_member_id;
-- - official Prediction participation is required before any fallback;
-- - BYE fixtures never require or receive a Strategy;
-- - explicit official Strategy remains authoritative;
-- - complete draft workspace remains authoritative and is auto-submitted by
--   the certified lock engine;
-- - missing or incomplete workspace receives the canonical default only as
--   the final fallback.
-- ============================================================================

begin;

-- ============================================================================
-- 1. PRESERVE THE CERTIFIED LOCK IMPLEMENTATION
-- ============================================================================

do $migration$
begin
  if to_regprocedure(
       'public.lock_round_strategies_pre_default_198_rpc(uuid)'
     ) is null then

    if to_regprocedure(
         'public.lock_round_strategies_rpc(uuid)'
       ) is null then
      raise exception using
        errcode = 'P0001',
        message = 'LOCK_ROUND_STRATEGIES_RPC_NOT_FOUND';
    end if;

    alter function public.lock_round_strategies_rpc(uuid)
      rename to lock_round_strategies_pre_default_198_rpc;
  end if;
end;
$migration$;

-- ============================================================================
-- 2. CANONICAL DEFAULT PAYLOAD BUILDER
-- ============================================================================

create or replace function public.build_canonical_default_strategy_payload(
  p_league_round_id uuid,
  p_mode text
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $function$
declare
  v_fantagol_round_id uuid;
  v_match_ids uuid[];
begin
  if p_league_round_id is null then
    raise exception using
      errcode = 'P0001',
      message = 'STRATEGY_ROUND_REQUIRED';
  end if;

  if p_mode not in ('fantacalcio', 'one_to_one') then
    raise exception using
      errcode = 'P0001',
      message = 'STRATEGY_MODE_INVALID';
  end if;

  select lr.fantagol_round_id
  into v_fantagol_round_id
  from public.league_rounds lr
  where lr.id = p_league_round_id
    and lr.enabled = true;

  if not found then
    raise exception using
      errcode = 'P0001',
      message = 'STRATEGY_ROUND_NOT_FOUND';
  end if;

  select array_agg(
    frm.match_id
    order by frm.slot_number
  )
  into v_match_ids
  from public.fantagol_round_matches frm
  where frm.fantagol_round_id = v_fantagol_round_id
    and frm.required = true
    and frm.removed_at is null;

  if coalesce(cardinality(v_match_ids), 0) <> 10 then
    raise exception using
      errcode = 'P0001',
      message = 'STRATEGY_DEFAULT_MATCH_SET_INVALID',
      detail = format(
        'league_round_id=%s required_match_count=%s',
        p_league_round_id,
        coalesce(cardinality(v_match_ids), 0)
      );
  end if;

  if p_mode = 'fantacalcio' then
    return jsonb_build_object(
      'schema_version',
      1,
      'allocations',
      (
        select jsonb_agg(
          jsonb_build_object(
            'match_id',
            ordered_match.match_id,
            'department',
            case
              when ordered_match.ordinality <= 5
                then 'attack'
              else 'defense'
            end
          )
          order by ordered_match.ordinality
        )
        from unnest(v_match_ids)
          with ordinality as ordered_match(
            match_id,
            ordinality
          )
      )
    );
  end if;

  return jsonb_build_object(
    'schema_version',
    1,
    'pairings',
    (
      select jsonb_agg(
        jsonb_build_object(
          'position',
          ordered_match.ordinality,
          'own_match_id',
          ordered_match.match_id,
          'opponent_match_id',
          ordered_match.match_id
        )
        order by ordered_match.ordinality
      )
      from unnest(v_match_ids)
        with ordinality as ordered_match(
          match_id,
          ordinality
        )
    )
  );
end;
$function$;

comment on function public.build_canonical_default_strategy_payload(
  uuid,
  text
) is
'Builds the deterministic schema_version 1 Strategy fallback from the ordered official ten-match set: slots 1-5 Attack and 6-10 Defense for Fantacalcio; identity pairings 1-to-1 through 10-to-10 for One-to-One.';

revoke all
on function public.build_canonical_default_strategy_payload(
  uuid,
  text
)
from public;

revoke all
on function public.build_canonical_default_strategy_payload(
  uuid,
  text
)
from anon;

revoke all
on function public.build_canonical_default_strategy_payload(
  uuid,
  text
)
from authenticated;

grant execute
on function public.build_canonical_default_strategy_payload(
  uuid,
  text
)
to service_role;

-- ============================================================================
-- 3. MATERIALIZE ELIGIBLE DEFAULT WORKSPACES
-- ============================================================================

create or replace function public.materialize_round_strategy_defaults_rpc(
  p_league_round_id uuid
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
  materialized_at timestamptz
)
language plpgsql
security definer
set search_path = public
as $function$
declare
  v_league_id uuid;
  v_fantagol_round_id uuid;
  v_match_set_version integer;
  v_required_prediction_count integer;
  v_now timestamptz := clock_timestamp();

  v_item record;
  v_strategy public.strategies%rowtype;

  v_official_prediction_count integer;
  v_workspace_payload jsonb;
  v_default_payload jsonb;
  v_workspace_complete boolean;
  v_next_version integer;

  v_eligible_count integer := 0;
  v_preserved_official_count integer := 0;
  v_preserved_complete_count integer := 0;
  v_created_count integer := 0;
  v_replaced_count integer := 0;
  v_rebound_count integer := 0;
  v_skipped_predictions_count integer := 0;
  v_skipped_bye_count integer := 0;
begin
  if p_league_round_id is null then
    raise exception using
      errcode = 'P0001',
      message = 'STRATEGY_ROUND_REQUIRED';
  end if;

  select
    lr.league_id,
    lr.fantagol_round_id,
    fr.official_match_set_version
  into
    v_league_id,
    v_fantagol_round_id,
    v_match_set_version
  from public.league_rounds lr
  join public.fantagol_rounds fr
    on fr.id = lr.fantagol_round_id
  where lr.id = p_league_round_id
    and lr.enabled = true;

  if not found then
    raise exception using
      errcode = 'P0001',
      message = 'STRATEGY_ROUND_NOT_FOUND';
  end if;

  if v_match_set_version is null then
    raise exception using
      errcode = 'P0001',
      message = 'STRATEGY_OFFICIAL_MATCH_SET_NOT_FOUND';
  end if;

  select count(*)::integer
  into v_required_prediction_count
  from public.fantagol_round_matches frm
  where frm.fantagol_round_id = v_fantagol_round_id
    and frm.required = true
    and frm.removed_at is null;

  if v_required_prediction_count <> 10 then
    raise exception using
      errcode = 'P0001',
      message = 'STRATEGY_DEFAULT_MATCH_SET_INVALID',
      detail = format(
        'league_round_id=%s required_match_count=%s',
        p_league_round_id,
        v_required_prediction_count
      );
  end if;

  perform pg_advisory_xact_lock(
    hashtextextended(
      'strategy-default-fallback:' ||
      p_league_round_id::text,
      0
    )
  );

  for v_item in
    with active_fixtures as (
      select
        lf.id as league_fixture_id,
        lf.mode,
        lf.is_bye,
        lf.home_member_id,
        lf.away_member_id
      from public.league_fixtures lf
      join public.league_schedule_versions lsv
        on lsv.id = lf.schedule_version_id
       and lsv.active = true
      where lf.league_id = v_league_id
        and lf.league_round_id = p_league_round_id
        and lf.mode in (
          'fantacalcio',
          'one_to_one'
        )
    ),
    fixture_members as (
      select
        af.league_fixture_id,
        af.mode,
        af.is_bye,
        af.home_member_id as league_member_id
      from active_fixtures af

      union all

      select
        af.league_fixture_id,
        af.mode,
        af.is_bye,
        af.away_member_id as league_member_id
      from active_fixtures af
      where af.away_member_id is not null
    )
    select
      fm.league_fixture_id,
      fm.mode,
      fm.is_bye,
      fm.league_member_id,
      lm.user_id
    from fixture_members fm
    join public.league_members lm
      on lm.id = fm.league_member_id
     and lm.league_id = v_league_id
     and lm.status = 'active'
    order by
      fm.mode,
      fm.league_fixture_id,
      fm.league_member_id
  loop
    if v_item.is_bye then
      v_skipped_bye_count :=
        v_skipped_bye_count + 1;

      continue;
    end if;

    v_eligible_count :=
      v_eligible_count + 1;

    -- ------------------------------------------------------------------------
    -- A fallback exists only for a member who officially participated by
    -- submitting all ten required Predictions.
    -- ------------------------------------------------------------------------

    select count(*)::integer
    into v_official_prediction_count
    from public.predictions p
    join public.fantagol_round_matches frm
      on frm.fantagol_round_id =
         v_fantagol_round_id
     and frm.match_id = p.match_id
     and frm.required = true
     and frm.removed_at is null
    where p.league_round_id =
          p_league_round_id
      and p.league_member_id =
          v_item.league_member_id
      and p.submitted_version is not null
      and p.official_submitted_at is not null
      and p.home_prediction is not null
      and p.away_prediction is not null
      and p.status in (
        'submitted',
        'locked'
      );

    if v_official_prediction_count <>
       v_required_prediction_count then

      v_skipped_predictions_count :=
        v_skipped_predictions_count + 1;

      continue;
    end if;

    -- ------------------------------------------------------------------------
    -- First resolve the aggregate already attached to the active fixture.
    -- ------------------------------------------------------------------------

    select s.*
    into v_strategy
    from public.strategies s
    where s.league_fixture_id =
          v_item.league_fixture_id
      and s.league_member_id =
          v_item.league_member_id
    for update;

    -- ------------------------------------------------------------------------
    -- If the schedule was regenerated before the first round, preserve the
    -- latest aggregate belonging to the same round, member and mode.
    --
    -- Opponent changes do not invalidate the Strategy. Only a BYE removes the
    -- requirement, and BYEs were already excluded above.
    -- ------------------------------------------------------------------------

    if not found then
      select s.*
      into v_strategy
      from public.strategies s
      join public.league_fixtures historical_fixture
        on historical_fixture.id =
           s.league_fixture_id
      where s.league_round_id =
            p_league_round_id
        and s.league_member_id =
            v_item.league_member_id
        and historical_fixture.mode =
            v_item.mode
      order by
        s.updated_at desc,
        s.created_at desc,
        s.id desc
      limit 1
      for update of s;

      if found then
        update public.strategies s
        set
          league_fixture_id =
            v_item.league_fixture_id
        where s.id = v_strategy.id
        returning s.*
        into v_strategy;

        v_rebound_count :=
          v_rebound_count + 1;
      end if;
    end if;

    if found then
      -- Explicit official Strategy is always authoritative.
      if v_strategy.submitted_version is not null then
        v_preserved_official_count :=
          v_preserved_official_count + 1;

        continue;
      end if;

      -- Current workspace payload is the immutable version referenced by
      -- strategies.version.
      select sv.payload
      into v_workspace_payload
      from public.strategy_versions sv
      where sv.strategy_id =
            v_strategy.id
        and sv.version =
            v_strategy.version;

      v_workspace_complete := false;

      if found then
        begin
          perform public.validate_strategy_submission_payload(
            v_item.mode,
            v_workspace_payload,
            p_league_round_id
          );

          v_workspace_complete := true;
        exception
          when others then
            v_workspace_complete := false;
        end;
      end if;

      -- A complete draft is preserved and will be auto-submitted by the
      -- certified lock implementation.
      if v_workspace_complete then
        v_preserved_complete_count :=
          v_preserved_complete_count + 1;

        continue;
      end if;

      -- Missing or incomplete workspace becomes the deterministic final
      -- fallback. Existing immutable history remains untouched.
      v_default_payload :=
        public.build_canonical_default_strategy_payload(
          p_league_round_id,
          v_item.mode
        );

      perform public.validate_strategy_submission_payload(
        v_item.mode,
        v_default_payload,
        p_league_round_id
      );

      v_next_version :=
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
        v_next_version,
        v_default_payload,
        'draft',
        'standard',
        null,
        null,
        v_now,
        jsonb_build_object(
          'operation',
          'canonical_default_fallback_materialized',
          'reason',
          'official_predictions_present_incomplete_or_missing_workspace',
          'mode',
          v_item.mode,
          'schema_version',
          1,
          'match_set_version',
          v_match_set_version,
          'league_id',
          v_league_id,
          'league_round_id',
          p_league_round_id,
          'league_fixture_id',
          v_item.league_fixture_id,
          'replaced_workspace_version',
          v_strategy.version
        )
      );

      update public.strategies s
      set
        league_fixture_id =
          v_item.league_fixture_id,
        status =
          'draft',
        source =
          'standard',
        version =
          v_next_version,
        submitted_version =
          null,
        submitted_at =
          null,
        official_submitted_at =
          null,
        locked_at =
          null
      where s.id = v_strategy.id;

      v_replaced_count :=
        v_replaced_count + 1;

      continue;
    end if;

    -- ------------------------------------------------------------------------
    -- No aggregate exists: create lifecycle aggregate first, then append the
    -- immutable default workspace version.
    -- ------------------------------------------------------------------------

    v_default_payload :=
      public.build_canonical_default_strategy_payload(
        p_league_round_id,
        v_item.mode
      );

    perform public.validate_strategy_submission_payload(
      v_item.mode,
      v_default_payload,
      p_league_round_id
    );

    insert into public.strategies (
      league_id,
      league_round_id,
      league_member_id,
      user_id,
      league_fixture_id,
      status,
      source,
      version
    )
    values (
      v_league_id,
      p_league_round_id,
      v_item.league_member_id,
      v_item.user_id,
      v_item.league_fixture_id,
      'draft',
      'standard',
      1
    )
    returning *
    into v_strategy;

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
      1,
      v_default_payload,
      'draft',
      'standard',
      null,
      null,
      v_now,
      jsonb_build_object(
        'operation',
        'canonical_default_fallback_materialized',
        'reason',
        'official_predictions_present_strategy_missing',
        'mode',
        v_item.mode,
        'schema_version',
        1,
        'match_set_version',
        v_match_set_version,
        'league_id',
        v_league_id,
        'league_round_id',
        p_league_round_id,
        'league_fixture_id',
        v_item.league_fixture_id
      )
    );

    v_created_count :=
      v_created_count + 1;
  end loop;

  return query
  select
    p_league_round_id,
    v_eligible_count,
    v_preserved_official_count,
    v_preserved_complete_count,
    v_created_count,
    v_replaced_count,
    v_rebound_count,
    v_skipped_predictions_count,
    v_skipped_bye_count,
    v_now;
end;
$function$;

comment on function public.materialize_round_strategy_defaults_rpc(
  uuid
) is
'Immediately before Strategy lock, materializes deterministic complete fallback workspaces only for active non-BYE fixture members with all ten official Predictions. Explicit submissions and complete drafts are preserved. Payloads are stored exclusively in immutable strategy_versions.';

revoke all
on function public.materialize_round_strategy_defaults_rpc(
  uuid
)
from public;

revoke all
on function public.materialize_round_strategy_defaults_rpc(
  uuid
)
from anon;

revoke all
on function public.materialize_round_strategy_defaults_rpc(
  uuid
)
from authenticated;

grant execute
on function public.materialize_round_strategy_defaults_rpc(
  uuid
)
to service_role;

-- ============================================================================
-- 4. CERTIFIED LOCK WRAPPER
-- ============================================================================

create or replace function public.lock_round_strategies_rpc(
  p_league_round_id uuid
)
returns table (
  league_round_id uuid,
  expected_strategy_count integer,
  locked_strategy_count integer,
  restored_official_strategy_count integer,
  auto_submitted_strategy_count integer,
  voided_strategy_count integer,
  missing_strategy_count integer,
  skipped_bye_fixture_count integer,
  already_terminal_strategy_count integer,
  locked_at timestamptz
)
language plpgsql
security definer
set search_path = public
as $function$
begin
  perform public.materialize_round_strategy_defaults_rpc(
    p_league_round_id
  );

  return query
  select *
  from public.lock_round_strategies_pre_default_198_rpc(
    p_league_round_id
  );
end;
$function$;

comment on function public.lock_round_strategies_rpc(
  uuid
) is
'Locks all active non-BYE round Strategies. Before delegating to the certified Strategy Lock Engine, it guarantees a canonical fallback only for members with all ten official Predictions. Members without official Predictions remain genuinely missing.';

revoke all
on function public.lock_round_strategies_rpc(
  uuid
)
from public;

revoke all
on function public.lock_round_strategies_rpc(
  uuid
)
from anon;

revoke all
on function public.lock_round_strategies_rpc(
  uuid
)
from authenticated;

grant execute
on function public.lock_round_strategies_rpc(
  uuid
)
to service_role;

-- Preserved implementation remains internal.
revoke all
on function public.lock_round_strategies_pre_default_198_rpc(
  uuid
)
from public;

revoke all
on function public.lock_round_strategies_pre_default_198_rpc(
  uuid
)
from anon;

revoke all
on function public.lock_round_strategies_pre_default_198_rpc(
  uuid
)
from authenticated;

grant execute
on function public.lock_round_strategies_pre_default_198_rpc(
  uuid
)
to service_role;

commit;