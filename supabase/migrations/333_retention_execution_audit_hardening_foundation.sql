-- ============================================================================
-- MIGRATION 333
-- Retention execution audit hardening foundation.
--
-- Adds:
--   1) append-only governance for retention_plan_decisions
--   2) a controlled retention_execution_attempts journal
--   3) postgres-only begin/finalize attempt authorities
--
-- This migration does NOT enable target execution and does NOT perform deletes.
-- ============================================================================

create or replace function public.protect_retention_plan_decision_append_only()
returns trigger
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
begin
  raise exception using
    errcode = '55000',
    message = 'RETENTION_PLAN_DECISION_APPEND_ONLY';
end;
$function$;

drop trigger if exists trg_protect_retention_plan_decisions_append_only
  on public.retention_plan_decisions;

create trigger trg_protect_retention_plan_decisions_append_only
before update or delete on public.retention_plan_decisions
for each row
execute function public.protect_retention_plan_decision_append_only();

revoke insert, update, delete, truncate
on table public.retention_plan_decisions
from service_role;

grant select
on table public.retention_plan_decisions
to service_role;

create table if not exists public.retention_execution_attempts (
  id uuid primary key default gen_random_uuid(),
  retention_plan_id uuid not null
    references public.retention_plans(id) on delete restrict,
  target_key text not null,
  target_version integer not null,
  expected_plan_hash text not null,
  attempt_number integer not null,
  attempt_status text not null default 'started',
  requested_batch_size integer not null,
  execution_batch_id uuid,
  deleted_count integer,
  skipped_already_executed_count integer,
  remaining_unexecuted_count integer,
  error_code text,
  error_message text,
  attempted_by uuid not null,
  started_at timestamptz not null default clock_timestamp(),
  completed_at timestamptz,
  attempt_metadata jsonb not null default '{}'::jsonb,

  constraint retention_execution_attempts_target_key_not_blank
    check (btrim(target_key) <> ''),

  constraint retention_execution_attempts_target_version_positive
    check (target_version > 0),

  constraint retention_execution_attempts_hash_format
    check (expected_plan_hash ~ '^[0-9a-f]{64}$'),

  constraint retention_execution_attempts_number_positive
    check (attempt_number > 0),

  constraint retention_execution_attempts_batch_positive
    check (requested_batch_size > 0),

  constraint retention_execution_attempts_status
    check (attempt_status in ('started','succeeded','failed','blocked')),

  constraint retention_execution_attempts_metadata_object
    check (jsonb_typeof(attempt_metadata) = 'object'),

  constraint retention_execution_attempts_completion
    check (
      (attempt_status = 'started' and completed_at is null)
      or
      (attempt_status <> 'started' and completed_at is not null)
    ),

  constraint retention_execution_attempts_success_counts
    check (
      attempt_status <> 'succeeded'
      or (
        deleted_count is not null
        and skipped_already_executed_count is not null
        and remaining_unexecuted_count is not null
        and deleted_count >= 0
        and skipped_already_executed_count >= 0
        and remaining_unexecuted_count >= 0
      )
    ),

  constraint retention_execution_attempts_failure_code
    check (
      attempt_status not in ('failed','blocked')
      or nullif(btrim(coalesce(error_code,'')), '') is not null
    ),

  constraint retention_execution_attempts_plan_number_uq
    unique (retention_plan_id, attempt_number)
);

create index if not exists retention_execution_attempts_plan_idx
  on public.retention_execution_attempts(retention_plan_id, attempt_number desc);

create index if not exists retention_execution_attempts_started_idx
  on public.retention_execution_attempts(started_at desc);

create or replace function public.guard_retention_execution_attempt_transition()
returns trigger
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
begin
  if tg_op = 'DELETE' then
    raise exception using
      errcode = '55000',
      message = 'RETENTION_EXECUTION_ATTEMPT_DELETE_FORBIDDEN';
  end if;

  if old.attempt_status <> 'started' then
    raise exception using
      errcode = '55000',
      message = 'RETENTION_EXECUTION_ATTEMPT_TERMINAL';
  end if;

  if new.id <> old.id
     or new.retention_plan_id <> old.retention_plan_id
     or new.target_key <> old.target_key
     or new.target_version <> old.target_version
     or new.expected_plan_hash <> old.expected_plan_hash
     or new.attempt_number <> old.attempt_number
     or new.requested_batch_size <> old.requested_batch_size
     or new.attempted_by <> old.attempted_by
     or new.started_at <> old.started_at
  then
    raise exception using
      errcode = '55000',
      message = 'RETENTION_EXECUTION_ATTEMPT_IDENTITY_IMMUTABLE';
  end if;

  if new.attempt_status not in ('succeeded','failed','blocked') then
    raise exception using
      errcode = '55000',
      message = 'RETENTION_EXECUTION_ATTEMPT_TRANSITION_INVALID';
  end if;

  return new;
end;
$function$;

drop trigger if exists trg_guard_retention_execution_attempt
  on public.retention_execution_attempts;

create trigger trg_guard_retention_execution_attempt
before update or delete on public.retention_execution_attempts
for each row
execute function public.guard_retention_execution_attempt_transition();

create or replace function public.begin_retention_execution_attempt_rpc(
  p_retention_plan_id uuid,
  p_expected_plan_hash text,
  p_requested_batch_size integer,
  p_attempted_by uuid,
  p_attempt_metadata jsonb default '{}'::jsonb
)
returns public.retention_execution_attempts
language plpgsql
security definer
set search_path to 'public', 'extensions', 'pg_temp'
as $function$
declare
  v_plan public.retention_plans%rowtype;
  v_target public.retention_targets%rowtype;
  v_attempt public.retention_execution_attempts%rowtype;
  v_attempt_number integer;
  v_batch integer;
begin
  if p_retention_plan_id is null then
    raise exception using
      errcode = '22004',
      message = 'RETENTION_PLAN_ID_REQUIRED';
  end if;

  if p_attempted_by is null then
    raise exception using
      errcode = '22023',
      message = 'RETENTION_EXECUTION_ATTEMPT_ACTOR_REQUIRED';
  end if;

  if p_expected_plan_hash is null
     or lower(btrim(p_expected_plan_hash)) !~ '^[0-9a-f]{64}$'
  then
    raise exception using
      errcode = '22023',
      message = 'RETENTION_PLAN_HASH_REQUIRED';
  end if;

  if jsonb_typeof(coalesce(p_attempt_metadata, '{}'::jsonb)) <> 'object' then
    raise exception using
      errcode = '22023',
      message = 'RETENTION_EXECUTION_ATTEMPT_METADATA_INVALID';
  end if;

  perform pg_advisory_xact_lock(
    hashtextextended('retention-execution-attempt:' || p_retention_plan_id::text, 0)
  );

  select *
    into v_plan
  from public.retention_plans
  where id = p_retention_plan_id
  for update;

  if not found then
    raise exception using
      errcode = 'P0002',
      message = 'RETENTION_PLAN_NOT_FOUND';
  end if;

  if v_plan.status <> 'approved' then
    raise exception using
      errcode = '55000',
      message = 'RETENTION_PLAN_NOT_EXECUTABLE';
  end if;

  if v_plan.plan_hash is distinct from lower(btrim(p_expected_plan_hash)) then
    raise exception using
      errcode = '40001',
      message = 'RETENTION_PLAN_HASH_MISMATCH';
  end if;

  select rt.*
    into v_target
  from public.retention_targets rt
  where rt.id = v_plan.target_id
    and rt.target_key = v_plan.target_key
    and rt.target_version = v_plan.target_version
    and rt.retired_at is null;

  if not found then
    raise exception using
      errcode = '55000',
      message = 'RETENTION_TARGET_VERSION_UNAVAILABLE';
  end if;

  if not v_target.execution_enabled then
    raise exception using
      errcode = '55000',
      message = 'RETENTION_TARGET_EXECUTION_DISABLED';
  end if;

  v_batch := coalesce(p_requested_batch_size, v_target.default_batch_size);

  if v_batch <= 0 or v_batch > v_target.maximum_batch_size then
    raise exception using
      errcode = '22023',
      message = 'RETENTION_EXECUTION_BATCH_SIZE_INVALID';
  end if;

  select coalesce(max(a.attempt_number), 0) + 1
    into v_attempt_number
  from public.retention_execution_attempts a
  where a.retention_plan_id = v_plan.id;

  insert into public.retention_execution_attempts (
    retention_plan_id,
    target_key,
    target_version,
    expected_plan_hash,
    attempt_number,
    attempt_status,
    requested_batch_size,
    attempted_by,
    attempt_metadata
  )
  values (
    v_plan.id,
    v_plan.target_key,
    v_plan.target_version,
    v_plan.plan_hash,
    v_attempt_number,
    'started',
    v_batch,
    p_attempted_by,
    coalesce(p_attempt_metadata, '{}'::jsonb)
  )
  returning * into v_attempt;

  return v_attempt;
end;
$function$;

create or replace function public.finalize_retention_execution_attempt_rpc(
  p_attempt_id uuid,
  p_status text,
  p_execution_batch_id uuid,
  p_deleted_count integer,
  p_skipped_count integer,
  p_remaining_count integer,
  p_error_code text,
  p_error_message text,
  p_attempt_metadata jsonb default '{}'::jsonb
)
returns public.retention_execution_attempts
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
  v_attempt public.retention_execution_attempts%rowtype;
  v_status text := lower(btrim(coalesce(p_status,'')));
begin
  if v_status not in ('succeeded','failed','blocked') then
    raise exception using
      errcode = '22023',
      message = 'RETENTION_EXECUTION_ATTEMPT_FINAL_STATUS_INVALID';
  end if;

  if jsonb_typeof(coalesce(p_attempt_metadata, '{}'::jsonb)) <> 'object' then
    raise exception using
      errcode = '22023',
      message = 'RETENTION_EXECUTION_ATTEMPT_METADATA_INVALID';
  end if;

  select *
    into v_attempt
  from public.retention_execution_attempts
  where id = p_attempt_id
  for update;

  if not found then
    raise exception using
      errcode = 'P0002',
      message = 'RETENTION_EXECUTION_ATTEMPT_NOT_FOUND';
  end if;

  if v_attempt.attempt_status <> 'started' then
    raise exception using
      errcode = '55000',
      message = 'RETENTION_EXECUTION_ATTEMPT_TERMINAL';
  end if;

  if v_status = 'succeeded' and (
    p_deleted_count is null
    or p_skipped_count is null
    or p_remaining_count is null
    or p_deleted_count < 0
    or p_skipped_count < 0
    or p_remaining_count < 0
  ) then
    raise exception using
      errcode = '22023',
      message = 'RETENTION_EXECUTION_ATTEMPT_COUNTS_INVALID';
  end if;

  if v_status in ('failed','blocked')
     and nullif(btrim(coalesce(p_error_code,'')), '') is null
  then
    raise exception using
      errcode = '22023',
      message = 'RETENTION_EXECUTION_ATTEMPT_ERROR_CODE_REQUIRED';
  end if;

  update public.retention_execution_attempts
     set attempt_status = v_status,
         execution_batch_id = p_execution_batch_id,
         deleted_count = p_deleted_count,
         skipped_already_executed_count = p_skipped_count,
         remaining_unexecuted_count = p_remaining_count,
         error_code = nullif(btrim(coalesce(p_error_code,'')), ''),
         error_message = nullif(p_error_message, ''),
         completed_at = clock_timestamp(),
         attempt_metadata = attempt_metadata || coalesce(p_attempt_metadata, '{}'::jsonb)
   where id = v_attempt.id
  returning * into v_attempt;

  return v_attempt;
end;
$function$;

revoke all on table public.retention_execution_attempts from public;
revoke all on table public.retention_execution_attempts from anon;
revoke all on table public.retention_execution_attempts from authenticated;
revoke all on table public.retention_execution_attempts from service_role;

grant select on table public.retention_execution_attempts to service_role;

revoke all on function public.begin_retention_execution_attempt_rpc(
  uuid,text,integer,uuid,jsonb
) from public;

revoke all on function public.begin_retention_execution_attempt_rpc(
  uuid,text,integer,uuid,jsonb
) from service_role;

revoke all on function public.finalize_retention_execution_attempt_rpc(
  uuid,text,uuid,integer,integer,integer,text,text,jsonb
) from public;

revoke all on function public.finalize_retention_execution_attempt_rpc(
  uuid,text,uuid,integer,integer,integer,text,text,jsonb
) from service_role;

revoke all on function public.protect_retention_plan_decision_append_only()
from public;

revoke all on function public.protect_retention_plan_decision_append_only()
from service_role;

revoke all on function public.guard_retention_execution_attempt_transition()
from public;

revoke all on function public.guard_retention_execution_attempt_transition()
from service_role;