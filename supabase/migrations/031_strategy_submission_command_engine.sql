-- Migration 031: Strategy Submission Command Engine
-- Purpose:
--   - validate complete mode-specific Strategy payloads;
--   - promote the current private workspace to an immutable official snapshot;
--   - support idempotent submit and intelligent resubmission;
--   - preserve all earlier workspace and official versions.
--
-- Canonical payload contracts:
--
-- Fantacalcio:
-- {
--   "attack":  ["<match_uuid>", ... exactly 5 unique],
--   "defense": ["<match_uuid>", ... exactly 5 unique]
-- }
-- The two arrays must be disjoint and together cover the 10 official round matches.
--
-- One-to-One:
-- {
--   "matrix": [
--     {
--       "own_match_id": "<match_uuid>",
--       "opponent_match_id": "<match_uuid>"
--     },
--     ... exactly 10 pairings
--   ]
-- }
-- Each official round match must appear exactly once on each side.

begin;

-- ============================================================
-- 1. PURE SUBMISSION PAYLOAD VALIDATOR
-- ============================================================

create or replace function public.validate_strategy_submission_payload(
  p_mode text,
  p_payload jsonb,
  p_league_round_id uuid
)
returns void
language plpgsql
security definer
set search_path = public
as $function$
declare
  v_fantagol_round_id uuid;
  v_required_match_count integer;
  v_attack_count integer;
  v_defense_count integer;
  v_attack_distinct_count integer;
  v_defense_distinct_count integer;
  v_total_distinct_count integer;
  v_matrix_count integer;
  v_own_distinct_count integer;
  v_opponent_distinct_count integer;
  v_invalid_count integer;
begin
  if p_mode not in ('fantacalcio', 'one_to_one') then
    raise exception using
      errcode = 'P0001',
      message = 'STRATEGY_MODE_INVALID';
  end if;

  if p_payload is null or jsonb_typeof(p_payload) <> 'object' then
    raise exception using
      errcode = 'P0001',
      message = 'STRATEGY_PAYLOAD_INVALID';
  end if;

  select lr.fantagol_round_id
  into v_fantagol_round_id
  from public.league_rounds lr
  where lr.id = p_league_round_id;

  if v_fantagol_round_id is null then
    raise exception using
      errcode = 'P0001',
      message = 'STRATEGY_ROUND_NOT_FOUND';
  end if;

  select count(*)
  into v_required_match_count
  from public.fantagol_round_matches frm
  where frm.fantagol_round_id = v_fantagol_round_id
    and frm.required = true
    and frm.removed_at is null;

  if v_required_match_count <> 10 then
    raise exception using
      errcode = 'P0001',
      message = 'STRATEGY_MODE_REQUIRES_TEN_MATCHES',
      detail = format('required_match_count=%s', v_required_match_count);
  end if;

  if p_mode = 'fantacalcio' then
    if jsonb_typeof(p_payload -> 'attack') <> 'array'
       or jsonb_typeof(p_payload -> 'defense') <> 'array' then
      raise exception using
        errcode = 'P0001',
        message = 'FANTACALCIO_STRATEGY_STRUCTURE_INVALID';
    end if;

    select
      jsonb_array_length(p_payload -> 'attack'),
      jsonb_array_length(p_payload -> 'defense')
    into
      v_attack_count,
      v_defense_count;

    if v_attack_count <> 5 or v_defense_count <> 5 then
      raise exception using
        errcode = 'P0001',
        message = 'FANTACALCIO_STRATEGY_SPLIT_INVALID',
        detail = format(
          'attack_count=%s defense_count=%s',
          v_attack_count,
          v_defense_count
        );
    end if;

    begin
      with attack_ids as (
        select value #>> '{}' as match_id_text
        from jsonb_array_elements(p_payload -> 'attack')
      ),
      defense_ids as (
        select value #>> '{}' as match_id_text
        from jsonb_array_elements(p_payload -> 'defense')
      )
      select
        (select count(distinct match_id_text) from attack_ids),
        (select count(distinct match_id_text) from defense_ids),
        (
          select count(distinct match_id_text)
          from (
            select match_id_text from attack_ids
            union all
            select match_id_text from defense_ids
          ) all_ids
        )
      into
        v_attack_distinct_count,
        v_defense_distinct_count,
        v_total_distinct_count;
    exception
      when others then
        raise exception using
          errcode = 'P0001',
          message = 'FANTACALCIO_STRATEGY_MATCH_ID_INVALID';
    end;

    if v_attack_distinct_count <> 5
       or v_defense_distinct_count <> 5
       or v_total_distinct_count <> 10 then
      raise exception using
        errcode = 'P0001',
        message = 'FANTACALCIO_STRATEGY_DUPLICATE_MATCH';
    end if;

    begin
      with selected_ids as (
        select (value #>> '{}')::uuid as match_id
        from jsonb_array_elements(p_payload -> 'attack')

        union all

        select (value #>> '{}')::uuid as match_id
        from jsonb_array_elements(p_payload -> 'defense')
      )
      select count(*)
      into v_invalid_count
      from selected_ids si
      left join public.fantagol_round_matches frm
        on frm.fantagol_round_id = v_fantagol_round_id
       and frm.match_id = si.match_id
       and frm.required = true
       and frm.removed_at is null
      where frm.id is null;
    exception
      when invalid_text_representation then
        raise exception using
          errcode = 'P0001',
          message = 'FANTACALCIO_STRATEGY_MATCH_ID_INVALID';
    end;

    if v_invalid_count > 0 then
      raise exception using
        errcode = 'P0001',
        message = 'FANTACALCIO_STRATEGY_MATCH_NOT_IN_ROUND';
    end if;

  elsif p_mode = 'one_to_one' then
    if jsonb_typeof(p_payload -> 'matrix') <> 'array' then
      raise exception using
        errcode = 'P0001',
        message = 'ONE_TO_ONE_MATRIX_STRUCTURE_INVALID';
    end if;

    v_matrix_count := jsonb_array_length(p_payload -> 'matrix');

    if v_matrix_count <> 10 then
      raise exception using
        errcode = 'P0001',
        message = 'ONE_TO_ONE_MATRIX_COUNT_INVALID',
        detail = format('matrix_count=%s', v_matrix_count);
    end if;

    if exists (
      select 1
      from jsonb_array_elements(p_payload -> 'matrix') item
      where jsonb_typeof(item) <> 'object'
         or item ->> 'own_match_id' is null
         or item ->> 'opponent_match_id' is null
    ) then
      raise exception using
        errcode = 'P0001',
        message = 'ONE_TO_ONE_PAIRING_STRUCTURE_INVALID';
    end if;

    select
      count(distinct item ->> 'own_match_id'),
      count(distinct item ->> 'opponent_match_id')
    into
      v_own_distinct_count,
      v_opponent_distinct_count
    from jsonb_array_elements(p_payload -> 'matrix') item;

    if v_own_distinct_count <> 10 or v_opponent_distinct_count <> 10 then
      raise exception using
        errcode = 'P0001',
        message = 'ONE_TO_ONE_MATRIX_DUPLICATE_MATCH';
    end if;

    begin
      with matrix_ids as (
        select
          (item ->> 'own_match_id')::uuid as own_match_id,
          (item ->> 'opponent_match_id')::uuid as opponent_match_id
        from jsonb_array_elements(p_payload -> 'matrix') item
      ),
      all_ids as (
        select own_match_id as match_id from matrix_ids
        union all
        select opponent_match_id as match_id from matrix_ids
      )
      select count(*)
      into v_invalid_count
      from all_ids ai
      left join public.fantagol_round_matches frm
        on frm.fantagol_round_id = v_fantagol_round_id
       and frm.match_id = ai.match_id
       and frm.required = true
       and frm.removed_at is null
      where frm.id is null;
    exception
      when invalid_text_representation then
        raise exception using
          errcode = 'P0001',
          message = 'ONE_TO_ONE_MATRIX_MATCH_ID_INVALID';
    end;

    if v_invalid_count > 0 then
      raise exception using
        errcode = 'P0001',
        message = 'ONE_TO_ONE_MATRIX_MATCH_NOT_IN_ROUND';
    end if;
  end if;
end;
$function$;

comment on function public.validate_strategy_submission_payload(text, jsonb, uuid)
is 'Validates canonical complete Fantacalcio or One-to-One Strategy payloads against the official ten-match FantaGol Round.';


-- ============================================================
-- 2. SUBMIT / RESUBMIT CURRENT STRATEGY WORKSPACE
-- ============================================================

create or replace function public.submit_strategy_rpc(
  p_league_round_id uuid,
  p_mode text
)
returns table (
  strategy_id uuid,
  league_fixture_id uuid,
  mode text,
  workspace_version integer,
  submitted_version integer,
  official_submitted_at timestamptz,
  already_submitted boolean,
  has_unconfirmed_changes boolean
)
language plpgsql
security definer
set search_path = public
as $function$
declare
  v_now timestamptz := now();
  v_user_id uuid := auth.uid();

  v_league_id uuid;
  v_member_id uuid;
  v_round_status text;
  v_round_opens_at timestamptz;
  v_round_lock_at timestamptz;

  v_fixture_id uuid;
  v_fixture_mode text;
  v_fixture_is_bye boolean;

  v_strategy public.strategies%rowtype;
  v_workspace_payload jsonb;
  v_new_submitted_version integer;
begin
  if v_user_id is null then
    raise exception using
      errcode = 'P0001',
      message = 'USER_NOT_AUTHENTICATED';
  end if;

  if p_league_round_id is null then
    raise exception using
      errcode = 'P0001',
      message = 'STRATEGY_ROUND_REQUIRED';
  end if;

  if p_mode is null or p_mode not in ('fantacalcio', 'one_to_one') then
    raise exception using
      errcode = 'P0001',
      message = 'STRATEGY_MODE_INVALID';
  end if;

  select
    lr.league_id,
    lr.status,
    fr.opens_at,
    fr.lock_at
  into
    v_league_id,
    v_round_status,
    v_round_opens_at,
    v_round_lock_at
  from public.league_rounds lr
  join public.fantagol_rounds fr
    on fr.id = lr.fantagol_round_id
  where lr.id = p_league_round_id
    and lr.enabled = true
  for update of lr;

  if not found then
    raise exception using
      errcode = 'P0001',
      message = 'STRATEGY_ROUND_NOT_FOUND';
  end if;

  if v_round_status <> 'predictions_open'
     or v_now < v_round_opens_at
     or v_now >= v_round_lock_at then
    raise exception using
      errcode = 'P0001',
      message = 'STRATEGY_WINDOW_CLOSED';
  end if;

  select lm.id
  into v_member_id
  from public.league_members lm
  where lm.league_id = v_league_id
    and lm.user_id = v_user_id
    and lm.status = 'active'
  limit 1;

  if v_member_id is null then
    raise exception using
      errcode = 'P0001',
      message = 'STRATEGY_ACTIVE_MEMBERSHIP_REQUIRED';
  end if;

  perform pg_advisory_xact_lock(
    hashtextextended(
      'strategy-submit:'
      || p_league_round_id::text
      || ':'
      || v_member_id::text
      || ':'
      || p_mode,
      0
    )
  );

  select
    lf.id,
    lf.mode,
    lf.is_bye
  into
    v_fixture_id,
    v_fixture_mode,
    v_fixture_is_bye
  from public.league_fixtures lf
  join public.league_schedule_versions lsv
    on lsv.id = lf.schedule_version_id
   and lsv.active = true
  where lf.league_id = v_league_id
    and lf.league_round_id = p_league_round_id
    and lf.mode = p_mode
    and (
      lf.home_member_id = v_member_id
      or lf.away_member_id = v_member_id
    );

  if not found then
    raise exception using
      errcode = 'P0001',
      message = 'STRATEGY_ACTIVE_FIXTURE_NOT_FOUND';
  end if;

  if v_fixture_is_bye then
    raise exception using
      errcode = 'P0001',
      message = 'STRATEGY_NOT_REQUIRED_FOR_BYE';
  end if;

  select s.*
  into v_strategy
  from public.strategies s
  where s.league_fixture_id = v_fixture_id
    and s.league_member_id = v_member_id
  for update;

  if not found then
    raise exception using
      errcode = 'P0001',
      message = 'STRATEGY_WORKSPACE_NOT_FOUND';
  end if;

  if v_strategy.status in ('locked', 'void') then
    raise exception using
      errcode = 'P0001',
      message = 'STRATEGY_NOT_SUBMITTABLE';
  end if;

  if v_strategy.submitted_version is not null
     and v_strategy.submitted_version = v_strategy.version
     and v_strategy.status = 'submitted' then
    return query
    select
      v_strategy.id,
      v_fixture_id,
      v_fixture_mode,
      v_strategy.version,
      v_strategy.submitted_version,
      v_strategy.official_submitted_at,
      true,
      false;
    return;
  end if;

  select sv.payload
  into v_workspace_payload
  from public.strategy_versions sv
  where sv.strategy_id = v_strategy.id
    and sv.version = v_strategy.version;

  if v_workspace_payload is null then
    raise exception using
      errcode = 'P0001',
      message = 'STRATEGY_WORKSPACE_VERSION_NOT_FOUND';
  end if;

  perform public.validate_strategy_submission_payload(
    v_fixture_mode,
    v_workspace_payload,
    p_league_round_id
  );

  v_new_submitted_version := v_strategy.version + 1;

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
    v_new_submitted_version,
    v_workspace_payload,
    'submitted',
    v_strategy.source,
    v_user_id,
    v_member_id,
    v_now,
    jsonb_build_object(
      'operation',
      case
        when v_strategy.submitted_version is null then 'initial_submit'
        else 'resubmit'
      end,
      'mode', v_fixture_mode,
      'workspace_source_version', v_strategy.version,
      'official_submitted_version', v_new_submitted_version,
      'league_round_id', p_league_round_id,
      'league_fixture_id', v_fixture_id
    )
  );

  update public.strategies s
  set
    status = 'submitted',
    version = v_new_submitted_version,
    submitted_version = v_new_submitted_version,
    submitted_at = v_now,
    official_submitted_at = v_now
  where s.id = v_strategy.id
  returning s.*
  into v_strategy;

  return query
  select
    v_strategy.id,
    v_fixture_id,
    v_fixture_mode,
    v_strategy.version,
    v_strategy.submitted_version,
    v_strategy.official_submitted_at,
    false,
    false;
end;
$function$;

comment on function public.submit_strategy_rpc(uuid, text)
is 'Validates and atomically promotes the authenticated member current Strategy workspace to an immutable official submitted snapshot. Repeated submit without edits is idempotent.';

revoke all on function public.validate_strategy_submission_payload(text, jsonb, uuid)
  from public;
revoke all on function public.validate_strategy_submission_payload(text, jsonb, uuid)
  from anon;
revoke all on function public.validate_strategy_submission_payload(text, jsonb, uuid)
  from authenticated;
grant execute on function public.validate_strategy_submission_payload(text, jsonb, uuid)
  to service_role;

revoke all on function public.submit_strategy_rpc(uuid, text)
  from public;
revoke all on function public.submit_strategy_rpc(uuid, text)
  from anon;
revoke all on function public.submit_strategy_rpc(uuid, text)
  from service_role;
grant execute on function public.submit_strategy_rpc(uuid, text)
  to authenticated;

commit;
