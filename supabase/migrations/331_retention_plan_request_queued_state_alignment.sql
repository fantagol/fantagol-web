-- ============================================================================
-- MIGRATION 331
-- Retention plan request queued-state alignment.
-- ============================================================================

create or replace function public.request_retention_plan_rpc(
  p_target_key text,
  p_idempotency_key text,
  p_requested_by uuid,
  p_retention_interval interval,
  p_batch_size integer,
  p_request_payload jsonb,
  p_correlation_id uuid,
  p_causation_id uuid
)
returns table(
  maintenance_run_id uuid,
  retention_plan_id uuid,
  run_status text,
  plan_status text,
  cutoff_at timestamptz
)
language plpgsql
security definer
set search_path to 'public', 'extensions', 'pg_temp'
as $function$
declare
  v_target public.retention_targets%rowtype;
  v_run public.maintenance_runs%rowtype;
  v_plan public.retention_plans%rowtype;
  v_interval interval;
  v_batch integer;
begin
  select * into v_target
  from public.retention_targets
  where target_key = p_target_key
    and retired_at is null;

  if v_target.id is null then
    raise exception using errcode = 'P0002', message = 'RETENTION_TARGET_NOT_FOUND';
  end if;

  if not v_target.planner_enabled then
    raise exception using errcode = '55000', message = 'RETENTION_TARGET_PLANNER_DISABLED';
  end if;

  v_interval := coalesce(p_retention_interval, v_target.default_retention_interval);
  v_batch := coalesce(p_batch_size, v_target.default_batch_size);

  if v_interval <= interval '0 seconds' then
    raise exception using errcode = '22023', message = 'RETENTION_INTERVAL_INVALID';
  end if;

  if v_batch <= 0 or v_batch > v_target.maximum_batch_size then
    raise exception using
      errcode = '22023',
      message = 'RETENTION_BATCH_SIZE_INVALID',
      detail = format('maximum_batch_size=%s', v_target.maximum_batch_size);
  end if;

  select * into v_run
  from public.maintenance_runs
  where idempotency_key = p_idempotency_key;

  if v_run.id is null then
    insert into public.maintenance_runs (
      policy_id, policy_key, operation_type, target_scope, trigger_type,
      requested_by, scheduled_for, status, dry_run, idempotency_key,
      correlation_id, causation_id, max_attempts, timeout_interval, request_payload
    )
    select
      mp.id,
      mp.policy_key,
      'retention_plan',
      v_target.target_key,
      'manual',
      p_requested_by,
      clock_timestamp(),
      'queued',
      true,
      p_idempotency_key,
      coalesce(p_correlation_id, gen_random_uuid()),
      p_causation_id,
      mp.max_attempts,
      mp.timeout_interval,
      coalesce(p_request_payload, '{}'::jsonb)
        || jsonb_build_object(
          'target_key', v_target.target_key,
          'target_version', v_target.target_version,
          'retention_interval', v_interval::text,
          'batch_size', v_batch
        )
    from public.maintenance_policies mp
    where mp.policy_key = 'retention_planner'
      and mp.retired_at is null
    returning * into v_run;

    if v_run.id is null then
      raise exception using errcode = 'P0002', message = 'RETENTION_PLANNER_POLICY_NOT_FOUND';
    end if;

    insert into public.maintenance_command_outbox (
      maintenance_run_id, command_type, command_payload, status, max_attempts
    )
    values (
      v_run.id,
      'build_retention_plan',
      jsonb_build_object(
        'maintenance_run_id', v_run.id,
        'target_key', v_target.target_key
      ),
      'pending',
      v_run.max_attempts
    );
  end if;

  select rp.* into v_plan
  from public.retention_plans rp
  where rp.maintenance_run_id = v_run.id
    and rp.target_id = v_target.id;

  if v_plan.id is null then
    insert into public.retention_plans (
      maintenance_run_id, target_id, target_key, target_version, status,
      dry_run, cutoff_at, retention_interval, requested_batch_size, planner_snapshot
    )
    values (
      v_run.id,
      v_target.id,
      v_target.target_key,
      v_target.target_version,
      'draft',
      true,
      clock_timestamp() - v_interval,
      v_interval,
      v_batch,
      jsonb_build_object(
        'target_schema', v_target.target_schema,
        'target_table', v_target.target_table,
        'identity_column', v_target.identity_column,
        'timestamp_column', v_target.timestamp_column,
        'status_column', v_target.status_column,
        'terminal_statuses', to_jsonb(v_target.terminal_statuses),
        'dependency_class', v_target.dependency_class,
        'execution_enabled', v_target.execution_enabled
      )
    )
    returning * into v_plan;
  end if;

  return query
  select v_run.id, v_plan.id, v_run.status, v_plan.status, v_plan.cutoff_at;
end;
$function$;

revoke all on function public.request_retention_plan_rpc(
  text,text,uuid,interval,integer,jsonb,uuid,uuid
) from public;

grant execute on function public.request_retention_plan_rpc(
  text,text,uuid,interval,integer,jsonb,uuid,uuid
) to service_role;