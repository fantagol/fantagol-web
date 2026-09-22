-- ============================================================================
-- MIGRATION 326
-- Retention execution receipt immutability + canonical plan hash revalidation.
--
-- Safety:
--   - no target/policy activation
--   - no retention execution
--   - preserves M325 runtime lineage guards
-- ============================================================================

create or replace function public.protect_retention_execution_receipt_append_only()
returns trigger
language plpgsql
security definer
set search_path to 'public','pg_temp'
as $function$
begin
  raise exception using
    errcode = '55000',
    message = 'RETENTION_EXECUTION_RECEIPT_APPEND_ONLY';
end;
$function$;

drop trigger if exists trg_protect_retention_execution_receipts_append_only
on public.retention_execution_receipts;

create trigger trg_protect_retention_execution_receipts_append_only
before update or delete
on public.retention_execution_receipts
for each row
execute function public.protect_retention_execution_receipt_append_only();

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
set search_path to 'public', 'extensions', 'pg_temp'
as $function$
declare
  v_plan public.retention_plans%rowtype;
  v_target public.retention_targets%rowtype;
  v_relation regclass;
  v_batch integer;
  v_batch_id uuid := gen_random_uuid();
  v_sql text;
  v_deleted integer := 0;
  v_skipped integer := 0;
  v_remaining integer := 0;
  v_blocked integer := 0;
  v_recomputed_plan_hash text;
begin
  if p_retention_plan_id is null then
    raise exception using errcode='22004', message='RETENTION_PLAN_ID_REQUIRED';
  end if;

  if p_expected_plan_hash is null
     or btrim(p_expected_plan_hash) = ''
     or lower(btrim(p_expected_plan_hash)) !~ '^[0-9a-f]{64}$'
  then
    raise exception using errcode='22023', message='RETENTION_PLAN_HASH_REQUIRED';
  end if;

  perform pg_advisory_xact_lock(
    hashtextextended('retention-execution:' || p_retention_plan_id::text, 0)
  );

  select *
  into v_plan
  from public.retention_plans
  where id = p_retention_plan_id
  for update;

  if not found then
    raise exception using errcode='P0002', message='RETENTION_PLAN_NOT_FOUND';
  end if;

  if v_plan.status <> 'approved' then
    raise exception using errcode='55000', message='RETENTION_PLAN_NOT_EXECUTABLE';
  end if;

  if v_plan.plan_hash is distinct from lower(btrim(p_expected_plan_hash)) then
    raise exception using errcode='40001', message='RETENTION_PLAN_HASH_MISMATCH';
  end if;

  select encode(
           extensions.digest(
             convert_to(
               jsonb_build_object(
                 'plan_id', v_plan.id,
                 'maintenance_run_id', v_plan.maintenance_run_id,
                 'target_key', v_plan.target_key,
                 'target_version', v_plan.target_version,
                 'cutoff_at', v_plan.cutoff_at,
                 'retention_interval', v_plan.retention_interval::text,
                 'requested_batch_size', v_plan.requested_batch_size,
                 'candidate_count', v_plan.candidate_count,
                 'items', coalesce(
                   jsonb_agg(
                     jsonb_build_object(
                       'item_order', i.item_order,
                       'target_identity', i.target_identity,
                       'target_timestamp', i.target_timestamp,
                       'target_status', i.target_status,
                       'item_hash', i.item_hash
                     )
                     order by i.item_order
                   ),
                   '[]'::jsonb
                 )
               )::text,
               'UTF8'
             ),
             'sha256'
           ),
           'hex'
         )
  into v_recomputed_plan_hash
  from public.retention_plan_items i
  where i.retention_plan_id = v_plan.id;

  if v_plan.plan_hash is distinct from v_recomputed_plan_hash then
    raise exception using
      errcode='40001',
      message='RETENTION_PLAN_CANONICAL_HASH_MISMATCH';
  end if;

  select rt.*
  into v_target
  from public.retention_targets rt
  where rt.id = v_plan.target_id
    and rt.target_key = v_plan.target_key
    and rt.target_version = v_plan.target_version
    and rt.retired_at is null;

  if not found then
    raise exception using errcode='55000', message='RETENTION_TARGET_VERSION_UNAVAILABLE';
  end if;

  if not v_target.execution_enabled then
    raise exception using errcode='55000', message='RETENTION_TARGET_EXECUTION_DISABLED';
  end if;

  if not v_target.destructive then
    raise exception using errcode='55000', message='RETENTION_TARGET_NOT_DESTRUCTIVE';
  end if;

  v_batch := coalesce(p_batch_size, v_target.default_batch_size);

  if v_batch <= 0 or v_batch > v_target.maximum_batch_size then
    raise exception using
      errcode='22023',
      message='RETENTION_EXECUTION_BATCH_SIZE_INVALID',
      detail=format('maximum_batch_size=%s',v_target.maximum_batch_size);
  end if;

  perform public.validate_retention_target_definition(
    v_target.target_schema,
    v_target.target_table,
    v_target.identity_column,
    v_target.timestamp_column,
    v_target.status_column,
    v_target.additional_predicate_sql
  );

  v_relation := to_regclass(format('%I.%I',v_target.target_schema,v_target.target_table));

  if v_relation is null then
    raise exception using errcode='P0002', message='RETENTION_TARGET_RELATION_NOT_FOUND';
  end if;

  select count(*)
  into v_skipped
  from public.retention_plan_items i
  where i.retention_plan_id = v_plan.id
    and exists (
      select 1
      from public.retention_execution_receipts r
      where r.retention_plan_item_id = i.id
    );

  if v_target.target_schema = 'public'
     and v_target.target_table = 'live_runtime_jobs'
     and v_target.dependency_class = 'parent_guarded'
  then
    select count(*)
    into v_blocked
    from public.retention_plan_items i
    join public.live_runtime_jobs j
      on j.id::text = i.target_identity
    where i.retention_plan_id = v_plan.id
      and not exists (
        select 1
        from public.retention_execution_receipts r
        where r.retention_plan_item_id = i.id
      )
      and (
        exists (
          select 1 from public.live_runtime_workflow_steps s where s.job_id=j.id
        )
        or exists (
          select 1 from public.live_runtime_dead_letters d where d.job_id=j.id
        )
        or exists (
          select 1 from public.live_runtime_workflows w where w.trigger_job_id=j.id
        )
      );

    if v_blocked > 0 then
      raise exception using
        errcode='55000',
        message='RETENTION_TARGET_DEPENDENCY_GUARD_BLOCKED',
        detail=format('blocked_items=%s',v_blocked);
    end if;
  end if;

  v_sql := format($fmt$
    with selected as (
      select i.id as plan_item_id,
             i.target_identity,
             i.target_timestamp,
             i.target_status
      from public.retention_plan_items i
      where i.retention_plan_id = $1
        and not exists (
          select 1
          from public.retention_execution_receipts r
          where r.retention_plan_item_id = i.id
        )
      order by i.item_order
      limit $2
      for update of i
    ),
    deleted as (
      delete from %s t
      using selected s
      where t.%I::text = s.target_identity
        and t.%I::timestamptz = s.target_timestamp
        %s
      returning s.plan_item_id,
                s.target_identity,
                s.target_timestamp,
                s.target_status
    ),
    receipted as (
      insert into public.retention_execution_receipts (
        retention_plan_id,
        retention_plan_item_id,
        target_key,
        target_version,
        target_identity,
        target_timestamp,
        target_status,
        plan_hash,
        execution_batch_id,
        execution_metadata
      )
      select
        $1,
        d.plan_item_id,
        $3,
        $4,
        d.target_identity,
        d.target_timestamp,
        d.target_status,
        $5,
        $6,
        jsonb_build_object(
          'authority','execute_retention_plan_batch_rpc',
          'target_table',$7
        )
      from deleted d
      on conflict (retention_plan_item_id) do nothing
      returning id
    )
    select count(*)::integer
    from receipted
  $fmt$,
    v_relation,
    v_target.identity_column,
    v_target.timestamp_column,
    case
      when v_target.status_column is null then ''
      else format(
        'and t.%I::text is not distinct from s.target_status',
        v_target.status_column
      )
    end
  );

  execute v_sql
  into v_deleted
  using
    v_plan.id,
    v_batch,
    v_target.target_key,
    v_target.target_version,
    v_plan.plan_hash,
    v_batch_id,
    format('%I.%I',v_target.target_schema,v_target.target_table);

  select count(*)
  into v_remaining
  from public.retention_plan_items i
  where i.retention_plan_id = v_plan.id
    and not exists (
      select 1
      from public.retention_execution_receipts r
      where r.retention_plan_item_id = i.id
    );

  return query
  select
    v_plan.id,
    v_plan.target_key,
    v_batch_id,
    v_deleted,
    v_skipped,
    v_remaining;
end;
$function$;

revoke all on function public.execute_retention_plan_batch_rpc(uuid,text,integer)
from public;