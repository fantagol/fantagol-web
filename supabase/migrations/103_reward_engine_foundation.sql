-- ============================================================================
-- FANTAGOL REWARD ENGINE FOUNDATION
-- Migration: 103_reward_engine_foundation.sql
-- Version: 1.0
-- Domain: Commercial Platform / Reward Engine
--
-- Certified scope:
--   - Reward source registry
--   - Reward campaign registry
--   - Immutable reward claims
--   - Append-only provider verification inbox
--   - Authenticated claim submission
--   - Backend-only verification and settlement
--   - Atomic ledger credit
--   - Per-user and campaign issuance limits
--   - Idempotent provider events and reward settlement
--   - RLS, grants, audit events and assertions
--
-- Explicitly out of scope:
--   - Direct rewarded-ad SDK/API calls
--   - Referral graph
--   - Public promotional codes
--   - Gift-code inventory
--   - Fraud scoring
--   - Automated campaign activation
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
      'PAYMENT_PROVIDER_EVENT',
      'REWARD_SOURCE',
      'REWARD_CAMPAIGN',
      'REWARD_CLAIM',
      'REWARD_PROVIDER_EVENT'
    )
  );

-- ============================================================================
-- 1. REWARD SOURCE REGISTRY
-- ============================================================================

create table if not exists public.reward_sources (
  id uuid primary key default gen_random_uuid(),
  source_code text not null,
  display_name text not null,
  source_type text not null,
  provider_code text null,
  enabled boolean not null default false,
  test_mode boolean not null default true,
  verification_mode text not null default 'backend',
  priority integer not null default 100,
  configuration jsonb not null default '{}'::jsonb,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default clock_timestamp(),
  updated_at timestamptz not null default clock_timestamp(),
  version integer not null default 1,

  constraint reward_sources_source_code_key
    unique (source_code),

  constraint reward_sources_source_code_check
    check (
      source_code = upper(source_code)
      and source_code ~ '^[A-Z][A-Z0-9_]{1,63}$'
    ),

  constraint reward_sources_display_name_check
    check (length(trim(display_name)) between 1 and 120),

  constraint reward_sources_source_type_check
    check (
      source_type in (
        'rewarded_ad',
        'promotion',
        'referral',
        'gift',
        'event',
        'operator'
      )
    ),

  constraint reward_sources_provider_code_check
    check (
      provider_code is null
      or (
        provider_code = lower(provider_code)
        and provider_code ~ '^[a-z][a-z0-9_]{1,63}$'
      )
    ),

  constraint reward_sources_verification_mode_check
    check (
      verification_mode in (
        'backend',
        'signed_callback',
        'manual_review'
      )
    ),

  constraint reward_sources_priority_check
    check (priority >= 0),

  constraint reward_sources_configuration_object_check
    check (jsonb_typeof(configuration) = 'object'),

  constraint reward_sources_metadata_object_check
    check (jsonb_typeof(metadata) = 'object'),

  constraint reward_sources_version_check
    check (version > 0)
);

create index if not exists reward_sources_enabled_priority_idx
  on public.reward_sources (
    enabled,
    priority,
    source_code
  );

comment on table public.reward_sources is
  'Provider-independent registry of commercial reward origins. Sources remain backend controlled.';

-- ============================================================================
-- 2. REWARD CAMPAIGNS
-- ============================================================================

create table if not exists public.reward_campaigns (
  id uuid primary key default gen_random_uuid(),
  campaign_code text not null,
  source_id uuid not null,
  title text not null,
  description text null,
  reward_type text not null,
  passes_per_claim integer not null,
  enabled boolean not null default false,
  public boolean not null default false,
  starts_at timestamptz null,
  ends_at timestamptz null,
  max_total_claims bigint null,
  max_total_passes bigint null,
  max_claims_per_user integer null,
  cooldown_seconds integer not null default 0,
  requires_external_verification boolean not null default true,
  issued_claims bigint not null default 0,
  issued_passes bigint not null default 0,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default clock_timestamp(),
  updated_at timestamptz not null default clock_timestamp(),
  version integer not null default 1,

  constraint reward_campaigns_campaign_code_key
    unique (campaign_code),

  constraint reward_campaigns_source_id_fkey
    foreign key (source_id)
    references public.reward_sources (id)
    on delete restrict,

  constraint reward_campaigns_campaign_code_check
    check (
      campaign_code = upper(campaign_code)
      and campaign_code ~ '^[A-Z][A-Z0-9_]{1,95}$'
    ),

  constraint reward_campaigns_title_check
    check (length(trim(title)) between 1 and 160),

  constraint reward_campaigns_reward_type_check
    check (
      reward_type in (
        'PASS_REWARD',
        'PASS_PROMOTION',
        'PASS_GIFT',
        'PASS_REFERRAL'
      )
    ),

  constraint reward_campaigns_passes_per_claim_check
    check (passes_per_claim > 0),

  constraint reward_campaigns_validity_check
    check (
      starts_at is null
      or ends_at is null
      or starts_at < ends_at
    ),

  constraint reward_campaigns_max_total_claims_check
    check (
      max_total_claims is null
      or max_total_claims > 0
    ),

  constraint reward_campaigns_max_total_passes_check
    check (
      max_total_passes is null
      or max_total_passes > 0
    ),

  constraint reward_campaigns_max_claims_per_user_check
    check (
      max_claims_per_user is null
      or max_claims_per_user > 0
    ),

  constraint reward_campaigns_cooldown_seconds_check
    check (cooldown_seconds >= 0),

  constraint reward_campaigns_issued_claims_check
    check (issued_claims >= 0),

  constraint reward_campaigns_issued_passes_check
    check (issued_passes >= 0),

  constraint reward_campaigns_metadata_object_check
    check (jsonb_typeof(metadata) = 'object'),

  constraint reward_campaigns_version_check
    check (version > 0)
);

create index if not exists reward_campaigns_catalog_idx
  on public.reward_campaigns (
    enabled,
    public,
    starts_at,
    ends_at,
    campaign_code
  );

create index if not exists reward_campaigns_source_idx
  on public.reward_campaigns (
    source_id,
    enabled,
    campaign_code
  );

comment on table public.reward_campaigns is
  'Controlled reward campaign definition with immutable settlement snapshots and authoritative issuance counters.';

-- ============================================================================
-- 3. REWARD CLAIMS
-- ============================================================================

create table if not exists public.reward_claims (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null,
  wallet_id uuid not null,
  campaign_id uuid not null,
  campaign_code text not null,
  source_id uuid not null,
  source_code text not null,
  reward_type text not null,
  passes_awarded integer not null,
  claim_status text not null default 'submitted',
  verification_status text not null default 'pending',
  client_idempotency_key text null,
  external_claim_reference text null,
  ledger_transaction_id uuid null,
  correlation_id uuid not null,
  submitted_at timestamptz not null default clock_timestamp(),
  verification_started_at timestamptz null,
  verified_at timestamptz null,
  rejected_at timestamptz null,
  settled_at timestamptz null,
  expired_at timestamptz null,
  rejection_code text null,
  rejection_message text null,
  evidence jsonb not null default '{}'::jsonb,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default clock_timestamp(),
  updated_at timestamptz not null default clock_timestamp(),
  version integer not null default 1,

  constraint reward_claims_user_id_fkey
    foreign key (user_id)
    references auth.users (id)
    on delete restrict,

  constraint reward_claims_wallet_id_fkey
    foreign key (wallet_id)
    references public.commercial_wallets (id)
    on delete restrict,

  constraint reward_claims_campaign_id_fkey
    foreign key (campaign_id)
    references public.reward_campaigns (id)
    on delete restrict,

  constraint reward_claims_source_id_fkey
    foreign key (source_id)
    references public.reward_sources (id)
    on delete restrict,

  constraint reward_claims_ledger_transaction_id_fkey
    foreign key (ledger_transaction_id)
    references public.commercial_ledger (id)
    on delete restrict,

  constraint reward_claims_ledger_transaction_id_key
    unique (ledger_transaction_id),

  constraint reward_claims_user_client_idempotency_key
    unique (user_id, client_idempotency_key),

  constraint reward_claims_campaign_code_check
    check (
      campaign_code = upper(campaign_code)
      and campaign_code ~ '^[A-Z][A-Z0-9_]{1,95}$'
    ),

  constraint reward_claims_source_code_check
    check (
      source_code = upper(source_code)
      and source_code ~ '^[A-Z][A-Z0-9_]{1,63}$'
    ),

  constraint reward_claims_reward_type_check
    check (
      reward_type in (
        'PASS_REWARD',
        'PASS_PROMOTION',
        'PASS_GIFT',
        'PASS_REFERRAL'
      )
    ),

  constraint reward_claims_passes_awarded_check
    check (passes_awarded > 0),

  constraint reward_claims_status_check
    check (
      claim_status in (
        'submitted',
        'verification_pending',
        'verified',
        'rejected',
        'settled',
        'expired'
      )
    ),

  constraint reward_claims_verification_status_check
    check (
      verification_status in (
        'pending',
        'processing',
        'verified',
        'rejected',
        'expired'
      )
    ),

  constraint reward_claims_client_idempotency_key_check
    check (
      client_idempotency_key is null
      or length(trim(client_idempotency_key)) between 8 and 200
    ),

  constraint reward_claims_external_reference_check
    check (
      external_claim_reference is null
      or length(trim(external_claim_reference)) between 1 and 300
    ),

  constraint reward_claims_rejection_code_check
    check (
      rejection_code is null
      or length(trim(rejection_code)) between 1 and 120
    ),

  constraint reward_claims_rejection_message_check
    check (
      rejection_message is null
      or length(trim(rejection_message)) between 1 and 1000
    ),

  constraint reward_claims_evidence_object_check
    check (jsonb_typeof(evidence) = 'object'),

  constraint reward_claims_metadata_object_check
    check (jsonb_typeof(metadata) = 'object'),

  constraint reward_claims_version_check
    check (version > 0),

  constraint reward_claims_settlement_consistency_check
    check (
      claim_status <> 'settled'
      or (
        verification_status = 'verified'
        and verified_at is not null
        and settled_at is not null
        and ledger_transaction_id is not null
      )
    ),

  constraint reward_claims_rejection_consistency_check
    check (
      claim_status <> 'rejected'
      or (
        verification_status = 'rejected'
        and rejected_at is not null
        and rejection_code is not null
      )
    ),

  constraint reward_claims_expiration_consistency_check
    check (
      claim_status <> 'expired'
      or (
        verification_status = 'expired'
        and expired_at is not null
      )
    )
);

create unique index if not exists reward_claims_external_reference_uidx
  on public.reward_claims (source_id, external_claim_reference)
  where external_claim_reference is not null;

create index if not exists reward_claims_user_created_idx
  on public.reward_claims (
    user_id,
    created_at desc
  );

create index if not exists reward_claims_campaign_user_idx
  on public.reward_claims (
    campaign_id,
    user_id,
    created_at desc
  );

create index if not exists reward_claims_status_idx
  on public.reward_claims (
    claim_status,
    verification_status,
    created_at
  );

create index if not exists reward_claims_correlation_idx
  on public.reward_claims (correlation_id);

comment on table public.reward_claims is
  'Immutable reward entitlement request. Passes are awarded only after backend verification and atomic ledger settlement.';

-- ============================================================================
-- 4. REWARD PROVIDER EVENT INBOX
-- ============================================================================

create table if not exists public.reward_provider_events (
  id uuid primary key default gen_random_uuid(),
  source_id uuid not null,
  source_code text not null,
  provider_event_id text not null,
  provider_event_type text not null,
  external_claim_reference text null,
  claim_id uuid null,
  payload_hash text not null,
  payload jsonb not null default '{}'::jsonb,
  signature_verified boolean not null default false,
  processing_status text not null default 'received',
  received_at timestamptz not null default clock_timestamp(),
  correlation_id uuid not null default gen_random_uuid(),
  created_at timestamptz not null default clock_timestamp(),

  constraint reward_provider_events_source_id_fkey
    foreign key (source_id)
    references public.reward_sources (id)
    on delete restrict,

  constraint reward_provider_events_claim_id_fkey
    foreign key (claim_id)
    references public.reward_claims (id)
    on delete set null,

  constraint reward_provider_events_source_event_key
    unique (source_id, provider_event_id),

  constraint reward_provider_events_source_code_check
    check (
      source_code = upper(source_code)
      and source_code ~ '^[A-Z][A-Z0-9_]{1,63}$'
    ),

  constraint reward_provider_events_provider_event_id_check
    check (length(trim(provider_event_id)) between 1 and 300),

  constraint reward_provider_events_provider_event_type_check
    check (length(trim(provider_event_type)) between 1 and 200),

  constraint reward_provider_events_external_reference_check
    check (
      external_claim_reference is null
      or length(trim(external_claim_reference)) between 1 and 300
    ),

  constraint reward_provider_events_payload_hash_check
    check (length(trim(payload_hash)) between 16 and 256),

  constraint reward_provider_events_payload_object_check
    check (jsonb_typeof(payload) = 'object'),

  constraint reward_provider_events_processing_status_check
    check (
      processing_status in (
        'received',
        'verified',
        'processed',
        'ignored',
        'failed'
      )
    )
);

create index if not exists reward_provider_events_status_idx
  on public.reward_provider_events (
    processing_status,
    received_at
  );

create index if not exists reward_provider_events_external_reference_idx
  on public.reward_provider_events (
    source_id,
    external_claim_reference
  )
  where external_claim_reference is not null;

comment on table public.reward_provider_events is
  'Append-only idempotent inbox for externally verified reward callbacks.';

-- ============================================================================
-- 5. UPDATED_AT TRIGGERS
-- ============================================================================

drop trigger if exists reward_sources_set_updated_at
  on public.reward_sources;

create trigger reward_sources_set_updated_at
before update on public.reward_sources
for each row execute function public.commercial_set_updated_at();

drop trigger if exists reward_campaigns_set_updated_at
  on public.reward_campaigns;

create trigger reward_campaigns_set_updated_at
before update on public.reward_campaigns
for each row execute function public.commercial_set_updated_at();

drop trigger if exists reward_claims_set_updated_at
  on public.reward_claims;

create trigger reward_claims_set_updated_at
before update on public.reward_claims
for each row execute function public.commercial_set_updated_at();

-- ============================================================================
-- 6. MUTATION GUARDS
-- ============================================================================

create or replace function public.guard_reward_campaign_projection()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
  if (
    new.issued_claims is distinct from old.issued_claims
    or new.issued_passes is distinct from old.issued_passes
  ) and current_setting(
    'fantagol.reward_internal_write',
    true
  ) is distinct from 'on' then
    raise exception using
      errcode = '42501',
      message = 'REWARD_CAMPAIGN_PROJECTION_INTERNAL_ONLY';
  end if;

  return new;
end;
$$;

drop trigger if exists reward_campaigns_projection_guard
  on public.reward_campaigns;

create trigger reward_campaigns_projection_guard
before update on public.reward_campaigns
for each row execute function public.guard_reward_campaign_projection();

create or replace function public.guard_reward_claim_mutation()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
  if (
    new.user_id is distinct from old.user_id
    or new.wallet_id is distinct from old.wallet_id
    or new.campaign_id is distinct from old.campaign_id
    or new.campaign_code is distinct from old.campaign_code
    or new.source_id is distinct from old.source_id
    or new.source_code is distinct from old.source_code
    or new.reward_type is distinct from old.reward_type
    or new.passes_awarded is distinct from old.passes_awarded
    or new.client_idempotency_key is distinct from old.client_idempotency_key
    or new.correlation_id is distinct from old.correlation_id
    or new.submitted_at is distinct from old.submitted_at
    or new.created_at is distinct from old.created_at
  ) then
    raise exception using
      errcode = 'P0001',
      message = 'REWARD_CLAIM_IDENTITY_IMMUTABLE';
  end if;

  if old.claim_status in ('settled', 'rejected', 'expired')
     and new.claim_status <> old.claim_status then
    raise exception using
      errcode = 'P0001',
      message = 'REWARD_CLAIM_TERMINAL_STATE_IMMUTABLE';
  end if;

  if new.ledger_transaction_id is distinct from old.ledger_transaction_id
     and old.ledger_transaction_id is not null then
    raise exception using
      errcode = 'P0001',
      message = 'REWARD_CLAIM_LEDGER_REFERENCE_IMMUTABLE';
  end if;

  return new;
end;
$$;

drop trigger if exists reward_claims_mutation_guard
  on public.reward_claims;

create trigger reward_claims_mutation_guard
before update on public.reward_claims
for each row execute function public.guard_reward_claim_mutation();

drop trigger if exists reward_provider_events_append_only_guard
  on public.reward_provider_events;

create trigger reward_provider_events_append_only_guard
before update or delete on public.reward_provider_events
for each row execute function public.prevent_commercial_append_only_mutation();

drop trigger if exists reward_provider_events_internal_insert_guard
  on public.reward_provider_events;

create trigger reward_provider_events_internal_insert_guard
before insert on public.reward_provider_events
for each row execute function public.guard_commercial_internal_insert();

-- ============================================================================
-- 7. PUBLIC REWARD CAMPAIGN CATALOG
-- ============================================================================

create or replace function public.get_reward_campaigns_rpc()
returns table (
  campaign_id uuid,
  campaign_code text,
  source_code text,
  title text,
  description text,
  reward_type text,
  passes_per_claim integer,
  cooldown_seconds integer,
  starts_at timestamptz,
  ends_at timestamptz,
  metadata jsonb
)
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select
    c.id,
    c.campaign_code,
    s.source_code,
    c.title,
    c.description,
    c.reward_type,
    c.passes_per_claim,
    c.cooldown_seconds,
    c.starts_at,
    c.ends_at,
    c.metadata
  from public.reward_campaigns c
  join public.reward_sources s
    on s.id = c.source_id
  where c.enabled = true
    and c.public = true
    and s.enabled = true
    and (
      c.starts_at is null
      or c.starts_at <= clock_timestamp()
    )
    and (
      c.ends_at is null
      or c.ends_at > clock_timestamp()
    )
  order by c.starts_at nulls first, c.campaign_code;
$$;

-- ============================================================================
-- 8. AUTHENTICATED CLAIM SUBMISSION
-- ============================================================================

create or replace function public.submit_my_reward_claim_rpc(
  p_campaign_code text,
  p_idempotency_key text,
  p_external_claim_reference text default null,
  p_evidence jsonb default '{}'::jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_user_id uuid;
  v_campaign public.reward_campaigns;
  v_source public.reward_sources;
  v_wallet public.commercial_wallets;
  v_existing public.reward_claims;
  v_claim public.reward_claims;
  v_campaign_code text := upper(trim(p_campaign_code));
  v_idempotency_key text := nullif(trim(p_idempotency_key), '');
  v_external_reference text :=
    nullif(trim(p_external_claim_reference), '');
  v_user_settled_claims bigint;
  v_last_submitted_at timestamptz;
begin
  v_user_id := public.commercial_assert_authenticated_user();

  if v_idempotency_key is null
     or length(v_idempotency_key) < 8
     or length(v_idempotency_key) > 200 then
    raise exception using
      errcode = '22023',
      message = 'REWARD_CLAIM_IDEMPOTENCY_KEY_INVALID';
  end if;

  if jsonb_typeof(coalesce(p_evidence, '{}'::jsonb)) <> 'object' then
    raise exception using
      errcode = '22023',
      message = 'REWARD_CLAIM_EVIDENCE_MUST_BE_OBJECT';
  end if;

  select *
  into v_existing
  from public.reward_claims
  where user_id = v_user_id
    and client_idempotency_key = v_idempotency_key;

  if found then
    if v_existing.campaign_code <> v_campaign_code
       or v_existing.external_claim_reference
            is distinct from v_external_reference then
      raise exception using
        errcode = '23505',
        message = 'REWARD_CLAIM_IDEMPOTENCY_CONFLICT';
    end if;

    return jsonb_build_object(
      'submitted', true,
      'created', false,
      'claim_id', v_existing.id,
      'claim_status', v_existing.claim_status,
      'verification_status', v_existing.verification_status,
      'campaign_code', v_existing.campaign_code,
      'passes', v_existing.passes_awarded,
      'server_time', clock_timestamp()
    );
  end if;

  select c.*
  into v_campaign
  from public.reward_campaigns c
  where c.campaign_code = v_campaign_code
    and c.enabled = true
    and c.public = true
    and (
      c.starts_at is null
      or c.starts_at <= clock_timestamp()
    )
    and (
      c.ends_at is null
      or c.ends_at > clock_timestamp()
    );

  if not found then
    return jsonb_build_object(
      'submitted', false,
      'error_code', 'REWARD_CAMPAIGN_NOT_AVAILABLE',
      'campaign_code', v_campaign_code,
      'server_time', clock_timestamp()
    );
  end if;

  select *
  into strict v_source
  from public.reward_sources
  where id = v_campaign.source_id;

  if not v_source.enabled then
    return jsonb_build_object(
      'submitted', false,
      'error_code', 'REWARD_SOURCE_NOT_AVAILABLE',
      'source_code', v_source.source_code,
      'server_time', clock_timestamp()
    );
  end if;

  if v_campaign.max_claims_per_user is not null then
    select count(*)
    into v_user_settled_claims
    from public.reward_claims
    where campaign_id = v_campaign.id
      and user_id = v_user_id
      and claim_status = 'settled';

    if v_user_settled_claims >= v_campaign.max_claims_per_user then
      return jsonb_build_object(
        'submitted', false,
        'error_code', 'REWARD_USER_CLAIM_LIMIT_REACHED',
        'campaign_code', v_campaign.campaign_code,
        'server_time', clock_timestamp()
      );
    end if;
  end if;

  if v_campaign.cooldown_seconds > 0 then
    select max(submitted_at)
    into v_last_submitted_at
    from public.reward_claims
    where campaign_id = v_campaign.id
      and user_id = v_user_id
      and claim_status not in ('rejected', 'expired');

    if v_last_submitted_at is not null
       and v_last_submitted_at
             + make_interval(secs => v_campaign.cooldown_seconds)
             > clock_timestamp() then
      return jsonb_build_object(
        'submitted', false,
        'error_code', 'REWARD_CLAIM_COOLDOWN_ACTIVE',
        'retry_after',
          v_last_submitted_at
          + make_interval(secs => v_campaign.cooldown_seconds),
        'server_time', clock_timestamp()
      );
    end if;
  end if;

  v_wallet := public.commercial_get_or_create_wallet(v_user_id);

  if v_wallet.status <> 'active' then
    return jsonb_build_object(
      'submitted', false,
      'error_code', 'COMMERCIAL_WALLET_NOT_ACTIVE',
      'server_time', clock_timestamp()
    );
  end if;

  insert into public.reward_claims (
    user_id,
    wallet_id,
    campaign_id,
    campaign_code,
    source_id,
    source_code,
    reward_type,
    passes_awarded,
    claim_status,
    verification_status,
    client_idempotency_key,
    external_claim_reference,
    correlation_id,
    evidence,
    metadata
  )
  values (
    v_user_id,
    v_wallet.id,
    v_campaign.id,
    v_campaign.campaign_code,
    v_source.id,
    v_source.source_code,
    v_campaign.reward_type,
    v_campaign.passes_per_claim,
    case
      when v_campaign.requires_external_verification
      then 'verification_pending'
      else 'submitted'
    end,
    'pending',
    v_idempotency_key,
    v_external_reference,
    gen_random_uuid(),
    coalesce(p_evidence, '{}'::jsonb),
    jsonb_build_object(
      'campaign_version', v_campaign.version,
      'source_version', v_source.version,
      'verification_mode', v_source.verification_mode
    )
  )
  returning * into v_claim;

  perform public.commercial_append_event_internal(
    'REWARD_CLAIM_SUBMITTED',
    'REWARD_CLAIM',
    v_claim.id,
    v_claim.user_id,
    v_claim.correlation_id,
    null,
    jsonb_build_object(
      'claim_id', v_claim.id,
      'campaign_code', v_claim.campaign_code,
      'source_code', v_claim.source_code,
      'reward_type', v_claim.reward_type,
      'passes', v_claim.passes_awarded
    )
  );

  return jsonb_build_object(
    'submitted', true,
    'created', true,
    'claim_id', v_claim.id,
    'claim_status', v_claim.claim_status,
    'verification_status', v_claim.verification_status,
    'campaign_code', v_claim.campaign_code,
    'source_code', v_claim.source_code,
    'passes', v_claim.passes_awarded,
    'server_time', clock_timestamp()
  );
end;
$$;

-- ============================================================================
-- 9. INTERNAL CLAIM CREATION
-- ============================================================================

create or replace function public.create_reward_claim_internal(
  p_user_id uuid,
  p_campaign_code text,
  p_external_claim_reference text,
  p_idempotency_key text,
  p_evidence jsonb default '{}'::jsonb,
  p_metadata jsonb default '{}'::jsonb
)
returns public.reward_claims
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_campaign public.reward_campaigns;
  v_source public.reward_sources;
  v_wallet public.commercial_wallets;
  v_existing public.reward_claims;
  v_claim public.reward_claims;
  v_campaign_code text := upper(trim(p_campaign_code));
  v_external_reference text :=
    nullif(trim(p_external_claim_reference), '');
  v_idempotency_key text := nullif(trim(p_idempotency_key), '');
begin
  if p_user_id is null then
    raise exception using
      errcode = '22004',
      message = 'REWARD_USER_ID_REQUIRED';
  end if;

  if v_idempotency_key is null then
    raise exception using
      errcode = '22023',
      message = 'REWARD_IDEMPOTENCY_KEY_REQUIRED';
  end if;

  select *
  into v_existing
  from public.reward_claims
  where user_id = p_user_id
    and client_idempotency_key = v_idempotency_key;

  if found then
    if v_existing.campaign_code <> v_campaign_code
       or v_existing.external_claim_reference
            is distinct from v_external_reference then
      raise exception using
        errcode = '23505',
        message = 'REWARD_CLAIM_IDEMPOTENCY_CONFLICT';
    end if;

    return v_existing;
  end if;

  select *
  into strict v_campaign
  from public.reward_campaigns
  where campaign_code = v_campaign_code
  for share;

  select *
  into strict v_source
  from public.reward_sources
  where id = v_campaign.source_id
  for share;

  if not v_campaign.enabled or not v_source.enabled then
    raise exception using
      errcode = 'P0001',
      message = 'REWARD_CAMPAIGN_OR_SOURCE_DISABLED';
  end if;

  v_wallet := public.commercial_get_or_create_wallet(p_user_id);

  insert into public.reward_claims (
    user_id,
    wallet_id,
    campaign_id,
    campaign_code,
    source_id,
    source_code,
    reward_type,
    passes_awarded,
    claim_status,
    verification_status,
    client_idempotency_key,
    external_claim_reference,
    correlation_id,
    evidence,
    metadata
  )
  values (
    p_user_id,
    v_wallet.id,
    v_campaign.id,
    v_campaign.campaign_code,
    v_source.id,
    v_source.source_code,
    v_campaign.reward_type,
    v_campaign.passes_per_claim,
    'verification_pending',
    'pending',
    v_idempotency_key,
    v_external_reference,
    gen_random_uuid(),
    coalesce(p_evidence, '{}'::jsonb),
    coalesce(p_metadata, '{}'::jsonb)
      || jsonb_build_object(
        'campaign_version', v_campaign.version,
        'source_version', v_source.version
      )
  )
  returning * into v_claim;

  perform public.commercial_append_event_internal(
    'REWARD_CLAIM_CREATED_INTERNAL',
    'REWARD_CLAIM',
    v_claim.id,
    v_claim.user_id,
    v_claim.correlation_id,
    null,
    jsonb_build_object(
      'claim_id', v_claim.id,
      'campaign_code', v_claim.campaign_code,
      'source_code', v_claim.source_code,
      'passes', v_claim.passes_awarded
    )
  );

  return v_claim;
end;
$$;

-- ============================================================================
-- 10. PROVIDER EVENT REGISTRATION
-- ============================================================================

create or replace function public.register_reward_provider_event_internal(
  p_source_code text,
  p_provider_event_id text,
  p_provider_event_type text,
  p_external_claim_reference text,
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
  v_source public.reward_sources;
  v_existing public.reward_provider_events;
  v_event public.reward_provider_events;
  v_source_code text := upper(trim(p_source_code));
  v_event_id text := trim(p_provider_event_id);
  v_payload_hash text := lower(trim(p_payload_hash));
begin
  select *
  into v_source
  from public.reward_sources
  where source_code = v_source_code;

  if not found then
    raise exception using
      errcode = '22023',
      message = 'REWARD_SOURCE_UNKNOWN';
  end if;

  select *
  into v_existing
  from public.reward_provider_events
  where source_id = v_source.id
    and provider_event_id = v_event_id;

  if found then
    if v_existing.payload_hash <> v_payload_hash then
      raise exception using
        errcode = '23505',
        message = 'REWARD_PROVIDER_EVENT_IDEMPOTENCY_CONFLICT';
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

  insert into public.reward_provider_events (
    source_id,
    source_code,
    provider_event_id,
    provider_event_type,
    external_claim_reference,
    payload_hash,
    payload,
    signature_verified,
    processing_status
  )
  values (
    v_source.id,
    v_source.source_code,
    v_event_id,
    trim(p_provider_event_type),
    nullif(trim(p_external_claim_reference), ''),
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
-- 11. ATOMIC VERIFICATION AND SETTLEMENT
-- ============================================================================

create or replace function public.settle_reward_claim_internal(
  p_claim_id uuid,
  p_provider_event_id uuid default null,
  p_external_claim_reference text default null,
  p_metadata jsonb default '{}'::jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_claim public.reward_claims;
  v_campaign public.reward_campaigns;
  v_source public.reward_sources;
  v_provider_event public.reward_provider_events;
  v_ledger public.commercial_ledger;
  v_external_reference text :=
    nullif(trim(p_external_claim_reference), '');
  v_user_settled_claims bigint;
begin
  select *
  into v_claim
  from public.reward_claims
  where id = p_claim_id
  for update;

  if not found then
    return jsonb_build_object(
      'settled', false,
      'error_code', 'REWARD_CLAIM_NOT_FOUND',
      'claim_id', p_claim_id
    );
  end if;

  perform pg_advisory_xact_lock(
    hashtextextended(
      'commercial-wallet:' || v_claim.user_id::text,
      0
    )
  );

  perform pg_advisory_xact_lock(
    hashtextextended(
      'reward-campaign:' || v_claim.campaign_id::text,
      0
    )
  );

  if v_claim.claim_status = 'settled' then
    return jsonb_build_object(
      'settled', true,
      'already_settled', true,
      'claim_id', v_claim.id,
      'ledger_id', v_claim.ledger_transaction_id,
      'passes_awarded', v_claim.passes_awarded
    );
  end if;

  if v_claim.claim_status in ('rejected', 'expired') then
    return jsonb_build_object(
      'settled', false,
      'error_code', 'REWARD_CLAIM_TERMINAL',
      'claim_id', v_claim.id,
      'claim_status', v_claim.claim_status
    );
  end if;

  select *
  into strict v_campaign
  from public.reward_campaigns
  where id = v_claim.campaign_id
  for update;

  select *
  into strict v_source
  from public.reward_sources
  where id = v_claim.source_id
  for share;

  if not v_campaign.enabled or not v_source.enabled then
    return jsonb_build_object(
      'settled', false,
      'error_code', 'REWARD_CAMPAIGN_OR_SOURCE_DISABLED',
      'claim_id', v_claim.id
    );
  end if;

  if v_campaign.starts_at is not null
     and v_campaign.starts_at > clock_timestamp() then
    return jsonb_build_object(
      'settled', false,
      'error_code', 'REWARD_CAMPAIGN_NOT_STARTED',
      'claim_id', v_claim.id
    );
  end if;

  if v_campaign.ends_at is not null
     and v_campaign.ends_at <= clock_timestamp() then
    return jsonb_build_object(
      'settled', false,
      'error_code', 'REWARD_CAMPAIGN_ENDED',
      'claim_id', v_claim.id
    );
  end if;

  if v_campaign.max_total_claims is not null
     and v_campaign.issued_claims >= v_campaign.max_total_claims then
    return jsonb_build_object(
      'settled', false,
      'error_code', 'REWARD_CAMPAIGN_CLAIM_CAP_REACHED',
      'claim_id', v_claim.id
    );
  end if;

  if v_campaign.max_total_passes is not null
     and v_campaign.issued_passes + v_claim.passes_awarded
           > v_campaign.max_total_passes then
    return jsonb_build_object(
      'settled', false,
      'error_code', 'REWARD_CAMPAIGN_PASS_CAP_REACHED',
      'claim_id', v_claim.id
    );
  end if;

  if v_campaign.max_claims_per_user is not null then
    select count(*)
    into v_user_settled_claims
    from public.reward_claims
    where campaign_id = v_campaign.id
      and user_id = v_claim.user_id
      and claim_status = 'settled';

    if v_user_settled_claims >= v_campaign.max_claims_per_user then
      return jsonb_build_object(
        'settled', false,
        'error_code', 'REWARD_USER_CLAIM_LIMIT_REACHED',
        'claim_id', v_claim.id
      );
    end if;
  end if;

  if v_campaign.requires_external_verification then
    if p_provider_event_id is null then
      raise exception using
        errcode = '22023',
        message = 'REWARD_PROVIDER_EVENT_REQUIRED';
    end if;

    select *
    into v_provider_event
    from public.reward_provider_events
    where id = p_provider_event_id
      and source_id = v_claim.source_id
    for share;

    if not found then
      raise exception using
        errcode = '22023',
        message = 'REWARD_PROVIDER_EVENT_NOT_FOUND';
    end if;

    if not v_provider_event.signature_verified then
      raise exception using
        errcode = '42501',
        message = 'REWARD_PROVIDER_SIGNATURE_NOT_VERIFIED';
    end if;

    if v_provider_event.external_claim_reference is not null
       and coalesce(
         v_external_reference,
         v_claim.external_claim_reference
       ) is distinct from
         v_provider_event.external_claim_reference then
      raise exception using
        errcode = '23505',
        message = 'REWARD_EXTERNAL_CLAIM_REFERENCE_MISMATCH';
    end if;
  end if;

  v_external_reference := coalesce(
    v_external_reference,
    v_claim.external_claim_reference,
    case
      when p_provider_event_id is not null
      then v_claim.source_code || ':' || p_provider_event_id::text
      else v_claim.source_code || ':' || v_claim.id::text
    end
  );

  v_ledger := public.commercial_append_ledger_internal(
    v_claim.user_id,
    v_claim.reward_type,
    v_claim.passes_awarded,
    'reward_engine',
    v_claim.correlation_id,
    p_provider_event_id,
    'reward-settlement:' || v_claim.id::text,
    v_external_reference,
    jsonb_build_object(
      'claim_id', v_claim.id,
      'campaign_id', v_claim.campaign_id,
      'campaign_code', v_claim.campaign_code,
      'source_id', v_claim.source_id,
      'source_code', v_claim.source_code,
      'provider_event_id', p_provider_event_id
    ) || coalesce(p_metadata, '{}'::jsonb)
  );

  update public.reward_claims
  set
    claim_status = 'settled',
    verification_status = 'verified',
    external_claim_reference = v_external_reference,
    ledger_transaction_id = v_ledger.id,
    verification_started_at = coalesce(
      verification_started_at,
      clock_timestamp()
    ),
    verified_at = clock_timestamp(),
    settled_at = clock_timestamp(),
    rejection_code = null,
    rejection_message = null,
    metadata = metadata || coalesce(p_metadata, '{}'::jsonb)
  where id = v_claim.id
  returning * into v_claim;

  perform set_config(
    'fantagol.reward_internal_write',
    'on',
    true
  );

  update public.reward_campaigns
  set
    issued_claims = issued_claims + 1,
    issued_passes = issued_passes + v_claim.passes_awarded
  where id = v_campaign.id;

  if p_provider_event_id is not null then
    perform public.commercial_append_event_internal(
      'REWARD_PROVIDER_EVENT_PROCESSED',
      'REWARD_PROVIDER_EVENT',
      p_provider_event_id,
      v_claim.user_id,
      v_provider_event.correlation_id,
      v_claim.id,
      jsonb_build_object(
        'provider_event_id', p_provider_event_id,
        'claim_id', v_claim.id,
        'external_claim_reference', v_external_reference
      )
    );
  end if;

  perform public.commercial_append_event_internal(
    'REWARD_CLAIM_SETTLED',
    'REWARD_CLAIM',
    v_claim.id,
    v_claim.user_id,
    v_claim.correlation_id,
    p_provider_event_id,
    jsonb_build_object(
      'claim_id', v_claim.id,
      'campaign_code', v_claim.campaign_code,
      'source_code', v_claim.source_code,
      'reward_type', v_claim.reward_type,
      'passes_awarded', v_claim.passes_awarded,
      'ledger_id', v_ledger.id,
      'balance_after', v_ledger.balance_after
    )
  );

  return jsonb_build_object(
    'settled', true,
    'already_settled', false,
    'claim_id', v_claim.id,
    'ledger_id', v_ledger.id,
    'reward_type', v_claim.reward_type,
    'passes_awarded', v_claim.passes_awarded,
    'available_passes', v_ledger.balance_after,
    'settled_at', v_claim.settled_at
  );
end;
$$;

-- ============================================================================
-- 12. CLAIM REJECTION / EXPIRATION
-- ============================================================================

create or replace function public.close_reward_claim_internal(
  p_claim_id uuid,
  p_outcome text,
  p_reason_code text default null,
  p_reason_message text default null,
  p_metadata jsonb default '{}'::jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_claim public.reward_claims;
  v_outcome text := lower(trim(p_outcome));
  v_reason_code text := nullif(trim(p_reason_code), '');
begin
  if v_outcome not in ('rejected', 'expired') then
    raise exception using
      errcode = '22023',
      message = 'REWARD_CLAIM_CLOSE_OUTCOME_INVALID';
  end if;

  if v_outcome = 'rejected' and v_reason_code is null then
    raise exception using
      errcode = '22023',
      message = 'REWARD_REJECTION_CODE_REQUIRED';
  end if;

  select *
  into v_claim
  from public.reward_claims
  where id = p_claim_id
  for update;

  if not found then
    return jsonb_build_object(
      'closed', false,
      'error_code', 'REWARD_CLAIM_NOT_FOUND',
      'claim_id', p_claim_id
    );
  end if;

  if v_claim.claim_status = v_outcome then
    return jsonb_build_object(
      'closed', true,
      'already_closed', true,
      'claim_id', v_claim.id,
      'claim_status', v_claim.claim_status
    );
  end if;

  if v_claim.claim_status in ('settled', 'rejected', 'expired') then
    return jsonb_build_object(
      'closed', false,
      'error_code', 'REWARD_CLAIM_TERMINAL',
      'claim_id', v_claim.id,
      'claim_status', v_claim.claim_status
    );
  end if;

  update public.reward_claims
  set
    claim_status = v_outcome,
    verification_status = v_outcome,
    rejected_at = case
      when v_outcome = 'rejected'
      then clock_timestamp()
      else rejected_at
    end,
    expired_at = case
      when v_outcome = 'expired'
      then clock_timestamp()
      else expired_at
    end,
    rejection_code = case
      when v_outcome = 'rejected'
      then v_reason_code
      else rejection_code
    end,
    rejection_message = case
      when v_outcome = 'rejected'
      then nullif(trim(p_reason_message), '')
      else rejection_message
    end,
    metadata = metadata || coalesce(p_metadata, '{}'::jsonb)
  where id = v_claim.id
  returning * into v_claim;

  perform public.commercial_append_event_internal(
    case
      when v_outcome = 'rejected'
      then 'REWARD_CLAIM_REJECTED'
      else 'REWARD_CLAIM_EXPIRED'
    end,
    'REWARD_CLAIM',
    v_claim.id,
    v_claim.user_id,
    v_claim.correlation_id,
    null,
    jsonb_build_object(
      'claim_id', v_claim.id,
      'claim_status', v_claim.claim_status,
      'reason_code', v_claim.rejection_code
    )
  );

  return jsonb_build_object(
    'closed', true,
    'already_closed', false,
    'claim_id', v_claim.id,
    'claim_status', v_claim.claim_status,
    'verification_status', v_claim.verification_status
  );
end;
$$;

-- ============================================================================
-- 13. AUTHENTICATED CLAIM HISTORY
-- ============================================================================

create or replace function public.get_my_reward_claims_rpc(
  p_limit integer default 50,
  p_offset integer default 0
)
returns table (
  claim_id uuid,
  campaign_code text,
  source_code text,
  reward_type text,
  passes_awarded integer,
  claim_status text,
  verification_status text,
  submitted_at timestamptz,
  verified_at timestamptz,
  rejected_at timestamptz,
  settled_at timestamptz,
  expired_at timestamptz
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
    c.id,
    c.campaign_code,
    c.source_code,
    c.reward_type,
    c.passes_awarded,
    c.claim_status,
    c.verification_status,
    c.submitted_at,
    c.verified_at,
    c.rejected_at,
    c.settled_at,
    c.expired_at
  from public.reward_claims c
  where c.user_id = v_user_id
  order by c.created_at desc
  limit v_limit
  offset v_offset;
end;
$$;

create or replace function public.get_my_reward_claim_rpc(
  p_claim_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_user_id uuid;
  v_claim public.reward_claims;
begin
  v_user_id := public.commercial_assert_authenticated_user();

  select *
  into v_claim
  from public.reward_claims
  where id = p_claim_id
    and user_id = v_user_id;

  if not found then
    return jsonb_build_object(
      'found', false,
      'error_code', 'REWARD_CLAIM_NOT_FOUND'
    );
  end if;

  return jsonb_build_object(
    'found', true,
    'claim_id', v_claim.id,
    'campaign_code', v_claim.campaign_code,
    'source_code', v_claim.source_code,
    'reward_type', v_claim.reward_type,
    'passes_awarded', v_claim.passes_awarded,
    'claim_status', v_claim.claim_status,
    'verification_status', v_claim.verification_status,
    'external_claim_reference',
      v_claim.external_claim_reference,
    'submitted_at', v_claim.submitted_at,
    'verified_at', v_claim.verified_at,
    'rejected_at', v_claim.rejected_at,
    'settled_at', v_claim.settled_at,
    'expired_at', v_claim.expired_at,
    'server_time', clock_timestamp()
  );
end;
$$;

-- ============================================================================
-- 14. ROW LEVEL SECURITY
-- ============================================================================

alter table public.reward_sources enable row level security;
alter table public.reward_campaigns enable row level security;
alter table public.reward_claims enable row level security;
alter table public.reward_provider_events enable row level security;

drop policy if exists reward_campaigns_authenticated_read
  on public.reward_campaigns;

create policy reward_campaigns_authenticated_read
on public.reward_campaigns
for select
to authenticated
using (
  enabled = true
  and public = true
  and (
    starts_at is null
    or starts_at <= clock_timestamp()
  )
  and (
    ends_at is null
    or ends_at > clock_timestamp()
  )
);

drop policy if exists reward_claims_owner_read
  on public.reward_claims;

create policy reward_claims_owner_read
on public.reward_claims
for select
to authenticated
using (user_id = auth.uid());

-- Reward sources and provider events remain backend-only.

-- ============================================================================
-- 15. PRIVILEGES
-- ============================================================================

revoke all on table public.reward_sources
  from anon, authenticated;

revoke all on table public.reward_campaigns
  from anon, authenticated;

revoke all on table public.reward_claims
  from anon, authenticated;

revoke all on table public.reward_provider_events
  from anon, authenticated;

grant select on table public.reward_campaigns
  to authenticated;

grant select on table public.reward_claims
  to authenticated;

grant all on table public.reward_sources
  to service_role;

grant all on table public.reward_campaigns
  to service_role;

grant all on table public.reward_claims
  to service_role;

grant all on table public.reward_provider_events
  to service_role;

revoke all on function public.get_reward_campaigns_rpc()
  from public, anon;

revoke all on function public.submit_my_reward_claim_rpc(
  text, text, text, jsonb
) from public, anon;

revoke all on function public.get_my_reward_claims_rpc(
  integer, integer
) from public, anon;

revoke all on function public.get_my_reward_claim_rpc(uuid)
  from public, anon;

grant execute on function public.get_reward_campaigns_rpc()
  to authenticated;

grant execute on function public.submit_my_reward_claim_rpc(
  text, text, text, jsonb
) to authenticated;

grant execute on function public.get_my_reward_claims_rpc(
  integer, integer
) to authenticated;

grant execute on function public.get_my_reward_claim_rpc(uuid)
  to authenticated;

revoke all on function public.create_reward_claim_internal(
  uuid, text, text, text, jsonb, jsonb
) from public, anon, authenticated;

revoke all on function public.register_reward_provider_event_internal(
  text, text, text, text, text, jsonb, boolean
) from public, anon, authenticated;

revoke all on function public.settle_reward_claim_internal(
  uuid, uuid, text, jsonb
) from public, anon, authenticated;

revoke all on function public.close_reward_claim_internal(
  uuid, text, text, text, jsonb
) from public, anon, authenticated;

grant execute on function public.create_reward_claim_internal(
  uuid, text, text, text, jsonb, jsonb
) to service_role;

grant execute on function public.register_reward_provider_event_internal(
  text, text, text, text, text, jsonb, boolean
) to service_role;

grant execute on function public.settle_reward_claim_internal(
  uuid, uuid, text, jsonb
) to service_role;

grant execute on function public.close_reward_claim_internal(
  uuid, text, text, text, jsonb
) to service_role;

-- ============================================================================
-- 16. FOUNDATION SEEDS
-- ============================================================================

insert into public.reward_sources (
  source_code,
  display_name,
  source_type,
  provider_code,
  enabled,
  test_mode,
  verification_mode,
  priority,
  configuration,
  metadata
)
values
  (
    'REWARDED_AD',
    'Rewarded Advertising',
    'rewarded_ad',
    null,
    false,
    true,
    'signed_callback',
    10,
    jsonb_build_object(
      'adapter_status', 'not_configured',
      'server_side_verification_required', true
    ),
    jsonb_build_object(
      'foundation_version', '1.0',
      'provider_independent', true
    )
  ),
  (
    'PROMOTION',
    'Promotion',
    'promotion',
    null,
    false,
    true,
    'backend',
    20,
    jsonb_build_object(
      'activation_status', 'not_configured'
    ),
    jsonb_build_object(
      'foundation_version', '1.0'
    )
  ),
  (
    'REFERRAL',
    'Referral',
    'referral',
    null,
    false,
    true,
    'backend',
    30,
    jsonb_build_object(
      'referral_engine_status', 'not_implemented'
    ),
    jsonb_build_object(
      'foundation_version', '1.0'
    )
  ),
  (
    'GIFT',
    'Gift',
    'gift',
    null,
    false,
    true,
    'manual_review',
    40,
    jsonb_build_object(
      'gift_inventory_status', 'not_implemented'
    ),
    jsonb_build_object(
      'foundation_version', '1.0'
    )
  )
on conflict (source_code) do update
set
  display_name = excluded.display_name,
  source_type = excluded.source_type,
  provider_code = excluded.provider_code,
  priority = excluded.priority,
  configuration = excluded.configuration,
  metadata = excluded.metadata;

insert into public.reward_campaigns (
  campaign_code,
  source_id,
  title,
  description,
  reward_type,
  passes_per_claim,
  enabled,
  public,
  max_claims_per_user,
  cooldown_seconds,
  requires_external_verification,
  metadata
)
select
  'REWARDED_AD_FOUNDATION',
  s.id,
  'Rewarded Ad Foundation',
  'Technical seed for future server-verified rewarded advertising.',
  'PASS_REWARD',
  1,
  false,
  false,
  null,
  3600,
  true,
  jsonb_build_object(
    'foundation_seed', true,
    'reward_value_requires_commercial_approval', true
  )
from public.reward_sources s
where s.source_code = 'REWARDED_AD'
on conflict (campaign_code) do update
set
  source_id = excluded.source_id,
  title = excluded.title,
  description = excluded.description,
  reward_type = excluded.reward_type,
  passes_per_claim = excluded.passes_per_claim,
  max_claims_per_user = excluded.max_claims_per_user,
  cooldown_seconds = excluded.cooldown_seconds,
  requires_external_verification =
    excluded.requires_external_verification,
  metadata = excluded.metadata;

-- Every reward source and campaign remains disabled until its adapter,
-- anti-fraud rules, legal disclosures and commercial values are approved.

-- ============================================================================
-- 17. DOCUMENTATION COMMENTS
-- ============================================================================

comment on function public.get_reward_campaigns_rpc() is
  'Returns enabled, public and currently valid reward campaigns.';

comment on function public.submit_my_reward_claim_rpc(
  text, text, text, jsonb
) is
  'Creates an authenticated idempotent reward claim but never awards Passes directly.';

comment on function public.settle_reward_claim_internal(
  uuid, uuid, text, jsonb
) is
  'Backend-only atomic verification and reward settlement through the immutable commercial ledger.';

comment on function public.register_reward_provider_event_internal(
  text, text, text, text, text, jsonb, boolean
) is
  'Backend-only idempotent registration of reward-provider callbacks after adapter-level signature verification.';

-- ============================================================================
-- 18. FOUNDATION ASSERTIONS
-- ============================================================================

do $$
declare
  v_source_count integer;
  v_campaign public.reward_campaigns;
begin
  select count(*)
  into v_source_count
  from public.reward_sources
  where source_code in (
    'REWARDED_AD',
    'PROMOTION',
    'REFERRAL',
    'GIFT'
  );

  if v_source_count <> 4 then
    raise exception
      'REWARD_ENGINE_FOUNDATION_ASSERTION_FAILED: source seed count';
  end if;

  if exists (
    select 1
    from public.reward_sources
    where source_code in (
      'REWARDED_AD',
      'PROMOTION',
      'REFERRAL',
      'GIFT'
    )
      and enabled = true
  ) then
    raise exception
      'REWARD_ENGINE_FOUNDATION_ASSERTION_FAILED: sources must remain disabled';
  end if;

  select *
  into strict v_campaign
  from public.reward_campaigns
  where campaign_code = 'REWARDED_AD_FOUNDATION';

  if v_campaign.enabled or v_campaign.public then
    raise exception
      'REWARD_ENGINE_FOUNDATION_ASSERTION_FAILED: campaign must remain hidden';
  end if;

  if not exists (
    select 1
    from pg_indexes
    where schemaname = 'public'
      and indexname = 'reward_claims_external_reference_uidx'
  ) then
    raise exception
      'REWARD_ENGINE_FOUNDATION_ASSERTION_FAILED: external reference uniqueness';
  end if;

  if not exists (
    select 1
    from pg_trigger
    where tgname = 'reward_provider_events_append_only_guard'
      and not tgisinternal
  ) then
    raise exception
      'REWARD_ENGINE_FOUNDATION_ASSERTION_FAILED: provider event append-only guard';
  end if;

  raise notice 'REWARD ENGINE FOUNDATION CERTIFIED';
  raise notice 'Reward sources seeded but disabled';
  raise notice 'Rewarded-ad campaign seeded but hidden pending approval';
end;
$$;

commit;
