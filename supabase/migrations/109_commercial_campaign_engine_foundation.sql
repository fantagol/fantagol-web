-- =============================================================================
-- FANTAGOL
-- Migration: 109_commercial_campaign_engine_foundation.sql
-- Milestone: Commercial Platform - Campaign Lifecycle and Governance Engine
--
-- Purpose:
--   - Extend the canonical reward_campaigns registry without duplicating it
--   - Introduce immutable campaign versions and explicit activation requests
--   - Evaluate campaign readiness before any operational activation
--   - Maintain an authoritative runtime-state projection
--   - Record append-only lifecycle events for complete auditability
--
-- Safety guarantees:
--   - No campaign is activated by this migration
--   - No reward, claim, ledger movement or wallet mutation is generated
--   - No provider integration is enabled
--   - No frontend role receives write access
--   - Existing loyalty campaigns remain disabled and private
-- =============================================================================

begin;

-- =============================================================================
-- 0. DEPENDENCY ASSERTIONS
-- =============================================================================

do $$
begin
  if to_regclass('public.reward_campaigns') is null
     or to_regclass('public.reward_sources') is null then
    raise exception using
      errcode = 'P0001',
      message = 'MIGRATION_109_REQUIRES_REWARD_ENGINE_FOUNDATION';
  end if;
end;
$$;

-- =============================================================================
-- 1. CAMPAIGN VERSIONS
-- =============================================================================

create table if not exists public.commercial_campaign_versions (
  id uuid primary key default gen_random_uuid(),
  campaign_id uuid not null,
  campaign_code text not null,
  version_number integer not null,

  version_status text not null default 'draft',
  configuration_snapshot jsonb not null,
  configuration_hash text not null,

  change_summary text null,
  created_by text not null,
  approved_by text null,
  approved_at timestamptz null,
  superseded_at timestamptz null,
  retired_at timestamptz null,

  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default clock_timestamp(),

  constraint commercial_campaign_versions_campaign_id_fkey
    foreign key (campaign_id)
    references public.reward_campaigns (id)
    on delete restrict,

  constraint commercial_campaign_versions_campaign_version_key
    unique (campaign_id, version_number),

  constraint commercial_campaign_versions_campaign_code_check
    check (
      campaign_code = upper(campaign_code)
      and campaign_code ~ '^[A-Z][A-Z0-9_]{1,95}$'
    ),

  constraint commercial_campaign_versions_version_number_check
    check (version_number > 0),

  constraint commercial_campaign_versions_status_check
    check (version_status in ('draft', 'approved', 'superseded', 'retired')),

  constraint commercial_campaign_versions_snapshot_object_check
    check (jsonb_typeof(configuration_snapshot) = 'object'),

  constraint commercial_campaign_versions_hash_check
    check (configuration_hash ~ '^[a-f0-9]{32}$'),

  constraint commercial_campaign_versions_created_by_check
    check (length(btrim(created_by)) between 1 and 160),

  constraint commercial_campaign_versions_metadata_object_check
    check (jsonb_typeof(metadata) = 'object'),

  constraint commercial_campaign_versions_approval_check
    check (
      (version_status = 'draft' and approved_at is null and approved_by is null)
      or
      (version_status <> 'draft' and approved_at is not null and approved_by is not null)
    )
);

create unique index if not exists commercial_campaign_versions_one_approved_idx
  on public.commercial_campaign_versions (campaign_id)
  where version_status = 'approved';

create index if not exists commercial_campaign_versions_campaign_idx
  on public.commercial_campaign_versions (campaign_id, version_number desc);

comment on table public.commercial_campaign_versions is
  'Versioned immutable snapshots of canonical reward campaigns. Approved versions are operational governance artifacts.';

-- =============================================================================
-- 2. ACTIVATION REQUESTS
-- =============================================================================

create table if not exists public.commercial_campaign_activation_requests (
  id uuid primary key default gen_random_uuid(),
  campaign_id uuid not null,
  campaign_version_id uuid not null,

  request_status text not null default 'pending',
  requested_state text not null default 'active',
  requested_start_at timestamptz null,
  requested_end_at timestamptz null,

  readiness_status text not null default 'not_evaluated',
  readiness_report jsonb not null default '{}'::jsonb,
  readiness_evaluated_at timestamptz null,

  requested_by text not null,
  request_reason text null,
  reviewed_by text null,
  review_reason text null,
  reviewed_at timestamptz null,

  correlation_id uuid not null default gen_random_uuid(),
  causation_id uuid null,
  metadata jsonb not null default '{}'::jsonb,

  created_at timestamptz not null default clock_timestamp(),
  updated_at timestamptz not null default clock_timestamp(),

  constraint commercial_campaign_activation_requests_campaign_id_fkey
    foreign key (campaign_id)
    references public.reward_campaigns (id)
    on delete restrict,

  constraint commercial_campaign_activation_requests_version_id_fkey
    foreign key (campaign_version_id)
    references public.commercial_campaign_versions (id)
    on delete restrict,

  constraint commercial_campaign_activation_requests_status_check
    check (request_status in ('pending', 'approved', 'rejected', 'cancelled')),

  constraint commercial_campaign_activation_requests_requested_state_check
    check (requested_state in ('scheduled', 'active')),

  constraint commercial_campaign_activation_requests_window_check
    check (requested_end_at is null or requested_start_at is null or requested_end_at > requested_start_at),

  constraint commercial_campaign_activation_requests_readiness_check
    check (readiness_status in ('not_evaluated', 'ready', 'blocked')),

  constraint commercial_campaign_activation_requests_report_object_check
    check (jsonb_typeof(readiness_report) = 'object'),

  constraint commercial_campaign_activation_requests_requested_by_check
    check (length(btrim(requested_by)) between 1 and 160),

  constraint commercial_campaign_activation_requests_metadata_object_check
    check (jsonb_typeof(metadata) = 'object'),

  constraint commercial_campaign_activation_requests_review_check
    check (
      (request_status = 'pending' and reviewed_at is null and reviewed_by is null)
      or
      (request_status <> 'pending' and reviewed_at is not null and reviewed_by is not null)
    )
);

create unique index if not exists commercial_campaign_activation_requests_one_pending_idx
  on public.commercial_campaign_activation_requests (campaign_id)
  where request_status = 'pending';

create index if not exists commercial_campaign_activation_requests_status_idx
  on public.commercial_campaign_activation_requests (request_status, created_at);

comment on table public.commercial_campaign_activation_requests is
  'Explicit approval workflow for campaign scheduling and activation. Requests never settle rewards.';

-- =============================================================================
-- 3. AUTHORITATIVE RUNTIME STATE
-- =============================================================================

create table if not exists public.commercial_campaign_runtime_states (
  campaign_id uuid primary key,
  campaign_code text not null,

  runtime_state text not null default 'inactive',
  active_version_id uuid null,
  activation_request_id uuid null,

  scheduled_start_at timestamptz null,
  scheduled_end_at timestamptz null,
  activated_at timestamptz null,
  suspended_at timestamptz null,
  closed_at timestamptz null,

  state_reason text null,
  readiness_status text not null default 'not_evaluated',
  readiness_report jsonb not null default '{}'::jsonb,
  last_evaluated_at timestamptz null,

  correlation_id uuid null,
  causation_id uuid null,
  metadata jsonb not null default '{}'::jsonb,

  created_at timestamptz not null default clock_timestamp(),
  updated_at timestamptz not null default clock_timestamp(),
  version integer not null default 1,

  constraint commercial_campaign_runtime_states_campaign_id_fkey
    foreign key (campaign_id)
    references public.reward_campaigns (id)
    on delete restrict,

  constraint commercial_campaign_runtime_states_active_version_id_fkey
    foreign key (active_version_id)
    references public.commercial_campaign_versions (id)
    on delete restrict,

  constraint commercial_campaign_runtime_states_activation_request_id_fkey
    foreign key (activation_request_id)
    references public.commercial_campaign_activation_requests (id)
    on delete restrict,

  constraint commercial_campaign_runtime_states_campaign_code_check
    check (
      campaign_code = upper(campaign_code)
      and campaign_code ~ '^[A-Z][A-Z0-9_]{1,95}$'
    ),

  constraint commercial_campaign_runtime_states_runtime_state_check
    check (runtime_state in (
      'inactive',
      'activation_pending',
      'scheduled',
      'active',
      'suspended',
      'blocked',
      'closed'
    )),

  constraint commercial_campaign_runtime_states_readiness_check
    check (readiness_status in ('not_evaluated', 'ready', 'blocked')),

  constraint commercial_campaign_runtime_states_window_check
    check (scheduled_end_at is null or scheduled_start_at is null or scheduled_end_at > scheduled_start_at),

  constraint commercial_campaign_runtime_states_report_object_check
    check (jsonb_typeof(readiness_report) = 'object'),

  constraint commercial_campaign_runtime_states_metadata_object_check
    check (jsonb_typeof(metadata) = 'object'),

  constraint commercial_campaign_runtime_states_version_check
    check (version > 0)
);

create index if not exists commercial_campaign_runtime_states_state_idx
  on public.commercial_campaign_runtime_states (runtime_state, updated_at);

comment on table public.commercial_campaign_runtime_states is
  'Authoritative operational projection for campaign lifecycle. It does not replace reward_campaigns.';

-- =============================================================================
-- 4. IMMUTABLE LIFECYCLE EVENTS
-- =============================================================================

create table if not exists public.commercial_campaign_lifecycle_events (
  id uuid primary key default gen_random_uuid(),
  campaign_id uuid not null,
  campaign_code text not null,
  campaign_version_id uuid null,
  activation_request_id uuid null,

  event_type text not null,
  previous_state text null,
  resulting_state text null,
  actor text not null,
  reason text null,

  correlation_id uuid not null default gen_random_uuid(),
  causation_id uuid null,
  payload jsonb not null default '{}'::jsonb,
  occurred_at timestamptz not null default clock_timestamp(),

  constraint commercial_campaign_lifecycle_events_campaign_id_fkey
    foreign key (campaign_id)
    references public.reward_campaigns (id)
    on delete restrict,

  constraint commercial_campaign_lifecycle_events_version_id_fkey
    foreign key (campaign_version_id)
    references public.commercial_campaign_versions (id)
    on delete restrict,

  constraint commercial_campaign_lifecycle_events_request_id_fkey
    foreign key (activation_request_id)
    references public.commercial_campaign_activation_requests (id)
    on delete restrict,

  constraint commercial_campaign_lifecycle_events_campaign_code_check
    check (
      campaign_code = upper(campaign_code)
      and campaign_code ~ '^[A-Z][A-Z0-9_]{1,95}$'
    ),

  constraint commercial_campaign_lifecycle_events_event_type_check
    check (event_type in (
      'CAMPAIGN_REGISTERED',
      'VERSION_CREATED',
      'VERSION_APPROVED',
      'VERSION_SUPERSEDED',
      'ACTIVATION_REQUESTED',
      'READINESS_EVALUATED',
      'ACTIVATION_APPROVED',
      'ACTIVATION_REJECTED',
      'CAMPAIGN_SCHEDULED',
      'CAMPAIGN_ACTIVATED',
      'CAMPAIGN_SUSPENDED',
      'CAMPAIGN_CLOSED'
    )),

  constraint commercial_campaign_lifecycle_events_actor_check
    check (length(btrim(actor)) between 1 and 160),

  constraint commercial_campaign_lifecycle_events_payload_object_check
    check (jsonb_typeof(payload) = 'object')
);

create index if not exists commercial_campaign_lifecycle_events_timeline_idx
  on public.commercial_campaign_lifecycle_events (campaign_id, occurred_at, id);

create index if not exists commercial_campaign_lifecycle_events_correlation_idx
  on public.commercial_campaign_lifecycle_events (correlation_id, occurred_at);

comment on table public.commercial_campaign_lifecycle_events is
  'Append-only audit timeline for every governed commercial campaign transition.';

-- =============================================================================
-- 5. INITIAL INACTIVE PROJECTION
-- =============================================================================

insert into public.commercial_campaign_runtime_states (
  campaign_id,
  campaign_code,
  runtime_state,
  readiness_status,
  state_reason,
  metadata
)
select
  c.id,
  c.campaign_code,
  'inactive',
  'not_evaluated',
  'MIGRATION_109_INITIAL_PROJECTION',
  jsonb_build_object('initialized_by', 'migration_109')
from public.reward_campaigns c
on conflict (campaign_id) do nothing;

-- =============================================================================
-- 6. PROTECTION TRIGGERS
-- =============================================================================

create or replace function public.protect_commercial_campaign_version_internal()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
  if tg_op = 'DELETE' then
    raise exception using
      errcode = 'P0001',
      message = 'COMMERCIAL_CAMPAIGN_VERSION_DELETE_FORBIDDEN';
  end if;

  if old.version_status <> 'draft' then
    if new.campaign_id is distinct from old.campaign_id
       or new.campaign_code is distinct from old.campaign_code
       or new.version_number is distinct from old.version_number
       or new.configuration_snapshot is distinct from old.configuration_snapshot
       or new.configuration_hash is distinct from old.configuration_hash
       or new.change_summary is distinct from old.change_summary
       or new.created_by is distinct from old.created_by
       or new.created_at is distinct from old.created_at then
      raise exception using
        errcode = 'P0001',
        message = 'COMMERCIAL_CAMPAIGN_APPROVED_VERSION_IMMUTABLE';
    end if;
  end if;

  return new;
end;
$$;

create or replace function public.protect_commercial_campaign_lifecycle_event_internal()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
  raise exception using
    errcode = 'P0001',
    message = 'COMMERCIAL_CAMPAIGN_LIFECYCLE_EVENT_IMMUTABLE';
end;
$$;

drop trigger if exists commercial_campaign_versions_guard
  on public.commercial_campaign_versions;
create trigger commercial_campaign_versions_guard
before update or delete on public.commercial_campaign_versions
for each row execute function public.protect_commercial_campaign_version_internal();

drop trigger if exists commercial_campaign_lifecycle_events_guard
  on public.commercial_campaign_lifecycle_events;
create trigger commercial_campaign_lifecycle_events_guard
before update or delete on public.commercial_campaign_lifecycle_events
for each row execute function public.protect_commercial_campaign_lifecycle_event_internal();

-- =============================================================================
-- 7. INTERNAL EVENT APPEND
-- =============================================================================

create or replace function public.append_commercial_campaign_lifecycle_event_internal(
  p_campaign_id uuid,
  p_campaign_version_id uuid,
  p_activation_request_id uuid,
  p_event_type text,
  p_previous_state text,
  p_resulting_state text,
  p_actor text,
  p_reason text default null,
  p_correlation_id uuid default null,
  p_causation_id uuid default null,
  p_payload jsonb default '{}'::jsonb
)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_campaign_code text;
  v_event_id uuid;
begin
  select campaign_code
  into v_campaign_code
  from public.reward_campaigns
  where id = p_campaign_id;

  if v_campaign_code is null then
    raise exception using errcode = 'P0001', message = 'COMMERCIAL_CAMPAIGN_NOT_FOUND';
  end if;

  insert into public.commercial_campaign_lifecycle_events (
    campaign_id,
    campaign_code,
    campaign_version_id,
    activation_request_id,
    event_type,
    previous_state,
    resulting_state,
    actor,
    reason,
    correlation_id,
    causation_id,
    payload
  ) values (
    p_campaign_id,
    v_campaign_code,
    p_campaign_version_id,
    p_activation_request_id,
    p_event_type,
    p_previous_state,
    p_resulting_state,
    btrim(p_actor),
    p_reason,
    coalesce(p_correlation_id, gen_random_uuid()),
    p_causation_id,
    coalesce(p_payload, '{}'::jsonb)
  )
  returning id into v_event_id;

  return v_event_id;
end;
$$;

-- =============================================================================
-- 8. CREATE CAMPAIGN VERSION
-- =============================================================================

create or replace function public.create_commercial_campaign_version_internal(
  p_campaign_id uuid,
  p_created_by text,
  p_change_summary text default null,
  p_metadata jsonb default '{}'::jsonb,
  p_correlation_id uuid default null,
  p_causation_id uuid default null
)
returns public.commercial_campaign_versions
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_campaign public.reward_campaigns;
  v_snapshot jsonb;
  v_version_number integer;
  v_result public.commercial_campaign_versions;
begin
  select *
  into v_campaign
  from public.reward_campaigns
  where id = p_campaign_id
  for update;

  if not found then
    raise exception using errcode = 'P0001', message = 'COMMERCIAL_CAMPAIGN_NOT_FOUND';
  end if;

  if nullif(btrim(p_created_by), '') is null then
    raise exception using errcode = 'P0001', message = 'COMMERCIAL_CAMPAIGN_ACTOR_REQUIRED';
  end if;

  if jsonb_typeof(coalesce(p_metadata, '{}'::jsonb)) <> 'object' then
    raise exception using errcode = 'P0001', message = 'COMMERCIAL_CAMPAIGN_METADATA_MUST_BE_OBJECT';
  end if;

  v_snapshot := to_jsonb(v_campaign) - array['issued_claims', 'issued_passes', 'created_at', 'updated_at'];

  select coalesce(max(version_number), 0) + 1
  into v_version_number
  from public.commercial_campaign_versions
  where campaign_id = p_campaign_id;

  insert into public.commercial_campaign_versions (
    campaign_id,
    campaign_code,
    version_number,
    version_status,
    configuration_snapshot,
    configuration_hash,
    change_summary,
    created_by,
    metadata
  ) values (
    v_campaign.id,
    v_campaign.campaign_code,
    v_version_number,
    'draft',
    v_snapshot,
    md5(v_snapshot::text),
    p_change_summary,
    btrim(p_created_by),
    coalesce(p_metadata, '{}'::jsonb)
  )
  returning * into v_result;

  perform public.append_commercial_campaign_lifecycle_event_internal(
    p_campaign_id := v_campaign.id,
    p_campaign_version_id := v_result.id,
    p_activation_request_id := null,
    p_event_type := 'VERSION_CREATED',
    p_previous_state := null,
    p_resulting_state := 'draft',
    p_actor := p_created_by,
    p_reason := p_change_summary,
    p_correlation_id := p_correlation_id,
    p_causation_id := p_causation_id,
    p_payload := jsonb_build_object(
      'version_number', v_result.version_number,
      'configuration_hash', v_result.configuration_hash
    )
  );

  return v_result;
end;
$$;

-- =============================================================================
-- 9. APPROVE CAMPAIGN VERSION
-- =============================================================================

create or replace function public.approve_commercial_campaign_version_internal(
  p_campaign_version_id uuid,
  p_approved_by text,
  p_reason text default null,
  p_correlation_id uuid default null,
  p_causation_id uuid default null
)
returns public.commercial_campaign_versions
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_version public.commercial_campaign_versions;
  v_current_snapshot jsonb;
  v_previous_approved_id uuid;
  v_result public.commercial_campaign_versions;
begin
  select *
  into v_version
  from public.commercial_campaign_versions
  where id = p_campaign_version_id
  for update;

  if not found then
    raise exception using errcode = 'P0001', message = 'COMMERCIAL_CAMPAIGN_VERSION_NOT_FOUND';
  end if;

  if v_version.version_status <> 'draft' then
    raise exception using errcode = 'P0001', message = 'COMMERCIAL_CAMPAIGN_VERSION_NOT_DRAFT';
  end if;

  if nullif(btrim(p_approved_by), '') is null then
    raise exception using errcode = 'P0001', message = 'COMMERCIAL_CAMPAIGN_ACTOR_REQUIRED';
  end if;

  select to_jsonb(c) - array['issued_claims', 'issued_passes', 'created_at', 'updated_at']
  into v_current_snapshot
  from public.reward_campaigns c
  where c.id = v_version.campaign_id
  for update;

  if v_current_snapshot is null then
    raise exception using errcode = 'P0001', message = 'COMMERCIAL_CAMPAIGN_NOT_FOUND';
  end if;

  if md5(v_current_snapshot::text) <> v_version.configuration_hash then
    raise exception using errcode = 'P0001', message = 'COMMERCIAL_CAMPAIGN_CONFIGURATION_DRIFT_DETECTED';
  end if;

  select id
  into v_previous_approved_id
  from public.commercial_campaign_versions
  where campaign_id = v_version.campaign_id
    and version_status = 'approved'
  for update;

  if v_previous_approved_id is not null then
    update public.commercial_campaign_versions
    set version_status = 'superseded',
        superseded_at = clock_timestamp()
    where id = v_previous_approved_id;

    perform public.append_commercial_campaign_lifecycle_event_internal(
      v_version.campaign_id,
      v_previous_approved_id,
      null,
      'VERSION_SUPERSEDED',
      'approved',
      'superseded',
      p_approved_by,
      p_reason,
      p_correlation_id,
      p_causation_id,
      jsonb_build_object('superseded_by_version_id', v_version.id)
    );
  end if;

  update public.commercial_campaign_versions
  set version_status = 'approved',
      approved_by = btrim(p_approved_by),
      approved_at = clock_timestamp()
  where id = v_version.id
  returning * into v_result;

  perform public.append_commercial_campaign_lifecycle_event_internal(
    v_result.campaign_id,
    v_result.id,
    null,
    'VERSION_APPROVED',
    'draft',
    'approved',
    p_approved_by,
    p_reason,
    p_correlation_id,
    p_causation_id,
    jsonb_build_object(
      'version_number', v_result.version_number,
      'configuration_hash', v_result.configuration_hash
    )
  );

  return v_result;
end;
$$;

-- =============================================================================
-- 10. READINESS EVALUATION
-- =============================================================================

create or replace function public.evaluate_commercial_campaign_readiness_internal(
  p_campaign_id uuid,
  p_campaign_version_id uuid default null,
  p_requested_start_at timestamptz default null,
  p_requested_end_at timestamptz default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_campaign public.reward_campaigns;
  v_source public.reward_sources;
  v_version public.commercial_campaign_versions;
  v_snapshot jsonb;
  v_blockers jsonb := '[]'::jsonb;
  v_warnings jsonb := '[]'::jsonb;
  v_ready boolean;
  v_effective_start timestamptz;
  v_effective_end timestamptz;
begin
  select * into v_campaign
  from public.reward_campaigns
  where id = p_campaign_id;

  if not found then
    return jsonb_build_object(
      'ready', false,
      'status', 'blocked',
      'blockers', jsonb_build_array('CAMPAIGN_NOT_FOUND'),
      'warnings', '[]'::jsonb,
      'evaluated_at', clock_timestamp()
    );
  end if;

  if p_campaign_version_id is null then
    select * into v_version
    from public.commercial_campaign_versions
    where campaign_id = p_campaign_id
      and version_status = 'approved';
  else
    select * into v_version
    from public.commercial_campaign_versions
    where id = p_campaign_version_id
      and campaign_id = p_campaign_id;
  end if;

  if v_version.id is null then
    v_blockers := v_blockers || jsonb_build_array('APPROVED_CAMPAIGN_VERSION_REQUIRED');
    v_snapshot := to_jsonb(v_campaign) - array['issued_claims', 'issued_passes', 'created_at', 'updated_at'];
  else
    v_snapshot := v_version.configuration_snapshot;

    if v_version.version_status <> 'approved' then
      v_blockers := v_blockers || jsonb_build_array('CAMPAIGN_VERSION_NOT_APPROVED');
    end if;

    if md5((to_jsonb(v_campaign) - array['issued_claims', 'issued_passes', 'created_at', 'updated_at'])::text)
       <> v_version.configuration_hash then
      v_blockers := v_blockers || jsonb_build_array('CAMPAIGN_CONFIGURATION_DRIFT_DETECTED');
    end if;
  end if;

  select * into v_source
  from public.reward_sources
  where id = v_campaign.source_id;

  if v_source.id is null then
    v_blockers := v_blockers || jsonb_build_array('REWARD_SOURCE_NOT_FOUND');
  elsif coalesce((to_jsonb(v_source)->>'enabled')::boolean, false) = false then
    v_blockers := v_blockers || jsonb_build_array('REWARD_SOURCE_DISABLED');
  end if;

  if coalesce((v_snapshot->>'passes_per_claim')::integer, 0) <= 0 then
    v_blockers := v_blockers || jsonb_build_array('INVALID_PASSES_PER_CLAIM');
  end if;

  v_effective_start := coalesce(
    p_requested_start_at,
    nullif(v_snapshot->>'valid_from', '')::timestamptz
  );

  v_effective_end := coalesce(
    p_requested_end_at,
    nullif(v_snapshot->>'valid_until', '')::timestamptz
  );

  if v_effective_end is not null
     and v_effective_start is not null
     and v_effective_end <= v_effective_start then
    v_blockers := v_blockers || jsonb_build_array('INVALID_ACTIVATION_WINDOW');
  end if;

  if v_effective_end is not null and v_effective_end <= clock_timestamp() then
    v_blockers := v_blockers || jsonb_build_array('ACTIVATION_WINDOW_ALREADY_EXPIRED');
  end if;

  if coalesce((v_snapshot->>'issued_claims')::bigint, 0) > 0
     or coalesce((v_snapshot->>'issued_passes')::bigint, 0) > 0 then
    v_warnings := v_warnings || jsonb_build_array('VERSION_SNAPSHOT_EXCLUDES_RUNTIME_COUNTER_AUTHORITY');
  end if;

  v_ready := jsonb_array_length(v_blockers) = 0;

  return jsonb_build_object(
    'ready', v_ready,
    'status', case when v_ready then 'ready' else 'blocked' end,
    'campaign_id', v_campaign.id,
    'campaign_code', v_campaign.campaign_code,
    'campaign_version_id', v_version.id,
    'campaign_version_number', v_version.version_number,
    'configuration_hash', v_version.configuration_hash,
    'source_id', v_campaign.source_id,
    'effective_start_at', v_effective_start,
    'effective_end_at', v_effective_end,
    'blockers', v_blockers,
    'warnings', v_warnings,
    'evaluated_at', clock_timestamp()
  );
end;
$$;

-- =============================================================================
-- 11. REQUEST ACTIVATION
-- =============================================================================

create or replace function public.request_commercial_campaign_activation_internal(
  p_campaign_id uuid,
  p_campaign_version_id uuid,
  p_requested_by text,
  p_requested_start_at timestamptz default null,
  p_requested_end_at timestamptz default null,
  p_request_reason text default null,
  p_metadata jsonb default '{}'::jsonb,
  p_correlation_id uuid default null,
  p_causation_id uuid default null
)
returns public.commercial_campaign_activation_requests
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_campaign public.reward_campaigns;
  v_version public.commercial_campaign_versions;
  v_readiness jsonb;
  v_result public.commercial_campaign_activation_requests;
  v_requested_state text;
  v_previous_state text;
begin
  select * into v_campaign
  from public.reward_campaigns
  where id = p_campaign_id
  for update;

  if not found then
    raise exception using errcode = 'P0001', message = 'COMMERCIAL_CAMPAIGN_NOT_FOUND';
  end if;

  select * into v_version
  from public.commercial_campaign_versions
  where id = p_campaign_version_id
    and campaign_id = p_campaign_id;

  if not found or v_version.version_status <> 'approved' then
    raise exception using errcode = 'P0001', message = 'APPROVED_COMMERCIAL_CAMPAIGN_VERSION_REQUIRED';
  end if;

  if nullif(btrim(p_requested_by), '') is null then
    raise exception using errcode = 'P0001', message = 'COMMERCIAL_CAMPAIGN_ACTOR_REQUIRED';
  end if;

  if p_requested_end_at is not null
     and p_requested_start_at is not null
     and p_requested_end_at <= p_requested_start_at then
    raise exception using errcode = 'P0001', message = 'INVALID_COMMERCIAL_CAMPAIGN_ACTIVATION_WINDOW';
  end if;

  if jsonb_typeof(coalesce(p_metadata, '{}'::jsonb)) <> 'object' then
    raise exception using errcode = 'P0001', message = 'COMMERCIAL_CAMPAIGN_METADATA_MUST_BE_OBJECT';
  end if;

  v_readiness := public.evaluate_commercial_campaign_readiness_internal(
    p_campaign_id,
    p_campaign_version_id,
    p_requested_start_at,
    p_requested_end_at
  );

  v_requested_state := case
    when p_requested_start_at is not null and p_requested_start_at > clock_timestamp()
      then 'scheduled'
    else 'active'
  end;

  insert into public.commercial_campaign_activation_requests (
    campaign_id,
    campaign_version_id,
    request_status,
    requested_state,
    requested_start_at,
    requested_end_at,
    readiness_status,
    readiness_report,
    readiness_evaluated_at,
    requested_by,
    request_reason,
    correlation_id,
    causation_id,
    metadata
  ) values (
    p_campaign_id,
    p_campaign_version_id,
    'pending',
    v_requested_state,
    p_requested_start_at,
    p_requested_end_at,
    v_readiness->>'status',
    v_readiness,
    clock_timestamp(),
    btrim(p_requested_by),
    p_request_reason,
    coalesce(p_correlation_id, gen_random_uuid()),
    p_causation_id,
    coalesce(p_metadata, '{}'::jsonb)
  )
  returning * into v_result;

  select runtime_state
  into v_previous_state
  from public.commercial_campaign_runtime_states
  where campaign_id = p_campaign_id
  for update;

  insert into public.commercial_campaign_runtime_states (
    campaign_id,
    campaign_code,
    runtime_state,
    active_version_id,
    activation_request_id,
    scheduled_start_at,
    scheduled_end_at,
    state_reason,
    readiness_status,
    readiness_report,
    last_evaluated_at,
    correlation_id,
    causation_id,
    metadata
  ) values (
    p_campaign_id,
    v_campaign.campaign_code,
    'activation_pending',
    p_campaign_version_id,
    v_result.id,
    p_requested_start_at,
    p_requested_end_at,
    'ACTIVATION_REQUEST_PENDING_REVIEW',
    v_readiness->>'status',
    v_readiness,
    clock_timestamp(),
    v_result.correlation_id,
    p_causation_id,
    '{}'::jsonb
  )
  on conflict (campaign_id) do update
  set runtime_state = 'activation_pending',
      active_version_id = excluded.active_version_id,
      activation_request_id = excluded.activation_request_id,
      scheduled_start_at = excluded.scheduled_start_at,
      scheduled_end_at = excluded.scheduled_end_at,
      state_reason = excluded.state_reason,
      readiness_status = excluded.readiness_status,
      readiness_report = excluded.readiness_report,
      last_evaluated_at = excluded.last_evaluated_at,
      correlation_id = excluded.correlation_id,
      causation_id = excluded.causation_id,
      updated_at = clock_timestamp(),
      version = public.commercial_campaign_runtime_states.version + 1;

  perform public.append_commercial_campaign_lifecycle_event_internal(
    p_campaign_id,
    p_campaign_version_id,
    v_result.id,
    'ACTIVATION_REQUESTED',
    v_previous_state,
    'activation_pending',
    p_requested_by,
    p_request_reason,
    v_result.correlation_id,
    p_causation_id,
    jsonb_build_object(
      'requested_state', v_requested_state,
      'requested_start_at', p_requested_start_at,
      'requested_end_at', p_requested_end_at,
      'readiness_status', v_readiness->>'status'
    )
  );

  perform public.append_commercial_campaign_lifecycle_event_internal(
    p_campaign_id,
    p_campaign_version_id,
    v_result.id,
    'READINESS_EVALUATED',
    'activation_pending',
    'activation_pending',
    p_requested_by,
    null,
    v_result.correlation_id,
    p_causation_id,
    v_readiness
  );

  return v_result;
end;
$$;

-- =============================================================================
-- 12. APPROVE ACTIVATION
-- =============================================================================

create or replace function public.approve_commercial_campaign_activation_internal(
  p_activation_request_id uuid,
  p_approved_by text,
  p_review_reason text default null,
  p_causation_id uuid default null
)
returns public.commercial_campaign_runtime_states
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_request public.commercial_campaign_activation_requests;
  v_campaign public.reward_campaigns;
  v_readiness jsonb;
  v_target_state text;
  v_result public.commercial_campaign_runtime_states;
begin
  select * into v_request
  from public.commercial_campaign_activation_requests
  where id = p_activation_request_id
  for update;

  if not found then
    raise exception using errcode = 'P0001', message = 'COMMERCIAL_CAMPAIGN_ACTIVATION_REQUEST_NOT_FOUND';
  end if;

  if v_request.request_status <> 'pending' then
    raise exception using errcode = 'P0001', message = 'COMMERCIAL_CAMPAIGN_ACTIVATION_REQUEST_NOT_PENDING';
  end if;

  if nullif(btrim(p_approved_by), '') is null then
    raise exception using errcode = 'P0001', message = 'COMMERCIAL_CAMPAIGN_ACTOR_REQUIRED';
  end if;

  select * into v_campaign
  from public.reward_campaigns
  where id = v_request.campaign_id
  for update;

  v_readiness := public.evaluate_commercial_campaign_readiness_internal(
    v_request.campaign_id,
    v_request.campaign_version_id,
    v_request.requested_start_at,
    v_request.requested_end_at
  );

  if coalesce((v_readiness->>'ready')::boolean, false) = false then
    update public.commercial_campaign_activation_requests
    set readiness_status = 'blocked',
        readiness_report = v_readiness,
        readiness_evaluated_at = clock_timestamp(),
        updated_at = clock_timestamp()
    where id = v_request.id;

    update public.commercial_campaign_runtime_states
    set runtime_state = 'blocked',
        state_reason = 'READINESS_BLOCKED_ACTIVATION',
        readiness_status = 'blocked',
        readiness_report = v_readiness,
        last_evaluated_at = clock_timestamp(),
        updated_at = clock_timestamp(),
        version = version + 1
    where campaign_id = v_request.campaign_id
    returning * into v_result;

    perform public.append_commercial_campaign_lifecycle_event_internal(
      v_request.campaign_id,
      v_request.campaign_version_id,
      v_request.id,
      'READINESS_EVALUATED',
      'activation_pending',
      'blocked',
      p_approved_by,
      'ACTIVATION_BLOCKED_BY_READINESS',
      v_request.correlation_id,
      p_causation_id,
      v_readiness
    );

    return v_result;
  end if;

  v_target_state := case
    when v_request.requested_start_at is not null
         and v_request.requested_start_at > clock_timestamp()
      then 'scheduled'
    else 'active'
  end;

  update public.commercial_campaign_activation_requests
  set request_status = 'approved',
      readiness_status = 'ready',
      readiness_report = v_readiness,
      readiness_evaluated_at = clock_timestamp(),
      reviewed_by = btrim(p_approved_by),
      review_reason = p_review_reason,
      reviewed_at = clock_timestamp(),
      updated_at = clock_timestamp()
  where id = v_request.id;

  update public.reward_campaigns
  set enabled = (v_target_state = 'active'),
      updated_at = clock_timestamp()
  where id = v_request.campaign_id;

  update public.commercial_campaign_runtime_states
  set runtime_state = v_target_state,
      active_version_id = v_request.campaign_version_id,
      activation_request_id = v_request.id,
      scheduled_start_at = v_request.requested_start_at,
      scheduled_end_at = v_request.requested_end_at,
      activated_at = case when v_target_state = 'active' then clock_timestamp() else null end,
      suspended_at = null,
      closed_at = null,
      state_reason = 'ACTIVATION_EXPLICITLY_APPROVED',
      readiness_status = 'ready',
      readiness_report = v_readiness,
      last_evaluated_at = clock_timestamp(),
      correlation_id = v_request.correlation_id,
      causation_id = p_causation_id,
      updated_at = clock_timestamp(),
      version = version + 1
  where campaign_id = v_request.campaign_id
  returning * into v_result;

  perform public.append_commercial_campaign_lifecycle_event_internal(
    v_request.campaign_id,
    v_request.campaign_version_id,
    v_request.id,
    'ACTIVATION_APPROVED',
    'activation_pending',
    v_target_state,
    p_approved_by,
    p_review_reason,
    v_request.correlation_id,
    p_causation_id,
    v_readiness
  );

  perform public.append_commercial_campaign_lifecycle_event_internal(
    v_request.campaign_id,
    v_request.campaign_version_id,
    v_request.id,
    case when v_target_state = 'scheduled' then 'CAMPAIGN_SCHEDULED' else 'CAMPAIGN_ACTIVATED' end,
    'activation_pending',
    v_target_state,
    p_approved_by,
    p_review_reason,
    v_request.correlation_id,
    p_causation_id,
    jsonb_build_object(
      'scheduled_start_at', v_request.requested_start_at,
      'scheduled_end_at', v_request.requested_end_at
    )
  );

  return v_result;
end;
$$;

-- =============================================================================
-- 13. REJECT ACTIVATION
-- =============================================================================

create or replace function public.reject_commercial_campaign_activation_internal(
  p_activation_request_id uuid,
  p_rejected_by text,
  p_review_reason text,
  p_causation_id uuid default null
)
returns public.commercial_campaign_activation_requests
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_request public.commercial_campaign_activation_requests;
  v_result public.commercial_campaign_activation_requests;
begin
  select * into v_request
  from public.commercial_campaign_activation_requests
  where id = p_activation_request_id
  for update;

  if not found then
    raise exception using errcode = 'P0001', message = 'COMMERCIAL_CAMPAIGN_ACTIVATION_REQUEST_NOT_FOUND';
  end if;

  if v_request.request_status <> 'pending' then
    raise exception using errcode = 'P0001', message = 'COMMERCIAL_CAMPAIGN_ACTIVATION_REQUEST_NOT_PENDING';
  end if;

  if nullif(btrim(p_rejected_by), '') is null
     or nullif(btrim(p_review_reason), '') is null then
    raise exception using errcode = 'P0001', message = 'COMMERCIAL_CAMPAIGN_REJECTION_ACTOR_AND_REASON_REQUIRED';
  end if;

  update public.commercial_campaign_activation_requests
  set request_status = 'rejected',
      reviewed_by = btrim(p_rejected_by),
      review_reason = btrim(p_review_reason),
      reviewed_at = clock_timestamp(),
      updated_at = clock_timestamp()
  where id = v_request.id
  returning * into v_result;

  update public.commercial_campaign_runtime_states
  set runtime_state = 'inactive',
      activation_request_id = v_request.id,
      state_reason = 'ACTIVATION_EXPLICITLY_REJECTED',
      updated_at = clock_timestamp(),
      version = version + 1
  where campaign_id = v_request.campaign_id;

  perform public.append_commercial_campaign_lifecycle_event_internal(
    v_request.campaign_id,
    v_request.campaign_version_id,
    v_request.id,
    'ACTIVATION_REJECTED',
    'activation_pending',
    'inactive',
    p_rejected_by,
    p_review_reason,
    v_request.correlation_id,
    p_causation_id,
    '{}'::jsonb
  );

  return v_result;
end;
$$;

-- =============================================================================
-- 14. SUSPEND CAMPAIGN
-- =============================================================================

create or replace function public.suspend_commercial_campaign_internal(
  p_campaign_id uuid,
  p_actor text,
  p_reason text,
  p_correlation_id uuid default null,
  p_causation_id uuid default null
)
returns public.commercial_campaign_runtime_states
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_state public.commercial_campaign_runtime_states;
  v_result public.commercial_campaign_runtime_states;
begin
  select * into v_state
  from public.commercial_campaign_runtime_states
  where campaign_id = p_campaign_id
  for update;

  if not found then
    raise exception using errcode = 'P0001', message = 'COMMERCIAL_CAMPAIGN_RUNTIME_STATE_NOT_FOUND';
  end if;

  if v_state.runtime_state not in ('scheduled', 'active') then
    raise exception using errcode = 'P0001', message = 'COMMERCIAL_CAMPAIGN_NOT_SUSPENDABLE';
  end if;

  if nullif(btrim(p_actor), '') is null or nullif(btrim(p_reason), '') is null then
    raise exception using errcode = 'P0001', message = 'COMMERCIAL_CAMPAIGN_SUSPENSION_ACTOR_AND_REASON_REQUIRED';
  end if;

  update public.reward_campaigns
  set enabled = false,
      updated_at = clock_timestamp()
  where id = p_campaign_id;

  update public.commercial_campaign_runtime_states
  set runtime_state = 'suspended',
      suspended_at = clock_timestamp(),
      state_reason = btrim(p_reason),
      correlation_id = coalesce(p_correlation_id, correlation_id, gen_random_uuid()),
      causation_id = p_causation_id,
      updated_at = clock_timestamp(),
      version = version + 1
  where campaign_id = p_campaign_id
  returning * into v_result;

  perform public.append_commercial_campaign_lifecycle_event_internal(
    p_campaign_id,
    v_state.active_version_id,
    v_state.activation_request_id,
    'CAMPAIGN_SUSPENDED',
    v_state.runtime_state,
    'suspended',
    p_actor,
    p_reason,
    coalesce(p_correlation_id, v_state.correlation_id),
    p_causation_id,
    '{}'::jsonb
  );

  return v_result;
end;
$$;

-- =============================================================================
-- 15. CLOSE CAMPAIGN
-- =============================================================================

create or replace function public.close_commercial_campaign_internal(
  p_campaign_id uuid,
  p_actor text,
  p_reason text,
  p_correlation_id uuid default null,
  p_causation_id uuid default null
)
returns public.commercial_campaign_runtime_states
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_state public.commercial_campaign_runtime_states;
  v_result public.commercial_campaign_runtime_states;
begin
  select * into v_state
  from public.commercial_campaign_runtime_states
  where campaign_id = p_campaign_id
  for update;

  if not found then
    raise exception using errcode = 'P0001', message = 'COMMERCIAL_CAMPAIGN_RUNTIME_STATE_NOT_FOUND';
  end if;

  if v_state.runtime_state = 'closed' then
    return v_state;
  end if;

  if nullif(btrim(p_actor), '') is null or nullif(btrim(p_reason), '') is null then
    raise exception using errcode = 'P0001', message = 'COMMERCIAL_CAMPAIGN_CLOSURE_ACTOR_AND_REASON_REQUIRED';
  end if;

  update public.reward_campaigns
  set enabled = false,
      updated_at = clock_timestamp()
  where id = p_campaign_id;

  update public.commercial_campaign_runtime_states
  set runtime_state = 'closed',
      closed_at = clock_timestamp(),
      state_reason = btrim(p_reason),
      correlation_id = coalesce(p_correlation_id, correlation_id, gen_random_uuid()),
      causation_id = p_causation_id,
      updated_at = clock_timestamp(),
      version = version + 1
  where campaign_id = p_campaign_id
  returning * into v_result;

  perform public.append_commercial_campaign_lifecycle_event_internal(
    p_campaign_id,
    v_state.active_version_id,
    v_state.activation_request_id,
    'CAMPAIGN_CLOSED',
    v_state.runtime_state,
    'closed',
    p_actor,
    p_reason,
    coalesce(p_correlation_id, v_state.correlation_id),
    p_causation_id,
    '{}'::jsonb
  );

  return v_result;
end;
$$;

-- =============================================================================
-- 16. PRIVATE READ MODELS
-- =============================================================================

create or replace function public.get_commercial_campaign_runtime_states_internal()
returns table (
  campaign_id uuid,
  campaign_code text,
  runtime_state text,
  active_version_id uuid,
  active_version_number integer,
  activation_request_id uuid,
  scheduled_start_at timestamptz,
  scheduled_end_at timestamptz,
  readiness_status text,
  readiness_report jsonb,
  state_reason text,
  updated_at timestamptz,
  version integer
)
language sql
security definer
stable
set search_path = public, pg_temp
as $$
  select
    s.campaign_id,
    s.campaign_code,
    s.runtime_state,
    s.active_version_id,
    v.version_number,
    s.activation_request_id,
    s.scheduled_start_at,
    s.scheduled_end_at,
    s.readiness_status,
    s.readiness_report,
    s.state_reason,
    s.updated_at,
    s.version
  from public.commercial_campaign_runtime_states s
  left join public.commercial_campaign_versions v
    on v.id = s.active_version_id
  order by s.campaign_code;
$$;

create or replace function public.get_commercial_campaign_lifecycle_internal(
  p_campaign_id uuid
)
returns setof public.commercial_campaign_lifecycle_events
language sql
security definer
stable
set search_path = public, pg_temp
as $$
  select e.*
  from public.commercial_campaign_lifecycle_events e
  where e.campaign_id = p_campaign_id
  order by e.occurred_at, e.id;
$$;

-- =============================================================================
-- 17. RLS AND PRIVILEGES
-- =============================================================================

alter table public.commercial_campaign_versions enable row level security;
alter table public.commercial_campaign_activation_requests enable row level security;
alter table public.commercial_campaign_runtime_states enable row level security;
alter table public.commercial_campaign_lifecycle_events enable row level security;

revoke all on table public.commercial_campaign_versions from public, anon, authenticated;
revoke all on table public.commercial_campaign_activation_requests from public, anon, authenticated;
revoke all on table public.commercial_campaign_runtime_states from public, anon, authenticated;
revoke all on table public.commercial_campaign_lifecycle_events from public, anon, authenticated;

revoke all on function public.protect_commercial_campaign_version_internal() from public, anon, authenticated;
revoke all on function public.protect_commercial_campaign_lifecycle_event_internal() from public, anon, authenticated;
revoke all on function public.append_commercial_campaign_lifecycle_event_internal(uuid, uuid, uuid, text, text, text, text, text, uuid, uuid, jsonb) from public, anon, authenticated;
revoke all on function public.create_commercial_campaign_version_internal(uuid, text, text, jsonb, uuid, uuid) from public, anon, authenticated;
revoke all on function public.approve_commercial_campaign_version_internal(uuid, text, text, uuid, uuid) from public, anon, authenticated;
revoke all on function public.evaluate_commercial_campaign_readiness_internal(uuid, uuid, timestamptz, timestamptz) from public, anon, authenticated;
revoke all on function public.request_commercial_campaign_activation_internal(uuid, uuid, text, timestamptz, timestamptz, text, jsonb, uuid, uuid) from public, anon, authenticated;
revoke all on function public.approve_commercial_campaign_activation_internal(uuid, text, text, uuid) from public, anon, authenticated;
revoke all on function public.reject_commercial_campaign_activation_internal(uuid, text, text, uuid) from public, anon, authenticated;
revoke all on function public.suspend_commercial_campaign_internal(uuid, text, text, uuid, uuid) from public, anon, authenticated;
revoke all on function public.close_commercial_campaign_internal(uuid, text, text, uuid, uuid) from public, anon, authenticated;
revoke all on function public.get_commercial_campaign_runtime_states_internal() from public, anon, authenticated;
revoke all on function public.get_commercial_campaign_lifecycle_internal(uuid) from public, anon, authenticated;

-- Explicit backend-only access.
grant select, insert, update on table public.commercial_campaign_versions to service_role;
grant select, insert, update on table public.commercial_campaign_activation_requests to service_role;
grant select, insert, update on table public.commercial_campaign_runtime_states to service_role;
grant select, insert on table public.commercial_campaign_lifecycle_events to service_role;

grant execute on function public.append_commercial_campaign_lifecycle_event_internal(uuid, uuid, uuid, text, text, text, text, text, uuid, uuid, jsonb) to service_role;
grant execute on function public.create_commercial_campaign_version_internal(uuid, text, text, jsonb, uuid, uuid) to service_role;
grant execute on function public.approve_commercial_campaign_version_internal(uuid, text, text, uuid, uuid) to service_role;
grant execute on function public.evaluate_commercial_campaign_readiness_internal(uuid, uuid, timestamptz, timestamptz) to service_role;
grant execute on function public.request_commercial_campaign_activation_internal(uuid, uuid, text, timestamptz, timestamptz, text, jsonb, uuid, uuid) to service_role;
grant execute on function public.approve_commercial_campaign_activation_internal(uuid, text, text, uuid) to service_role;
grant execute on function public.reject_commercial_campaign_activation_internal(uuid, text, text, uuid) to service_role;
grant execute on function public.suspend_commercial_campaign_internal(uuid, text, text, uuid, uuid) to service_role;
grant execute on function public.close_commercial_campaign_internal(uuid, text, text, uuid, uuid) to service_role;
grant execute on function public.get_commercial_campaign_runtime_states_internal() to service_role;
grant execute on function public.get_commercial_campaign_lifecycle_internal(uuid) to service_role;

-- =============================================================================
-- 18. FOUNDATION CERTIFICATION ASSERTIONS
-- =============================================================================

do $$
declare
  v_campaign_count bigint;
  v_runtime_count bigint;
  v_enabled_count bigint;
  v_public_count bigint;
begin
  select count(*) into v_campaign_count
  from public.reward_campaigns;

  select count(*) into v_runtime_count
  from public.commercial_campaign_runtime_states;

  if v_campaign_count <> v_runtime_count then
    raise exception using
      errcode = 'P0001',
      message = 'COMMERCIAL_CAMPAIGN_RUNTIME_PROJECTION_INCOMPLETE';
  end if;

  select count(*) into v_enabled_count
  from public.reward_campaigns
  where enabled = true;

  select count(*) into v_public_count
  from public.reward_campaigns
  where public = true;

  -- Migration 109 must not alter existing activation or visibility decisions.
  -- Counts are recorded only as a migration notice; no campaign is toggled here.
  raise notice 'MIGRATION_109_CERTIFIED campaign_count=%, runtime_count=%, enabled_count=%, public_count=%',
    v_campaign_count,
    v_runtime_count,
    v_enabled_count,
    v_public_count;
end;
$$;

commit;
