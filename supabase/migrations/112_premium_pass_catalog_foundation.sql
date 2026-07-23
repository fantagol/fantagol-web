-- ============================================================================
-- FANTAGOL — MIGRATION 112
-- PREMIUM PASS CATALOG FOUNDATION
-- ============================================================================
-- Purpose:
--   - Define the single canonical Premium Pass economic unit
--   - Version and govern its catalog policy
--   - Bind existing commercial products to their canonical Pass quantity
--   - Keep Ledger as source of truth and Wallet as projection
--
-- Safety:
--   - No Wallet or Ledger mutation
--   - No Pass credit, debit, purchase, reward, grant or consumption
--   - No provider integration
--   - No product, campaign or provider activation
--   - Existing commercial_products purchase contract is preserved
-- ============================================================================

begin;

-- --------------------------------------------------------------------------
-- 0. Prerequisite contract
-- --------------------------------------------------------------------------

do $$
begin
  if to_regclass('public.commercial_products') is null then
    raise exception 'MIGRATION_112_REQUIRES_COMMERCIAL_PRODUCTS';
  end if;

  if not exists (
    select 1 from information_schema.columns
    where table_schema = 'public'
      and table_name = 'commercial_products'
      and column_name = 'passes'
  ) then
    raise exception 'MIGRATION_112_REQUIRES_COMMERCIAL_PRODUCTS_PASSES';
  end if;

  if to_regclass('public.commercial_product_runtime_states') is null then
    raise exception 'MIGRATION_112_REQUIRES_MIGRATION_111';
  end if;
end;
$$;

-- --------------------------------------------------------------------------
-- 1. Canonical Pass definition
-- --------------------------------------------------------------------------

create table public.premium_pass_definitions (
  id uuid primary key default gen_random_uuid(),
  pass_code text not null unique,
  display_name text not null,
  description text,

  unit_scale integer not null default 1,
  ledger_unit_code text not null default 'PREMIUM_PASS',
  wallet_unit_code text not null default 'PREMIUM_PASS',

  catalog_status text not null default 'draft',
  enabled boolean not null default false,
  public boolean not null default false,
  transferable boolean not null default false,
  expires_by_default boolean not null default false,

  configuration jsonb not null default '{}'::jsonb,
  metadata jsonb not null default '{}'::jsonb,

  created_at timestamptz not null default clock_timestamp(),
  updated_at timestamptz not null default clock_timestamp(),

  constraint premium_pass_definitions_code_check
    check (pass_code ~ '^[A-Z][A-Z0-9_]{2,63}$'),
  constraint premium_pass_definitions_unit_scale_check
    check (unit_scale = 1),
  constraint premium_pass_definitions_status_check
    check (catalog_status in ('draft', 'approved', 'retired')),
  constraint premium_pass_definitions_public_check
    check (not public or enabled),
  constraint premium_pass_definitions_configuration_check
    check (jsonb_typeof(configuration) = 'object'),
  constraint premium_pass_definitions_metadata_check
    check (jsonb_typeof(metadata) = 'object')
);

create unique index premium_pass_single_active_unit_idx
  on public.premium_pass_definitions ((1))
  where catalog_status <> 'retired';

comment on table public.premium_pass_definitions is
  'Canonical Premium Pass denomination registry. FantaGol supports one non-fractional internal Pass unit.';

-- --------------------------------------------------------------------------
-- 2. Immutable policy versions
-- --------------------------------------------------------------------------

create table public.premium_pass_policy_versions (
  id uuid primary key default gen_random_uuid(),
  pass_definition_id uuid not null
    references public.premium_pass_definitions(id) on delete restrict,
  version_number integer not null,
  version_status text not null default 'draft',

  policy_snapshot jsonb not null,
  change_summary text,

  created_by text not null,
  created_at timestamptz not null default clock_timestamp(),
  approved_by text,
  approved_at timestamptz,
  approval_reason text,
  metadata jsonb not null default '{}'::jsonb,

  constraint premium_pass_policy_versions_unique
    unique (pass_definition_id, version_number),
  constraint premium_pass_policy_versions_number_check
    check (version_number > 0),
  constraint premium_pass_policy_versions_status_check
    check (version_status in ('draft', 'approved', 'superseded', 'retired')),
  constraint premium_pass_policy_versions_snapshot_check
    check (jsonb_typeof(policy_snapshot) = 'object'),
  constraint premium_pass_policy_versions_metadata_check
    check (jsonb_typeof(metadata) = 'object'),
  constraint premium_pass_policy_versions_approval_check
    check (
      (version_status = 'draft' and approved_at is null and approved_by is null)
      or
      (version_status <> 'draft' and approved_at is not null and approved_by is not null)
    )
);

create unique index premium_pass_one_approved_version_idx
  on public.premium_pass_policy_versions(pass_definition_id)
  where version_status = 'approved';

comment on table public.premium_pass_policy_versions is
  'Immutable version history for Premium Pass denomination, accounting and consumption policy.';

-- --------------------------------------------------------------------------
-- 3. Product composition
-- --------------------------------------------------------------------------

create table public.commercial_product_pass_components (
  id uuid primary key default gen_random_uuid(),
  product_id uuid not null
    references public.commercial_products(id) on delete restrict,
  pass_definition_id uuid not null
    references public.premium_pass_definitions(id) on delete restrict,
  quantity integer not null,
  component_status text not null default 'declared',
  configuration jsonb not null default '{}'::jsonb,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default clock_timestamp(),
  updated_at timestamptz not null default clock_timestamp(),

  constraint commercial_product_pass_components_unique
    unique (product_id, pass_definition_id),
  constraint commercial_product_pass_components_quantity_check
    check (quantity > 0),
  constraint commercial_product_pass_components_status_check
    check (component_status in ('declared', 'certified', 'suspended', 'retired')),
  constraint commercial_product_pass_components_configuration_check
    check (jsonb_typeof(configuration) = 'object'),
  constraint commercial_product_pass_components_metadata_check
    check (jsonb_typeof(metadata) = 'object')
);

create index commercial_product_pass_components_pass_idx
  on public.commercial_product_pass_components(pass_definition_id, component_status);

comment on table public.commercial_product_pass_components is
  'Declarative mapping between an existing commercial product and its canonical Premium Pass quantity.';

-- --------------------------------------------------------------------------
-- 4. Activation governance
-- --------------------------------------------------------------------------

create table public.premium_pass_activation_requests (
  id uuid primary key default gen_random_uuid(),
  pass_definition_id uuid not null
    references public.premium_pass_definitions(id) on delete restrict,
  policy_version_id uuid not null
    references public.premium_pass_policy_versions(id) on delete restrict,

  request_status text not null default 'pending',
  readiness_status text not null default 'not_evaluated',
  readiness_report jsonb not null default '{}'::jsonb,
  request_reason text,
  requested_by text not null,
  requested_at timestamptz not null default clock_timestamp(),
  reviewed_by text,
  reviewed_at timestamptz,
  review_reason text,
  metadata jsonb not null default '{}'::jsonb,

  constraint premium_pass_activation_requests_status_check
    check (request_status in ('pending', 'approved', 'rejected', 'cancelled')),
  constraint premium_pass_activation_requests_readiness_check
    check (readiness_status in ('not_evaluated', 'ready', 'blocked')),
  constraint premium_pass_activation_requests_report_check
    check (jsonb_typeof(readiness_report) = 'object'),
  constraint premium_pass_activation_requests_metadata_check
    check (jsonb_typeof(metadata) = 'object'),
  constraint premium_pass_activation_requests_review_check
    check (
      (request_status = 'pending' and reviewed_at is null and reviewed_by is null)
      or
      (request_status <> 'pending' and reviewed_at is not null and reviewed_by is not null)
    )
);

create unique index premium_pass_one_pending_activation_idx
  on public.premium_pass_activation_requests(pass_definition_id)
  where request_status = 'pending';

create table public.premium_pass_runtime_states (
  pass_definition_id uuid primary key
    references public.premium_pass_definitions(id) on delete restrict,
  runtime_state text not null default 'inactive',
  readiness_status text not null default 'not_evaluated',
  readiness_report jsonb not null default '{}'::jsonb,
  active_policy_version_id uuid
    references public.premium_pass_policy_versions(id) on delete restrict,
  activation_request_id uuid
    references public.premium_pass_activation_requests(id) on delete set null,
  state_reason text not null default 'CATALOG_FOUNDATION_INITIALIZED',
  evaluated_at timestamptz,
  activated_at timestamptz,
  suspended_at timestamptz,
  retired_at timestamptz,
  updated_at timestamptz not null default clock_timestamp(),

  constraint premium_pass_runtime_states_state_check
    check (runtime_state in ('inactive', 'activation_pending', 'active', 'blocked', 'suspended', 'retired')),
  constraint premium_pass_runtime_states_readiness_check
    check (readiness_status in ('not_evaluated', 'ready', 'blocked')),
  constraint premium_pass_runtime_states_report_check
    check (jsonb_typeof(readiness_report) = 'object')
);

create table public.premium_pass_lifecycle_events (
  id uuid primary key default gen_random_uuid(),
  pass_definition_id uuid not null
    references public.premium_pass_definitions(id) on delete restrict,
  policy_version_id uuid
    references public.premium_pass_policy_versions(id) on delete restrict,
  activation_request_id uuid
    references public.premium_pass_activation_requests(id) on delete set null,
  event_type text not null,
  previous_state text,
  next_state text,
  actor text not null,
  reason text,
  payload jsonb not null default '{}'::jsonb,
  occurred_at timestamptz not null default clock_timestamp(),

  constraint premium_pass_lifecycle_events_type_check
    check (event_type in (
      'PASS_DEFINITION_REGISTERED',
      'PASS_POLICY_VERSION_CREATED',
      'PASS_POLICY_VERSION_APPROVED',
      'PASS_READINESS_EVALUATED',
      'PASS_ACTIVATION_REQUESTED',
      'PASS_ACTIVATION_APPROVED',
      'PASS_ACTIVATION_REJECTED',
      'PASS_SUSPENDED',
      'PASS_RETIRED'
    )),
  constraint premium_pass_lifecycle_events_payload_check
    check (jsonb_typeof(payload) = 'object')
);

create index premium_pass_lifecycle_timeline_idx
  on public.premium_pass_lifecycle_events(pass_definition_id, occurred_at, id);

-- --------------------------------------------------------------------------
-- 5. Immutability guards
-- --------------------------------------------------------------------------

create or replace function public.protect_premium_pass_policy_version_internal()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if tg_op = 'DELETE' then
    raise exception 'PREMIUM_PASS_POLICY_VERSION_DELETE_FORBIDDEN';
  end if;

  if old.version_status <> 'draft' then
    raise exception 'PREMIUM_PASS_POLICY_VERSION_IMMUTABLE';
  end if;

  if new.pass_definition_id <> old.pass_definition_id
     or new.version_number <> old.version_number
     or new.policy_snapshot <> old.policy_snapshot
     or new.created_by <> old.created_by
     or new.created_at <> old.created_at then
    raise exception 'PREMIUM_PASS_POLICY_VERSION_CORE_IMMUTABLE';
  end if;

  return new;
end;
$$;

create trigger premium_pass_policy_versions_guard
before update or delete on public.premium_pass_policy_versions
for each row execute function public.protect_premium_pass_policy_version_internal();

create or replace function public.protect_premium_pass_lifecycle_event_internal()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  raise exception 'PREMIUM_PASS_LIFECYCLE_APPEND_ONLY';
end;
$$;

create trigger premium_pass_lifecycle_events_guard
before update or delete on public.premium_pass_lifecycle_events
for each row execute function public.protect_premium_pass_lifecycle_event_internal();

create or replace function public.append_premium_pass_lifecycle_event_internal(
  p_pass_definition_id uuid,
  p_policy_version_id uuid,
  p_activation_request_id uuid,
  p_event_type text,
  p_previous_state text,
  p_next_state text,
  p_actor text,
  p_reason text,
  p_payload jsonb default '{}'::jsonb
)
returns public.premium_pass_lifecycle_events
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_event public.premium_pass_lifecycle_events;
begin
  insert into public.premium_pass_lifecycle_events (
    pass_definition_id, policy_version_id, activation_request_id,
    event_type, previous_state, next_state, actor, reason, payload
  ) values (
    p_pass_definition_id, p_policy_version_id, p_activation_request_id,
    p_event_type, p_previous_state, p_next_state, p_actor, p_reason,
    coalesce(p_payload, '{}'::jsonb)
  ) returning * into v_event;

  return v_event;
end;
$$;

-- --------------------------------------------------------------------------
-- 6. Governance functions
-- --------------------------------------------------------------------------

create or replace function public.create_premium_pass_policy_version_internal(
  p_pass_definition_id uuid,
  p_created_by text,
  p_change_summary text default null,
  p_policy_overrides jsonb default '{}'::jsonb,
  p_metadata jsonb default '{}'::jsonb
)
returns public.premium_pass_policy_versions
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_pass public.premium_pass_definitions;
  v_version public.premium_pass_policy_versions;
  v_next integer;
begin
  select * into v_pass
  from public.premium_pass_definitions
  where id = p_pass_definition_id
  for update;

  if not found then raise exception 'PREMIUM_PASS_DEFINITION_NOT_FOUND'; end if;
  if coalesce(btrim(p_created_by), '') = '' then raise exception 'CREATED_BY_REQUIRED'; end if;
  if jsonb_typeof(coalesce(p_policy_overrides, '{}'::jsonb)) <> 'object' then
    raise exception 'POLICY_OVERRIDES_MUST_BE_OBJECT';
  end if;

  select coalesce(max(version_number), 0) + 1
  into v_next
  from public.premium_pass_policy_versions
  where pass_definition_id = p_pass_definition_id;

  insert into public.premium_pass_policy_versions (
    pass_definition_id, version_number, version_status,
    policy_snapshot, change_summary, created_by, metadata
  ) values (
    p_pass_definition_id,
    v_next,
    'draft',
    jsonb_build_object(
      'pass_code', v_pass.pass_code,
      'unit_scale', v_pass.unit_scale,
      'ledger_unit_code', v_pass.ledger_unit_code,
      'wallet_unit_code', v_pass.wallet_unit_code,
      'transferable', v_pass.transferable,
      'expires_by_default', v_pass.expires_by_default,
      'accounting_model', 'IMMUTABLE_LEDGER_WITH_WALLET_PROJECTION',
      'fractional_units_allowed', false
    ) || coalesce(p_policy_overrides, '{}'::jsonb),
    p_change_summary,
    p_created_by,
    coalesce(p_metadata, '{}'::jsonb)
  ) returning * into v_version;

  perform public.append_premium_pass_lifecycle_event_internal(
    p_pass_definition_id, v_version.id, null,
    'PASS_POLICY_VERSION_CREATED', null, 'draft', p_created_by,
    p_change_summary, jsonb_build_object('version_number', v_next)
  );

  return v_version;
end;
$$;

create or replace function public.approve_premium_pass_policy_version_internal(
  p_policy_version_id uuid,
  p_approved_by text,
  p_reason text default null
)
returns public.premium_pass_policy_versions
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_version public.premium_pass_policy_versions;
begin
  select * into v_version
  from public.premium_pass_policy_versions
  where id = p_policy_version_id
  for update;

  if not found then raise exception 'PREMIUM_PASS_POLICY_VERSION_NOT_FOUND'; end if;
  if v_version.version_status <> 'draft' then raise exception 'PREMIUM_PASS_POLICY_VERSION_NOT_DRAFT'; end if;
  if coalesce(btrim(p_approved_by), '') = '' then raise exception 'APPROVED_BY_REQUIRED'; end if;

  update public.premium_pass_policy_versions
  set version_status = 'approved',
      approved_by = p_approved_by,
      approved_at = clock_timestamp(),
      approval_reason = p_reason
  where id = p_policy_version_id
  returning * into v_version;

  perform public.append_premium_pass_lifecycle_event_internal(
    v_version.pass_definition_id, v_version.id, null,
    'PASS_POLICY_VERSION_APPROVED', 'draft', 'approved',
    p_approved_by, p_reason,
    jsonb_build_object('version_number', v_version.version_number)
  );

  return v_version;
end;
$$;

create or replace function public.evaluate_premium_pass_readiness_internal(
  p_pass_definition_id uuid,
  p_policy_version_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_pass public.premium_pass_definitions;
  v_version public.premium_pass_policy_versions;
  v_blockers jsonb := '[]'::jsonb;
  v_component_count bigint;
  v_mismatch_count bigint;
  v_ready boolean;
  v_report jsonb;
begin
  select * into v_pass from public.premium_pass_definitions where id = p_pass_definition_id;
  if not found then raise exception 'PREMIUM_PASS_DEFINITION_NOT_FOUND'; end if;

  select * into v_version
  from public.premium_pass_policy_versions
  where id = p_policy_version_id
    and pass_definition_id = p_pass_definition_id;

  if not found then
    v_blockers := v_blockers || '"POLICY_VERSION_NOT_FOUND"'::jsonb;
  elsif v_version.version_status <> 'approved' then
    v_blockers := v_blockers || '"POLICY_VERSION_NOT_APPROVED"'::jsonb;
  end if;

  if not v_pass.enabled then
    v_blockers := v_blockers || '"PASS_DEFINITION_DISABLED"'::jsonb;
  end if;

  select count(*) into v_component_count
  from public.commercial_product_pass_components
  where pass_definition_id = p_pass_definition_id
    and component_status = 'certified';

  if v_component_count = 0 then
    v_blockers := v_blockers || '"NO_CERTIFIED_PRODUCT_COMPONENTS"'::jsonb;
  end if;

  select count(*) into v_mismatch_count
  from public.commercial_product_pass_components c
  join public.commercial_products p on p.id = c.product_id
  where c.pass_definition_id = p_pass_definition_id
    and c.quantity <> p.passes;

  if v_mismatch_count > 0 then
    v_blockers := v_blockers || '"PRODUCT_PASS_QUANTITY_MISMATCH"'::jsonb;
  end if;

  v_ready := jsonb_array_length(v_blockers) = 0;
  v_report := jsonb_build_object(
    'ready', v_ready,
    'status', case when v_ready then 'ready' else 'blocked' end,
    'blockers', v_blockers,
    'pass_definition_id', p_pass_definition_id,
    'policy_version_id', p_policy_version_id,
    'certified_product_component_count', v_component_count,
    'quantity_mismatch_count', v_mismatch_count,
    'evaluated_at', clock_timestamp()
  );

  update public.premium_pass_runtime_states
  set readiness_status = case when v_ready then 'ready' else 'blocked' end,
      readiness_report = v_report,
      evaluated_at = clock_timestamp(),
      updated_at = clock_timestamp()
  where pass_definition_id = p_pass_definition_id;

  perform public.append_premium_pass_lifecycle_event_internal(
    p_pass_definition_id, p_policy_version_id, null,
    'PASS_READINESS_EVALUATED', null,
    case when v_ready then 'ready' else 'blocked' end,
    'PREMIUM_PASS_READINESS_ENGINE', null, v_report
  );

  return v_report;
end;
$$;

create or replace function public.request_premium_pass_activation_internal(
  p_pass_definition_id uuid,
  p_policy_version_id uuid,
  p_requested_by text,
  p_request_reason text default null,
  p_metadata jsonb default '{}'::jsonb
)
returns public.premium_pass_activation_requests
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_report jsonb;
  v_request public.premium_pass_activation_requests;
  v_previous text;
begin
  v_report := public.evaluate_premium_pass_readiness_internal(
    p_pass_definition_id, p_policy_version_id
  );

  select runtime_state into v_previous
  from public.premium_pass_runtime_states
  where pass_definition_id = p_pass_definition_id
  for update;

  insert into public.premium_pass_activation_requests (
    pass_definition_id, policy_version_id,
    request_status, readiness_status, readiness_report,
    request_reason, requested_by, metadata
  ) values (
    p_pass_definition_id, p_policy_version_id,
    'pending', v_report->>'status', v_report,
    p_request_reason, p_requested_by, coalesce(p_metadata, '{}'::jsonb)
  ) returning * into v_request;

  update public.premium_pass_runtime_states
  set runtime_state = 'activation_pending',
      activation_request_id = v_request.id,
      active_policy_version_id = p_policy_version_id,
      readiness_status = v_report->>'status',
      readiness_report = v_report,
      state_reason = 'PREMIUM_PASS_ACTIVATION_REQUESTED',
      updated_at = clock_timestamp()
  where pass_definition_id = p_pass_definition_id;

  perform public.append_premium_pass_lifecycle_event_internal(
    p_pass_definition_id, p_policy_version_id, v_request.id,
    'PASS_ACTIVATION_REQUESTED', v_previous, 'activation_pending',
    p_requested_by, p_request_reason, v_report
  );

  return v_request;
end;
$$;

create or replace function public.approve_premium_pass_activation_internal(
  p_activation_request_id uuid,
  p_approved_by text,
  p_review_reason text default null
)
returns public.premium_pass_runtime_states
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_request public.premium_pass_activation_requests;
  v_runtime public.premium_pass_runtime_states;
begin
  select * into v_request
  from public.premium_pass_activation_requests
  where id = p_activation_request_id
  for update;

  if not found then raise exception 'PREMIUM_PASS_ACTIVATION_REQUEST_NOT_FOUND'; end if;
  if v_request.request_status <> 'pending' then raise exception 'PREMIUM_PASS_ACTIVATION_REQUEST_NOT_PENDING'; end if;

  if v_request.readiness_status <> 'ready' then
    update public.premium_pass_runtime_states
    set runtime_state = 'blocked',
        state_reason = 'PREMIUM_PASS_ACTIVATION_READINESS_BLOCKED',
        updated_at = clock_timestamp()
    where pass_definition_id = v_request.pass_definition_id
    returning * into v_runtime;

    return v_runtime;
  end if;

  update public.premium_pass_activation_requests
  set request_status = 'approved', reviewed_by = p_approved_by,
      reviewed_at = clock_timestamp(), review_reason = p_review_reason
  where id = p_activation_request_id;

  update public.premium_pass_definitions
  set catalog_status = 'approved', enabled = true,
      updated_at = clock_timestamp()
  where id = v_request.pass_definition_id;

  update public.premium_pass_runtime_states
  set runtime_state = 'active', readiness_status = 'ready',
      active_policy_version_id = v_request.policy_version_id,
      activation_request_id = v_request.id,
      state_reason = 'PREMIUM_PASS_ACTIVATION_APPROVED',
      activated_at = clock_timestamp(), updated_at = clock_timestamp()
  where pass_definition_id = v_request.pass_definition_id
  returning * into v_runtime;

  perform public.append_premium_pass_lifecycle_event_internal(
    v_request.pass_definition_id, v_request.policy_version_id, v_request.id,
    'PASS_ACTIVATION_APPROVED', 'activation_pending', 'active',
    p_approved_by, p_review_reason, v_request.readiness_report
  );

  return v_runtime;
end;
$$;

create or replace function public.reject_premium_pass_activation_internal(
  p_activation_request_id uuid,
  p_rejected_by text,
  p_review_reason text default null
)
returns public.premium_pass_activation_requests
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_request public.premium_pass_activation_requests;
begin
  select * into v_request
  from public.premium_pass_activation_requests
  where id = p_activation_request_id
  for update;

  if not found then raise exception 'PREMIUM_PASS_ACTIVATION_REQUEST_NOT_FOUND'; end if;
  if v_request.request_status <> 'pending' then raise exception 'PREMIUM_PASS_ACTIVATION_REQUEST_NOT_PENDING'; end if;

  update public.premium_pass_activation_requests
  set request_status = 'rejected', reviewed_by = p_rejected_by,
      reviewed_at = clock_timestamp(), review_reason = p_review_reason
  where id = p_activation_request_id
  returning * into v_request;

  update public.premium_pass_runtime_states
  set runtime_state = 'inactive',
      state_reason = 'PREMIUM_PASS_ACTIVATION_EXPLICITLY_REJECTED',
      updated_at = clock_timestamp()
  where pass_definition_id = v_request.pass_definition_id;

  perform public.append_premium_pass_lifecycle_event_internal(
    v_request.pass_definition_id, v_request.policy_version_id, v_request.id,
    'PASS_ACTIVATION_REJECTED', 'activation_pending', 'inactive',
    p_rejected_by, p_review_reason, v_request.readiness_report
  );

  return v_request;
end;
$$;

create or replace function public.get_premium_pass_catalog_internal()
returns table (
  pass_definition_id uuid,
  pass_code text,
  display_name text,
  catalog_status text,
  enabled boolean,
  public boolean,
  runtime_state text,
  readiness_status text,
  active_policy_version_id uuid,
  product_component_count bigint,
  total_catalog_passes bigint
)
language sql
security definer
set search_path = public, pg_temp
as $$
  select
    d.id, d.pass_code, d.display_name, d.catalog_status,
    d.enabled, d.public,
    s.runtime_state, s.readiness_status, s.active_policy_version_id,
    count(c.id), coalesce(sum(c.quantity), 0)
  from public.premium_pass_definitions d
  join public.premium_pass_runtime_states s
    on s.pass_definition_id = d.id
  left join public.commercial_product_pass_components c
    on c.pass_definition_id = d.id
   and c.component_status <> 'retired'
  group by d.id, s.pass_definition_id;
$$;

create or replace function public.get_premium_pass_lifecycle_internal(
  p_pass_definition_id uuid
)
returns setof public.premium_pass_lifecycle_events
language sql
security definer
set search_path = public, pg_temp
as $$
  select *
  from public.premium_pass_lifecycle_events
  where pass_definition_id = p_pass_definition_id
  order by occurred_at, id;
$$;

-- --------------------------------------------------------------------------
-- 7. Seed canonical unit and product compositions
-- --------------------------------------------------------------------------

insert into public.premium_pass_definitions (
  pass_code, display_name, description,
  unit_scale, ledger_unit_code, wallet_unit_code,
  catalog_status, enabled, public, transferable,
  expires_by_default, configuration, metadata
) values (
  'PREMIUM_PASS',
  'Premium Pass',
  'Unità economica interna unica della piattaforma FantaGol.',
  1,
  'PREMIUM_PASS',
  'PREMIUM_PASS',
  'draft',
  false,
  false,
  false,
  false,
  jsonb_build_object(
    'single_wallet', true,
    'ledger_source_of_truth', true,
    'wallet_is_projection', true,
    'fractional_units_allowed', false
  ),
  jsonb_build_object('introduced_by_migration', 112)
)
on conflict (pass_code) do nothing;

insert into public.premium_pass_runtime_states (
  pass_definition_id, runtime_state, readiness_status,
  readiness_report, state_reason
)
select id, 'inactive', 'not_evaluated', '{}'::jsonb,
       'PREMIUM_PASS_CATALOG_FOUNDATION_INITIALIZED'
from public.premium_pass_definitions
where pass_code = 'PREMIUM_PASS'
on conflict (pass_definition_id) do nothing;

insert into public.commercial_product_pass_components (
  product_id, pass_definition_id, quantity,
  component_status, configuration, metadata
)
select
  p.id,
  d.id,
  p.passes,
  'certified',
  jsonb_build_object(
    'source_column', 'commercial_products.passes',
    'fulfillment_mode', 'pass_credit'
  ),
  jsonb_build_object(
    'introduced_by_migration', 112,
    'preserves_migration_102_contract', true
  )
from public.commercial_products p
cross join public.premium_pass_definitions d
where d.pass_code = 'PREMIUM_PASS'
  and p.passes > 0
on conflict (product_id, pass_definition_id) do update
set quantity = excluded.quantity,
    component_status = 'certified',
    configuration = excluded.configuration,
    metadata = public.commercial_product_pass_components.metadata || excluded.metadata,
    updated_at = clock_timestamp();

insert into public.premium_pass_lifecycle_events (
  pass_definition_id, event_type, next_state,
  actor, reason, payload
)
select
  d.id,
  'PASS_DEFINITION_REGISTERED',
  'inactive',
  'MIGRATION_112',
  'Canonical Premium Pass catalog foundation initialized',
  jsonb_build_object(
    'pass_code', d.pass_code,
    'product_component_count', (
      select count(*)
      from public.commercial_product_pass_components c
      where c.pass_definition_id = d.id
    )
  )
from public.premium_pass_definitions d
where d.pass_code = 'PREMIUM_PASS'
  and not exists (
    select 1
    from public.premium_pass_lifecycle_events e
    where e.pass_definition_id = d.id
      and e.event_type = 'PASS_DEFINITION_REGISTERED'
  );

-- --------------------------------------------------------------------------
-- 8. RLS and privileges
-- --------------------------------------------------------------------------

alter table public.premium_pass_definitions enable row level security;
alter table public.premium_pass_policy_versions enable row level security;
alter table public.commercial_product_pass_components enable row level security;
alter table public.premium_pass_activation_requests enable row level security;
alter table public.premium_pass_runtime_states enable row level security;
alter table public.premium_pass_lifecycle_events enable row level security;

revoke all on table public.premium_pass_definitions from public, anon, authenticated;
revoke all on table public.premium_pass_policy_versions from public, anon, authenticated;
revoke all on table public.commercial_product_pass_components from public, anon, authenticated;
revoke all on table public.premium_pass_activation_requests from public, anon, authenticated;
revoke all on table public.premium_pass_runtime_states from public, anon, authenticated;
revoke all on table public.premium_pass_lifecycle_events from public, anon, authenticated;

grant select, insert, update, delete on table public.premium_pass_definitions to service_role;
grant select, insert, update, delete on table public.premium_pass_policy_versions to service_role;
grant select, insert, update, delete on table public.commercial_product_pass_components to service_role;
grant select, insert, update, delete on table public.premium_pass_activation_requests to service_role;
grant select, insert, update, delete on table public.premium_pass_runtime_states to service_role;
grant select, insert, update, delete on table public.premium_pass_lifecycle_events to service_role;

revoke all on function public.create_premium_pass_policy_version_internal(uuid,text,text,jsonb,jsonb) from public, anon, authenticated;
revoke all on function public.approve_premium_pass_policy_version_internal(uuid,text,text) from public, anon, authenticated;
revoke all on function public.evaluate_premium_pass_readiness_internal(uuid,uuid) from public, anon, authenticated;
revoke all on function public.request_premium_pass_activation_internal(uuid,uuid,text,text,jsonb) from public, anon, authenticated;
revoke all on function public.approve_premium_pass_activation_internal(uuid,text,text) from public, anon, authenticated;
revoke all on function public.reject_premium_pass_activation_internal(uuid,text,text) from public, anon, authenticated;
revoke all on function public.get_premium_pass_catalog_internal() from public, anon, authenticated;
revoke all on function public.get_premium_pass_lifecycle_internal(uuid) from public, anon, authenticated;

grant execute on function public.create_premium_pass_policy_version_internal(uuid,text,text,jsonb,jsonb) to service_role;
grant execute on function public.approve_premium_pass_policy_version_internal(uuid,text,text) to service_role;
grant execute on function public.evaluate_premium_pass_readiness_internal(uuid,uuid) to service_role;
grant execute on function public.request_premium_pass_activation_internal(uuid,uuid,text,text,jsonb) to service_role;
grant execute on function public.approve_premium_pass_activation_internal(uuid,text,text) to service_role;
grant execute on function public.reject_premium_pass_activation_internal(uuid,text,text) to service_role;
grant execute on function public.get_premium_pass_catalog_internal() to service_role;
grant execute on function public.get_premium_pass_lifecycle_internal(uuid) to service_role;

-- --------------------------------------------------------------------------
-- 9. Certification assertions
-- --------------------------------------------------------------------------

do $$
declare
  v_definition_count bigint;
  v_runtime_count bigint;
  v_component_count bigint;
  v_product_count bigint;
  v_mismatch_count bigint;
  v_enabled_count bigint;
  v_public_count bigint;
  v_version_count bigint;
  v_request_count bigint;
begin
  select count(*) into v_definition_count
  from public.premium_pass_definitions
  where pass_code = 'PREMIUM_PASS';

  select count(*) into v_runtime_count
  from public.premium_pass_runtime_states;

  select count(*) into v_component_count
  from public.commercial_product_pass_components
  where component_status = 'certified';

  select count(*) into v_product_count
  from public.commercial_products
  where passes > 0;

  select count(*) into v_mismatch_count
  from public.commercial_product_pass_components c
  join public.commercial_products p on p.id = c.product_id
  where c.quantity <> p.passes;

  select count(*) into v_enabled_count
  from public.premium_pass_definitions
  where enabled;

  select count(*) into v_public_count
  from public.premium_pass_definitions
  where public;

  select count(*) into v_version_count
  from public.premium_pass_policy_versions;

  select count(*) into v_request_count
  from public.premium_pass_activation_requests;

  if v_definition_count <> 1 then
    raise exception 'MIGRATION_112_PASS_DEFINITION_ASSERTION_FAILED count=%', v_definition_count;
  end if;

  if v_runtime_count <> 1 then
    raise exception 'MIGRATION_112_RUNTIME_ASSERTION_FAILED count=%', v_runtime_count;
  end if;

  if v_component_count <> v_product_count or v_mismatch_count <> 0 then
    raise exception
      'MIGRATION_112_PRODUCT_COMPONENT_ASSERTION_FAILED components=%, products=%, mismatches=%',
      v_component_count, v_product_count, v_mismatch_count;
  end if;

  if v_enabled_count <> 0 or v_public_count <> 0
     or v_version_count <> 0 or v_request_count <> 0 then
    raise exception
      'MIGRATION_112_PASSIVE_STATE_ASSERTION_FAILED enabled=%, public=%, versions=%, requests=%',
      v_enabled_count, v_public_count, v_version_count, v_request_count;
  end if;

  raise notice
    'MIGRATION_112_CERTIFIED pass_definition_count=%, runtime_count=%, product_component_count=%, version_count=%, request_count=%, enabled_count=%, public_count=%',
    v_definition_count, v_runtime_count, v_component_count,
    v_version_count, v_request_count, v_enabled_count, v_public_count;
end;
$$;

commit;
