-- =============================================================================
-- FANTAGOL
-- Migration: 111_commercial_product_catalog_governance_foundation.sql
-- Milestone: Commercial Platform - Existing Product Catalog Governance
--
-- Purpose:
--   - Extend the commercial_products catalog created by migration 102
--   - Preserve existing purchase-engine contracts and seeded hidden pass packs
--   - Add immutable product versions, provider listings, campaign bindings,
--     readiness, explicit activation governance and append-only lifecycle events
--
-- Safety guarantees:
--   - Existing STARTER/STANDARD/PRO/MEGA products are preserved
--   - Existing passes, price_minor, currency and purchase RPC contracts remain valid
--   - No product is enabled or made public
--   - No provider listing or campaign binding is enabled
--   - No purchase, reward, ledger or wallet mutation is generated
-- =============================================================================

begin;

-- =============================================================================
-- 0. DEPENDENCY AND LEGACY CONTRACT ASSERTIONS
-- =============================================================================

do $$
begin
  if to_regclass('public.commercial_products') is null
     or to_regclass('public.commercial_purchases') is null
     or to_regclass('public.commercial_providers') is null
     or to_regclass('public.commercial_provider_runtime_states') is null
     or to_regclass('public.reward_campaigns') is null
     or to_regclass('public.commercial_campaign_runtime_states') is null then
    raise exception using
      errcode = 'P0001',
      message = 'MIGRATION_111_REQUIRES_PURCHASE_PROVIDER_AND_CAMPAIGN_FOUNDATIONS';
  end if;

  if not exists (
    select 1 from information_schema.columns
    where table_schema = 'public'
      and table_name = 'commercial_products'
      and column_name = 'passes'
  ) or not exists (
    select 1 from information_schema.columns
    where table_schema = 'public'
      and table_name = 'commercial_products'
      and column_name = 'price_minor'
  ) or not exists (
    select 1 from information_schema.columns
    where table_schema = 'public'
      and table_name = 'commercial_products'
      and column_name = 'currency'
  ) then
    raise exception 'MIGRATION_111_LEGACY_PRODUCT_CONTRACT_NOT_FOUND';
  end if;
end;
$$;

-- =============================================================================
-- 1. NON-DESTRUCTIVE GOVERNANCE EXTENSION OF EXISTING CATALOG
-- =============================================================================

alter table public.commercial_products
  add column if not exists fulfillment_mode text,
  add column if not exists catalog_status text,
  add column if not exists test_only boolean,
  add column if not exists entitlement_specification jsonb,
  add column if not exists configuration jsonb;

update public.commercial_products
set
  fulfillment_mode = coalesce(fulfillment_mode, 'pass_credit'),
  catalog_status = coalesce(
    catalog_status,
    case when enabled then 'approved' else 'draft' end
  ),
  test_only = coalesce(test_only, true),
  entitlement_specification = coalesce(
    entitlement_specification,
    jsonb_build_object('pass_quantity', passes)
  ),
  configuration = coalesce(configuration, '{}'::jsonb)
where fulfillment_mode is null
   or catalog_status is null
   or test_only is null
   or entitlement_specification is null
   or configuration is null;

alter table public.commercial_products
  alter column fulfillment_mode set default 'pass_credit',
  alter column fulfillment_mode set not null,
  alter column catalog_status set default 'draft',
  alter column catalog_status set not null,
  alter column test_only set default true,
  alter column test_only set not null,
  alter column entitlement_specification set default '{}'::jsonb,
  alter column entitlement_specification set not null,
  alter column configuration set default '{}'::jsonb,
  alter column configuration set not null;

do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conrelid = 'public.commercial_products'::regclass
      and conname = 'commercial_products_fulfillment_mode_check'
  ) then
    alter table public.commercial_products
      add constraint commercial_products_fulfillment_mode_check
      check (fulfillment_mode in ('pass_credit'));
  end if;

  if not exists (
    select 1 from pg_constraint
    where conrelid = 'public.commercial_products'::regclass
      and conname = 'commercial_products_catalog_status_check'
  ) then
    alter table public.commercial_products
      add constraint commercial_products_catalog_status_check
      check (catalog_status in ('draft', 'approved', 'suspended', 'retired'));
  end if;

  if not exists (
    select 1 from pg_constraint
    where conrelid = 'public.commercial_products'::regclass
      and conname = 'commercial_products_entitlement_specification_object_check'
  ) then
    alter table public.commercial_products
      add constraint commercial_products_entitlement_specification_object_check
      check (jsonb_typeof(entitlement_specification) = 'object');
  end if;

  if not exists (
    select 1 from pg_constraint
    where conrelid = 'public.commercial_products'::regclass
      and conname = 'commercial_products_configuration_object_check'
  ) then
    alter table public.commercial_products
      add constraint commercial_products_configuration_object_check
      check (jsonb_typeof(configuration) = 'object');
  end if;

  if not exists (
    select 1 from pg_constraint
    where conrelid = 'public.commercial_products'::regclass
      and conname = 'commercial_products_public_requires_enabled_check'
  ) then
    alter table public.commercial_products
      add constraint commercial_products_public_requires_enabled_check
      check (not public or enabled);
  end if;
end;
$$;

create index if not exists commercial_products_governance_idx
  on public.commercial_products (
    catalog_status,
    enabled,
    public,
    test_only,
    product_code
  );

comment on table public.commercial_products is
  'Canonical Premium Pass product catalog created by migration 102 and governed by migration 111. Legacy purchase-engine columns remain authoritative.';

-- =============================================================================
-- 2. IMMUTABLE PRODUCT VERSIONS
-- =============================================================================

create table public.commercial_product_versions (
  id uuid primary key default gen_random_uuid(),
  product_id uuid not null,
  product_code text not null,
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

  constraint commercial_product_versions_product_id_fkey
    foreign key (product_id)
    references public.commercial_products (id)
    on delete restrict,
  constraint commercial_product_versions_unique
    unique (product_id, version_number),
  constraint commercial_product_versions_status_check
    check (version_status in ('draft', 'approved', 'superseded', 'retired')),
  constraint commercial_product_versions_snapshot_object_check
    check (jsonb_typeof(configuration_snapshot) = 'object'),
  constraint commercial_product_versions_hash_check
    check (configuration_hash ~ '^[a-f0-9]{32}$'),
  constraint commercial_product_versions_metadata_object_check
    check (jsonb_typeof(metadata) = 'object'),
  constraint commercial_product_versions_approval_check
    check (
      (version_status = 'draft' and approved_by is null and approved_at is null)
      or
      (version_status <> 'draft' and approved_by is not null and approved_at is not null)
    )
);

create index commercial_product_versions_status_idx
  on public.commercial_product_versions (
    product_id,
    version_status,
    version_number desc
  );

-- =============================================================================
-- 3. PROVIDER LISTINGS
-- =============================================================================

create table public.commercial_product_provider_listings (
  id uuid primary key default gen_random_uuid(),
  product_id uuid not null,
  provider_id uuid not null,
  listing_code text not null,
  external_product_reference text null,
  environment text not null default 'test',
  listing_status text not null default 'draft',
  enabled boolean not null default false,
  configuration jsonb not null default '{}'::jsonb,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default clock_timestamp(),
  updated_at timestamptz not null default clock_timestamp(),

  constraint commercial_product_provider_listings_product_fkey
    foreign key (product_id)
    references public.commercial_products (id)
    on delete restrict,
  constraint commercial_product_provider_listings_provider_fkey
    foreign key (provider_id)
    references public.commercial_providers (id)
    on delete restrict,
  constraint commercial_product_provider_listings_unique
    unique (product_id, provider_id, environment),
  constraint commercial_product_provider_listings_code_check
    check (listing_code = upper(listing_code) and listing_code ~ '^[A-Z][A-Z0-9_]{1,95}$'),
  constraint commercial_product_provider_listings_environment_check
    check (environment in ('test', 'live')),
  constraint commercial_product_provider_listings_status_check
    check (listing_status in ('draft', 'active', 'suspended', 'retired')),
  constraint commercial_product_provider_listings_enabled_check
    check (not enabled or listing_status = 'active'),
  constraint commercial_product_provider_listings_configuration_check
    check (jsonb_typeof(configuration) = 'object'),
  constraint commercial_product_provider_listings_metadata_check
    check (jsonb_typeof(metadata) = 'object')
);

create index commercial_product_provider_listings_lookup_idx
  on public.commercial_product_provider_listings (
    product_id,
    environment,
    listing_status,
    enabled
  );

-- =============================================================================
-- 4. CAMPAIGN ↔ PRODUCT BINDINGS
-- =============================================================================

create table public.commercial_campaign_product_bindings (
  id uuid primary key default gen_random_uuid(),
  campaign_id uuid not null,
  product_id uuid not null,
  binding_role text not null,
  enabled boolean not null default false,
  valid_from timestamptz null,
  valid_until timestamptz null,
  configuration jsonb not null default '{}'::jsonb,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default clock_timestamp(),
  updated_at timestamptz not null default clock_timestamp(),

  constraint commercial_campaign_product_bindings_campaign_fkey
    foreign key (campaign_id)
    references public.reward_campaigns (id)
    on delete restrict,
  constraint commercial_campaign_product_bindings_product_fkey
    foreign key (product_id)
    references public.commercial_products (id)
    on delete restrict,
  constraint commercial_campaign_product_bindings_unique
    unique (campaign_id, product_id, binding_role),
  constraint commercial_campaign_product_bindings_role_check
    check (binding_role in ('promotion', 'distribution', 'discount', 'eligibility')),
  constraint commercial_campaign_product_bindings_validity_check
    check (valid_until is null or valid_from is null or valid_until > valid_from),
  constraint commercial_campaign_product_bindings_configuration_check
    check (jsonb_typeof(configuration) = 'object'),
  constraint commercial_campaign_product_bindings_metadata_check
    check (jsonb_typeof(metadata) = 'object')
);

create index commercial_campaign_product_bindings_lookup_idx
  on public.commercial_campaign_product_bindings (
    campaign_id,
    product_id,
    enabled
  );

-- =============================================================================
-- 5. ACTIVATION REQUESTS
-- =============================================================================

create table public.commercial_product_activation_requests (
  id uuid primary key default gen_random_uuid(),
  product_id uuid not null,
  product_version_id uuid not null,
  request_status text not null default 'pending',
  requested_environment text not null default 'test',
  requested_public boolean not null default false,
  readiness_status text not null default 'not_evaluated',
  readiness_report jsonb not null default '{}'::jsonb,
  requested_by text not null,
  request_reason text null,
  reviewed_by text null,
  review_reason text null,
  requested_at timestamptz not null default clock_timestamp(),
  reviewed_at timestamptz null,
  metadata jsonb not null default '{}'::jsonb,

  constraint commercial_product_activation_requests_product_fkey
    foreign key (product_id)
    references public.commercial_products (id)
    on delete restrict,
  constraint commercial_product_activation_requests_version_fkey
    foreign key (product_version_id)
    references public.commercial_product_versions (id)
    on delete restrict,
  constraint commercial_product_activation_requests_status_check
    check (request_status in ('pending', 'approved', 'rejected', 'cancelled')),
  constraint commercial_product_activation_requests_environment_check
    check (requested_environment in ('test', 'live')),
  constraint commercial_product_activation_requests_public_check
    check (not requested_public or requested_environment = 'live'),
  constraint commercial_product_activation_requests_readiness_check
    check (readiness_status in ('not_evaluated', 'ready', 'blocked')),
  constraint commercial_product_activation_requests_report_check
    check (jsonb_typeof(readiness_report) = 'object'),
  constraint commercial_product_activation_requests_metadata_check
    check (jsonb_typeof(metadata) = 'object'),
  constraint commercial_product_activation_requests_review_check
    check (
      (request_status = 'pending' and reviewed_by is null and reviewed_at is null)
      or
      (request_status <> 'pending' and reviewed_by is not null and reviewed_at is not null)
    )
);

create unique index commercial_product_activation_requests_pending_uidx
  on public.commercial_product_activation_requests (product_id)
  where request_status = 'pending';

-- =============================================================================
-- 6. RUNTIME STATE PROJECTION
-- =============================================================================

create table public.commercial_product_runtime_states (
  product_id uuid primary key,
  product_code text not null unique,
  runtime_state text not null default 'inactive',
  readiness_status text not null default 'not_evaluated',
  active_version_id uuid null,
  activation_request_id uuid null,
  active_environment text null,
  active_public boolean not null default false,
  state_reason text null,
  readiness_report jsonb not null default '{}'::jsonb,
  activated_at timestamptz null,
  suspended_at timestamptz null,
  retired_at timestamptz null,
  updated_at timestamptz not null default clock_timestamp(),

  constraint commercial_product_runtime_states_product_fkey
    foreign key (product_id)
    references public.commercial_products (id)
    on delete restrict,
  constraint commercial_product_runtime_states_version_fkey
    foreign key (active_version_id)
    references public.commercial_product_versions (id)
    on delete restrict,
  constraint commercial_product_runtime_states_request_fkey
    foreign key (activation_request_id)
    references public.commercial_product_activation_requests (id)
    on delete restrict,
  constraint commercial_product_runtime_states_state_check
    check (runtime_state in ('inactive', 'activation_pending', 'blocked', 'active_test', 'active_live', 'suspended', 'retired')),
  constraint commercial_product_runtime_states_readiness_check
    check (readiness_status in ('not_evaluated', 'ready', 'blocked')),
  constraint commercial_product_runtime_states_environment_check
    check (active_environment is null or active_environment in ('test', 'live')),
  constraint commercial_product_runtime_states_report_check
    check (jsonb_typeof(readiness_report) = 'object'),
  constraint commercial_product_runtime_states_public_check
    check (not active_public or runtime_state = 'active_live')
);

-- Seed runtime coverage for the existing catalog without activating anything.
insert into public.commercial_product_runtime_states (
  product_id,
  product_code,
  runtime_state,
  readiness_status,
  state_reason
)
select
  p.id,
  p.product_code,
  'inactive',
  'not_evaluated',
  'MIGRATION_111_RUNTIME_BASELINE'
from public.commercial_products p
on conflict (product_id) do nothing;

-- =============================================================================
-- 7. APPEND-ONLY LIFECYCLE EVENTS
-- =============================================================================

create table public.commercial_product_lifecycle_events (
  id uuid primary key default gen_random_uuid(),
  product_id uuid not null,
  product_version_id uuid null,
  activation_request_id uuid null,
  event_type text not null,
  previous_state text null,
  next_state text null,
  event_reason text null,
  actor text not null,
  correlation_id uuid null,
  causation_id uuid null,
  payload jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default clock_timestamp(),

  constraint commercial_product_lifecycle_events_product_fkey
    foreign key (product_id)
    references public.commercial_products (id)
    on delete restrict,
  constraint commercial_product_lifecycle_events_version_fkey
    foreign key (product_version_id)
    references public.commercial_product_versions (id)
    on delete restrict,
  constraint commercial_product_lifecycle_events_request_fkey
    foreign key (activation_request_id)
    references public.commercial_product_activation_requests (id)
    on delete restrict,
  constraint commercial_product_lifecycle_events_payload_check
    check (jsonb_typeof(payload) = 'object')
);

create index commercial_product_lifecycle_events_timeline_idx
  on public.commercial_product_lifecycle_events (
    product_id,
    created_at,
    id
  );

-- =============================================================================
-- 8. INTERNAL MUTATION GUARDS
-- =============================================================================

create or replace function public.protect_commercial_product_version_internal()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if current_setting('fantagol.allow_commercial_product_version_mutation', true) <> 'on' then
    raise exception 'COMMERCIAL_PRODUCT_VERSION_IMMUTABLE';
  end if;
  if tg_op = 'DELETE' then return old; end if;
  return new;
end;
$$;

create or replace function public.protect_commercial_product_lifecycle_event_internal()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if current_setting('fantagol.allow_commercial_product_event_mutation', true) <> 'on' then
    raise exception 'COMMERCIAL_PRODUCT_LIFECYCLE_EVENT_APPEND_ONLY';
  end if;
  if tg_op = 'DELETE' then return old; end if;
  return new;
end;
$$;

create trigger commercial_product_versions_guard
before update or delete on public.commercial_product_versions
for each row execute function public.protect_commercial_product_version_internal();

create trigger commercial_product_lifecycle_events_guard
before update or delete on public.commercial_product_lifecycle_events
for each row execute function public.protect_commercial_product_lifecycle_event_internal();

-- =============================================================================
-- 9. APPEND EVENT
-- =============================================================================

create or replace function public.append_commercial_product_lifecycle_event_internal(
  p_product_id uuid,
  p_product_version_id uuid,
  p_activation_request_id uuid,
  p_event_type text,
  p_previous_state text,
  p_next_state text,
  p_event_reason text,
  p_actor text,
  p_correlation_id uuid default null,
  p_causation_id uuid default null,
  p_payload jsonb default '{}'::jsonb
)
returns public.commercial_product_lifecycle_events
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_event public.commercial_product_lifecycle_events;
begin
  insert into public.commercial_product_lifecycle_events (
    product_id,
    product_version_id,
    activation_request_id,
    event_type,
    previous_state,
    next_state,
    event_reason,
    actor,
    correlation_id,
    causation_id,
    payload
  ) values (
    p_product_id,
    p_product_version_id,
    p_activation_request_id,
    upper(btrim(p_event_type)),
    p_previous_state,
    p_next_state,
    nullif(btrim(p_event_reason), ''),
    btrim(p_actor),
    p_correlation_id,
    p_causation_id,
    coalesce(p_payload, '{}'::jsonb)
  ) returning * into v_event;

  return v_event;
end;
$$;

-- =============================================================================
-- 10. PRODUCT VERSION GOVERNANCE
-- =============================================================================

create or replace function public.create_commercial_product_version_internal(
  p_product_id uuid,
  p_created_by text,
  p_change_summary text default null,
  p_metadata jsonb default '{}'::jsonb,
  p_correlation_id uuid default null,
  p_causation_id uuid default null
)
returns public.commercial_product_versions
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_product public.commercial_products;
  v_version_number integer;
  v_snapshot jsonb;
  v_version public.commercial_product_versions;
begin
  select * into v_product
  from public.commercial_products
  where id = p_product_id
  for update;

  if not found then raise exception 'COMMERCIAL_PRODUCT_NOT_FOUND'; end if;

  select coalesce(max(version_number), 0) + 1
  into v_version_number
  from public.commercial_product_versions
  where product_id = p_product_id;

  v_snapshot := jsonb_build_object(
    'product_code', v_product.product_code,
    'title', v_product.title,
    'description', v_product.description,
    'product_type', v_product.product_type,
    'passes', v_product.passes,
    'price_minor', v_product.price_minor,
    'currency', v_product.currency,
    'sort_order', v_product.sort_order,
    'valid_from', v_product.valid_from,
    'valid_to', v_product.valid_to,
    'fulfillment_mode', v_product.fulfillment_mode,
    'catalog_status', v_product.catalog_status,
    'test_only', v_product.test_only,
    'entitlement_specification', v_product.entitlement_specification,
    'configuration', v_product.configuration,
    'metadata', v_product.metadata,
    'registry_version', v_product.version
  );

  insert into public.commercial_product_versions (
    product_id, product_code, version_number, version_status,
    configuration_snapshot, configuration_hash, change_summary,
    created_by, metadata
  ) values (
    v_product.id, v_product.product_code, v_version_number, 'draft',
    v_snapshot, md5(v_snapshot::text), nullif(btrim(p_change_summary), ''),
    btrim(p_created_by), coalesce(p_metadata, '{}'::jsonb)
  ) returning * into v_version;

  perform public.append_commercial_product_lifecycle_event_internal(
    v_product.id, v_version.id, null,
    'PRODUCT_VERSION_CREATED', null, 'draft', p_change_summary,
    p_created_by, p_correlation_id, p_causation_id,
    jsonb_build_object('version_number', v_version.version_number)
  );

  return v_version;
end;
$$;

create or replace function public.approve_commercial_product_version_internal(
  p_product_version_id uuid,
  p_approved_by text,
  p_reason text default null,
  p_correlation_id uuid default null,
  p_causation_id uuid default null
)
returns public.commercial_product_versions
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_version public.commercial_product_versions;
begin
  select * into v_version
  from public.commercial_product_versions
  where id = p_product_version_id
  for update;

  if not found then raise exception 'COMMERCIAL_PRODUCT_VERSION_NOT_FOUND'; end if;
  if v_version.version_status <> 'draft' then raise exception 'COMMERCIAL_PRODUCT_VERSION_NOT_DRAFT'; end if;

  perform set_config('fantagol.allow_commercial_product_version_mutation', 'on', true);

  update public.commercial_product_versions
  set version_status = 'approved',
      approved_by = btrim(p_approved_by),
      approved_at = clock_timestamp()
  where id = v_version.id
  returning * into v_version;

  update public.commercial_products
  set catalog_status = 'approved',
      updated_at = clock_timestamp()
  where id = v_version.product_id
    and catalog_status = 'draft';

  perform public.append_commercial_product_lifecycle_event_internal(
    v_version.product_id, v_version.id, null,
    'PRODUCT_VERSION_APPROVED', 'draft', 'approved', p_reason,
    p_approved_by, p_correlation_id, p_causation_id,
    jsonb_build_object('version_number', v_version.version_number)
  );

  return v_version;
end;
$$;

-- =============================================================================
-- 11. DISABLED LISTING AND CAMPAIGN BINDING CREATION
-- =============================================================================

create or replace function public.create_commercial_product_provider_listing_internal(
  p_product_id uuid,
  p_provider_id uuid,
  p_listing_code text,
  p_environment text default 'test',
  p_external_product_reference text default null,
  p_configuration jsonb default '{}'::jsonb,
  p_metadata jsonb default '{}'::jsonb
)
returns public.commercial_product_provider_listings
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_listing public.commercial_product_provider_listings;
begin
  if not exists (select 1 from public.commercial_products where id = p_product_id) then
    raise exception 'COMMERCIAL_PRODUCT_NOT_FOUND';
  end if;
  if not exists (select 1 from public.commercial_providers where id = p_provider_id) then
    raise exception 'COMMERCIAL_PROVIDER_NOT_FOUND';
  end if;

  insert into public.commercial_product_provider_listings (
    product_id, provider_id, listing_code, external_product_reference,
    environment, listing_status, enabled, configuration, metadata
  ) values (
    p_product_id, p_provider_id, upper(btrim(p_listing_code)),
    nullif(btrim(p_external_product_reference), ''), p_environment,
    'draft', false, coalesce(p_configuration, '{}'::jsonb),
    coalesce(p_metadata, '{}'::jsonb)
  ) returning * into v_listing;

  return v_listing;
end;
$$;

create or replace function public.bind_commercial_campaign_product_internal(
  p_campaign_id uuid,
  p_product_id uuid,
  p_binding_role text,
  p_valid_from timestamptz default null,
  p_valid_until timestamptz default null,
  p_configuration jsonb default '{}'::jsonb,
  p_metadata jsonb default '{}'::jsonb
)
returns public.commercial_campaign_product_bindings
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_binding public.commercial_campaign_product_bindings;
begin
  if not exists (select 1 from public.reward_campaigns where id = p_campaign_id) then
    raise exception 'REWARD_CAMPAIGN_NOT_FOUND';
  end if;
  if not exists (select 1 from public.commercial_products where id = p_product_id) then
    raise exception 'COMMERCIAL_PRODUCT_NOT_FOUND';
  end if;

  insert into public.commercial_campaign_product_bindings (
    campaign_id, product_id, binding_role, enabled,
    valid_from, valid_until, configuration, metadata
  ) values (
    p_campaign_id, p_product_id, p_binding_role, false,
    p_valid_from, p_valid_until,
    coalesce(p_configuration, '{}'::jsonb),
    coalesce(p_metadata, '{}'::jsonb)
  ) returning * into v_binding;

  return v_binding;
end;
$$;

-- =============================================================================
-- 12. READINESS
-- =============================================================================

create or replace function public.evaluate_commercial_product_readiness_internal(
  p_product_id uuid,
  p_product_version_id uuid,
  p_requested_environment text default 'test',
  p_requested_public boolean default false
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_product public.commercial_products;
  v_version public.commercial_product_versions;
  v_blockers jsonb := '[]'::jsonb;
  v_listing_count bigint := 0;
  v_report jsonb;
begin
  select * into v_product
  from public.commercial_products
  where id = p_product_id;

  if not found then raise exception 'COMMERCIAL_PRODUCT_NOT_FOUND'; end if;

  select * into v_version
  from public.commercial_product_versions
  where id = p_product_version_id
    and product_id = p_product_id;

  if not found then
    v_blockers := v_blockers || '"PRODUCT_VERSION_NOT_FOUND"'::jsonb;
  elsif v_version.version_status <> 'approved' then
    v_blockers := v_blockers || '"PRODUCT_VERSION_NOT_APPROVED"'::jsonb;
  end if;

  if v_product.catalog_status <> 'approved' then
    v_blockers := v_blockers || '"PRODUCT_NOT_APPROVED"'::jsonb;
  end if;

  if p_requested_environment not in ('test', 'live') then
    v_blockers := v_blockers || '"INVALID_REQUESTED_ENVIRONMENT"'::jsonb;
  end if;

  if p_requested_environment = 'live' and v_product.test_only then
    v_blockers := v_blockers || '"PRODUCT_TEST_ONLY"'::jsonb;
  end if;

  if p_requested_public and p_requested_environment <> 'live' then
    v_blockers := v_blockers || '"PUBLIC_PRODUCT_REQUIRES_LIVE_ENVIRONMENT"'::jsonb;
  end if;

  if v_product.passes <= 0 then
    v_blockers := v_blockers || '"PASS_QUANTITY_INVALID"'::jsonb;
  end if;

  if v_product.price_minor <= 0 or v_product.currency !~ '^[A-Z]{3}$' then
    v_blockers := v_blockers || '"LEGACY_PRICE_INVALID"'::jsonb;
  end if;

  select count(*) into v_listing_count
  from public.commercial_product_provider_listings l
  join public.commercial_providers p on p.id = l.provider_id
  join public.commercial_provider_runtime_states s on s.provider_id = p.id
  where l.product_id = p_product_id
    and l.environment = p_requested_environment
    and l.listing_status = 'active'
    and l.enabled
    and p.enabled
    and (
      (p_requested_environment = 'test' and s.runtime_state in ('active_test', 'active_live'))
      or
      (p_requested_environment = 'live' and s.runtime_state = 'active_live')
    );

  if v_listing_count = 0 then
    v_blockers := v_blockers || '"ACTIVE_PROVIDER_LISTING_REQUIRED"'::jsonb;
  end if;

  v_report := jsonb_build_object(
    'ready', jsonb_array_length(v_blockers) = 0,
    'status', case when jsonb_array_length(v_blockers) = 0 then 'ready' else 'blocked' end,
    'product_id', p_product_id,
    'product_code', v_product.product_code,
    'product_version_id', p_product_version_id,
    'requested_environment', p_requested_environment,
    'requested_public', p_requested_public,
    'active_provider_listing_count', v_listing_count,
    'blockers', v_blockers,
    'evaluated_at', clock_timestamp()
  );

  update public.commercial_product_runtime_states
  set readiness_status = v_report->>'status',
      readiness_report = v_report,
      state_reason = case when (v_report->>'ready')::boolean then 'PRODUCT_READY' else 'PRODUCT_READINESS_BLOCKED' end,
      updated_at = clock_timestamp()
  where product_id = p_product_id;

  return v_report;
end;
$$;

-- =============================================================================
-- 13. ACTIVATION REQUEST / APPROVAL / REJECTION
-- =============================================================================

create or replace function public.request_commercial_product_activation_internal(
  p_product_id uuid,
  p_product_version_id uuid,
  p_requested_by text,
  p_requested_environment text default 'test',
  p_requested_public boolean default false,
  p_request_reason text default null,
  p_metadata jsonb default '{}'::jsonb,
  p_correlation_id uuid default null,
  p_causation_id uuid default null
)
returns public.commercial_product_activation_requests
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_readiness jsonb;
  v_request public.commercial_product_activation_requests;
  v_previous_state text;
begin
  select runtime_state into v_previous_state
  from public.commercial_product_runtime_states
  where product_id = p_product_id
  for update;

  if not found then raise exception 'COMMERCIAL_PRODUCT_RUNTIME_STATE_NOT_FOUND'; end if;

  v_readiness := public.evaluate_commercial_product_readiness_internal(
    p_product_id,
    p_product_version_id,
    p_requested_environment,
    p_requested_public
  );

  insert into public.commercial_product_activation_requests (
    product_id, product_version_id, request_status,
    requested_environment, requested_public,
    readiness_status, readiness_report,
    requested_by, request_reason, metadata
  ) values (
    p_product_id, p_product_version_id, 'pending',
    p_requested_environment, p_requested_public,
    v_readiness->>'status', v_readiness,
    btrim(p_requested_by), nullif(btrim(p_request_reason), ''),
    coalesce(p_metadata, '{}'::jsonb)
  ) returning * into v_request;

  update public.commercial_product_runtime_states
  set runtime_state = 'activation_pending',
      active_version_id = p_product_version_id,
      activation_request_id = v_request.id,
      readiness_status = v_readiness->>'status',
      readiness_report = v_readiness,
      state_reason = 'PRODUCT_ACTIVATION_REQUESTED',
      updated_at = clock_timestamp()
  where product_id = p_product_id;

  perform public.append_commercial_product_lifecycle_event_internal(
    p_product_id, p_product_version_id, v_request.id,
    'PRODUCT_ACTIVATION_REQUESTED', v_previous_state, 'activation_pending',
    p_request_reason, p_requested_by, p_correlation_id, p_causation_id,
    jsonb_build_object(
      'requested_environment', p_requested_environment,
      'requested_public', p_requested_public,
      'readiness_status', v_readiness->>'status'
    )
  );

  return v_request;
end;
$$;

create or replace function public.approve_commercial_product_activation_internal(
  p_activation_request_id uuid,
  p_approved_by text,
  p_review_reason text default null,
  p_correlation_id uuid default null,
  p_causation_id uuid default null
)
returns public.commercial_product_runtime_states
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_request public.commercial_product_activation_requests;
  v_readiness jsonb;
  v_runtime public.commercial_product_runtime_states;
  v_next_state text;
begin
  select * into v_request
  from public.commercial_product_activation_requests
  where id = p_activation_request_id
  for update;

  if not found then raise exception 'COMMERCIAL_PRODUCT_ACTIVATION_REQUEST_NOT_FOUND'; end if;
  if v_request.request_status <> 'pending' then raise exception 'COMMERCIAL_PRODUCT_ACTIVATION_REQUEST_NOT_PENDING'; end if;

  v_readiness := public.evaluate_commercial_product_readiness_internal(
    v_request.product_id,
    v_request.product_version_id,
    v_request.requested_environment,
    v_request.requested_public
  );

  if not (v_readiness->>'ready')::boolean then
    update public.commercial_product_runtime_states
    set runtime_state = 'blocked',
        readiness_status = 'blocked',
        readiness_report = v_readiness,
        state_reason = 'PRODUCT_ACTIVATION_BLOCKED',
        updated_at = clock_timestamp()
    where product_id = v_request.product_id
    returning * into v_runtime;

    perform public.append_commercial_product_lifecycle_event_internal(
      v_request.product_id, v_request.product_version_id, v_request.id,
      'PRODUCT_ACTIVATION_BLOCKED', 'activation_pending', 'blocked',
      'READINESS_BLOCKED', p_approved_by, p_correlation_id, p_causation_id,
      v_readiness
    );

    return v_runtime;
  end if;

  v_next_state := case when v_request.requested_environment = 'live' then 'active_live' else 'active_test' end;

  update public.commercial_product_activation_requests
  set request_status = 'approved',
      reviewed_by = btrim(p_approved_by),
      review_reason = nullif(btrim(p_review_reason), ''),
      reviewed_at = clock_timestamp(),
      readiness_status = 'ready',
      readiness_report = v_readiness
  where id = v_request.id;

  update public.commercial_products
  set enabled = true,
      public = v_request.requested_public,
      catalog_status = 'approved',
      test_only = (v_request.requested_environment = 'test'),
      updated_at = clock_timestamp()
  where id = v_request.product_id;

  update public.commercial_product_runtime_states
  set runtime_state = v_next_state,
      readiness_status = 'ready',
      readiness_report = v_readiness,
      active_version_id = v_request.product_version_id,
      activation_request_id = v_request.id,
      active_environment = v_request.requested_environment,
      active_public = v_request.requested_public,
      state_reason = 'PRODUCT_ACTIVATION_APPROVED',
      activated_at = clock_timestamp(),
      updated_at = clock_timestamp()
  where product_id = v_request.product_id
  returning * into v_runtime;

  perform public.append_commercial_product_lifecycle_event_internal(
    v_request.product_id, v_request.product_version_id, v_request.id,
    'PRODUCT_ACTIVATION_APPROVED', 'activation_pending', v_next_state,
    p_review_reason, p_approved_by, p_correlation_id, p_causation_id,
    jsonb_build_object(
      'environment', v_request.requested_environment,
      'public', v_request.requested_public
    )
  );

  return v_runtime;
end;
$$;

create or replace function public.reject_commercial_product_activation_internal(
  p_activation_request_id uuid,
  p_rejected_by text,
  p_review_reason text default null,
  p_correlation_id uuid default null,
  p_causation_id uuid default null
)
returns public.commercial_product_activation_requests
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_request public.commercial_product_activation_requests;
begin
  select * into v_request
  from public.commercial_product_activation_requests
  where id = p_activation_request_id
  for update;

  if not found then raise exception 'COMMERCIAL_PRODUCT_ACTIVATION_REQUEST_NOT_FOUND'; end if;
  if v_request.request_status <> 'pending' then raise exception 'COMMERCIAL_PRODUCT_ACTIVATION_REQUEST_NOT_PENDING'; end if;

  update public.commercial_product_activation_requests
  set request_status = 'rejected',
      reviewed_by = btrim(p_rejected_by),
      review_reason = nullif(btrim(p_review_reason), ''),
      reviewed_at = clock_timestamp()
  where id = v_request.id
  returning * into v_request;

  update public.commercial_product_runtime_states
  set runtime_state = 'inactive',
      state_reason = 'PRODUCT_ACTIVATION_EXPLICITLY_REJECTED',
      updated_at = clock_timestamp()
  where product_id = v_request.product_id;

  perform public.append_commercial_product_lifecycle_event_internal(
    v_request.product_id, v_request.product_version_id, v_request.id,
    'PRODUCT_ACTIVATION_REJECTED', 'activation_pending', 'inactive',
    p_review_reason, p_rejected_by, p_correlation_id, p_causation_id,
    '{}'::jsonb
  );

  return v_request;
end;
$$;

-- =============================================================================
-- 14. SUSPEND / RETIRE
-- =============================================================================

create or replace function public.suspend_commercial_product_internal(
  p_product_id uuid,
  p_actor text,
  p_reason text default null
)
returns public.commercial_product_runtime_states
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_previous text;
  v_runtime public.commercial_product_runtime_states;
begin
  select runtime_state into v_previous
  from public.commercial_product_runtime_states
  where product_id = p_product_id
  for update;

  if not found then raise exception 'COMMERCIAL_PRODUCT_RUNTIME_STATE_NOT_FOUND'; end if;

  update public.commercial_products
  set enabled = false, public = false, catalog_status = 'suspended', updated_at = clock_timestamp()
  where id = p_product_id;

  update public.commercial_product_runtime_states
  set runtime_state = 'suspended', active_public = false,
      state_reason = 'PRODUCT_SUSPENDED', suspended_at = clock_timestamp(),
      updated_at = clock_timestamp()
  where product_id = p_product_id
  returning * into v_runtime;

  perform public.append_commercial_product_lifecycle_event_internal(
    p_product_id, v_runtime.active_version_id, v_runtime.activation_request_id,
    'PRODUCT_SUSPENDED', v_previous, 'suspended', p_reason, p_actor,
    null, null, '{}'::jsonb
  );

  return v_runtime;
end;
$$;

create or replace function public.retire_commercial_product_internal(
  p_product_id uuid,
  p_actor text,
  p_reason text default null
)
returns public.commercial_product_runtime_states
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_previous text;
  v_runtime public.commercial_product_runtime_states;
begin
  select runtime_state into v_previous
  from public.commercial_product_runtime_states
  where product_id = p_product_id
  for update;

  if not found then raise exception 'COMMERCIAL_PRODUCT_RUNTIME_STATE_NOT_FOUND'; end if;

  update public.commercial_products
  set enabled = false, public = false, catalog_status = 'retired', updated_at = clock_timestamp()
  where id = p_product_id;

  update public.commercial_product_runtime_states
  set runtime_state = 'retired', active_public = false,
      state_reason = 'PRODUCT_RETIRED', retired_at = clock_timestamp(),
      updated_at = clock_timestamp()
  where product_id = p_product_id
  returning * into v_runtime;

  perform public.append_commercial_product_lifecycle_event_internal(
    p_product_id, v_runtime.active_version_id, v_runtime.activation_request_id,
    'PRODUCT_RETIRED', v_previous, 'retired', p_reason, p_actor,
    null, null, '{}'::jsonb
  );

  return v_runtime;
end;
$$;

-- =============================================================================
-- 15. READ MODELS
-- =============================================================================

create or replace function public.get_commercial_product_runtime_states_internal(
  p_product_code text default null
)
returns table (
  product_id uuid,
  product_code text,
  title text,
  passes integer,
  price_minor integer,
  currency text,
  enabled boolean,
  public boolean,
  catalog_status text,
  runtime_state text,
  readiness_status text,
  active_environment text,
  active_public boolean,
  active_version_id uuid,
  activation_request_id uuid,
  state_reason text,
  updated_at timestamptz
)
language sql
security definer
set search_path = public, pg_temp
as $$
  select
    p.id, p.product_code, p.title, p.passes, p.price_minor, p.currency,
    p.enabled, p.public, p.catalog_status,
    s.runtime_state, s.readiness_status, s.active_environment,
    s.active_public, s.active_version_id, s.activation_request_id,
    s.state_reason, s.updated_at
  from public.commercial_products p
  join public.commercial_product_runtime_states s on s.product_id = p.id
  where p_product_code is null or p.product_code = upper(btrim(p_product_code))
  order by p.sort_order, p.product_code;
$$;

create or replace function public.get_commercial_product_lifecycle_internal(
  p_product_id uuid,
  p_limit integer default 200
)
returns setof public.commercial_product_lifecycle_events
language sql
security definer
set search_path = public, pg_temp
as $$
  select *
  from public.commercial_product_lifecycle_events
  where product_id = p_product_id
  order by created_at desc, id desc
  limit greatest(1, least(coalesce(p_limit, 200), 1000));
$$;

-- =============================================================================
-- 16. RLS AND PRIVILEGES
-- =============================================================================

alter table public.commercial_product_versions enable row level security;
alter table public.commercial_product_provider_listings enable row level security;
alter table public.commercial_campaign_product_bindings enable row level security;
alter table public.commercial_product_activation_requests enable row level security;
alter table public.commercial_product_runtime_states enable row level security;
alter table public.commercial_product_lifecycle_events enable row level security;

revoke all on table public.commercial_product_versions from public, anon, authenticated;
revoke all on table public.commercial_product_provider_listings from public, anon, authenticated;
revoke all on table public.commercial_campaign_product_bindings from public, anon, authenticated;
revoke all on table public.commercial_product_activation_requests from public, anon, authenticated;
revoke all on table public.commercial_product_runtime_states from public, anon, authenticated;
revoke all on table public.commercial_product_lifecycle_events from public, anon, authenticated;

grant select, insert, update, delete on table public.commercial_product_versions to service_role;
grant select, insert, update, delete on table public.commercial_product_provider_listings to service_role;
grant select, insert, update, delete on table public.commercial_campaign_product_bindings to service_role;
grant select, insert, update, delete on table public.commercial_product_activation_requests to service_role;
grant select, insert, update, delete on table public.commercial_product_runtime_states to service_role;
grant select, insert, update, delete on table public.commercial_product_lifecycle_events to service_role;

revoke all on function public.protect_commercial_product_version_internal() from public, anon, authenticated;
revoke all on function public.protect_commercial_product_lifecycle_event_internal() from public, anon, authenticated;
revoke all on function public.append_commercial_product_lifecycle_event_internal(uuid, uuid, uuid, text, text, text, text, text, uuid, uuid, jsonb) from public, anon, authenticated;
revoke all on function public.create_commercial_product_version_internal(uuid, text, text, jsonb, uuid, uuid) from public, anon, authenticated;
revoke all on function public.approve_commercial_product_version_internal(uuid, text, text, uuid, uuid) from public, anon, authenticated;
revoke all on function public.create_commercial_product_provider_listing_internal(uuid, uuid, text, text, text, jsonb, jsonb) from public, anon, authenticated;
revoke all on function public.bind_commercial_campaign_product_internal(uuid, uuid, text, timestamptz, timestamptz, jsonb, jsonb) from public, anon, authenticated;
revoke all on function public.evaluate_commercial_product_readiness_internal(uuid, uuid, text, boolean) from public, anon, authenticated;
revoke all on function public.request_commercial_product_activation_internal(uuid, uuid, text, text, boolean, text, jsonb, uuid, uuid) from public, anon, authenticated;
revoke all on function public.approve_commercial_product_activation_internal(uuid, text, text, uuid, uuid) from public, anon, authenticated;
revoke all on function public.reject_commercial_product_activation_internal(uuid, text, text, uuid, uuid) from public, anon, authenticated;
revoke all on function public.suspend_commercial_product_internal(uuid, text, text) from public, anon, authenticated;
revoke all on function public.retire_commercial_product_internal(uuid, text, text) from public, anon, authenticated;
revoke all on function public.get_commercial_product_runtime_states_internal(text) from public, anon, authenticated;
revoke all on function public.get_commercial_product_lifecycle_internal(uuid, integer) from public, anon, authenticated;

grant execute on function public.append_commercial_product_lifecycle_event_internal(uuid, uuid, uuid, text, text, text, text, text, uuid, uuid, jsonb) to service_role;
grant execute on function public.create_commercial_product_version_internal(uuid, text, text, jsonb, uuid, uuid) to service_role;
grant execute on function public.approve_commercial_product_version_internal(uuid, text, text, uuid, uuid) to service_role;
grant execute on function public.create_commercial_product_provider_listing_internal(uuid, uuid, text, text, text, jsonb, jsonb) to service_role;
grant execute on function public.bind_commercial_campaign_product_internal(uuid, uuid, text, timestamptz, timestamptz, jsonb, jsonb) to service_role;
grant execute on function public.evaluate_commercial_product_readiness_internal(uuid, uuid, text, boolean) to service_role;
grant execute on function public.request_commercial_product_activation_internal(uuid, uuid, text, text, boolean, text, jsonb, uuid, uuid) to service_role;
grant execute on function public.approve_commercial_product_activation_internal(uuid, text, text, uuid, uuid) to service_role;
grant execute on function public.reject_commercial_product_activation_internal(uuid, text, text, uuid, uuid) to service_role;
grant execute on function public.suspend_commercial_product_internal(uuid, text, text) to service_role;
grant execute on function public.retire_commercial_product_internal(uuid, text, text) to service_role;
grant execute on function public.get_commercial_product_runtime_states_internal(text) to service_role;
grant execute on function public.get_commercial_product_lifecycle_internal(uuid, integer) to service_role;

-- =============================================================================
-- 17. CERTIFICATION ASSERTIONS
-- =============================================================================

do $$
declare
  v_product_count bigint;
  v_runtime_count bigint;
  v_version_count bigint;
  v_listing_count bigint;
  v_binding_count bigint;
  v_request_count bigint;
  v_event_count bigint;
  v_enabled_count bigint;
  v_public_count bigint;
  v_function_count bigint;
begin
  select count(*) into v_product_count from public.commercial_products;
  select count(*) into v_runtime_count from public.commercial_product_runtime_states;
  select count(*) into v_version_count from public.commercial_product_versions;
  select count(*) into v_listing_count from public.commercial_product_provider_listings;
  select count(*) into v_binding_count from public.commercial_campaign_product_bindings;
  select count(*) into v_request_count from public.commercial_product_activation_requests;
  select count(*) into v_event_count from public.commercial_product_lifecycle_events;
  select count(*) into v_enabled_count from public.commercial_products where enabled;
  select count(*) into v_public_count from public.commercial_products where public;

  if v_product_count < 4 then
    raise exception 'MIGRATION_111_EXISTING_PRODUCT_CATALOG_ASSERTION_FAILED count=%', v_product_count;
  end if;

  if v_runtime_count <> v_product_count then
    raise exception 'MIGRATION_111_RUNTIME_COVERAGE_ASSERTION_FAILED products=%, runtime=%', v_product_count, v_runtime_count;
  end if;

  if v_version_count <> 0
     or v_listing_count <> 0
     or v_binding_count <> 0
     or v_request_count <> 0
     or v_event_count <> 0
     or v_enabled_count <> 0
     or v_public_count <> 0 then
    raise exception
      'MIGRATION_111_PASSIVE_STATE_ASSERTION_FAILED versions=%, listings=%, bindings=%, requests=%, events=%, enabled=%, public=%',
      v_version_count, v_listing_count, v_binding_count,
      v_request_count, v_event_count, v_enabled_count, v_public_count;
  end if;

  select count(distinct p.proname)
  into v_function_count
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public'
    and p.proname in (
      'append_commercial_product_lifecycle_event_internal',
      'create_commercial_product_version_internal',
      'approve_commercial_product_version_internal',
      'create_commercial_product_provider_listing_internal',
      'bind_commercial_campaign_product_internal',
      'evaluate_commercial_product_readiness_internal',
      'request_commercial_product_activation_internal',
      'approve_commercial_product_activation_internal',
      'reject_commercial_product_activation_internal',
      'suspend_commercial_product_internal',
      'retire_commercial_product_internal',
      'get_commercial_product_runtime_states_internal',
      'get_commercial_product_lifecycle_internal'
    );

  if v_function_count <> 13 then
    raise exception 'MIGRATION_111_FUNCTION_ASSERTION_FAILED count=%', v_function_count;
  end if;

  raise notice
    'MIGRATION_111_CERTIFIED product_count=%, runtime_count=%, version_count=%, listing_count=%, binding_count=%, enabled_count=%, public_count=%',
    v_product_count, v_runtime_count, v_version_count,
    v_listing_count, v_binding_count, v_enabled_count, v_public_count;
end;
$$;

commit;
