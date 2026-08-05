-- ============================================================================
-- FANTAGOL
-- Migration 198
-- Strategy Default Fallback and Availability Contract
--
-- Canonical rules:
--
-- 1. An explicit official Strategy remains authoritative.
-- 2. A complete saved workspace is auto-submitted by the existing lock engine.
-- 3. A missing or incomplete workspace receives the canonical default only when
--    the member officially submitted the complete Prediction set.
-- 4. A member without an official Prediction submission remains genuinely
--    absent and receives no Strategy fallback.
-- 5. A BYE never requires nor receives a Strategy.
-- 6. When a pre-deadline schedule is regenerated, an existing non-BYE Strategy
--    aggregate is rebound to the new active fixture without invalidating its
--    official payload solely because the opponent changed.
--
-- The existing certified lock implementation is preserved behind a wrapper.
-- ============================================================================

begin;

-- --------------------------------------------------------------------------
-- 1. Preserve the certified Strategy lock implementation.
-- --------------------------------------------------------------------------

do $migration$
begin
  if to_regprocedure(
       'public.lock_round_strategies_pre_default_198_rpc(uuid)'
     ) is null then

    if to_regprocedure(
         'public.lock_round_strategies_rpc(uuid)'
       ) is null then
      raise exception
        'LOCK_ROUND_STRATEGIES_RPC_NOT_FOUND';
    end if;

    alter function public.lock_round_strategies_rpc(uuid)
      rename to lock_round_strategies_pre_default_198_rpc;
  end if;
end;
$migration$;

-- --------------------------------------------------------------------------
-- 2. Build the canonical default payload from the official ordered Match Set.
-- --------------------------------------------------------------------------

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
  if p_mode not in ('fantacalcio', 'one_to_one') then
    raise exception using
      errcode = 'P0001',
      message = 'STRATEGY_MODE_INVALID';
  end if;

  select lr.fantagol_round_id
  into v_fantagol_round_id
  from public.league_rounds lr
  where lr.id = p_league_round_id;

  if not found then
    raise exception using
      errcode = 'P0001',
      message = 'LEAGUE_ROUND_NOT_FOUND';
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
            item.match_id,
            'department',
            case
              when item.ordinality <= 5 then 'attack'
              else 'defense'
            end
          )
          order by item.ordinality
        )
        from unnest(v_match_ids)
          with ordinality as item(
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
          item.ordinality,
          'own_match_id',
          item.match_id,
          'opponent_match_id',
          item.match_id
        )
        order by item.ordinality
      )
      from unnest(v_match_ids)
        with ordinality as item(
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
'Builds the deterministic schema_version 1 Strategy fallback from the official ordered ten-match set: slots 1-5 Attack and 6-10 Defense for Fantacalcio; identity matrix 1-to-1 through 10-to-10 for One-to-One.';

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

-- --------------------------------------------------------------------------
-- 3. Materialize missing or invalid fallback workspaces.
--
-- Participation is certified by a complete official Prediction snapshot:
-- every required match must have submitted_version and official_submitted_at.
-- Status may already be locked because Prediction locking precedes Strategy
-- locking in the runtime pipeline.
-- --------------------------------------------------------------------------

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
  where lr.id = p_league_round_id;

  if not found then
    raise exception using
      errcode = 'P0001',
      message = 'LEAGUE_ROUND_NOT_FOUND';
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
        af.away_member_id
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

    select s.*
    into v_strategy
    from public.strategies s
    where s.league_round_id =
          p_league_round_id
      and s.league_member_id =
          v_item.league_member_id
      and s.strategy_type =
          v_item.mode
    for update;

    if found then
      if v_strategy.league_fixture_id
         is distinct from
         v_item.league_fixture_id then

        update public.strategies s
        set
          league_fixture_id =
            v_item.league_fixture_id
        where s.id = v_strategy.id;

        v_strategy.league_fixture_id :=
          v_item.league_fixture_id;

        v_rebound_count :=
          v_rebound_count + 1;
      end if;

      if v_strategy.submitted_version
         is not null then

        v_preserved_official_count :=
          v_preserved_official_count + 1;

        continue;
      end if;

      v_workspace_complete := true;

      begin
        perform public.validate_strategy_submission_payload(
          v_item.mode,
          v_strategy.payload,
          p_league_round_id
        );
      exception
        when others then
          v_workspace_complete := false;
      end;

      if v_workspace_complete then
        v_preserved_complete_count :=
          v_preserved_complete_count + 1;

        continue;
      end if;

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
          'official_predictions_present_incomplete_strategy',
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
        payload =
          v_default_payload,
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
      strategy_type,
      payload,
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
      v_item.mode,
      v_default_payload,
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
'Materializes canonical Strategy defaults immediately before Strategy lock, exclusively for non-BYE active-fixture members with a complete official Prediction submission. Existing official Strategies and complete workspaces are preserved; incomplete or missing workspaces receive the deterministic fallback.';

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

-- --------------------------------------------------------------------------
-- 4. Certified wrapper.
--
-- First guarantee eligible fallback workspaces, then delegate all official
-- submission/restoration/locking behavior to the previously certified engine.
-- --------------------------------------------------------------------------

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
  perform
    public.materialize_round_strategy_defaults_rpc(
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
'Locks all active non-BYE round Strategies. Before delegating to the certified Strategy Lock Engine, it guarantees a canonical complete fallback only for members with a complete official Prediction submission. Members without official predictions remain missing.';

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