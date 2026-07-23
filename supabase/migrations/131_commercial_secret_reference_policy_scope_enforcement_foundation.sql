-- =============================================================================
-- FANTAGOL
-- Migration: 131_commercial_secret_reference_policy_scope_enforcement_foundation.sql
-- Milestone: Commercial Platform - Secret Reference Policy & Scope Enforcement
--
-- Purpose:
--   Introduce a deterministic, passive authorization layer over an accepted
--   secret-reference gateway decision. This layer evaluates policy, scope,
--   namespace ownership, capability, backend trust and binding compatibility.
--
-- Safety:
--   No endpoint discovery, backend contact, authentication, secret lookup,
--   secret resolution, decryption, credential loading/delivery or network use.
-- =============================================================================

\set ON_ERROR_STOP on

begin;

create extension if not exists pgcrypto with schema extensions;

do $$
begin
  if to_regclass('public.commercial_secret_reference_gateway_requests') is null
     or to_regclass('public.commercial_secret_reference_gateway_decisions') is null
     or to_regclass('public.commercial_secret_backend_bindings') is null
     or to_regclass('public.commercial_secret_backends') is null
     or to_regclass('public.commercial_secret_backend_versions') is null then
    raise exception 'MIGRATION_131_DEPENDENCY_MISSING';
  end if;
end
$$;

-- =============================================================================
-- 1. AUTHORIZATION POLICY
-- =============================================================================

create table public.commercial_secret_reference_authorization_policies (
  id uuid primary key default gen_random_uuid(),
  policy_code text not null,
  environment text not null default 'production',
  policy_status text not null default 'draft',
  policy_version integer not null default 1,

  intake_enabled boolean not null default true,
  policy_evaluation_enabled boolean not null default true,
  scope_enforcement_enabled boolean not null default true,
  namespace_ownership_enabled boolean not null default true,
  capability_enforcement_enabled boolean not null default true,
  backend_trust_enforcement_enabled boolean not null default true,
  binding_validation_enforcement_enabled boolean not null default true,
  contract_validation_enabled boolean not null default true,
  decision_recording_enabled boolean not null default true,

  automatic_dispatch_enabled boolean not null default false,
  endpoint_discovery_enabled boolean not null default false,
  backend_probe_enabled boolean not null default false,
  backend_contact_enabled boolean not null default false,
  backend_authentication_enabled boolean not null default false,
  secret_lookup_enabled boolean not null default false,
  secret_resolution_enabled boolean not null default false,
  secret_decryption_enabled boolean not null default false,
  credential_material_loading_enabled boolean not null default false,
  credential_delivery_enabled boolean not null default false,
  network_access_enabled boolean not null default false,

  default_decision text not null default 'held',
  created_by text not null,
  approved_by text,
  approved_at timestamptz,
  policy_metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default clock_timestamp(),

  constraint commercial_secret_reference_authorization_policy_unique
    unique(policy_code, environment),

  constraint commercial_secret_reference_authorization_policy_code_check
    check (
      policy_code=lower(policy_code)
      and policy_code ~ '^[a-z][a-z0-9:_-]{7,159}$'
      and environment in ('development','test','staging','production')
      and policy_status in ('draft','approved','retired')
      and policy_version > 0
      and default_decision in ('held','blocked')
    ),

  constraint commercial_secret_reference_authorization_policy_json_check
    check (
      jsonb_typeof(policy_metadata)='object'
      and not (policy_metadata ?| array[
        'secret','secret_value','password','private_key','access_token',
        'refresh_token','api_key','client_secret','plaintext','ciphertext',
        'url','uri','endpoint','connection_string','dsn','host','hostname'
      ])
    ),

  constraint commercial_secret_reference_authorization_policy_passive_check
    check (
      automatic_dispatch_enabled=false
      and endpoint_discovery_enabled=false
      and backend_probe_enabled=false
      and backend_contact_enabled=false
      and backend_authentication_enabled=false
      and secret_lookup_enabled=false
      and secret_resolution_enabled=false
      and secret_decryption_enabled=false
      and credential_material_loading_enabled=false
      and credential_delivery_enabled=false
      and network_access_enabled=false
    )
);

comment on table public.commercial_secret_reference_authorization_policies is
'Immutable passive authorization policy for opaque secret references.';

-- =============================================================================
-- 2. SCOPE RULES
-- =============================================================================

create table public.commercial_secret_reference_scope_rules (
  id uuid primary key default gen_random_uuid(),
  authorization_policy_id uuid not null,
  rule_code text not null,
  rule_status text not null default 'draft',
  rule_priority integer not null default 100,

  scope_type text not null,
  scope_key text not null,
  namespace_pattern text not null,
  capability_code text not null,
  minimum_backend_trust_tier text not null default 'validated',

  allow_reference_routing boolean not null default true,
  require_validated_binding boolean not null default true,
  require_active_contract boolean not null default true,
  require_namespace_ownership boolean not null default true,

  created_by text not null,
  approved_by text,
  approved_at timestamptz,
  rule_metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default clock_timestamp(),

  constraint commercial_secret_reference_scope_rule_policy_fkey
    foreign key(authorization_policy_id)
    references public.commercial_secret_reference_authorization_policies(id)
    on delete restrict,

  constraint commercial_secret_reference_scope_rule_unique
    unique(authorization_policy_id, rule_code),

  constraint commercial_secret_reference_scope_rule_values_check
    check (
      rule_code=lower(rule_code)
      and rule_code ~ '^[a-z][a-z0-9:_-]{5,159}$'
      and rule_status in ('draft','approved','suspended','retired')
      and rule_priority between 1 and 10000
      and scope_type in ('platform','provider','credential_binding')
      and scope_key=lower(scope_key)
      and (scope_key='*' or scope_key ~ '^[a-z][a-z0-9:_-]{1,159}$')
      and namespace_pattern=lower(namespace_pattern)
      and (namespace_pattern='*' or namespace_pattern ~ '^[a-z][a-z0-9:_-]{3,159}\*?$')
      and capability_code=lower(capability_code)
      and (capability_code='*' or capability_code ~ '^[a-z][a-z0-9:_-]{3,95}$')
      and minimum_backend_trust_tier in ('registered','validated','approved')
      and jsonb_typeof(rule_metadata)='object'
      and not (rule_metadata ?| array[
        'secret','secret_value','password','private_key','access_token',
        'refresh_token','api_key','client_secret','plaintext','ciphertext',
        'url','uri','endpoint','connection_string','dsn','host','hostname'
      ])
    )
);

create index commercial_secret_reference_scope_rules_lookup_idx
  on public.commercial_secret_reference_scope_rules
  (authorization_policy_id, rule_status, scope_type, rule_priority, id);

-- =============================================================================
-- 3. AUTHORIZATION REQUESTS
-- =============================================================================

create table public.commercial_secret_reference_authorization_requests (
  id uuid primary key default gen_random_uuid(),
  request_key text not null unique,
  idempotency_key text not null unique,

  authorization_policy_id uuid not null,
  gateway_request_id uuid not null,
  gateway_decision_id uuid not null,

  requested_environment text not null,
  requested_scope_type text not null,
  requested_scope_key text not null,
  requested_namespace text not null,
  requested_capability text not null,

  request_status text not null default 'received',
  correlation_id uuid not null,
  causation_id uuid,
  requested_by text not null,
  requested_at timestamptz not null default clock_timestamp(),
  evaluated_at timestamptz,
  terminal_reason text,

  request_hash text not null,
  request_metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default clock_timestamp(),
  updated_at timestamptz not null default clock_timestamp(),

  constraint commercial_secret_reference_authorization_request_policy_fkey
    foreign key(authorization_policy_id)
    references public.commercial_secret_reference_authorization_policies(id)
    on delete restrict,

  constraint commercial_secret_reference_authorization_request_gateway_request_fkey
    foreign key(gateway_request_id)
    references public.commercial_secret_reference_gateway_requests(id)
    on delete restrict,

  constraint commercial_secret_reference_authorization_request_gateway_decision_fkey
    foreign key(gateway_decision_id)
    references public.commercial_secret_reference_gateway_decisions(id)
    on delete restrict,

  constraint commercial_secret_reference_authorization_request_values_check
    check (
      request_key=lower(request_key)
      and request_key ~ '^[a-z][a-z0-9:_-]{7,159}$'
      and length(idempotency_key) between 8 and 240
      and requested_environment in ('development','test','staging','production')
      and requested_scope_type in ('platform','provider','credential_binding')
      and requested_scope_key=lower(requested_scope_key)
      and requested_namespace=lower(requested_namespace)
      and requested_capability=lower(requested_capability)
      and request_status in ('received','evaluated','authorized','held','blocked','cancelled')
      and request_hash ~ '^[a-f0-9]{64}$'
      and jsonb_typeof(request_metadata)='object'
      and not (request_metadata ?| array[
        'secret','secret_value','password','private_key','access_token',
        'refresh_token','api_key','client_secret','plaintext','ciphertext',
        'url','uri','endpoint','connection_string','dsn','host','hostname'
      ])
    )
);

create index commercial_secret_reference_authorization_requests_queue_idx
  on public.commercial_secret_reference_authorization_requests
  (request_status, requested_at, id);

-- =============================================================================
-- 4. EVALUATIONS
-- =============================================================================

create table public.commercial_secret_reference_authorization_evaluations (
  id uuid primary key default gen_random_uuid(),
  authorization_request_id uuid not null,
  scope_rule_id uuid,

  evaluation_order integer not null,
  evaluation_code text not null,
  evaluation_status text not null,
  passed boolean not null,
  evaluation_reason text,

  evaluation_hash text not null,
  evaluation_metadata jsonb not null default '{}'::jsonb,
  evaluated_at timestamptz not null default clock_timestamp(),

  constraint commercial_secret_reference_authorization_evaluation_request_fkey
    foreign key(authorization_request_id)
    references public.commercial_secret_reference_authorization_requests(id)
    on delete restrict,

  constraint commercial_secret_reference_authorization_evaluation_rule_fkey
    foreign key(scope_rule_id)
    references public.commercial_secret_reference_scope_rules(id)
    on delete restrict,

  constraint commercial_secret_reference_authorization_evaluation_unique
    unique(authorization_request_id, evaluation_order),

  constraint commercial_secret_reference_authorization_evaluation_values_check
    check (
      evaluation_order between 1 and 100
      and evaluation_code in (
        'GATEWAY_DECISION','ENVIRONMENT','SCOPE_RULE','SCOPE_KEY',
        'NAMESPACE_OWNERSHIP','CAPABILITY','BACKEND_TRUST',
        'BINDING_VALIDATION','CONTRACT_STATUS','PASSIVE_POSTURE'
      )
      and evaluation_status in ('passed','failed','held')
      and evaluation_hash ~ '^[a-f0-9]{64}$'
      and jsonb_typeof(evaluation_metadata)='object'
      and not (evaluation_metadata ?| array[
        'secret','secret_value','password','private_key','access_token',
        'refresh_token','api_key','client_secret','plaintext','ciphertext',
        'url','uri','endpoint','connection_string','dsn','host','hostname'
      ])
    )
);

-- =============================================================================
-- 5. DECISIONS
-- =============================================================================

create table public.commercial_secret_reference_authorization_decisions (
  id uuid primary key default gen_random_uuid(),
  authorization_request_id uuid not null unique,
  scope_rule_id uuid,

  decision_status text not null,
  decision_code text not null,
  authorized boolean not null default false,

  selected_backend_binding_id uuid,
  selected_backend_id uuid,
  selected_backend_version_id uuid,

  resolved_scope_type text,
  resolved_scope_key text,
  resolved_namespace text,
  resolved_capability text,

  backend_contact_allowed boolean not null default false,
  authentication_allowed boolean not null default false,
  secret_lookup_allowed boolean not null default false,
  secret_resolution_allowed boolean not null default false,
  decryption_allowed boolean not null default false,
  material_loading_allowed boolean not null default false,
  delivery_allowed boolean not null default false,
  network_access_allowed boolean not null default false,

  decided_by text not null,
  decision_reason text,
  decision_hash text not null,
  decision_metadata jsonb not null default '{}'::jsonb,
  decided_at timestamptz not null default clock_timestamp(),

  constraint commercial_secret_reference_authorization_decision_request_fkey
    foreign key(authorization_request_id)
    references public.commercial_secret_reference_authorization_requests(id)
    on delete restrict,

  constraint commercial_secret_reference_authorization_decision_rule_fkey
    foreign key(scope_rule_id)
    references public.commercial_secret_reference_scope_rules(id)
    on delete restrict,

  constraint commercial_secret_reference_authorization_decision_binding_fkey
    foreign key(selected_backend_binding_id)
    references public.commercial_secret_backend_bindings(id)
    on delete restrict,

  constraint commercial_secret_reference_authorization_decision_backend_fkey
    foreign key(selected_backend_id)
    references public.commercial_secret_backends(id)
    on delete restrict,

  constraint commercial_secret_reference_authorization_decision_version_fkey
    foreign key(selected_backend_version_id)
    references public.commercial_secret_backend_versions(id)
    on delete restrict,

  constraint commercial_secret_reference_authorization_decision_values_check
    check (
      decision_status in ('authorized','held','blocked')
      and decision_code in (
        'AUTHORIZED',
        'POLICY_DISABLED',
        'GATEWAY_NOT_ACCEPTED',
        'ENVIRONMENT_MISMATCH',
        'NO_SCOPE_RULE',
        'INVALID_SCOPE',
        'SCOPE_KEY_MISMATCH',
        'NAMESPACE_NOT_OWNED',
        'CAPABILITY_NOT_ALLOWED',
        'BACKEND_NOT_TRUSTED',
        'BINDING_NOT_VALIDATED',
        'CONTRACT_NOT_ACTIVE',
        'PASSIVE_POSTURE_VIOLATION'
      )
      and authorized=(decision_status='authorized')
      and decision_hash ~ '^[a-f0-9]{64}$'
      and jsonb_typeof(decision_metadata)='object'
      and not (decision_metadata ?| array[
        'secret','secret_value','password','private_key','access_token',
        'refresh_token','api_key','client_secret','plaintext','ciphertext',
        'url','uri','endpoint','connection_string','dsn','host','hostname'
      ])
    ),

  constraint commercial_secret_reference_authorization_decision_passive_check
    check (
      backend_contact_allowed=false
      and authentication_allowed=false
      and secret_lookup_allowed=false
      and secret_resolution_allowed=false
      and decryption_allowed=false
      and material_loading_allowed=false
      and delivery_allowed=false
      and network_access_allowed=false
    )
);

-- =============================================================================
-- 6. RECEIPTS AND EVENTS
-- =============================================================================

create table public.commercial_secret_reference_authorization_receipts (
  id uuid primary key default gen_random_uuid(),
  receipt_type text not null,
  authorization_request_id uuid,
  authorization_decision_id uuid,
  receipt_status text not null,
  receipt_code text not null,
  receipt_message text,
  recorded_by text not null,
  correlation_id uuid,
  receipt_hash text not null,
  receipt_metadata jsonb not null default '{}'::jsonb,
  recorded_at timestamptz not null default clock_timestamp(),

  constraint commercial_secret_reference_authorization_receipt_request_fkey
    foreign key(authorization_request_id)
    references public.commercial_secret_reference_authorization_requests(id)
    on delete restrict,

  constraint commercial_secret_reference_authorization_receipt_decision_fkey
    foreign key(authorization_decision_id)
    references public.commercial_secret_reference_authorization_decisions(id)
    on delete restrict,

  constraint commercial_secret_reference_authorization_receipt_values_check
    check (
      receipt_type in ('REQUEST_ACCEPTED','REQUEST_REPLAYED','EVALUATION_COMPLETED','DECISION_RECORDED')
      and receipt_status in ('accepted','replayed','passed','held','blocked','authorized')
      and receipt_hash ~ '^[a-f0-9]{64}$'
      and jsonb_typeof(receipt_metadata)='object'
      and not (receipt_metadata ?| array[
        'secret','secret_value','password','private_key','access_token',
        'refresh_token','api_key','client_secret','plaintext','ciphertext',
        'url','uri','endpoint','connection_string','dsn','host','hostname'
      ])
    )
);

create table public.commercial_secret_reference_authorization_events (
  id uuid primary key default gen_random_uuid(),
  event_type text not null,
  authorization_policy_id uuid,
  scope_rule_id uuid,
  authorization_request_id uuid,
  authorization_decision_id uuid,
  event_status text not null,
  event_message text,
  event_source text not null,
  correlation_id uuid,
  causation_id uuid,
  event_hash text not null,
  event_metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default clock_timestamp(),

  constraint commercial_secret_reference_authorization_event_policy_fkey
    foreign key(authorization_policy_id)
    references public.commercial_secret_reference_authorization_policies(id)
    on delete restrict,

  constraint commercial_secret_reference_authorization_event_rule_fkey
    foreign key(scope_rule_id)
    references public.commercial_secret_reference_scope_rules(id)
    on delete restrict,

  constraint commercial_secret_reference_authorization_event_request_fkey
    foreign key(authorization_request_id)
    references public.commercial_secret_reference_authorization_requests(id)
    on delete restrict,

  constraint commercial_secret_reference_authorization_event_decision_fkey
    foreign key(authorization_decision_id)
    references public.commercial_secret_reference_authorization_decisions(id)
    on delete restrict,

  constraint commercial_secret_reference_authorization_event_values_check
    check (
      event_type ~ '^[A-Z][A-Z0-9_]{3,95}$'
      and event_status in ('draft','approved','received','evaluated','authorized','held','blocked')
      and event_hash ~ '^[a-f0-9]{64}$'
      and jsonb_typeof(event_metadata)='object'
      and not (event_metadata ?| array[
        'secret','secret_value','password','private_key','access_token',
        'refresh_token','api_key','client_secret','plaintext','ciphertext',
        'url','uri','endpoint','connection_string','dsn','host','hostname'
      ])
    )
);

-- =============================================================================
-- 7. GENERIC PROTECTION
-- =============================================================================

create function public.commercial_secret_reference_authorization_set_updated_at()
returns trigger
language plpgsql
set search_path=public,pg_temp
as $$
begin
  new.updated_at=clock_timestamp();
  return new;
end
$$;

create function public.commercial_secret_reference_authorization_immutable()
returns trigger
language plpgsql
set search_path=public,pg_temp
as $$
begin
  raise exception 'COMMERCIAL_SECRET_REFERENCE_AUTHORIZATION_IMMUTABLE';
end
$$;

create function public.commercial_secret_reference_authorization_append_only()
returns trigger
language plpgsql
set search_path=public,pg_temp
as $$
begin
  raise exception 'COMMERCIAL_SECRET_REFERENCE_AUTHORIZATION_APPEND_ONLY';
end
$$;

create trigger commercial_secret_reference_authorization_requests_updated_at
before update on public.commercial_secret_reference_authorization_requests
for each row execute function public.commercial_secret_reference_authorization_set_updated_at();

create trigger commercial_secret_reference_authorization_policies_immutable
before update or delete on public.commercial_secret_reference_authorization_policies
for each row execute function public.commercial_secret_reference_authorization_immutable();

create trigger commercial_secret_reference_scope_rules_immutable
before update or delete on public.commercial_secret_reference_scope_rules
for each row execute function public.commercial_secret_reference_authorization_immutable();

create trigger commercial_secret_reference_authorization_evaluations_immutable
before update or delete on public.commercial_secret_reference_authorization_evaluations
for each row execute function public.commercial_secret_reference_authorization_immutable();

create trigger commercial_secret_reference_authorization_decisions_immutable
before update or delete on public.commercial_secret_reference_authorization_decisions
for each row execute function public.commercial_secret_reference_authorization_immutable();

create trigger commercial_secret_reference_authorization_receipts_append_only
before update or delete on public.commercial_secret_reference_authorization_receipts
for each row execute function public.commercial_secret_reference_authorization_append_only();

create trigger commercial_secret_reference_authorization_events_append_only
before update or delete on public.commercial_secret_reference_authorization_events
for each row execute function public.commercial_secret_reference_authorization_append_only();

-- =============================================================================
-- 8. APPEND HELPERS
-- =============================================================================

create function public.append_commercial_secret_reference_authorization_receipt(
  p_receipt_type text,
  p_authorization_request_id uuid,
  p_authorization_decision_id uuid,
  p_receipt_status text,
  p_receipt_code text,
  p_receipt_message text,
  p_recorded_by text,
  p_correlation_id uuid,
  p_receipt_metadata jsonb default '{}'::jsonb
)
returns public.commercial_secret_reference_authorization_receipts
language plpgsql
security definer
set search_path=public,extensions,pg_temp
as $$
declare
  v_row public.commercial_secret_reference_authorization_receipts;
  v_hash text;
begin
  v_hash:=encode(digest(concat_ws('|',
    p_receipt_type,coalesce(p_authorization_request_id::text,''),
    coalesce(p_authorization_decision_id::text,''),p_receipt_status,
    p_receipt_code,coalesce(p_receipt_message,''),p_recorded_by,
    coalesce(p_correlation_id::text,''),coalesce(p_receipt_metadata,'{}'::jsonb)::text
  ),'sha256'),'hex');

  insert into public.commercial_secret_reference_authorization_receipts(
    receipt_type,authorization_request_id,authorization_decision_id,
    receipt_status,receipt_code,receipt_message,recorded_by,correlation_id,
    receipt_hash,receipt_metadata
  ) values (
    p_receipt_type,p_authorization_request_id,p_authorization_decision_id,
    p_receipt_status,p_receipt_code,p_receipt_message,p_recorded_by,
    p_correlation_id,v_hash,coalesce(p_receipt_metadata,'{}'::jsonb)
  ) returning * into v_row;
  return v_row;
end
$$;

create function public.append_commercial_secret_reference_authorization_event(
  p_event_type text,
  p_authorization_policy_id uuid,
  p_scope_rule_id uuid,
  p_authorization_request_id uuid,
  p_authorization_decision_id uuid,
  p_event_status text,
  p_event_message text,
  p_event_source text,
  p_correlation_id uuid,
  p_causation_id uuid,
  p_event_metadata jsonb default '{}'::jsonb
)
returns public.commercial_secret_reference_authorization_events
language plpgsql
security definer
set search_path=public,extensions,pg_temp
as $$
declare
  v_row public.commercial_secret_reference_authorization_events;
  v_hash text;
begin
  v_hash:=encode(digest(concat_ws('|',
    p_event_type,coalesce(p_authorization_policy_id::text,''),
    coalesce(p_scope_rule_id::text,''),coalesce(p_authorization_request_id::text,''),
    coalesce(p_authorization_decision_id::text,''),p_event_status,
    coalesce(p_event_message,''),p_event_source,
    coalesce(p_correlation_id::text,''),coalesce(p_causation_id::text,''),
    coalesce(p_event_metadata,'{}'::jsonb)::text
  ),'sha256'),'hex');

  insert into public.commercial_secret_reference_authorization_events(
    event_type,authorization_policy_id,scope_rule_id,authorization_request_id,
    authorization_decision_id,event_status,event_message,event_source,
    correlation_id,causation_id,event_hash,event_metadata
  ) values (
    p_event_type,p_authorization_policy_id,p_scope_rule_id,p_authorization_request_id,
    p_authorization_decision_id,p_event_status,p_event_message,p_event_source,
    p_correlation_id,p_causation_id,v_hash,coalesce(p_event_metadata,'{}'::jsonb)
  ) returning * into v_row;
  return v_row;
end
$$;

-- =============================================================================
-- 9. INTAKE
-- =============================================================================

create function public.enqueue_commercial_secret_reference_authorization_request(
  p_request_key text,
  p_idempotency_key text,
  p_gateway_request_id uuid,
  p_gateway_decision_id uuid,
  p_requested_scope_type text,
  p_requested_scope_key text,
  p_requested_namespace text,
  p_requested_capability text,
  p_requested_by text,
  p_correlation_id uuid,
  p_causation_id uuid default null,
  p_request_metadata jsonb default '{}'::jsonb
)
returns public.commercial_secret_reference_authorization_requests
language plpgsql
security definer
set search_path=public,extensions,pg_temp
as $$
declare
  v_policy public.commercial_secret_reference_authorization_policies;
  v_gateway_request public.commercial_secret_reference_gateway_requests;
  v_gateway_decision public.commercial_secret_reference_gateway_decisions;
  v_existing public.commercial_secret_reference_authorization_requests;
  v_row public.commercial_secret_reference_authorization_requests;
  v_hash text;
begin
  select * into strict v_policy
  from public.commercial_secret_reference_authorization_policies
  where environment='production' and policy_status='approved'
  order by policy_version desc limit 1;

  if not v_policy.intake_enabled then
    raise exception 'COMMERCIAL_SECRET_REFERENCE_AUTHORIZATION_INTAKE_DISABLED';
  end if;

  select * into strict v_gateway_request
  from public.commercial_secret_reference_gateway_requests
  where id=p_gateway_request_id;

  select * into strict v_gateway_decision
  from public.commercial_secret_reference_gateway_decisions
  where id=p_gateway_decision_id and gateway_request_id=p_gateway_request_id;

  v_hash:=encode(digest(concat_ws('|',
    lower(p_request_key),p_gateway_request_id::text,p_gateway_decision_id::text,
    lower(p_requested_scope_type),lower(p_requested_scope_key),
    lower(p_requested_namespace),lower(p_requested_capability),
    coalesce(p_request_metadata,'{}'::jsonb)::text
  ),'sha256'),'hex');

  select * into v_existing
  from public.commercial_secret_reference_authorization_requests
  where idempotency_key=p_idempotency_key;

  if found then
    if v_existing.request_hash<>v_hash then
      raise exception 'COMMERCIAL_SECRET_REFERENCE_AUTHORIZATION_IDEMPOTENCY_CONFLICT';
    end if;

    perform public.append_commercial_secret_reference_authorization_receipt(
      'REQUEST_REPLAYED',v_existing.id,null,'replayed','REQUEST_REPLAYED',
      'Authorization request replayed',p_requested_by,p_correlation_id,
      jsonb_build_object('idempotency_key',p_idempotency_key)
    );
    return v_existing;
  end if;

  insert into public.commercial_secret_reference_authorization_requests(
    request_key,idempotency_key,authorization_policy_id,gateway_request_id,
    gateway_decision_id,requested_environment,requested_scope_type,
    requested_scope_key,requested_namespace,requested_capability,request_status,
    correlation_id,causation_id,requested_by,request_hash,request_metadata
  ) values (
    lower(p_request_key),p_idempotency_key,v_policy.id,p_gateway_request_id,
    p_gateway_decision_id,v_gateway_request.requested_environment,
    lower(p_requested_scope_type),lower(p_requested_scope_key),
    lower(p_requested_namespace),lower(p_requested_capability),'received',
    p_correlation_id,p_causation_id,p_requested_by,v_hash,
    coalesce(p_request_metadata,'{}'::jsonb)
  ) returning * into v_row;

  perform public.append_commercial_secret_reference_authorization_receipt(
    'REQUEST_ACCEPTED',v_row.id,null,'accepted','REQUEST_ACCEPTED',
    'Authorization request accepted',p_requested_by,p_correlation_id,
    jsonb_build_object('request_key',v_row.request_key)
  );

  perform public.append_commercial_secret_reference_authorization_event(
    'SECRET_REFERENCE_AUTHORIZATION_REQUESTED',v_policy.id,null,v_row.id,null,
    'received','Authorization request received','AUTHORIZATION_ENGINE',
    p_correlation_id,p_causation_id,jsonb_build_object('request_key',v_row.request_key)
  );

  return v_row;
end
$$;

-- =============================================================================
-- 10. EVALUATION ENGINE
-- =============================================================================

create function public.evaluate_commercial_secret_reference_authorization_request(
  p_authorization_request_id uuid,
  p_decided_by text
)
returns public.commercial_secret_reference_authorization_decisions
language plpgsql
security definer
set search_path=public,extensions,pg_temp
as $$
declare
  v_request public.commercial_secret_reference_authorization_requests;
  v_policy public.commercial_secret_reference_authorization_policies;
  v_gateway_decision public.commercial_secret_reference_gateway_decisions;
  v_binding public.commercial_secret_backend_bindings;
  v_backend public.commercial_secret_backends;
  v_version public.commercial_secret_backend_versions;
  v_rule public.commercial_secret_reference_scope_rules;
  v_decision public.commercial_secret_reference_authorization_decisions;
  v_status text:='authorized';
  v_code text:='AUTHORIZED';
  v_reason text:='All authorization constraints satisfied';
  v_hash text;
  v_order integer:=0;
  v_pass boolean;
begin
  select * into strict v_request
  from public.commercial_secret_reference_authorization_requests
  where id=p_authorization_request_id
  for update;

  select * into strict v_policy
  from public.commercial_secret_reference_authorization_policies
  where id=v_request.authorization_policy_id;

  select * into strict v_gateway_decision
  from public.commercial_secret_reference_gateway_decisions
  where id=v_request.gateway_decision_id;

  if exists(
    select 1 from public.commercial_secret_reference_authorization_decisions
    where authorization_request_id=v_request.id
  ) then
    select * into strict v_decision
    from public.commercial_secret_reference_authorization_decisions
    where authorization_request_id=v_request.id;
    return v_decision;
  end if;

  v_order:=v_order+1;
  v_pass:=(v_gateway_decision.decision_status='accepted');
  insert into public.commercial_secret_reference_authorization_evaluations(
    authorization_request_id,evaluation_order,evaluation_code,evaluation_status,
    passed,evaluation_reason,evaluation_hash,evaluation_metadata
  ) values (
    v_request.id,v_order,'GATEWAY_DECISION',
    case when v_pass then 'passed' else 'failed' end,v_pass,
    case when v_pass then 'Gateway decision accepted' else 'Gateway decision not accepted' end,
    encode(digest(v_request.id::text||'|GATEWAY_DECISION|'||v_pass::text,'sha256'),'hex'),'{}'
  );

  if not v_pass then
    v_status:='blocked'; v_code:='GATEWAY_NOT_ACCEPTED'; v_reason:='Gateway decision is not accepted';
  end if;

  if v_status='authorized' then
    select * into v_rule
    from public.commercial_secret_reference_scope_rules r
    where r.authorization_policy_id=v_policy.id
      and r.rule_status='approved'
      and r.scope_type=v_request.requested_scope_type
      and (r.scope_key='*' or r.scope_key=v_request.requested_scope_key)
      and (
        r.namespace_pattern='*'
        or r.namespace_pattern=v_request.requested_namespace
        or (
          right(r.namespace_pattern,1)='*'
          and v_request.requested_namespace like left(r.namespace_pattern,length(r.namespace_pattern)-1)||'%'
        )
      )
      and (r.capability_code='*' or r.capability_code=v_request.requested_capability)
    order by r.rule_priority,r.id
    limit 1;

    v_order:=v_order+1;
    v_pass:=(v_rule.id is not null);
    insert into public.commercial_secret_reference_authorization_evaluations(
      authorization_request_id,scope_rule_id,evaluation_order,evaluation_code,
      evaluation_status,passed,evaluation_reason,evaluation_hash,evaluation_metadata
    ) values (
      v_request.id,v_rule.id,v_order,'SCOPE_RULE',
      case when v_pass then 'passed' else 'failed' end,v_pass,
      case when v_pass then 'Matching approved scope rule found' else 'No approved scope rule found' end,
      encode(digest(v_request.id::text||'|SCOPE_RULE|'||v_pass::text,'sha256'),'hex'),'{}'
    );

    if not v_pass then
      v_status:=v_policy.default_decision;
      v_code:='NO_SCOPE_RULE';
      v_reason:='No approved scope rule matches the request';
    end if;
  end if;

  if v_status='authorized' then
    select * into strict v_binding
    from public.commercial_secret_backend_bindings
    where id=v_gateway_decision.selected_backend_binding_id;

    select * into strict v_backend
    from public.commercial_secret_backends
    where id=v_gateway_decision.selected_backend_id;

    select * into strict v_version
    from public.commercial_secret_backend_versions
    where id=v_gateway_decision.selected_backend_version_id;

    if not v_rule.allow_reference_routing then
      v_status:='blocked'; v_code:='INVALID_SCOPE'; v_reason:='Scope rule denies reference routing';
    elsif v_rule.require_namespace_ownership
      and v_binding.reference_namespace<>v_request.requested_namespace then
      v_status:='blocked'; v_code:='NAMESPACE_NOT_OWNED'; v_reason:='Binding does not own requested namespace';
    elsif v_rule.require_validated_binding and v_binding.binding_status<>'validated' then
      v_status:='blocked'; v_code:='BINDING_NOT_VALIDATED'; v_reason:='Backend binding is not validated';
    elsif (
      case v_backend.trust_tier
        when 'approved' then 3 when 'validated' then 2 when 'registered' then 1 else 0 end
      <
      case v_rule.minimum_backend_trust_tier
        when 'approved' then 3 when 'validated' then 2 when 'registered' then 1 else 0 end
    ) then
      v_status:='blocked'; v_code:='BACKEND_NOT_TRUSTED'; v_reason:='Backend trust tier is insufficient';
    elsif v_rule.require_active_contract
      and (v_version.version_status not in ('validated','approved')
           or v_backend.active_version_id<>v_version.id) then
      v_status:='blocked'; v_code:='CONTRACT_NOT_ACTIVE'; v_reason:='Backend contract version is not active';
    elsif not v_gateway_decision.capability_available then
      v_status:='blocked'; v_code:='CAPABILITY_NOT_ALLOWED'; v_reason:='Requested capability is unavailable';
    end if;
  end if;

  v_hash:=encode(digest(concat_ws('|',
    v_request.id::text,v_status,v_code,coalesce(v_rule.id::text,''),
    coalesce(v_gateway_decision.selected_backend_binding_id::text,''),
    coalesce(v_gateway_decision.selected_backend_id::text,''),
    coalesce(v_gateway_decision.selected_backend_version_id::text,'')
  ),'sha256'),'hex');

  insert into public.commercial_secret_reference_authorization_decisions(
    authorization_request_id,scope_rule_id,decision_status,decision_code,authorized,
    selected_backend_binding_id,selected_backend_id,selected_backend_version_id,
    resolved_scope_type,resolved_scope_key,resolved_namespace,resolved_capability,
    decided_by,decision_reason,decision_hash,decision_metadata
  ) values (
    v_request.id,v_rule.id,v_status,v_code,(v_status='authorized'),
    v_gateway_decision.selected_backend_binding_id,
    v_gateway_decision.selected_backend_id,
    v_gateway_decision.selected_backend_version_id,
    v_request.requested_scope_type,v_request.requested_scope_key,
    v_request.requested_namespace,v_request.requested_capability,
    p_decided_by,v_reason,v_hash,
    jsonb_build_object('passive_authorization_only',true)
  ) returning * into v_decision;

  update public.commercial_secret_reference_authorization_requests
  set request_status=v_status,evaluated_at=clock_timestamp(),terminal_reason=v_reason
  where id=v_request.id;

  perform public.append_commercial_secret_reference_authorization_receipt(
    'EVALUATION_COMPLETED',v_request.id,v_decision.id,
    case when v_status='authorized' then 'passed' else v_status end,
    v_code,v_reason,p_decided_by,v_request.correlation_id,
    jsonb_build_object('evaluation_count',v_order)
  );

  perform public.append_commercial_secret_reference_authorization_receipt(
    'DECISION_RECORDED',v_request.id,v_decision.id,v_status,v_code,
    v_reason,p_decided_by,v_request.correlation_id,
    jsonb_build_object('authorized',v_decision.authorized)
  );

  perform public.append_commercial_secret_reference_authorization_event(
    'SECRET_REFERENCE_AUTHORIZATION_DECIDED',v_policy.id,v_rule.id,
    v_request.id,v_decision.id,v_status,v_reason,'AUTHORIZATION_ENGINE',
    v_request.correlation_id,v_request.causation_id,
    jsonb_build_object('decision_code',v_code,'authorized',v_decision.authorized)
  );

  return v_decision;
end
$$;

-- =============================================================================
-- 11. READ MODEL
-- =============================================================================

create view public.commercial_secret_reference_authorization_read_model
with (security_invoker=true)
as
select
  r.id as authorization_request_id,
  r.request_key,
  r.idempotency_key,
  r.request_status,
  r.requested_environment,
  r.requested_scope_type,
  r.requested_scope_key,
  r.requested_namespace,
  r.requested_capability,
  r.gateway_request_id,
  r.gateway_decision_id,
  d.id as authorization_decision_id,
  d.decision_status,
  d.decision_code,
  d.authorized,
  d.scope_rule_id,
  d.selected_backend_binding_id,
  d.selected_backend_id,
  d.selected_backend_version_id,
  d.resolved_scope_type,
  d.resolved_scope_key,
  d.resolved_namespace,
  d.resolved_capability,
  d.backend_contact_allowed,
  d.authentication_allowed,
  d.secret_lookup_allowed,
  d.secret_resolution_allowed,
  d.decryption_allowed,
  d.material_loading_allowed,
  d.delivery_allowed,
  d.network_access_allowed,
  coalesce(e.evaluation_count,0) as evaluation_count,
  coalesce(rc.receipt_count,0) as receipt_count,
  coalesce(ev.event_count,0) as event_count,
  r.correlation_id,
  r.requested_at,
  r.evaluated_at
from public.commercial_secret_reference_authorization_requests r
left join public.commercial_secret_reference_authorization_decisions d
  on d.authorization_request_id=r.id
left join lateral (
  select count(*)::bigint as evaluation_count
  from public.commercial_secret_reference_authorization_evaluations x
  where x.authorization_request_id=r.id
) e on true
left join lateral (
  select count(*)::bigint as receipt_count
  from public.commercial_secret_reference_authorization_receipts x
  where x.authorization_request_id=r.id
) rc on true
left join lateral (
  select count(*)::bigint as event_count
  from public.commercial_secret_reference_authorization_events x
  where x.authorization_request_id=r.id
) ev on true;

comment on view public.commercial_secret_reference_authorization_read_model is
'Passive read model for secret-reference policy and scope authorization.';

-- =============================================================================
-- 12. FOUNDATION DATA
-- =============================================================================

insert into public.commercial_secret_reference_authorization_policies(
  policy_code,environment,policy_status,policy_version,
  created_by,approved_by,approved_at,policy_metadata
) values (
  'commercial:secret_reference_authorization:v1',
  'production','approved',1,
  'MIGRATION_131','MIGRATION_131',clock_timestamp(),
  jsonb_build_object(
    'opaque_references_only',true,
    'plaintext_storage_forbidden',true,
    'passive_authorization_only',true
  )
);

insert into public.commercial_secret_reference_scope_rules(
  authorization_policy_id,rule_code,rule_status,rule_priority,
  scope_type,scope_key,namespace_pattern,capability_code,
  minimum_backend_trust_tier,allow_reference_routing,
  require_validated_binding,require_active_contract,
  require_namespace_ownership,created_by,approved_by,approved_at,rule_metadata
)
select
  p.id,'commercial:secret_reference:platform_default','approved',100,
  'platform','platform','*','*','validated',true,true,true,true,
  'MIGRATION_131','MIGRATION_131',clock_timestamp(),
  jsonb_build_object('foundation_rule',true,'passive_only',true)
from public.commercial_secret_reference_authorization_policies p
where p.policy_code='commercial:secret_reference_authorization:v1'
  and p.environment='production';

select public.append_commercial_secret_reference_authorization_event(
  'SECRET_REFERENCE_AUTHORIZATION_INITIALIZED',
  p.id,r.id,null,null,'approved',
  'Secret-reference policy and scope enforcement initialized in passive mode',
  'MIGRATION_131',gen_random_uuid(),null,
  jsonb_build_object(
    'automatic_dispatch_enabled',false,
    'endpoint_discovery_enabled',false,
    'backend_contact_enabled',false,
    'secret_lookup_enabled',false,
    'secret_resolution_enabled',false,
    'secret_decryption_enabled',false,
    'credential_material_loading_enabled',false,
    'credential_delivery_enabled',false,
    'network_access_enabled',false
  )
)
from public.commercial_secret_reference_authorization_policies p
join public.commercial_secret_reference_scope_rules r
  on r.authorization_policy_id=p.id
where p.policy_code='commercial:secret_reference_authorization:v1'
  and p.environment='production'
  and r.rule_code='commercial:secret_reference:platform_default';

-- =============================================================================
-- 13. RLS AND PRIVILEGES
-- =============================================================================

alter table public.commercial_secret_reference_authorization_policies enable row level security;
alter table public.commercial_secret_reference_scope_rules enable row level security;
alter table public.commercial_secret_reference_authorization_requests enable row level security;
alter table public.commercial_secret_reference_authorization_evaluations enable row level security;
alter table public.commercial_secret_reference_authorization_decisions enable row level security;
alter table public.commercial_secret_reference_authorization_receipts enable row level security;
alter table public.commercial_secret_reference_authorization_events enable row level security;

revoke all on public.commercial_secret_reference_authorization_policies from public,anon,authenticated;
revoke all on public.commercial_secret_reference_scope_rules from public,anon,authenticated;
revoke all on public.commercial_secret_reference_authorization_requests from public,anon,authenticated;
revoke all on public.commercial_secret_reference_authorization_evaluations from public,anon,authenticated;
revoke all on public.commercial_secret_reference_authorization_decisions from public,anon,authenticated;
revoke all on public.commercial_secret_reference_authorization_receipts from public,anon,authenticated;
revoke all on public.commercial_secret_reference_authorization_events from public,anon,authenticated;
revoke all on public.commercial_secret_reference_authorization_read_model from public,anon,authenticated;

grant select,insert,update on public.commercial_secret_reference_authorization_requests to service_role;
grant select on public.commercial_secret_reference_authorization_policies to service_role;
grant select on public.commercial_secret_reference_scope_rules to service_role;
grant select,insert on public.commercial_secret_reference_authorization_evaluations to service_role;
grant select,insert on public.commercial_secret_reference_authorization_decisions to service_role;
grant select,insert on public.commercial_secret_reference_authorization_receipts to service_role;
grant select,insert on public.commercial_secret_reference_authorization_events to service_role;
grant select on public.commercial_secret_reference_authorization_read_model to service_role;

revoke all on function public.append_commercial_secret_reference_authorization_receipt(text,uuid,uuid,text,text,text,text,uuid,jsonb) from public,anon,authenticated;
revoke all on function public.append_commercial_secret_reference_authorization_event(text,uuid,uuid,uuid,uuid,text,text,text,uuid,uuid,jsonb) from public,anon,authenticated;
revoke all on function public.enqueue_commercial_secret_reference_authorization_request(text,text,uuid,uuid,text,text,text,text,text,uuid,uuid,jsonb) from public,anon,authenticated;
revoke all on function public.evaluate_commercial_secret_reference_authorization_request(uuid,text) from public,anon,authenticated;

grant execute on function public.append_commercial_secret_reference_authorization_receipt(text,uuid,uuid,text,text,text,text,uuid,jsonb) to service_role;
grant execute on function public.append_commercial_secret_reference_authorization_event(text,uuid,uuid,uuid,uuid,text,text,text,uuid,uuid,jsonb) to service_role;
grant execute on function public.enqueue_commercial_secret_reference_authorization_request(text,text,uuid,uuid,text,text,text,text,text,uuid,uuid,jsonb) to service_role;
grant execute on function public.evaluate_commercial_secret_reference_authorization_request(uuid,text) to service_role;

-- =============================================================================
-- 14. FOUNDATION CERTIFICATION
-- =============================================================================

do $$
declare
  v_policy_count bigint;
  v_rule_count bigint;
  v_request_count bigint;
  v_evaluation_count bigint;
  v_decision_count bigint;
  v_receipt_count bigint;
  v_event_count bigint;
  v_policy public.commercial_secret_reference_authorization_policies;
begin
  select count(*) into v_policy_count
  from public.commercial_secret_reference_authorization_policies;

  select count(*) into v_rule_count
  from public.commercial_secret_reference_scope_rules;

  select count(*) into v_request_count
  from public.commercial_secret_reference_authorization_requests;

  select count(*) into v_evaluation_count
  from public.commercial_secret_reference_authorization_evaluations;

  select count(*) into v_decision_count
  from public.commercial_secret_reference_authorization_decisions;

  select count(*) into v_receipt_count
  from public.commercial_secret_reference_authorization_receipts;

  select count(*) into v_event_count
  from public.commercial_secret_reference_authorization_events;

  select * into strict v_policy
  from public.commercial_secret_reference_authorization_policies
  where policy_code='commercial:secret_reference_authorization:v1'
    and environment='production'
    and policy_status='approved';

  if v_policy_count<>1 or v_rule_count<>1 or v_request_count<>0
     or v_evaluation_count<>0 or v_decision_count<>0
     or v_receipt_count<>0 or v_event_count<>1 then
    raise exception
      'MIGRATION_131_COUNT_ASSERTION_FAILED policy=%, rule=%, request=%, evaluation=%, decision=%, receipt=%, event=%',
      v_policy_count,v_rule_count,v_request_count,v_evaluation_count,
      v_decision_count,v_receipt_count,v_event_count;
  end if;

  if v_policy.automatic_dispatch_enabled
     or v_policy.endpoint_discovery_enabled
     or v_policy.backend_probe_enabled
     or v_policy.backend_contact_enabled
     or v_policy.backend_authentication_enabled
     or v_policy.secret_lookup_enabled
     or v_policy.secret_resolution_enabled
     or v_policy.secret_decryption_enabled
     or v_policy.credential_material_loading_enabled
     or v_policy.credential_delivery_enabled
     or v_policy.network_access_enabled then
    raise exception 'MIGRATION_131_PASSIVE_POSTURE_ASSERTION_FAILED';
  end if;

  raise notice
    'MIGRATION_131_CERTIFIED policy_count=%, rule_count=%, request_count=%, evaluation_count=%, decision_count=%, receipt_count=%, event_count=%, intake_enabled=%, policy_evaluation_enabled=%, scope_enforcement_enabled=%, namespace_ownership_enabled=%, capability_enforcement_enabled=%, backend_trust_enforcement_enabled=%, binding_validation_enforcement_enabled=%, contract_validation_enabled=%, decision_recording_enabled=%, automatic_dispatch_enabled=f, endpoint_discovery_enabled=f, backend_probe_enabled=f, backend_contact_enabled=f, backend_authentication_enabled=f, secret_lookup_enabled=f, secret_resolution_enabled=f, secret_decryption_enabled=f, credential_material_loading_enabled=f, credential_delivery_enabled=f, network_access_enabled=f, opaque_references_only=true, plaintext_storage_forbidden=true',
    v_policy_count,v_rule_count,v_request_count,v_evaluation_count,
    v_decision_count,v_receipt_count,v_event_count,
    v_policy.intake_enabled,v_policy.policy_evaluation_enabled,
    v_policy.scope_enforcement_enabled,v_policy.namespace_ownership_enabled,
    v_policy.capability_enforcement_enabled,
    v_policy.backend_trust_enforcement_enabled,
    v_policy.binding_validation_enforcement_enabled,
    v_policy.contract_validation_enabled,v_policy.decision_recording_enabled;
end
$$;

commit;
