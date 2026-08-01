-- ============================================================================
-- FANTAGOL
-- Migration 173 v2: Account Deletion Identity Bridge
-- Phase 13.7.2
--
-- Purpose
--   Prepare the competitive and commercial schemas for certified Auth detach.
--   This migration does not anonymize, erase, schedule or execute any account.
--
-- Installs
--   - nullable + ON DELETE SET NULL competitive Auth links;
--   - permanent retention_subject_id bridge on commercial/loyalty domains;
--   - deterministic service-only retention-subject resolver;
--   - dual-write compatibility triggers for existing write functions;
--   - backfill for any existing commercial/loyalty rows;
--   - partial live-user uniqueness and permanent retention uniqueness;
--   - terminal-state invariants required before Auth detach.
--
-- Safety
--   - no account lifecycle state is advanced;
--   - no user_id or owner_id value is changed;
--   - no workflow/job/erasure step is created;
--   - runtime and destructive flags remain disabled.
-- ============================================================================

begin;

-- --------------------------------------------------------------------------
-- 1. Service-only retention identity resolver
-- --------------------------------------------------------------------------

create or replace function public.resolve_data_retention_subject_internal(
  p_user_id uuid,
  p_retention_basis text default 'mixed'
)
returns uuid
language plpgsql
security definer
set search_path = public, extensions, pg_catalog
as $function$
declare
  v_user_id uuid := p_user_id;
  v_basis text := coalesce(nullif(btrim(p_retention_basis), ''), 'mixed');
  v_subject_token text;
  v_subject_id uuid;
begin
  if v_user_id is null then
    raise exception using
      errcode = '22004',
      message = 'RETENTION_SUBJECT_USER_ID_REQUIRED';
  end if;

  if v_basis not in (
    'commercial_ledger_integrity',
    'payment_evidence',
    'fraud_prevention',
    'legal_claims',
    'certified_game_history',
    'compliance_audit',
    'mixed'
  ) then
    raise exception using
      errcode = '22023',
      message = 'RETENTION_SUBJECT_BASIS_INVALID';
  end if;

  -- Permanent pseudonymous identity. The raw Auth UUID is not stored in
  -- data_retention_subjects or its restricted metadata.
  v_subject_token := encode(
    extensions.digest(
      convert_to(
        'fantagol-retention-subject-v1:' || v_user_id::text,
        'UTF8'
      ),
      'sha256'
    ),
    'hex'
  );

  insert into public.data_retention_subjects (
    subject_token,
    subject_class,
    retention_status,
    retention_basis,
    basis_version,
    restricted_metadata
  )
  values (
    v_subject_token,
    'account',
    'active',
    v_basis,
    1,
    jsonb_build_object(
      'identity_contract', 'retention-subject-v1.0.1',
      'created_by', 'identity_bridge'
    )
  )
  on conflict (subject_token)
  do update
  set
    retention_status =
      case
        when public.data_retention_subjects.retention_status = 'pending'
          then 'active'
        else public.data_retention_subjects.retention_status
      end,
    retention_basis =
      case
        when public.data_retention_subjects.retention_basis = v_basis
          then public.data_retention_subjects.retention_basis
        else 'mixed'
      end,
    version = public.data_retention_subjects.version + 1,
    updated_at = clock_timestamp()
  returning id into v_subject_id;

  update public.account_lifecycle l
  set
    retention_subject_id = v_subject_id,
    version = l.version + 1,
    updated_at = clock_timestamp()
  where l.auth_user_id = v_user_id
    and l.retention_subject_id is null;

  return v_subject_id;
end;
$function$;

comment on function public.resolve_data_retention_subject_internal(uuid, text) is
  'Service-only deterministic resolver for the permanent pseudonymous commercial identity. It stores no raw Auth identifier in the retention subject.';

revoke all on function public.resolve_data_retention_subject_internal(uuid, text)
  from public, anon, authenticated;

grant execute on function public.resolve_data_retention_subject_internal(uuid, text)
  to service_role;

-- --------------------------------------------------------------------------
-- 2. Generic dual-write trigger
-- --------------------------------------------------------------------------

create or replace function public.ensure_retention_subject_bridge_internal()
returns trigger
language plpgsql
security definer
set search_path = public, pg_catalog
as $function$
begin
  if new.retention_subject_id is null and new.user_id is not null then
    new.retention_subject_id :=
      public.resolve_data_retention_subject_internal(
        new.user_id,
        case tg_table_name
          when 'commercial_ledger' then 'commercial_ledger_integrity'
          when 'commercial_purchases' then 'payment_evidence'
          else 'mixed'
        end
      );
  end if;

  if new.retention_subject_id is null then
    raise exception using
      errcode = '23514',
      message = 'RETENTION_SUBJECT_REQUIRED';
  end if;

  return new;
end;
$function$;

comment on function public.ensure_retention_subject_bridge_internal() is
  'Compatibility trigger that dual-writes retention identity while legacy writers still supply user_id.';

revoke all on function public.ensure_retention_subject_bridge_internal()
  from public, anon, authenticated;

grant execute on function public.ensure_retention_subject_bridge_internal()
  to service_role;

-- --------------------------------------------------------------------------
-- 3. Competitive identity bridge
-- --------------------------------------------------------------------------

alter table public.clubs
  alter column owner_id drop not null;

alter table public.clubs
  drop constraint if exists clubs_owner_id_fkey;

alter table public.clubs
  add constraint clubs_owner_id_fkey
  foreign key (owner_id)
  references auth.users(id)
  on delete set null;

alter table public.clubs
  drop constraint if exists clubs_owner_id_key;

drop index if exists public.clubs_owner_id_key;

create unique index if not exists clubs_owner_id_uidx
  on public.clubs(owner_id)
  where owner_id is not null;

alter table public.league_members
  alter column user_id drop not null;

alter table public.league_members
  drop constraint if exists league_members_user_id_fkey;

alter table public.league_members
  add constraint league_members_user_id_fkey
  foreign key (user_id)
  references auth.users(id)
  on delete set null;

alter table public.predictions
  alter column user_id drop not null;

alter table public.predictions
  drop constraint if exists predictions_user_id_fkey;

alter table public.predictions
  add constraint predictions_user_id_fkey
  foreign key (user_id)
  references auth.users(id)
  on delete set null;

-- The legacy prediction uniqueness contract is intentionally retained here.
-- Its retirement requires a separate write-path certification.

-- --------------------------------------------------------------------------
-- 4. Commercial / loyalty common retention identity columns
-- --------------------------------------------------------------------------

alter table public.commercial_wallets
  add column if not exists retention_subject_id uuid;

alter table public.commercial_ledger
  add column if not exists retention_subject_id uuid;

alter table public.commercial_purchases
  add column if not exists retention_subject_id uuid;

alter table public.premium_access_sessions
  add column if not exists retention_subject_id uuid;

alter table public.loyalty_event_producer_receipts
  add column if not exists retention_subject_id uuid;

alter table public.loyalty_reward_events
  add column if not exists retention_subject_id uuid;

alter table public.loyalty_reward_runtime_inbox
  add column if not exists retention_subject_id uuid;

alter table public.reward_claims
  add column if not exists retention_subject_id uuid;

alter table public.reward_revelations
  add column if not exists retention_subject_id uuid;

alter table public.workflow_loyalty_dispatch_outbox
  add column if not exists retention_subject_id uuid;

-- --------------------------------------------------------------------------
-- 5. Backfill all currently retained user domains
-- --------------------------------------------------------------------------

do $backfill$
declare
  v_record record;
  v_subject_id uuid;
begin
  for v_record in
    select distinct user_id
    from (
      select user_id from public.commercial_wallets
      union all
      select user_id from public.commercial_ledger
      union all
      select user_id from public.commercial_purchases
      union all
      select user_id from public.premium_access_sessions
      union all
      select user_id from public.loyalty_event_producer_receipts
      union all
      select user_id from public.loyalty_reward_events
      union all
      select user_id from public.loyalty_reward_runtime_inbox
      union all
      select user_id from public.reward_claims
      union all
      select user_id from public.reward_revelations
      union all
      select user_id from public.workflow_loyalty_dispatch_outbox
    ) identities
    where user_id is not null
  loop
    v_subject_id :=
      public.resolve_data_retention_subject_internal(
        v_record.user_id,
        'mixed'
      );

    update public.commercial_wallets
       set retention_subject_id = v_subject_id
     where user_id = v_record.user_id
       and retention_subject_id is null;

    update public.commercial_ledger
       set retention_subject_id = v_subject_id
     where user_id = v_record.user_id
       and retention_subject_id is null;

    update public.commercial_purchases
       set retention_subject_id = v_subject_id
     where user_id = v_record.user_id
       and retention_subject_id is null;

    update public.premium_access_sessions
       set retention_subject_id = v_subject_id
     where user_id = v_record.user_id
       and retention_subject_id is null;

    update public.loyalty_event_producer_receipts
       set retention_subject_id = v_subject_id
     where user_id = v_record.user_id
       and retention_subject_id is null;

    update public.loyalty_reward_events
       set retention_subject_id = v_subject_id
     where user_id = v_record.user_id
       and retention_subject_id is null;

    update public.loyalty_reward_runtime_inbox
       set retention_subject_id = v_subject_id
     where user_id = v_record.user_id
       and retention_subject_id is null;

    update public.reward_claims
       set retention_subject_id = v_subject_id
     where user_id = v_record.user_id
       and retention_subject_id is null;

    update public.reward_revelations
       set retention_subject_id = v_subject_id
     where user_id = v_record.user_id
       and retention_subject_id is null;

    update public.workflow_loyalty_dispatch_outbox
       set retention_subject_id = v_subject_id
     where user_id = v_record.user_id
       and retention_subject_id is null;
  end loop;
end;
$backfill$;

-- --------------------------------------------------------------------------
-- 6. Retention subject FKs
-- --------------------------------------------------------------------------

alter table public.commercial_wallets
  drop constraint if exists commercial_wallets_retention_subject_id_fkey;

alter table public.commercial_wallets
  add constraint commercial_wallets_retention_subject_id_fkey
  foreign key (retention_subject_id)
  references public.data_retention_subjects(id)
  on delete restrict;

alter table public.commercial_ledger
  drop constraint if exists commercial_ledger_retention_subject_id_fkey;

alter table public.commercial_ledger
  add constraint commercial_ledger_retention_subject_id_fkey
  foreign key (retention_subject_id)
  references public.data_retention_subjects(id)
  on delete restrict;

alter table public.commercial_purchases
  drop constraint if exists commercial_purchases_retention_subject_id_fkey;

alter table public.commercial_purchases
  add constraint commercial_purchases_retention_subject_id_fkey
  foreign key (retention_subject_id)
  references public.data_retention_subjects(id)
  on delete restrict;

alter table public.premium_access_sessions
  drop constraint if exists premium_access_sessions_retention_subject_id_fkey;

alter table public.premium_access_sessions
  add constraint premium_access_sessions_retention_subject_id_fkey
  foreign key (retention_subject_id)
  references public.data_retention_subjects(id)
  on delete restrict;

alter table public.loyalty_event_producer_receipts
  drop constraint if exists loyalty_event_producer_receipts_retention_subject_id_fkey;

alter table public.loyalty_event_producer_receipts
  add constraint loyalty_event_producer_receipts_retention_subject_id_fkey
  foreign key (retention_subject_id)
  references public.data_retention_subjects(id)
  on delete restrict;

alter table public.loyalty_reward_events
  drop constraint if exists loyalty_reward_events_retention_subject_id_fkey;

alter table public.loyalty_reward_events
  add constraint loyalty_reward_events_retention_subject_id_fkey
  foreign key (retention_subject_id)
  references public.data_retention_subjects(id)
  on delete restrict;

alter table public.loyalty_reward_runtime_inbox
  drop constraint if exists loyalty_reward_runtime_inbox_retention_subject_id_fkey;

alter table public.loyalty_reward_runtime_inbox
  add constraint loyalty_reward_runtime_inbox_retention_subject_id_fkey
  foreign key (retention_subject_id)
  references public.data_retention_subjects(id)
  on delete restrict;

alter table public.reward_claims
  drop constraint if exists reward_claims_retention_subject_id_fkey;

alter table public.reward_claims
  add constraint reward_claims_retention_subject_id_fkey
  foreign key (retention_subject_id)
  references public.data_retention_subjects(id)
  on delete restrict;

alter table public.reward_revelations
  drop constraint if exists reward_revelations_retention_subject_id_fkey;

alter table public.reward_revelations
  add constraint reward_revelations_retention_subject_id_fkey
  foreign key (retention_subject_id)
  references public.data_retention_subjects(id)
  on delete restrict;

alter table public.workflow_loyalty_dispatch_outbox
  drop constraint if exists workflow_loyalty_dispatch_retention_subject_id_fkey;

alter table public.workflow_loyalty_dispatch_outbox
  add constraint workflow_loyalty_dispatch_retention_subject_id_fkey
  foreign key (retention_subject_id)
  references public.data_retention_subjects(id)
  on delete restrict;

-- --------------------------------------------------------------------------
-- 7. Dual-write triggers before NOT NULL enforcement
-- --------------------------------------------------------------------------

drop trigger if exists trg_commercial_wallets_retention_bridge
  on public.commercial_wallets;
create trigger trg_commercial_wallets_retention_bridge
before insert or update of user_id, retention_subject_id
on public.commercial_wallets
for each row execute function
  public.ensure_retention_subject_bridge_internal();

drop trigger if exists trg_commercial_ledger_retention_bridge
  on public.commercial_ledger;
create trigger trg_commercial_ledger_retention_bridge
before insert or update of user_id, retention_subject_id
on public.commercial_ledger
for each row execute function
  public.ensure_retention_subject_bridge_internal();

drop trigger if exists trg_commercial_purchases_retention_bridge
  on public.commercial_purchases;
create trigger trg_commercial_purchases_retention_bridge
before insert or update of user_id, retention_subject_id
on public.commercial_purchases
for each row execute function
  public.ensure_retention_subject_bridge_internal();

drop trigger if exists trg_premium_access_sessions_retention_bridge
  on public.premium_access_sessions;
create trigger trg_premium_access_sessions_retention_bridge
before insert or update of user_id, retention_subject_id
on public.premium_access_sessions
for each row execute function
  public.ensure_retention_subject_bridge_internal();

drop trigger if exists trg_loyalty_event_receipts_retention_bridge
  on public.loyalty_event_producer_receipts;
create trigger trg_loyalty_event_receipts_retention_bridge
before insert or update of user_id, retention_subject_id
on public.loyalty_event_producer_receipts
for each row execute function
  public.ensure_retention_subject_bridge_internal();

drop trigger if exists trg_loyalty_reward_events_retention_bridge
  on public.loyalty_reward_events;
create trigger trg_loyalty_reward_events_retention_bridge
before insert or update of user_id, retention_subject_id
on public.loyalty_reward_events
for each row execute function
  public.ensure_retention_subject_bridge_internal();

drop trigger if exists trg_loyalty_runtime_inbox_retention_bridge
  on public.loyalty_reward_runtime_inbox;
create trigger trg_loyalty_runtime_inbox_retention_bridge
before insert or update of user_id, retention_subject_id
on public.loyalty_reward_runtime_inbox
for each row execute function
  public.ensure_retention_subject_bridge_internal();

drop trigger if exists trg_reward_claims_retention_bridge
  on public.reward_claims;
create trigger trg_reward_claims_retention_bridge
before insert or update of user_id, retention_subject_id
on public.reward_claims
for each row execute function
  public.ensure_retention_subject_bridge_internal();

drop trigger if exists trg_reward_revelations_retention_bridge
  on public.reward_revelations;
create trigger trg_reward_revelations_retention_bridge
before insert or update of user_id, retention_subject_id
on public.reward_revelations
for each row execute function
  public.ensure_retention_subject_bridge_internal();

drop trigger if exists trg_workflow_loyalty_outbox_retention_bridge
  on public.workflow_loyalty_dispatch_outbox;
create trigger trg_workflow_loyalty_outbox_retention_bridge
before insert or update of user_id, retention_subject_id
on public.workflow_loyalty_dispatch_outbox
for each row execute function
  public.ensure_retention_subject_bridge_internal();

-- Existing and future legacy writes now dual-write safely.
alter table public.commercial_wallets
  alter column retention_subject_id set not null;
alter table public.commercial_ledger
  alter column retention_subject_id set not null;
alter table public.commercial_purchases
  alter column retention_subject_id set not null;
alter table public.premium_access_sessions
  alter column retention_subject_id set not null;
alter table public.loyalty_event_producer_receipts
  alter column retention_subject_id set not null;
alter table public.loyalty_reward_events
  alter column retention_subject_id set not null;
alter table public.loyalty_reward_runtime_inbox
  alter column retention_subject_id set not null;
alter table public.reward_claims
  alter column retention_subject_id set not null;
alter table public.reward_revelations
  alter column retention_subject_id set not null;
alter table public.workflow_loyalty_dispatch_outbox
  alter column retention_subject_id set not null;

-- --------------------------------------------------------------------------
-- 8. Live Auth links become nullable + SET NULL
-- --------------------------------------------------------------------------

alter table public.commercial_wallets alter column user_id drop not null;
alter table public.commercial_ledger alter column user_id drop not null;
alter table public.commercial_purchases alter column user_id drop not null;
alter table public.premium_access_sessions alter column user_id drop not null;
alter table public.loyalty_event_producer_receipts alter column user_id drop not null;
alter table public.loyalty_reward_events alter column user_id drop not null;
alter table public.loyalty_reward_runtime_inbox alter column user_id drop not null;
alter table public.reward_claims alter column user_id drop not null;
alter table public.reward_revelations alter column user_id drop not null;
alter table public.workflow_loyalty_dispatch_outbox alter column user_id drop not null;

alter table public.commercial_wallets
  drop constraint if exists commercial_wallets_user_id_fkey;
alter table public.commercial_wallets
  add constraint commercial_wallets_user_id_fkey
  foreign key (user_id) references auth.users(id) on delete set null;

alter table public.commercial_purchases
  drop constraint if exists commercial_purchases_user_id_fkey;
alter table public.commercial_purchases
  add constraint commercial_purchases_user_id_fkey
  foreign key (user_id) references auth.users(id) on delete set null;

alter table public.loyalty_event_producer_receipts
  drop constraint if exists loyalty_event_producer_receipts_user_id_fkey;
alter table public.loyalty_event_producer_receipts
  add constraint loyalty_event_producer_receipts_user_id_fkey
  foreign key (user_id) references auth.users(id) on delete set null;

alter table public.loyalty_reward_events
  drop constraint if exists loyalty_reward_events_user_id_fkey;
alter table public.loyalty_reward_events
  add constraint loyalty_reward_events_user_id_fkey
  foreign key (user_id) references auth.users(id) on delete set null;

alter table public.loyalty_reward_runtime_inbox
  drop constraint if exists loyalty_reward_runtime_inbox_user_id_fkey;
alter table public.loyalty_reward_runtime_inbox
  add constraint loyalty_reward_runtime_inbox_user_id_fkey
  foreign key (user_id) references auth.users(id) on delete set null;

alter table public.reward_claims
  drop constraint if exists reward_claims_user_id_fkey;
alter table public.reward_claims
  add constraint reward_claims_user_id_fkey
  foreign key (user_id) references auth.users(id) on delete set null;

alter table public.reward_revelations
  drop constraint if exists reward_revelations_user_id_fkey;
alter table public.reward_revelations
  add constraint reward_revelations_user_id_fkey
  foreign key (user_id) references auth.users(id) on delete set null;

alter table public.workflow_loyalty_dispatch_outbox
  drop constraint if exists workflow_loyalty_dispatch_user_id_fkey;
alter table public.workflow_loyalty_dispatch_outbox
  add constraint workflow_loyalty_dispatch_user_id_fkey
  foreign key (user_id) references auth.users(id) on delete set null;

-- commercial_ledger and premium_access_sessions have no direct Auth FK in the
-- current schema audit; add the canonical bridge FKs.
alter table public.commercial_ledger
  drop constraint if exists commercial_ledger_user_id_fkey;
alter table public.commercial_ledger
  add constraint commercial_ledger_user_id_fkey
  foreign key (user_id) references auth.users(id) on delete set null;

alter table public.premium_access_sessions
  drop constraint if exists premium_access_sessions_user_id_fkey;
alter table public.premium_access_sessions
  add constraint premium_access_sessions_user_id_fkey
  foreign key (user_id) references auth.users(id) on delete set null;

-- --------------------------------------------------------------------------
-- 9. Uniqueness and lookup contracts
-- --------------------------------------------------------------------------

alter table public.commercial_wallets
  drop constraint if exists commercial_wallets_user_id_key;
drop index if exists public.commercial_wallets_user_id_key;

create unique index if not exists commercial_wallets_user_id_uidx
  on public.commercial_wallets(user_id)
  where user_id is not null;

create unique index if not exists commercial_wallets_retention_subject_uidx
  on public.commercial_wallets(retention_subject_id);

alter table public.commercial_purchases
  drop constraint if exists commercial_purchases_user_client_idempotency_key;
drop index if exists public.commercial_purchases_user_client_idempotency_key;

create unique index if not exists commercial_purchases_user_client_idempotency_uidx
  on public.commercial_purchases(user_id, client_idempotency_key)
  where user_id is not null;

create unique index if not exists commercial_purchases_retention_client_idempotency_uidx
  on public.commercial_purchases(
    retention_subject_id,
    client_idempotency_key
  );

alter table public.premium_access_sessions
  drop constraint if exists premium_access_sessions_request_key;
drop index if exists public.premium_access_sessions_request_key;

create unique index if not exists premium_access_sessions_request_user_uidx
  on public.premium_access_sessions(
    user_id,
    resource_code,
    request_idempotency_key
  )
  where user_id is not null;

create unique index if not exists premium_access_sessions_request_retention_uidx
  on public.premium_access_sessions(
    retention_subject_id,
    resource_code,
    request_idempotency_key
  );

drop index if exists public.premium_access_sessions_one_active_uidx;
create unique index if not exists premium_access_sessions_one_active_uidx
  on public.premium_access_sessions(user_id, resource_code)
  where status = 'active'
    and user_id is not null;

alter table public.reward_claims
  drop constraint if exists reward_claims_user_client_idempotency_key;
drop index if exists public.reward_claims_user_client_idempotency_key;

create unique index if not exists reward_claims_user_client_idempotency_uidx
  on public.reward_claims(user_id, client_idempotency_key)
  where user_id is not null
    and client_idempotency_key is not null;

create unique index if not exists reward_claims_retention_client_idempotency_uidx
  on public.reward_claims(
    retention_subject_id,
    client_idempotency_key
  )
  where client_idempotency_key is not null;

create index if not exists commercial_ledger_retention_subject_created_idx
  on public.commercial_ledger(retention_subject_id, created_at desc);

drop index if exists public.commercial_ledger_user_created_idx;
create index if not exists commercial_ledger_user_created_idx
  on public.commercial_ledger(user_id, created_at desc)
  where user_id is not null;

create index if not exists commercial_purchases_retention_created_idx
  on public.commercial_purchases(retention_subject_id, created_at desc);
create index if not exists premium_access_sessions_retention_idx
  on public.premium_access_sessions(
    retention_subject_id,
    resource_code,
    status,
    expires_at desc
  );
create index if not exists loyalty_event_receipts_retention_idx
  on public.loyalty_event_producer_receipts(
    retention_subject_id,
    received_at desc
  );
create index if not exists loyalty_reward_events_retention_idx
  on public.loyalty_reward_events(
    retention_subject_id,
    created_at desc
  );
create index if not exists loyalty_runtime_inbox_retention_idx
  on public.loyalty_reward_runtime_inbox(
    retention_subject_id,
    created_at desc
  );
create index if not exists reward_claims_retention_created_idx
  on public.reward_claims(retention_subject_id, created_at desc);
create index if not exists reward_revelations_retention_created_idx
  on public.reward_revelations(retention_subject_id, created_at desc);
create index if not exists workflow_loyalty_outbox_retention_idx
  on public.workflow_loyalty_dispatch_outbox(
    retention_subject_id,
    enqueued_at desc
  );

-- --------------------------------------------------------------------------
-- 10. Terminal-state safety contracts for detached rows
-- --------------------------------------------------------------------------

alter table public.commercial_wallets
  drop constraint if exists commercial_wallets_detached_terminal_ck;

alter table public.commercial_wallets
  add constraint commercial_wallets_detached_terminal_ck
  check (
    user_id is not null
    or (
      status = 'closed'
      and available_passes = 0
    )
  );

alter table public.commercial_purchases
  drop constraint if exists commercial_purchases_detached_terminal_ck;

alter table public.commercial_purchases
  add constraint commercial_purchases_detached_terminal_ck
  check (
    user_id is not null
    or purchase_status in (
      'confirmed',
      'cancelled',
      'failed',
      'refunded'
    )
  );

alter table public.premium_access_sessions
  drop constraint if exists premium_access_sessions_detached_terminal_ck;

alter table public.premium_access_sessions
  add constraint premium_access_sessions_detached_terminal_ck
  check (
    user_id is not null
    or status in ('expired', 'revoked')
  );

alter table public.loyalty_event_producer_receipts
  drop constraint if exists loyalty_event_receipts_detached_terminal_ck;

alter table public.loyalty_event_producer_receipts
  add constraint loyalty_event_receipts_detached_terminal_ck
  check (
    user_id is not null
    or receipt_status in (
      'enqueued',
      'duplicate',
      'rejected'
    )
  );

alter table public.loyalty_reward_events
  drop constraint if exists loyalty_reward_events_detached_terminal_ck;

alter table public.loyalty_reward_events
  add constraint loyalty_reward_events_detached_terminal_ck
  check (
    user_id is not null
    or event_status in (
      'rewarded',
      'ignored',
      'failed'
    )
  );

alter table public.loyalty_reward_runtime_inbox
  drop constraint if exists loyalty_runtime_inbox_detached_terminal_ck;

alter table public.loyalty_reward_runtime_inbox
  add constraint loyalty_runtime_inbox_detached_terminal_ck
  check (
    user_id is not null
    or event_status in (
      'rewarded',
      'skipped',
      'failed',
      'dead_letter'
    )
  );

alter table public.reward_claims
  drop constraint if exists reward_claims_detached_terminal_ck;

alter table public.reward_claims
  add constraint reward_claims_detached_terminal_ck
  check (
    user_id is not null
    or claim_status in (
      'rejected',
      'settled',
      'expired'
    )
  );

alter table public.reward_revelations
  drop constraint if exists reward_revelations_detached_terminal_ck;

alter table public.reward_revelations
  add constraint reward_revelations_detached_terminal_ck
  check (
    user_id is not null
    or revelation_status = 'seen'
  );

alter table public.workflow_loyalty_dispatch_outbox
  drop constraint if exists workflow_loyalty_outbox_detached_terminal_ck;

alter table public.workflow_loyalty_dispatch_outbox
  add constraint workflow_loyalty_outbox_detached_terminal_ck
  check (
    user_id is not null
    or dispatch_status in (
      'dispatched',
      'duplicate',
      'rejected',
      'dead_letter'
    )
  );

-- commercial_ledger is immutable evidence and may remain detached as long as
-- its permanent retention subject is present.

-- --------------------------------------------------------------------------
-- 11. Platform metadata
-- --------------------------------------------------------------------------

update public.account_lifecycle_policies
set
  policy_config = policy_config || jsonb_build_object(
    'identity_bridge_installed', true,
    'identity_bridge_version', '1.0.1',
    'commercial_dual_write_enabled', true,
    'commercial_retention_subject_required', true,
    'competitive_auth_detach_ready', true,
    'domain_handlers_enabled', false
  ),
  updated_at = clock_timestamp()
where policy_code = 'ACCOUNT_DELETION_STANDARD'
  and policy_version = 1;

update public.platform_configuration
set
  schema_version = greatest(schema_version, 173),
  metadata = metadata || jsonb_build_object(
    'account_deletion_identity_bridge_migration', 173,
    'account_deletion_identity_bridge_contract',
      'account-deletion-identity-bridge-v1.0.1',
    'account_deletion_domain_handlers_enabled', false,
    'account_deletion_identity_bridge_revision', 'v2'
  ),
  updated_at = now()
where configuration_key = 'primary';

update public.platform_engine_registry
set
  metadata = metadata || jsonb_build_object(
    'identity_bridge_migration', 173,
    'identity_bridge_contract',
      'account-deletion-identity-bridge-v1.0.1',
    'retention_subject_dual_write', true,
    'competitive_auth_detach_ready', true,
    'domain_handlers_installed', false,
    'destructive_handlers_installed', false
  ),
  updated_at = now()
where engine_code = 'account_lifecycle_engine';

-- --------------------------------------------------------------------------
-- 12. Assertions
-- --------------------------------------------------------------------------

do $assertions$
declare
  v_engine public.platform_engine_registry%rowtype;
  v_policy public.account_lifecycle_policies%rowtype;
  v_missing_retention bigint;
  v_workflow_count bigint;
  v_job_count bigint;
  v_advanced_run_count bigint;
begin
  select *
    into v_engine
  from public.platform_engine_registry
  where engine_code = 'account_lifecycle_engine';

  if not found
     or v_engine.lifecycle_status <> 'installed'
     or v_engine.runtime_enabled
     or v_engine.is_certified then
    raise exception
      'ACCOUNT_IDENTITY_BRIDGE_ASSERTION_FAILED: engine safety state changed';
  end if;

  select *
    into v_policy
  from public.account_lifecycle_policies
  where policy_code = 'ACCOUNT_DELETION_STANDARD'
    and policy_version = 1;

  if not found
     or v_policy.automatic_execution_enabled
     or coalesce(
       (v_policy.policy_config ->> 'runtime_launch_enabled')::boolean,
       true
     )
     or coalesce(
       (v_policy.policy_config ->> 'runtime_worker_enabled')::boolean,
       true
     )
     or coalesce(
       (v_policy.policy_config ->> 'domain_handlers_enabled')::boolean,
       true
     )
     or coalesce(
       (v_policy.policy_config ->> 'auth_deletion_enabled')::boolean,
       true
     ) then
    raise exception
      'ACCOUNT_IDENTITY_BRIDGE_ASSERTION_FAILED: execution enabled';
  end if;

  select sum(missing_count)
    into v_missing_retention
  from (
    select count(*) as missing_count
      from public.commercial_wallets
     where retention_subject_id is null
    union all
    select count(*) from public.commercial_ledger
     where retention_subject_id is null
    union all
    select count(*) from public.commercial_purchases
     where retention_subject_id is null
    union all
    select count(*) from public.premium_access_sessions
     where retention_subject_id is null
    union all
    select count(*) from public.loyalty_event_producer_receipts
     where retention_subject_id is null
    union all
    select count(*) from public.loyalty_reward_events
     where retention_subject_id is null
    union all
    select count(*) from public.loyalty_reward_runtime_inbox
     where retention_subject_id is null
    union all
    select count(*) from public.reward_claims
     where retention_subject_id is null
    union all
    select count(*) from public.reward_revelations
     where retention_subject_id is null
    union all
    select count(*) from public.workflow_loyalty_dispatch_outbox
     where retention_subject_id is null
  ) missing;

  if coalesce(v_missing_retention, 0) <> 0 then
    raise exception
      'ACCOUNT_IDENTITY_BRIDGE_ASSERTION_FAILED: retention backfill incomplete';
  end if;

  select count(*) into v_workflow_count
  from public.live_runtime_workflows
  where workflow_type = 'ACCOUNT_DELETION_V1';

  select count(*) into v_job_count
  from public.live_runtime_jobs
  where job_type = 'execute_account_erasure_step';

  select count(*) into v_advanced_run_count
  from public.account_erasure_runs
  where run_status in ('leased', 'running', 'completed')
     or workflow_id is not null;

  if v_workflow_count <> 0
     or v_job_count <> 0
     or v_advanced_run_count <> 0 then
    raise exception
      'ACCOUNT_IDENTITY_BRIDGE_ASSERTION_FAILED: runtime data changed';
  end if;

  if exists (
    select 1
    from public.account_lifecycle
    where lifecycle_status = 'deletion_scheduled'
      and (
        workflow_id is not null
        or erasure_started_at is not null
        or mutation_frozen_at is not null
      )
  ) then
    raise exception
      'ACCOUNT_IDENTITY_BRIDGE_ASSERTION_FAILED: scheduled lifecycle advanced';
  end if;
end;
$assertions$;

commit;
