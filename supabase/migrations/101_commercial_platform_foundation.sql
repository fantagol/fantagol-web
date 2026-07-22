-- ============================================================================
-- FANTAGOL COMMERCIAL PLATFORM FOUNDATION
-- Migration: 101_commercial_platform_foundation.sql
-- Version: 1.0
-- Domain: Commercial Platform
--
-- Certified scope:
--   - Premium resource registry
--   - Single commercial wallet per user
--   - Immutable pass ledger
--   - Premium access sessions
--   - Atomic pass consumption + 15-minute access
--   - Backend-authoritative access verification
--   - RLS, grants, idempotency, audit events
--
-- Explicitly out of scope:
--   - Stripe / payment adapters
--   - Purchase orders
--   - Donations
--   - Advertising providers and rewarded-video callbacks
--   - Promotions and referral campaigns
-- ============================================================================

begin;

create extension if not exists pgcrypto;

-- ============================================================================
-- 1. PREMIUM RESOURCE REGISTRY
-- ============================================================================

create table if not exists public.premium_resources (
  id uuid primary key default gen_random_uuid(),
  resource_code text not null,
  title text not null,
  description text null,
  pass_cost integer not null default 1,
  session_duration_seconds integer not null default 900,
  enabled boolean not null default true,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default clock_timestamp(),
  updated_at timestamptz not null default clock_timestamp(),
  version integer not null default 1,

  constraint premium_resources_resource_code_key
    unique (resource_code),

  constraint premium_resources_resource_code_check
    check (
      resource_code = upper(resource_code)
      and resource_code ~ '^[A-Z][A-Z0-9_]{1,63}$'
    ),

  constraint premium_resources_title_check
    check (length(trim(title)) between 1 and 160),

  constraint premium_resources_pass_cost_check
    check (pass_cost > 0),

  constraint premium_resources_session_duration_check
    check (session_duration_seconds between 60 and 86400),

  constraint premium_resources_metadata_object_check
    check (jsonb_typeof(metadata) = 'object'),

  constraint premium_resources_version_check
    check (version > 0)
);

create index if not exists premium_resources_enabled_idx
  on public.premium_resources (enabled, resource_code);

comment on table public.premium_resources is
  'Configurable registry of premium resources. CONTROL_ROOM costs one Pass and grants a 900-second session.';

-- ============================================================================
-- 2. SINGLE COMMERCIAL WALLET
-- ============================================================================

create table if not exists public.commercial_wallets (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null,
  status text not null default 'active',
  available_passes integer not null default 0,
  lifetime_earned integer not null default 0,
  lifetime_consumed integer not null default 0,
  lifetime_purchased integer not null default 0,
  lifetime_rewarded integer not null default 0,
  lifetime_promotional integer not null default 0,
  ledger_version bigint not null default 0,
  created_at timestamptz not null default clock_timestamp(),
  updated_at timestamptz not null default clock_timestamp(),
  version integer not null default 1,

  constraint commercial_wallets_user_id_key
    unique (user_id),

  constraint commercial_wallets_user_id_fkey
    foreign key (user_id)
    references auth.users (id)
    on delete restrict,

  constraint commercial_wallets_status_check
    check (status in ('active', 'suspended', 'closed')),

  constraint commercial_wallets_available_passes_check
    check (available_passes >= 0),

  constraint commercial_wallets_lifetime_earned_check
    check (lifetime_earned >= 0),

  constraint commercial_wallets_lifetime_consumed_check
    check (lifetime_consumed >= 0),

  constraint commercial_wallets_lifetime_purchased_check
    check (lifetime_purchased >= 0),

  constraint commercial_wallets_lifetime_rewarded_check
    check (lifetime_rewarded >= 0),

  constraint commercial_wallets_lifetime_promotional_check
    check (lifetime_promotional >= 0),

  constraint commercial_wallets_ledger_version_check
    check (ledger_version >= 0),

  constraint commercial_wallets_version_check
    check (version > 0)
);

create index if not exists commercial_wallets_status_idx
  on public.commercial_wallets (status);

comment on table public.commercial_wallets is
  'Single operational Premium Pass wallet per user. Balance is a projection of the immutable commercial ledger.';

-- ============================================================================
-- 3. IMMUTABLE COMMERCIAL LEDGER
-- ============================================================================

create table if not exists public.commercial_ledger (
  id uuid primary key default gen_random_uuid(),
  wallet_id uuid not null,
  user_id uuid not null,
  transaction_type text not null,
  amount integer not null,
  balance_before integer not null,
  balance_after integer not null,
  ledger_sequence bigint not null,
  source_engine text not null,
  correlation_id uuid null,
  causation_id uuid null,
  idempotency_key text null,
  external_reference text null,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default clock_timestamp(),

  constraint commercial_ledger_wallet_id_fkey
    foreign key (wallet_id)
    references public.commercial_wallets (id)
    on delete restrict,

  constraint commercial_ledger_wallet_sequence_key
    unique (wallet_id, ledger_sequence),

  constraint commercial_ledger_transaction_type_check
    check (
      transaction_type in (
        'PASS_PURCHASE',
        'PASS_REWARD',
        'PASS_PROMOTION',
        'PASS_GIFT',
        'PASS_REFERRAL',
        'PASS_CONSUMPTION',
        'PASS_REFUND',
        'MANUAL_ADJUSTMENT'
      )
    ),

  constraint commercial_ledger_amount_check
    check (amount <> 0),

  constraint commercial_ledger_balance_before_check
    check (balance_before >= 0),

  constraint commercial_ledger_balance_after_check
    check (balance_after >= 0),

  constraint commercial_ledger_balance_arithmetic_check
    check (balance_after = balance_before + amount),

  constraint commercial_ledger_sequence_check
    check (ledger_sequence > 0),

  constraint commercial_ledger_source_engine_check
    check (
      length(trim(source_engine)) between 1 and 100
      and source_engine = lower(source_engine)
    ),

  constraint commercial_ledger_idempotency_key_check
    check (
      idempotency_key is null
      or length(trim(idempotency_key)) between 8 and 200
    ),

  constraint commercial_ledger_external_reference_check
    check (
      external_reference is null
      or length(trim(external_reference)) between 1 and 300
    ),

  constraint commercial_ledger_metadata_object_check
    check (jsonb_typeof(metadata) = 'object')
);

create unique index if not exists commercial_ledger_source_idempotency_uidx
  on public.commercial_ledger (source_engine, idempotency_key)
  where idempotency_key is not null;

create unique index if not exists commercial_ledger_source_external_reference_uidx
  on public.commercial_ledger (source_engine, external_reference)
  where external_reference is not null;

create index if not exists commercial_ledger_wallet_created_idx
  on public.commercial_ledger (wallet_id, created_at desc);

create index if not exists commercial_ledger_user_created_idx
  on public.commercial_ledger (user_id, created_at desc);

create index if not exists commercial_ledger_correlation_idx
  on public.commercial_ledger (correlation_id)
  where correlation_id is not null;

comment on table public.commercial_ledger is
  'Append-only source of truth for every Premium Pass movement. UPDATE and DELETE are forbidden.';

-- ============================================================================
-- 4. PREMIUM ACCESS SESSIONS
-- ============================================================================

create table if not exists public.premium_access_sessions (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null,
  wallet_id uuid not null,
  premium_resource_id uuid not null,
  resource_code text not null,
  ledger_transaction_id uuid not null,
  request_idempotency_key text not null,
  status text not null default 'active',
  pass_cost integer not null,
  duration_seconds integer not null,
  started_at timestamptz not null,
  expires_at timestamptz not null,
  revoked_at timestamptz null,
  revocation_reason text null,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default clock_timestamp(),
  updated_at timestamptz not null default clock_timestamp(),
  version integer not null default 1,

  constraint premium_access_sessions_wallet_id_fkey
    foreign key (wallet_id)
    references public.commercial_wallets (id)
    on delete restrict,

  constraint premium_access_sessions_resource_id_fkey
    foreign key (premium_resource_id)
    references public.premium_resources (id)
    on delete restrict,

  constraint premium_access_sessions_ledger_id_fkey
    foreign key (ledger_transaction_id)
    references public.commercial_ledger (id)
    on delete restrict,

  constraint premium_access_sessions_ledger_id_key
    unique (ledger_transaction_id),

  constraint premium_access_sessions_request_key
    unique (user_id, resource_code, request_idempotency_key),

  constraint premium_access_sessions_resource_code_check
    check (
      resource_code = upper(resource_code)
      and resource_code ~ '^[A-Z][A-Z0-9_]{1,63}$'
    ),

  constraint premium_access_sessions_request_idempotency_check
    check (length(trim(request_idempotency_key)) between 8 and 200),

  constraint premium_access_sessions_status_check
    check (status in ('active', 'expired', 'revoked')),

  constraint premium_access_sessions_pass_cost_check
    check (pass_cost > 0),

  constraint premium_access_sessions_duration_check
    check (duration_seconds between 60 and 86400),

  constraint premium_access_sessions_time_check
    check (expires_at > started_at),

  constraint premium_access_sessions_duration_consistency_check
    check (
      expires_at =
        started_at + make_interval(secs => duration_seconds)
    ),

  constraint premium_access_sessions_revocation_check
    check (
      (status = 'revoked' and revoked_at is not null)
      or
      (status <> 'revoked' and revoked_at is null)
    ),

  constraint premium_access_sessions_revocation_reason_check
    check (
      revocation_reason is null
      or length(trim(revocation_reason)) between 1 and 300
    ),

  constraint premium_access_sessions_metadata_object_check
    check (jsonb_typeof(metadata) = 'object'),

  constraint premium_access_sessions_version_check
    check (version > 0)
);

create unique index if not exists premium_access_sessions_one_active_uidx
  on public.premium_access_sessions (user_id, resource_code)
  where status = 'active';

create index if not exists premium_access_sessions_user_resource_idx
  on public.premium_access_sessions
    (user_id, resource_code, status, expires_at desc);

create index if not exists premium_access_sessions_expiry_idx
  on public.premium_access_sessions (expires_at)
  where status = 'active';

comment on table public.premium_access_sessions is
  'Backend-authoritative time-bounded access. One active session per user and premium resource.';

-- ============================================================================
-- 5. COMMERCIAL PLATFORM AUDIT EVENTS
-- ============================================================================

create table if not exists public.commercial_platform_events (
  id uuid primary key default gen_random_uuid(),
  event_type text not null,
  aggregate_type text not null,
  aggregate_id uuid not null,
  user_id uuid null,
  correlation_id uuid null,
  causation_id uuid null,
  event_version integer not null default 1,
  payload jsonb not null default '{}'::jsonb,
  occurred_at timestamptz not null default clock_timestamp(),
  created_at timestamptz not null default clock_timestamp(),

  constraint commercial_platform_events_event_type_check
    check (
      length(trim(event_type)) between 1 and 120
      and event_type = upper(event_type)
    ),

  constraint commercial_platform_events_aggregate_type_check
    check (
      aggregate_type in (
        'COMMERCIAL_WALLET',
        'COMMERCIAL_LEDGER',
        'PREMIUM_ACCESS_SESSION',
        'PREMIUM_RESOURCE'
      )
    ),

  constraint commercial_platform_events_event_version_check
    check (event_version > 0),

  constraint commercial_platform_events_payload_object_check
    check (jsonb_typeof(payload) = 'object')
);

create index if not exists commercial_platform_events_aggregate_idx
  on public.commercial_platform_events
    (aggregate_type, aggregate_id, occurred_at desc);

create index if not exists commercial_platform_events_user_idx
  on public.commercial_platform_events (user_id, occurred_at desc)
  where user_id is not null;

create index if not exists commercial_platform_events_correlation_idx
  on public.commercial_platform_events (correlation_id)
  where correlation_id is not null;

comment on table public.commercial_platform_events is
  'Append-only operational and domain timeline for the Commercial Platform.';

-- ============================================================================
-- 6. COMMON UPDATED_AT TRIGGER
-- ============================================================================

create or replace function public.commercial_set_updated_at()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
  new.updated_at := clock_timestamp();
  new.version := old.version + 1;
  return new;
end;
$$;

drop trigger if exists premium_resources_set_updated_at
  on public.premium_resources;

create trigger premium_resources_set_updated_at
before update on public.premium_resources
for each row execute function public.commercial_set_updated_at();

drop trigger if exists commercial_wallets_set_updated_at
  on public.commercial_wallets;

create trigger commercial_wallets_set_updated_at
before update on public.commercial_wallets
for each row execute function public.commercial_set_updated_at();

drop trigger if exists premium_access_sessions_set_updated_at
  on public.premium_access_sessions;

create trigger premium_access_sessions_set_updated_at
before update on public.premium_access_sessions
for each row execute function public.commercial_set_updated_at();

-- ============================================================================
-- 7. IMMUTABILITY AND INTERNAL-WRITE GUARDS
-- ============================================================================

create or replace function public.prevent_commercial_append_only_mutation()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
  raise exception using
    errcode = 'P0001',
    message = 'COMMERCIAL_APPEND_ONLY_VIOLATION',
    detail = format(
      'UPDATE or DELETE is forbidden on append-only relation %I.%I.',
      tg_table_schema,
      tg_table_name
    );
end;
$$;

drop trigger if exists commercial_ledger_append_only_guard
  on public.commercial_ledger;

create trigger commercial_ledger_append_only_guard
before update or delete on public.commercial_ledger
for each row execute function public.prevent_commercial_append_only_mutation();

drop trigger if exists commercial_platform_events_append_only_guard
  on public.commercial_platform_events;

create trigger commercial_platform_events_append_only_guard
before update or delete on public.commercial_platform_events
for each row execute function public.prevent_commercial_append_only_mutation();

create or replace function public.guard_commercial_internal_insert()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
  if coalesce(
    current_setting('fantagol.commercial_internal_write', true),
    'off'
  ) <> 'on' then
    raise exception using
      errcode = 'P0001',
      message = 'COMMERCIAL_INTERNAL_WRITE_REQUIRED';
  end if;

  return new;
end;
$$;

drop trigger if exists commercial_ledger_internal_insert_guard
  on public.commercial_ledger;

create trigger commercial_ledger_internal_insert_guard
before insert on public.commercial_ledger
for each row execute function public.guard_commercial_internal_insert();

drop trigger if exists commercial_platform_events_internal_insert_guard
  on public.commercial_platform_events;

create trigger commercial_platform_events_internal_insert_guard
before insert on public.commercial_platform_events
for each row execute function public.guard_commercial_internal_insert();

create or replace function public.guard_commercial_wallet_projection_update()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
  if (
    new.available_passes is distinct from old.available_passes
    or new.lifetime_earned is distinct from old.lifetime_earned
    or new.lifetime_consumed is distinct from old.lifetime_consumed
    or new.lifetime_purchased is distinct from old.lifetime_purchased
    or new.lifetime_rewarded is distinct from old.lifetime_rewarded
    or new.lifetime_promotional is distinct from old.lifetime_promotional
    or new.ledger_version is distinct from old.ledger_version
  ) and coalesce(
    current_setting('fantagol.commercial_internal_write', true),
    'off'
  ) <> 'on' then
    raise exception using
      errcode = 'P0001',
      message = 'COMMERCIAL_WALLET_PROJECTION_WRITE_FORBIDDEN';
  end if;

  return new;
end;
$$;

drop trigger if exists commercial_wallets_projection_guard
  on public.commercial_wallets;

create trigger commercial_wallets_projection_guard
before update on public.commercial_wallets
for each row execute function public.guard_commercial_wallet_projection_update();

create or replace function public.guard_premium_session_mutation()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
  if (
    new.user_id is distinct from old.user_id
    or new.wallet_id is distinct from old.wallet_id
    or new.premium_resource_id is distinct from old.premium_resource_id
    or new.resource_code is distinct from old.resource_code
    or new.ledger_transaction_id is distinct from old.ledger_transaction_id
    or new.request_idempotency_key is distinct from old.request_idempotency_key
    or new.pass_cost is distinct from old.pass_cost
    or new.duration_seconds is distinct from old.duration_seconds
    or new.started_at is distinct from old.started_at
    or new.expires_at is distinct from old.expires_at
    or new.created_at is distinct from old.created_at
  ) then
    raise exception using
      errcode = 'P0001',
      message = 'PREMIUM_ACCESS_SESSION_IDENTITY_IMMUTABLE';
  end if;

  if old.status <> new.status then
    if old.status <> 'active'
       or new.status not in ('expired', 'revoked') then
      raise exception using
        errcode = 'P0001',
        message = 'PREMIUM_ACCESS_SESSION_INVALID_TRANSITION';
    end if;
  end if;

  return new;
end;
$$;

drop trigger if exists premium_access_sessions_mutation_guard
  on public.premium_access_sessions;

create trigger premium_access_sessions_mutation_guard
before update on public.premium_access_sessions
for each row execute function public.guard_premium_session_mutation();

-- ============================================================================
-- 8. INTERNAL HELPERS
-- ============================================================================

create or replace function public.commercial_assert_authenticated_user()
returns uuid
language plpgsql
stable
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_user_id uuid;
begin
  v_user_id := auth.uid();

  if v_user_id is null then
    raise exception using
      errcode = '42501',
      message = 'COMMERCIAL_AUTHENTICATION_REQUIRED';
  end if;

  return v_user_id;
end;
$$;

create or replace function public.commercial_get_or_create_wallet(
  p_user_id uuid
)
returns public.commercial_wallets
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_wallet public.commercial_wallets;
begin
  if p_user_id is null then
    raise exception using
      errcode = '22004',
      message = 'COMMERCIAL_USER_ID_REQUIRED';
  end if;

  insert into public.commercial_wallets (user_id)
  values (p_user_id)
  on conflict (user_id) do nothing;

  select *
  into strict v_wallet
  from public.commercial_wallets
  where user_id = p_user_id;

  return v_wallet;
end;
$$;

create or replace function public.commercial_append_event_internal(
  p_event_type text,
  p_aggregate_type text,
  p_aggregate_id uuid,
  p_user_id uuid,
  p_correlation_id uuid,
  p_causation_id uuid,
  p_payload jsonb default '{}'::jsonb
)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_event_id uuid;
begin
  perform set_config(
    'fantagol.commercial_internal_write',
    'on',
    true
  );

  insert into public.commercial_platform_events (
    event_type,
    aggregate_type,
    aggregate_id,
    user_id,
    correlation_id,
    causation_id,
    payload
  )
  values (
    upper(trim(p_event_type)),
    upper(trim(p_aggregate_type)),
    p_aggregate_id,
    p_user_id,
    p_correlation_id,
    p_causation_id,
    coalesce(p_payload, '{}'::jsonb)
  )
  returning id into v_event_id;

  return v_event_id;
end;
$$;

create or replace function public.commercial_append_ledger_internal(
  p_user_id uuid,
  p_transaction_type text,
  p_amount integer,
  p_source_engine text,
  p_correlation_id uuid default null,
  p_causation_id uuid default null,
  p_idempotency_key text default null,
  p_external_reference text default null,
  p_metadata jsonb default '{}'::jsonb
)
returns public.commercial_ledger
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_wallet public.commercial_wallets;
  v_existing public.commercial_ledger;
  v_ledger public.commercial_ledger;
  v_transaction_type text := upper(trim(p_transaction_type));
  v_source_engine text := lower(trim(p_source_engine));
  v_idempotency_key text := nullif(trim(p_idempotency_key), '');
  v_external_reference text := nullif(trim(p_external_reference), '');
  v_balance_after integer;
  v_lifetime_earned_delta integer := 0;
  v_lifetime_consumed_delta integer := 0;
  v_lifetime_purchased_delta integer := 0;
  v_lifetime_rewarded_delta integer := 0;
  v_lifetime_promotional_delta integer := 0;
begin
  if p_user_id is null then
    raise exception using
      errcode = '22004',
      message = 'COMMERCIAL_USER_ID_REQUIRED';
  end if;

  if p_amount is null or p_amount = 0 then
    raise exception using
      errcode = '22023',
      message = 'COMMERCIAL_LEDGER_AMOUNT_INVALID';
  end if;

  if v_source_engine is null or v_source_engine = '' then
    raise exception using
      errcode = '22023',
      message = 'COMMERCIAL_SOURCE_ENGINE_REQUIRED';
  end if;

  if jsonb_typeof(coalesce(p_metadata, '{}'::jsonb)) <> 'object' then
    raise exception using
      errcode = '22023',
      message = 'COMMERCIAL_METADATA_MUST_BE_OBJECT';
  end if;

  if v_idempotency_key is not null then
    select *
    into v_existing
    from public.commercial_ledger
    where source_engine = v_source_engine
      and idempotency_key = v_idempotency_key;

    if found then
      if v_existing.user_id is distinct from p_user_id
         or v_existing.transaction_type is distinct from v_transaction_type
         or v_existing.amount is distinct from p_amount
         or v_existing.external_reference
              is distinct from v_external_reference then
        raise exception using
          errcode = '23505',
          message = 'COMMERCIAL_IDEMPOTENCY_CONFLICT';
      end if;

      return v_existing;
    end if;
  end if;

  perform public.commercial_get_or_create_wallet(p_user_id);

  select *
  into strict v_wallet
  from public.commercial_wallets
  where user_id = p_user_id
  for update;

  if v_wallet.status <> 'active' then
    raise exception using
      errcode = 'P0001',
      message = 'COMMERCIAL_WALLET_NOT_ACTIVE';
  end if;

  v_balance_after := v_wallet.available_passes + p_amount;

  if v_balance_after < 0 then
    raise exception using
      errcode = 'P0001',
      message = 'COMMERCIAL_INSUFFICIENT_PASSES';
  end if;

  if p_amount > 0 then
    v_lifetime_earned_delta := p_amount;
  else
    v_lifetime_consumed_delta := abs(p_amount);
  end if;

  if v_transaction_type = 'PASS_PURCHASE' and p_amount > 0 then
    v_lifetime_purchased_delta := p_amount;
  elsif v_transaction_type = 'PASS_REWARD' and p_amount > 0 then
    v_lifetime_rewarded_delta := p_amount;
  elsif v_transaction_type in (
    'PASS_PROMOTION',
    'PASS_GIFT',
    'PASS_REFERRAL'
  ) and p_amount > 0 then
    v_lifetime_promotional_delta := p_amount;
  end if;

  perform set_config(
    'fantagol.commercial_internal_write',
    'on',
    true
  );

  insert into public.commercial_ledger (
    wallet_id,
    user_id,
    transaction_type,
    amount,
    balance_before,
    balance_after,
    ledger_sequence,
    source_engine,
    correlation_id,
    causation_id,
    idempotency_key,
    external_reference,
    metadata
  )
  values (
    v_wallet.id,
    p_user_id,
    v_transaction_type,
    p_amount,
    v_wallet.available_passes,
    v_balance_after,
    v_wallet.ledger_version + 1,
    v_source_engine,
    p_correlation_id,
    p_causation_id,
    v_idempotency_key,
    v_external_reference,
    coalesce(p_metadata, '{}'::jsonb)
  )
  returning * into v_ledger;

  update public.commercial_wallets
  set
    available_passes = v_balance_after,
    lifetime_earned =
      lifetime_earned + v_lifetime_earned_delta,
    lifetime_consumed =
      lifetime_consumed + v_lifetime_consumed_delta,
    lifetime_purchased =
      lifetime_purchased + v_lifetime_purchased_delta,
    lifetime_rewarded =
      lifetime_rewarded + v_lifetime_rewarded_delta,
    lifetime_promotional =
      lifetime_promotional + v_lifetime_promotional_delta,
    ledger_version = ledger_version + 1
  where id = v_wallet.id;

  perform public.commercial_append_event_internal(
    'COMMERCIAL_LEDGER_ENTRY_APPENDED',
    'COMMERCIAL_LEDGER',
    v_ledger.id,
    p_user_id,
    p_correlation_id,
    p_causation_id,
    jsonb_build_object(
      'wallet_id', v_wallet.id,
      'transaction_type', v_transaction_type,
      'amount', p_amount,
      'balance_before', v_wallet.available_passes,
      'balance_after', v_balance_after,
      'ledger_sequence', v_ledger.ledger_sequence,
      'source_engine', v_source_engine
    )
  );

  return v_ledger;
end;
$$;

-- Internal operator/service helper.
-- It is intentionally NOT granted to authenticated or anon.
create or replace function public.grant_commercial_passes_internal(
  p_user_id uuid,
  p_amount integer,
  p_transaction_type text default 'MANUAL_ADJUSTMENT',
  p_idempotency_key text default null,
  p_external_reference text default null,
  p_metadata jsonb default '{}'::jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_ledger public.commercial_ledger;
begin
  if p_amount is null or p_amount <= 0 then
    raise exception using
      errcode = '22023',
      message = 'COMMERCIAL_GRANT_AMOUNT_MUST_BE_POSITIVE';
  end if;

  v_ledger := public.commercial_append_ledger_internal(
    p_user_id,
    p_transaction_type,
    p_amount,
    'commercial_platform',
    gen_random_uuid(),
    null,
    p_idempotency_key,
    p_external_reference,
    coalesce(p_metadata, '{}'::jsonb)
  );

  return jsonb_build_object(
    'granted', true,
    'ledger_id', v_ledger.id,
    'user_id', v_ledger.user_id,
    'amount', v_ledger.amount,
    'available_passes', v_ledger.balance_after
  );
end;
$$;

-- ============================================================================
-- 9. PUBLIC AUTHENTICATED RPC: WALLET
-- ============================================================================

create or replace function public.get_my_commercial_wallet_rpc()
returns jsonb
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_user_id uuid;
  v_wallet public.commercial_wallets;
begin
  v_user_id := public.commercial_assert_authenticated_user();
  v_wallet := public.commercial_get_or_create_wallet(v_user_id);

  return jsonb_build_object(
    'available', true,
    'wallet_id', v_wallet.id,
    'status', v_wallet.status,
    'available_passes', v_wallet.available_passes,
    'lifetime_earned', v_wallet.lifetime_earned,
    'lifetime_consumed', v_wallet.lifetime_consumed,
    'lifetime_purchased', v_wallet.lifetime_purchased,
    'lifetime_rewarded', v_wallet.lifetime_rewarded,
    'lifetime_promotional', v_wallet.lifetime_promotional,
    'ledger_version', v_wallet.ledger_version,
    'server_time', clock_timestamp()
  );
end;
$$;

create or replace function public.get_my_commercial_ledger_rpc(
  p_limit integer default 50,
  p_offset integer default 0
)
returns table (
  ledger_id uuid,
  transaction_type text,
  amount integer,
  balance_before integer,
  balance_after integer,
  source_engine text,
  external_reference text,
  metadata jsonb,
  created_at timestamptz
)
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_user_id uuid;
  v_limit integer;
  v_offset integer;
begin
  v_user_id := public.commercial_assert_authenticated_user();
  v_limit := least(greatest(coalesce(p_limit, 50), 1), 200);
  v_offset := greatest(coalesce(p_offset, 0), 0);

  return query
  select
    l.id,
    l.transaction_type,
    l.amount,
    l.balance_before,
    l.balance_after,
    l.source_engine,
    l.external_reference,
    l.metadata,
    l.created_at
  from public.commercial_ledger l
  where l.user_id = v_user_id
  order by l.ledger_sequence desc
  limit v_limit
  offset v_offset;
end;
$$;

-- ============================================================================
-- 10. PUBLIC AUTHENTICATED RPC: ACCESS STATUS
-- ============================================================================

create or replace function public.get_my_premium_access_status_rpc(
  p_resource_code text
)
returns jsonb
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_user_id uuid;
  v_resource public.premium_resources;
  v_session public.premium_access_sessions;
  v_wallet public.commercial_wallets;
  v_now timestamptz := clock_timestamp();
  v_remaining_seconds integer := 0;
  v_has_active_session boolean := false;
begin
  v_user_id := public.commercial_assert_authenticated_user();

  select *
  into v_resource
  from public.premium_resources
  where resource_code = upper(trim(p_resource_code))
    and enabled = true;

  if not found then
    return jsonb_build_object(
      'authorized', false,
      'error_code', 'PREMIUM_RESOURCE_NOT_AVAILABLE',
      'resource_code', upper(trim(p_resource_code)),
      'server_time', v_now
    );
  end if;

  perform public.commercial_get_or_create_wallet(v_user_id);

  update public.premium_access_sessions
  set status = 'expired'
  where user_id = v_user_id
    and resource_code = v_resource.resource_code
    and status = 'active'
    and expires_at <= v_now;

  select *
  into v_session
  from public.premium_access_sessions
  where user_id = v_user_id
    and resource_code = v_resource.resource_code
    and status = 'active'
    and expires_at > v_now
  order by started_at desc
  limit 1;

  v_has_active_session := found;

  select *
  into strict v_wallet
  from public.commercial_wallets
  where user_id = v_user_id;

  if v_has_active_session then
    v_remaining_seconds := greatest(
      0,
      ceil(extract(epoch from (v_session.expires_at - v_now)))::integer
    );

    return jsonb_build_object(
      'authorized', true,
      'session_id', v_session.id,
      'resource_code', v_resource.resource_code,
      'title', v_resource.title,
      'started_at', v_session.started_at,
      'expires_at', v_session.expires_at,
      'server_time', v_now,
      'remaining_seconds', v_remaining_seconds,
      'available_passes', v_wallet.available_passes,
      'pass_cost', v_session.pass_cost,
      'duration_seconds', v_session.duration_seconds
    );
  end if;

  return jsonb_build_object(
    'authorized', false,
    'error_code', 'PREMIUM_ACCESS_SESSION_REQUIRED',
    'resource_code', v_resource.resource_code,
    'title', v_resource.title,
    'server_time', v_now,
    'remaining_seconds', 0,
    'available_passes', v_wallet.available_passes,
    'pass_cost', v_resource.pass_cost,
    'duration_seconds', v_resource.session_duration_seconds
  );
end;
$$;

-- ============================================================================
-- 11. PUBLIC AUTHENTICATED RPC: START OR REUSE SESSION
-- ============================================================================

create or replace function public.start_my_premium_access_session_rpc(
  p_resource_code text,
  p_idempotency_key text
)
returns jsonb
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_user_id uuid;
  v_resource public.premium_resources;
  v_wallet public.commercial_wallets;
  v_existing_session public.premium_access_sessions;
  v_session public.premium_access_sessions;
  v_ledger public.commercial_ledger;
  v_now timestamptz := clock_timestamp();
  v_request_key text := nullif(trim(p_idempotency_key), '');
  v_correlation_id uuid := gen_random_uuid();
  v_remaining_seconds integer;
begin
  v_user_id := public.commercial_assert_authenticated_user();

  if v_request_key is null
     or length(v_request_key) < 8
     or length(v_request_key) > 200 then
    raise exception using
      errcode = '22023',
      message = 'PREMIUM_ACCESS_IDEMPOTENCY_KEY_INVALID';
  end if;

  select *
  into v_resource
  from public.premium_resources
  where resource_code = upper(trim(p_resource_code))
    and enabled = true;

  if not found then
    return jsonb_build_object(
      'authorized', false,
      'error_code', 'PREMIUM_RESOURCE_NOT_AVAILABLE',
      'resource_code', upper(trim(p_resource_code)),
      'server_time', v_now
    );
  end if;

  -- Serialize every commercial mutation for the same user.
  perform pg_advisory_xact_lock(
    hashtextextended('commercial-wallet:' || v_user_id::text, 0)
  );

  -- Strict request idempotency: the same request returns the same artifact.
  select *
  into v_existing_session
  from public.premium_access_sessions
  where user_id = v_user_id
    and resource_code = v_resource.resource_code
    and request_idempotency_key = v_request_key;

  if found then
    if v_existing_session.status = 'active'
       and v_existing_session.expires_at <= v_now then
      update public.premium_access_sessions
      set status = 'expired'
      where id = v_existing_session.id
      returning * into v_existing_session;
    end if;

    select *
    into strict v_wallet
    from public.commercial_wallets
    where id = v_existing_session.wallet_id;

    v_remaining_seconds := case
      when v_existing_session.status = 'active'
       and v_existing_session.expires_at > v_now
      then greatest(
        0,
        ceil(
          extract(epoch from (v_existing_session.expires_at - v_now))
        )::integer
      )
      else 0
    end;

    return jsonb_build_object(
      'authorized',
        v_existing_session.status = 'active'
        and v_existing_session.expires_at > v_now,
      'reused_existing_session', true,
      'pass_consumed', false,
      'session_id', v_existing_session.id,
      'session_status', v_existing_session.status,
      'resource_code', v_existing_session.resource_code,
      'started_at', v_existing_session.started_at,
      'expires_at', v_existing_session.expires_at,
      'server_time', v_now,
      'remaining_seconds', v_remaining_seconds,
      'available_passes', v_wallet.available_passes,
      'ledger_id', v_existing_session.ledger_transaction_id,
      'error_code', case
        when v_existing_session.status = 'active'
         and v_existing_session.expires_at > v_now
        then null
        else 'PREMIUM_ACCESS_REQUEST_ALREADY_COMPLETED'
      end
    );
  end if;

  perform public.commercial_get_or_create_wallet(v_user_id);

  select *
  into strict v_wallet
  from public.commercial_wallets
  where user_id = v_user_id
  for update;

  if v_wallet.status <> 'active' then
    return jsonb_build_object(
      'authorized', false,
      'error_code', 'COMMERCIAL_WALLET_NOT_ACTIVE',
      'resource_code', v_resource.resource_code,
      'server_time', v_now,
      'available_passes', v_wallet.available_passes
    );
  end if;

  -- Close stale active rows before checking for a reusable session.
  update public.premium_access_sessions
  set status = 'expired'
  where user_id = v_user_id
    and resource_code = v_resource.resource_code
    and status = 'active'
    and expires_at <= v_now;

  -- A second tab/device reuses the current session and consumes no Pass.
  select *
  into v_existing_session
  from public.premium_access_sessions
  where user_id = v_user_id
    and resource_code = v_resource.resource_code
    and status = 'active'
    and expires_at > v_now
  order by started_at desc
  limit 1;

  if found then
    v_remaining_seconds := greatest(
      0,
      ceil(
        extract(epoch from (v_existing_session.expires_at - v_now))
      )::integer
    );

    return jsonb_build_object(
      'authorized', true,
      'reused_existing_session', true,
      'pass_consumed', false,
      'session_id', v_existing_session.id,
      'session_status', v_existing_session.status,
      'resource_code', v_existing_session.resource_code,
      'started_at', v_existing_session.started_at,
      'expires_at', v_existing_session.expires_at,
      'server_time', v_now,
      'remaining_seconds', v_remaining_seconds,
      'available_passes', v_wallet.available_passes,
      'ledger_id', v_existing_session.ledger_transaction_id
    );
  end if;

  if v_wallet.available_passes < v_resource.pass_cost then
    return jsonb_build_object(
      'authorized', false,
      'error_code', 'COMMERCIAL_INSUFFICIENT_PASSES',
      'resource_code', v_resource.resource_code,
      'server_time', v_now,
      'remaining_seconds', 0,
      'available_passes', v_wallet.available_passes,
      'required_passes', v_resource.pass_cost
    );
  end if;

  v_ledger := public.commercial_append_ledger_internal(
    v_user_id,
    'PASS_CONSUMPTION',
    -v_resource.pass_cost,
    'premium_access_engine',
    v_correlation_id,
    null,
    'premium-session-debit:' || v_user_id::text || ':' ||
      v_resource.resource_code || ':' || v_request_key,
    null,
    jsonb_build_object(
      'resource_id', v_resource.id,
      'resource_code', v_resource.resource_code,
      'duration_seconds', v_resource.session_duration_seconds,
      'request_idempotency_key', v_request_key
    )
  );

  insert into public.premium_access_sessions (
    user_id,
    wallet_id,
    premium_resource_id,
    resource_code,
    ledger_transaction_id,
    request_idempotency_key,
    status,
    pass_cost,
    duration_seconds,
    started_at,
    expires_at,
    metadata
  )
  values (
    v_user_id,
    v_wallet.id,
    v_resource.id,
    v_resource.resource_code,
    v_ledger.id,
    v_request_key,
    'active',
    v_resource.pass_cost,
    v_resource.session_duration_seconds,
    v_now,
    v_now + make_interval(
      secs => v_resource.session_duration_seconds
    ),
    jsonb_build_object(
      'correlation_id', v_correlation_id,
      'source', 'start_my_premium_access_session_rpc'
    )
  )
  returning * into v_session;

  perform public.commercial_append_event_internal(
    'PREMIUM_ACCESS_SESSION_CREATED',
    'PREMIUM_ACCESS_SESSION',
    v_session.id,
    v_user_id,
    v_correlation_id,
    v_ledger.id,
    jsonb_build_object(
      'resource_id', v_resource.id,
      'resource_code', v_resource.resource_code,
      'pass_cost', v_session.pass_cost,
      'duration_seconds', v_session.duration_seconds,
      'started_at', v_session.started_at,
      'expires_at', v_session.expires_at,
      'ledger_transaction_id', v_ledger.id
    )
  );

  return jsonb_build_object(
    'authorized', true,
    'reused_existing_session', false,
    'pass_consumed', true,
    'session_id', v_session.id,
    'session_status', v_session.status,
    'resource_code', v_session.resource_code,
    'started_at', v_session.started_at,
    'expires_at', v_session.expires_at,
    'server_time', v_now,
    'remaining_seconds', v_session.duration_seconds,
    'available_passes', v_ledger.balance_after,
    'ledger_id', v_ledger.id
  );
end;
$$;

-- ============================================================================
-- 12. SERVICE RPC: REVOKE SESSION
-- ============================================================================

create or replace function public.revoke_premium_access_session_internal(
  p_session_id uuid,
  p_reason text,
  p_correlation_id uuid default gen_random_uuid()
)
returns jsonb
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_session public.premium_access_sessions;
  v_reason text := nullif(trim(p_reason), '');
begin
  if v_reason is null then
    raise exception using
      errcode = '22023',
      message = 'PREMIUM_SESSION_REVOCATION_REASON_REQUIRED';
  end if;

  select *
  into v_session
  from public.premium_access_sessions
  where id = p_session_id
  for update;

  if not found then
    return jsonb_build_object(
      'revoked', false,
      'error_code', 'PREMIUM_ACCESS_SESSION_NOT_FOUND',
      'session_id', p_session_id
    );
  end if;

  if v_session.status = 'revoked' then
    return jsonb_build_object(
      'revoked', true,
      'already_revoked', true,
      'session_id', v_session.id,
      'revoked_at', v_session.revoked_at
    );
  end if;

  if v_session.status = 'expired' then
    return jsonb_build_object(
      'revoked', false,
      'error_code', 'PREMIUM_ACCESS_SESSION_ALREADY_EXPIRED',
      'session_id', v_session.id
    );
  end if;

  update public.premium_access_sessions
  set
    status = 'revoked',
    revoked_at = clock_timestamp(),
    revocation_reason = v_reason
  where id = v_session.id
  returning * into v_session;

  perform public.commercial_append_event_internal(
    'PREMIUM_ACCESS_SESSION_REVOKED',
    'PREMIUM_ACCESS_SESSION',
    v_session.id,
    v_session.user_id,
    p_correlation_id,
    null,
    jsonb_build_object(
      'resource_code', v_session.resource_code,
      'reason', v_reason,
      'revoked_at', v_session.revoked_at
    )
  );

  return jsonb_build_object(
    'revoked', true,
    'already_revoked', false,
    'session_id', v_session.id,
    'revoked_at', v_session.revoked_at,
    'reason', v_reason
  );
end;
$$;

-- ============================================================================
-- 13. ROW LEVEL SECURITY
-- ============================================================================

alter table public.premium_resources enable row level security;
alter table public.commercial_wallets enable row level security;
alter table public.commercial_ledger enable row level security;
alter table public.premium_access_sessions enable row level security;
alter table public.commercial_platform_events enable row level security;

drop policy if exists premium_resources_authenticated_read
  on public.premium_resources;

create policy premium_resources_authenticated_read
on public.premium_resources
for select
to authenticated
using (enabled = true);

drop policy if exists commercial_wallets_owner_read
  on public.commercial_wallets;

create policy commercial_wallets_owner_read
on public.commercial_wallets
for select
to authenticated
using (user_id = auth.uid());

drop policy if exists commercial_ledger_owner_read
  on public.commercial_ledger;

create policy commercial_ledger_owner_read
on public.commercial_ledger
for select
to authenticated
using (user_id = auth.uid());

drop policy if exists premium_access_sessions_owner_read
  on public.premium_access_sessions;

create policy premium_access_sessions_owner_read
on public.premium_access_sessions
for select
to authenticated
using (user_id = auth.uid());

-- Commercial events remain backend-only in v1.

-- ============================================================================
-- 14. PRIVILEGES
-- ============================================================================

revoke all on table public.premium_resources from anon, authenticated;
revoke all on table public.commercial_wallets from anon, authenticated;
revoke all on table public.commercial_ledger from anon, authenticated;
revoke all on table public.premium_access_sessions from anon, authenticated;
revoke all on table public.commercial_platform_events from anon, authenticated;

grant select on table public.premium_resources to authenticated;
grant select on table public.commercial_wallets to authenticated;
grant select on table public.commercial_ledger to authenticated;
grant select on table public.premium_access_sessions to authenticated;

grant all on table public.premium_resources to service_role;
grant all on table public.commercial_wallets to service_role;
grant all on table public.commercial_ledger to service_role;
grant all on table public.premium_access_sessions to service_role;
grant all on table public.commercial_platform_events to service_role;

revoke all on function public.commercial_assert_authenticated_user()
  from public, anon, authenticated;

revoke all on function public.commercial_get_or_create_wallet(uuid)
  from public, anon, authenticated;

revoke all on function public.commercial_append_event_internal(
  text, text, uuid, uuid, uuid, uuid, jsonb
) from public, anon, authenticated;

revoke all on function public.commercial_append_ledger_internal(
  uuid, text, integer, text, uuid, uuid, text, text, jsonb
) from public, anon, authenticated;

revoke all on function public.grant_commercial_passes_internal(
  uuid, integer, text, text, text, jsonb
) from public, anon, authenticated;

revoke all on function public.revoke_premium_access_session_internal(
  uuid, text, uuid
) from public, anon, authenticated;

revoke all on function public.get_my_commercial_wallet_rpc()
  from public, anon;

revoke all on function public.get_my_commercial_ledger_rpc(
  integer, integer
) from public, anon;

revoke all on function public.get_my_premium_access_status_rpc(text)
  from public, anon;

revoke all on function public.start_my_premium_access_session_rpc(
  text, text
) from public, anon;

grant execute on function public.get_my_commercial_wallet_rpc()
  to authenticated;

grant execute on function public.get_my_commercial_ledger_rpc(
  integer, integer
) to authenticated;

grant execute on function public.get_my_premium_access_status_rpc(text)
  to authenticated;

grant execute on function public.start_my_premium_access_session_rpc(
  text, text
) to authenticated;

grant execute on function public.grant_commercial_passes_internal(
  uuid, integer, text, text, text, jsonb
) to service_role;

grant execute on function public.revoke_premium_access_session_internal(
  uuid, text, uuid
) to service_role;

-- Ensure helpers remain available to their SECURITY DEFINER callers.
grant execute on function public.commercial_assert_authenticated_user()
  to service_role;

grant execute on function public.commercial_get_or_create_wallet(uuid)
  to service_role;

grant execute on function public.commercial_append_event_internal(
  text, text, uuid, uuid, uuid, uuid, jsonb
) to service_role;

grant execute on function public.commercial_append_ledger_internal(
  uuid, text, integer, text, uuid, uuid, text, text, jsonb
) to service_role;

-- ============================================================================
-- 15. CONTROL ROOM RESOURCE SEED
-- ============================================================================

insert into public.premium_resources (
  resource_code,
  title,
  description,
  pass_cost,
  session_duration_seconds,
  enabled,
  metadata
)
values (
  'CONTROL_ROOM',
  'Control Room',
  'Community Intelligence premium access session.',
  1,
  900,
  true,
  jsonb_build_object(
    'foundation_version', '1.0',
    'access_model', 'one_pass_one_session',
    'kick_out_at_expiry', true
  )
)
on conflict (resource_code) do update
set
  title = excluded.title,
  description = excluded.description,
  pass_cost = excluded.pass_cost,
  session_duration_seconds = excluded.session_duration_seconds,
  enabled = excluded.enabled,
  metadata = excluded.metadata;

-- ============================================================================
-- 16. DOCUMENTATION COMMENTS
-- ============================================================================

comment on function public.get_my_commercial_wallet_rpc() is
  'Returns the authenticated user single-wallet projection. Creates an empty wallet when absent.';

comment on function public.get_my_commercial_ledger_rpc(integer, integer) is
  'Returns the authenticated user immutable Premium Pass ledger history.';

comment on function public.get_my_premium_access_status_rpc(text) is
  'Returns backend-authoritative access status and remaining seconds for one premium resource.';

comment on function public.start_my_premium_access_session_rpc(text, text) is
  'Atomically reuses an active session or consumes Passes and creates a new time-bounded premium session.';

comment on function public.grant_commercial_passes_internal(
  uuid, integer, text, text, text, jsonb
) is
  'Backend-only helper for certified credits. Future Purchase, Reward and Promotion engines must call this path or its versioned successor.';

-- ============================================================================
-- 17. FOUNDATION ASSERTIONS
-- ============================================================================

do $$
declare
  v_control_room public.premium_resources;
begin
  select *
  into strict v_control_room
  from public.premium_resources
  where resource_code = 'CONTROL_ROOM';

  if v_control_room.pass_cost <> 1 then
    raise exception 'COMMERCIAL_FOUNDATION_ASSERTION_FAILED: CONTROL_ROOM pass_cost';
  end if;

  if v_control_room.session_duration_seconds <> 900 then
    raise exception 'COMMERCIAL_FOUNDATION_ASSERTION_FAILED: CONTROL_ROOM duration';
  end if;

  if not v_control_room.enabled then
    raise exception 'COMMERCIAL_FOUNDATION_ASSERTION_FAILED: CONTROL_ROOM disabled';
  end if;

  if not exists (
    select 1
    from pg_indexes
    where schemaname = 'public'
      and indexname = 'premium_access_sessions_one_active_uidx'
  ) then
    raise exception 'COMMERCIAL_FOUNDATION_ASSERTION_FAILED: active-session unique index';
  end if;

  if not exists (
    select 1
    from pg_trigger
    where tgname = 'commercial_ledger_append_only_guard'
      and not tgisinternal
  ) then
    raise exception 'COMMERCIAL_FOUNDATION_ASSERTION_FAILED: ledger append-only guard';
  end if;

  raise notice 'COMMERCIAL PLATFORM FOUNDATION CERTIFIED';
  raise notice 'CONTROL_ROOM: 1 Pass = 900 seconds';
end;
$$;

commit;
