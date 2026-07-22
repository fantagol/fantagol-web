-- ============================================================================
-- FANTAGOL PASS PURCHASE ENGINE FOUNDATION
-- Migration: 102_pass_purchase_engine_foundation.sql
-- Version: 1.0
-- Domain: Commercial Platform / Purchase Engine
--
-- Certified scope:
--   - Payment provider registry
--   - Commercial product catalog
--   - Provider-independent purchase orders
--   - Append-only payment event inbox
--   - Authenticated purchase intent creation
--   - Backend-only payment confirmation
--   - Atomic PASS_PURCHASE ledger credit
--   - Idempotent provider callbacks
--   - Controlled cancellation and refund foundation
--   - RLS, grants, audit events and assertions
--
-- Explicitly out of scope:
--   - Direct Stripe SDK/API calls
--   - Checkout URL creation
--   - Card data storage
--   - Tax engine
--   - Invoices
--   - Subscriptions
-- ============================================================================

begin;

-- ============================================================================
-- 0. EXTEND COMMERCIAL AUDIT AGGREGATE VOCABULARY
-- ============================================================================

alter table public.commercial_platform_events
  drop constraint if exists
    commercial_platform_events_aggregate_type_check;

alter table public.commercial_platform_events
  add constraint commercial_platform_events_aggregate_type_check
  check (
    aggregate_type in (
      'COMMERCIAL_WALLET',
      'COMMERCIAL_LEDGER',
      'PREMIUM_ACCESS_SESSION',
      'PREMIUM_RESOURCE',
      'COMMERCIAL_PURCHASE',
      'COMMERCIAL_PRODUCT',
      'PAYMENT_PROVIDER',
      'PAYMENT_PROVIDER_EVENT'
    )
  );

-- ============================================================================
-- 1. PAYMENT PROVIDER REGISTRY
-- ============================================================================

create table if not exists public.payment_providers (
  id uuid primary key default gen_random_uuid(),
  provider_code text not null,
  display_name text not null,
  provider_type text not null default 'payment',
  enabled boolean not null default false,
  test_mode boolean not null default true,
  priority integer not null default 100,
  configuration jsonb not null default '{}'::jsonb,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default clock_timestamp(),
  updated_at timestamptz not null default clock_timestamp(),
  version integer not null default 1,

  constraint payment_providers_provider_code_key
    unique (provider_code),

  constraint payment_providers_provider_code_check
    check (
      provider_code = lower(provider_code)
      and provider_code ~ '^[a-z][a-z0-9_]{1,63}$'
    ),

  constraint payment_providers_display_name_check
    check (length(trim(display_name)) between 1 and 120),

  constraint payment_providers_provider_type_check
    check (provider_type = 'payment'),

  constraint payment_providers_priority_check
    check (priority >= 0),

  constraint payment_providers_configuration_object_check
    check (jsonb_typeof(configuration) = 'object'),

  constraint payment_providers_metadata_object_check
    check (jsonb_typeof(metadata) = 'object'),

  constraint payment_providers_version_check
    check (version > 0)
);

create index if not exists payment_providers_enabled_priority_idx
  on public.payment_providers (enabled, priority, provider_code);

comment on table public.payment_providers is
  'Provider-independent payment adapter registry. No credentials or card data may be exposed to clients.';

-- ============================================================================
-- 2. COMMERCIAL PRODUCT CATALOG
-- ============================================================================

create table if not exists public.commercial_products (
  id uuid primary key default gen_random_uuid(),
  product_code text not null,
  title text not null,
  description text null,
  product_type text not null default 'pass_pack',
  passes integer not null,
  price_minor integer not null,
  currency text not null,
  enabled boolean not null default true,
  public boolean not null default true,
  sort_order integer not null default 100,
  valid_from timestamptz null,
  valid_to timestamptz null,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default clock_timestamp(),
  updated_at timestamptz not null default clock_timestamp(),
  version integer not null default 1,

  constraint commercial_products_product_code_key
    unique (product_code),

  constraint commercial_products_product_code_check
    check (
      product_code = upper(product_code)
      and product_code ~ '^[A-Z][A-Z0-9_]{1,63}$'
    ),

  constraint commercial_products_title_check
    check (length(trim(title)) between 1 and 160),

  constraint commercial_products_product_type_check
    check (product_type = 'pass_pack'),

  constraint commercial_products_passes_check
    check (passes > 0),

  constraint commercial_products_price_minor_check
    check (price_minor > 0),

  constraint commercial_products_currency_check
    check (
      currency = upper(currency)
      and currency ~ '^[A-Z]{3}$'
    ),

  constraint commercial_products_sort_order_check
    check (sort_order >= 0),

  constraint commercial_products_validity_check
    check (
      valid_from is null
      or valid_to is null
      or valid_from < valid_to
    ),

  constraint commercial_products_metadata_object_check
    check (jsonb_typeof(metadata) = 'object'),

  constraint commercial_products_version_check
    check (version > 0)
);

create index if not exists commercial_products_catalog_idx
  on public.commercial_products (
    enabled,
    public,
    sort_order,
    product_code
  );

create index if not exists commercial_products_validity_idx
  on public.commercial_products (valid_from, valid_to);

comment on table public.commercial_products is
  'Versioned provider-independent catalog of one-time Premium Pass packs. Price is stored in minor currency units.';

-- ============================================================================
-- 3. PURCHASE ORDERS
-- ============================================================================

create table if not exists public.commercial_purchases (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null,
  wallet_id uuid not null,
  product_id uuid not null,
  product_code text not null,
  provider_id uuid not null,
  provider_code text not null,
  purchase_status text not null default 'pending',
  payment_status text not null default 'pending',
  passes_awarded integer not null,
  price_minor integer not null,
  currency text not null,
  client_idempotency_key text not null,
  provider_transaction_id text null,
  provider_checkout_reference text null,
  ledger_transaction_id uuid null,
  refund_ledger_transaction_id uuid null,
  correlation_id uuid not null,
  failure_code text null,
  failure_message text null,
  created_at timestamptz not null default clock_timestamp(),
  provider_created_at timestamptz null,
  confirmed_at timestamptz null,
  cancelled_at timestamptz null,
  failed_at timestamptz null,
  refunded_at timestamptz null,
  updated_at timestamptz not null default clock_timestamp(),
  metadata jsonb not null default '{}'::jsonb,
  version integer not null default 1,

  constraint commercial_purchases_user_id_fkey
    foreign key (user_id)
    references auth.users (id)
    on delete restrict,

  constraint commercial_purchases_wallet_id_fkey
    foreign key (wallet_id)
    references public.commercial_wallets (id)
    on delete restrict,

  constraint commercial_purchases_product_id_fkey
    foreign key (product_id)
    references public.commercial_products (id)
    on delete restrict,

  constraint commercial_purchases_provider_id_fkey
    foreign key (provider_id)
    references public.payment_providers (id)
    on delete restrict,

  constraint commercial_purchases_ledger_transaction_id_fkey
    foreign key (ledger_transaction_id)
    references public.commercial_ledger (id)
    on delete restrict,

  constraint commercial_purchases_refund_ledger_transaction_id_fkey
    foreign key (refund_ledger_transaction_id)
    references public.commercial_ledger (id)
    on delete restrict,

  constraint commercial_purchases_user_client_idempotency_key
    unique (user_id, client_idempotency_key),

  constraint commercial_purchases_ledger_transaction_id_key
    unique (ledger_transaction_id),

  constraint commercial_purchases_refund_ledger_transaction_id_key
    unique (refund_ledger_transaction_id),

  constraint commercial_purchases_product_code_check
    check (
      product_code = upper(product_code)
      and product_code ~ '^[A-Z][A-Z0-9_]{1,63}$'
    ),

  constraint commercial_purchases_provider_code_check
    check (
      provider_code = lower(provider_code)
      and provider_code ~ '^[a-z][a-z0-9_]{1,63}$'
    ),

  constraint commercial_purchases_status_check
    check (
      purchase_status in (
        'pending',
        'provider_created',
        'confirmed',
        'cancelled',
        'failed',
        'refunded'
      )
    ),

  constraint commercial_purchases_payment_status_check
    check (
      payment_status in (
        'pending',
        'requires_action',
        'processing',
        'paid',
        'cancelled',
        'failed',
        'refunded'
      )
    ),

  constraint commercial_purchases_passes_awarded_check
    check (passes_awarded > 0),

  constraint commercial_purchases_price_minor_check
    check (price_minor > 0),

  constraint commercial_purchases_currency_check
    check (
      currency = upper(currency)
      and currency ~ '^[A-Z]{3}$'
    ),

  constraint commercial_purchases_client_idempotency_key_check
    check (
      length(trim(client_idempotency_key)) between 8 and 200
    ),

  constraint commercial_purchases_provider_transaction_id_check
    check (
      provider_transaction_id is null
      or length(trim(provider_transaction_id)) between 1 and 300
    ),

  constraint commercial_purchases_provider_checkout_reference_check
    check (
      provider_checkout_reference is null
      or length(trim(provider_checkout_reference)) between 1 and 500
    ),

  constraint commercial_purchases_failure_code_check
    check (
      failure_code is null
      or length(trim(failure_code)) between 1 and 120
    ),

  constraint commercial_purchases_failure_message_check
    check (
      failure_message is null
      or length(trim(failure_message)) between 1 and 1000
    ),

  constraint commercial_purchases_metadata_object_check
    check (jsonb_typeof(metadata) = 'object'),

  constraint commercial_purchases_version_check
    check (version > 0),

  constraint commercial_purchases_confirmation_consistency_check
    check (
      purchase_status <> 'confirmed'
      or (
        payment_status = 'paid'
        and confirmed_at is not null
        and ledger_transaction_id is not null
        and provider_transaction_id is not null
      )
    ),

  constraint commercial_purchases_refund_consistency_check
    check (
      purchase_status <> 'refunded'
      or (
        payment_status = 'refunded'
        and refunded_at is not null
        and ledger_transaction_id is not null
        and refund_ledger_transaction_id is not null
      )
    ),

  constraint commercial_purchases_cancel_consistency_check
    check (
      purchase_status <> 'cancelled'
      or (
        payment_status = 'cancelled'
        and cancelled_at is not null
      )
    ),

  constraint commercial_purchases_failure_consistency_check
    check (
      purchase_status <> 'failed'
      or (
        payment_status = 'failed'
        and failed_at is not null
        and failure_code is not null
      )
    )
);

create unique index if not exists commercial_purchases_provider_transaction_uidx
  on public.commercial_purchases (provider_id, provider_transaction_id)
  where provider_transaction_id is not null;

create index if not exists commercial_purchases_user_created_idx
  on public.commercial_purchases (user_id, created_at desc);

create index if not exists commercial_purchases_status_idx
  on public.commercial_purchases (
    purchase_status,
    payment_status,
    created_at
  );

create index if not exists commercial_purchases_provider_status_idx
  on public.commercial_purchases (
    provider_id,
    purchase_status,
    created_at
  );

create index if not exists commercial_purchases_correlation_idx
  on public.commercial_purchases (correlation_id);

comment on table public.commercial_purchases is
  'Provider-independent one-time purchase order. Product, price, currency and awarded Passes are immutable snapshots.';

-- ============================================================================
-- 4. PAYMENT PROVIDER EVENT INBOX
-- ============================================================================

create table if not exists public.payment_provider_events (
  id uuid primary key default gen_random_uuid(),
  provider_id uuid not null,
  provider_code text not null,
  provider_event_id text not null,
  provider_event_type text not null,
  provider_transaction_id text null,
  purchase_id uuid null,
  payload_hash text not null,
  payload jsonb not null default '{}'::jsonb,
  signature_verified boolean not null default false,
  processing_status text not null default 'received',
  processing_attempts integer not null default 0,
  received_at timestamptz not null default clock_timestamp(),
  processed_at timestamptz null,
  failed_at timestamptz null,
  error_code text null,
  error_message text null,
  correlation_id uuid not null default gen_random_uuid(),
  created_at timestamptz not null default clock_timestamp(),

  constraint payment_provider_events_provider_id_fkey
    foreign key (provider_id)
    references public.payment_providers (id)
    on delete restrict,

  constraint payment_provider_events_purchase_id_fkey
    foreign key (purchase_id)
    references public.commercial_purchases (id)
    on delete set null,

  constraint payment_provider_events_provider_event_key
    unique (provider_id, provider_event_id),

  constraint payment_provider_events_provider_code_check
    check (
      provider_code = lower(provider_code)
      and provider_code ~ '^[a-z][a-z0-9_]{1,63}$'
    ),

  constraint payment_provider_events_provider_event_id_check
    check (length(trim(provider_event_id)) between 1 and 300),

  constraint payment_provider_events_provider_event_type_check
    check (length(trim(provider_event_type)) between 1 and 200),

  constraint payment_provider_events_provider_transaction_check
    check (
      provider_transaction_id is null
      or length(trim(provider_transaction_id)) between 1 and 300
    ),

  constraint payment_provider_events_payload_hash_check
    check (length(trim(payload_hash)) between 16 and 256),

  constraint payment_provider_events_payload_object_check
    check (jsonb_typeof(payload) = 'object'),

  constraint payment_provider_events_processing_status_check
    check (
      processing_status in (
        'received',
        'verified',
        'processing',
        'processed',
        'ignored',
        'failed'
      )
    ),

  constraint payment_provider_events_attempts_check
    check (processing_attempts >= 0),

  constraint payment_provider_events_error_code_check
    check (
      error_code is null
      or length(trim(error_code)) between 1 and 120
    ),

  constraint payment_provider_events_error_message_check
    check (
      error_message is null
      or length(trim(error_message)) between 1 and 1000
    ),

  constraint payment_provider_events_processed_consistency_check
    check (
      processing_status <> 'processed'
      or processed_at is not null
    ),

  constraint payment_provider_events_failed_consistency_check
    check (
      processing_status <> 'failed'
      or (
        failed_at is not null
        and error_code is not null
      )
    )
);

create index if not exists payment_provider_events_status_idx
  on public.payment_provider_events (
    processing_status,
    received_at
  );

create index if not exists payment_provider_events_transaction_idx
  on public.payment_provider_events (
    provider_id,
    provider_transaction_id
  )
  where provider_transaction_id is not null;

create index if not exists payment_provider_events_purchase_idx
  on public.payment_provider_events (
    purchase_id,
    received_at desc
  )
  where purchase_id is not null;

comment on table public.payment_provider_events is
  'Idempotent append-only inbox for signed payment-provider callbacks. Raw card data must never be stored.';

-- ============================================================================
-- 5. UPDATED_AT TRIGGERS
-- ============================================================================

drop trigger if exists payment_providers_set_updated_at
  on public.payment_providers;

create trigger payment_providers_set_updated_at
before update on public.payment_providers
for each row execute function public.commercial_set_updated_at();

drop trigger if exists commercial_products_set_updated_at
  on public.commercial_products;

create trigger commercial_products_set_updated_at
before update on public.commercial_products
for each row execute function public.commercial_set_updated_at();

drop trigger if exists commercial_purchases_set_updated_at
  on public.commercial_purchases;

create trigger commercial_purchases_set_updated_at
before update on public.commercial_purchases
for each row execute function public.commercial_set_updated_at();

-- ============================================================================
-- 6. IMMUTABILITY AND INTERNAL-WRITE GUARDS
-- ============================================================================

create or replace function public.guard_commercial_purchase_mutation()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
  if (
    new.user_id is distinct from old.user_id
    or new.wallet_id is distinct from old.wallet_id
    or new.product_id is distinct from old.product_id
    or new.product_code is distinct from old.product_code
    or new.provider_id is distinct from old.provider_id
    or new.provider_code is distinct from old.provider_code
    or new.passes_awarded is distinct from old.passes_awarded
    or new.price_minor is distinct from old.price_minor
    or new.currency is distinct from old.currency
    or new.client_idempotency_key is distinct from old.client_idempotency_key
    or new.correlation_id is distinct from old.correlation_id
    or new.created_at is distinct from old.created_at
  ) then
    raise exception using
      errcode = 'P0001',
      message = 'COMMERCIAL_PURCHASE_IDENTITY_IMMUTABLE';
  end if;

  if old.purchase_status = 'refunded'
     and new.purchase_status <> 'refunded' then
    raise exception using
      errcode = 'P0001',
      message = 'COMMERCIAL_PURCHASE_REFUND_FINAL';
  end if;

  if old.purchase_status in ('cancelled', 'failed')
     and new.purchase_status not in (
       old.purchase_status,
       'confirmed'
     ) then
    raise exception using
      errcode = 'P0001',
      message = 'COMMERCIAL_PURCHASE_INVALID_TERMINAL_TRANSITION';
  end if;

  if new.ledger_transaction_id is distinct from old.ledger_transaction_id
     and old.ledger_transaction_id is not null then
    raise exception using
      errcode = 'P0001',
      message = 'COMMERCIAL_PURCHASE_LEDGER_REFERENCE_IMMUTABLE';
  end if;

  if new.refund_ledger_transaction_id
       is distinct from old.refund_ledger_transaction_id
     and old.refund_ledger_transaction_id is not null then
    raise exception using
      errcode = 'P0001',
      message = 'COMMERCIAL_PURCHASE_REFUND_LEDGER_REFERENCE_IMMUTABLE';
  end if;

  return new;
end;
$$;

drop trigger if exists commercial_purchases_mutation_guard
  on public.commercial_purchases;

create trigger commercial_purchases_mutation_guard
before update on public.commercial_purchases
for each row execute function public.guard_commercial_purchase_mutation();

drop trigger if exists payment_provider_events_append_only_guard
  on public.payment_provider_events;

create trigger payment_provider_events_append_only_guard
before update or delete on public.payment_provider_events
for each row execute function public.prevent_commercial_append_only_mutation();

drop trigger if exists payment_provider_events_internal_insert_guard
  on public.payment_provider_events;

create trigger payment_provider_events_internal_insert_guard
before insert on public.payment_provider_events
for each row execute function public.guard_commercial_internal_insert();

-- ============================================================================
-- 7. CATALOG RPC
-- ============================================================================

create or replace function public.get_commercial_products_rpc(
  p_currency text default null
)
returns table (
  product_id uuid,
  product_code text,
  title text,
  description text,
  passes integer,
  price_minor integer,
  currency text,
  sort_order integer,
  metadata jsonb
)
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select
    p.id,
    p.product_code,
    p.title,
    p.description,
    p.passes,
    p.price_minor,
    p.currency,
    p.sort_order,
    p.metadata
  from public.commercial_products p
  where p.enabled = true
    and p.public = true
    and (
      p.valid_from is null
      or p.valid_from <= clock_timestamp()
    )
    and (
      p.valid_to is null
      or p.valid_to > clock_timestamp()
    )
    and (
      p_currency is null
      or p.currency = upper(trim(p_currency))
    )
  order by p.sort_order, p.price_minor, p.product_code;
$$;

-- ============================================================================
-- 8. AUTHENTICATED PURCHASE INTENT
-- ============================================================================

create or replace function public.create_my_commercial_purchase_rpc(
  p_product_code text,
  p_provider_code text,
  p_idempotency_key text
)
returns jsonb
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_user_id uuid;
  v_product public.commercial_products;
  v_provider public.payment_providers;
  v_wallet public.commercial_wallets;
  v_existing public.commercial_purchases;
  v_purchase public.commercial_purchases;
  v_product_code text := upper(trim(p_product_code));
  v_provider_code text := lower(trim(p_provider_code));
  v_idempotency_key text := nullif(trim(p_idempotency_key), '');
begin
  v_user_id := public.commercial_assert_authenticated_user();

  if v_idempotency_key is null
     or length(v_idempotency_key) < 8
     or length(v_idempotency_key) > 200 then
    raise exception using
      errcode = '22023',
      message = 'COMMERCIAL_PURCHASE_IDEMPOTENCY_KEY_INVALID';
  end if;

  select *
  into v_existing
  from public.commercial_purchases
  where user_id = v_user_id
    and client_idempotency_key = v_idempotency_key;

  if found then
    if v_existing.product_code <> v_product_code
       or v_existing.provider_code <> v_provider_code then
      raise exception using
        errcode = '23505',
        message = 'COMMERCIAL_PURCHASE_IDEMPOTENCY_CONFLICT';
    end if;

    return jsonb_build_object(
      'created', false,
      'reused_existing_purchase', true,
      'purchase_id', v_existing.id,
      'purchase_status', v_existing.purchase_status,
      'payment_status', v_existing.payment_status,
      'product_code', v_existing.product_code,
      'provider_code', v_existing.provider_code,
      'passes', v_existing.passes_awarded,
      'price_minor', v_existing.price_minor,
      'currency', v_existing.currency,
      'provider_checkout_reference',
        v_existing.provider_checkout_reference,
      'server_time', clock_timestamp()
    );
  end if;

  select *
  into v_product
  from public.commercial_products
  where product_code = v_product_code
    and enabled = true
    and public = true
    and (
      valid_from is null
      or valid_from <= clock_timestamp()
    )
    and (
      valid_to is null
      or valid_to > clock_timestamp()
    );

  if not found then
    return jsonb_build_object(
      'created', false,
      'error_code', 'COMMERCIAL_PRODUCT_NOT_AVAILABLE',
      'product_code', v_product_code,
      'server_time', clock_timestamp()
    );
  end if;

  select *
  into v_provider
  from public.payment_providers
  where provider_code = v_provider_code
    and enabled = true;

  if not found then
    return jsonb_build_object(
      'created', false,
      'error_code', 'PAYMENT_PROVIDER_NOT_AVAILABLE',
      'provider_code', v_provider_code,
      'server_time', clock_timestamp()
    );
  end if;

  v_wallet := public.commercial_get_or_create_wallet(v_user_id);

  if v_wallet.status <> 'active' then
    return jsonb_build_object(
      'created', false,
      'error_code', 'COMMERCIAL_WALLET_NOT_ACTIVE',
      'server_time', clock_timestamp()
    );
  end if;

  insert into public.commercial_purchases (
    user_id,
    wallet_id,
    product_id,
    product_code,
    provider_id,
    provider_code,
    purchase_status,
    payment_status,
    passes_awarded,
    price_minor,
    currency,
    client_idempotency_key,
    correlation_id,
    metadata
  )
  values (
    v_user_id,
    v_wallet.id,
    v_product.id,
    v_product.product_code,
    v_provider.id,
    v_provider.provider_code,
    'pending',
    'pending',
    v_product.passes,
    v_product.price_minor,
    v_product.currency,
    v_idempotency_key,
    gen_random_uuid(),
    jsonb_build_object(
      'product_version', v_product.version,
      'provider_test_mode', v_provider.test_mode,
      'catalog_snapshot_at', clock_timestamp()
    )
  )
  returning * into v_purchase;

  perform public.commercial_append_event_internal(
    'COMMERCIAL_PURCHASE_CREATED',
    'COMMERCIAL_PURCHASE',
    v_purchase.id,
    v_user_id,
    v_purchase.correlation_id,
    null,
    jsonb_build_object(
      'purchase_id', v_purchase.id,
      'product_code', v_purchase.product_code,
      'provider_code', v_purchase.provider_code,
      'passes', v_purchase.passes_awarded,
      'price_minor', v_purchase.price_minor,
      'currency', v_purchase.currency
    )
  );

  return jsonb_build_object(
    'created', true,
    'reused_existing_purchase', false,
    'purchase_id', v_purchase.id,
    'purchase_status', v_purchase.purchase_status,
    'payment_status', v_purchase.payment_status,
    'product_code', v_purchase.product_code,
    'provider_code', v_purchase.provider_code,
    'passes', v_purchase.passes_awarded,
    'price_minor', v_purchase.price_minor,
    'currency', v_purchase.currency,
    'server_time', clock_timestamp()
  );
end;
$$;

-- ============================================================================
-- 9. BACKEND ADAPTER: ATTACH PROVIDER CHECKOUT
-- ============================================================================

create or replace function public.attach_purchase_provider_checkout_internal(
  p_purchase_id uuid,
  p_provider_checkout_reference text,
  p_payment_status text default 'requires_action',
  p_metadata jsonb default '{}'::jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_purchase public.commercial_purchases;
  v_reference text := nullif(trim(p_provider_checkout_reference), '');
  v_payment_status text := lower(trim(p_payment_status));
begin
  if v_reference is null then
    raise exception using
      errcode = '22023',
      message = 'PROVIDER_CHECKOUT_REFERENCE_REQUIRED';
  end if;

  if v_payment_status not in (
    'requires_action',
    'processing'
  ) then
    raise exception using
      errcode = '22023',
      message = 'PROVIDER_CHECKOUT_PAYMENT_STATUS_INVALID';
  end if;

  select *
  into v_purchase
  from public.commercial_purchases
  where id = p_purchase_id
  for update;

  if not found then
    return jsonb_build_object(
      'attached', false,
      'error_code', 'COMMERCIAL_PURCHASE_NOT_FOUND',
      'purchase_id', p_purchase_id
    );
  end if;

  if v_purchase.purchase_status = 'provider_created'
     and v_purchase.provider_checkout_reference = v_reference then
    return jsonb_build_object(
      'attached', true,
      'already_attached', true,
      'purchase_id', v_purchase.id,
      'provider_checkout_reference', v_reference,
      'payment_status', v_purchase.payment_status
    );
  end if;

  if v_purchase.purchase_status <> 'pending' then
    return jsonb_build_object(
      'attached', false,
      'error_code', 'COMMERCIAL_PURCHASE_NOT_PENDING',
      'purchase_id', v_purchase.id,
      'purchase_status', v_purchase.purchase_status
    );
  end if;

  update public.commercial_purchases
  set
    purchase_status = 'provider_created',
    payment_status = v_payment_status,
    provider_checkout_reference = v_reference,
    provider_created_at = clock_timestamp(),
    metadata = metadata || coalesce(p_metadata, '{}'::jsonb)
  where id = v_purchase.id
  returning * into v_purchase;

  perform public.commercial_append_event_internal(
    'COMMERCIAL_PURCHASE_PROVIDER_CREATED',
    'COMMERCIAL_PURCHASE',
    v_purchase.id,
    v_purchase.user_id,
    v_purchase.correlation_id,
    null,
    jsonb_build_object(
      'purchase_id', v_purchase.id,
      'provider_code', v_purchase.provider_code,
      'provider_checkout_reference', v_reference,
      'payment_status', v_payment_status
    )
  );

  return jsonb_build_object(
    'attached', true,
    'already_attached', false,
    'purchase_id', v_purchase.id,
    'provider_checkout_reference', v_reference,
    'payment_status', v_purchase.payment_status
  );
end;
$$;

-- ============================================================================
-- 10. PAYMENT PROVIDER EVENT REGISTRATION
-- ============================================================================

create or replace function public.register_payment_provider_event_internal(
  p_provider_code text,
  p_provider_event_id text,
  p_provider_event_type text,
  p_provider_transaction_id text,
  p_payload_hash text,
  p_payload jsonb,
  p_signature_verified boolean
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_provider public.payment_providers;
  v_existing public.payment_provider_events;
  v_event public.payment_provider_events;
  v_provider_code text := lower(trim(p_provider_code));
  v_provider_event_id text := trim(p_provider_event_id);
  v_payload_hash text := lower(trim(p_payload_hash));
begin
  select *
  into v_provider
  from public.payment_providers
  where provider_code = v_provider_code;

  if not found then
    raise exception using
      errcode = '22023',
      message = 'PAYMENT_PROVIDER_UNKNOWN';
  end if;

  select *
  into v_existing
  from public.payment_provider_events
  where provider_id = v_provider.id
    and provider_event_id = v_provider_event_id;

  if found then
    if v_existing.payload_hash <> v_payload_hash then
      raise exception using
        errcode = '23505',
        message = 'PAYMENT_PROVIDER_EVENT_IDEMPOTENCY_CONFLICT';
    end if;

    return jsonb_build_object(
      'registered', false,
      'duplicate', true,
      'event_id', v_existing.id,
      'processing_status', v_existing.processing_status,
      'signature_verified', v_existing.signature_verified
    );
  end if;

  perform set_config(
    'fantagol.commercial_internal_write',
    'on',
    true
  );

  insert into public.payment_provider_events (
    provider_id,
    provider_code,
    provider_event_id,
    provider_event_type,
    provider_transaction_id,
    payload_hash,
    payload,
    signature_verified,
    processing_status
  )
  values (
    v_provider.id,
    v_provider.provider_code,
    v_provider_event_id,
    trim(p_provider_event_type),
    nullif(trim(p_provider_transaction_id), ''),
    v_payload_hash,
    coalesce(p_payload, '{}'::jsonb),
    coalesce(p_signature_verified, false),
    case
      when coalesce(p_signature_verified, false)
      then 'verified'
      else 'received'
    end
  )
  returning * into v_event;

  return jsonb_build_object(
    'registered', true,
    'duplicate', false,
    'event_id', v_event.id,
    'processing_status', v_event.processing_status,
    'signature_verified', v_event.signature_verified,
    'correlation_id', v_event.correlation_id
  );
end;
$$;

-- ============================================================================
-- 11. BACKEND-ONLY PAYMENT CONFIRMATION
-- ============================================================================

create or replace function public.confirm_commercial_purchase_internal(
  p_purchase_id uuid,
  p_provider_transaction_id text,
  p_provider_event_id uuid default null,
  p_metadata jsonb default '{}'::jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_purchase public.commercial_purchases;
  v_provider_event public.payment_provider_events;
  v_ledger public.commercial_ledger;
  v_provider_transaction_id text :=
    nullif(trim(p_provider_transaction_id), '');
begin
  if v_provider_transaction_id is null then
    raise exception using
      errcode = '22023',
      message = 'PROVIDER_TRANSACTION_ID_REQUIRED';
  end if;

  select *
  into v_purchase
  from public.commercial_purchases
  where id = p_purchase_id
  for update;

  if not found then
    return jsonb_build_object(
      'confirmed', false,
      'error_code', 'COMMERCIAL_PURCHASE_NOT_FOUND',
      'purchase_id', p_purchase_id
    );
  end if;

  perform pg_advisory_xact_lock(
    hashtextextended(
      'commercial-wallet:' || v_purchase.user_id::text,
      0
    )
  );

  if v_purchase.purchase_status = 'confirmed' then
    if v_purchase.provider_transaction_id
         is distinct from v_provider_transaction_id then
      raise exception using
        errcode = '23505',
        message = 'COMMERCIAL_PURCHASE_PROVIDER_TRANSACTION_CONFLICT';
    end if;

    return jsonb_build_object(
      'confirmed', true,
      'already_confirmed', true,
      'purchase_id', v_purchase.id,
      'ledger_id', v_purchase.ledger_transaction_id,
      'provider_transaction_id',
        v_purchase.provider_transaction_id,
      'passes_awarded', v_purchase.passes_awarded
    );
  end if;

  if v_purchase.purchase_status = 'refunded' then
    return jsonb_build_object(
      'confirmed', false,
      'error_code', 'COMMERCIAL_PURCHASE_ALREADY_REFUNDED',
      'purchase_id', v_purchase.id
    );
  end if;

  if p_provider_event_id is not null then
    select *
    into v_provider_event
    from public.payment_provider_events
    where id = p_provider_event_id
      and provider_id = v_purchase.provider_id
    for update;

    if not found then
      raise exception using
        errcode = '22023',
        message = 'PAYMENT_PROVIDER_EVENT_NOT_FOUND';
    end if;

    if not v_provider_event.signature_verified then
      raise exception using
        errcode = '42501',
        message = 'PAYMENT_PROVIDER_SIGNATURE_NOT_VERIFIED';
    end if;

    if v_provider_event.provider_transaction_id is not null
       and v_provider_event.provider_transaction_id
             <> v_provider_transaction_id then
      raise exception using
        errcode = '23505',
        message = 'PAYMENT_PROVIDER_TRANSACTION_MISMATCH';
    end if;
  end if;

  if exists (
    select 1
    from public.commercial_purchases p
    where p.provider_id = v_purchase.provider_id
      and p.provider_transaction_id = v_provider_transaction_id
      and p.id <> v_purchase.id
  ) then
    raise exception using
      errcode = '23505',
      message = 'PROVIDER_TRANSACTION_ALREADY_USED';
  end if;

  v_ledger := public.commercial_append_ledger_internal(
    v_purchase.user_id,
    'PASS_PURCHASE',
    v_purchase.passes_awarded,
    'purchase_engine',
    v_purchase.correlation_id,
    p_provider_event_id,
    'purchase-credit:' || v_purchase.id::text,
    v_purchase.provider_code || ':' || v_provider_transaction_id,
    jsonb_build_object(
      'purchase_id', v_purchase.id,
      'product_id', v_purchase.product_id,
      'product_code', v_purchase.product_code,
      'provider_id', v_purchase.provider_id,
      'provider_code', v_purchase.provider_code,
      'provider_transaction_id', v_provider_transaction_id,
      'price_minor', v_purchase.price_minor,
      'currency', v_purchase.currency
    ) || coalesce(p_metadata, '{}'::jsonb)
  );

  update public.commercial_purchases
  set
    purchase_status = 'confirmed',
    payment_status = 'paid',
    provider_transaction_id = v_provider_transaction_id,
    ledger_transaction_id = v_ledger.id,
    confirmed_at = clock_timestamp(),
    failure_code = null,
    failure_message = null,
    metadata = metadata || coalesce(p_metadata, '{}'::jsonb)
  where id = v_purchase.id
  returning * into v_purchase;

  if p_provider_event_id is not null then
    -- Append-only inbox: processing outcome is recorded in Commercial events.
    perform public.commercial_append_event_internal(
      'PAYMENT_PROVIDER_EVENT_PROCESSED',
      'PAYMENT_PROVIDER_EVENT',
      p_provider_event_id,
      v_purchase.user_id,
      v_provider_event.correlation_id,
      v_purchase.id,
      jsonb_build_object(
        'provider_event_id', p_provider_event_id,
        'purchase_id', v_purchase.id,
        'provider_transaction_id', v_provider_transaction_id
      )
    );
  end if;

  perform public.commercial_append_event_internal(
    'COMMERCIAL_PURCHASE_CONFIRMED',
    'COMMERCIAL_PURCHASE',
    v_purchase.id,
    v_purchase.user_id,
    v_purchase.correlation_id,
    p_provider_event_id,
    jsonb_build_object(
      'purchase_id', v_purchase.id,
      'product_code', v_purchase.product_code,
      'provider_code', v_purchase.provider_code,
      'provider_transaction_id', v_provider_transaction_id,
      'ledger_id', v_ledger.id,
      'passes_awarded', v_purchase.passes_awarded,
      'balance_after', v_ledger.balance_after
    )
  );

  return jsonb_build_object(
    'confirmed', true,
    'already_confirmed', false,
    'purchase_id', v_purchase.id,
    'provider_transaction_id', v_provider_transaction_id,
    'ledger_id', v_ledger.id,
    'passes_awarded', v_purchase.passes_awarded,
    'available_passes', v_ledger.balance_after,
    'confirmed_at', v_purchase.confirmed_at
  );
end;
$$;

-- ============================================================================
-- 12. CANCELLATION / FAILURE FOUNDATION
-- ============================================================================

create or replace function public.close_commercial_purchase_internal(
  p_purchase_id uuid,
  p_outcome text,
  p_failure_code text default null,
  p_failure_message text default null,
  p_metadata jsonb default '{}'::jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_purchase public.commercial_purchases;
  v_outcome text := lower(trim(p_outcome));
  v_failure_code text := nullif(trim(p_failure_code), '');
begin
  if v_outcome not in ('cancelled', 'failed') then
    raise exception using
      errcode = '22023',
      message = 'COMMERCIAL_PURCHASE_CLOSE_OUTCOME_INVALID';
  end if;

  if v_outcome = 'failed' and v_failure_code is null then
    raise exception using
      errcode = '22023',
      message = 'COMMERCIAL_PURCHASE_FAILURE_CODE_REQUIRED';
  end if;

  select *
  into v_purchase
  from public.commercial_purchases
  where id = p_purchase_id
  for update;

  if not found then
    return jsonb_build_object(
      'closed', false,
      'error_code', 'COMMERCIAL_PURCHASE_NOT_FOUND',
      'purchase_id', p_purchase_id
    );
  end if;

  if v_purchase.purchase_status = v_outcome then
    return jsonb_build_object(
      'closed', true,
      'already_closed', true,
      'purchase_id', v_purchase.id,
      'purchase_status', v_purchase.purchase_status
    );
  end if;

  if v_purchase.purchase_status in ('confirmed', 'refunded') then
    return jsonb_build_object(
      'closed', false,
      'error_code', 'COMMERCIAL_PURCHASE_ALREADY_SETTLED',
      'purchase_id', v_purchase.id,
      'purchase_status', v_purchase.purchase_status
    );
  end if;

  update public.commercial_purchases
  set
    purchase_status = v_outcome,
    payment_status = v_outcome,
    cancelled_at = case
      when v_outcome = 'cancelled'
      then clock_timestamp()
      else cancelled_at
    end,
    failed_at = case
      when v_outcome = 'failed'
      then clock_timestamp()
      else failed_at
    end,
    failure_code = case
      when v_outcome = 'failed'
      then v_failure_code
      else null
    end,
    failure_message = case
      when v_outcome = 'failed'
      then nullif(trim(p_failure_message), '')
      else null
    end,
    metadata = metadata || coalesce(p_metadata, '{}'::jsonb)
  where id = v_purchase.id
  returning * into v_purchase;

  perform public.commercial_append_event_internal(
    case
      when v_outcome = 'cancelled'
      then 'COMMERCIAL_PURCHASE_CANCELLED'
      else 'COMMERCIAL_PURCHASE_FAILED'
    end,
    'COMMERCIAL_PURCHASE',
    v_purchase.id,
    v_purchase.user_id,
    v_purchase.correlation_id,
    null,
    jsonb_build_object(
      'purchase_id', v_purchase.id,
      'purchase_status', v_purchase.purchase_status,
      'failure_code', v_purchase.failure_code
    )
  );

  return jsonb_build_object(
    'closed', true,
    'already_closed', false,
    'purchase_id', v_purchase.id,
    'purchase_status', v_purchase.purchase_status,
    'payment_status', v_purchase.payment_status
  );
end;
$$;

-- ============================================================================
-- 13. CONTROLLED REFUND FOUNDATION
-- ============================================================================

create or replace function public.refund_commercial_purchase_internal(
  p_purchase_id uuid,
  p_provider_refund_reference text,
  p_metadata jsonb default '{}'::jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_purchase public.commercial_purchases;
  v_wallet public.commercial_wallets;
  v_refund_ledger public.commercial_ledger;
  v_refund_reference text :=
    nullif(trim(p_provider_refund_reference), '');
begin
  if v_refund_reference is null then
    raise exception using
      errcode = '22023',
      message = 'PROVIDER_REFUND_REFERENCE_REQUIRED';
  end if;

  select *
  into v_purchase
  from public.commercial_purchases
  where id = p_purchase_id
  for update;

  if not found then
    return jsonb_build_object(
      'refunded', false,
      'error_code', 'COMMERCIAL_PURCHASE_NOT_FOUND',
      'purchase_id', p_purchase_id
    );
  end if;

  perform pg_advisory_xact_lock(
    hashtextextended(
      'commercial-wallet:' || v_purchase.user_id::text,
      0
    )
  );

  if v_purchase.purchase_status = 'refunded' then
    return jsonb_build_object(
      'refunded', true,
      'already_refunded', true,
      'purchase_id', v_purchase.id,
      'refund_ledger_id',
        v_purchase.refund_ledger_transaction_id
    );
  end if;

  if v_purchase.purchase_status <> 'confirmed' then
    return jsonb_build_object(
      'refunded', false,
      'error_code', 'COMMERCIAL_PURCHASE_NOT_CONFIRMED',
      'purchase_id', v_purchase.id,
      'purchase_status', v_purchase.purchase_status
    );
  end if;

  select *
  into strict v_wallet
  from public.commercial_wallets
  where id = v_purchase.wallet_id
  for update;

  if v_wallet.available_passes < v_purchase.passes_awarded then
    return jsonb_build_object(
      'refunded', false,
      'error_code', 'COMMERCIAL_REFUND_INSUFFICIENT_PASSES',
      'purchase_id', v_purchase.id,
      'available_passes', v_wallet.available_passes,
      'required_passes', v_purchase.passes_awarded
    );
  end if;

  v_refund_ledger := public.commercial_append_ledger_internal(
    v_purchase.user_id,
    'PASS_REFUND',
    -v_purchase.passes_awarded,
    'purchase_engine',
    v_purchase.correlation_id,
    v_purchase.ledger_transaction_id,
    'purchase-refund:' || v_purchase.id::text,
    v_purchase.provider_code || ':refund:' || v_refund_reference,
    jsonb_build_object(
      'purchase_id', v_purchase.id,
      'original_ledger_id', v_purchase.ledger_transaction_id,
      'provider_transaction_id',
        v_purchase.provider_transaction_id,
      'provider_refund_reference', v_refund_reference
    ) || coalesce(p_metadata, '{}'::jsonb)
  );

  update public.commercial_purchases
  set
    purchase_status = 'refunded',
    payment_status = 'refunded',
    refund_ledger_transaction_id = v_refund_ledger.id,
    refunded_at = clock_timestamp(),
    metadata = metadata || jsonb_build_object(
      'provider_refund_reference', v_refund_reference
    ) || coalesce(p_metadata, '{}'::jsonb)
  where id = v_purchase.id
  returning * into v_purchase;

  perform public.commercial_append_event_internal(
    'COMMERCIAL_PURCHASE_REFUNDED',
    'COMMERCIAL_PURCHASE',
    v_purchase.id,
    v_purchase.user_id,
    v_purchase.correlation_id,
    v_refund_ledger.id,
    jsonb_build_object(
      'purchase_id', v_purchase.id,
      'refund_ledger_id', v_refund_ledger.id,
      'passes_debited', v_purchase.passes_awarded,
      'balance_after', v_refund_ledger.balance_after,
      'provider_refund_reference', v_refund_reference
    )
  );

  return jsonb_build_object(
    'refunded', true,
    'already_refunded', false,
    'purchase_id', v_purchase.id,
    'refund_ledger_id', v_refund_ledger.id,
    'passes_debited', v_purchase.passes_awarded,
    'available_passes', v_refund_ledger.balance_after,
    'refunded_at', v_purchase.refunded_at
  );
end;
$$;

-- ============================================================================
-- 14. AUTHENTICATED PURCHASE HISTORY
-- ============================================================================

create or replace function public.get_my_commercial_purchases_rpc(
  p_limit integer default 50,
  p_offset integer default 0
)
returns table (
  purchase_id uuid,
  product_code text,
  provider_code text,
  purchase_status text,
  payment_status text,
  passes_awarded integer,
  price_minor integer,
  currency text,
  provider_checkout_reference text,
  provider_transaction_id text,
  created_at timestamptz,
  confirmed_at timestamptz,
  cancelled_at timestamptz,
  failed_at timestamptz,
  refunded_at timestamptz
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
    p.id,
    p.product_code,
    p.provider_code,
    p.purchase_status,
    p.payment_status,
    p.passes_awarded,
    p.price_minor,
    p.currency,
    p.provider_checkout_reference,
    p.provider_transaction_id,
    p.created_at,
    p.confirmed_at,
    p.cancelled_at,
    p.failed_at,
    p.refunded_at
  from public.commercial_purchases p
  where p.user_id = v_user_id
  order by p.created_at desc
  limit v_limit
  offset v_offset;
end;
$$;

create or replace function public.get_my_commercial_purchase_rpc(
  p_purchase_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_user_id uuid;
  v_purchase public.commercial_purchases;
begin
  v_user_id := public.commercial_assert_authenticated_user();

  select *
  into v_purchase
  from public.commercial_purchases
  where id = p_purchase_id
    and user_id = v_user_id;

  if not found then
    return jsonb_build_object(
      'found', false,
      'error_code', 'COMMERCIAL_PURCHASE_NOT_FOUND'
    );
  end if;

  return jsonb_build_object(
    'found', true,
    'purchase_id', v_purchase.id,
    'product_code', v_purchase.product_code,
    'provider_code', v_purchase.provider_code,
    'purchase_status', v_purchase.purchase_status,
    'payment_status', v_purchase.payment_status,
    'passes_awarded', v_purchase.passes_awarded,
    'price_minor', v_purchase.price_minor,
    'currency', v_purchase.currency,
    'provider_checkout_reference',
      v_purchase.provider_checkout_reference,
    'provider_transaction_id',
      v_purchase.provider_transaction_id,
    'created_at', v_purchase.created_at,
    'provider_created_at', v_purchase.provider_created_at,
    'confirmed_at', v_purchase.confirmed_at,
    'cancelled_at', v_purchase.cancelled_at,
    'failed_at', v_purchase.failed_at,
    'refunded_at', v_purchase.refunded_at,
    'server_time', clock_timestamp()
  );
end;
$$;

-- ============================================================================
-- 15. ROW LEVEL SECURITY
-- ============================================================================

alter table public.payment_providers enable row level security;
alter table public.commercial_products enable row level security;
alter table public.commercial_purchases enable row level security;
alter table public.payment_provider_events enable row level security;

drop policy if exists commercial_products_authenticated_read
  on public.commercial_products;

create policy commercial_products_authenticated_read
on public.commercial_products
for select
to authenticated
using (
  enabled = true
  and public = true
  and (
    valid_from is null
    or valid_from <= clock_timestamp()
  )
  and (
    valid_to is null
    or valid_to > clock_timestamp()
  )
);

drop policy if exists commercial_purchases_owner_read
  on public.commercial_purchases;

create policy commercial_purchases_owner_read
on public.commercial_purchases
for select
to authenticated
using (user_id = auth.uid());

-- Payment providers and provider events remain backend-only.

-- ============================================================================
-- 16. PRIVILEGES
-- ============================================================================

revoke all on table public.payment_providers
  from anon, authenticated;

revoke all on table public.commercial_products
  from anon, authenticated;

revoke all on table public.commercial_purchases
  from anon, authenticated;

revoke all on table public.payment_provider_events
  from anon, authenticated;

grant select on table public.commercial_products
  to authenticated;

grant select on table public.commercial_purchases
  to authenticated;

grant all on table public.payment_providers
  to service_role;

grant all on table public.commercial_products
  to service_role;

grant all on table public.commercial_purchases
  to service_role;

grant all on table public.payment_provider_events
  to service_role;

revoke all on function public.get_commercial_products_rpc(text)
  from public, anon;

revoke all on function public.create_my_commercial_purchase_rpc(
  text, text, text
) from public, anon;

revoke all on function public.get_my_commercial_purchases_rpc(
  integer, integer
) from public, anon;

revoke all on function public.get_my_commercial_purchase_rpc(uuid)
  from public, anon;

grant execute on function public.get_commercial_products_rpc(text)
  to authenticated;

grant execute on function public.create_my_commercial_purchase_rpc(
  text, text, text
) to authenticated;

grant execute on function public.get_my_commercial_purchases_rpc(
  integer, integer
) to authenticated;

grant execute on function public.get_my_commercial_purchase_rpc(uuid)
  to authenticated;

revoke all on function public.attach_purchase_provider_checkout_internal(
  uuid, text, text, jsonb
) from public, anon, authenticated;

revoke all on function public.register_payment_provider_event_internal(
  text, text, text, text, text, jsonb, boolean
) from public, anon, authenticated;

revoke all on function public.confirm_commercial_purchase_internal(
  uuid, text, uuid, jsonb
) from public, anon, authenticated;

revoke all on function public.close_commercial_purchase_internal(
  uuid, text, text, text, jsonb
) from public, anon, authenticated;

revoke all on function public.refund_commercial_purchase_internal(
  uuid, text, jsonb
) from public, anon, authenticated;

grant execute on function public.attach_purchase_provider_checkout_internal(
  uuid, text, text, jsonb
) to service_role;

grant execute on function public.register_payment_provider_event_internal(
  text, text, text, text, text, jsonb, boolean
) to service_role;

grant execute on function public.confirm_commercial_purchase_internal(
  uuid, text, uuid, jsonb
) to service_role;

grant execute on function public.close_commercial_purchase_internal(
  uuid, text, text, text, jsonb
) to service_role;

grant execute on function public.refund_commercial_purchase_internal(
  uuid, text, jsonb
) to service_role;

-- ============================================================================
-- 17. FOUNDATION SEEDS
-- ============================================================================

insert into public.payment_providers (
  provider_code,
  display_name,
  provider_type,
  enabled,
  test_mode,
  priority,
  configuration,
  metadata
)
values (
  'stripe',
  'Stripe',
  'payment',
  false,
  true,
  10,
  jsonb_build_object(
    'adapter_status', 'not_configured',
    'webhook_required', true
  ),
  jsonb_build_object(
    'foundation_version', '1.0',
    'provider_independent', true
  )
)
on conflict (provider_code) do update
set
  display_name = excluded.display_name,
  provider_type = excluded.provider_type,
  priority = excluded.priority,
  metadata = excluded.metadata;

insert into public.commercial_products (
  product_code,
  title,
  description,
  product_type,
  passes,
  price_minor,
  currency,
  enabled,
  public,
  sort_order,
  metadata
)
values
  (
    'STARTER',
    'Starter',
    'Starter Premium Pass pack.',
    'pass_pack',
    5,
    199,
    'EUR',
    false,
    false,
    10,
    jsonb_build_object(
      'foundation_seed', true,
      'price_requires_commercial_approval', true
    )
  ),
  (
    'STANDARD',
    'Standard',
    'Standard Premium Pass pack.',
    'pass_pack',
    15,
    499,
    'EUR',
    false,
    false,
    20,
    jsonb_build_object(
      'foundation_seed', true,
      'price_requires_commercial_approval', true
    )
  ),
  (
    'PRO',
    'Pro',
    'Pro Premium Pass pack.',
    'pass_pack',
    40,
    999,
    'EUR',
    false,
    false,
    30,
    jsonb_build_object(
      'foundation_seed', true,
      'price_requires_commercial_approval', true
    )
  ),
  (
    'MEGA',
    'Mega',
    'Mega Premium Pass pack.',
    'pass_pack',
    100,
    1999,
    'EUR',
    false,
    false,
    40,
    jsonb_build_object(
      'foundation_seed', true,
      'price_requires_commercial_approval', true
    )
  )
on conflict (product_code) do update
set
  title = excluded.title,
  description = excluded.description,
  product_type = excluded.product_type,
  passes = excluded.passes,
  price_minor = excluded.price_minor,
  currency = excluded.currency,
  sort_order = excluded.sort_order,
  metadata = excluded.metadata;

-- Products and Stripe remain disabled until commercial configuration,
-- legal pricing approval and provider credentials are completed.

-- ============================================================================
-- 18. DOCUMENTATION COMMENTS
-- ============================================================================

comment on function public.get_commercial_products_rpc(text) is
  'Returns only enabled, public and currently valid one-time Premium Pass packs.';

comment on function public.create_my_commercial_purchase_rpc(
  text, text, text
) is
  'Creates an idempotent provider-independent purchase order for the authenticated user. It does not confirm payment or award Passes.';

comment on function public.confirm_commercial_purchase_internal(
  uuid, text, uuid, jsonb
) is
  'Backend-only atomic payment confirmation. Credits Premium Passes exactly once through the immutable ledger.';

comment on function public.register_payment_provider_event_internal(
  text, text, text, text, text, jsonb, boolean
) is
  'Backend-only idempotent registration of a payment provider callback after adapter-level signature verification.';

comment on function public.refund_commercial_purchase_internal(
  uuid, text, jsonb
) is
  'Backend-only refund foundation. Debits originally awarded Passes only when the wallet has sufficient available balance.';

-- ============================================================================
-- 19. FOUNDATION ASSERTIONS
-- ============================================================================

do $$
declare
  v_provider public.payment_providers;
  v_product_count integer;
begin
  select *
  into strict v_provider
  from public.payment_providers
  where provider_code = 'stripe';

  if v_provider.enabled then
    raise exception
      'PURCHASE_ENGINE_FOUNDATION_ASSERTION_FAILED: Stripe must remain disabled';
  end if;

  select count(*)
  into v_product_count
  from public.commercial_products
  where product_code in (
    'STARTER',
    'STANDARD',
    'PRO',
    'MEGA'
  );

  if v_product_count <> 4 then
    raise exception
      'PURCHASE_ENGINE_FOUNDATION_ASSERTION_FAILED: product seed count';
  end if;

  if exists (
    select 1
    from public.commercial_products
    where product_code in (
      'STARTER',
      'STANDARD',
      'PRO',
      'MEGA'
    )
      and (enabled = true or public = true)
  ) then
    raise exception
      'PURCHASE_ENGINE_FOUNDATION_ASSERTION_FAILED: products must remain hidden';
  end if;

  if not exists (
    select 1
    from pg_indexes
    where schemaname = 'public'
      and indexname =
        'commercial_purchases_provider_transaction_uidx'
  ) then
    raise exception
      'PURCHASE_ENGINE_FOUNDATION_ASSERTION_FAILED: provider transaction uniqueness';
  end if;

  if not exists (
    select 1
    from pg_trigger
    where tgname = 'payment_provider_events_append_only_guard'
      and not tgisinternal
  ) then
    raise exception
      'PURCHASE_ENGINE_FOUNDATION_ASSERTION_FAILED: provider event append-only guard';
  end if;

  raise notice 'PASS PURCHASE ENGINE FOUNDATION CERTIFIED';
  raise notice 'Stripe adapter seeded but disabled';
  raise notice 'Commercial products seeded but hidden pending approval';
end;
$$;

commit;
