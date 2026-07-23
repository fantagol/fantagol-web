-- ============================================================================
-- FANTAGOL
-- Migration: 111_pass_ledger_contract_alignment.sql
-- Milestone: 11.4.1 - Pass Ledger Contract Alignment
--
-- Purpose:
--   - Preserve historical commercial records.
--   - Block every new use of deprecated commercial reward categories.
--   - Restrict the active Premium Pass contract to:
--       PASS_PURCHASE
--       PASS_REWARD
--       PASS_CONSUMPTION
--       PASS_REFUND
--       MANUAL_ADJUSTMENT
--   - Freeze lifetime_promotional as a legacy read-only projection.
--
-- Deprecated categories retained only for historical compatibility:
--   - PASS_PROMOTION
--   - PASS_GIFT
--   - PASS_REFERRAL
-- ============================================================================

begin;

do $$
begin
  if to_regclass('public.commercial_ledger') is null then
    raise exception using errcode = '42P01', message = 'PASS_LEDGER_ALIGNMENT_COMMERCIAL_LEDGER_MISSING';
  end if;
  if to_regclass('public.commercial_wallets') is null then
    raise exception using errcode = '42P01', message = 'PASS_LEDGER_ALIGNMENT_COMMERCIAL_WALLETS_MISSING';
  end if;
  if to_regclass('public.reward_campaigns') is null then
    raise exception using errcode = '42P01', message = 'PASS_LEDGER_ALIGNMENT_REWARD_CAMPAIGNS_MISSING';
  end if;
  if to_regclass('public.reward_claims') is null then
    raise exception using errcode = '42P01', message = 'PASS_LEDGER_ALIGNMENT_REWARD_CLAIMS_MISSING';
  end if;
end;
$$;

update public.reward_campaigns
set enabled = false, updated_at = clock_timestamp()
where reward_type in ('PASS_PROMOTION','PASS_GIFT','PASS_REFERRAL')
  and enabled is true;

comment on column public.reward_campaigns.reward_type is
'Active contract accepts PASS_REWARD only. Deprecated values are retained solely for historical compatibility.';
comment on column public.reward_claims.reward_type is
'Active contract accepts PASS_REWARD only. Deprecated values are retained solely for historical compatibility.';
comment on column public.commercial_wallets.lifetime_promotional is
'Legacy frozen projection retained for historical compatibility. No new commercial operation may increment this field.';

create or replace function public.guard_active_commercial_ledger_contract()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
  if new.transaction_type in ('PASS_PROMOTION','PASS_GIFT','PASS_REFERRAL') then
    raise exception using
      errcode = 'P0001',
      message = 'COMMERCIAL_LEDGER_TRANSACTION_TYPE_DEPRECATED',
      detail = format('transaction_type %s is retained for historical compatibility only', new.transaction_type),
      hint = 'Use PASS_REWARD for approved server-authoritative rewards.';
  end if;

  if new.transaction_type not in ('PASS_PURCHASE','PASS_REWARD','PASS_CONSUMPTION','PASS_REFUND','MANUAL_ADJUSTMENT') then
    raise exception using
      errcode = 'P0001',
      message = 'COMMERCIAL_LEDGER_TRANSACTION_TYPE_NOT_ALLOWED',
      detail = format('transaction_type %s is outside the active Premium Pass contract', coalesce(new.transaction_type, '<null>'));
  end if;

  return new;
end;
$$;

drop trigger if exists commercial_ledger_active_contract_guard on public.commercial_ledger;
create trigger commercial_ledger_active_contract_guard
before insert on public.commercial_ledger
for each row execute function public.guard_active_commercial_ledger_contract();

create or replace function public.guard_active_reward_campaign_contract()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
  if new.reward_type <> 'PASS_REWARD' then
    raise exception using
      errcode = 'P0001',
      message = 'REWARD_CAMPAIGN_TYPE_NOT_ALLOWED',
      detail = format('reward_type %s is outside the active reward contract', coalesce(new.reward_type, '<null>')),
      hint = 'Every approved Premium Pass reward campaign must use PASS_REWARD.';
  end if;
  return new;
end;
$$;

drop trigger if exists reward_campaigns_active_contract_guard on public.reward_campaigns;
create trigger reward_campaigns_active_contract_guard
before insert or update of reward_type on public.reward_campaigns
for each row execute function public.guard_active_reward_campaign_contract();

create or replace function public.guard_active_reward_claim_contract()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
  if new.reward_type <> 'PASS_REWARD' then
    raise exception using
      errcode = 'P0001',
      message = 'REWARD_CLAIM_TYPE_NOT_ALLOWED',
      detail = format('reward_type %s is outside the active reward contract', coalesce(new.reward_type, '<null>')),
      hint = 'Every new Premium Pass reward claim must use PASS_REWARD.';
  end if;
  return new;
end;
$$;

drop trigger if exists reward_claims_active_contract_guard on public.reward_claims;
create trigger reward_claims_active_contract_guard
before insert or update of reward_type on public.reward_claims
for each row execute function public.guard_active_reward_claim_contract();

create or replace function public.guard_legacy_promotional_projection_freeze()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
  if new.lifetime_promotional is distinct from old.lifetime_promotional then
    raise exception using
      errcode = 'P0001',
      message = 'COMMERCIAL_WALLET_LEGACY_PROMOTIONAL_PROJECTION_FROZEN',
      detail = 'lifetime_promotional is retained for historical compatibility and cannot change';
  end if;
  return new;
end;
$$;

drop trigger if exists commercial_wallets_legacy_promotional_freeze on public.commercial_wallets;
create trigger commercial_wallets_legacy_promotional_freeze
before update of lifetime_promotional on public.commercial_wallets
for each row execute function public.guard_legacy_promotional_projection_freeze();

revoke all on function public.guard_active_commercial_ledger_contract() from public, anon, authenticated;
revoke all on function public.guard_active_reward_campaign_contract() from public, anon, authenticated;
revoke all on function public.guard_active_reward_claim_contract() from public, anon, authenticated;
revoke all on function public.guard_legacy_promotional_projection_freeze() from public, anon, authenticated;

grant execute on function public.guard_active_commercial_ledger_contract() to service_role;
grant execute on function public.guard_active_reward_campaign_contract() to service_role;
grant execute on function public.guard_active_reward_claim_contract() to service_role;
grant execute on function public.guard_legacy_promotional_projection_freeze() to service_role;

do $$
declare
  v_enabled_deprecated_campaigns bigint;
begin
  select count(*) into v_enabled_deprecated_campaigns
  from public.reward_campaigns
  where reward_type in ('PASS_PROMOTION','PASS_GIFT','PASS_REFERRAL')
    and enabled is true;

  if v_enabled_deprecated_campaigns <> 0 then
    raise exception using errcode = 'P0001', message = 'PASS_LEDGER_ALIGNMENT_DEPRECATED_CAMPAIGN_STILL_ENABLED';
  end if;

  if not exists (select 1 from pg_trigger where tgname = 'commercial_ledger_active_contract_guard' and not tgisinternal) then
    raise exception using errcode = 'P0001', message = 'PASS_LEDGER_ALIGNMENT_LEDGER_GUARD_MISSING';
  end if;
  if not exists (select 1 from pg_trigger where tgname = 'reward_campaigns_active_contract_guard' and not tgisinternal) then
    raise exception using errcode = 'P0001', message = 'PASS_LEDGER_ALIGNMENT_CAMPAIGN_GUARD_MISSING';
  end if;
  if not exists (select 1 from pg_trigger where tgname = 'reward_claims_active_contract_guard' and not tgisinternal) then
    raise exception using errcode = 'P0001', message = 'PASS_LEDGER_ALIGNMENT_CLAIM_GUARD_MISSING';
  end if;
  if not exists (select 1 from pg_trigger where tgname = 'commercial_wallets_legacy_promotional_freeze' and not tgisinternal) then
    raise exception using errcode = 'P0001', message = 'PASS_LEDGER_ALIGNMENT_PROMOTIONAL_FREEZE_MISSING';
  end if;
end;
$$;

commit;
