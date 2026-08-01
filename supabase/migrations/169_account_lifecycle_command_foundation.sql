-- ============================================================================
-- FANTAGOL
-- Migration 169: Account Lifecycle Command Foundation
-- Phase 13.5.3
--
-- Purpose
--   Introduce the safe command layer for opening, reading and cancelling an
--   account deletion lifecycle.
--
-- Safety boundary
--   - no Auth user is deleted;
--   - no Storage object is deleted;
--   - no profile, Club, membership, prediction or commercial row is changed;
--   - no live-runtime workflow instance is launched;
--   - no erasure step handler is executed;
--   - automatic execution and every destructive feature remain disabled.
--
-- Strong confirmation
--   A client cannot self-assert recent authentication. A trusted backend first
--   reauthenticates the user and then issues a short-lived, one-time grant.
--   The authenticated request RPC atomically consumes that grant together with
--   the exact confirmation phrase.
-- ============================================================================

begin;

-- --------------------------------------------------------------------------
-- 1. Ephemeral recent-auth grants
-- --------------------------------------------------------------------------

create table if not exists public.account_deletion_reauth_grants (
  id uuid primary key default extensions.gen_random_uuid(),
  user_id uuid not null,
  token_digest text not null,
  confirmation_method text not null,
  grant_status text not null default 'active',
  issued_at timestamptz not null default clock_timestamp(),
  expires_at timestamptz not null,
  consumed_at timestamptz,
  revoked_at timestamptz,
  issued_by text not null default 'trusted_backend',
  correlation_id uuid,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default clock_timestamp(),

  constraint account_deletion_reauth_grants_user_fk
    foreign key (user_id)
    references auth.users(id)
    on delete cascade,
  constraint account_deletion_reauth_grants_token_uq
    unique (token_digest),
  constraint account_deletion_reauth_grants_method_ck
    check (confirmation_method in (
      'password_reauthentication',
      'oauth_reauthentication',
      'recent_session',
      'signed_email_link',
      'support_verified'
    )),
  constraint account_deletion_reauth_grants_status_ck
    check (grant_status in ('active','consumed','revoked','expired')),
  constraint account_deletion_reauth_grants_token_ck
    check (length(btrim(token_digest)) >= 64),
  constraint account_deletion_reauth_grants_time_ck
    check (
      expires_at > issued_at
      and (consumed_at is null or consumed_at >= issued_at)
      and (revoked_at is null or revoked_at >= issued_at)
    ),
  constraint account_deletion_reauth_grants_terminal_ck
    check (
      (grant_status <> 'consumed' or consumed_at is not null)
      and (grant_status <> 'revoked' or revoked_at is not null)
    ),
  constraint account_deletion_reauth_grants_metadata_ck
    check (jsonb_typeof(metadata) = 'object')
);

create index if not exists account_deletion_reauth_grants_user_active_idx
  on public.account_deletion_reauth_grants (user_id, expires_at)
  where grant_status = 'active';

create index if not exists account_deletion_reauth_grants_expiry_idx
  on public.account_deletion_reauth_grants (expires_at)
  where grant_status = 'active';

comment on table public.account_deletion_reauth_grants is
  'Short-lived one-time proof issued by a trusted backend after real reauthentication. Raw grant tokens are never persisted.';

alter table public.account_deletion_reauth_grants enable row level security;
alter table public.account_deletion_reauth_grants force row level security;

revoke all on table public.account_deletion_reauth_grants
  from public, anon, authenticated;

grant select, insert, update, delete
  on table public.account_deletion_reauth_grants
  to service_role;

drop policy if exists account_deletion_reauth_grants_service_all
  on public.account_deletion_reauth_grants;
create policy account_deletion_reauth_grants_service_all
  on public.account_deletion_reauth_grants
  for all
  to service_role
  using (true)
  with check (true);

-- --------------------------------------------------------------------------
-- 2. Internal audit writer
-- --------------------------------------------------------------------------

create or replace function public.append_account_deletion_audit_internal(
  p_account_lifecycle_id uuid,
  p_erasure_run_id uuid,
  p_event_code text,
  p_event_result text,
  p_step_code text default null,
  p_affected_row_count bigint default 0,
  p_affected_object_count bigint default 0,
  p_evidence_digest text default null,
  p_correlation_id uuid default null,
  p_causation_id uuid default null,
  p_failure_code text default null,
  p_blocker_code text default null,
  p_audit_metadata jsonb default '{}'::jsonb
)
returns uuid
language plpgsql
security definer
set search_path = public, extensions, pg_catalog
as $function$
declare
  v_lifecycle public.account_lifecycle%rowtype;
  v_policy public.account_lifecycle_policies%rowtype;
  v_audit_id uuid;
begin
  select *
    into v_lifecycle
  from public.account_lifecycle
  where id = p_account_lifecycle_id;

  if not found then
    raise exception using
      errcode = 'P0002',
      message = 'ACCOUNT_LIFECYCLE_NOT_FOUND';
  end if;

  select *
    into v_policy
  from public.account_lifecycle_policies
  where id = v_lifecycle.policy_id;

  if not found then
    raise exception using
      errcode = 'P0002',
      message = 'ACCOUNT_LIFECYCLE_POLICY_NOT_FOUND';
  end if;

  if p_event_code not in (
    'ACCOUNT_DELETION_REQUESTED',
    'ACCOUNT_DELETION_VERIFIED',
    'ACCOUNT_DELETION_SCHEDULED',
    'ACCOUNT_DELETION_CANCELLED',
    'ACCOUNT_ERASURE_STARTED',
    'ACCOUNT_ERASURE_BLOCKED',
    'ACCOUNT_ERASURE_RESUMED',
    'ACCOUNT_GOVERNANCE_TRANSFERRED',
    'ACCOUNT_COMMERCIAL_ACCESS_REVOKED',
    'ACCOUNT_RETENTION_SUBJECT_CREATED',
    'ACCOUNT_COMMERCIAL_IDENTITY_PSEUDONYMIZED',
    'ACCOUNT_COMPETITIVE_IDENTITY_ANONYMIZED',
    'ACCOUNT_JSONB_SCRUBBED',
    'ACCOUNT_STORAGE_ERASED',
    'ACCOUNT_PROFILE_ERASED',
    'ACCOUNT_AUTH_IDENTITY_DELETED',
    'ACCOUNT_ERASURE_FAILED',
    'ACCOUNT_DELETED'
  ) then
    raise exception using
      errcode = '22023',
      message = 'ACCOUNT_DELETION_AUDIT_EVENT_INVALID';
  end if;

  insert into public.account_deletion_audit (
    account_lifecycle_id,
    erasure_run_id,
    subject_token,
    event_code,
    event_version,
    event_result,
    policy_code,
    policy_version,
    workflow_code,
    workflow_version,
    occurred_at,
    step_code,
    affected_row_count,
    affected_object_count,
    evidence_digest,
    correlation_id,
    causation_id,
    failure_code,
    blocker_code,
    audit_metadata
  )
  values (
    v_lifecycle.id,
    p_erasure_run_id,
    v_lifecycle.subject_token,
    p_event_code,
    1,
    p_event_result,
    v_policy.policy_code,
    v_policy.policy_version,
    v_policy.workflow_code,
    v_policy.workflow_version,
    clock_timestamp(),
    p_step_code,
    greatest(coalesce(p_affected_row_count, 0), 0),
    greatest(coalesce(p_affected_object_count, 0), 0),
    p_evidence_digest,
    p_correlation_id,
    p_causation_id,
    p_failure_code,
    p_blocker_code,
    coalesce(p_audit_metadata, '{}'::jsonb)
  )
  returning id into v_audit_id;

  return v_audit_id;
end;
$function$;

comment on function public.append_account_deletion_audit_internal(
  uuid, uuid, text, text, text, bigint, bigint, text, uuid, uuid, text, text, jsonb
) is
  'Service-only append writer for non-identifying Account Lifecycle audit evidence.';

revoke all on function public.append_account_deletion_audit_internal(
  uuid, uuid, text, text, text, bigint, bigint, text, uuid, uuid, text, text, jsonb
) from public, anon, authenticated;

grant execute on function public.append_account_deletion_audit_internal(
  uuid, uuid, text, text, text, bigint, bigint, text, uuid, uuid, text, text, jsonb
) to service_role;

-- --------------------------------------------------------------------------
-- 3. Trusted-backend reauthentication grant issuance
-- --------------------------------------------------------------------------

create or replace function public.issue_account_deletion_reauth_grant_internal(
  p_user_id uuid,
  p_confirmation_method text,
  p_ttl interval default interval '5 minutes',
  p_correlation_id uuid default null,
  p_metadata jsonb default '{}'::jsonb
)
returns table (
  grant_id uuid,
  grant_token text,
  expires_at timestamptz
)
language plpgsql
security definer
set search_path = public, auth, extensions, pg_catalog
as $function$
declare
  v_raw_token text;
  v_digest text;
  v_grant_id uuid;
  v_expires_at timestamptz;
begin
  if p_user_id is null then
    raise exception using
      errcode = '22023',
      message = 'ACCOUNT_DELETION_REAUTH_USER_REQUIRED';
  end if;

  if not exists (
    select 1
    from auth.users
    where id = p_user_id
  ) then
    raise exception using
      errcode = 'P0002',
      message = 'ACCOUNT_DELETION_REAUTH_USER_NOT_FOUND';
  end if;

  if p_confirmation_method not in (
    'password_reauthentication',
    'oauth_reauthentication',
    'recent_session',
    'signed_email_link',
    'support_verified'
  ) then
    raise exception using
      errcode = '22023',
      message = 'ACCOUNT_DELETION_REAUTH_METHOD_INVALID';
  end if;

  if p_ttl < interval '30 seconds'
     or p_ttl > interval '15 minutes' then
    raise exception using
      errcode = '22023',
      message = 'ACCOUNT_DELETION_REAUTH_TTL_INVALID';
  end if;

  if jsonb_typeof(coalesce(p_metadata, '{}'::jsonb)) <> 'object' then
    raise exception using
      errcode = '22023',
      message = 'ACCOUNT_DELETION_REAUTH_METADATA_INVALID';
  end if;

  update public.account_deletion_reauth_grants
  set
    grant_status = 'expired'
  where user_id = p_user_id
    and grant_status = 'active'
    and expires_at <= clock_timestamp();

  update public.account_deletion_reauth_grants
  set
    grant_status = 'revoked',
    revoked_at = clock_timestamp()
  where user_id = p_user_id
    and grant_status = 'active';

  v_raw_token := encode(extensions.gen_random_bytes(32), 'hex');
  v_digest := encode(
    extensions.digest(convert_to(v_raw_token, 'UTF8'), 'sha256'),
    'hex'
  );
  v_expires_at := clock_timestamp() + p_ttl;

  insert into public.account_deletion_reauth_grants (
    user_id,
    token_digest,
    confirmation_method,
    grant_status,
    issued_at,
    expires_at,
    issued_by,
    correlation_id,
    metadata
  )
  values (
    p_user_id,
    v_digest,
    p_confirmation_method,
    'active',
    clock_timestamp(),
    v_expires_at,
    'trusted_backend',
    p_correlation_id,
    coalesce(p_metadata, '{}'::jsonb)
  )
  returning id into v_grant_id;

  return query
  select v_grant_id, v_raw_token, v_expires_at;
end;
$function$;

comment on function public.issue_account_deletion_reauth_grant_internal(
  uuid, text, interval, uuid, jsonb
) is
  'Service-only one-time grant issuer. The caller must complete real provider-appropriate reauthentication before invoking it.';

revoke all on function public.issue_account_deletion_reauth_grant_internal(
  uuid, text, interval, uuid, jsonb
) from public, anon, authenticated;

grant execute on function public.issue_account_deletion_reauth_grant_internal(
  uuid, text, interval, uuid, jsonb
) to service_role;

-- --------------------------------------------------------------------------
-- 4. User-safe state composer
-- --------------------------------------------------------------------------

create or replace function public.compose_my_account_deletion_status_internal(
  p_user_id uuid
)
returns jsonb
language plpgsql
security definer
stable
set search_path = public, pg_catalog
as $function$
declare
  v_lifecycle public.account_lifecycle%rowtype;
  v_policy public.account_lifecycle_policies%rowtype;
  v_request public.account_deletion_requests%rowtype;
  v_now timestamptz := clock_timestamp();
begin
  select *
    into v_lifecycle
  from public.account_lifecycle
  where auth_user_id = p_user_id;

  if not found then
    select *
      into v_policy
    from public.account_lifecycle_policies
    where policy_code = 'ACCOUNT_DELETION_STANDARD'
      and retired_at is null
      and effective_from <= v_now
    order by policy_version desc
    limit 1;

    return jsonb_build_object(
      'lifecycle_status', 'active',
      'has_open_request', false,
      'request_status', null,
      'requested_at', null,
      'scheduled_for', null,
      'cancellation_allowed', false,
      'cooling_off_seconds_remaining', 0,
      'automatic_execution_enabled',
        coalesce(v_policy.automatic_execution_enabled, false),
      'policy_code', v_policy.policy_code,
      'policy_version', v_policy.policy_version,
      'cooling_off_seconds',
        case
          when v_policy.id is null then null
          else extract(epoch from v_policy.cooling_off_interval)::bigint
        end,
      'blocked', false,
      'blocker_code', null,
      'failed', false,
      'failure_code', null
    );
  end if;

  select *
    into v_policy
  from public.account_lifecycle_policies
  where id = v_lifecycle.policy_id;

  if v_lifecycle.active_request_id is not null then
    select *
      into v_request
    from public.account_deletion_requests
    where id = v_lifecycle.active_request_id;
  end if;

  return jsonb_build_object(
    'lifecycle_status', v_lifecycle.lifecycle_status,
    'has_open_request',
      coalesce(v_request.request_status in (
        'pending_verification',
        'verified',
        'accepted',
        'scheduled',
        'executing'
      ), false),
    'request_status', v_request.request_status,
    'requested_at', v_lifecycle.requested_at,
    'scheduled_for', v_lifecycle.scheduled_for,
    'cancellation_allowed',
      v_lifecycle.lifecycle_status in (
        'delete_requested',
        'deletion_scheduled'
      ),
    'cooling_off_seconds_remaining',
      case
        when v_lifecycle.scheduled_for is null then 0
        else greatest(
          floor(extract(epoch from (v_lifecycle.scheduled_for - v_now)))::bigint,
          0
        )
      end,
    'automatic_execution_enabled',
      coalesce(v_policy.automatic_execution_enabled, false),
    'policy_code', v_policy.policy_code,
    'policy_version', v_policy.policy_version,
    'cooling_off_seconds',
      extract(epoch from v_policy.cooling_off_interval)::bigint,
    'blocked', v_lifecycle.lifecycle_status = 'erasure_blocked',
    'blocker_code',
      case
        when v_lifecycle.lifecycle_status = 'erasure_blocked'
          then v_lifecycle.blocker_code
        else null
      end,
    'failed', v_lifecycle.lifecycle_status = 'deletion_failed',
    'failure_code',
      case
        when v_lifecycle.lifecycle_status = 'deletion_failed'
          then v_lifecycle.failure_code
        else null
      end
  );
end;
$function$;

revoke all on function public.compose_my_account_deletion_status_internal(uuid)
  from public, anon, authenticated;

grant execute on function public.compose_my_account_deletion_status_internal(uuid)
  to service_role;

-- --------------------------------------------------------------------------
-- 5. Authenticated status RPC
-- --------------------------------------------------------------------------

create or replace function public.get_my_account_deletion_status_rpc()
returns jsonb
language plpgsql
security definer
stable
set search_path = public, auth, pg_catalog
as $function$
declare
  v_user_id uuid := auth.uid();
begin
  if v_user_id is null then
    raise exception using
      errcode = '42501',
      message = 'AUTHENTICATION_REQUIRED';
  end if;

  return public.compose_my_account_deletion_status_internal(v_user_id);
end;
$function$;

comment on function public.get_my_account_deletion_status_rpc() is
  'Returns the authenticated user-safe Account Lifecycle state without exposing subject tokens, workflow internals or retention identity.';

revoke all on function public.get_my_account_deletion_status_rpc()
  from public, anon;

grant execute on function public.get_my_account_deletion_status_rpc()
  to authenticated, service_role;

-- --------------------------------------------------------------------------
-- 6. Public policy read RPC
-- --------------------------------------------------------------------------

create or replace function public.get_account_deletion_public_policy_rpc()
returns jsonb
language sql
security definer
stable
set search_path = public, pg_catalog
as $function$
  select jsonb_build_object(
    'policy_code', p.policy_code,
    'policy_version', p.policy_version,
    'display_name', p.display_name,
    'description', p.description,
    'cooling_off_seconds',
      extract(epoch from p.cooling_off_interval)::bigint,
    'public_request_enabled', p.public_request_enabled,
    'authenticated_request_enabled', p.authenticated_request_enabled,
    'automatic_execution_enabled', p.automatic_execution_enabled,
    'confirmation_phrase', p.policy_config ->> 'confirmation_phrase',
    'data_handling', jsonb_build_object(
      'auth_identity', 'delete_last',
      'direct_personal_data', 'delete',
      'competitive_history', 'anonymize_and_retain',
      'commercial_evidence', 'pseudonymize_and_retain_restricted'
    )
  )
  from public.account_lifecycle_policies p
  where p.policy_code = 'ACCOUNT_DELETION_STANDARD'
    and p.retired_at is null
    and p.effective_from <= clock_timestamp()
  order by p.policy_version desc
  limit 1;
$function$;

comment on function public.get_account_deletion_public_policy_rpc() is
  'Public non-sensitive policy read model for the in-app and public account deletion pages.';

revoke all on function public.get_account_deletion_public_policy_rpc()
  from public;

grant execute on function public.get_account_deletion_public_policy_rpc()
  to anon, authenticated, service_role;

-- --------------------------------------------------------------------------
-- 7. Authenticated request command
-- --------------------------------------------------------------------------

create or replace function public.request_my_account_deletion_rpc(
  p_confirmation_phrase text,
  p_reauth_grant_token text,
  p_idempotency_key text,
  p_request_channel text default 'authenticated_web'
)
returns jsonb
language plpgsql
security definer
set search_path = public, auth, extensions, pg_catalog
as $function$
declare
  v_user_id uuid := auth.uid();
  v_now timestamptz := clock_timestamp();
  v_policy public.account_lifecycle_policies%rowtype;
  v_lifecycle public.account_lifecycle%rowtype;
  v_request public.account_deletion_requests%rowtype;
  v_grant public.account_deletion_reauth_grants%rowtype;
  v_token_digest text;
  v_subject_token text;
  v_scheduled_for timestamptz;
  v_plan_snapshot jsonb;
  v_plan_digest text;
  v_run_id uuid;
  v_correlation_id uuid := extensions.gen_random_uuid();
begin
  if v_user_id is null then
    raise exception using
      errcode = '42501',
      message = 'AUTHENTICATION_REQUIRED';
  end if;

  if p_request_channel not in ('authenticated_web','android_app') then
    raise exception using
      errcode = '22023',
      message = 'ACCOUNT_DELETION_REQUEST_CHANNEL_INVALID';
  end if;

  if length(btrim(coalesce(p_idempotency_key, ''))) not between 8 and 200 then
    raise exception using
      errcode = '22023',
      message = 'ACCOUNT_DELETION_IDEMPOTENCY_KEY_INVALID';
  end if;

  select *
    into v_policy
  from public.account_lifecycle_policies
  where policy_code = 'ACCOUNT_DELETION_STANDARD'
    and retired_at is null
    and effective_from <= v_now
    and authenticated_request_enabled
  order by policy_version desc
  limit 1;

  if not found then
    raise exception using
      errcode = '55000',
      message = 'ACCOUNT_DELETION_AUTHENTICATED_REQUEST_DISABLED';
  end if;

  -- Idempotent replay is resolved before consuming another reauth grant.
  select r.*
    into v_request
  from public.account_deletion_requests r
  join public.account_lifecycle l
    on l.id = r.account_lifecycle_id
  where l.auth_user_id = v_user_id
    and r.idempotency_key = p_idempotency_key
  order by r.created_at desc
  limit 1;

  if found then
    return public.compose_my_account_deletion_status_internal(v_user_id)
      || jsonb_build_object(
        'idempotent_replay', true,
        'request_id', v_request.id
      );
  end if;

  if p_confirmation_phrase is distinct from
     (v_policy.policy_config ->> 'confirmation_phrase') then
    raise exception using
      errcode = '22023',
      message = 'ACCOUNT_DELETION_CONFIRMATION_PHRASE_INVALID';
  end if;

  if length(btrim(coalesce(p_reauth_grant_token, ''))) < 32 then
    raise exception using
      errcode = '22023',
      message = 'ACCOUNT_DELETION_REAUTH_GRANT_INVALID';
  end if;

  v_token_digest := encode(
    extensions.digest(
      convert_to(btrim(p_reauth_grant_token), 'UTF8'),
      'sha256'
    ),
    'hex'
  );

  select *
    into v_grant
  from public.account_deletion_reauth_grants
  where token_digest = v_token_digest
  for update;

  if not found
     or v_grant.user_id <> v_user_id
     or v_grant.grant_status <> 'active'
     or v_grant.expires_at <= v_now then
    raise exception using
      errcode = '42501',
      message = 'ACCOUNT_DELETION_REAUTH_GRANT_INVALID_OR_EXPIRED';
  end if;

  select *
    into v_lifecycle
  from public.account_lifecycle
  where auth_user_id = v_user_id
  for update;

  if found and v_lifecycle.lifecycle_status in (
    'delete_requested',
    'deletion_scheduled',
    'erasure_running',
    'erasure_blocked',
    'deletion_failed'
  ) then
    raise exception using
      errcode = '55000',
      message = 'ACCOUNT_DELETION_ALREADY_ACTIVE';
  end if;

  if found and v_lifecycle.lifecycle_status = 'deleted' then
    raise exception using
      errcode = '55000',
      message = 'ACCOUNT_ALREADY_DELETED';
  end if;

  if not found then
    v_subject_token := encode(extensions.gen_random_bytes(32), 'hex');

    insert into public.account_lifecycle (
      auth_user_id,
      subject_token,
      policy_id,
      lifecycle_status,
      version
    )
    values (
      v_user_id,
      v_subject_token,
      v_policy.id,
      'active',
      1
    )
    returning * into v_lifecycle;
  else
    update public.account_lifecycle
    set
      policy_id = v_policy.id,
      blocker_code = null,
      failure_code = null,
      failure_message = null,
      version = version + 1
    where id = v_lifecycle.id
    returning * into v_lifecycle;
  end if;

  update public.account_deletion_reauth_grants
  set
    grant_status = 'consumed',
    consumed_at = v_now
  where id = v_grant.id;

  update public.account_lifecycle
  set
    lifecycle_status = 'delete_requested',
    requested_at = v_now,
    scheduled_for = null,
    cancelled_at = null,
    erasure_started_at = null,
    auth_deleted_at = null,
    completed_at = null,
    active_request_id = null,
    active_erasure_run_id = null,
    workflow_id = null,
    mutation_frozen_at = null,
    blocker_code = null,
    failure_code = null,
    failure_message = null,
    version = version + 1
  where id = v_lifecycle.id
  returning * into v_lifecycle;

  v_scheduled_for := v_now + v_policy.cooling_off_interval;

  insert into public.account_deletion_requests (
    account_lifecycle_id,
    policy_id,
    request_channel,
    request_status,
    confirmation_method,
    confirmation_phrase_version,
    confirmed_at,
    recent_auth_verified_at,
    idempotency_key,
    requested_at,
    scheduled_for,
    request_metadata
  )
  values (
    v_lifecycle.id,
    v_policy.id,
    p_request_channel,
    'scheduled',
    v_grant.confirmation_method,
    coalesce(
      v_policy.policy_config ->> 'confirmation_phrase_version',
      'ELIMINA_V1'
    ),
    v_now,
    v_grant.issued_at,
    p_idempotency_key,
    v_now,
    v_scheduled_for,
    jsonb_build_object(
      'correlation_id', v_correlation_id,
      'reauth_grant_id', v_grant.id,
      'foundation_migration', 169
    )
  )
  returning * into v_request;

  select jsonb_build_object(
    'workflow_code', v_policy.workflow_code,
    'workflow_version', v_policy.workflow_version,
    'catalog_version', 1,
    'policy_code', v_policy.policy_code,
    'policy_version', v_policy.policy_version,
    'scheduled_for', v_scheduled_for,
    'steps', jsonb_agg(
      jsonb_build_object(
        'step_code', c.step_code,
        'step_order', c.step_order,
        'handler_code', c.handler_code,
        'mandatory', c.mandatory,
        'irreversible', c.irreversible,
        'max_attempts', c.max_attempts,
        'timeout_seconds',
          extract(epoch from c.timeout_interval)::bigint
      )
      order by c.step_order
    )
  )
  into v_plan_snapshot
  from public.account_erasure_step_catalog c
  where c.workflow_code = v_policy.workflow_code
    and c.workflow_version = v_policy.workflow_version
    and c.catalog_version = 1
    and c.retired_at is null;

  if v_plan_snapshot is null
     or jsonb_array_length(v_plan_snapshot -> 'steps') <> 18 then
    raise exception using
      errcode = '55000',
      message = 'ACCOUNT_DELETION_STEP_CATALOG_INVALID';
  end if;

  v_plan_digest := encode(
    extensions.digest(
      convert_to(v_plan_snapshot::text, 'UTF8'),
      'sha256'
    ),
    'hex'
  );

  insert into public.account_erasure_runs (
    account_lifecycle_id,
    deletion_request_id,
    policy_id,
    workflow_id,
    workflow_code,
    workflow_version,
    step_catalog_version,
    run_status,
    plan_snapshot,
    plan_digest,
    scheduled_for,
    attempt_count,
    max_attempts,
    version
  )
  values (
    v_lifecycle.id,
    v_request.id,
    v_policy.id,
    null,
    v_policy.workflow_code,
    v_policy.workflow_version,
    1,
    'scheduled',
    v_plan_snapshot,
    v_plan_digest,
    v_scheduled_for,
    0,
    8,
    1
  )
  returning id into v_run_id;

  insert into public.account_erasure_steps (
    erasure_run_id,
    step_catalog_id,
    step_code,
    step_order,
    step_status,
    mandatory,
    irreversible,
    attempt_count,
    max_attempts,
    available_at,
    evidence_summary,
    version
  )
  select
    v_run_id,
    c.id,
    c.step_code,
    c.step_order,
    'pending',
    c.mandatory,
    c.irreversible,
    0,
    c.max_attempts,
    v_scheduled_for,
    '{}'::jsonb,
    1
  from public.account_erasure_step_catalog c
  where c.workflow_code = v_policy.workflow_code
    and c.workflow_version = v_policy.workflow_version
    and c.catalog_version = 1
    and c.retired_at is null
  order by c.step_order;

  update public.account_lifecycle
  set
    active_request_id = v_request.id,
    active_erasure_run_id = v_run_id,
    scheduled_for = v_scheduled_for,
    version = version + 1
  where id = v_lifecycle.id;

  perform public.append_account_deletion_audit_internal(
    v_lifecycle.id,
    v_run_id,
    'ACCOUNT_DELETION_REQUESTED',
    'accepted',
    null,
    1,
    0,
    null,
    v_correlation_id,
    null,
    null,
    null,
    jsonb_build_object(
      'request_channel', p_request_channel,
      'confirmation_method', v_grant.confirmation_method,
      'policy_version', v_policy.policy_version
    )
  );

  update public.account_lifecycle
  set
    lifecycle_status = 'deletion_scheduled',
    version = version + 1
  where id = v_lifecycle.id;

  perform public.append_account_deletion_audit_internal(
    v_lifecycle.id,
    v_run_id,
    'ACCOUNT_DELETION_SCHEDULED',
    'scheduled',
    null,
    1,
    0,
    v_plan_digest,
    v_correlation_id,
    null,
    null,
    null,
    jsonb_build_object(
      'scheduled_for', v_scheduled_for,
      'cooling_off_seconds',
        extract(epoch from v_policy.cooling_off_interval)::bigint,
      'canonical_step_count', 18
    )
  );

  return public.compose_my_account_deletion_status_internal(v_user_id)
    || jsonb_build_object(
      'idempotent_replay', false,
      'request_id', v_request.id,
      'erasure_run_id', v_run_id
    );
end;
$function$;

comment on function public.request_my_account_deletion_rpc(
  text, text, text, text
) is
  'Authenticated command that consumes a trusted recent-auth grant, opens the lifecycle, freezes the versioned erasure plan and schedules the cooling-off period. It performs no erasure.';

revoke all on function public.request_my_account_deletion_rpc(
  text, text, text, text
) from public, anon;

grant execute on function public.request_my_account_deletion_rpc(
  text, text, text, text
) to authenticated, service_role;

-- --------------------------------------------------------------------------
-- 8. Authenticated cancellation command
-- --------------------------------------------------------------------------

create or replace function public.cancel_my_account_deletion_rpc(
  p_idempotency_key text,
  p_cancellation_reason_code text default 'USER_REVOKED'
)
returns jsonb
language plpgsql
security definer
set search_path = public, auth, extensions, pg_catalog
as $function$
declare
  v_user_id uuid := auth.uid();
  v_lifecycle public.account_lifecycle%rowtype;
  v_request public.account_deletion_requests%rowtype;
  v_run public.account_erasure_runs%rowtype;
  v_now timestamptz := clock_timestamp();
  v_correlation_id uuid := extensions.gen_random_uuid();
begin
  if v_user_id is null then
    raise exception using
      errcode = '42501',
      message = 'AUTHENTICATION_REQUIRED';
  end if;

  if length(btrim(coalesce(p_idempotency_key, ''))) not between 8 and 200 then
    raise exception using
      errcode = '22023',
      message = 'ACCOUNT_DELETION_IDEMPOTENCY_KEY_INVALID';
  end if;

  select *
    into v_lifecycle
  from public.account_lifecycle
  where auth_user_id = v_user_id
  for update;

  if not found then
    return public.compose_my_account_deletion_status_internal(v_user_id)
      || jsonb_build_object('idempotent_replay', true);
  end if;

  if v_lifecycle.lifecycle_status = 'active' then
    return public.compose_my_account_deletion_status_internal(v_user_id)
      || jsonb_build_object('idempotent_replay', true);
  end if;

  if v_lifecycle.lifecycle_status not in (
    'delete_requested',
    'deletion_scheduled'
  ) then
    raise exception using
      errcode = '55000',
      message = 'ACCOUNT_DELETION_CANCELLATION_NOT_ALLOWED';
  end if;

  select *
    into v_request
  from public.account_deletion_requests
  where id = v_lifecycle.active_request_id
  for update;

  if not found then
    raise exception using
      errcode = 'P0002',
      message = 'ACCOUNT_DELETION_ACTIVE_REQUEST_NOT_FOUND';
  end if;

  select *
    into v_run
  from public.account_erasure_runs
  where id = v_lifecycle.active_erasure_run_id
  for update;

  if found and (
    v_run.run_status not in ('planned','scheduled','cancelled')
    or v_run.started_at is not null
    or v_run.workflow_id is not null
  ) then
    raise exception using
      errcode = '55000',
      message = 'ACCOUNT_DELETION_CANCELLATION_NOT_ALLOWED';
  end if;

  if v_request.request_status = 'cancelled' then
    return public.compose_my_account_deletion_status_internal(v_user_id)
      || jsonb_build_object(
        'idempotent_replay', true,
        'request_id', v_request.id
      );
  end if;

  update public.account_deletion_requests
  set
    request_status = 'cancelled',
    cancelled_at = v_now,
    cancellation_reason_code =
      left(coalesce(nullif(btrim(p_cancellation_reason_code), ''), 'USER_REVOKED'), 100)
  where id = v_request.id;

  if v_run.id is not null then
    update public.account_erasure_runs
    set
      run_status = 'cancelled',
      cancelled_at = v_now,
      lease_owner = null,
      lease_token = null,
      leased_at = null,
      lease_expires_at = null,
      version = version + 1
    where id = v_run.id;
  end if;

  update public.account_lifecycle
  set
    lifecycle_status = 'deletion_cancelled',
    cancelled_at = v_now,
    version = version + 1
  where id = v_lifecycle.id;

  perform public.append_account_deletion_audit_internal(
    v_lifecycle.id,
    v_run.id,
    'ACCOUNT_DELETION_CANCELLED',
    'cancelled',
    null,
    1,
    0,
    null,
    v_correlation_id,
    null,
    null,
    null,
    jsonb_build_object(
      'reason_code',
        left(coalesce(nullif(btrim(p_cancellation_reason_code), ''), 'USER_REVOKED'), 100)
    )
  );

  update public.account_lifecycle
  set
    lifecycle_status = 'active',
    requested_at = null,
    scheduled_for = null,
    erasure_started_at = null,
    auth_deleted_at = null,
    completed_at = null,
    active_request_id = null,
    active_erasure_run_id = null,
    workflow_id = null,
    mutation_frozen_at = null,
    blocker_code = null,
    failure_code = null,
    failure_message = null,
    version = version + 1
  where id = v_lifecycle.id;

  return public.compose_my_account_deletion_status_internal(v_user_id)
    || jsonb_build_object(
      'idempotent_replay', false,
      'cancelled_request_id', v_request.id,
      'cancelled_erasure_run_id', v_run.id
    );
end;
$function$;

comment on function public.cancel_my_account_deletion_rpc(text, text) is
  'Authenticated idempotent cancellation command. Cancellation is allowed only before erasure execution begins.';

revoke all on function public.cancel_my_account_deletion_rpc(text, text)
  from public, anon;

grant execute on function public.cancel_my_account_deletion_rpc(text, text)
  to authenticated, service_role;

-- --------------------------------------------------------------------------
-- 9. Guard against premature runtime launch
-- --------------------------------------------------------------------------

create or replace function public.guard_account_erasure_run_runtime_boundary()
returns trigger
language plpgsql
security invoker
set search_path = public, pg_catalog
as $function$
declare
  v_policy public.account_lifecycle_policies%rowtype;
begin
  if (
    new.workflow_id is distinct from old.workflow_id
    and new.workflow_id is not null
  ) or new.run_status in ('leased','running') then
    select p.*
      into v_policy
    from public.account_lifecycle_policies p
    where p.id = new.policy_id;

    if not coalesce(v_policy.automatic_execution_enabled, false)
       or not coalesce(
         (v_policy.policy_config ->> 'auth_deletion_enabled')::boolean,
         false
       ) then
      raise exception using
        errcode = '55000',
        message = 'ACCOUNT_DELETION_RUNTIME_NOT_ENABLED';
    end if;
  end if;

  return new;
end;
$function$;

drop trigger if exists trg_guard_account_erasure_run_runtime_boundary
  on public.account_erasure_runs;
create trigger trg_guard_account_erasure_run_runtime_boundary
before update of workflow_id, run_status
on public.account_erasure_runs
for each row execute function public.guard_account_erasure_run_runtime_boundary();

revoke all on function public.guard_account_erasure_run_runtime_boundary()
  from public, anon, authenticated;

grant execute on function public.guard_account_erasure_run_runtime_boundary()
  to service_role;

-- --------------------------------------------------------------------------
-- 10. Runtime-safe maintenance helper for expired grants
-- --------------------------------------------------------------------------

create or replace function public.expire_account_deletion_reauth_grants_internal(
  p_limit integer default 500
)
returns integer
language plpgsql
security definer
set search_path = public, pg_catalog
as $function$
declare
  v_count integer;
begin
  if p_limit < 1 or p_limit > 5000 then
    raise exception using
      errcode = '22023',
      message = 'ACCOUNT_DELETION_REAUTH_EXPIRE_LIMIT_INVALID';
  end if;

  with due as (
    select id
    from public.account_deletion_reauth_grants
    where grant_status = 'active'
      and expires_at <= clock_timestamp()
    order by expires_at, id
    limit p_limit
    for update skip locked
  )
  update public.account_deletion_reauth_grants g
  set grant_status = 'expired'
  from due
  where g.id = due.id;

  get diagnostics v_count = row_count;
  return v_count;
end;
$function$;

revoke all on function public.expire_account_deletion_reauth_grants_internal(integer)
  from public, anon, authenticated;

grant execute on function public.expire_account_deletion_reauth_grants_internal(integer)
  to service_role;

-- --------------------------------------------------------------------------
-- 11. Platform metadata
-- --------------------------------------------------------------------------

update public.platform_configuration
set
  schema_version = greatest(schema_version, 169),
  metadata = metadata || jsonb_build_object(
    'account_lifecycle_command_foundation_migration', 169,
    'account_lifecycle_command_contract', 'account-lifecycle-command-v1',
    'account_lifecycle_runtime_enabled', false,
    'account_lifecycle_destructive_features_enabled', false
  ),
  updated_at = now()
where configuration_key = 'primary';

update public.platform_engine_registry
set
  metadata = metadata || jsonb_build_object(
    'command_foundation_migration', 169,
    'command_contract', 'account-lifecycle-command-v1',
    'reauth_grant_contract', 'one-time-sha256-v1',
    'request_rpc', 'request_my_account_deletion_rpc',
    'cancel_rpc', 'cancel_my_account_deletion_rpc',
    'status_rpc', 'get_my_account_deletion_status_rpc',
    'runtime_launch_enabled', false
  ),
  updated_at = now()
where engine_code = 'account_lifecycle_engine';

-- --------------------------------------------------------------------------
-- 12. Migration assertions
-- --------------------------------------------------------------------------

do $assertions$
declare
  v_engine public.platform_engine_registry%rowtype;
  v_policy public.account_lifecycle_policies%rowtype;
  v_execute_count integer;
begin
  if to_regclass('public.account_deletion_reauth_grants') is null then
    raise exception
      'ACCOUNT_LIFECYCLE_COMMAND_ASSERTION_FAILED: reauth grants table missing';
  end if;

  if to_regprocedure(
    'public.issue_account_deletion_reauth_grant_internal(uuid,text,interval,uuid,jsonb)'
  ) is null then
    raise exception
      'ACCOUNT_LIFECYCLE_COMMAND_ASSERTION_FAILED: grant issuer missing';
  end if;

  if to_regprocedure(
    'public.request_my_account_deletion_rpc(text,text,text,text)'
  ) is null then
    raise exception
      'ACCOUNT_LIFECYCLE_COMMAND_ASSERTION_FAILED: request RPC missing';
  end if;

  if to_regprocedure(
    'public.cancel_my_account_deletion_rpc(text,text)'
  ) is null then
    raise exception
      'ACCOUNT_LIFECYCLE_COMMAND_ASSERTION_FAILED: cancel RPC missing';
  end if;

  if to_regprocedure(
    'public.get_my_account_deletion_status_rpc()'
  ) is null then
    raise exception
      'ACCOUNT_LIFECYCLE_COMMAND_ASSERTION_FAILED: status RPC missing';
  end if;

  if to_regprocedure(
    'public.get_account_deletion_public_policy_rpc()'
  ) is null then
    raise exception
      'ACCOUNT_LIFECYCLE_COMMAND_ASSERTION_FAILED: public policy RPC missing';
  end if;

  select *
    into v_policy
  from public.account_lifecycle_policies
  where policy_code = 'ACCOUNT_DELETION_STANDARD'
    and policy_version = 1;

  if not found
     or v_policy.automatic_execution_enabled
     or coalesce(
       (v_policy.policy_config ->> 'auth_deletion_enabled')::boolean,
       true
     )
     or coalesce(
       (v_policy.policy_config ->> 'storage_deletion_enabled')::boolean,
       true
     )
     or coalesce(
       (v_policy.policy_config ->> 'commercial_detach_enabled')::boolean,
       true
     )
     or coalesce(
       (v_policy.policy_config ->> 'competitive_anonymization_enabled')::boolean,
       true
     ) then
    raise exception
      'ACCOUNT_LIFECYCLE_COMMAND_ASSERTION_FAILED: destructive features must remain disabled';
  end if;

  select *
    into v_engine
  from public.platform_engine_registry
  where engine_code = 'account_lifecycle_engine';

  if not found
     or v_engine.runtime_enabled
     or v_engine.is_certified
     or v_engine.lifecycle_status <> 'installed' then
    raise exception
      'ACCOUNT_LIFECYCLE_COMMAND_ASSERTION_FAILED: engine activation state changed';
  end if;

  select count(*)
    into v_execute_count
  from information_schema.routine_privileges
  where specific_schema = 'public'
    and routine_name = 'request_my_account_deletion_rpc'
    and grantee = 'authenticated'
    and privilege_type = 'EXECUTE';

  if v_execute_count < 1 then
    raise exception
      'ACCOUNT_LIFECYCLE_COMMAND_ASSERTION_FAILED: authenticated request grant missing';
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
  ) or exists (
    select 1
    from public.account_deletion_reauth_grants
  ) then
    raise exception
      'ACCOUNT_LIFECYCLE_COMMAND_ASSERTION_FAILED: migration created operational user data';
  end if;

  if exists (
    select 1
    from public.live_runtime_workflow_registry
    where workflow_key = 'ACCOUNT_DELETION_V1'
  ) then
    raise exception
      'ACCOUNT_LIFECYCLE_COMMAND_ASSERTION_FAILED: migration created a workflow instance';
  end if;
end;
$assertions$;

commit;
