-- Migration 032: Strategy Payload Contract v1
-- Purpose:
--   - freeze the canonical versioned JSON contract for Strategy payloads;
--   - update workspace autosave metadata with payload schema and Match Set version;
--   - replace submission validation for Fantacalcio allocations and One-to-One pairings;
--   - preserve the existing Strategy aggregate and versioning model.
--
-- Canonical Fantacalcio payload v1:
-- {
--   "schema_version": 1,
--   "allocations": [
--     { "match_id": "<uuid>", "department": "attack" | "defense" }
--   ]
-- }
--
-- Canonical One-to-One payload v1:
-- {
--   "schema_version": 1,
--   "pairings": [
--     {
--       "position": 1..10,
--       "own_match_id": "<uuid>",
--       "opponent_match_id": "<uuid>"
--     }
--   ]
-- }
--
-- Draft payloads may be structurally partial, but must declare schema_version = 1.
-- Complete mode-specific validation remains mandatory at submit.

begin;

-- ============================================================
-- 1. REPLACE WORKSPACE AUTOSAVE COMMAND
-- ============================================================

create or replace function public.save_strategy_draft_rpc(
  p_league_round_id uuid,
  p_mode text,
  p_payload jsonb
)
returns table (
  strategy_id uuid,
  league_fixture_id uuid,
  mode text,
  workspace_version integer,
  strategy_status text,
  submitted_version integer,
  has_unconfirmed_changes boolean,
  saved_at timestamptz
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
  v_match_set_version integer;

  v_fixture_id uuid;
  v_fixture_is_bye boolean;

  v_strategy public.strategies%rowtype;
  v_next_version integer;
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

  if p_payload is null or jsonb_typeof(p_payload) <> 'object' then
    raise exception using
      errcode = 'P0001',
      message = 'STRATEGY_PAYLOAD_INVALID';
  end if;

  if jsonb_typeof(p_payload -> 'schema_version') <> 'number'
     or (p_payload ->> 'schema_version')::integer <> 1 then
    raise exception using
      errcode = 'P0001',
      message = 'STRATEGY_PAYLOAD_SCHEMA_VERSION_INVALID';
  end if;

  -- Drafts may be incomplete, but present containers must use the canonical type.
  if p_mode = 'fantacalcio'
     and p_payload ? 'allocations'
     and jsonb_typeof(p_payload -> 'allocations') <> 'array' then
    raise exception using
      errcode = 'P0001',
      message = 'FANTACALCIO_STRATEGY_STRUCTURE_INVALID';
  end if;

  if p_mode = 'one_to_one'
     and p_payload ? 'pairings'
     and jsonb_typeof(p_payload -> 'pairings') <> 'array' then
    raise exception using
      errcode = 'P0001',
      message = 'ONE_TO_ONE_MATRIX_STRUCTURE_INVALID';
  end if;

  select
    lr.league_id,
    lr.status,
    fr.opens_at,
    fr.lock_at,
    fr.official_match_set_version
  into
    v_league_id,
    v_round_status,
    v_round_opens_at,
    v_round_lock_at,
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
      message = 'STRATEGY_ROUND_NOT_FOUND';
  end if;

  if v_match_set_version is null then
    raise exception using
      errcode = 'P0001',
      message = 'STRATEGY_OFFICIAL_MATCH_SET_NOT_FOUND';
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
      'strategy-save:'
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
    lf.is_bye
  into
    v_fixture_id,
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

  if found then
    if v_strategy.status in ('locked', 'void') then
      raise exception using
        errcode = 'P0001',
        message = 'STRATEGY_NOT_EDITABLE';
    end if;

    v_next_version := v_strategy.version + 1;

    update public.strategies s
    set
      status = 'draft',
      source = 'standard',
      version = v_next_version
    where s.id = v_strategy.id
    returning s.*
    into v_strategy;
  else
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
      v_member_id,
      v_user_id,
      v_fixture_id,
      'draft',
      'standard',
      1
    )
    returning *
    into v_strategy;

    v_next_version := 1;
  end if;

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
    p_payload,
    'draft',
    'standard',
    v_user_id,
    v_member_id,
    v_now,
    jsonb_build_object(
      'operation', 'workspace_save',
      'mode', p_mode,
      'schema_version', 1,
      'match_set_version', v_match_set_version,
      'league_round_id', p_league_round_id,
      'league_fixture_id', v_fixture_id,
      'official_submitted_version', v_strategy.submitted_version
    )
  );

  return query
  select
    v_strategy.id,
    v_fixture_id,
    p_mode,
    v_next_version,
    'draft'::text,
    v_strategy.submitted_version,
    (
      v_strategy.submitted_version is not null
      and v_strategy.submitted_version <> v_next_version
    ),
    v_now;
end;
$function$;

comment on function public.save_strategy_draft_rpc(uuid, text, jsonb)
is 'Autosaves a canonical schema_version 1 Strategy workspace and records the official Match Set version in immutable metadata. Draft mode payloads may be incomplete.';


-- ============================================================
-- 2. REPLACE COMPLETE SUBMISSION PAYLOAD VALIDATOR
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

  v_allocation_count integer;
  v_attack_count integer;
  v_defense_count integer;
  v_allocation_distinct_count integer;

  v_pairing_count integer;
  v_position_distinct_count integer;
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

  if jsonb_typeof(p_payload -> 'schema_version') <> 'number'
     or (p_payload ->> 'schema_version')::integer <> 1 then
    raise exception using
      errcode = 'P0001',
      message = 'STRATEGY_PAYLOAD_SCHEMA_VERSION_INVALID';
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
    if jsonb_typeof(p_payload -> 'allocations') <> 'array' then
      raise exception using
        errcode = 'P0001',
        message = 'FANTACALCIO_STRATEGY_STRUCTURE_INVALID';
    end if;

    v_allocation_count := jsonb_array_length(p_payload -> 'allocations');

    if v_allocation_count <> 10 then
      raise exception using
        errcode = 'P0001',
        message = 'FANTACALCIO_STRATEGY_ALLOCATION_COUNT_INVALID',
        detail = format('allocation_count=%s', v_allocation_count);
    end if;

    if exists (
      select 1
      from jsonb_array_elements(p_payload -> 'allocations') item
      where jsonb_typeof(item) <> 'object'
         or item ->> 'match_id' is null
         or item ->> 'department' is null
         or item ->> 'department' not in ('attack', 'defense')
    ) then
      raise exception using
        errcode = 'P0001',
        message = 'FANTACALCIO_STRATEGY_ALLOCATION_INVALID';
    end if;

    select
      count(*) filter (where item ->> 'department' = 'attack'),
      count(*) filter (where item ->> 'department' = 'defense'),
      count(distinct item ->> 'match_id')
    into
      v_attack_count,
      v_defense_count,
      v_allocation_distinct_count
    from jsonb_array_elements(p_payload -> 'allocations') item;

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

    if v_allocation_distinct_count <> 10 then
      raise exception using
        errcode = 'P0001',
        message = 'FANTACALCIO_STRATEGY_DUPLICATE_MATCH';
    end if;

    begin
      with allocation_ids as (
        select (item ->> 'match_id')::uuid as match_id
        from jsonb_array_elements(p_payload -> 'allocations') item
      )
      select count(*)
      into v_invalid_count
      from allocation_ids ai
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
          message = 'FANTACALCIO_STRATEGY_MATCH_ID_INVALID';
    end;

    if v_invalid_count > 0 then
      raise exception using
        errcode = 'P0001',
        message = 'FANTACALCIO_STRATEGY_MATCH_NOT_IN_ROUND';
    end if;

  elsif p_mode = 'one_to_one' then
    if jsonb_typeof(p_payload -> 'pairings') <> 'array' then
      raise exception using
        errcode = 'P0001',
        message = 'ONE_TO_ONE_MATRIX_STRUCTURE_INVALID';
    end if;

    v_pairing_count := jsonb_array_length(p_payload -> 'pairings');

    if v_pairing_count <> 10 then
      raise exception using
        errcode = 'P0001',
        message = 'ONE_TO_ONE_MATRIX_COUNT_INVALID',
        detail = format('pairing_count=%s', v_pairing_count);
    end if;

    if exists (
      select 1
      from jsonb_array_elements(p_payload -> 'pairings') item
      where jsonb_typeof(item) <> 'object'
         or item ->> 'position' is null
         or item ->> 'own_match_id' is null
         or item ->> 'opponent_match_id' is null
    ) then
      raise exception using
        errcode = 'P0001',
        message = 'ONE_TO_ONE_PAIRING_STRUCTURE_INVALID';
    end if;

    if exists (
      select 1
      from jsonb_array_elements(p_payload -> 'pairings') item
      where not ((item ->> 'position') ~ '^[0-9]+$')
    ) then
      raise exception using
        errcode = 'P0001',
        message = 'ONE_TO_ONE_PAIRING_POSITION_INVALID';
    end if;

    select
      count(distinct (item ->> 'position')::integer),
      count(distinct item ->> 'own_match_id'),
      count(distinct item ->> 'opponent_match_id')
    into
      v_position_distinct_count,
      v_own_distinct_count,
      v_opponent_distinct_count
    from jsonb_array_elements(p_payload -> 'pairings') item;

    if exists (
      select 1
      from jsonb_array_elements(p_payload -> 'pairings') item
      where (item ->> 'position')::integer < 1
         or (item ->> 'position')::integer > 10
    ) then
      raise exception using
        errcode = 'P0001',
        message = 'ONE_TO_ONE_PAIRING_POSITION_INVALID';
    end if;

    if v_position_distinct_count <> 10 then
      raise exception using
        errcode = 'P0001',
        message = 'ONE_TO_ONE_PAIRING_POSITION_DUPLICATE';
    end if;

    if v_own_distinct_count <> 10 or v_opponent_distinct_count <> 10 then
      raise exception using
        errcode = 'P0001',
        message = 'ONE_TO_ONE_MATRIX_DUPLICATE_MATCH';
    end if;

    begin
      with pairing_ids as (
        select
          (item ->> 'own_match_id')::uuid as own_match_id,
          (item ->> 'opponent_match_id')::uuid as opponent_match_id
        from jsonb_array_elements(p_payload -> 'pairings') item
      ),
      all_ids as (
        select own_match_id as match_id from pairing_ids
        union all
        select opponent_match_id as match_id from pairing_ids
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
is 'Validates canonical Strategy payload schema_version 1: ten Fantacalcio allocations or ten ordered One-to-One pairings against the official FantaGol Round Match Set.';


-- ============================================================
-- 3. REPLACE SUBMIT / RESUBMIT COMMAND METADATA
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
  v_match_set_version integer;

  v_fixture_id uuid;
  v_fixture_mode text;
  v_fixture_is_bye boolean;

  v_strategy public.strategies%rowtype;
  v_workspace_payload jsonb;
  v_payload_schema_version integer;
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
    fr.lock_at,
    fr.official_match_set_version
  into
    v_league_id,
    v_round_status,
    v_round_opens_at,
    v_round_lock_at,
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
      message = 'STRATEGY_ROUND_NOT_FOUND';
  end if;

  if v_match_set_version is null then
    raise exception using
      errcode = 'P0001',
      message = 'STRATEGY_OFFICIAL_MATCH_SET_NOT_FOUND';
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

  v_payload_schema_version := (v_workspace_payload ->> 'schema_version')::integer;
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
      'schema_version', v_payload_schema_version,
      'match_set_version', v_match_set_version,
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
is 'Validates and promotes canonical Strategy payload schema_version 1 to an immutable official snapshot, recording the official Match Set version. Repeated submit without edits is idempotent.';


-- ============================================================
-- 4. PRIVILEGES
-- ============================================================

revoke all on function public.save_strategy_draft_rpc(uuid, text, jsonb)
  from public;
revoke all on function public.save_strategy_draft_rpc(uuid, text, jsonb)
  from anon;
revoke all on function public.save_strategy_draft_rpc(uuid, text, jsonb)
  from service_role;
grant execute on function public.save_strategy_draft_rpc(uuid, text, jsonb)
  to authenticated;

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
