-- ============================================================================
-- FANTAGOL
-- MIGRATION 225
-- MARKET INTELLIGENCE ATOMIC RUNTIME PERSISTENCE WRITER
-- ============================================================================
--
-- Purpose:
--   Persist one complete immutable BM_INTERPOLATED round snapshot atomically.
--
-- Security:
--   service_role only
--   never exposed to anon/authenticated
--
-- Idempotency:
--   same round + active model + source + canonical source-input set
--   returns the existing ready snapshot instead of creating a new version.
-- ============================================================================

begin;

create or replace function public.persist_market_intelligence_snapshot_internal(
  p_fantagol_round_id uuid,
  p_snapshot_source text,
  p_captured_at timestamptz,
  p_matches jsonb,
  p_metadata jsonb default '{}'::jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
declare
  v_model_id uuid;
  v_model_code text;
  v_algorithm_version text;
  v_required_count integer;
  v_payload_count integer;
  v_snapshot_id uuid;
  v_existing_snapshot_id uuid;
  v_snapshot_version integer;
  v_input_set jsonb;
  v_output_set jsonb;
  v_input_hash text;
  v_snapshot_hash text;
  v_quality_score numeric;
  v_quality_status text;
  v_item jsonb;
  v_match_id uuid;
  v_odds_snapshot_id uuid;
  v_slot integer;
  v_current_match_snapshot_id uuid;
  v_previous_match_snapshot_id uuid;
  v_movement jsonb;
begin
  if p_fantagol_round_id is null then
    raise exception 'MARKET_INTELLIGENCE_ROUND_REQUIRED';
  end if;

  if p_snapshot_source not in ('PACKAGE','ADVANCED') then
    raise exception 'MARKET_INTELLIGENCE_SOURCE_INVALID';
  end if;

  if p_captured_at is null then
    raise exception 'MARKET_INTELLIGENCE_CAPTURED_AT_REQUIRED';
  end if;

  if jsonb_typeof(p_matches) is distinct from 'array' then
    raise exception 'MARKET_INTELLIGENCE_MATCHES_ARRAY_REQUIRED';
  end if;

  select
    m.id,
    m.model_code,
    m.algorithm_version
  into
    v_model_id,
    v_model_code,
    v_algorithm_version
  from public.market_intelligence_models m
  where m.model_code = 'BM_INTERPOLATED'
    and m.status = 'active'
  order by m.model_version desc
  limit 1;

  if v_model_id is null then
    raise exception 'MARKET_INTELLIGENCE_ACTIVE_MODEL_NOT_FOUND';
  end if;

  select count(*)
  into v_required_count
  from public.fantagol_round_matches frm
  where frm.fantagol_round_id = p_fantagol_round_id
    and frm.required
    and frm.removed_at is null;

  select jsonb_array_length(p_matches)
  into v_payload_count;

  if v_required_count <= 0 then
    raise exception 'MARKET_INTELLIGENCE_ROUND_HAS_NO_REQUIRED_MATCHES';
  end if;

  if v_payload_count <> v_required_count then
    raise exception
      'MARKET_INTELLIGENCE_MATCH_COUNT_MISMATCH expected=% actual=%',
      v_required_count,
      v_payload_count;
  end if;

  -- Serialize version allocation + idempotency per round/model.
  perform pg_advisory_xact_lock(
    hashtext(
      'market_intelligence:' ||
      p_fantagol_round_id::text ||
      ':' ||
      v_model_id::text
    )
  );

  -- Validate exact round membership, slots, model contract and source snapshot ownership.
  if exists (
    select 1
    from jsonb_array_elements(p_matches) x(item)
    left join public.fantagol_round_matches frm
      on frm.fantagol_round_id = p_fantagol_round_id
     and frm.match_id = (x.item->>'match_id')::uuid
     and frm.slot_number = (x.item->>'slot_number')::integer
     and frm.required
     and frm.removed_at is null
    left join public.odds_market_snapshots oms
      on oms.id = (x.item->>'odds_market_snapshot_id')::uuid
     and oms.match_id = (x.item->>'match_id')::uuid
    where frm.match_id is null
       or oms.id is null
       or x.item->>'model_code' is distinct from v_model_code
       or x.item->>'algorithm_version' is distinct from v_algorithm_version
  ) then
    raise exception 'MARKET_INTELLIGENCE_PAYLOAD_CONTRACT_MISMATCH';
  end if;

  if (
    select count(distinct (x.item->>'match_id')::uuid)
    from jsonb_array_elements(p_matches) x(item)
  ) <> v_required_count then
    raise exception 'MARKET_INTELLIGENCE_DUPLICATE_OR_MISSING_MATCH';
  end if;

  if (
    select count(distinct (x.item->>'slot_number')::integer)
    from jsonb_array_elements(p_matches) x(item)
  ) <> v_required_count then
    raise exception 'MARKET_INTELLIGENCE_DUPLICATE_OR_MISSING_SLOT';
  end if;

  select jsonb_agg(
    jsonb_build_object(
      'slot_number', (x.item->>'slot_number')::integer,
      'match_id', x.item->>'match_id',
      'odds_market_snapshot_id', x.item->>'odds_market_snapshot_id',
      'input_hash', x.item->>'input_hash'
    )
    order by (x.item->>'slot_number')::integer
  )
  into v_input_set
  from jsonb_array_elements(p_matches) x(item);

  v_input_hash := public.compute_jsonb_sha256(
    jsonb_build_object(
      'round_id', p_fantagol_round_id,
      'model_id', v_model_id,
      'source', p_snapshot_source,
      'inputs', v_input_set
    )
  );

  select s.id
  into v_existing_snapshot_id
  from public.market_intelligence_snapshots s
  where s.fantagol_round_id = p_fantagol_round_id
    and s.market_model_id = v_model_id
    and s.snapshot_source = p_snapshot_source
    and s.input_hash = v_input_hash
    and s.status = 'ready'
  order by s.snapshot_version desc
  limit 1;

  if v_existing_snapshot_id is not null then
    return jsonb_build_object(
      'created', false,
      'idempotent', true,
      'snapshot_id', v_existing_snapshot_id,
      'input_hash', v_input_hash
    );
  end if;

  select coalesce(max(s.snapshot_version),0) + 1
  into v_snapshot_version
  from public.market_intelligence_snapshots s
  where s.fantagol_round_id = p_fantagol_round_id
    and s.market_model_id = v_model_id;

  select avg(
    greatest(
      0::numeric,
      least(
        1::numeric,
        coalesce((x.item->>'quality_score')::numeric,0)
      )
    )
  )
  into v_quality_score
  from jsonb_array_elements(p_matches) x(item);

  v_quality_status :=
    case
      when v_quality_score >= 0.75 then 'healthy'
      when v_quality_score >= 0.50 then 'degraded'
      else 'insufficient'
    end;

  insert into public.market_intelligence_snapshots (
    fantagol_round_id,
    market_model_id,
    snapshot_version,
    status,
    required_match_count,
    captured_match_count,
    input_hash,
    quality_status,
    quality_score,
    metadata,
    schema_version,
    captured_at,
    snapshot_source
  )
  values (
    p_fantagol_round_id,
    v_model_id,
    v_snapshot_version,
    'building',
    v_required_count,
    0,
    v_input_hash,
    v_quality_status,
    v_quality_score,
    coalesce(p_metadata,'{}'::jsonb),
    1,
    p_captured_at,
    p_snapshot_source
  )
  returning id into v_snapshot_id;

  for v_item in
    select x.item
    from jsonb_array_elements(p_matches) x(item)
    order by (x.item->>'slot_number')::integer
  loop
    v_match_id := (v_item->>'match_id')::uuid;
    v_odds_snapshot_id := (v_item->>'odds_market_snapshot_id')::uuid;
    v_slot := (v_item->>'slot_number')::integer;

    select ms.id
    into v_previous_match_snapshot_id
    from public.market_intelligence_match_snapshots ms
    join public.market_intelligence_snapshots s
      on s.id = ms.market_intelligence_snapshot_id
    where ms.match_id = v_match_id
      and s.fantagol_round_id = p_fantagol_round_id
      and s.market_model_id = v_model_id
      and s.status = 'ready'
    order by s.snapshot_version desc
    limit 1;

    insert into public.market_intelligence_match_snapshots (
      market_intelligence_snapshot_id,
      match_id,
      odds_market_snapshot_id,
      slot_number,
      model_code,
      algorithm_version,
      home_probability,
      draw_probability,
      away_probability,
      expected_home_goals,
      expected_away_goals,
      primary_outcome,
      confidence_score,
      input_payload,
      output_payload,
      input_hash,
      output_hash,
      over_25_probability,
      under_25_probability,
      goal_probability,
      no_goal_probability,
      market_confidence,
      model_loss
    )
    values (
      v_snapshot_id,
      v_match_id,
      v_odds_snapshot_id,
      v_slot,
      v_item->>'model_code',
      v_item->>'algorithm_version',
      (v_item#>>'{sign,home}')::numeric,
      (v_item#>>'{sign,draw}')::numeric,
      (v_item#>>'{sign,away}')::numeric,
      nullif(v_item->>'expected_home_goals','')::numeric,
      nullif(v_item->>'expected_away_goals','')::numeric,
      v_item->>'primary_outcome',
      nullif(v_item->>'confidence_score','')::numeric,
      coalesce(v_item->'input_payload','{}'::jsonb),
      coalesce(v_item->'output_payload','{}'::jsonb),
      v_item->>'input_hash',
      v_item->>'output_hash',
      nullif(v_item#>>'{totals,over_25}','')::numeric,
      nullif(v_item#>>'{totals,under_25}','')::numeric,
      nullif(v_item#>>'{btts,goal}','')::numeric,
      nullif(v_item#>>'{btts,no_goal}','')::numeric,
      nullif(v_item->>'market_confidence','')::numeric,
      nullif(v_item->>'model_loss','')::numeric
    )
    returning id into v_current_match_snapshot_id;

    if v_previous_match_snapshot_id is not null
       and jsonb_typeof(coalesce(v_item->'movements','[]'::jsonb)) = 'array'
    then
      for v_movement in
        select mv.value
        from jsonb_array_elements(
          coalesce(v_item->'movements','[]'::jsonb)
        ) mv(value)
      loop
        insert into public.market_intelligence_signal_movements (
          fantagol_round_id,
          match_id,
          market_model_id,
          previous_match_snapshot_id,
          current_match_snapshot_id,
          signal_type,
          signal_key,
          previous_probability,
          current_probability,
          delta_probability,
          delta_percentage_points,
          previous_rank,
          current_rank,
          rank_delta,
          movement_magnitude,
          direction,
          movement_hash,
          metadata
        )
        values (
          p_fantagol_round_id,
          v_match_id,
          v_model_id,
          v_previous_match_snapshot_id,
          v_current_match_snapshot_id,
          v_movement->>'signal_type',
          v_movement->>'signal_key',
          nullif(v_movement->>'previous_probability','')::numeric,
          nullif(v_movement->>'current_probability','')::numeric,
          nullif(v_movement->>'delta_probability','')::numeric,
          nullif(v_movement->>'delta_percentage_points','')::numeric,
          nullif(v_movement->>'previous_rank','')::integer,
          nullif(v_movement->>'current_rank','')::integer,
          nullif(v_movement->>'rank_delta','')::integer,
          coalesce(
            nullif(v_movement->>'movement_magnitude','')::numeric,
            0
          ),
          v_movement->>'direction',
          public.compute_jsonb_sha256(
            jsonb_build_object(
              'previous_match_snapshot_id', v_previous_match_snapshot_id,
              'current_match_snapshot_id', v_current_match_snapshot_id,
              'signal_type', v_movement->>'signal_type',
              'signal_key', v_movement->>'signal_key',
              'delta_probability', v_movement->>'delta_probability',
              'previous_rank', v_movement->>'previous_rank',
              'current_rank', v_movement->>'current_rank'
            )
          ),
          coalesce(v_movement->'metadata','{}'::jsonb)
        );
      end loop;
    end if;
  end loop;

  select jsonb_agg(
    jsonb_build_object(
      'slot_number', ms.slot_number,
      'match_id', ms.match_id,
      'output_hash', ms.output_hash
    )
    order by ms.slot_number
  )
  into v_output_set
  from public.market_intelligence_match_snapshots ms
  where ms.market_intelligence_snapshot_id = v_snapshot_id;

  v_snapshot_hash := public.compute_jsonb_sha256(
    jsonb_build_object(
      'round_id', p_fantagol_round_id,
      'model_id', v_model_id,
      'snapshot_version', v_snapshot_version,
      'outputs', v_output_set
    )
  );

  update public.market_intelligence_snapshots
  set
    status = 'ready',
    built_at = clock_timestamp(),
    frozen_at = clock_timestamp(),
    captured_match_count = v_required_count,
    snapshot_hash = v_snapshot_hash
  where id = v_snapshot_id;

  return jsonb_build_object(
    'created', true,
    'idempotent', false,
    'snapshot_id', v_snapshot_id,
    'snapshot_version', v_snapshot_version,
    'captured_match_count', v_required_count,
    'input_hash', v_input_hash,
    'snapshot_hash', v_snapshot_hash,
    'quality_status', v_quality_status,
    'quality_score', v_quality_score
  );
end;
$$;

comment on function public.persist_market_intelligence_snapshot_internal(
  uuid,text,timestamptz,jsonb,jsonb
) is
'Atomic service-role-only persistence writer for complete immutable BM_INTERPOLATED round snapshots and granular temporal movements.';

revoke all on function public.persist_market_intelligence_snapshot_internal(
  uuid,text,timestamptz,jsonb,jsonb
) from public, anon, authenticated;

grant execute on function public.persist_market_intelligence_snapshot_internal(
  uuid,text,timestamptz,jsonb,jsonb
) to service_role;

do $$
begin
  if to_regprocedure(
    'public.persist_market_intelligence_snapshot_internal(uuid,text,timestamp with time zone,jsonb,jsonb)'
  ) is null then
    raise exception 'R38C4C_INSTALL_ASSERTION_WRITER_MISSING';
  end if;

  if has_function_privilege(
    'authenticated',
    'public.persist_market_intelligence_snapshot_internal(uuid,text,timestamp with time zone,jsonb,jsonb)',
    'EXECUTE'
  ) then
    raise exception 'R38C4C_INSTALL_ASSERTION_AUTHENTICATED_EXPOSED';
  end if;

  if not has_function_privilege(
    'service_role',
    'public.persist_market_intelligence_snapshot_internal(uuid,text,timestamp with time zone,jsonb,jsonb)',
    'EXECUTE'
  ) then
    raise exception 'R38C4C_INSTALL_ASSERTION_SERVICE_ROLE_MISSING';
  end if;

  raise notice 'R38-C4-C MARKET INTELLIGENCE ATOMIC WRITER CERTIFIED';
end;
$$;

commit;
