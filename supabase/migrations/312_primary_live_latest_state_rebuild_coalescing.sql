-- ============================================================================
-- FANTAGOL MIGRATION 312
-- PRIMARY LIVE LATEST-STATE REBUILD COALESCING
--
-- Authority:
--   - Primary LIVE only (TuttoIlCalcio).
--   - Football-Data canonical/final enqueue path is intentionally unchanged.
--
-- Guarantees:
--   - advisory transaction lock per league_round;
--   - latest-state-wins among pending/retry_wait primary-live rebuilds;
--   - claimed/running jobs are never cancelled;
--   - replay of an equal/newer active authority version is a no-op;
--   - primary-live rebuild priority is fixed at 12;
--   - event idempotency remains unique by observation id.
-- ============================================================================

create or replace function public.enqueue_primary_live_rebuild_job_rpc(
  p_league_round_id uuid,
  p_observation_id uuid,
  p_authority_version bigint,
  p_match_id uuid,
  p_fantagol_round_id uuid default null,
  p_changed_fields text[] default '{}'::text[],
  p_correlation_id uuid default null,
  p_causation_id uuid default null
)
returns table(
  job_id uuid,
  job_status text,
  inserted boolean,
  scheduled_at timestamptz,
  attempt_count integer,
  correlation_id uuid
)
language plpgsql
security definer
set search_path = public, pg_temp
as $function$
declare
  v_existing public.live_runtime_jobs%rowtype;
  v_job public.live_runtime_jobs%rowtype;
  v_idempotency_key text;
  v_now timestamptz := clock_timestamp();
begin
  if p_league_round_id is null then
    raise exception using
      errcode = 'P0001',
      message = 'PRIMARY_LIVE_LEAGUE_ROUND_ID_REQUIRED';
  end if;

  if p_observation_id is null then
    raise exception using
      errcode = 'P0001',
      message = 'PRIMARY_LIVE_OBSERVATION_ID_REQUIRED';
  end if;

  if p_authority_version is null or p_authority_version < 1 then
    raise exception using
      errcode = 'P0001',
      message = 'PRIMARY_LIVE_AUTHORITY_VERSION_REQUIRED';
  end if;

  if p_match_id is null then
    raise exception using
      errcode = 'P0001',
      message = 'PRIMARY_LIVE_MATCH_ID_REQUIRED';
  end if;

  perform pg_advisory_xact_lock(
    hashtextextended(
      'primary-live-rebuild:' || p_league_round_id::text,
      0
    )
  );

  /*
   * If an equal/newer primary-live rebuild is already active, return it.
   * This includes claimed/running: they are preserved and never superseded.
   */
  select j.*
  into v_existing
  from public.live_runtime_jobs j
  where j.job_type = 'rebuild_league_round'
    and j.scope_type = 'league_round'
    and j.scope_id = p_league_round_id
    and j.status in ('pending','retry_wait','claimed','running')
    and j.payload->>'rebuild_provenance' = 'primary_live'
    and case
          when (j.payload->>'live_authority_version') ~ '^[0-9]+$'
            then (j.payload->>'live_authority_version')::bigint
          else 0
        end >= p_authority_version
  order by
    case
      when (j.payload->>'live_authority_version') ~ '^[0-9]+$'
        then (j.payload->>'live_authority_version')::bigint
      else 0
    end desc,
    j.created_at desc
  limit 1;

  if found then
    return query
    select
      v_existing.id,
      v_existing.status,
      false,
      v_existing.scheduled_at,
      v_existing.attempt_count,
      v_existing.correlation_id;
    return;
  end if;

  /*
   * Supersede only queued stale work. In-flight work is deliberately preserved.
   */
  update public.live_runtime_jobs j
  set
    status = 'cancelled',
    cancelled_at = v_now,
    updated_at = v_now,
    result = coalesce(j.result, '{}'::jsonb) || jsonb_build_object(
      'cancel_reason', 'PRIMARY_LIVE_SUPERSEDED',
      'superseded_by_live_authority_version', p_authority_version
    )
  where j.job_type = 'rebuild_league_round'
    and j.scope_type = 'league_round'
    and j.scope_id = p_league_round_id
    and j.status in ('pending','retry_wait')
    and j.payload->>'rebuild_provenance' = 'primary_live'
    and case
          when (j.payload->>'live_authority_version') ~ '^[0-9]+$'
            then (j.payload->>'live_authority_version')::bigint
          else 0
        end < p_authority_version;

  v_idempotency_key :=
    'live:rebuild-league-round:primary-live:' ||
    p_league_round_id::text || ':' ||
    p_observation_id::text;

  insert into public.live_runtime_jobs (
    job_type,
    status,
    priority,
    scope_type,
    scope_id,
    scheduled_at,
    attempt_count,
    max_attempts,
    idempotency_key,
    correlation_id,
    causation_id,
    payload
  )
  values (
    'rebuild_league_round',
    'pending',
    12,
    'league_round',
    p_league_round_id,
    v_now,
    0,
    5,
    v_idempotency_key,
    coalesce(p_correlation_id, gen_random_uuid()),
    p_causation_id,
    jsonb_build_object(
      'rebuild_provenance', 'primary_live',
      'live_authority_source', 'tuttoilcalcio',
      'live_authority_observation_id', p_observation_id,
      'live_authority_version', p_authority_version,
      'match_id', p_match_id,
      'fantagol_round_id', p_fantagol_round_id,
      'league_round_id', p_league_round_id,
      'change_type', 'PRIMARY_LIVE_STATE_CHANGED',
      'changed_fields', to_jsonb(coalesce(p_changed_fields, '{}'::text[]))
    )
  )
  on conflict (idempotency_key)
  do nothing
  returning *
  into v_job;

  if found then
    return query
    select
      v_job.id,
      v_job.status,
      true,
      v_job.scheduled_at,
      v_job.attempt_count,
      v_job.correlation_id;
    return;
  end if;

  /*
   * Historical replay whose unique event key already exists.
   */
  select j.*
  into v_job
  from public.live_runtime_jobs j
  where j.idempotency_key = v_idempotency_key;

  if not found then
    raise exception using
      errcode = 'P0001',
      message = 'PRIMARY_LIVE_REBUILD_ENQUEUE_CONFLICT_WITHOUT_JOB';
  end if;

  return query
  select
    v_job.id,
    v_job.status,
    false,
    v_job.scheduled_at,
    v_job.attempt_count,
    v_job.correlation_id;
end;
$function$;

revoke all on function public.enqueue_primary_live_rebuild_job_rpc(
  uuid, uuid, bigint, uuid, uuid, text[], uuid, uuid
) from public;

revoke all on function public.enqueue_primary_live_rebuild_job_rpc(
  uuid, uuid, bigint, uuid, uuid, text[], uuid, uuid
) from anon;

revoke all on function public.enqueue_primary_live_rebuild_job_rpc(
  uuid, uuid, bigint, uuid, uuid, text[], uuid, uuid
) from authenticated;

grant execute on function public.enqueue_primary_live_rebuild_job_rpc(
  uuid, uuid, bigint, uuid, uuid, text[], uuid, uuid
) to service_role;