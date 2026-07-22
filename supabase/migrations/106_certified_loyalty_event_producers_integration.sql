-- ============================================================================
-- FANTAGOL
-- Migration: 106_certified_loyalty_event_producers_integration.sql
-- Milestone: Commercial Platform — Certified Loyalty Event Producers
--
-- Purpose:
--   - Register the authoritative domain producers for the ten loyalty events
--   - Validate certified producer evidence before runtime enqueue
--   - Persist producer receipts and idempotent delivery state
--   - Route certified events to Migration 105 adapters
--   - Preserve complete separation between domain engines and reward settlement
--
-- Safety:
--   - Backend/service_role only
--   - No client producer path
--   - No direct trigger on mutable game tables
--   - No policy, campaign or reward-source activation
--   - No Pass settlement inside producer functions
-- ============================================================================

begin;

-- ============================================================================
-- 0. DEPENDENCY ASSERTIONS
-- ============================================================================

do $$
begin
  if to_regclass('public.loyalty_reward_runtime_inbox') is null
     or to_regclass('public.loyalty_reward_runtime_attempts') is null then
    raise exception using
      errcode = 'P0001',
      message = 'MIGRATION_106_REQUIRES_MIGRATION_105';
  end if;

  if to_regprocedure(
    'public.enqueue_certified_prediction_loyalty_event_internal(uuid,text,uuid,text,uuid,uuid,uuid,timestamp with time zone,uuid,uuid,jsonb)'
  ) is null then
    raise exception using
      errcode = 'P0001',
      message = 'MIGRATION_106_REQUIRES_PREDICTION_LOYALTY_ADAPTER';
  end if;

  if to_regprocedure(
    'public.enqueue_certified_league_loyalty_event_internal(uuid,text,uuid,text,uuid,uuid,timestamp with time zone,uuid,uuid,jsonb)'
  ) is null then
    raise exception using
      errcode = 'P0001',
      message = 'MIGRATION_106_REQUIRES_LEAGUE_LOYALTY_ADAPTER';
  end if;

  if to_regprocedure(
    'public.enqueue_certified_participation_loyalty_event_internal(uuid,text,text,uuid,uuid,uuid,timestamp with time zone,uuid,uuid,jsonb)'
  ) is null then
    raise exception using
      errcode = 'P0001',
      message = 'MIGRATION_106_REQUIRES_PARTICIPATION_LOYALTY_ADAPTER';
  end if;
end;
$$;

-- ============================================================================
-- 1. PRODUCER REGISTRY
-- ============================================================================

create table if not exists public.loyalty_event_producers (
  id uuid primary key default gen_random_uuid(),

  producer_code text not null unique,
  producer_name text not null,
  engine_code text not null,
  event_code text not null unique,
  adapter_family text not null,

  certification_mode text not null,
  certification_reference_prefix text not null,

  enabled boolean not null default false,
  test_mode boolean not null default true,
  requires_service_role boolean not null default true,
  requires_certification_evidence boolean not null default true,

  minimum_evidence_version integer not null default 1,
  configuration jsonb not null default '{}'::jsonb,
  metadata jsonb not null default '{}'::jsonb,

  created_at timestamptz not null default clock_timestamp(),
  updated_at timestamptz not null default clock_timestamp(),
  version integer not null default 1,

  constraint loyalty_event_producers_code_check
    check (producer_code ~ '^[A-Z][A-Z0-9_]{2,99}$'),

  constraint loyalty_event_producers_name_check
    check (length(trim(producer_name)) between 3 and 200),

  constraint loyalty_event_producers_engine_code_check
    check (engine_code ~ '^[A-Z][A-Z0-9_]{2,99}$'),

  constraint loyalty_event_producers_event_code_check
    check (event_code ~ '^[A-Z][A-Z0-9_]{2,149}$'),

  constraint loyalty_event_producers_adapter_family_check
    check (
      adapter_family in (
        'prediction_result',
        'league',
        'participation'
      )
    ),

  constraint loyalty_event_producers_certification_mode_check
    check (
      certification_mode in (
        'certified_result',
        'certified_round',
        'certified_league_state',
        'certified_profile_state',
        'certified_participation_state'
      )
    ),

  constraint loyalty_event_producers_reference_prefix_check
    check (
      certification_reference_prefix ~ '^[a-z][a-z0-9._-]{2,79}$'
    ),

  constraint loyalty_event_producers_evidence_version_check
    check (minimum_evidence_version between 1 and 1000),

  constraint loyalty_event_producers_configuration_check
    check (jsonb_typeof(configuration) = 'object'),

  constraint loyalty_event_producers_metadata_check
    check (jsonb_typeof(metadata) = 'object'),

  constraint loyalty_event_producers_version_check
    check (version > 0)
);

comment on table public.loyalty_event_producers is
  'Registry of authoritative backend producers allowed to emit certified loyalty events.';

-- ============================================================================
-- 2. PRODUCER RECEIPTS
-- ============================================================================

create table if not exists public.loyalty_event_producer_receipts (
  id uuid primary key default gen_random_uuid(),

  producer_id uuid not null,
  producer_code text not null,
  event_code text not null,

  producer_event_key text not null unique,
  certification_reference text not null,

  user_id uuid not null,
  league_id uuid null,
  league_round_id uuid null,
  season_id uuid null,
  prediction_result_id uuid null,

  receipt_status text not null default 'received',

  evidence_version integer not null,
  evidence jsonb not null,
  payload jsonb not null default '{}'::jsonb,
  metadata jsonb not null default '{}'::jsonb,

  correlation_id uuid not null default gen_random_uuid(),
  causation_id uuid null,

  occurred_at timestamptz not null,
  received_at timestamptz not null default clock_timestamp(),
  validated_at timestamptz null,
  enqueued_at timestamptz null,
  rejected_at timestamptz null,

  runtime_inbox_event_id uuid null,

  rejection_code text null,
  rejection_message text null,

  created_at timestamptz not null default clock_timestamp(),
  updated_at timestamptz not null default clock_timestamp(),
  version integer not null default 1,

  constraint loyalty_event_producer_receipts_producer_id_fkey
    foreign key (producer_id)
    references public.loyalty_event_producers (id)
    on delete restrict,

  constraint loyalty_event_producer_receipts_user_id_fkey
    foreign key (user_id)
    references auth.users (id)
    on delete restrict,

  constraint loyalty_event_producer_receipts_runtime_inbox_event_id_fkey
    foreign key (runtime_inbox_event_id)
    references public.loyalty_reward_runtime_inbox (id)
    on delete restrict,

  constraint loyalty_event_producer_receipts_runtime_inbox_event_id_key
    unique (runtime_inbox_event_id),

  constraint loyalty_event_producer_receipts_producer_code_check
    check (producer_code ~ '^[A-Z][A-Z0-9_]{2,99}$'),

  constraint loyalty_event_producer_receipts_event_code_check
    check (event_code ~ '^[A-Z][A-Z0-9_]{2,149}$'),

  constraint loyalty_event_producer_receipts_event_key_check
    check (length(trim(producer_event_key)) between 8 and 300),

  constraint loyalty_event_producer_receipts_reference_check
    check (length(trim(certification_reference)) between 8 and 500),

  constraint loyalty_event_producer_receipts_status_check
    check (
      receipt_status in (
        'received',
        'validated',
        'enqueued',
        'duplicate',
        'rejected'
      )
    ),

  constraint loyalty_event_producer_receipts_evidence_version_check
    check (evidence_version between 1 and 1000),

  constraint loyalty_event_producer_receipts_evidence_check
    check (
      jsonb_typeof(evidence) = 'object'
      and evidence <> '{}'::jsonb
    ),

  constraint loyalty_event_producer_receipts_payload_check
    check (jsonb_typeof(payload) = 'object'),

  constraint loyalty_event_producer_receipts_metadata_check
    check (jsonb_typeof(metadata) = 'object'),

  constraint loyalty_event_producer_receipts_rejection_code_check
    check (
      rejection_code is null
      or length(trim(rejection_code)) between 3 and 200
    ),

  constraint loyalty_event_producer_receipts_rejection_message_check
    check (
      rejection_message is null
      or length(rejection_message) <= 2000
    ),

  constraint loyalty_event_producer_receipts_version_check
    check (version > 0),

  constraint loyalty_event_producer_receipts_terminal_state_check
    check (
      (
        receipt_status in ('enqueued', 'duplicate')
        and runtime_inbox_event_id is not null
        and enqueued_at is not null
      )
      or receipt_status not in ('enqueued', 'duplicate')
    ),

  constraint loyalty_event_producer_receipts_rejected_state_check
    check (
      (
        receipt_status = 'rejected'
        and rejected_at is not null
        and rejection_code is not null
      )
      or receipt_status <> 'rejected'
    )
);

create index if not exists loyalty_event_producer_receipts_producer_idx
  on public.loyalty_event_producer_receipts (
    producer_code,
    received_at desc
  );

create index if not exists loyalty_event_producer_receipts_user_idx
  on public.loyalty_event_producer_receipts (
    user_id,
    received_at desc
  );

create index if not exists loyalty_event_producer_receipts_status_idx
  on public.loyalty_event_producer_receipts (
    receipt_status,
    received_at desc
  );

create index if not exists loyalty_event_producer_receipts_correlation_idx
  on public.loyalty_event_producer_receipts (correlation_id);

create index if not exists loyalty_event_producer_receipts_scope_idx
  on public.loyalty_event_producer_receipts (
    league_id,
    league_round_id,
    season_id,
    prediction_result_id
  );

comment on table public.loyalty_event_producer_receipts is
  'Immutable business receipt for every certified producer event accepted or rejected by the loyalty integration layer.';

-- ============================================================================
-- 3. UPDATED_AT TRIGGERS
-- ============================================================================

create or replace function public.set_loyalty_producer_updated_at()
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

drop trigger if exists loyalty_event_producers_set_updated_at
  on public.loyalty_event_producers;

create trigger loyalty_event_producers_set_updated_at
before update on public.loyalty_event_producers
for each row
execute function public.set_loyalty_producer_updated_at();

drop trigger if exists loyalty_event_producer_receipts_set_updated_at
  on public.loyalty_event_producer_receipts;

create trigger loyalty_event_producer_receipts_set_updated_at
before update on public.loyalty_event_producer_receipts
for each row
execute function public.set_loyalty_producer_updated_at();

-- ============================================================================
-- 4. EVIDENCE VALIDATION
-- ============================================================================

create or replace function public.validate_loyalty_producer_evidence_internal(
  p_producer_code text,
  p_event_code text,
  p_user_id uuid,
  p_league_id uuid,
  p_league_round_id uuid,
  p_season_id uuid,
  p_prediction_result_id uuid,
  p_certification_reference text,
  p_evidence_version integer,
  p_evidence jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_producer public.loyalty_event_producers;
  v_reference text := nullif(trim(p_certification_reference), '');
  v_required_fields text[];
  v_field text;
begin
  select *
  into v_producer
  from public.loyalty_event_producers
  where producer_code = upper(trim(p_producer_code))
  for share;

  if not found then
    return jsonb_build_object(
      'valid', false,
      'error_code', 'LOYALTY_PRODUCER_NOT_REGISTERED'
    );
  end if;

  if v_producer.event_code <> upper(trim(p_event_code)) then
    return jsonb_build_object(
      'valid', false,
      'error_code', 'LOYALTY_PRODUCER_EVENT_CODE_MISMATCH'
    );
  end if;

  if not v_producer.enabled then
    return jsonb_build_object(
      'valid', false,
      'error_code', 'LOYALTY_PRODUCER_DISABLED'
    );
  end if;

  if p_user_id is null then
    return jsonb_build_object(
      'valid', false,
      'error_code', 'LOYALTY_PRODUCER_USER_ID_REQUIRED'
    );
  end if;

  if v_reference is null
     or v_reference not like
       v_producer.certification_reference_prefix || ':%' then
    return jsonb_build_object(
      'valid', false,
      'error_code', 'LOYALTY_PRODUCER_CERTIFICATION_REFERENCE_INVALID',
      'expected_prefix', v_producer.certification_reference_prefix
    );
  end if;

  if coalesce(p_evidence_version, 0) <
     v_producer.minimum_evidence_version then
    return jsonb_build_object(
      'valid', false,
      'error_code', 'LOYALTY_PRODUCER_EVIDENCE_VERSION_UNSUPPORTED',
      'minimum_evidence_version', v_producer.minimum_evidence_version
    );
  end if;

  if jsonb_typeof(coalesce(p_evidence, '{}'::jsonb)) <> 'object'
     or coalesce(p_evidence, '{}'::jsonb) = '{}'::jsonb then
    return jsonb_build_object(
      'valid', false,
      'error_code', 'LOYALTY_PRODUCER_EVIDENCE_REQUIRED'
    );
  end if;

  if coalesce((p_evidence ->> 'certified')::boolean, false) is false then
    return jsonb_build_object(
      'valid', false,
      'error_code', 'LOYALTY_PRODUCER_CERTIFIED_FLAG_REQUIRED'
    );
  end if;

  if nullif(p_evidence ->> 'certified_at', '') is null then
    return jsonb_build_object(
      'valid', false,
      'error_code', 'LOYALTY_PRODUCER_CERTIFIED_AT_REQUIRED'
    );
  end if;

  if nullif(p_evidence ->> 'certification_digest', '') is null then
    return jsonb_build_object(
      'valid', false,
      'error_code', 'LOYALTY_PRODUCER_CERTIFICATION_DIGEST_REQUIRED'
    );
  end if;

  v_required_fields := case v_producer.adapter_family
    when 'prediction_result'
      then array[
        'prediction_result_id',
        'league_id',
        'league_round_id',
        'result_kind'
      ]
    when 'league'
      then array[
        'league_id',
        'achievement_kind'
      ]
    when 'participation'
      then array[
        'participation_kind'
      ]
    else array[]::text[]
  end;

  foreach v_field in array v_required_fields loop
    if nullif(p_evidence ->> v_field, '') is null then
      return jsonb_build_object(
        'valid', false,
        'error_code', 'LOYALTY_PRODUCER_REQUIRED_EVIDENCE_FIELD_MISSING',
        'missing_field', v_field
      );
    end if;
  end loop;

  if v_producer.adapter_family = 'prediction_result' then
    if p_prediction_result_id is null
       or p_league_id is null
       or p_league_round_id is null then
      return jsonb_build_object(
        'valid', false,
        'error_code', 'LOYALTY_PRODUCER_PREDICTION_SCOPE_REQUIRED'
      );
    end if;

    if p_evidence ->> 'prediction_result_id'
         <> p_prediction_result_id::text
       or p_evidence ->> 'league_id' <> p_league_id::text
       or p_evidence ->> 'league_round_id'
         <> p_league_round_id::text then
      return jsonb_build_object(
        'valid', false,
        'error_code', 'LOYALTY_PRODUCER_PREDICTION_EVIDENCE_SCOPE_MISMATCH'
      );
    end if;
  end if;

  if v_producer.adapter_family = 'league' then
    if p_league_id is null then
      return jsonb_build_object(
        'valid', false,
        'error_code', 'LOYALTY_PRODUCER_LEAGUE_SCOPE_REQUIRED'
      );
    end if;

    if p_evidence ->> 'league_id' <> p_league_id::text then
      return jsonb_build_object(
        'valid', false,
        'error_code', 'LOYALTY_PRODUCER_LEAGUE_EVIDENCE_SCOPE_MISMATCH'
      );
    end if;
  end if;

  if p_season_id is not null
     and nullif(p_evidence ->> 'season_id', '') is not null
     and p_evidence ->> 'season_id' <> p_season_id::text then
    return jsonb_build_object(
      'valid', false,
      'error_code', 'LOYALTY_PRODUCER_SEASON_EVIDENCE_SCOPE_MISMATCH'
    );
  end if;

  return jsonb_build_object(
    'valid', true,
    'producer_id', v_producer.id,
    'producer_code', v_producer.producer_code,
    'event_code', v_producer.event_code,
    'adapter_family', v_producer.adapter_family,
    'certification_mode', v_producer.certification_mode
  );
exception
  when invalid_text_representation then
    return jsonb_build_object(
      'valid', false,
      'error_code', 'LOYALTY_PRODUCER_EVIDENCE_TYPE_INVALID'
    );
end;
$$;

-- ============================================================================
-- 5. GENERIC CERTIFIED PRODUCER ENTRY POINT
-- ============================================================================

create or replace function public.emit_certified_loyalty_event_internal(
  p_producer_code text,
  p_producer_event_key text,
  p_user_id uuid,
  p_certification_reference text,
  p_evidence_version integer,
  p_evidence jsonb,
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
  v_producer_code text := upper(trim(p_producer_code));
  v_event_key text := nullif(trim(p_producer_event_key), '');
  v_reference text := nullif(trim(p_certification_reference), '');
  v_producer public.loyalty_event_producers;
  v_existing public.loyalty_event_producer_receipts;
  v_receipt public.loyalty_event_producer_receipts;
  v_validation jsonb;
  v_enqueue_result jsonb;
  v_runtime_inbox_id uuid;
  v_correlation_id uuid := coalesce(p_correlation_id, gen_random_uuid());
begin
  if v_event_key is null
     or length(v_event_key) < 8
     or length(v_event_key) > 300 then
    raise exception using
      errcode = '22023',
      message = 'LOYALTY_PRODUCER_EVENT_KEY_INVALID';
  end if;

  if jsonb_typeof(coalesce(p_payload, '{}'::jsonb)) <> 'object'
     or jsonb_typeof(coalesce(p_metadata, '{}'::jsonb)) <> 'object' then
    raise exception using
      errcode = '22023',
      message = 'LOYALTY_PRODUCER_JSON_OBJECT_REQUIRED';
  end if;

  select *
  into v_producer
  from public.loyalty_event_producers
  where producer_code = v_producer_code
  for share;

  if not found then
    raise exception using
      errcode = 'P0002',
      message = 'LOYALTY_PRODUCER_NOT_REGISTERED';
  end if;

  perform pg_advisory_xact_lock(
    hashtextextended('loyalty-producer:' || v_event_key, 0)
  );

  select *
  into v_existing
  from public.loyalty_event_producer_receipts
  where producer_event_key = v_event_key;

  if found then
    if v_existing.producer_code is distinct from v_producer_code
       or v_existing.user_id is distinct from p_user_id
       or v_existing.certification_reference is distinct from v_reference then
      raise exception using
        errcode = '23505',
        message = 'LOYALTY_PRODUCER_EVENT_KEY_CONFLICT';
    end if;

    return jsonb_build_object(
      'accepted', v_existing.receipt_status in ('enqueued', 'duplicate'),
      'created', false,
      'already_exists', true,
      'receipt_id', v_existing.id,
      'receipt_status', v_existing.receipt_status,
      'runtime_inbox_event_id', v_existing.runtime_inbox_event_id,
      'rejection_code', v_existing.rejection_code,
      'server_time', clock_timestamp()
    );
  end if;

  insert into public.loyalty_event_producer_receipts (
    producer_id,
    producer_code,
    event_code,
    producer_event_key,
    certification_reference,
    user_id,
    league_id,
    league_round_id,
    season_id,
    prediction_result_id,
    receipt_status,
    evidence_version,
    evidence,
    payload,
    metadata,
    correlation_id,
    causation_id,
    occurred_at
  )
  values (
    v_producer.id,
    v_producer.producer_code,
    v_producer.event_code,
    v_event_key,
    v_reference,
    p_user_id,
    p_league_id,
    p_league_round_id,
    p_season_id,
    p_prediction_result_id,
    'received',
    p_evidence_version,
    p_evidence,
    coalesce(p_payload, '{}'::jsonb),
    coalesce(p_metadata, '{}'::jsonb)
      || jsonb_build_object(
        'producer_version', v_producer.version,
        'integration_version', '1.0',
        'frontend_origin_allowed', false
      ),
    v_correlation_id,
    p_causation_id,
    coalesce(p_occurred_at, clock_timestamp())
  )
  returning * into v_receipt;

  v_validation :=
    public.validate_loyalty_producer_evidence_internal(
      v_producer.producer_code,
      v_producer.event_code,
      p_user_id,
      p_league_id,
      p_league_round_id,
      p_season_id,
      p_prediction_result_id,
      v_reference,
      p_evidence_version,
      p_evidence
    );

  if coalesce((v_validation ->> 'valid')::boolean, false) is false then
    update public.loyalty_event_producer_receipts
    set
      receipt_status = 'rejected',
      rejected_at = clock_timestamp(),
      rejection_code = coalesce(
        v_validation ->> 'error_code',
        'LOYALTY_PRODUCER_EVIDENCE_REJECTED'
      ),
      rejection_message = left(v_validation::text, 2000)
    where id = v_receipt.id
    returning * into v_receipt;

    perform public.commercial_append_event_internal(
      'LOYALTY_PRODUCER_EVENT_REJECTED',
      'LOYALTY_PRODUCER_RECEIPT',
      v_receipt.id,
      v_receipt.user_id,
      v_receipt.correlation_id,
      v_receipt.causation_id,
      jsonb_build_object(
        'receipt_id', v_receipt.id,
        'producer_code', v_receipt.producer_code,
        'event_code', v_receipt.event_code,
        'producer_event_key', v_receipt.producer_event_key,
        'validation', v_validation
      )
    );

    return jsonb_build_object(
      'accepted', false,
      'created', true,
      'receipt_id', v_receipt.id,
      'receipt_status', v_receipt.receipt_status,
      'rejection_code', v_receipt.rejection_code,
      'validation', v_validation,
      'server_time', clock_timestamp()
    );
  end if;

  update public.loyalty_event_producer_receipts
  set
    receipt_status = 'validated',
    validated_at = clock_timestamp()
  where id = v_receipt.id
  returning * into v_receipt;

  case v_producer.adapter_family
    when 'prediction_result' then
      v_enqueue_result :=
        public.enqueue_certified_prediction_loyalty_event_internal(
          p_user_id,
          v_producer.event_code,
          p_prediction_result_id,
          v_reference,
          p_league_id,
          p_league_round_id,
          p_season_id,
          p_occurred_at,
          v_correlation_id,
          p_causation_id,
          coalesce(p_payload, '{}'::jsonb)
            || jsonb_build_object(
              'producer_receipt_id', v_receipt.id,
              'producer_code', v_producer.producer_code,
              'certification_evidence', p_evidence
            )
        );

    when 'league' then
      v_enqueue_result :=
        public.enqueue_certified_league_loyalty_event_internal(
          p_user_id,
          v_producer.event_code,
          p_league_id,
          v_reference,
          p_league_round_id,
          p_season_id,
          p_occurred_at,
          v_correlation_id,
          p_causation_id,
          coalesce(p_payload, '{}'::jsonb)
            || jsonb_build_object(
              'producer_receipt_id', v_receipt.id,
              'producer_code', v_producer.producer_code,
              'certification_evidence', p_evidence
            )
        );

    when 'participation' then
      v_enqueue_result :=
        public.enqueue_certified_participation_loyalty_event_internal(
          p_user_id,
          v_producer.event_code,
          v_reference,
          p_league_id,
          p_league_round_id,
          p_season_id,
          p_occurred_at,
          v_correlation_id,
          p_causation_id,
          coalesce(p_payload, '{}'::jsonb)
            || jsonb_build_object(
              'producer_receipt_id', v_receipt.id,
              'producer_code', v_producer.producer_code,
              'certification_evidence', p_evidence
            )
        );

    else
      raise exception using
        errcode = 'P0001',
        message = 'LOYALTY_PRODUCER_ADAPTER_FAMILY_UNSUPPORTED';
  end case;

  v_runtime_inbox_id :=
    nullif(v_enqueue_result ->> 'inbox_event_id', '')::uuid;

  if v_runtime_inbox_id is null then
    raise exception using
      errcode = 'P0001',
      message = 'LOYALTY_PRODUCER_RUNTIME_INBOX_ID_MISSING';
  end if;

  update public.loyalty_event_producer_receipts
  set
    receipt_status = case
      when coalesce(
        (v_enqueue_result ->> 'already_exists')::boolean,
        false
      )
      then 'duplicate'
      else 'enqueued'
    end,
    enqueued_at = clock_timestamp(),
    runtime_inbox_event_id = v_runtime_inbox_id,
    metadata = metadata || jsonb_build_object(
      'runtime_enqueue_result', v_enqueue_result
    )
  where id = v_receipt.id
  returning * into v_receipt;

  perform public.commercial_append_event_internal(
    'LOYALTY_PRODUCER_EVENT_ENQUEUED',
    'LOYALTY_PRODUCER_RECEIPT',
    v_receipt.id,
    v_receipt.user_id,
    v_receipt.correlation_id,
    v_receipt.causation_id,
    jsonb_build_object(
      'receipt_id', v_receipt.id,
      'producer_code', v_receipt.producer_code,
      'event_code', v_receipt.event_code,
      'producer_event_key', v_receipt.producer_event_key,
      'runtime_inbox_event_id', v_receipt.runtime_inbox_event_id,
      'receipt_status', v_receipt.receipt_status
    )
  );

  return jsonb_build_object(
    'accepted', true,
    'created', true,
    'receipt_id', v_receipt.id,
    'receipt_status', v_receipt.receipt_status,
    'runtime_inbox_event_id', v_receipt.runtime_inbox_event_id,
    'runtime_enqueue_result', v_enqueue_result,
    'server_time', clock_timestamp()
  );
end;
$$;

-- ============================================================================
-- 6. PRODUCER-SPECIFIC WRAPPERS
-- ============================================================================

create or replace function public.emit_certified_prediction_achievement_internal(
  p_user_id uuid,
  p_achievement_code text,
  p_prediction_result_id uuid,
  p_league_id uuid,
  p_league_round_id uuid,
  p_certification_reference text,
  p_certification_digest text,
  p_certified_at timestamptz,
  p_season_id uuid default null,
  p_correlation_id uuid default null,
  p_causation_id uuid default null,
  p_payload jsonb default '{}'::jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_achievement text := upper(trim(p_achievement_code));
  v_producer_code text;
  v_result_kind text;
begin
  case v_achievement
    when 'EXACT' then
      v_producer_code := 'PREDICTION_RESULT_EXACT';
      v_result_kind := 'exact';
    when 'GRAND_SLAM' then
      v_producer_code := 'PREDICTION_RESULT_GRAND_SLAM';
      v_result_kind := 'grand_slam';
    when 'CANTONATA' then
      v_producer_code := 'PREDICTION_RESULT_CANTONATA';
      v_result_kind := 'cantonata';
    else
      raise exception using
        errcode = '22023',
        message = 'LOYALTY_PREDICTION_ACHIEVEMENT_INVALID';
  end case;

  return public.emit_certified_loyalty_event_internal(
    v_producer_code,
    'certified-prediction:' || p_prediction_result_id::text
      || ':' || lower(v_achievement),
    p_user_id,
    p_certification_reference,
    1,
    jsonb_build_object(
      'certified', true,
      'certified_at', p_certified_at,
      'certification_digest', p_certification_digest,
      'prediction_result_id', p_prediction_result_id,
      'league_id', p_league_id,
      'league_round_id', p_league_round_id,
      'season_id', p_season_id,
      'result_kind', v_result_kind
    ),
    p_certified_at,
    p_league_id,
    p_league_round_id,
    p_season_id,
    p_prediction_result_id,
    p_correlation_id,
    p_causation_id,
    coalesce(p_payload, '{}'::jsonb),
    jsonb_build_object(
      'wrapper', 'emit_certified_prediction_achievement_internal'
    )
  );
end;
$$;

create or replace function public.emit_certified_league_achievement_internal(
  p_user_id uuid,
  p_achievement_code text,
  p_league_id uuid,
  p_certification_reference text,
  p_certification_digest text,
  p_certified_at timestamptz,
  p_league_round_id uuid default null,
  p_season_id uuid default null,
  p_correlation_id uuid default null,
  p_causation_id uuid default null,
  p_payload jsonb default '{}'::jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_achievement text := upper(trim(p_achievement_code));
  v_producer_code text;
begin
  case v_achievement
    when 'LEAGUE_FULL_8' then
      v_producer_code := 'LEAGUE_REACHED_8_MEMBERS';
    when 'FIRST_ROUND_COMPLETED' then
      v_producer_code := 'LEAGUE_FIRST_ROUND_CERTIFICATION';
    when 'SEASON_COMPLETED' then
      v_producer_code := 'LEAGUE_SEASON_CERTIFICATION';
    else
      raise exception using
        errcode = '22023',
        message = 'LOYALTY_LEAGUE_ACHIEVEMENT_INVALID';
  end case;

  return public.emit_certified_loyalty_event_internal(
    v_producer_code,
    'certified-league:' || p_league_id::text
      || ':' || lower(v_achievement)
      || ':' || coalesce(p_season_id::text, 'global'),
    p_user_id,
    p_certification_reference,
    1,
    jsonb_build_object(
      'certified', true,
      'certified_at', p_certified_at,
      'certification_digest', p_certification_digest,
      'league_id', p_league_id,
      'league_round_id', p_league_round_id,
      'season_id', p_season_id,
      'achievement_kind', lower(v_achievement)
    ),
    p_certified_at,
    p_league_id,
    p_league_round_id,
    p_season_id,
    null,
    p_correlation_id,
    p_causation_id,
    coalesce(p_payload, '{}'::jsonb),
    jsonb_build_object(
      'wrapper', 'emit_certified_league_achievement_internal'
    )
  );
end;
$$;

create or replace function public.emit_certified_participation_achievement_internal(
  p_user_id uuid,
  p_achievement_code text,
  p_certification_reference text,
  p_certification_digest text,
  p_certified_at timestamptz,
  p_league_id uuid default null,
  p_league_round_id uuid default null,
  p_season_id uuid default null,
  p_correlation_id uuid default null,
  p_causation_id uuid default null,
  p_payload jsonb default '{}'::jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_achievement text := upper(trim(p_achievement_code));
  v_producer_code text;
begin
  case v_achievement
    when 'PROFILE_COMPLETED_AFTER_FIRST_ROUND' then
      v_producer_code := 'PROFILE_COMPLETION_AFTER_FIRST_ROUND';
    when 'STREAK_5' then
      v_producer_code := 'PREDICTION_COMPLETION_STREAK_5';
    when 'STREAK_10' then
      v_producer_code := 'PREDICTION_COMPLETION_STREAK_10';
    when 'FULL_SEASON' then
      v_producer_code := 'PREDICTION_COMPLETION_FULL_SEASON';
    else
      raise exception using
        errcode = '22023',
        message = 'LOYALTY_PARTICIPATION_ACHIEVEMENT_INVALID';
  end case;

  return public.emit_certified_loyalty_event_internal(
    v_producer_code,
    'certified-participation:' || p_user_id::text
      || ':' || lower(v_achievement)
      || ':' || coalesce(p_league_id::text, 'global')
      || ':' || coalesce(p_season_id::text, 'global'),
    p_user_id,
    p_certification_reference,
    1,
    jsonb_build_object(
      'certified', true,
      'certified_at', p_certified_at,
      'certification_digest', p_certification_digest,
      'league_id', p_league_id,
      'league_round_id', p_league_round_id,
      'season_id', p_season_id,
      'participation_kind', lower(v_achievement)
    ),
    p_certified_at,
    p_league_id,
    p_league_round_id,
    p_season_id,
    null,
    p_correlation_id,
    p_causation_id,
    coalesce(p_payload, '{}'::jsonb),
    jsonb_build_object(
      'wrapper', 'emit_certified_participation_achievement_internal'
    )
  );
end;
$$;

-- ============================================================================
-- 7. PRODUCER ADMINISTRATION
-- ============================================================================

create or replace function public.set_loyalty_event_producer_state_internal(
  p_producer_code text,
  p_enabled boolean,
  p_test_mode boolean,
  p_reason text
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_reason text := nullif(trim(p_reason), '');
  v_producer public.loyalty_event_producers;
begin
  if v_reason is null or length(v_reason) < 8 then
    raise exception using
      errcode = '22023',
      message = 'LOYALTY_PRODUCER_STATE_REASON_REQUIRED';
  end if;

  update public.loyalty_event_producers
  set
    enabled = coalesce(p_enabled, enabled),
    test_mode = coalesce(p_test_mode, test_mode),
    metadata = metadata || jsonb_build_object(
      'last_state_change_reason', v_reason,
      'last_state_change_at', clock_timestamp()
    )
  where producer_code = upper(trim(p_producer_code))
  returning * into v_producer;

  if not found then
    raise exception using
      errcode = 'P0002',
      message = 'LOYALTY_PRODUCER_NOT_REGISTERED';
  end if;

  perform public.commercial_append_event_internal(
    'LOYALTY_PRODUCER_STATE_CHANGED',
    'LOYALTY_EVENT_PRODUCER',
    v_producer.id,
    null,
    gen_random_uuid(),
    null,
    jsonb_build_object(
      'producer_code', v_producer.producer_code,
      'enabled', v_producer.enabled,
      'test_mode', v_producer.test_mode,
      'reason', v_reason
    )
  );

  return jsonb_build_object(
    'updated', true,
    'producer_code', v_producer.producer_code,
    'enabled', v_producer.enabled,
    'test_mode', v_producer.test_mode,
    'server_time', clock_timestamp()
  );
end;
$$;

-- ============================================================================
-- 8. READ MODELS
-- ============================================================================

create or replace view public.loyalty_event_producer_registry_v
with (security_invoker = true)
as
select
  producer_code,
  producer_name,
  engine_code,
  event_code,
  adapter_family,
  certification_mode,
  certification_reference_prefix,
  enabled,
  test_mode,
  requires_service_role,
  requires_certification_evidence,
  minimum_evidence_version,
  version,
  updated_at
from public.loyalty_event_producers;

create or replace view public.loyalty_event_producer_health_v
with (security_invoker = true)
as
select
  count(*)::integer as producer_count,
  count(*) filter (where enabled)::integer as enabled_producer_count,
  count(*) filter (where test_mode)::integer as test_mode_producer_count,
  (
    select count(*)::integer
    from public.loyalty_event_producer_receipts
    where receipt_status = 'received'
  ) as received_receipt_count,
  (
    select count(*)::integer
    from public.loyalty_event_producer_receipts
    where receipt_status = 'validated'
  ) as validated_receipt_count,
  (
    select count(*)::integer
    from public.loyalty_event_producer_receipts
    where receipt_status in ('enqueued', 'duplicate')
  ) as delivered_receipt_count,
  (
    select count(*)::integer
    from public.loyalty_event_producer_receipts
    where receipt_status = 'rejected'
  ) as rejected_receipt_count,
  clock_timestamp() as server_time
from public.loyalty_event_producers;

comment on view public.loyalty_event_producer_registry_v is
  'Backend registry projection for certified loyalty event producers.';

comment on view public.loyalty_event_producer_health_v is
  'Backend health projection for certified loyalty producer receipts.';

-- ============================================================================
-- 9. SEED TEN PRODUCERS, ALL DISABLED
-- ============================================================================

insert into public.loyalty_event_producers (
  producer_code,
  producer_name,
  engine_code,
  event_code,
  adapter_family,
  certification_mode,
  certification_reference_prefix,
  enabled,
  test_mode,
  configuration,
  metadata
)
values
  (
    'LEAGUE_REACHED_8_MEMBERS',
    'League reached eight active members',
    'LEAGUE_GOVERNANCE_ENGINE',
    'LEAGUE_REACHED_8_ACTIVE_MEMBERS',
    'league',
    'certified_league_state',
    'league-membership-certification',
    false,
    true,
    jsonb_build_object('minimum_active_members', 8),
    jsonb_build_object('activation_phase', 'post-e2e')
  ),
  (
    'LEAGUE_FIRST_ROUND_CERTIFICATION',
    'League first round certified',
    'ROUND_CERTIFICATION_ENGINE',
    'LEAGUE_FIRST_ROUND_CERTIFIED',
    'league',
    'certified_round',
    'round-certification',
    false,
    true,
    jsonb_build_object('required_round_number', 1),
    jsonb_build_object('activation_phase', 'post-e2e')
  ),
  (
    'LEAGUE_SEASON_CERTIFICATION',
    'League season certified complete',
    'COMPETITION_ENGINE',
    'LEAGUE_SEASON_CERTIFIED_COMPLETE',
    'league',
    'certified_league_state',
    'season-certification',
    false,
    true,
    '{}'::jsonb,
    jsonb_build_object('activation_phase', 'post-e2e')
  ),
  (
    'PROFILE_COMPLETION_AFTER_FIRST_ROUND',
    'Profile completed after first certified round',
    'PROFILE_ENGINE',
    'PROFILE_COMPLETED_AFTER_FIRST_LEAGUE_ROUND',
    'participation',
    'certified_profile_state',
    'profile-state-certification',
    false,
    true,
    jsonb_build_object('minimum_completed_league_rounds', 1),
    jsonb_build_object('activation_phase', 'post-e2e')
  ),
  (
    'PREDICTION_RESULT_EXACT',
    'Certified Exact prediction result',
    'RESOLUTION_ENGINE',
    'CERTIFIED_EXACT_ACHIEVED',
    'prediction_result',
    'certified_result',
    'prediction-result-certification',
    false,
    true,
    jsonb_build_object('result_kind', 'exact'),
    jsonb_build_object('activation_phase', 'post-e2e')
  ),
  (
    'PREDICTION_RESULT_GRAND_SLAM',
    'Certified Grand Slam prediction result',
    'RESOLUTION_ENGINE',
    'CERTIFIED_GRAND_SLAM_ACHIEVED',
    'prediction_result',
    'certified_result',
    'prediction-result-certification',
    false,
    true,
    jsonb_build_object('result_kind', 'grand_slam'),
    jsonb_build_object('activation_phase', 'post-e2e')
  ),
  (
    'PREDICTION_RESULT_CANTONATA',
    'Certified Cantonata prediction result',
    'RESOLUTION_ENGINE',
    'CERTIFIED_CANTONATA_ACHIEVED',
    'prediction_result',
    'certified_result',
    'prediction-result-certification',
    false,
    true,
    jsonb_build_object('result_kind', 'cantonata'),
    jsonb_build_object('activation_phase', 'post-e2e')
  ),
  (
    'PREDICTION_COMPLETION_STREAK_5',
    'Five consecutive complete certified prediction rounds',
    'PARTICIPATION_ENGINE',
    'COMPLETE_PREDICTIONS_STREAK_5_CERTIFIED',
    'participation',
    'certified_participation_state',
    'participation-certification',
    false,
    true,
    jsonb_build_object('required_streak', 5),
    jsonb_build_object('activation_phase', 'post-e2e')
  ),
  (
    'PREDICTION_COMPLETION_STREAK_10',
    'Ten consecutive complete certified prediction rounds',
    'PARTICIPATION_ENGINE',
    'COMPLETE_PREDICTIONS_STREAK_10_CERTIFIED',
    'participation',
    'certified_participation_state',
    'participation-certification',
    false,
    true,
    jsonb_build_object('required_streak', 10),
    jsonb_build_object('activation_phase', 'post-e2e')
  ),
  (
    'PREDICTION_COMPLETION_FULL_SEASON',
    'Complete certified predictions for full season',
    'PARTICIPATION_ENGINE',
    'COMPLETE_PREDICTIONS_FULL_SEASON_CERTIFIED',
    'participation',
    'certified_participation_state',
    'participation-certification',
    false,
    true,
    jsonb_build_object('scope', 'league_season'),
    jsonb_build_object('activation_phase', 'post-e2e')
  )
on conflict (producer_code)
do update
set
  producer_name = excluded.producer_name,
  engine_code = excluded.engine_code,
  event_code = excluded.event_code,
  adapter_family = excluded.adapter_family,
  certification_mode = excluded.certification_mode,
  certification_reference_prefix =
    excluded.certification_reference_prefix,
  enabled = false,
  test_mode = true,
  requires_service_role = true,
  requires_certification_evidence = true,
  minimum_evidence_version = excluded.minimum_evidence_version,
  configuration = excluded.configuration,
  metadata = public.loyalty_event_producers.metadata
    || excluded.metadata;

-- ============================================================================
-- 10. RLS AND PRIVILEGES
-- ============================================================================

alter table public.loyalty_event_producers enable row level security;
alter table public.loyalty_event_producer_receipts enable row level security;

-- No client policies.

revoke all on table public.loyalty_event_producers
  from public, anon, authenticated;

revoke all on table public.loyalty_event_producer_receipts
  from public, anon, authenticated;

revoke all on table public.loyalty_event_producer_registry_v
  from public, anon, authenticated;

revoke all on table public.loyalty_event_producer_health_v
  from public, anon, authenticated;

grant all on table public.loyalty_event_producers to service_role;
grant all on table public.loyalty_event_producer_receipts to service_role;
grant select on table public.loyalty_event_producer_registry_v to service_role;
grant select on table public.loyalty_event_producer_health_v to service_role;

revoke all on function public.validate_loyalty_producer_evidence_internal(
  text, text, uuid, uuid, uuid, uuid, uuid, text, integer, jsonb
) from public, anon, authenticated;

revoke all on function public.emit_certified_loyalty_event_internal(
  text, text, uuid, text, integer, jsonb, timestamptz,
  uuid, uuid, uuid, uuid, uuid, uuid, jsonb, jsonb
) from public, anon, authenticated;

revoke all on function public.emit_certified_prediction_achievement_internal(
  uuid, text, uuid, uuid, uuid, text, text, timestamptz,
  uuid, uuid, uuid, jsonb
) from public, anon, authenticated;

revoke all on function public.emit_certified_league_achievement_internal(
  uuid, text, uuid, text, text, timestamptz,
  uuid, uuid, uuid, uuid, jsonb
) from public, anon, authenticated;

revoke all on function public.emit_certified_participation_achievement_internal(
  uuid, text, text, text, timestamptz,
  uuid, uuid, uuid, uuid, uuid, jsonb
) from public, anon, authenticated;

revoke all on function public.set_loyalty_event_producer_state_internal(
  text, boolean, boolean, text
) from public, anon, authenticated;

grant execute on function public.validate_loyalty_producer_evidence_internal(
  text, text, uuid, uuid, uuid, uuid, uuid, text, integer, jsonb
) to service_role;

grant execute on function public.emit_certified_loyalty_event_internal(
  text, text, uuid, text, integer, jsonb, timestamptz,
  uuid, uuid, uuid, uuid, uuid, uuid, jsonb, jsonb
) to service_role;

grant execute on function public.emit_certified_prediction_achievement_internal(
  uuid, text, uuid, uuid, uuid, text, text, timestamptz,
  uuid, uuid, uuid, jsonb
) to service_role;

grant execute on function public.emit_certified_league_achievement_internal(
  uuid, text, uuid, text, text, timestamptz,
  uuid, uuid, uuid, uuid, jsonb
) to service_role;

grant execute on function public.emit_certified_participation_achievement_internal(
  uuid, text, text, text, timestamptz,
  uuid, uuid, uuid, uuid, uuid, jsonb
) to service_role;

grant execute on function public.set_loyalty_event_producer_state_internal(
  text, boolean, boolean, text
) to service_role;

-- ============================================================================
-- 11. FINAL ASSERTIONS
-- ============================================================================

do $$
declare
  v_producer_count integer;
  v_enabled_producer_count integer;
  v_enabled_policy_count integer;
  v_enabled_campaign_count integer;
  v_enabled_source_count integer;
  v_duplicate_event_count integer;
begin
  select count(*)
  into v_producer_count
  from public.loyalty_event_producers;

  if v_producer_count <> 10 then
    raise exception using
      errcode = 'P0001',
      message = 'LOYALTY_PRODUCERS_EXPECTED_10';
  end if;

  select count(*)
  into v_enabled_producer_count
  from public.loyalty_event_producers
  where enabled = true;

  if v_enabled_producer_count <> 0 then
    raise exception using
      errcode = 'P0001',
      message = 'LOYALTY_PRODUCERS_MUST_REMAIN_DISABLED';
  end if;

  select count(*)
  into v_duplicate_event_count
  from (
    select event_code
    from public.loyalty_event_producers
    group by event_code
    having count(*) > 1
  ) d;

  if v_duplicate_event_count <> 0 then
    raise exception using
      errcode = 'P0001',
      message = 'LOYALTY_PRODUCERS_DUPLICATE_EVENT_CODE';
  end if;

  select count(*)
  into v_enabled_policy_count
  from public.loyalty_reward_policies
  where enabled = true;

  select count(*)
  into v_enabled_campaign_count
  from public.reward_campaigns
  where campaign_code like 'LOYALTY_%'
    and enabled = true;

  select count(*)
  into v_enabled_source_count
  from public.reward_sources
  where source_code = 'INTERNAL_ACHIEVEMENT'
    and enabled = true;

  if v_enabled_policy_count <> 0
     or v_enabled_campaign_count <> 0
     or v_enabled_source_count <> 0 then
    raise exception using
      errcode = 'P0001',
      message = 'LOYALTY_PRODUCER_MIGRATION_MUST_NOT_ACTIVATE_REWARDS';
  end if;

  if to_regprocedure(
    'public.emit_certified_loyalty_event_internal(text,text,uuid,text,integer,jsonb,timestamp with time zone,uuid,uuid,uuid,uuid,uuid,uuid,jsonb,jsonb)'
  ) is null then
    raise exception using
      errcode = 'P0001',
      message = 'LOYALTY_PRODUCER_EMIT_FUNCTION_MISSING';
  end if;

  raise notice 'CERTIFIED LOYALTY EVENT PRODUCERS INTEGRATION CERTIFIED';
  raise notice '10 authoritative producer contracts registered and disabled';
  raise notice 'Certified evidence validation and producer receipts installed';
  raise notice 'Producer events route idempotently to Migration 105 runtime inbox';
  raise notice 'No mutable game-table trigger has been introduced';
  raise notice 'No loyalty producer, policy, campaign or reward source has been enabled';
  raise notice 'Workflow handler calls and controlled E2E activation remain pending';
end;
$$;

commit;
