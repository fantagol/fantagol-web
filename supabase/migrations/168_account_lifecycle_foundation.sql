-- ============================================================================
-- FANTAGOL
-- Migration 168: Account Lifecycle & Data Erasure Foundation
-- Phase 13.5.2
--
-- Purpose
--   Introduce the additive, inactive-by-default persistence foundation for the
--   Account Lifecycle & Data Erasure Engine.
--
-- Scope
--   - engine registration and dependency graph
--   - lifecycle policy catalogue
--   - pseudonymous retention subjects
--   - lifecycle aggregate
--   - deletion requests
--   - immutable erasure-run plan snapshots
--   - canonical step catalogue and durable step evidence
--   - versioned JSONB erasure rules
--   - append-only non-identifying deletion audit
--   - RLS, grants, transition guards and structural assertions
--
-- Safety
--   - no existing user/domain table is altered;
--   - no account deletion command is introduced;
--   - no scheduler or worker is enabled;
--   - no Auth, Storage, Club, membership, prediction or commercial row is
--     deleted, anonymised or detached;
--   - the engine is registered as installed, runtime-disabled and uncertified.
-- ============================================================================

begin;

create extension if not exists pgcrypto with schema extensions;

-- --------------------------------------------------------------------------
-- 1. Engine registration
-- --------------------------------------------------------------------------

do $register_engine$
declare
  v_installation_order integer;
begin
  select coalesce(max(installation_order), 0) + 10
    into v_installation_order
  from public.platform_engine_registry
  where engine_code <> 'account_lifecycle_engine';

  insert into public.platform_engine_registry (
    engine_code,
    engine_name,
    engine_version,
    engine_kind,
    lifecycle_status,
    runtime_enabled,
    is_certified,
    certification_version,
    certified_at,
    owner_scope,
    installation_order,
    dependencies,
    metadata
  )
  values (
    'account_lifecycle_engine',
    'Account Lifecycle & Data Erasure Engine',
    '1.0.0',
    'governance',
    'installed',
    false,
    false,
    null,
    null,
    'platform',
    v_installation_order,
    '[
      "core_engine",
      "competition_engine",
      "workflow_engine",
      "recovery_engine",
      "maintenance_engine",
      "platform_governance_engine"
    ]'::jsonb,
    jsonb_build_object(
      'phase', '13.5.2',
      'contract', 'account-lifecycle-data-erasure-v1',
      'migration', 168,
      'auth_boundary', 'delete-last',
      'competitive_identity', 'league_members',
      'commercial_identity', 'data_retention_subjects',
      'automatic_execution', false,
      'foundation_only', true
    )
  )
  on conflict (engine_code) do update
  set
    engine_name = excluded.engine_name,
    engine_version = excluded.engine_version,
    engine_kind = excluded.engine_kind,
    lifecycle_status = case
      when public.platform_engine_registry.lifecycle_status in ('active','degraded')
        then public.platform_engine_registry.lifecycle_status
      else excluded.lifecycle_status
    end,
    runtime_enabled = public.platform_engine_registry.runtime_enabled,
    is_certified = public.platform_engine_registry.is_certified,
    certification_version = public.platform_engine_registry.certification_version,
    certified_at = public.platform_engine_registry.certified_at,
    owner_scope = excluded.owner_scope,
    dependencies = excluded.dependencies,
    metadata = public.platform_engine_registry.metadata || excluded.metadata,
    updated_at = now();
end;
$register_engine$;

insert into public.platform_engine_dependencies (
  dependent_engine_code,
  dependency_engine_code,
  dependency_type,
  minimum_version,
  maximum_version_exclusive,
  requires_runtime_enabled,
  requires_certification,
  allowed_dependency_statuses,
  enabled,
  rationale,
  metadata
)
values
  (
    'account_lifecycle_engine','core_engine','required','1.0.0',null,
    true,true,array['active','degraded']::text[],true,
    'Lifecycle identity, security and authoritative database contracts require the certified Core Engine.',
    '{"migration":168,"contract":"account-lifecycle-data-erasure-v1"}'::jsonb
  ),
  (
    'account_lifecycle_engine','competition_engine','required','1.0.0',null,
    true,true,array['active','degraded']::text[],true,
    'Competitive-history preservation and governance succession depend on canonical competition and membership contracts.',
    '{"migration":168,"contract":"account-lifecycle-data-erasure-v1"}'::jsonb
  ),
  (
    'account_lifecycle_engine','workflow_engine','runtime','1.0.0',null,
    true,true,array['active','degraded']::text[],true,
    'Account erasure is a durable multi-step business workflow and must use the certified Workflow Engine.',
    '{"migration":168,"contract":"account-lifecycle-data-erasure-v1"}'::jsonb
  ),
  (
    'account_lifecycle_engine','recovery_engine','runtime','1.0.0',null,
    true,true,array['active','degraded']::text[],true,
    'Interrupted or failed erasure workflows require deterministic recovery and resumability.',
    '{"migration":168,"contract":"account-lifecycle-data-erasure-v1"}'::jsonb
  ),
  (
    'account_lifecycle_engine','maintenance_engine','runtime','1.0.0',null,
    true,true,array['active','degraded']::text[],true,
    'Due-request scheduling, reconciliation and later technical retention integrate with the maintenance runtime.',
    '{"migration":168,"contract":"account-lifecycle-data-erasure-v1"}'::jsonb
  ),
  (
    'account_lifecycle_engine','platform_governance_engine','required','1.0.0',null,
    true,true,array['active','degraded']::text[],true,
    'Engine activation, policy ownership and certification are governed by the Platform Governance Engine.',
    '{"migration":168,"contract":"account-lifecycle-data-erasure-v1"}'::jsonb
  )
on conflict (dependent_engine_code, dependency_engine_code) do update
set
  dependency_type = excluded.dependency_type,
  minimum_version = excluded.minimum_version,
  maximum_version_exclusive = excluded.maximum_version_exclusive,
  requires_runtime_enabled = excluded.requires_runtime_enabled,
  requires_certification = excluded.requires_certification,
  allowed_dependency_statuses = excluded.allowed_dependency_statuses,
  enabled = excluded.enabled,
  rationale = excluded.rationale,
  metadata = public.platform_engine_dependencies.metadata || excluded.metadata,
  updated_at = now();

select public.refresh_platform_engine_dependencies_cache('account_lifecycle_engine');

-- --------------------------------------------------------------------------
-- 2. Shared helpers
-- --------------------------------------------------------------------------

create or replace function public.set_account_lifecycle_updated_at()
returns trigger
language plpgsql
security invoker
set search_path = public, pg_catalog
as $function$
begin
  new.updated_at := clock_timestamp();
  return new;
end;
$function$;

comment on function public.set_account_lifecycle_updated_at()
is 'Maintains updated_at on mutable Account Lifecycle Engine aggregates.';

create or replace function public.protect_account_deletion_audit_append_only()
returns trigger
language plpgsql
security invoker
set search_path = public, pg_catalog
as $function$
begin
  raise exception using
    errcode = '55000',
    message = 'ACCOUNT_DELETION_AUDIT_APPEND_ONLY';
end;
$function$;

comment on function public.protect_account_deletion_audit_append_only()
is 'Rejects updates and deletes against the append-only account deletion audit.';

-- --------------------------------------------------------------------------
-- 3. Lifecycle policies
-- --------------------------------------------------------------------------

create table if not exists public.account_lifecycle_policies (
  id uuid primary key default extensions.gen_random_uuid(),
  policy_code text not null,
  policy_version integer not null,
  display_name text not null,
  description text,
  cooling_off_interval interval not null,
  minimum_recent_auth_age interval not null,
  automatic_execution_enabled boolean not null default false,
  public_request_enabled boolean not null default true,
  authenticated_request_enabled boolean not null default true,
  workflow_code text not null default 'ACCOUNT_DELETION_V1',
  workflow_version text not null default '1.0.0',
  effective_from timestamptz not null,
  retired_at timestamptz,
  policy_config jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default clock_timestamp(),
  updated_at timestamptz not null default clock_timestamp(),

  constraint account_lifecycle_policies_identity_uq
    unique (policy_code, policy_version),
  constraint account_lifecycle_policies_code_ck
    check (btrim(policy_code) <> '' and policy_code = upper(policy_code)),
  constraint account_lifecycle_policies_version_ck
    check (policy_version > 0),
  constraint account_lifecycle_policies_name_ck
    check (btrim(display_name) <> ''),
  constraint account_lifecycle_policies_intervals_ck
    check (
      cooling_off_interval >= interval '0 seconds'
      and minimum_recent_auth_age >= interval '0 seconds'
    ),
  constraint account_lifecycle_policies_workflow_ck
    check (
      btrim(workflow_code) <> ''
      and workflow_version ~ '^[0-9]+\.[0-9]+\.[0-9]+([+-][0-9A-Za-z.-]+)?$'
    ),
  constraint account_lifecycle_policies_config_ck
    check (jsonb_typeof(policy_config) = 'object'),
  constraint account_lifecycle_policies_effective_window_ck
    check (retired_at is null or retired_at > effective_from)
);

create index if not exists account_lifecycle_policies_effective_idx
  on public.account_lifecycle_policies (policy_code, effective_from desc);

create unique index if not exists account_lifecycle_policies_active_uidx
  on public.account_lifecycle_policies (policy_code)
  where retired_at is null;

comment on table public.account_lifecycle_policies is
  'Versioned product and execution policy frozen into every accepted account deletion request.';

-- --------------------------------------------------------------------------
-- 4. Pseudonymous retention subjects
-- --------------------------------------------------------------------------

create table if not exists public.data_retention_subjects (
  id uuid primary key default extensions.gen_random_uuid(),
  subject_token text not null,
  subject_class text not null default 'account',
  retention_status text not null default 'pending',
  retention_basis text not null,
  basis_version integer not null default 1,
  opened_at timestamptz not null default clock_timestamp(),
  closed_at timestamptz,
  review_at timestamptz,
  expires_at timestamptz,
  purged_at timestamptz,
  restricted_metadata jsonb not null default '{}'::jsonb,
  version integer not null default 1,
  created_at timestamptz not null default clock_timestamp(),
  updated_at timestamptz not null default clock_timestamp(),

  constraint data_retention_subjects_token_uq unique (subject_token),
  constraint data_retention_subjects_token_ck
    check (length(btrim(subject_token)) >= 32),
  constraint data_retention_subjects_class_ck
    check (subject_class = 'account'),
  constraint data_retention_subjects_status_ck
    check (retention_status in (
      'pending','active','closed','expired','review_required','purged'
    )),
  constraint data_retention_subjects_basis_ck
    check (retention_basis in (
      'commercial_ledger_integrity',
      'payment_evidence',
      'fraud_prevention',
      'legal_claims',
      'certified_game_history',
      'compliance_audit',
      'mixed'
    )),
  constraint data_retention_subjects_version_ck
    check (basis_version > 0 and version > 0),
  constraint data_retention_subjects_metadata_ck
    check (jsonb_typeof(restricted_metadata) = 'object'),
  constraint data_retention_subjects_time_ck
    check (
      (closed_at is null or closed_at >= opened_at)
      and (review_at is null or review_at >= opened_at)
      and (expires_at is null or expires_at >= opened_at)
      and (purged_at is null or retention_status = 'purged')
    )
);

create index if not exists data_retention_subjects_status_review_idx
  on public.data_retention_subjects (retention_status, review_at);

create index if not exists data_retention_subjects_expiry_idx
  on public.data_retention_subjects (expires_at)
  where expires_at is not null;

comment on table public.data_retention_subjects is
  'Restricted pseudonymous identity retained independently from Supabase Auth when lawful or structurally necessary.';

-- --------------------------------------------------------------------------
-- 5. Account lifecycle aggregate
-- --------------------------------------------------------------------------

create table if not exists public.account_lifecycle (
  id uuid primary key default extensions.gen_random_uuid(),
  auth_user_id uuid,
  subject_token text not null,
  retention_subject_id uuid,
  policy_id uuid not null,
  lifecycle_status text not null default 'active',
  requested_at timestamptz,
  scheduled_for timestamptz,
  cancelled_at timestamptz,
  erasure_started_at timestamptz,
  auth_deleted_at timestamptz,
  completed_at timestamptz,
  active_request_id uuid,
  active_erasure_run_id uuid,
  workflow_id uuid,
  blocker_code text,
  failure_code text,
  failure_message text,
  mutation_frozen_at timestamptz,
  version integer not null default 1,
  created_at timestamptz not null default clock_timestamp(),
  updated_at timestamptz not null default clock_timestamp(),

  constraint account_lifecycle_subject_token_uq unique (subject_token),
  constraint account_lifecycle_auth_user_fk
    foreign key (auth_user_id)
    references auth.users(id)
    on delete set null,
  constraint account_lifecycle_retention_subject_fk
    foreign key (retention_subject_id)
    references public.data_retention_subjects(id)
    on delete restrict,
  constraint account_lifecycle_policy_fk
    foreign key (policy_id)
    references public.account_lifecycle_policies(id)
    on delete restrict,
  constraint account_lifecycle_workflow_fk
    foreign key (workflow_id)
    references public.live_runtime_workflows(id)
    on delete set null,
  constraint account_lifecycle_token_ck
    check (length(btrim(subject_token)) >= 32),
  constraint account_lifecycle_status_ck
    check (lifecycle_status in (
      'active',
      'delete_requested',
      'deletion_scheduled',
      'erasure_running',
      'erasure_blocked',
      'deleted',
      'deletion_cancelled',
      'deletion_failed'
    )),
  constraint account_lifecycle_version_ck
    check (version > 0),
  constraint account_lifecycle_schedule_ck
    check (
      scheduled_for is null
      or requested_at is null
      or scheduled_for >= requested_at
    ),
  constraint account_lifecycle_execution_time_ck
    check (
      (erasure_started_at is null or requested_at is null or erasure_started_at >= requested_at)
      and (auth_deleted_at is null or erasure_started_at is not null)
      and (completed_at is null or erasure_started_at is not null)
    ),
  constraint account_lifecycle_deleted_state_ck
    check (
      lifecycle_status <> 'deleted'
      or (
        auth_user_id is null
        and auth_deleted_at is not null
        and completed_at is not null
        and retention_subject_id is not null
      )
    ),
  constraint account_lifecycle_frozen_state_ck
    check (
      mutation_frozen_at is null
      or lifecycle_status in (
        'erasure_running','erasure_blocked','deletion_failed','deleted'
      )
    )
);

create unique index if not exists account_lifecycle_auth_user_uidx
  on public.account_lifecycle (auth_user_id)
  where auth_user_id is not null;

create index if not exists account_lifecycle_status_schedule_idx
  on public.account_lifecycle (lifecycle_status, scheduled_for)
  where lifecycle_status in (
    'delete_requested','deletion_scheduled','erasure_blocked','deletion_failed'
  );

create index if not exists account_lifecycle_retention_subject_idx
  on public.account_lifecycle (retention_subject_id)
  where retention_subject_id is not null;

create index if not exists account_lifecycle_workflow_idx
  on public.account_lifecycle (workflow_id)
  where workflow_id is not null;

comment on table public.account_lifecycle is
  'Authoritative current-state aggregate for account deletion and erasure governance.';

-- --------------------------------------------------------------------------
-- 6. Deletion requests
-- --------------------------------------------------------------------------

create table if not exists public.account_deletion_requests (
  id uuid primary key default extensions.gen_random_uuid(),
  account_lifecycle_id uuid not null,
  policy_id uuid not null,
  request_channel text not null,
  request_status text not null,
  confirmation_method text not null,
  confirmation_phrase_version text not null default 'ELIMINA_V1',
  confirmed_at timestamptz,
  recent_auth_verified_at timestamptz,
  public_verification_token_digest text,
  public_verification_expires_at timestamptz,
  public_verified_at timestamptz,
  idempotency_key text not null,
  requested_at timestamptz not null default clock_timestamp(),
  scheduled_for timestamptz,
  cancelled_at timestamptz,
  cancellation_reason_code text,
  rejected_at timestamptz,
  rejection_code text,
  request_metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default clock_timestamp(),
  updated_at timestamptz not null default clock_timestamp(),

  constraint account_deletion_requests_lifecycle_fk
    foreign key (account_lifecycle_id)
    references public.account_lifecycle(id)
    on delete restrict,
  constraint account_deletion_requests_policy_fk
    foreign key (policy_id)
    references public.account_lifecycle_policies(id)
    on delete restrict,
  constraint account_deletion_requests_idempotency_uq
    unique (account_lifecycle_id, idempotency_key),
  constraint account_deletion_requests_channel_ck
    check (request_channel in (
      'authenticated_web','android_app','public_web',
      'support_assisted','admin_recovery'
    )),
  constraint account_deletion_requests_status_ck
    check (request_status in (
      'pending_verification','verified','accepted','scheduled','cancelled',
      'superseded','executing','completed','rejected','expired'
    )),
  constraint account_deletion_requests_confirmation_ck
    check (confirmation_method in (
      'password_reauthentication','oauth_reauthentication','recent_session',
      'signed_email_link','support_verified'
    )),
  constraint account_deletion_requests_idempotency_ck
    check (length(btrim(idempotency_key)) between 8 and 200),
  constraint account_deletion_requests_metadata_ck
    check (jsonb_typeof(request_metadata) = 'object'),
  constraint account_deletion_requests_schedule_ck
    check (scheduled_for is null or scheduled_for >= requested_at),
  constraint account_deletion_requests_cancel_ck
    check (cancelled_at is null or request_status = 'cancelled'),
  constraint account_deletion_requests_reject_ck
    check (rejected_at is null or request_status = 'rejected'),
  constraint account_deletion_requests_public_ck
    check (
      request_channel <> 'public_web'
      or public_verification_token_digest is not null
    )
);

create unique index if not exists account_deletion_requests_open_uidx
  on public.account_deletion_requests (account_lifecycle_id)
  where request_status in (
    'pending_verification','verified','accepted','scheduled','executing'
  );

create index if not exists account_deletion_requests_schedule_idx
  on public.account_deletion_requests (request_status, scheduled_for);

create index if not exists account_deletion_requests_lifecycle_created_idx
  on public.account_deletion_requests (account_lifecycle_id, created_at desc);

create index if not exists account_deletion_requests_public_digest_idx
  on public.account_deletion_requests (public_verification_token_digest)
  where public_verification_token_digest is not null;

comment on table public.account_deletion_requests is
  'Append-oriented request history; credentials and raw authentication evidence are never stored.';

-- --------------------------------------------------------------------------
-- 7. Erasure runs
-- --------------------------------------------------------------------------

create table if not exists public.account_erasure_runs (
  id uuid primary key default extensions.gen_random_uuid(),
  account_lifecycle_id uuid not null,
  deletion_request_id uuid not null,
  policy_id uuid not null,
  workflow_id uuid,
  workflow_code text not null,
  workflow_version text not null,
  step_catalog_version integer not null,
  run_status text not null default 'planned',
  plan_snapshot jsonb not null,
  plan_digest text not null,
  scheduled_for timestamptz not null,
  lease_owner text,
  lease_token uuid,
  leased_at timestamptz,
  lease_expires_at timestamptz,
  started_at timestamptz,
  blocked_at timestamptz,
  completed_at timestamptz,
  failed_at timestamptz,
  cancelled_at timestamptz,
  blocker_code text,
  failure_code text,
  last_error_message text,
  attempt_count integer not null default 0,
  max_attempts integer not null default 8,
  version integer not null default 1,
  created_at timestamptz not null default clock_timestamp(),
  updated_at timestamptz not null default clock_timestamp(),

  constraint account_erasure_runs_lifecycle_fk
    foreign key (account_lifecycle_id)
    references public.account_lifecycle(id)
    on delete restrict,
  constraint account_erasure_runs_request_fk
    foreign key (deletion_request_id)
    references public.account_deletion_requests(id)
    on delete restrict,
  constraint account_erasure_runs_policy_fk
    foreign key (policy_id)
    references public.account_lifecycle_policies(id)
    on delete restrict,
  constraint account_erasure_runs_workflow_fk
    foreign key (workflow_id)
    references public.live_runtime_workflows(id)
    on delete set null,
  constraint account_erasure_runs_request_uq unique (deletion_request_id),
  constraint account_erasure_runs_status_ck
    check (run_status in (
      'planned','scheduled','leased','running','blocked',
      'retry_scheduled','failed','completed','cancelled'
    )),
  constraint account_erasure_runs_identity_ck
    check (
      btrim(workflow_code) <> ''
      and workflow_version ~ '^[0-9]+\.[0-9]+\.[0-9]+([+-][0-9A-Za-z.-]+)?$'
      and step_catalog_version > 0
    ),
  constraint account_erasure_runs_plan_ck
    check (
      jsonb_typeof(plan_snapshot) = 'object'
      and length(btrim(plan_digest)) >= 32
    ),
  constraint account_erasure_runs_attempts_ck
    check (
      attempt_count >= 0
      and max_attempts between 1 and 100
      and version > 0
    ),
  constraint account_erasure_runs_lease_ck
    check (
      (
        lease_owner is null and lease_token is null
        and leased_at is null and lease_expires_at is null
      )
      or
      (
        lease_owner is not null and lease_token is not null
        and leased_at is not null and lease_expires_at is not null
        and lease_expires_at > leased_at
      )
    ),
  constraint account_erasure_runs_time_ck
    check (
      (started_at is null or started_at >= created_at)
      and (completed_at is null or started_at is not null)
      and (failed_at is null or started_at is not null)
    )
);

create unique index if not exists account_erasure_runs_active_uidx
  on public.account_erasure_runs (account_lifecycle_id)
  where run_status in (
    'planned','scheduled','leased','running','blocked','retry_scheduled'
  );

create index if not exists account_erasure_runs_due_idx
  on public.account_erasure_runs (run_status, scheduled_for);

create index if not exists account_erasure_runs_lease_idx
  on public.account_erasure_runs (run_status, lease_expires_at);

create index if not exists account_erasure_runs_lifecycle_created_idx
  on public.account_erasure_runs (account_lifecycle_id, created_at desc);

create index if not exists account_erasure_runs_workflow_idx
  on public.account_erasure_runs (workflow_id)
  where workflow_id is not null;

comment on table public.account_erasure_runs is
  'Immutable-plan execution aggregate for one accepted deletion request.';

-- Circular active references are added only after request/run tables exist.
alter table public.account_lifecycle
  add constraint account_lifecycle_active_request_fk
  foreign key (active_request_id)
  references public.account_deletion_requests(id)
  on delete set null
  deferrable initially deferred;

alter table public.account_lifecycle
  add constraint account_lifecycle_active_erasure_run_fk
  foreign key (active_erasure_run_id)
  references public.account_erasure_runs(id)
  on delete set null
  deferrable initially deferred;

-- --------------------------------------------------------------------------
-- 8. Canonical erasure-step catalogue
-- --------------------------------------------------------------------------

create table if not exists public.account_erasure_step_catalog (
  id uuid primary key default extensions.gen_random_uuid(),
  workflow_code text not null,
  workflow_version text not null,
  catalog_version integer not null,
  step_code text not null,
  step_order integer not null,
  display_name text not null,
  description text,
  handler_code text not null,
  mandatory boolean not null default true,
  irreversible boolean not null default false,
  retry_enabled boolean not null default true,
  max_attempts integer not null default 8,
  retry_policy_code text not null default 'EXPONENTIAL_STANDARD',
  timeout_interval interval not null default interval '5 minutes',
  requires_service_role boolean not null default true,
  requires_external_provider boolean not null default false,
  step_config jsonb not null default '{}'::jsonb,
  effective_from timestamptz not null,
  retired_at timestamptz,
  created_at timestamptz not null default clock_timestamp(),
  updated_at timestamptz not null default clock_timestamp(),

  constraint account_erasure_step_catalog_code_uq
    unique (workflow_code, workflow_version, catalog_version, step_code),
  constraint account_erasure_step_catalog_order_uq
    unique (workflow_code, workflow_version, catalog_version, step_order),
  constraint account_erasure_step_catalog_identity_ck
    check (
      btrim(workflow_code) <> ''
      and workflow_version ~ '^[0-9]+\.[0-9]+\.[0-9]+([+-][0-9A-Za-z.-]+)?$'
      and catalog_version > 0
      and step_order > 0
      and btrim(step_code) <> ''
      and step_code = upper(step_code)
      and btrim(handler_code) <> ''
    ),
  constraint account_erasure_step_catalog_retry_ck
    check (
      max_attempts between 1 and 100
      and timeout_interval > interval '0 seconds'
    ),
  constraint account_erasure_step_catalog_config_ck
    check (jsonb_typeof(step_config) = 'object'),
  constraint account_erasure_step_catalog_window_ck
    check (retired_at is null or retired_at > effective_from)
);

create index if not exists account_erasure_step_catalog_active_idx
  on public.account_erasure_step_catalog (
    workflow_code, workflow_version, catalog_version, step_order
  )
  where retired_at is null;

comment on table public.account_erasure_step_catalog is
  'Versioned domain catalogue for the canonical Account Deletion workflow; it does not represent runtime workflow instances.';

-- --------------------------------------------------------------------------
-- 9. Durable step state and evidence
-- --------------------------------------------------------------------------

create table if not exists public.account_erasure_steps (
  id uuid primary key default extensions.gen_random_uuid(),
  erasure_run_id uuid not null,
  step_catalog_id uuid not null,
  step_code text not null,
  step_order integer not null,
  step_status text not null default 'pending',
  mandatory boolean not null,
  irreversible boolean not null,
  attempt_count integer not null default 0,
  max_attempts integer not null,
  available_at timestamptz not null default clock_timestamp(),
  lease_owner text,
  lease_token uuid,
  leased_at timestamptz,
  lease_expires_at timestamptz,
  started_at timestamptz,
  completed_at timestamptz,
  blocked_at timestamptz,
  failed_at timestamptz,
  affected_row_count bigint not null default 0,
  affected_object_count bigint not null default 0,
  evidence_digest text,
  evidence_summary jsonb not null default '{}'::jsonb,
  blocker_code text,
  error_code text,
  error_message text,
  version integer not null default 1,
  created_at timestamptz not null default clock_timestamp(),
  updated_at timestamptz not null default clock_timestamp(),

  constraint account_erasure_steps_run_fk
    foreign key (erasure_run_id)
    references public.account_erasure_runs(id)
    on delete cascade,
  constraint account_erasure_steps_catalog_fk
    foreign key (step_catalog_id)
    references public.account_erasure_step_catalog(id)
    on delete restrict,
  constraint account_erasure_steps_code_uq unique (erasure_run_id, step_code),
  constraint account_erasure_steps_order_uq unique (erasure_run_id, step_order),
  constraint account_erasure_steps_status_ck
    check (step_status in (
      'pending','leased','running','blocked','retry_scheduled',
      'failed','skipped','completed'
    )),
  constraint account_erasure_steps_numeric_ck
    check (
      step_order > 0
      and attempt_count >= 0
      and max_attempts between 1 and 100
      and affected_row_count >= 0
      and affected_object_count >= 0
      and version > 0
    ),
  constraint account_erasure_steps_evidence_ck
    check (
      jsonb_typeof(evidence_summary) = 'object'
      and (evidence_digest is null or length(btrim(evidence_digest)) >= 32)
    ),
  constraint account_erasure_steps_lease_ck
    check (
      (
        lease_owner is null and lease_token is null
        and leased_at is null and lease_expires_at is null
      )
      or
      (
        lease_owner is not null and lease_token is not null
        and leased_at is not null and lease_expires_at is not null
        and lease_expires_at > leased_at
      )
    ),
  constraint account_erasure_steps_terminal_ck
    check (
      (step_status <> 'completed' or completed_at is not null)
      and (step_status <> 'blocked' or blocker_code is not null)
      and (step_status <> 'failed' or error_code is not null)
    )
);

create index if not exists account_erasure_steps_claim_idx
  on public.account_erasure_steps (step_status, available_at, step_order)
  where step_status in ('pending','retry_scheduled');

create index if not exists account_erasure_steps_lease_idx
  on public.account_erasure_steps (step_status, lease_expires_at)
  where step_status in ('leased','running');

create index if not exists account_erasure_steps_run_order_idx
  on public.account_erasure_steps (erasure_run_id, step_order);

create index if not exists account_erasure_steps_failure_idx
  on public.account_erasure_steps (error_code, failed_at)
  where step_status = 'failed';

comment on table public.account_erasure_steps is
  'Durable status and non-sensitive evidence for every step of an erasure run.';

-- --------------------------------------------------------------------------
-- 10. Versioned JSONB erasure rules
-- --------------------------------------------------------------------------

create table if not exists public.data_erasure_jsonb_rules (
  id uuid primary key default extensions.gen_random_uuid(),
  rule_code text not null,
  rule_version integer not null,
  target_schema text not null default 'public',
  target_table text not null,
  target_column text not null,
  subject_identity_column text,
  match_mode text not null,
  json_path text,
  key_pattern text,
  value_match_source text,
  action_code text not null,
  replacement_value jsonb,
  mandatory boolean not null default true,
  active boolean not null default true,
  rule_config jsonb not null default '{}'::jsonb,
  effective_from timestamptz not null,
  retired_at timestamptz,
  created_at timestamptz not null default clock_timestamp(),
  updated_at timestamptz not null default clock_timestamp(),

  constraint data_erasure_jsonb_rules_identity_uq
    unique (rule_code, rule_version),
  constraint data_erasure_jsonb_rules_identity_ck
    check (
      rule_version > 0
      and btrim(target_schema) <> ''
      and btrim(target_table) <> ''
      and btrim(target_column) <> ''
    ),
  constraint data_erasure_jsonb_rules_match_ck
    check (match_mode in (
      'key_exact',
      'key_case_insensitive',
      'key_pattern',
      'json_path',
      'value_equals_auth_user_id',
      'value_equals_email_digest',
      'recursive_forbidden_keys'
    )),
  constraint data_erasure_jsonb_rules_action_ck
    check (action_code in (
      'remove_key',
      'set_null',
      'replace_static',
      'replace_subject_token',
      'replace_retention_subject_id',
      'remove_matching_array_item',
      'reject_unregistered_payload'
    )),
  constraint data_erasure_jsonb_rules_config_ck
    check (jsonb_typeof(rule_config) = 'object'),
  constraint data_erasure_jsonb_rules_window_ck
    check (retired_at is null or retired_at > effective_from)
);

create index if not exists data_erasure_jsonb_rules_target_idx
  on public.data_erasure_jsonb_rules (
    target_schema, target_table, target_column, active
  );

create index if not exists data_erasure_jsonb_rules_active_idx
  on public.data_erasure_jsonb_rules (effective_from, rule_code)
  where active and retired_at is null;

comment on table public.data_erasure_jsonb_rules is
  'Versioned data-driven registry of JSONB personal-identifier scrubbing rules.';

-- --------------------------------------------------------------------------
-- 11. Append-only deletion audit
-- --------------------------------------------------------------------------

create table if not exists public.account_deletion_audit (
  id uuid primary key default extensions.gen_random_uuid(),
  account_lifecycle_id uuid not null,
  erasure_run_id uuid,
  subject_token text not null,
  event_code text not null,
  event_version integer not null default 1,
  event_result text not null,
  policy_code text not null,
  policy_version integer not null,
  workflow_code text,
  workflow_version text,
  occurred_at timestamptz not null default clock_timestamp(),
  step_code text,
  affected_row_count bigint not null default 0,
  affected_object_count bigint not null default 0,
  evidence_digest text,
  correlation_id uuid,
  causation_id uuid,
  failure_code text,
  blocker_code text,
  audit_metadata jsonb not null default '{}'::jsonb,

  constraint account_deletion_audit_lifecycle_fk
    foreign key (account_lifecycle_id)
    references public.account_lifecycle(id)
    on delete restrict,
  constraint account_deletion_audit_run_fk
    foreign key (erasure_run_id)
    references public.account_erasure_runs(id)
    on delete set null,
  constraint account_deletion_audit_identity_ck
    check (
      length(btrim(subject_token)) >= 32
      and event_version > 0
      and policy_version > 0
    ),
  constraint account_deletion_audit_result_ck
    check (event_result in (
      'recorded','accepted','scheduled','cancelled','started',
      'blocked','succeeded','failed','completed'
    )),
  constraint account_deletion_audit_counts_ck
    check (affected_row_count >= 0 and affected_object_count >= 0),
  constraint account_deletion_audit_metadata_ck
    check (jsonb_typeof(audit_metadata) = 'object'),
  constraint account_deletion_audit_digest_ck
    check (evidence_digest is null or length(btrim(evidence_digest)) >= 32)
);

create unique index if not exists account_deletion_audit_final_uidx
  on public.account_deletion_audit (account_lifecycle_id, event_code)
  where event_code = 'ACCOUNT_DELETED';

create index if not exists account_deletion_audit_lifecycle_time_idx
  on public.account_deletion_audit (account_lifecycle_id, occurred_at);

create index if not exists account_deletion_audit_subject_time_idx
  on public.account_deletion_audit (subject_token, occurred_at);

create index if not exists account_deletion_audit_event_time_idx
  on public.account_deletion_audit (event_code, occurred_at);

create index if not exists account_deletion_audit_run_step_idx
  on public.account_deletion_audit (erasure_run_id, step_code);

comment on table public.account_deletion_audit is
  'Append-only, non-identifying compliance evidence for account lifecycle and erasure execution.';

drop trigger if exists trg_account_deletion_audit_append_only
  on public.account_deletion_audit;
create trigger trg_account_deletion_audit_append_only
before update or delete on public.account_deletion_audit
for each row execute function public.protect_account_deletion_audit_append_only();

-- --------------------------------------------------------------------------
-- 12. State-transition guards
-- --------------------------------------------------------------------------

create or replace function public.guard_account_lifecycle_transition()
returns trigger
language plpgsql
security invoker
set search_path = public, pg_catalog
as $function$
begin
  if new.lifecycle_status = old.lifecycle_status then
    return new;
  end if;

  if old.lifecycle_status = 'deleted' then
    raise exception using
      errcode = '23514',
      message = 'ACCOUNT_LIFECYCLE_DELETED_TERMINAL';
  end if;

  if not (
    (old.lifecycle_status = 'active'
      and new.lifecycle_status = 'delete_requested')
    or
    (old.lifecycle_status = 'delete_requested'
      and new.lifecycle_status in ('deletion_scheduled','deletion_cancelled'))
    or
    (old.lifecycle_status = 'deletion_scheduled'
      and new.lifecycle_status in ('deletion_cancelled','erasure_running','erasure_blocked'))
    or
    (old.lifecycle_status = 'erasure_blocked'
      and new.lifecycle_status in ('deletion_scheduled','erasure_running','deletion_failed'))
    or
    (old.lifecycle_status = 'erasure_running'
      and new.lifecycle_status in ('deleted','deletion_failed'))
    or
    (old.lifecycle_status = 'deletion_cancelled'
      and new.lifecycle_status = 'active')
    or
    (old.lifecycle_status = 'deletion_failed'
      and new.lifecycle_status in ('erasure_running','erasure_blocked'))
  ) then
    raise exception using
      errcode = '23514',
      message = format(
        'ACCOUNT_LIFECYCLE_TRANSITION_INVALID: %s -> %s',
        old.lifecycle_status,
        new.lifecycle_status
      );
  end if;

  if new.lifecycle_status = 'erasure_running'
     and new.erasure_started_at is null then
    raise exception using
      errcode = '23514',
      message = 'ACCOUNT_LIFECYCLE_ERASURE_STARTED_AT_REQUIRED';
  end if;

  return new;
end;
$function$;

drop trigger if exists trg_guard_account_lifecycle_transition
  on public.account_lifecycle;
create trigger trg_guard_account_lifecycle_transition
before update of lifecycle_status on public.account_lifecycle
for each row execute function public.guard_account_lifecycle_transition();

create or replace function public.guard_account_erasure_step_transition()
returns trigger
language plpgsql
security invoker
set search_path = public, pg_catalog
as $function$
begin
  if new.step_status = old.step_status then
    return new;
  end if;

  if old.step_status in ('completed','skipped') then
    raise exception using
      errcode = '23514',
      message = 'ACCOUNT_ERASURE_STEP_TERMINAL';
  end if;

  if not (
    (old.step_status = 'pending'
      and new.step_status in ('leased','running','blocked','skipped'))
    or
    (old.step_status = 'leased'
      and new.step_status in ('running','retry_scheduled','failed','blocked'))
    or
    (old.step_status = 'running'
      and new.step_status in ('completed','retry_scheduled','failed','blocked'))
    or
    (old.step_status = 'blocked'
      and new.step_status in ('pending','retry_scheduled','failed'))
    or
    (old.step_status = 'retry_scheduled'
      and new.step_status in ('leased','running','failed','blocked'))
    or
    (old.step_status = 'failed'
      and new.step_status in ('retry_scheduled','pending'))
  ) then
    raise exception using
      errcode = '23514',
      message = format(
        'ACCOUNT_ERASURE_STEP_TRANSITION_INVALID: %s -> %s',
        old.step_status,
        new.step_status
      );
  end if;

  if old.mandatory and new.step_status = 'skipped' then
    raise exception using
      errcode = '23514',
      message = 'ACCOUNT_ERASURE_MANDATORY_STEP_CANNOT_SKIP';
  end if;

  return new;
end;
$function$;

drop trigger if exists trg_guard_account_erasure_step_transition
  on public.account_erasure_steps;
create trigger trg_guard_account_erasure_step_transition
before update of step_status on public.account_erasure_steps
for each row execute function public.guard_account_erasure_step_transition();

-- --------------------------------------------------------------------------
-- 13. updated_at triggers
-- --------------------------------------------------------------------------

do $updated_at_triggers$
declare
  v_table text;
begin
  foreach v_table in array array[
    'account_lifecycle_policies',
    'data_retention_subjects',
    'account_lifecycle',
    'account_deletion_requests',
    'account_erasure_runs',
    'account_erasure_step_catalog',
    'account_erasure_steps',
    'data_erasure_jsonb_rules'
  ]
  loop
    execute format(
      'drop trigger if exists %I on public.%I',
      'trg_' || v_table || '_updated_at',
      v_table
    );

    execute format(
      'create trigger %I before update on public.%I
       for each row execute function public.set_account_lifecycle_updated_at()',
      'trg_' || v_table || '_updated_at',
      v_table
    );
  end loop;
end;
$updated_at_triggers$;

-- --------------------------------------------------------------------------
-- 14. Seed standard policy
-- --------------------------------------------------------------------------

insert into public.account_lifecycle_policies (
  policy_code,
  policy_version,
  display_name,
  description,
  cooling_off_interval,
  minimum_recent_auth_age,
  automatic_execution_enabled,
  public_request_enabled,
  authenticated_request_enabled,
  workflow_code,
  workflow_version,
  effective_from,
  retired_at,
  policy_config
)
values (
  'ACCOUNT_DELETION_STANDARD',
  1,
  'Standard account deletion policy',
  'Initial FantaGol account deletion policy with configurable thirty-day cooling-off and disabled automatic execution.',
  interval '30 days',
  interval '15 minutes',
  false,
  true,
  true,
  'ACCOUNT_DELETION_V1',
  '1.0.0',
  clock_timestamp(),
  null,
  jsonb_build_object(
    'confirmation_phrase', 'ELIMINA',
    'confirmation_phrase_version', 'ELIMINA_V1',
    'auth_deletion_enabled', false,
    'storage_deletion_enabled', false,
    'commercial_detach_enabled', false,
    'competitive_anonymization_enabled', false,
    'foundation_migration', 168
  )
)
on conflict (policy_code, policy_version) do update
set
  display_name = excluded.display_name,
  description = excluded.description,
  cooling_off_interval = excluded.cooling_off_interval,
  minimum_recent_auth_age = excluded.minimum_recent_auth_age,
  automatic_execution_enabled = false,
  public_request_enabled = excluded.public_request_enabled,
  authenticated_request_enabled = excluded.authenticated_request_enabled,
  workflow_code = excluded.workflow_code,
  workflow_version = excluded.workflow_version,
  policy_config = public.account_lifecycle_policies.policy_config || excluded.policy_config,
  updated_at = clock_timestamp();

-- --------------------------------------------------------------------------
-- 15. Seed canonical workflow step catalogue
-- --------------------------------------------------------------------------

insert into public.account_erasure_step_catalog (
  workflow_code,
  workflow_version,
  catalog_version,
  step_code,
  step_order,
  display_name,
  description,
  handler_code,
  mandatory,
  irreversible,
  retry_enabled,
  max_attempts,
  retry_policy_code,
  timeout_interval,
  requires_service_role,
  requires_external_provider,
  step_config,
  effective_from
)
values
  ('ACCOUNT_DELETION_V1','1.0.0',1,'ACQUIRE_ACCOUNT_LIFECYCLE_LEASE',10,'Acquire lifecycle lease','Serialize lifecycle execution.','acquire_account_lifecycle_lease',true,false,true,8,'EXPONENTIAL_STANDARD',interval '2 minutes',true,false,'{}',clock_timestamp()),
  ('ACCOUNT_DELETION_V1','1.0.0',1,'FREEZE_ACCOUNT_MUTATIONS',20,'Freeze account mutations','Prevent new user-originated mutations.','freeze_account_mutations',true,false,true,8,'EXPONENTIAL_STANDARD',interval '2 minutes',true,false,'{}',clock_timestamp()),
  ('ACCOUNT_DELETION_V1','1.0.0',1,'EVALUATE_ERASURE_READINESS',30,'Evaluate erasure readiness','Detect deterministic blockers before mutation.','evaluate_erasure_readiness',true,false,true,8,'EXPONENTIAL_STANDARD',interval '5 minutes',true,false,'{}',clock_timestamp()),
  ('ACCOUNT_DELETION_V1','1.0.0',1,'RESOLVE_LEAGUE_GOVERNANCE',40,'Resolve league governance','Transfer canonical league governance.','resolve_league_governance',true,false,true,8,'EXPONENTIAL_STANDARD',interval '10 minutes',true,false,'{}',clock_timestamp()),
  ('ACCOUNT_DELETION_V1','1.0.0',1,'REVOKE_ACTIVE_COMMERCIAL_ACCESS',50,'Revoke commercial access','Revoke active premium access sessions.','revoke_active_commercial_access',true,false,true,8,'EXPONENTIAL_STANDARD',interval '5 minutes',true,false,'{}',clock_timestamp()),
  ('ACCOUNT_DELETION_V1','1.0.0',1,'CLOSE_COMMERCIAL_WALLET',60,'Close commercial wallet','Close the wallet through certified commercial rules.','close_commercial_wallet',true,false,true,8,'EXPONENTIAL_STANDARD',interval '5 minutes',true,false,'{}',clock_timestamp()),
  ('ACCOUNT_DELETION_V1','1.0.0',1,'CREATE_OR_RESOLVE_RETENTION_SUBJECT',70,'Resolve retention subject','Create or resolve permanent pseudonymous identity.','create_or_resolve_retention_subject',true,false,true,8,'EXPONENTIAL_STANDARD',interval '5 minutes',true,false,'{}',clock_timestamp()),
  ('ACCOUNT_DELETION_V1','1.0.0',1,'PSEUDONYMIZE_COMMERCIAL_AND_LOYALTY_DOMAINS',80,'Pseudonymize commercial domains','Detach commercial and loyalty history from Auth.','pseudonymize_commercial_and_loyalty_domains',true,false,true,8,'EXPONENTIAL_STANDARD',interval '15 minutes',true,false,'{}',clock_timestamp()),
  ('ACCOUNT_DELETION_V1','1.0.0',1,'ANONYMIZE_COMPETITIVE_IDENTITY',90,'Anonymize competitive identity','Preserve history through membership-scoped anonymization.','anonymize_competitive_identity',true,false,true,8,'EXPONENTIAL_STANDARD',interval '15 minutes',true,false,'{}',clock_timestamp()),
  ('ACCOUNT_DELETION_V1','1.0.0',1,'DETACH_LEGACY_AUTH_REFERENCES',100,'Detach legacy Auth references','Set eligible legacy Auth references to null.','detach_legacy_auth_references',true,false,true,8,'EXPONENTIAL_STANDARD',interval '10 minutes',true,false,'{}',clock_timestamp()),
  ('ACCOUNT_DELETION_V1','1.0.0',1,'SCRUB_JSONB_PERSONAL_IDENTIFIERS',110,'Scrub JSONB identifiers','Apply versioned registered JSONB erasure rules.','scrub_jsonb_personal_identifiers',true,false,true,8,'EXPONENTIAL_STANDARD',interval '20 minutes',true,false,'{}',clock_timestamp()),
  ('ACCOUNT_DELETION_V1','1.0.0',1,'DELETE_STORAGE_ASSETS',120,'Delete Storage assets','Delete user-owned and UUID-prefixed Storage objects.','delete_storage_assets',true,true,true,8,'EXPONENTIAL_STANDARD',interval '15 minutes',true,true,'{}',clock_timestamp()),
  ('ACCOUNT_DELETION_V1','1.0.0',1,'DELETE_PROFILE_PERSONAL_DATA',130,'Delete profile personal data','Delete directly identifying profile data.','delete_profile_personal_data',true,true,true,8,'EXPONENTIAL_STANDARD',interval '5 minutes',true,false,'{}',clock_timestamp()),
  ('ACCOUNT_DELETION_V1','1.0.0',1,'VERIFY_PRE_AUTH_DELETION_INVARIANTS',140,'Verify pre-Auth invariants','Certify readiness for the final Auth boundary.','verify_pre_auth_deletion_invariants',true,false,true,8,'EXPONENTIAL_STANDARD',interval '10 minutes',true,false,'{}',clock_timestamp()),
  ('ACCOUNT_DELETION_V1','1.0.0',1,'DELETE_SUPABASE_AUTH_IDENTITY',150,'Delete Supabase Auth identity','Delete Auth identity only after certification.','delete_supabase_auth_identity',true,true,true,8,'EXPONENTIAL_STANDARD',interval '10 minutes',true,true,'{}',clock_timestamp()),
  ('ACCOUNT_DELETION_V1','1.0.0',1,'VERIFY_POST_AUTH_DELETION_INVARIANTS',160,'Verify post-Auth invariants','Prove Auth and direct personal data are absent.','verify_post_auth_deletion_invariants',true,false,true,8,'EXPONENTIAL_STANDARD',interval '10 minutes',true,false,'{}',clock_timestamp()),
  ('ACCOUNT_DELETION_V1','1.0.0',1,'WRITE_FINAL_NON_IDENTIFYING_AUDIT',170,'Write final audit','Write minimal non-identifying completion evidence.','write_final_non_identifying_audit',true,false,true,8,'EXPONENTIAL_STANDARD',interval '5 minutes',true,false,'{}',clock_timestamp()),
  ('ACCOUNT_DELETION_V1','1.0.0',1,'CERTIFY_ACCOUNT_DELETION',180,'Certify account deletion','Mark lifecycle deleted after all invariants pass.','certify_account_deletion',true,false,true,8,'EXPONENTIAL_STANDARD',interval '5 minutes',true,false,'{}',clock_timestamp())
on conflict (workflow_code, workflow_version, catalog_version, step_code) do update
set
  step_order = excluded.step_order,
  display_name = excluded.display_name,
  description = excluded.description,
  handler_code = excluded.handler_code,
  mandatory = excluded.mandatory,
  irreversible = excluded.irreversible,
  retry_enabled = excluded.retry_enabled,
  max_attempts = excluded.max_attempts,
  retry_policy_code = excluded.retry_policy_code,
  timeout_interval = excluded.timeout_interval,
  requires_service_role = excluded.requires_service_role,
  requires_external_provider = excluded.requires_external_provider,
  step_config = public.account_erasure_step_catalog.step_config || excluded.step_config,
  updated_at = clock_timestamp();

-- --------------------------------------------------------------------------
-- 16. Security
-- --------------------------------------------------------------------------

alter table public.account_lifecycle_policies enable row level security;
alter table public.data_retention_subjects enable row level security;
alter table public.account_lifecycle enable row level security;
alter table public.account_deletion_requests enable row level security;
alter table public.account_erasure_runs enable row level security;
alter table public.account_erasure_step_catalog enable row level security;
alter table public.account_erasure_steps enable row level security;
alter table public.data_erasure_jsonb_rules enable row level security;
alter table public.account_deletion_audit enable row level security;

alter table public.account_lifecycle_policies force row level security;
alter table public.data_retention_subjects force row level security;
alter table public.account_lifecycle force row level security;
alter table public.account_deletion_requests force row level security;
alter table public.account_erasure_runs force row level security;
alter table public.account_erasure_step_catalog force row level security;
alter table public.account_erasure_steps force row level security;
alter table public.data_erasure_jsonb_rules force row level security;
alter table public.account_deletion_audit force row level security;

revoke all on table public.account_lifecycle_policies from public, anon, authenticated;
revoke all on table public.data_retention_subjects from public, anon, authenticated;
revoke all on table public.account_lifecycle from public, anon, authenticated;
revoke all on table public.account_deletion_requests from public, anon, authenticated;
revoke all on table public.account_erasure_runs from public, anon, authenticated;
revoke all on table public.account_erasure_step_catalog from public, anon, authenticated;
revoke all on table public.account_erasure_steps from public, anon, authenticated;
revoke all on table public.data_erasure_jsonb_rules from public, anon, authenticated;
revoke all on table public.account_deletion_audit from public, anon, authenticated;

grant select, insert, update, delete on table public.account_lifecycle_policies to service_role;
grant select, insert, update, delete on table public.data_retention_subjects to service_role;
grant select, insert, update, delete on table public.account_lifecycle to service_role;
grant select, insert, update, delete on table public.account_deletion_requests to service_role;
grant select, insert, update, delete on table public.account_erasure_runs to service_role;
grant select, insert, update, delete on table public.account_erasure_step_catalog to service_role;
grant select, insert, update, delete on table public.account_erasure_steps to service_role;
grant select, insert, update, delete on table public.data_erasure_jsonb_rules to service_role;
grant select, insert on table public.account_deletion_audit to service_role;

do $service_policies$
declare
  v_table text;
  v_policy text;
begin
  foreach v_table in array array[
    'account_lifecycle_policies',
    'data_retention_subjects',
    'account_lifecycle',
    'account_deletion_requests',
    'account_erasure_runs',
    'account_erasure_step_catalog',
    'account_erasure_steps',
    'data_erasure_jsonb_rules',
    'account_deletion_audit'
  ]
  loop
    v_policy := v_table || '_service_all';
    execute format('drop policy if exists %I on public.%I', v_policy, v_table);
    execute format(
      'create policy %I on public.%I for all to service_role using (true) with check (true)',
      v_policy,
      v_table
    );
  end loop;
end;
$service_policies$;

revoke all on function public.set_account_lifecycle_updated_at()
  from public, anon, authenticated;
revoke all on function public.protect_account_deletion_audit_append_only()
  from public, anon, authenticated;
revoke all on function public.guard_account_lifecycle_transition()
  from public, anon, authenticated;
revoke all on function public.guard_account_erasure_step_transition()
  from public, anon, authenticated;

grant execute on function public.set_account_lifecycle_updated_at()
  to service_role;
grant execute on function public.protect_account_deletion_audit_append_only()
  to service_role;
grant execute on function public.guard_account_lifecycle_transition()
  to service_role;
grant execute on function public.guard_account_erasure_step_transition()
  to service_role;

-- --------------------------------------------------------------------------
-- 17. Platform metadata progression
-- --------------------------------------------------------------------------

update public.platform_configuration
set
  schema_version = greatest(schema_version, 168),
  metadata = metadata || jsonb_build_object(
    'account_lifecycle_foundation_migration', 168,
    'account_lifecycle_contract', 'account-lifecycle-data-erasure-v1',
    'account_lifecycle_runtime_enabled', false
  ),
  updated_at = now()
where configuration_key = 'primary';

-- --------------------------------------------------------------------------
-- 18. Migration assertions
-- --------------------------------------------------------------------------

do $assertions$
declare
  v_missing text[];
  v_step_count integer;
  v_policy_count integer;
  v_dependency_count integer;
  v_engine public.platform_engine_registry%rowtype;
  v_dependency_validation jsonb;
begin
  select array_agg(expected.object_name order by expected.object_name)
    into v_missing
  from (
    values
      ('account_lifecycle_policies'),
      ('data_retention_subjects'),
      ('account_lifecycle'),
      ('account_deletion_requests'),
      ('account_erasure_runs'),
      ('account_erasure_step_catalog'),
      ('account_erasure_steps'),
      ('data_erasure_jsonb_rules'),
      ('account_deletion_audit')
  ) as expected(object_name)
  where to_regclass('public.' || expected.object_name) is null;

  if v_missing is not null then
    raise exception
      'ACCOUNT_LIFECYCLE_FOUNDATION_ASSERTION_FAILED: missing objects %',
      v_missing;
  end if;

  select * into v_engine
  from public.platform_engine_registry
  where engine_code = 'account_lifecycle_engine';

  if not found then
    raise exception
      'ACCOUNT_LIFECYCLE_FOUNDATION_ASSERTION_FAILED: engine registry row missing';
  end if;

  if v_engine.runtime_enabled
     or v_engine.is_certified
     or v_engine.lifecycle_status <> 'installed' then
    raise exception
      'ACCOUNT_LIFECYCLE_FOUNDATION_ASSERTION_FAILED: engine must remain installed, runtime-disabled and uncertified';
  end if;

  select count(*) into v_dependency_count
  from public.platform_engine_dependencies
  where dependent_engine_code = 'account_lifecycle_engine'
    and enabled;

  if v_dependency_count <> 6 then
    raise exception
      'ACCOUNT_LIFECYCLE_FOUNDATION_ASSERTION_FAILED: expected 6 enabled dependencies, found %',
      v_dependency_count;
  end if;

  v_dependency_validation :=
    public.validate_platform_dependency_graph_rpc('account_lifecycle_engine');

  if coalesce((v_dependency_validation ->> 'is_valid')::boolean, false) is not true then
    raise exception
      'ACCOUNT_LIFECYCLE_FOUNDATION_ASSERTION_FAILED: dependency graph invalid: %',
      v_dependency_validation;
  end if;

  select count(*) into v_policy_count
  from public.account_lifecycle_policies
  where policy_code = 'ACCOUNT_DELETION_STANDARD'
    and policy_version = 1
    and automatic_execution_enabled is false
    and (policy_config ->> 'auth_deletion_enabled')::boolean is false;

  if v_policy_count <> 1 then
    raise exception
      'ACCOUNT_LIFECYCLE_FOUNDATION_ASSERTION_FAILED: safe standard policy missing';
  end if;

  select count(*) into v_step_count
  from public.account_erasure_step_catalog
  where workflow_code = 'ACCOUNT_DELETION_V1'
    and workflow_version = '1.0.0'
    and catalog_version = 1
    and retired_at is null;

  if v_step_count <> 18 then
    raise exception
      'ACCOUNT_LIFECYCLE_FOUNDATION_ASSERTION_FAILED: expected 18 canonical steps, found %',
      v_step_count;
  end if;

  if exists (
    select 1
    from public.account_lifecycle
  ) or exists (
    select 1
    from public.account_deletion_requests
  ) or exists (
    select 1
    from public.account_erasure_runs
  ) or exists (
    select 1
    from public.account_erasure_steps
  ) or exists (
    select 1
    from public.account_deletion_audit
  ) then
    raise exception
      'ACCOUNT_LIFECYCLE_FOUNDATION_ASSERTION_FAILED: foundation migration created operational account data';
  end if;

  if exists (
    select 1
    from public.live_runtime_workflow_registry
    where workflow_key = 'ACCOUNT_DELETION_V1'
  ) then
    raise exception
      'ACCOUNT_LIFECYCLE_FOUNDATION_ASSERTION_FAILED: migration must not create workflow instances';
  end if;
end;
$assertions$;

commit;
