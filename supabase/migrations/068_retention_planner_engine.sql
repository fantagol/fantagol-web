-- ============================================================================
-- FantaGol
-- Migration 068: Retention Planner Engine
-- Milestone 7.4.2
--
-- Purpose
--   Introduce an auditable, non-destructive retention planning layer above the
--   Maintenance Engine Foundation created by migration 067.
--
-- Safety contract
--   * This migration never deletes application data.
--   * Plans contain immutable snapshots of candidate identities and metadata.
--   * Target tables and columns must be explicitly registered and validated.
--   * Every generated plan is dry-run only and requires explicit approval.
--   * Approval does not execute the plan.
--   * A future Housekeeping Execution Engine will consume approved plans.
-- ============================================================================

begin;

create extension if not exists pgcrypto with schema extensions;

-- --------------------------------------------------------------------------
-- Retention target registry
-- --------------------------------------------------------------------------

create table if not exists public.retention_targets (
  id uuid primary key default gen_random_uuid(),
  target_key text not null,
  target_version integer not null default 1,
  display_name text not null,
  description text,
  target_schema text not null default 'public',
  target_table text not null,
  identity_column text not null default 'id',
  timestamp_column text not null,
  status_column text,
  terminal_statuses text[] not null default '{}'::text[],
  additional_predicate_sql text,
  default_retention_interval interval not null,
  default_batch_size integer not null default 100,
  maximum_batch_size integer not null default 1000,
  dependency_class text not null default 'independent',
  planner_enabled boolean not null default false,
  execution_enabled boolean not null default false,
  destructive boolean not null default true,
  target_config jsonb not null default '{}'::jsonb,
  created_by uuid,
  created_at timestamptz not null default clock_timestamp(),
  updated_at timestamptz not null default clock_timestamp(),
  retired_at timestamptz,
  constraint retention_targets_key_not_blank
    check (btrim(target_key) <> ''),
  constraint retention_targets_display_name_not_blank
    check (btrim(display_name) <> ''),
  constraint retention_targets_schema_not_blank
    check (btrim(target_schema) <> ''),
  constraint retention_targets_table_not_blank
    check (btrim(target_table) <> ''),
  constraint retention_targets_identity_not_blank
    check (btrim(identity_column) <> ''),
  constraint retention_targets_timestamp_not_blank
    check (btrim(timestamp_column) <> ''),
  constraint retention_targets_version_positive
    check (target_version > 0),
  constraint retention_targets_retention_positive
    check (default_retention_interval > interval '0 seconds'),
  constraint retention_targets_batch_positive
    check (default_batch_size > 0),
  constraint retention_targets_max_batch_positive
    check (maximum_batch_size > 0),
  constraint retention_targets_batch_limit
    check (default_batch_size <= maximum_batch_size),
  constraint retention_targets_dependency_class
    check (
      dependency_class in (
        'independent',
        'child_first',
        'parent_guarded',
        'immutable_reference',
        'manual_only'
      )
    ),
  constraint retention_targets_config_object
    check (jsonb_typeof(target_config) = 'object'),
  constraint retention_targets_execution_safety
    check (execution_enabled = false or planner_enabled = true),
  constraint retention_targets_unique_version
    unique (target_key, target_version)
);

create unique index if not exists retention_targets_one_active_version_uidx
  on public.retention_targets (target_key)
  where retired_at is null;

create index if not exists retention_targets_planner_idx
  on public.retention_targets (planner_enabled, dependency_class, target_key)
  where retired_at is null;

drop trigger if exists trg_retention_targets_updated_at
  on public.retention_targets;

create trigger trg_retention_targets_updated_at
before update on public.retention_targets
for each row
execute function public.set_maintenance_updated_at();

comment on table public.retention_targets
is 'Versioned allowlist of database targets that may be inspected by the retention planner. Registration never enables execution.';

-- --------------------------------------------------------------------------
-- Immutable retention plans
-- --------------------------------------------------------------------------

create table if not exists public.retention_plans (
  id uuid primary key default gen_random_uuid(),
  maintenance_run_id uuid not null
    references public.maintenance_runs(id) on delete restrict,
  target_id uuid not null
    references public.retention_targets(id) on delete restrict,
  target_key text not null,
  target_version integer not null,
  status text not null default 'draft',
  dry_run boolean not null default true,
  cutoff_at timestamptz not null,
  retention_interval interval not null,
  requested_batch_size integer not null,
  candidate_count integer not null default 0,
  truncated boolean not null default false,
  candidate_min_timestamp timestamptz,
  candidate_max_timestamp timestamptz,
  planner_version text not null default 'retention-planner-v1',
  planner_snapshot jsonb not null default '{}'::jsonb,
  plan_hash text,
  generated_at timestamptz,
  approved_at timestamptz,
  approved_by uuid,
  approval_reason text,
  cancelled_at timestamptz,
  cancelled_by uuid,
  cancellation_reason text,
  created_at timestamptz not null default clock_timestamp(),
  constraint retention_plans_status
    check (status in ('draft', 'generated', 'approved', 'cancelled', 'expired')),
  constraint retention_plans_dry_run_required
    check (dry_run = true),
  constraint retention_plans_retention_positive
    check (retention_interval > interval '0 seconds'),
  constraint retention_plans_batch_positive
    check (requested_batch_size > 0),
  constraint retention_plans_count_nonnegative
    check (candidate_count >= 0),
  constraint retention_plans_snapshot_object
    check (jsonb_typeof(planner_snapshot) = 'object'),
  constraint retention_plans_hash_format
    check (plan_hash is null or plan_hash ~ '^[0-9a-f]{64}$'),
  constraint retention_plans_generated_consistency
    check (
      status = 'draft'
      or (generated_at is not null and plan_hash is not null)
    ),
  constraint retention_plans_approved_consistency
    check (
      status <> 'approved'
      or (approved_at is not null and approved_by is not null)
    ),
  constraint retention_plans_cancelled_consistency
    check (
      status <> 'cancelled'
      or cancelled_at is not null
    ),
  constraint retention_plans_run_target_unique
    unique (maintenance_run_id, target_id)
);

create index if not exists retention_plans_status_idx
  on public.retention_plans (status, generated_at desc);

create index if not exists retention_plans_target_history_idx
  on public.retention_plans (target_key, generated_at desc);

create index if not exists retention_plans_hash_idx
  on public.retention_plans (plan_hash)
  where plan_hash is not null;

comment on table public.retention_plans
is 'Immutable dry-run retention plans. Approval changes lifecycle state only and never performs deletion.';

-- --------------------------------------------------------------------------
-- Candidate snapshot ledger
-- --------------------------------------------------------------------------

create table if not exists public.retention_plan_items (
  id uuid primary key default gen_random_uuid(),
  retention_plan_id uuid not null
    references public.retention_plans(id) on delete restrict,
  item_order integer not null,
  target_identity text not null,
  target_timestamp timestamptz not null,
  target_status text,
  candidate_snapshot jsonb not null default '{}'::jsonb,
  item_hash text not null,
  created_at timestamptz not null default clock_timestamp(),
  constraint retention_plan_items_order_positive
    check (item_order > 0),
  constraint retention_plan_items_identity_not_blank
    check (btrim(target_identity) <> ''),
  constraint retention_plan_items_snapshot_object
    check (jsonb_typeof(candidate_snapshot) = 'object'),
  constraint retention_plan_items_hash_format
    check (item_hash ~ '^[0-9a-f]{64}$'),
  constraint retention_plan_items_unique_order
    unique (retention_plan_id, item_order),
  constraint retention_plan_items_unique_identity
    unique (retention_plan_id, target_identity)
);

create index if not exists retention_plan_items_plan_timestamp_idx
  on public.retention_plan_items (
    retention_plan_id,
    target_timestamp,
    target_identity
  );

comment on table public.retention_plan_items
is 'Immutable candidate identity snapshots belonging to a generated retention plan.';

-- --------------------------------------------------------------------------
-- Approval audit ledger
-- --------------------------------------------------------------------------

create table if not exists public.retention_plan_decisions (
  id uuid primary key default gen_random_uuid(),
  retention_plan_id uuid not null
    references public.retention_plans(id) on delete restrict,
  decision text not null,
  decided_by uuid,
  reason text,
  expected_plan_hash text not null,
  decision_metadata jsonb not null default '{}'::jsonb,
  decided_at timestamptz not null default clock_timestamp(),
  constraint retention_plan_decisions_decision
    check (decision in ('approved', 'cancelled', 'expired')),
  constraint retention_plan_decisions_hash_format
    check (expected_plan_hash ~ '^[0-9a-f]{64}$'),
  constraint retention_plan_decisions_metadata_object
    check (jsonb_typeof(decision_metadata) = 'object')
);

create index if not exists retention_plan_decisions_plan_idx
  on public.retention_plan_decisions (retention_plan_id, decided_at desc);

comment on table public.retention_plan_decisions
is 'Append-only audit ledger for retention plan approvals, cancellations and expirations.';

-- --------------------------------------------------------------------------
-- Immutability guards
-- --------------------------------------------------------------------------

create or replace function public.protect_retention_plan_item_immutability()
returns trigger
language plpgsql
security invoker
set search_path = public, pg_temp
as $$
begin
  raise exception using
    errcode = '55000',
    message = 'RETENTION_PLAN_ITEM_IMMUTABLE',
    detail = 'Generated retention plan items cannot be updated or deleted.';
end;
$$;

comment on function public.protect_retention_plan_item_immutability()
is 'Rejects updates and deletes against generated retention candidate snapshots.';

drop trigger if exists trg_protect_retention_plan_items_update
  on public.retention_plan_items;

create trigger trg_protect_retention_plan_items_update
before update on public.retention_plan_items
for each row
execute function public.protect_retention_plan_item_immutability();

drop trigger if exists trg_protect_retention_plan_items_delete
  on public.retention_plan_items;

create trigger trg_protect_retention_plan_items_delete
before delete on public.retention_plan_items
for each row
execute function public.protect_retention_plan_item_immutability();

create or replace function public.protect_retention_plan_core_immutability()
returns trigger
language plpgsql
security invoker
set search_path = public, pg_temp
as $$
begin
  if old.status <> 'draft' then
    if new.maintenance_run_id is distinct from old.maintenance_run_id
       or new.target_id is distinct from old.target_id
       or new.target_key is distinct from old.target_key
       or new.target_version is distinct from old.target_version
       or new.dry_run is distinct from old.dry_run
       or new.cutoff_at is distinct from old.cutoff_at
       or new.retention_interval is distinct from old.retention_interval
       or new.requested_batch_size is distinct from old.requested_batch_size
       or new.candidate_count is distinct from old.candidate_count
       or new.truncated is distinct from old.truncated
       or new.candidate_min_timestamp is distinct from old.candidate_min_timestamp
       or new.candidate_max_timestamp is distinct from old.candidate_max_timestamp
       or new.planner_version is distinct from old.planner_version
       or new.planner_snapshot is distinct from old.planner_snapshot
       or new.plan_hash is distinct from old.plan_hash
       or new.generated_at is distinct from old.generated_at
    then
      raise exception using
        errcode = '55000',
        message = 'RETENTION_PLAN_CORE_IMMUTABLE',
        detail = 'Generated retention plan content cannot be modified.';
    end if;
  end if;

  if old.status = 'approved' and new.status <> 'approved' then
    raise exception using
      errcode = '55000',
      message = 'RETENTION_PLAN_APPROVAL_FINAL',
      detail = 'An approved retention plan cannot transition to another state.';
  end if;

  if old.status in ('cancelled', 'expired') and new.status <> old.status then
    raise exception using
      errcode = '55000',
      message = 'RETENTION_PLAN_TERMINAL_STATE',
      detail = 'A cancelled or expired retention plan cannot be reopened.';
  end if;

  return new;
end;
$$;

comment on function public.protect_retention_plan_core_immutability()
is 'Protects generated plan content while permitting audited lifecycle transitions.';

drop trigger if exists trg_protect_retention_plan_core
  on public.retention_plans;

create trigger trg_protect_retention_plan_core
before update on public.retention_plans
for each row
execute function public.protect_retention_plan_core_immutability();

-- --------------------------------------------------------------------------
-- Registry validation helper
-- --------------------------------------------------------------------------

create or replace function public.validate_retention_target_definition(
  p_target_schema text,
  p_target_table text,
  p_identity_column text,
  p_timestamp_column text,
  p_status_column text,
  p_additional_predicate_sql text
)
returns void
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
declare
  v_relation regclass;
  v_identity_type text;
  v_timestamp_type text;
begin
  if btrim(coalesce(p_target_schema, '')) <> 'public' then
    raise exception using
      errcode = '22023',
      message = 'RETENTION_TARGET_SCHEMA_NOT_ALLOWED',
      detail = 'Only the public schema may be registered.';
  end if;

  if p_target_table !~ '^[a-z][a-z0-9_]*$'
     or p_identity_column !~ '^[a-z][a-z0-9_]*$'
     or p_timestamp_column !~ '^[a-z][a-z0-9_]*$'
     or (p_status_column is not null and p_status_column !~ '^[a-z][a-z0-9_]*$')
  then
    raise exception using
      errcode = '22023',
      message = 'RETENTION_TARGET_IDENTIFIER_INVALID';
  end if;

  if p_additional_predicate_sql is not null then
    raise exception using
      errcode = '0A000',
      message = 'RETENTION_CUSTOM_PREDICATE_DISABLED',
      detail = 'Migration 068 intentionally disables custom SQL predicates.';
  end if;

  v_relation := to_regclass(format('%I.%I', p_target_schema, p_target_table));

  if v_relation is null then
    raise exception using
      errcode = '42P01',
      message = 'RETENTION_TARGET_TABLE_NOT_FOUND';
  end if;

  if not exists (
    select 1
    from pg_class c
    join pg_namespace n on n.oid = c.relnamespace
    where c.oid = v_relation
      and n.nspname = 'public'
      and c.relkind = 'r'
  ) then
    raise exception using
      errcode = '42809',
      message = 'RETENTION_TARGET_MUST_BE_TABLE';
  end if;

  select format_type(a.atttypid, a.atttypmod)
    into v_identity_type
  from pg_attribute a
  where a.attrelid = v_relation
    and a.attname = p_identity_column
    and a.attnum > 0
    and not a.attisdropped;

  if v_identity_type is null then
    raise exception using
      errcode = '42703',
      message = 'RETENTION_IDENTITY_COLUMN_NOT_FOUND';
  end if;

  select format_type(a.atttypid, a.atttypmod)
    into v_timestamp_type
  from pg_attribute a
  where a.attrelid = v_relation
    and a.attname = p_timestamp_column
    and a.attnum > 0
    and not a.attisdropped;

  if v_timestamp_type not in (
    'timestamp with time zone',
    'timestamp without time zone',
    'date'
  ) then
    raise exception using
      errcode = '42804',
      message = 'RETENTION_TIMESTAMP_COLUMN_INVALID',
      detail = coalesce(v_timestamp_type, 'missing');
  end if;

  if p_status_column is not null and not exists (
    select 1
    from pg_attribute a
    where a.attrelid = v_relation
      and a.attname = p_status_column
      and a.attnum > 0
      and not a.attisdropped
  ) then
    raise exception using
      errcode = '42703',
      message = 'RETENTION_STATUS_COLUMN_NOT_FOUND';
  end if;
end;
$$;

comment on function public.validate_retention_target_definition(text, text, text, text, text, text)
is 'Validates that a retention target is an explicitly named public table with existing identity, timestamp and optional status columns.';

-- --------------------------------------------------------------------------
-- Target registration RPC
-- --------------------------------------------------------------------------

create or replace function public.register_retention_target_rpc(
  p_target_key text,
  p_display_name text,
  p_description text,
  p_target_table text,
  p_identity_column text,
  p_timestamp_column text,
  p_status_column text,
  p_terminal_statuses text[],
  p_default_retention_interval interval,
  p_default_batch_size integer,
  p_maximum_batch_size integer,
  p_dependency_class text,
  p_planner_enabled boolean,
  p_target_config jsonb,
  p_created_by uuid
)
returns public.retention_targets
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
declare
  v_previous public.retention_targets%rowtype;
  v_new public.retention_targets%rowtype;
  v_version integer;
begin
  if btrim(coalesce(p_target_key, '')) = '' then
    raise exception using errcode = '22023', message = 'RETENTION_TARGET_KEY_REQUIRED';
  end if;

  if p_default_retention_interval is null
     or p_default_retention_interval <= interval '0 seconds'
  then
    raise exception using errcode = '22023', message = 'RETENTION_INTERVAL_INVALID';
  end if;

  perform public.validate_retention_target_definition(
    'public',
    p_target_table,
    coalesce(p_identity_column, 'id'),
    p_timestamp_column,
    p_status_column,
    null
  );

  select *
    into v_previous
  from public.retention_targets
  where target_key = p_target_key
    and retired_at is null
  for update;

  v_version := coalesce(v_previous.target_version, 0) + 1;

  if v_previous.id is not null then
    update public.retention_targets
       set retired_at = clock_timestamp(),
           planner_enabled = false,
           execution_enabled = false
     where id = v_previous.id;
  end if;

  insert into public.retention_targets (
    target_key,
    target_version,
    display_name,
    description,
    target_schema,
    target_table,
    identity_column,
    timestamp_column,
    status_column,
    terminal_statuses,
    additional_predicate_sql,
    default_retention_interval,
    default_batch_size,
    maximum_batch_size,
    dependency_class,
    planner_enabled,
    execution_enabled,
    destructive,
    target_config,
    created_by
  )
  values (
    btrim(p_target_key),
    v_version,
    btrim(p_display_name),
    p_description,
    'public',
    btrim(p_target_table),
    btrim(coalesce(p_identity_column, 'id')),
    btrim(p_timestamp_column),
    nullif(btrim(coalesce(p_status_column, '')), ''),
    coalesce(p_terminal_statuses, '{}'::text[]),
    null,
    p_default_retention_interval,
    coalesce(p_default_batch_size, 100),
    coalesce(p_maximum_batch_size, 1000),
    coalesce(p_dependency_class, 'independent'),
    coalesce(p_planner_enabled, false),
    false,
    true,
    coalesce(p_target_config, '{}'::jsonb),
    p_created_by
  )
  returning * into v_new;

  return v_new;
end;
$$;

comment on function public.register_retention_target_rpc(text, text, text, text, text, text, text, text[], interval, integer, integer, text, boolean, jsonb, uuid)
is 'Registers a new immutable version of an allowlisted retention target. Execution remains disabled.';

-- --------------------------------------------------------------------------
-- Plan request RPC
-- --------------------------------------------------------------------------

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
returns table (
  maintenance_run_id uuid,
  retention_plan_id uuid,
  run_status text,
  plan_status text,
  cutoff_at timestamptz
)
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
declare
  v_target public.retention_targets%rowtype;
  v_run public.maintenance_runs%rowtype;
  v_plan public.retention_plans%rowtype;
  v_interval interval;
  v_batch integer;
begin
  select *
    into v_target
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

  select *
    into v_run
  from public.maintenance_runs
  where idempotency_key = p_idempotency_key;

  if v_run.id is null then
    insert into public.maintenance_runs (
      policy_id,
      policy_key,
      operation_type,
      target_scope,
      trigger_type,
      requested_by,
      scheduled_for,
      status,
      dry_run,
      idempotency_key,
      correlation_id,
      causation_id,
      max_attempts,
      timeout_interval,
      request_payload
    )
    select
      mp.id,
      mp.policy_key,
      'retention_plan',
      v_target.target_key,
      'manual',
      p_requested_by,
      clock_timestamp(),
      'requested',
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
      maintenance_run_id,
      command_type,
      command_payload,
      status,
      max_attempts
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

  select *
    into v_plan
  from public.retention_plans
  where maintenance_run_id = v_run.id
    and target_id = v_target.id;

  if v_plan.id is null then
    insert into public.retention_plans (
      maintenance_run_id,
      target_id,
      target_key,
      target_version,
      status,
      dry_run,
      cutoff_at,
      retention_interval,
      requested_batch_size,
      planner_snapshot
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
$$;

comment on function public.request_retention_plan_rpc(text, text, uuid, interval, integer, jsonb, uuid, uuid)
is 'Creates an idempotent dry-run maintenance request, outbox command and draft retention plan for an enabled target.';

-- --------------------------------------------------------------------------
-- Plan builder RPC
-- --------------------------------------------------------------------------

create or replace function public.build_retention_plan_rpc(
  p_retention_plan_id uuid,
  p_maintenance_run_id uuid,
  p_lease_token uuid
)
returns public.retention_plans
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
declare
  v_plan public.retention_plans%rowtype;
  v_target public.retention_targets%rowtype;
  v_run public.maintenance_runs%rowtype;
  v_relation regclass;
  v_status_filter text := '';
  v_sql text;
  v_candidate_count integer;
  v_full_count bigint;
  v_plan_hash text;
begin
  select *
    into v_run
  from public.maintenance_runs
  where id = p_maintenance_run_id
  for update;

  if v_run.id is null then
    raise exception using errcode = 'P0002', message = 'MAINTENANCE_RUN_NOT_FOUND';
  end if;

  if v_run.status <> 'running'
     or v_run.lease_token is distinct from p_lease_token
     or v_run.lease_expires_at <= clock_timestamp()
  then
    raise exception using errcode = '55000', message = 'MAINTENANCE_RUN_LEASE_INVALID';
  end if;

  select *
    into v_plan
  from public.retention_plans
  where id = p_retention_plan_id
    and maintenance_run_id = p_maintenance_run_id
  for update;

  if v_plan.id is null then
    raise exception using errcode = 'P0002', message = 'RETENTION_PLAN_NOT_FOUND';
  end if;

  if v_plan.status <> 'draft' then
    return v_plan;
  end if;

  select *
    into v_target
  from public.retention_targets
  where id = v_plan.target_id;

  if v_target.id is null or v_target.retired_at is not null then
    raise exception using errcode = '55000', message = 'RETENTION_TARGET_VERSION_UNAVAILABLE';
  end if;

  if not v_target.planner_enabled then
    raise exception using errcode = '55000', message = 'RETENTION_TARGET_PLANNER_DISABLED';
  end if;

  perform public.validate_retention_target_definition(
    v_target.target_schema,
    v_target.target_table,
    v_target.identity_column,
    v_target.timestamp_column,
    v_target.status_column,
    v_target.additional_predicate_sql
  );

  v_relation := to_regclass(format('%I.%I', v_target.target_schema, v_target.target_table));

  if v_target.status_column is not null then
    if cardinality(v_target.terminal_statuses) = 0 then
      raise exception using errcode = '22023', message = 'RETENTION_TERMINAL_STATUSES_REQUIRED';
    end if;

    v_status_filter := format(
      ' and t.%I::text = any ($2)',
      v_target.status_column
    );
  end if;

  v_sql := format(
    'select count(*) from %s t where t.%I < $1%s',
    v_relation,
    v_target.timestamp_column,
    v_status_filter
  );

  if v_target.status_column is null then
    execute v_sql into v_full_count using v_plan.cutoff_at;
  else
    execute v_sql into v_full_count using v_plan.cutoff_at, v_target.terminal_statuses;
  end if;

  v_sql := format($fmt$
    insert into public.retention_plan_items (
      retention_plan_id,
      item_order,
      target_identity,
      target_timestamp,
      target_status,
      candidate_snapshot,
      item_hash
    )
    select
      $1,
      row_number() over (order by q.target_timestamp, q.target_identity)::integer,
      q.target_identity,
      q.target_timestamp,
      q.target_status,
      jsonb_build_object(
        'target_identity', q.target_identity,
        'target_timestamp', q.target_timestamp,
        'target_status', q.target_status,
        'target_table', $5,
        'cutoff_at', $2
      ),
      encode(
        extensions.digest(
          convert_to(
            concat_ws('|', $1::text, q.target_identity, q.target_timestamp::text, coalesce(q.target_status, '')),
            'UTF8'
          ),
          'sha256'
        ),
        'hex'
      )
    from (
      select
        t.%I::text as target_identity,
        t.%I::timestamptz as target_timestamp,
        %s as target_status
      from %s t
      where t.%I < $2%s
      order by t.%I, t.%I::text
      limit $4
    ) q
  $fmt$,
    v_target.identity_column,
    v_target.timestamp_column,
    case
      when v_target.status_column is null then 'null::text'
      else format('t.%I::text', v_target.status_column)
    end,
    v_relation,
    v_target.timestamp_column,
    case
      when v_target.status_column is null then ''
      else format(' and t.%I::text = any ($3)', v_target.status_column)
    end,
    v_target.timestamp_column,
    v_target.identity_column
  );

  execute v_sql
    using
      v_plan.id,
      v_plan.cutoff_at,
      v_target.terminal_statuses,
      v_plan.requested_batch_size,
      format('%I.%I', v_target.target_schema, v_target.target_table);

  get diagnostics v_candidate_count = row_count;

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
                 'candidate_count', v_candidate_count,
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
    into v_plan_hash
  from public.retention_plan_items i
  where i.retention_plan_id = v_plan.id;

  update public.retention_plans
     set status = 'generated',
         candidate_count = v_candidate_count,
         truncated = v_full_count > v_candidate_count,
         candidate_min_timestamp = (
           select min(target_timestamp)
           from public.retention_plan_items
           where retention_plan_id = v_plan.id
         ),
         candidate_max_timestamp = (
           select max(target_timestamp)
           from public.retention_plan_items
           where retention_plan_id = v_plan.id
         ),
         plan_hash = v_plan_hash,
         generated_at = clock_timestamp(),
         planner_snapshot = planner_snapshot || jsonb_build_object(
           'total_eligible_count', v_full_count,
           'selected_candidate_count', v_candidate_count,
           'truncated', v_full_count > v_candidate_count,
           'validated_at', clock_timestamp()
         )
   where id = v_plan.id
   returning * into v_plan;

  update public.maintenance_runs
     set metrics = metrics || jsonb_build_object(
           'retention_plan_id', v_plan.id,
           'candidate_count', v_candidate_count,
           'total_eligible_count', v_full_count,
           'plan_hash', v_plan_hash
         ),
         heartbeat_at = clock_timestamp()
   where id = v_run.id;

  return v_plan;
end;
$$;

comment on function public.build_retention_plan_rpc(uuid, uuid, uuid)
is 'Builds an immutable dry-run candidate snapshot under a valid maintenance-run lease. It never modifies target data.';

-- --------------------------------------------------------------------------
-- Approval and cancellation RPCs
-- --------------------------------------------------------------------------

create or replace function public.approve_retention_plan_rpc(
  p_retention_plan_id uuid,
  p_expected_plan_hash text,
  p_approved_by uuid,
  p_reason text,
  p_decision_metadata jsonb
)
returns public.retention_plans
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
declare
  v_plan public.retention_plans%rowtype;
begin
  if p_approved_by is null then
    raise exception using errcode = '22023', message = 'RETENTION_APPROVER_REQUIRED';
  end if;

  select *
    into v_plan
  from public.retention_plans
  where id = p_retention_plan_id
  for update;

  if v_plan.id is null then
    raise exception using errcode = 'P0002', message = 'RETENTION_PLAN_NOT_FOUND';
  end if;

  if v_plan.status = 'approved' then
    if v_plan.plan_hash is distinct from p_expected_plan_hash then
      raise exception using errcode = '40001', message = 'RETENTION_PLAN_HASH_MISMATCH';
    end if;
    return v_plan;
  end if;

  if v_plan.status <> 'generated' then
    raise exception using errcode = '55000', message = 'RETENTION_PLAN_NOT_APPROVABLE';
  end if;

  if v_plan.plan_hash is distinct from lower(p_expected_plan_hash) then
    raise exception using errcode = '40001', message = 'RETENTION_PLAN_HASH_MISMATCH';
  end if;

  update public.retention_plans
     set status = 'approved',
         approved_at = clock_timestamp(),
         approved_by = p_approved_by,
         approval_reason = nullif(btrim(coalesce(p_reason, '')), '')
   where id = v_plan.id
   returning * into v_plan;

  insert into public.retention_plan_decisions (
    retention_plan_id,
    decision,
    decided_by,
    reason,
    expected_plan_hash,
    decision_metadata
  )
  values (
    v_plan.id,
    'approved',
    p_approved_by,
    nullif(btrim(coalesce(p_reason, '')), ''),
    v_plan.plan_hash,
    coalesce(p_decision_metadata, '{}'::jsonb)
  );

  return v_plan;
end;
$$;

comment on function public.approve_retention_plan_rpc(uuid, text, uuid, text, jsonb)
is 'Approves a generated plan only when the caller supplies its exact SHA-256 hash. Approval never executes housekeeping.';

create or replace function public.cancel_retention_plan_rpc(
  p_retention_plan_id uuid,
  p_expected_plan_hash text,
  p_cancelled_by uuid,
  p_reason text,
  p_decision_metadata jsonb
)
returns public.retention_plans
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
declare
  v_plan public.retention_plans%rowtype;
begin
  select *
    into v_plan
  from public.retention_plans
  where id = p_retention_plan_id
  for update;

  if v_plan.id is null then
    raise exception using errcode = 'P0002', message = 'RETENTION_PLAN_NOT_FOUND';
  end if;

  if v_plan.status = 'cancelled' then
    return v_plan;
  end if;

  if v_plan.status not in ('draft', 'generated') then
    raise exception using errcode = '55000', message = 'RETENTION_PLAN_NOT_CANCELLABLE';
  end if;

  if v_plan.plan_hash is not null
     and v_plan.plan_hash is distinct from lower(p_expected_plan_hash)
  then
    raise exception using errcode = '40001', message = 'RETENTION_PLAN_HASH_MISMATCH';
  end if;

  update public.retention_plans
     set status = 'cancelled',
         cancelled_at = clock_timestamp(),
         cancelled_by = p_cancelled_by,
         cancellation_reason = nullif(btrim(coalesce(p_reason, '')), '')
   where id = v_plan.id
   returning * into v_plan;

  if v_plan.plan_hash is not null then
    insert into public.retention_plan_decisions (
      retention_plan_id,
      decision,
      decided_by,
      reason,
      expected_plan_hash,
      decision_metadata
    )
    values (
      v_plan.id,
      'cancelled',
      p_cancelled_by,
      nullif(btrim(coalesce(p_reason, '')), ''),
      v_plan.plan_hash,
      coalesce(p_decision_metadata, '{}'::jsonb)
    );
  end if;

  return v_plan;
end;
$$;

comment on function public.cancel_retention_plan_rpc(uuid, text, uuid, text, jsonb)
is 'Cancels a draft or generated retention plan. Generated plans require the exact expected hash.';

-- --------------------------------------------------------------------------
-- Read models
-- --------------------------------------------------------------------------

create or replace view public.retention_plan_status_v1
with (security_invoker = true)
as
select
  rp.id as retention_plan_id,
  rp.maintenance_run_id,
  rp.target_key,
  rp.target_version,
  rt.display_name as target_display_name,
  rt.target_schema,
  rt.target_table,
  rt.identity_column,
  rt.timestamp_column,
  rt.status_column,
  rt.terminal_statuses,
  rt.dependency_class,
  rt.execution_enabled,
  rp.status,
  rp.dry_run,
  rp.cutoff_at,
  rp.retention_interval,
  rp.requested_batch_size,
  rp.candidate_count,
  rp.truncated,
  rp.candidate_min_timestamp,
  rp.candidate_max_timestamp,
  rp.planner_version,
  rp.plan_hash,
  rp.generated_at,
  rp.approved_at,
  rp.approved_by,
  rp.cancelled_at,
  rp.created_at,
  mr.status as maintenance_run_status,
  mr.worker_id,
  mr.error_code,
  mr.error_message
from public.retention_plans rp
join public.retention_targets rt
  on rt.id = rp.target_id
join public.maintenance_runs mr
  on mr.id = rp.maintenance_run_id;

comment on view public.retention_plan_status_v1
is 'Operational read model joining retention plans, target definitions and maintenance-run state.';

create or replace view public.retention_plan_attention_v1
with (security_invoker = true)
as
select
  s.*,
  case
    when s.maintenance_run_status = 'failed' then 'maintenance_run_failed'
    when s.status = 'generated' and s.generated_at < clock_timestamp() - interval '24 hours'
      then 'generated_plan_awaiting_decision'
    when s.status = 'approved' and s.execution_enabled = false
      then 'approved_plan_execution_disabled'
    when s.truncated then 'candidate_batch_truncated'
    else 'review_required'
  end as attention_reason
from public.retention_plan_status_v1 s
where s.maintenance_run_status = 'failed'
   or (s.status = 'generated' and s.generated_at < clock_timestamp() - interval '24 hours')
   or (s.status = 'approved' and s.execution_enabled = false)
   or s.truncated;

comment on view public.retention_plan_attention_v1
is 'Retention plans requiring operator attention. Approved plans remain non-executable in migration 068.';

-- --------------------------------------------------------------------------
-- RLS and privileges
-- --------------------------------------------------------------------------

alter table public.retention_targets enable row level security;
alter table public.retention_plans enable row level security;
alter table public.retention_plan_items enable row level security;
alter table public.retention_plan_decisions enable row level security;

drop policy if exists retention_targets_service_role_all
  on public.retention_targets;
create policy retention_targets_service_role_all
  on public.retention_targets
  for all
  to service_role
  using (true)
  with check (true);

drop policy if exists retention_plans_service_role_all
  on public.retention_plans;
create policy retention_plans_service_role_all
  on public.retention_plans
  for all
  to service_role
  using (true)
  with check (true);

drop policy if exists retention_plan_items_service_role_all
  on public.retention_plan_items;
create policy retention_plan_items_service_role_all
  on public.retention_plan_items
  for all
  to service_role
  using (true)
  with check (true);

drop policy if exists retention_plan_decisions_service_role_all
  on public.retention_plan_decisions;
create policy retention_plan_decisions_service_role_all
  on public.retention_plan_decisions
  for all
  to service_role
  using (true)
  with check (true);

revoke all on table public.retention_targets from public, anon, authenticated;
revoke all on table public.retention_plans from public, anon, authenticated;
revoke all on table public.retention_plan_items from public, anon, authenticated;
revoke all on table public.retention_plan_decisions from public, anon, authenticated;

grant select, insert, update, delete on table public.retention_targets to service_role;
grant select, insert, update, delete on table public.retention_plans to service_role;
grant select, insert, update, delete on table public.retention_plan_items to service_role;
grant select, insert, update, delete on table public.retention_plan_decisions to service_role;

revoke all on table public.retention_plan_status_v1 from public, anon, authenticated;
revoke all on table public.retention_plan_attention_v1 from public, anon, authenticated;
grant select on table public.retention_plan_status_v1 to service_role;
grant select on table public.retention_plan_attention_v1 to service_role;

revoke execute on function public.validate_retention_target_definition(text, text, text, text, text, text)
  from public, anon, authenticated;
revoke execute on function public.register_retention_target_rpc(text, text, text, text, text, text, text, text[], interval, integer, integer, text, boolean, jsonb, uuid)
  from public, anon, authenticated;
revoke execute on function public.request_retention_plan_rpc(text, text, uuid, interval, integer, jsonb, uuid, uuid)
  from public, anon, authenticated;
revoke execute on function public.build_retention_plan_rpc(uuid, uuid, uuid)
  from public, anon, authenticated;
revoke execute on function public.approve_retention_plan_rpc(uuid, text, uuid, text, jsonb)
  from public, anon, authenticated;
revoke execute on function public.cancel_retention_plan_rpc(uuid, text, uuid, text, jsonb)
  from public, anon, authenticated;

grant execute on function public.validate_retention_target_definition(text, text, text, text, text, text)
  to service_role;
grant execute on function public.register_retention_target_rpc(text, text, text, text, text, text, text, text[], interval, integer, integer, text, boolean, jsonb, uuid)
  to service_role;
grant execute on function public.request_retention_plan_rpc(text, text, uuid, interval, integer, jsonb, uuid, uuid)
  to service_role;
grant execute on function public.build_retention_plan_rpc(uuid, uuid, uuid)
  to service_role;
grant execute on function public.approve_retention_plan_rpc(uuid, text, uuid, text, jsonb)
  to service_role;
grant execute on function public.cancel_retention_plan_rpc(uuid, text, uuid, text, jsonb)
  to service_role;

-- --------------------------------------------------------------------------
-- Seed planner policy
-- --------------------------------------------------------------------------

insert into public.maintenance_policies (
  policy_key,
  policy_version,
  display_name,
  description,
  operation_type,
  target_scope,
  schedule_expression,
  retention_interval,
  batch_size,
  max_attempts,
  timeout_interval,
  dry_run_default,
  destructive,
  enabled,
  policy_config
)
values (
  'retention_planner',
  1,
  'Retention Planner',
  'Creates immutable dry-run candidate plans. It never executes housekeeping.',
  'retention_plan',
  'runtime',
  null,
  interval '90 days',
  100,
  3,
  interval '15 minutes',
  true,
  true,
  false,
  jsonb_build_object(
    'planner_version', 'retention-planner-v1',
    'approval_required', true,
    'execution_enabled', false,
    'custom_predicates_enabled', false
  )
)
on conflict (policy_key, policy_version) do nothing;

-- --------------------------------------------------------------------------
-- Seed conservative target allowlist
--
-- All targets are planner-disabled by default. The definitions document safe
-- candidate criteria without activating scans. Enabling requires a later,
-- explicit operator action and E2E certification.
-- --------------------------------------------------------------------------

insert into public.retention_targets (
  target_key,
  target_version,
  display_name,
  description,
  target_schema,
  target_table,
  identity_column,
  timestamp_column,
  status_column,
  terminal_statuses,
  default_retention_interval,
  default_batch_size,
  maximum_batch_size,
  dependency_class,
  planner_enabled,
  execution_enabled,
  destructive,
  target_config
)
values
  (
    'workflow_events_history',
    1,
    'Workflow Events History',
    'Historical workflow events. Child records must be handled before workflow parents.',
    'public',
    'live_runtime_workflow_events',
    'id',
    'occurred_at',
    null,
    '{}'::text[],
    interval '180 days',
    250,
    1000,
    'child_first',
    false,
    false,
    true,
    jsonb_build_object('parent_table', 'live_runtime_workflows')
  ),
  (
    'workflow_timeline_history',
    1,
    'Workflow Timeline History',
    'Denormalized workflow timeline history retained for diagnostics.',
    'public',
    'live_runtime_workflow_timeline',
    'id',
    'occurred_at',
    null,
    '{}'::text[],
    interval '180 days',
    250,
    1000,
    'child_first',
    false,
    false,
    true,
    jsonb_build_object('parent_table', 'live_runtime_workflows')
  ),
  (
    'runtime_jobs_terminal',
    1,
    'Terminal Runtime Jobs',
    'Completed terminal runtime jobs older than the retention window.',
    'public',
    'live_runtime_jobs',
    'id',
    'completed_at',
    'status',
    array['completed', 'failed', 'cancelled']::text[],
    interval '180 days',
    100,
    500,
    'parent_guarded',
    false,
    false,
    true,
    jsonb_build_object('guard_reference', 'live_runtime_workflow_steps.job_id')
  ),
  (
    'recovery_attempts_terminal',
    1,
    'Terminal Recovery Attempts',
    'Finished recovery attempts belonging to terminal recovery requests.',
    'public',
    'live_runtime_recovery_attempts',
    'id',
    'finished_at',
    'status',
    array['succeeded', 'failed', 'cancelled']::text[],
    interval '180 days',
    100,
    500,
    'child_first',
    false,
    false,
    true,
    jsonb_build_object('parent_table', 'live_runtime_recovery_requests')
  ),
  (
    'round_simulation_events_history',
    1,
    'Round Simulation Events History',
    'Historical simulation events. Parent simulation immutability remains protected.',
    'public',
    'round_simulation_events',
    'id',
    'occurred_at',
    null,
    '{}'::text[],
    interval '365 days',
    250,
    1000,
    'child_first',
    false,
    false,
    true,
    jsonb_build_object('parent_table', 'round_simulations')
  )
on conflict (target_key, target_version) do nothing;

commit;
