-- ============================================================================
-- FANTAGOL LOYALTY REWARD POLICY FOUNDATION
-- Migration: 104_loyalty_reward_policy_foundation.sql
-- Version: 1.0
-- Domain: Commercial Platform / Loyalty Reward Policy Engine
--
-- Certified scope:
--   - Hidden loyalty reward policy registry
--   - Ten approved contribution and merit objectives
--   - Certified-event-only reward award path
--   - Deterministic anti-duplication by reward scope
--   - Atomic integration with Reward Engine 103 and Commercial Ledger 101
--   - Persistent unseen reward revelation state for drawer UX
--   - Hamburger pulse / badge / Control Room balance animation read model
--   - Backend-only award execution
--   - Authenticated acknowledgement of revealed rewards
--   - RLS, grants, audit events, seeds and assertions
--
-- Explicitly excluded by product policy:
--   - Welcome bonuses
--   - Registration bonuses
--   - First-login bonuses
--   - Daily-login bonuses
--   - Public missions, progress bars or reward catalogs
--   - Popup, modal or intrusive reward notifications
--
-- Explicitly out of scope:
--   - Domain event producers and workflow launchers
--   - Frontend animation implementation
--   - Final commercial value approval for each campaign
--   - Automatic activation of any reward source, campaign or policy
-- ============================================================================

begin;

-- ============================================================================
-- 0. PRECONDITION ASSERTIONS
-- ============================================================================

do $$
begin
  if to_regclass('public.commercial_wallets') is null
     or to_regclass('public.commercial_ledger') is null
     or to_regclass('public.commercial_platform_events') is null
     or to_regclass('public.reward_sources') is null
     or to_regclass('public.reward_campaigns') is null
     or to_regclass('public.reward_claims') is null then
    raise exception
      'LOYALTY_REWARD_POLICY_PRECONDITION_FAILED: migrations 101 and 103 are required';
  end if;
end;
$$;

-- ============================================================================
-- 1. EXTEND COMMERCIAL AUDIT AGGREGATE VOCABULARY
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
      'REWARD_PROVIDER_EVENT',
      'LOYALTY_REWARD_POLICY',
      'LOYALTY_REWARD_EVENT',
      'REWARD_REVELATION'
    )
  );

-- ============================================================================
-- 2. HIDDEN LOYALTY REWARD POLICY REGISTRY
-- ============================================================================

create table if not exists public.loyalty_reward_policies (
  id uuid primary key default gen_random_uuid(),
  policy_code text not null,
  event_code text not null,
  campaign_id uuid not null,
  campaign_code text not null,
  reward_scope text not null,
  enabled boolean not null default false,
  hidden boolean not null default true,
  requires_certified_event boolean not null default true,
  priority integer not null default 100,
  configuration jsonb not null default '{}'::jsonb,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default clock_timestamp(),
  updated_at timestamptz not null default clock_timestamp(),
  version integer not null default 1,

  constraint loyalty_reward_policies_policy_code_key
    unique (policy_code),

  constraint loyalty_reward_policies_event_code_key
    unique (event_code),

  constraint loyalty_reward_policies_campaign_id_key
    unique (campaign_id),

  constraint loyalty_reward_policies_campaign_id_fkey
    foreign key (campaign_id)
    references public.reward_campaigns (id)
    on delete restrict,

  constraint loyalty_reward_policies_policy_code_check
    check (
      policy_code = upper(policy_code)
      and policy_code ~ '^[A-Z][A-Z0-9_]{2,95}$'
    ),

  constraint loyalty_reward_policies_event_code_check
    check (
      event_code = upper(event_code)
      and event_code ~ '^[A-Z][A-Z0-9_]{2,95}$'
    ),

  constraint loyalty_reward_policies_campaign_code_check
    check (
      campaign_code = upper(campaign_code)
      and campaign_code ~ '^[A-Z][A-Z0-9_]{2,95}$'
    ),

  constraint loyalty_reward_policies_reward_scope_check
    check (
      reward_scope in (
        'account',
        'league',
        'league_round',
        'prediction_result',
        'league_season',
        'league_season_streak'
      )
    ),

  constraint loyalty_reward_policies_hidden_check
    check (hidden = true),

  constraint loyalty_reward_policies_certified_check
    check (requires_certified_event = true),

  constraint loyalty_reward_policies_priority_check
    check (priority >= 0),

  constraint loyalty_reward_policies_configuration_object_check
    check (jsonb_typeof(configuration) = 'object'),

  constraint loyalty_reward_policies_metadata_object_check
    check (jsonb_typeof(metadata) = 'object'),

  constraint loyalty_reward_policies_version_check
    check (version > 0)
);

create index if not exists loyalty_reward_policies_runtime_idx
  on public.loyalty_reward_policies (
    enabled,
    event_code,
    priority
  );

comment on table public.loyalty_reward_policies is
  'Backend-only hidden mapping between certified FantaGol domain events and Reward Engine campaigns.';

-- ============================================================================
-- 3. CERTIFIED LOYALTY REWARD EVENTS
-- ============================================================================

create table if not exists public.loyalty_reward_events (
  id uuid primary key default gen_random_uuid(),
  policy_id uuid not null,
  policy_code text not null,
  event_code text not null,
  event_key text not null,
  deduplication_key text not null,
  user_id uuid not null,
  league_id uuid null,
  league_round_id uuid null,
  season_id uuid null,
  prediction_result_id uuid null,
  certification_reference text not null,
  event_status text not null default 'processing',
  claim_id uuid null,
  ledger_transaction_id uuid null,
  passes_awarded integer null,
  balance_before integer null,
  balance_after integer null,
  correlation_id uuid not null,
  causation_id uuid null,
  occurred_at timestamptz not null,
  processed_at timestamptz null,
  failure_code text null,
  payload jsonb not null default '{}'::jsonb,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default clock_timestamp(),
  updated_at timestamptz not null default clock_timestamp(),
  version integer not null default 1,

  constraint loyalty_reward_events_policy_id_fkey
    foreign key (policy_id)
    references public.loyalty_reward_policies (id)
    on delete restrict,

  constraint loyalty_reward_events_user_id_fkey
    foreign key (user_id)
    references auth.users (id)
    on delete restrict,

  constraint loyalty_reward_events_claim_id_fkey
    foreign key (claim_id)
    references public.reward_claims (id)
    on delete restrict,

  constraint loyalty_reward_events_ledger_id_fkey
    foreign key (ledger_transaction_id)
    references public.commercial_ledger (id)
    on delete restrict,

  constraint loyalty_reward_events_event_key_key
    unique (event_key),

  constraint loyalty_reward_events_deduplication_key_key
    unique (deduplication_key),

  constraint loyalty_reward_events_claim_id_key
    unique (claim_id),

  constraint loyalty_reward_events_ledger_id_key
    unique (ledger_transaction_id),

  constraint loyalty_reward_events_policy_code_check
    check (
      policy_code = upper(policy_code)
      and policy_code ~ '^[A-Z][A-Z0-9_]{2,95}$'
    ),

  constraint loyalty_reward_events_event_code_check
    check (
      event_code = upper(event_code)
      and event_code ~ '^[A-Z][A-Z0-9_]{2,95}$'
    ),

  constraint loyalty_reward_events_event_key_check
    check (length(trim(event_key)) between 8 and 300),

  constraint loyalty_reward_events_deduplication_key_check
    check (length(trim(deduplication_key)) between 8 and 500),

  constraint loyalty_reward_events_certification_reference_check
    check (length(trim(certification_reference)) between 8 and 500),

  constraint loyalty_reward_events_status_check
    check (
      event_status in (
        'processing',
        'rewarded',
        'ignored',
        'failed'
      )
    ),

  constraint loyalty_reward_events_passes_check
    check (passes_awarded is null or passes_awarded > 0),

  constraint loyalty_reward_events_balances_check
    check (
      (balance_before is null and balance_after is null)
      or (
        balance_before >= 0
        and balance_after >= balance_before
      )
    ),

  constraint loyalty_reward_events_failure_code_check
    check (
      failure_code is null
      or length(trim(failure_code)) between 1 and 160
    ),

  constraint loyalty_reward_events_payload_object_check
    check (jsonb_typeof(payload) = 'object'),

  constraint loyalty_reward_events_metadata_object_check
    check (jsonb_typeof(metadata) = 'object'),

  constraint loyalty_reward_events_version_check
    check (version > 0),

  constraint loyalty_reward_events_rewarded_consistency_check
    check (
      event_status <> 'rewarded'
      or (
        claim_id is not null
        and ledger_transaction_id is not null
        and passes_awarded is not null
        and balance_before is not null
        and balance_after is not null
        and processed_at is not null
        and failure_code is null
      )
    ),

  constraint loyalty_reward_events_failed_consistency_check
    check (
      event_status <> 'failed'
      or (
        processed_at is not null
        and failure_code is not null
      )
    )
);

create index if not exists loyalty_reward_events_user_created_idx
  on public.loyalty_reward_events (user_id, created_at desc);

create index if not exists loyalty_reward_events_policy_created_idx
  on public.loyalty_reward_events (policy_id, created_at desc);

create index if not exists loyalty_reward_events_scope_idx
  on public.loyalty_reward_events (
    league_id,
    league_round_id,
    season_id,
    prediction_result_id
  );

create index if not exists loyalty_reward_events_status_idx
  on public.loyalty_reward_events (event_status, created_at);

comment on table public.loyalty_reward_events is
  'One persistent backend-certified reward occurrence per deterministic reward scope.';

-- ============================================================================
-- 4. REWARD REVELATION READ MODEL
-- ============================================================================

create table if not exists public.reward_revelations (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null,
  loyalty_reward_event_id uuid not null,
  claim_id uuid not null,
  ledger_transaction_id uuid not null,
  passes_awarded integer not null,
  balance_before integer not null,
  balance_after integer not null,
  revelation_status text not null default 'unseen',
  available_at timestamptz not null default clock_timestamp(),
  seen_at timestamptz null,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default clock_timestamp(),
  updated_at timestamptz not null default clock_timestamp(),
  version integer not null default 1,

  constraint reward_revelations_user_id_fkey
    foreign key (user_id)
    references auth.users (id)
    on delete restrict,

  constraint reward_revelations_event_id_fkey
    foreign key (loyalty_reward_event_id)
    references public.loyalty_reward_events (id)
    on delete restrict,

  constraint reward_revelations_claim_id_fkey
    foreign key (claim_id)
    references public.reward_claims (id)
    on delete restrict,

  constraint reward_revelations_ledger_id_fkey
    foreign key (ledger_transaction_id)
    references public.commercial_ledger (id)
    on delete restrict,

  constraint reward_revelations_event_id_key
    unique (loyalty_reward_event_id),

  constraint reward_revelations_claim_id_key
    unique (claim_id),

  constraint reward_revelations_ledger_id_key
    unique (ledger_transaction_id),

  constraint reward_revelations_passes_check
    check (passes_awarded > 0),

  constraint reward_revelations_balance_before_check
    check (balance_before >= 0),

  constraint reward_revelations_balance_after_check
    check (balance_after = balance_before + passes_awarded),

  constraint reward_revelations_status_check
    check (revelation_status in ('unseen', 'seen')),

  constraint reward_revelations_seen_consistency_check
    check (
      (revelation_status = 'unseen' and seen_at is null)
      or (revelation_status = 'seen' and seen_at is not null)
    ),

  constraint reward_revelations_metadata_object_check
    check (jsonb_typeof(metadata) = 'object'),

  constraint reward_revelations_version_check
    check (version > 0)
);

create index if not exists reward_revelations_unseen_user_idx
  on public.reward_revelations (user_id, available_at, id)
  where revelation_status = 'unseen';

create index if not exists reward_revelations_user_created_idx
  on public.reward_revelations (user_id, created_at desc);

comment on table public.reward_revelations is
  'Persistent UX read model for non-intrusive reward discovery through the hamburger and Control Room drawer card.';

-- ============================================================================
-- 5. UPDATED_AT TRIGGERS
-- ============================================================================

drop trigger if exists loyalty_reward_policies_set_updated_at
  on public.loyalty_reward_policies;

create trigger loyalty_reward_policies_set_updated_at
before update on public.loyalty_reward_policies
for each row execute function public.commercial_set_updated_at();

drop trigger if exists loyalty_reward_events_set_updated_at
  on public.loyalty_reward_events;

create trigger loyalty_reward_events_set_updated_at
before update on public.loyalty_reward_events
for each row execute function public.commercial_set_updated_at();

drop trigger if exists reward_revelations_set_updated_at
  on public.reward_revelations;

create trigger reward_revelations_set_updated_at
before update on public.reward_revelations
for each row execute function public.commercial_set_updated_at();

-- ============================================================================
-- 6. MUTATION GUARDS
-- ============================================================================

create or replace function public.guard_loyalty_reward_policy_projection()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
  if (
    new.campaign_id is distinct from old.campaign_id
    or new.campaign_code is distinct from old.campaign_code
    or new.policy_code is distinct from old.policy_code
    or new.event_code is distinct from old.event_code
    or new.reward_scope is distinct from old.reward_scope
    or new.hidden is distinct from old.hidden
    or new.requires_certified_event
         is distinct from old.requires_certified_event
    or new.created_at is distinct from old.created_at
  ) then
    raise exception using
      errcode = 'P0001',
      message = 'LOYALTY_REWARD_POLICY_IDENTITY_IMMUTABLE';
  end if;

  return new;
end;
$$;

drop trigger if exists loyalty_reward_policies_projection_guard
  on public.loyalty_reward_policies;

create trigger loyalty_reward_policies_projection_guard
before update on public.loyalty_reward_policies
for each row execute function public.guard_loyalty_reward_policy_projection();

create or replace function public.guard_loyalty_reward_event_mutation()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
  if current_setting(
       'fantagol.loyalty_reward_internal_write',
       true
     ) is distinct from 'on' then
    raise exception using
      errcode = '42501',
      message = 'LOYALTY_REWARD_EVENT_INTERNAL_ONLY';
  end if;

  if (
    new.policy_id is distinct from old.policy_id
    or new.policy_code is distinct from old.policy_code
    or new.event_code is distinct from old.event_code
    or new.event_key is distinct from old.event_key
    or new.deduplication_key is distinct from old.deduplication_key
    or new.user_id is distinct from old.user_id
    or new.league_id is distinct from old.league_id
    or new.league_round_id is distinct from old.league_round_id
    or new.season_id is distinct from old.season_id
    or new.prediction_result_id is distinct from old.prediction_result_id
    or new.certification_reference
         is distinct from old.certification_reference
    or new.correlation_id is distinct from old.correlation_id
    or new.causation_id is distinct from old.causation_id
    or new.occurred_at is distinct from old.occurred_at
    or new.created_at is distinct from old.created_at
  ) then
    raise exception using
      errcode = 'P0001',
      message = 'LOYALTY_REWARD_EVENT_IDENTITY_IMMUTABLE';
  end if;

  if old.event_status in ('rewarded', 'ignored', 'failed')
     and new.event_status <> old.event_status then
    raise exception using
      errcode = 'P0001',
      message = 'LOYALTY_REWARD_EVENT_TERMINAL_STATE_IMMUTABLE';
  end if;

  return new;
end;
$$;

drop trigger if exists loyalty_reward_events_mutation_guard
  on public.loyalty_reward_events;

create trigger loyalty_reward_events_mutation_guard
before update on public.loyalty_reward_events
for each row execute function public.guard_loyalty_reward_event_mutation();

create or replace function public.guard_loyalty_reward_event_insert()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
  if current_setting(
       'fantagol.loyalty_reward_internal_write',
       true
     ) is distinct from 'on' then
    raise exception using
      errcode = '42501',
      message = 'LOYALTY_REWARD_EVENT_INSERT_INTERNAL_ONLY';
  end if;

  return new;
end;
$$;

drop trigger if exists loyalty_reward_events_internal_insert_guard
  on public.loyalty_reward_events;

create trigger loyalty_reward_events_internal_insert_guard
before insert on public.loyalty_reward_events
for each row execute function public.guard_loyalty_reward_event_insert();

create or replace function public.guard_reward_revelation_mutation()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
  if current_setting(
       'fantagol.reward_revelation_internal_write',
       true
     ) is distinct from 'on' then
    raise exception using
      errcode = '42501',
      message = 'REWARD_REVELATION_INTERNAL_ONLY';
  end if;

  if (
    new.user_id is distinct from old.user_id
    or new.loyalty_reward_event_id
         is distinct from old.loyalty_reward_event_id
    or new.claim_id is distinct from old.claim_id
    or new.ledger_transaction_id
         is distinct from old.ledger_transaction_id
    or new.passes_awarded is distinct from old.passes_awarded
    or new.balance_before is distinct from old.balance_before
    or new.balance_after is distinct from old.balance_after
    or new.available_at is distinct from old.available_at
    or new.created_at is distinct from old.created_at
  ) then
    raise exception using
      errcode = 'P0001',
      message = 'REWARD_REVELATION_IDENTITY_IMMUTABLE';
  end if;

  if old.revelation_status = 'seen'
     and new.revelation_status <> 'seen' then
    raise exception using
      errcode = 'P0001',
      message = 'REWARD_REVELATION_SEEN_STATE_IMMUTABLE';
  end if;

  return new;
end;
$$;

drop trigger if exists reward_revelations_mutation_guard
  on public.reward_revelations;

create trigger reward_revelations_mutation_guard
before update on public.reward_revelations
for each row execute function public.guard_reward_revelation_mutation();

create or replace function public.guard_reward_revelation_insert()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
  if current_setting(
       'fantagol.reward_revelation_internal_write',
       true
     ) is distinct from 'on' then
    raise exception using
      errcode = '42501',
      message = 'REWARD_REVELATION_INSERT_INTERNAL_ONLY';
  end if;

  return new;
end;
$$;

drop trigger if exists reward_revelations_internal_insert_guard
  on public.reward_revelations;

create trigger reward_revelations_internal_insert_guard
before insert on public.reward_revelations
for each row execute function public.guard_reward_revelation_insert();

-- ============================================================================
-- 7. DETERMINISTIC REWARD SCOPE KEY
-- ============================================================================

create or replace function public.build_loyalty_reward_deduplication_key(
  p_policy_code text,
  p_reward_scope text,
  p_user_id uuid,
  p_league_id uuid default null,
  p_league_round_id uuid default null,
  p_season_id uuid default null,
  p_prediction_result_id uuid default null
)
returns text
language plpgsql
immutable
set search_path = public, pg_temp
as $$
declare
  v_policy_code text := upper(trim(p_policy_code));
  v_scope text := lower(trim(p_reward_scope));
begin
  if p_user_id is null then
    raise exception using
      errcode = '22004',
      message = 'LOYALTY_REWARD_USER_ID_REQUIRED';
  end if;

  case v_scope
    when 'account' then
      return concat_ws(':', 'loyalty', v_policy_code, p_user_id);

    when 'league' then
      if p_league_id is null then
        raise exception using
          errcode = '22004',
          message = 'LOYALTY_REWARD_LEAGUE_ID_REQUIRED';
      end if;

      return concat_ws(
        ':', 'loyalty', v_policy_code, p_user_id, p_league_id
      );

    when 'league_round' then
      if p_league_id is null or p_league_round_id is null then
        raise exception using
          errcode = '22004',
          message = 'LOYALTY_REWARD_LEAGUE_ROUND_SCOPE_REQUIRED';
      end if;

      return concat_ws(
        ':',
        'loyalty',
        v_policy_code,
        p_user_id,
        p_league_id,
        p_league_round_id
      );

    when 'prediction_result' then
      if p_prediction_result_id is null then
        raise exception using
          errcode = '22004',
          message = 'LOYALTY_REWARD_PREDICTION_RESULT_REQUIRED';
      end if;

      return concat_ws(
        ':',
        'loyalty',
        v_policy_code,
        p_user_id,
        p_prediction_result_id
      );

    when 'league_season' then
      if p_league_id is null or p_season_id is null then
        raise exception using
          errcode = '22004',
          message = 'LOYALTY_REWARD_LEAGUE_SEASON_SCOPE_REQUIRED';
      end if;

      return concat_ws(
        ':',
        'loyalty',
        v_policy_code,
        p_user_id,
        p_league_id,
        p_season_id
      );

    when 'league_season_streak' then
      if p_league_id is null or p_season_id is null then
        raise exception using
          errcode = '22004',
          message = 'LOYALTY_REWARD_STREAK_SCOPE_REQUIRED';
      end if;

      return concat_ws(
        ':',
        'loyalty',
        v_policy_code,
        p_user_id,
        p_league_id,
        p_season_id
      );

    else
      raise exception using
        errcode = '22023',
        message = 'LOYALTY_REWARD_SCOPE_INVALID';
  end case;
end;
$$;

-- ============================================================================
-- 8. BACKEND-ONLY CERTIFIED LOYALTY AWARD
-- ============================================================================

create or replace function public.award_loyalty_reward_internal(
  p_user_id uuid,
  p_event_code text,
  p_event_key text,
  p_certification_reference text,
  p_occurred_at timestamptz default clock_timestamp(),
  p_league_id uuid default null,
  p_league_round_id uuid default null,
  p_season_id uuid default null,
  p_prediction_result_id uuid default null,
  p_correlation_id uuid default null,
  p_causation_id uuid default null,
  p_payload jsonb default '{}'::jsonb,
  p_metadata jsonb default '{}'::jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_event_code text := upper(trim(p_event_code));
  v_event_key text := nullif(trim(p_event_key), '');
  v_certification_reference text :=
    nullif(trim(p_certification_reference), '');
  v_policy public.loyalty_reward_policies;
  v_campaign public.reward_campaigns;
  v_source public.reward_sources;
  v_existing public.loyalty_reward_events;
  v_event public.loyalty_reward_events;
  v_claim public.reward_claims;
  v_ledger public.commercial_ledger;
  v_settlement jsonb;
  v_deduplication_key text;
  v_correlation_id uuid := coalesce(p_correlation_id, gen_random_uuid());
begin
  if p_user_id is null then
    raise exception using
      errcode = '22004',
      message = 'LOYALTY_REWARD_USER_ID_REQUIRED';
  end if;

  if v_event_key is null
     or length(v_event_key) < 8
     or length(v_event_key) > 300 then
    raise exception using
      errcode = '22023',
      message = 'LOYALTY_REWARD_EVENT_KEY_INVALID';
  end if;

  if v_certification_reference is null
     or length(v_certification_reference) < 8
     or length(v_certification_reference) > 500 then
    raise exception using
      errcode = '22023',
      message = 'LOYALTY_REWARD_CERTIFICATION_REFERENCE_INVALID';
  end if;

  if jsonb_typeof(coalesce(p_payload, '{}'::jsonb)) <> 'object'
     or jsonb_typeof(coalesce(p_metadata, '{}'::jsonb)) <> 'object' then
    raise exception using
      errcode = '22023',
      message = 'LOYALTY_REWARD_JSON_OBJECT_REQUIRED';
  end if;

  select *
  into v_existing
  from public.loyalty_reward_events
  where event_key = v_event_key;

  if found then
    if v_existing.user_id is distinct from p_user_id
       or v_existing.event_code is distinct from v_event_code
       or v_existing.certification_reference
            is distinct from v_certification_reference then
      raise exception using
        errcode = '23505',
        message = 'LOYALTY_REWARD_EVENT_KEY_CONFLICT';
    end if;

    return jsonb_build_object(
      'rewarded', v_existing.event_status = 'rewarded',
      'created', false,
      'already_processed', true,
      'event_id', v_existing.id,
      'event_status', v_existing.event_status,
      'claim_id', v_existing.claim_id,
      'ledger_id', v_existing.ledger_transaction_id,
      'passes_awarded', v_existing.passes_awarded,
      'available_passes', v_existing.balance_after,
      'server_time', clock_timestamp()
    );
  end if;

  select *
  into v_policy
  from public.loyalty_reward_policies
  where event_code = v_event_code
  for share;

  if not found then
    return jsonb_build_object(
      'rewarded', false,
      'created', false,
      'error_code', 'LOYALTY_REWARD_POLICY_NOT_FOUND',
      'event_code', v_event_code,
      'server_time', clock_timestamp()
    );
  end if;

  if not v_policy.enabled then
    return jsonb_build_object(
      'rewarded', false,
      'created', false,
      'error_code', 'LOYALTY_REWARD_POLICY_DISABLED',
      'policy_code', v_policy.policy_code,
      'server_time', clock_timestamp()
    );
  end if;

  select *
  into strict v_campaign
  from public.reward_campaigns
  where id = v_policy.campaign_id
  for share;

  select *
  into strict v_source
  from public.reward_sources
  where id = v_campaign.source_id
  for share;

  if not v_campaign.enabled or not v_source.enabled then
    return jsonb_build_object(
      'rewarded', false,
      'created', false,
      'error_code', 'LOYALTY_REWARD_CAMPAIGN_OR_SOURCE_DISABLED',
      'policy_code', v_policy.policy_code,
      'server_time', clock_timestamp()
    );
  end if;

  if v_campaign.public then
    raise exception using
      errcode = 'P0001',
      message = 'LOYALTY_REWARD_CAMPAIGN_MUST_REMAIN_HIDDEN';
  end if;

  v_deduplication_key := public.build_loyalty_reward_deduplication_key(
    v_policy.policy_code,
    v_policy.reward_scope,
    p_user_id,
    p_league_id,
    p_league_round_id,
    p_season_id,
    p_prediction_result_id
  );

  perform pg_advisory_xact_lock(
    hashtextextended(v_deduplication_key, 0)
  );

  select *
  into v_existing
  from public.loyalty_reward_events
  where deduplication_key = v_deduplication_key;

  if found then
    return jsonb_build_object(
      'rewarded', v_existing.event_status = 'rewarded',
      'created', false,
      'already_processed', true,
      'event_id', v_existing.id,
      'event_status', v_existing.event_status,
      'claim_id', v_existing.claim_id,
      'ledger_id', v_existing.ledger_transaction_id,
      'passes_awarded', v_existing.passes_awarded,
      'available_passes', v_existing.balance_after,
      'server_time', clock_timestamp()
    );
  end if;

  perform set_config(
    'fantagol.loyalty_reward_internal_write',
    'on',
    true
  );

  insert into public.loyalty_reward_events (
    policy_id,
    policy_code,
    event_code,
    event_key,
    deduplication_key,
    user_id,
    league_id,
    league_round_id,
    season_id,
    prediction_result_id,
    certification_reference,
    event_status,
    correlation_id,
    causation_id,
    occurred_at,
    payload,
    metadata
  )
  values (
    v_policy.id,
    v_policy.policy_code,
    v_policy.event_code,
    v_event_key,
    v_deduplication_key,
    p_user_id,
    p_league_id,
    p_league_round_id,
    p_season_id,
    p_prediction_result_id,
    v_certification_reference,
    'processing',
    v_correlation_id,
    p_causation_id,
    coalesce(p_occurred_at, clock_timestamp()),
    coalesce(p_payload, '{}'::jsonb),
    coalesce(p_metadata, '{}'::jsonb)
      || jsonb_build_object(
        'policy_version', v_policy.version,
        'campaign_version', v_campaign.version,
        'source_version', v_source.version
      )
  )
  returning * into v_event;

  perform public.commercial_append_event_internal(
    'LOYALTY_REWARD_EVENT_REGISTERED',
    'LOYALTY_REWARD_EVENT',
    v_event.id,
    v_event.user_id,
    v_event.correlation_id,
    v_event.causation_id,
    jsonb_build_object(
      'event_id', v_event.id,
      'policy_code', v_event.policy_code,
      'event_code', v_event.event_code,
      'certification_reference', v_event.certification_reference
    )
  );

  begin
    v_claim := public.create_reward_claim_internal(
      p_user_id,
      v_policy.campaign_code,
      v_deduplication_key,
      'loyalty-claim:' || v_event.id::text,
      jsonb_build_object(
        'event_code', v_event.event_code,
        'event_key', v_event.event_key,
        'certification_reference', v_event.certification_reference,
        'league_id', v_event.league_id,
        'league_round_id', v_event.league_round_id,
        'season_id', v_event.season_id,
        'prediction_result_id', v_event.prediction_result_id
      ) || coalesce(p_payload, '{}'::jsonb),
      jsonb_build_object(
        'loyalty_reward_event_id', v_event.id,
        'policy_id', v_policy.id,
        'policy_code', v_policy.policy_code,
        'hidden_reward', true
      ) || coalesce(p_metadata, '{}'::jsonb)
    );

    v_settlement := public.settle_reward_claim_internal(
      v_claim.id,
      null,
      v_deduplication_key,
      jsonb_build_object(
        'loyalty_reward_event_id', v_event.id,
        'policy_id', v_policy.id,
        'policy_code', v_policy.policy_code,
        'certification_reference', v_event.certification_reference,
        'hidden_reward', true
      )
    );

    if coalesce((v_settlement ->> 'settled')::boolean, false) is false then
      raise exception using
        errcode = 'P0001',
        message = coalesce(
          v_settlement ->> 'error_code',
          'LOYALTY_REWARD_SETTLEMENT_FAILED'
        );
    end if;

    select *
    into strict v_ledger
    from public.commercial_ledger
    where id = (v_settlement ->> 'ledger_id')::uuid;

    perform set_config(
      'fantagol.loyalty_reward_internal_write',
      'on',
      true
    );

    update public.loyalty_reward_events
    set
      event_status = 'rewarded',
      claim_id = v_claim.id,
      ledger_transaction_id = v_ledger.id,
      passes_awarded = v_claim.passes_awarded,
      balance_before = v_ledger.balance_before,
      balance_after = v_ledger.balance_after,
      processed_at = clock_timestamp(),
      failure_code = null
    where id = v_event.id
    returning * into v_event;

    perform set_config(
      'fantagol.reward_revelation_internal_write',
      'on',
      true
    );

    insert into public.reward_revelations (
      user_id,
      loyalty_reward_event_id,
      claim_id,
      ledger_transaction_id,
      passes_awarded,
      balance_before,
      balance_after,
      revelation_status,
      available_at,
      metadata
    )
    values (
      v_event.user_id,
      v_event.id,
      v_claim.id,
      v_ledger.id,
      v_claim.passes_awarded,
      v_ledger.balance_before,
      v_ledger.balance_after,
      'unseen',
      clock_timestamp(),
      jsonb_build_object(
        'communication_channel', 'control_room_drawer',
        'hamburger_pulse_seconds', 3,
        'show_badge', true,
        'show_popup', false,
        'show_modal', false,
        'reveal_reason', false
      )
    );

    perform public.commercial_append_event_internal(
      'LOYALTY_REWARD_AWARDED',
      'LOYALTY_REWARD_EVENT',
      v_event.id,
      v_event.user_id,
      v_event.correlation_id,
      v_claim.id,
      jsonb_build_object(
        'event_id', v_event.id,
        'policy_code', v_event.policy_code,
        'claim_id', v_claim.id,
        'ledger_id', v_ledger.id,
        'passes_awarded', v_claim.passes_awarded,
        'balance_after', v_ledger.balance_after,
        'communication_channel', 'control_room_drawer'
      )
    );

    return jsonb_build_object(
      'rewarded', true,
      'created', true,
      'already_processed', false,
      'event_id', v_event.id,
      'claim_id', v_claim.id,
      'ledger_id', v_ledger.id,
      'passes_awarded', v_claim.passes_awarded,
      'balance_before', v_ledger.balance_before,
      'available_passes', v_ledger.balance_after,
      'revelation_status', 'unseen',
      'server_time', clock_timestamp()
    );
  exception
    when others then
      perform set_config(
        'fantagol.loyalty_reward_internal_write',
        'on',
        true
      );

      update public.loyalty_reward_events
      set
        event_status = 'failed',
        processed_at = clock_timestamp(),
        failure_code = left(sqlstate || ':' || sqlerrm, 160)
      where id = v_event.id;

      perform public.commercial_append_event_internal(
        'LOYALTY_REWARD_AWARD_FAILED',
        'LOYALTY_REWARD_EVENT',
        v_event.id,
        v_event.user_id,
        v_event.correlation_id,
        v_event.causation_id,
        jsonb_build_object(
          'event_id', v_event.id,
          'policy_code', v_event.policy_code,
          'error_code', sqlstate,
          'error_message', sqlerrm
        )
      );

      raise;
  end;
end;
$$;

-- ============================================================================
-- 9. AUTHENTICATED REWARD SIGNAL READ MODEL
-- ============================================================================

create or replace function public.get_my_reward_signal_rpc()
returns jsonb
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_user_id uuid;
  v_wallet public.commercial_wallets;
  v_unseen_count integer;
  v_unseen_passes integer;
  v_previous_visible_balance integer;
  v_latest_reward_at timestamptz;
begin
  v_user_id := public.commercial_assert_authenticated_user();
  v_wallet := public.commercial_get_or_create_wallet(v_user_id);

  select
    count(*)::integer,
    coalesce(sum(r.passes_awarded), 0)::integer,
    min(r.balance_before),
    max(r.available_at)
  into
    v_unseen_count,
    v_unseen_passes,
    v_previous_visible_balance,
    v_latest_reward_at
  from public.reward_revelations r
  where r.user_id = v_user_id
    and r.revelation_status = 'unseen';

  return jsonb_build_object(
    'available_passes', v_wallet.available_passes,
    'previous_visible_balance', coalesce(
      v_previous_visible_balance,
      v_wallet.available_passes
    ),
    'unseen_reward_count', coalesce(v_unseen_count, 0),
    'unseen_passes', coalesce(v_unseen_passes, 0),
    'latest_reward_at', v_latest_reward_at,
    'should_pulse_hamburger', coalesce(v_unseen_count, 0) > 0,
    'hamburger_pulse_seconds', case
      when coalesce(v_unseen_count, 0) > 0 then 3
      else 0
    end,
    'show_badge', coalesce(v_unseen_count, 0) > 0,
    'reveal_channel', 'control_room_drawer',
    'show_popup', false,
    'show_modal', false,
    'server_time', clock_timestamp()
  );
end;
$$;

-- ============================================================================
-- 10. DRAWER OPEN / REWARD REVELATION ACKNOWLEDGEMENT
-- ============================================================================

create or replace function public.reveal_my_reward_updates_rpc()
returns jsonb
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_user_id uuid;
  v_wallet public.commercial_wallets;
  v_revealed_count integer;
  v_revealed_passes integer;
  v_balance_before integer;
  v_seen_at timestamptz := clock_timestamp();
begin
  v_user_id := public.commercial_assert_authenticated_user();
  v_wallet := public.commercial_get_or_create_wallet(v_user_id);

  perform pg_advisory_xact_lock(
    hashtextextended(
      'reward-revelation:' || v_user_id::text,
      0
    )
  );

  select
    count(*)::integer,
    coalesce(sum(r.passes_awarded), 0)::integer,
    min(r.balance_before)
  into
    v_revealed_count,
    v_revealed_passes,
    v_balance_before
  from public.reward_revelations r
  where r.user_id = v_user_id
    and r.revelation_status = 'unseen';

  if coalesce(v_revealed_count, 0) = 0 then
    return jsonb_build_object(
      'revealed', true,
      'revealed_count', 0,
      'passes_delta', 0,
      'balance_before', v_wallet.available_passes,
      'balance_after', v_wallet.available_passes,
      'badge_cleared', true,
      'control_room_highlight', false,
      'counter_animation', false,
      'server_time', clock_timestamp()
    );
  end if;

  perform set_config(
    'fantagol.reward_revelation_internal_write',
    'on',
    true
  );

  update public.reward_revelations
  set
    revelation_status = 'seen',
    seen_at = v_seen_at
  where user_id = v_user_id
    and revelation_status = 'unseen';

  perform public.commercial_append_event_internal(
    'REWARD_REVELATIONS_SEEN',
    'REWARD_REVELATION',
    v_user_id,
    v_user_id,
    gen_random_uuid(),
    null,
    jsonb_build_object(
      'revealed_count', v_revealed_count,
      'passes_delta', v_revealed_passes,
      'balance_before', v_balance_before,
      'balance_after', v_wallet.available_passes,
      'communication_channel', 'control_room_drawer',
      'seen_at', v_seen_at
    )
  );

  return jsonb_build_object(
    'revealed', true,
    'revealed_count', v_revealed_count,
    'passes_delta', v_revealed_passes,
    'balance_before', v_balance_before,
    'balance_after', v_wallet.available_passes,
    'badge_cleared', true,
    'control_room_highlight', true,
    'counter_animation', true,
    'reveal_reason', false,
    'seen_at', v_seen_at,
    'server_time', clock_timestamp()
  );
end;
$$;

-- ============================================================================
-- 11. AUTHENTICATED REWARD REVELATION HISTORY
-- ============================================================================

create or replace function public.get_my_reward_revelations_rpc(
  p_limit integer default 50,
  p_offset integer default 0
)
returns table (
  revelation_id uuid,
  passes_awarded integer,
  balance_before integer,
  balance_after integer,
  revelation_status text,
  available_at timestamptz,
  seen_at timestamptz
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
    r.id,
    r.passes_awarded,
    r.balance_before,
    r.balance_after,
    r.revelation_status,
    r.available_at,
    r.seen_at
  from public.reward_revelations r
  where r.user_id = v_user_id
  order by r.created_at desc
  limit v_limit
  offset v_offset;
end;
$$;

-- ============================================================================
-- 12. ROW LEVEL SECURITY
-- ============================================================================

alter table public.loyalty_reward_policies enable row level security;
alter table public.loyalty_reward_events enable row level security;
alter table public.reward_revelations enable row level security;

drop policy if exists reward_revelations_owner_read
  on public.reward_revelations;

create policy reward_revelations_owner_read
on public.reward_revelations
for select
to authenticated
using (user_id = auth.uid());

-- Policies and loyalty events remain backend-only and are never exposed as a
-- public objective catalog.

-- ============================================================================
-- 13. PRIVILEGES
-- ============================================================================

revoke all on table public.loyalty_reward_policies
  from anon, authenticated;

revoke all on table public.loyalty_reward_events
  from anon, authenticated;

revoke all on table public.reward_revelations
  from anon, authenticated;

grant select on table public.reward_revelations
  to authenticated;

grant all on table public.loyalty_reward_policies
  to service_role;

grant all on table public.loyalty_reward_events
  to service_role;

grant all on table public.reward_revelations
  to service_role;

revoke all on function public.build_loyalty_reward_deduplication_key(
  text, text, uuid, uuid, uuid, uuid, uuid
) from public, anon, authenticated;

revoke all on function public.award_loyalty_reward_internal(
  uuid, text, text, text, timestamptz,
  uuid, uuid, uuid, uuid, uuid, uuid, jsonb, jsonb
) from public, anon, authenticated;

grant execute on function public.build_loyalty_reward_deduplication_key(
  text, text, uuid, uuid, uuid, uuid, uuid
) to service_role;

grant execute on function public.award_loyalty_reward_internal(
  uuid, text, text, text, timestamptz,
  uuid, uuid, uuid, uuid, uuid, uuid, jsonb, jsonb
) to service_role;

revoke all on function public.get_my_reward_signal_rpc()
  from public, anon;

revoke all on function public.reveal_my_reward_updates_rpc()
  from public, anon;

revoke all on function public.get_my_reward_revelations_rpc(
  integer, integer
) from public, anon;

grant execute on function public.get_my_reward_signal_rpc()
  to authenticated;

grant execute on function public.reveal_my_reward_updates_rpc()
  to authenticated;

grant execute on function public.get_my_reward_revelations_rpc(
  integer, integer
) to authenticated;

-- ============================================================================
-- 14. INTERNAL ACHIEVEMENT SOURCE SEED
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
values (
  'INTERNAL_ACHIEVEMENT',
  'Internal Certified Achievement',
  'event',
  null,
  false,
  true,
  'backend',
  5,
  jsonb_build_object(
    'certified_domain_event_required', true,
    'public_objective_catalog', false,
    'activation_status', 'pending_commercial_approval'
  ),
  jsonb_build_object(
    'foundation_version', '1.0',
    'hidden_rewards', true,
    'welcome_bonus_forbidden', true
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

-- ============================================================================
-- 15. HIDDEN CAMPAIGN SEEDS
-- ============================================================================

with campaign_seed (
  campaign_code,
  title,
  description,
  passes_per_claim,
  max_claims_per_user,
  metadata
) as (
  values
    (
      'LOYALTY_LEAGUE_FULL_8',
      'League Full Eight',
      'Hidden reward for a league reaching eight active participants.',
      1,
      null,
      jsonb_build_object('objective_family', 'community_growth')
    ),
    (
      'LOYALTY_LEAGUE_FIRST_ROUND_COMPLETED',
      'League First Round Completed',
      'Hidden reward after the first certified league round.',
      1,
      null,
      jsonb_build_object('objective_family', 'league_progress')
    ),
    (
      'LOYALTY_LEAGUE_SEASON_COMPLETED',
      'League Season Completed',
      'Hidden reward after the league season is certified complete.',
      1,
      null,
      jsonb_build_object('objective_family', 'league_progress')
    ),
    (
      'LOYALTY_PROFILE_COMPLETED_AFTER_FIRST_ROUND',
      'Profile Completed After First Round',
      'Hidden account reward requiring profile completion and first league-round participation.',
      1,
      1,
      jsonb_build_object('objective_family', 'profile_completion')
    ),
    (
      'LOYALTY_EXACT_ACHIEVED',
      'Exact Achieved',
      'Hidden repeatable reward for a certified Exact.',
      1,
      null,
      jsonb_build_object('objective_family', 'merit')
    ),
    (
      'LOYALTY_GRAND_SLAM_ACHIEVED',
      'Grande Slam Achieved',
      'Hidden repeatable reward for a certified Grande Slam.',
      1,
      null,
      jsonb_build_object('objective_family', 'merit')
    ),
    (
      'LOYALTY_CANTONATA_ACHIEVED',
      'Cantonata Achieved',
      'Hidden repeatable participation reward for a certified Cantonata.',
      1,
      null,
      jsonb_build_object('objective_family', 'participation')
    ),
    (
      'LOYALTY_COMPLETE_PREDICTIONS_STREAK_5',
      'Five Complete Rounds',
      'Hidden reward for five consecutive complete prediction rounds.',
      1,
      null,
      jsonb_build_object('objective_family', 'consistency', 'threshold', 5)
    ),
    (
      'LOYALTY_COMPLETE_PREDICTIONS_STREAK_10',
      'Ten Complete Rounds',
      'Hidden reward for ten consecutive complete prediction rounds.',
      1,
      null,
      jsonb_build_object('objective_family', 'consistency', 'threshold', 10)
    ),
    (
      'LOYALTY_COMPLETE_PREDICTIONS_FULL_SEASON',
      'Complete Prediction Season',
      'Hidden reward for completing a season without missing predictions.',
      1,
      null,
      jsonb_build_object('objective_family', 'consistency', 'threshold', 'full_season')
    )
)
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
  cs.campaign_code,
  s.id,
  cs.title,
  cs.description,
  'PASS_REWARD',
  cs.passes_per_claim,
  false,
  false,
  cs.max_claims_per_user,
  0,
  false,
  cs.metadata || jsonb_build_object(
    'foundation_seed', true,
    'hidden_reward', true,
    'reward_value_requires_commercial_approval', true,
    'public_objective_catalog', false,
    'welcome_bonus', false
  )
from campaign_seed cs
cross join public.reward_sources s
where s.source_code = 'INTERNAL_ACHIEVEMENT'
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

-- ============================================================================
-- 16. HIDDEN POLICY SEEDS
-- ============================================================================

with policy_seed (
  policy_code,
  event_code,
  campaign_code,
  reward_scope,
  priority,
  configuration,
  metadata
) as (
  values
    (
      'POLICY_LEAGUE_FULL_8',
      'LEAGUE_REACHED_8_ACTIVE_MEMBERS',
      'LOYALTY_LEAGUE_FULL_8',
      'league',
      10,
      jsonb_build_object(
        'minimum_active_members', 8,
        'award_each_eligible_member', true
      ),
      jsonb_build_object('one_time_per_user_per_league', true)
    ),
    (
      'POLICY_LEAGUE_FIRST_ROUND_COMPLETED',
      'LEAGUE_FIRST_ROUND_CERTIFIED',
      'LOYALTY_LEAGUE_FIRST_ROUND_COMPLETED',
      'league',
      20,
      jsonb_build_object(
        'required_round_sequence', 1,
        'award_each_eligible_member', true
      ),
      jsonb_build_object('one_time_per_user_per_league', true)
    ),
    (
      'POLICY_LEAGUE_SEASON_COMPLETED',
      'LEAGUE_SEASON_CERTIFIED_COMPLETE',
      'LOYALTY_LEAGUE_SEASON_COMPLETED',
      'league_season',
      30,
      jsonb_build_object('award_each_eligible_member', true),
      jsonb_build_object('one_time_per_user_per_league_season', true)
    ),
    (
      'POLICY_PROFILE_COMPLETED_AFTER_FIRST_ROUND',
      'PROFILE_COMPLETED_AFTER_FIRST_LEAGUE_ROUND',
      'LOYALTY_PROFILE_COMPLETED_AFTER_FIRST_ROUND',
      'account',
      40,
      jsonb_build_object(
        'minimum_completed_league_rounds', 1,
        'minimum_league_members', 1,
        'requires_eight_member_league', false
      ),
      jsonb_build_object('one_time_per_account', true)
    ),
    (
      'POLICY_EXACT_ACHIEVED',
      'CERTIFIED_EXACT_ACHIEVED',
      'LOYALTY_EXACT_ACHIEVED',
      'prediction_result',
      50,
      jsonb_build_object('repeatable', true),
      jsonb_build_object('one_time_per_prediction_result', true)
    ),
    (
      'POLICY_GRAND_SLAM_ACHIEVED',
      'CERTIFIED_GRAND_SLAM_ACHIEVED',
      'LOYALTY_GRAND_SLAM_ACHIEVED',
      'prediction_result',
      60,
      jsonb_build_object(
        'repeatable', true,
        'cumulative_with_exact', true
      ),
      jsonb_build_object('one_time_per_prediction_result', true)
    ),
    (
      'POLICY_CANTONATA_ACHIEVED',
      'CERTIFIED_CANTONATA_ACHIEVED',
      'LOYALTY_CANTONATA_ACHIEVED',
      'prediction_result',
      70,
      jsonb_build_object('repeatable', true),
      jsonb_build_object('one_time_per_prediction_result', true)
    ),
    (
      'POLICY_COMPLETE_PREDICTIONS_STREAK_5',
      'COMPLETE_PREDICTIONS_STREAK_5_CERTIFIED',
      'LOYALTY_COMPLETE_PREDICTIONS_STREAK_5',
      'league_season_streak',
      80,
      jsonb_build_object(
        'required_consecutive_rounds', 5,
        'all_round_predictions_required', true
      ),
      jsonb_build_object('one_time_per_user_per_league_season', true)
    ),
    (
      'POLICY_COMPLETE_PREDICTIONS_STREAK_10',
      'COMPLETE_PREDICTIONS_STREAK_10_CERTIFIED',
      'LOYALTY_COMPLETE_PREDICTIONS_STREAK_10',
      'league_season_streak',
      90,
      jsonb_build_object(
        'required_consecutive_rounds', 10,
        'all_round_predictions_required', true
      ),
      jsonb_build_object('one_time_per_user_per_league_season', true)
    ),
    (
      'POLICY_COMPLETE_PREDICTIONS_FULL_SEASON',
      'COMPLETE_PREDICTIONS_FULL_SEASON_CERTIFIED',
      'LOYALTY_COMPLETE_PREDICTIONS_FULL_SEASON',
      'league_season',
      100,
      jsonb_build_object(
        'all_season_rounds_required', true,
        'all_round_predictions_required', true
      ),
      jsonb_build_object('one_time_per_user_per_league_season', true)
    )
)
insert into public.loyalty_reward_policies (
  policy_code,
  event_code,
  campaign_id,
  campaign_code,
  reward_scope,
  enabled,
  hidden,
  requires_certified_event,
  priority,
  configuration,
  metadata
)
select
  ps.policy_code,
  ps.event_code,
  c.id,
  c.campaign_code,
  ps.reward_scope,
  false,
  true,
  true,
  ps.priority,
  ps.configuration,
  ps.metadata || jsonb_build_object(
    'foundation_version', '1.0',
    'activation_status', 'pending_runtime_integration',
    'public_objective_catalog', false
  )
from policy_seed ps
join public.reward_campaigns c
  on c.campaign_code = ps.campaign_code
on conflict (policy_code) do update
set
  priority = excluded.priority,
  configuration = excluded.configuration,
  metadata = excluded.metadata;

-- ============================================================================
-- 17. DOCUMENTATION COMMENTS
-- ============================================================================

comment on function public.award_loyalty_reward_internal(
  uuid, text, text, text, timestamptz,
  uuid, uuid, uuid, uuid, uuid, uuid, jsonb, jsonb
) is
  'Backend-only atomic award path for a certified hidden loyalty event. Creates and settles a Reward Engine claim and an unseen drawer revelation.';

comment on function public.get_my_reward_signal_rpc() is
  'Returns the private hamburger pulse, badge and Pass-balance animation signal without exposing reward objectives.';

comment on function public.reveal_my_reward_updates_rpc() is
  'Called when the user voluntarily opens the drawer. Marks unseen rewards as seen and returns the aggregate balance animation contract.';

comment on function public.get_my_reward_revelations_rpc(
  integer, integer
) is
  'Returns private reward revelation history without exposing policy codes, objectives or trigger reasons.';

-- ============================================================================
-- 18. FOUNDATION ASSERTIONS
-- ============================================================================

do $$
declare
  v_source public.reward_sources;
  v_campaign_count integer;
  v_policy_count integer;
begin
  select *
  into strict v_source
  from public.reward_sources
  where source_code = 'INTERNAL_ACHIEVEMENT';

  if v_source.enabled
     or not v_source.test_mode
     or v_source.verification_mode <> 'backend' then
    raise exception
      'LOYALTY_REWARD_POLICY_ASSERTION_FAILED: source activation state';
  end if;

  select count(*)
  into v_campaign_count
  from public.reward_campaigns
  where campaign_code like 'LOYALTY_%';

  if v_campaign_count <> 10 then
    raise exception
      'LOYALTY_REWARD_POLICY_ASSERTION_FAILED: campaign seed count';
  end if;

  if exists (
    select 1
    from public.reward_campaigns
    where campaign_code like 'LOYALTY_%'
      and (enabled = true or public = true)
  ) then
    raise exception
      'LOYALTY_REWARD_POLICY_ASSERTION_FAILED: campaigns must remain hidden and disabled';
  end if;

  select count(*)
  into v_policy_count
  from public.loyalty_reward_policies;

  if v_policy_count <> 10 then
    raise exception
      'LOYALTY_REWARD_POLICY_ASSERTION_FAILED: policy seed count';
  end if;

  if exists (
    select 1
    from public.loyalty_reward_policies
    where enabled = true
       or hidden = false
       or requires_certified_event = false
  ) then
    raise exception
      'LOYALTY_REWARD_POLICY_ASSERTION_FAILED: policy safety state';
  end if;

  if exists (
    select 1
    from public.reward_campaigns
    where campaign_code ~ '(WELCOME|SIGNUP|REGISTER|FIRST_LOGIN|DAILY_LOGIN|RETURN_TOMORROW)'
  ) then
    raise exception
      'LOYALTY_REWARD_POLICY_ASSERTION_FAILED: forbidden acquisition bonus detected';
  end if;

  if not exists (
    select 1
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.proname = 'get_my_reward_signal_rpc'
  ) then
    raise exception
      'LOYALTY_REWARD_POLICY_ASSERTION_FAILED: reward signal RPC missing';
  end if;
end;
$$;

-- ============================================================================
-- 19. CERTIFICATION NOTICE
-- ============================================================================

do $$
begin
  raise notice 'LOYALTY REWARD POLICY FOUNDATION CERTIFIED';
  raise notice '10 hidden loyalty objectives seeded and disabled';
  raise notice 'No welcome, registration, login or daily bonus exists';
  raise notice 'Reward communication restricted to hamburger, badge and Control Room drawer';
  raise notice 'Frontend implementation and workflow event producers remain pending';
end;
$$;

commit;
