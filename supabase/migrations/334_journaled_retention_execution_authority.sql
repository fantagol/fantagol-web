-- ============================================================================
-- MIGRATION 334
-- Journaled retention execution authority.
--
-- Canonical execution contract:
--   begin attempt -> guarded execute -> finalize attempt
--
-- The previous executor is moved to a postgres-only internal schema.
-- The public compatibility signature is recreated as a guarded wrapper and
-- refuses execution unless exactly one matching STARTED attempt exists.
--
-- This migration does not enable any retention target.
-- ============================================================================

create schema if not exists retention_internal authorization postgres;

revoke all on schema retention_internal from public;
revoke all on schema retention_internal from service_role;

do $body$
begin
  if to_regprocedure(
       'retention_internal.execute_retention_plan_batch_rpc(uuid,text,integer)'
     ) is null
  then
    if to_regprocedure(
         'public.execute_retention_plan_batch_rpc(uuid,text,integer)'
       ) is null
    then
      raise exception using
        errcode='P0002',
        message='RETENTION_EXECUTION_BASE_AUTHORITY_NOT_FOUND';
    end if;

    alter function public.execute_retention_plan_batch_rpc(
      uuid,text,integer
    ) set schema retention_internal;
  end if;
end
$body$;

revoke all on function retention_internal.execute_retention_plan_batch_rpc(
  uuid,text,integer
) from public;

revoke all on function retention_internal.execute_retention_plan_batch_rpc(
  uuid,text,integer
) from service_role;

create unique index if not exists
  retention_execution_attempts_one_started_per_plan_idx
on public.retention_execution_attempts(retention_plan_id)
where attempt_status='started';

create or replace function public.execute_retention_plan_batch_rpc(
  p_retention_plan_id uuid,
  p_expected_plan_hash text,
  p_batch_size integer default null
)
returns table(
  retention_plan_id uuid,
  target_key text,
  execution_batch_id uuid,
  deleted_count integer,
  skipped_already_executed_count integer,
  remaining_unexecuted_count integer
)
language plpgsql
security definer
set search_path to 'public', 'retention_internal', 'extensions', 'pg_temp'
as $function$
declare
  v_attempt public.retention_execution_attempts%rowtype;
  v_effective_batch integer;
begin
  select a.*
    into v_attempt
  from public.retention_execution_attempts a
  where a.retention_plan_id = p_retention_plan_id
    and a.attempt_status = 'started'
    and a.expected_plan_hash = lower(btrim(p_expected_plan_hash));

  if not found then
    raise exception using
      errcode='55000',
      message='RETENTION_EXECUTION_ATTEMPT_REQUIRED';
  end if;

  v_effective_batch := coalesce(p_batch_size, v_attempt.requested_batch_size);

  if v_effective_batch <> v_attempt.requested_batch_size then
    raise exception using
      errcode='22023',
      message='RETENTION_EXECUTION_ATTEMPT_BATCH_MISMATCH',
      detail=format(
        'attempt_batch=%s requested_batch=%s',
        v_attempt.requested_batch_size,
        v_effective_batch
      );
  end if;

  return query
  select *
  from retention_internal.execute_retention_plan_batch_rpc(
    p_retention_plan_id,
    p_expected_plan_hash,
    v_effective_batch
  );
end;
$function$;

revoke all on function public.execute_retention_plan_batch_rpc(
  uuid,text,integer
) from public;

revoke all on function public.execute_retention_plan_batch_rpc(
  uuid,text,integer
) from service_role;

create or replace function public.execute_retention_plan_journaled_rpc(
  p_retention_plan_id uuid,
  p_expected_plan_hash text,
  p_batch_size integer,
  p_attempted_by uuid,
  p_attempt_metadata jsonb default '{}'::jsonb
)
returns jsonb
language plpgsql
security definer
set search_path to 'public', 'extensions', 'pg_temp'
as $function$
declare
  v_attempt public.retention_execution_attempts%rowtype;
  v_final public.retention_execution_attempts%rowtype;
  v_exec record;
  v_state text;
  v_message text;
begin
  perform pg_advisory_xact_lock(
    hashtextextended(
      'retention-journaled-execution:' || p_retention_plan_id::text,
      0
    )
  );

  v_attempt := public.begin_retention_execution_attempt_rpc(
    p_retention_plan_id,
    p_expected_plan_hash,
    p_batch_size,
    p_attempted_by,
    coalesce(p_attempt_metadata, '{}'::jsonb)
      || jsonb_build_object(
           'authority',
           'execute_retention_plan_journaled_rpc'
         )
  );

  begin
    select *
      into strict v_exec
    from public.execute_retention_plan_batch_rpc(
      p_retention_plan_id,
      p_expected_plan_hash,
      v_attempt.requested_batch_size
    );

    v_final := public.finalize_retention_execution_attempt_rpc(
      v_attempt.id,
      'succeeded',
      v_exec.execution_batch_id,
      v_exec.deleted_count,
      v_exec.skipped_already_executed_count,
      v_exec.remaining_unexecuted_count,
      null,
      null,
      jsonb_build_object(
        'execution_authority',
        'execute_retention_plan_batch_rpc'
      )
    );

    return jsonb_build_object(
      'executed', true,
      'attempt_id', v_final.id,
      'attempt_number', v_final.attempt_number,
      'attempt_status', v_final.attempt_status,
      'retention_plan_id', v_final.retention_plan_id,
      'target_key', v_final.target_key,
      'target_version', v_final.target_version,
      'execution_batch_id', v_final.execution_batch_id,
      'deleted_count', v_final.deleted_count,
      'skipped_already_executed_count',
        v_final.skipped_already_executed_count,
      'remaining_unexecuted_count',
        v_final.remaining_unexecuted_count
    );

  exception when others then
    get stacked diagnostics
      v_state = returned_sqlstate,
      v_message = message_text;

    v_final := public.finalize_retention_execution_attempt_rpc(
      v_attempt.id,
      'failed',
      null,
      null,
      null,
      null,
      coalesce(nullif(v_state,''),'RETENTION_EXECUTION_FAILED'),
      v_message,
      jsonb_build_object(
        'execution_authority',
        'execute_retention_plan_batch_rpc',
        'caught_by',
        'execute_retention_plan_journaled_rpc'
      )
    );

    return jsonb_build_object(
      'executed', false,
      'attempt_id', v_final.id,
      'attempt_number', v_final.attempt_number,
      'attempt_status', v_final.attempt_status,
      'retention_plan_id', v_final.retention_plan_id,
      'target_key', v_final.target_key,
      'target_version', v_final.target_version,
      'error_code', v_final.error_code,
      'error_message', v_final.error_message
    );
  end;
end;
$function$;

revoke all on function public.execute_retention_plan_journaled_rpc(
  uuid,text,integer,uuid,jsonb
) from public;

revoke all on function public.execute_retention_plan_journaled_rpc(
  uuid,text,integer,uuid,jsonb
) from service_role;