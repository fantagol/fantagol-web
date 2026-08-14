begin;

-- ============================================================================
-- FANTAGOL
-- Migration 239
-- Rewarded Ad test-mode canary scope
--
-- Goal:
--   While REWARDED_AD remains in test_mode, claims are permitted only for
--   explicitly authorized users.
--
-- Production invariant:
--   When the reward source leaves test_mode, this guard becomes inert.
--
-- Initial certification scope:
--   Pirata da Vinci
--   4bfb4391-15a2-4b21-989e-43299c73c49c
-- ============================================================================


-- ============================================================================
-- 1. PRIVATE TEST AUTHORIZATION REGISTRY
-- ============================================================================

create table if not exists public.commercial_reward_test_authorizations (
  id uuid primary key default gen_random_uuid(),

  campaign_id uuid not null
    references public.reward_campaigns(id)
    on delete cascade,

  user_id uuid not null
    references auth.users(id)
    on delete cascade,

  enabled boolean not null default false,

  expires_at timestamptz null,

  reason text not null,

  metadata jsonb not null default '{}'::jsonb,

  created_at timestamptz not null default clock_timestamp(),
  updated_at timestamptz not null default clock_timestamp(),

  constraint commercial_reward_test_authorizations_campaign_user_uq
    unique (campaign_id, user_id),

  constraint commercial_reward_test_authorizations_reason_check
    check (btrim(reason) <> ''),

  constraint commercial_reward_test_authorizations_metadata_object_check
    check (jsonb_typeof(metadata) = 'object')
);

comment on table public.commercial_reward_test_authorizations is
  'Private, fail-closed authorization registry for user-scoped reward certification while a reward source remains in test_mode. Not a production audience system.';

create index if not exists commercial_reward_test_authorizations_lookup_idx
  on public.commercial_reward_test_authorizations (
    campaign_id,
    user_id,
    enabled,
    expires_at
  );


-- ============================================================================
-- 2. UPDATED_AT
-- ============================================================================

create or replace function public.touch_commercial_reward_test_authorization()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  new.updated_at := clock_timestamp();
  return new;
end;
$$;

drop trigger if exists commercial_reward_test_authorizations_touch_trg
  on public.commercial_reward_test_authorizations;

create trigger commercial_reward_test_authorizations_touch_trg
before update
on public.commercial_reward_test_authorizations
for each row
execute function public.touch_commercial_reward_test_authorization();


-- ============================================================================
-- 3. INTERNAL AUTHORIZATION ASSERTION
-- ============================================================================

create or replace function public.assert_reward_test_authorization_internal(
  p_campaign_id uuid,
  p_user_id uuid
)
returns void
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_campaign public.reward_campaigns;
  v_source public.reward_sources;
begin
  select *
  into strict v_campaign
  from public.reward_campaigns
  where id = p_campaign_id;

  select *
  into strict v_source
  from public.reward_sources
  where id = v_campaign.source_id;

  -- Production behavior remains unchanged.
  if not v_source.test_mode then
    return;
  end if;

  -- This certification gate applies only to REWARDED_AD.
  if v_source.source_code <> 'REWARDED_AD' then
    return;
  end if;

  if not exists (
    select 1
    from public.commercial_reward_test_authorizations a
    where a.campaign_id = p_campaign_id
      and a.user_id = p_user_id
      and a.enabled = true
      and (
        a.expires_at is null
        or a.expires_at > clock_timestamp()
      )
  ) then
    raise exception using
      errcode = 'P0001',
      message = 'REWARD_TEST_SCOPE_NOT_AUTHORIZED';
  end if;
end;
$$;

comment on function public.assert_reward_test_authorization_internal(uuid,uuid) is
  'Fail-closed certification authorization for REWARDED_AD claims while the source is in test_mode. Production mode bypasses this temporary certification scope.';


-- ============================================================================
-- 4. CLAIM INSERT GUARD
-- ============================================================================

create or replace function public.guard_reward_claim_test_authorization()
returns trigger
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
begin
  if new.source_code = 'REWARDED_AD' then
    perform public.assert_reward_test_authorization_internal(
      new.campaign_id,
      new.user_id
    );
  end if;

  return new;
end;
$$;

drop trigger if exists reward_claims_test_authorization_trg
  on public.reward_claims;

create trigger reward_claims_test_authorization_trg
before insert
on public.reward_claims
for each row
execute function public.guard_reward_claim_test_authorization();


-- ============================================================================
-- 5. SECURITY
-- ============================================================================

alter table public.commercial_reward_test_authorizations
  enable row level security;

revoke all
on public.commercial_reward_test_authorizations
from public, anon, authenticated;

grant select, insert, update, delete
on public.commercial_reward_test_authorizations
to service_role;

revoke all
on function public.touch_commercial_reward_test_authorization()
from public, anon, authenticated;

revoke all
on function public.assert_reward_test_authorization_internal(uuid,uuid)
from public, anon, authenticated;

revoke all
on function public.guard_reward_claim_test_authorization()
from public, anon, authenticated;

grant execute
on function public.assert_reward_test_authorization_internal(uuid,uuid)
to service_role;


-- ============================================================================
-- 6. INITIAL PIRATA CANARY AUTHORIZATION
-- ============================================================================

insert into public.commercial_reward_test_authorizations (
  campaign_id,
  user_id,
  enabled,
  expires_at,
  reason,
  metadata
)
select
  c.id,
  '4bfb4391-15a2-4b21-989e-43299c73c49c'::uuid,
  true,
  clock_timestamp() + interval '24 hours',
  'C-COMM-07C Pirata da Vinci Rewarded Ad controlled canary',
  jsonb_build_object(
    'scope', 'pirata_only',
    'environment', 'test',
    'source_code', 'REWARDED_AD',
    'campaign_code', 'REWARDED_AD_FOUNDATION',
    'certification_phase', 'C-COMM-07'
  )
from public.reward_campaigns c
where c.campaign_code = 'REWARDED_AD_FOUNDATION'
on conflict (campaign_id, user_id)
do update set
  enabled = true,
  expires_at = clock_timestamp() + interval '24 hours',
  reason = excluded.reason,
  metadata = excluded.metadata,
  updated_at = clock_timestamp();


-- ============================================================================
-- 7. MIGRATION SAFETY ASSERTIONS
-- ============================================================================

do $$
declare
  v_source public.reward_sources;
  v_campaign public.reward_campaigns;
  v_auth_count integer;
begin
  select *
  into strict v_source
  from public.reward_sources
  where source_code = 'REWARDED_AD';

  select *
  into strict v_campaign
  from public.reward_campaigns
  where campaign_code = 'REWARDED_AD_FOUNDATION';

  if v_source.test_mode is not true then
    raise exception
      'MIGRATION_239_REWARDED_SOURCE_MUST_REMAIN_TEST_MODE';
  end if;

  if v_source.enabled is not false then
    raise exception
      'MIGRATION_239_MUST_NOT_ENABLE_REWARDED_SOURCE';
  end if;

  if v_campaign.enabled is not false then
    raise exception
      'MIGRATION_239_MUST_NOT_ENABLE_REWARDED_CAMPAIGN';
  end if;

  if v_campaign.public is not false then
    raise exception
      'MIGRATION_239_MUST_NOT_PUBLISH_REWARDED_CAMPAIGN';
  end if;

  select count(*)
  into v_auth_count
  from public.commercial_reward_test_authorizations a
  where a.campaign_id = v_campaign.id
    and a.user_id =
      '4bfb4391-15a2-4b21-989e-43299c73c49c'::uuid
    and a.enabled = true
    and a.expires_at > clock_timestamp();

  if v_auth_count <> 1 then
    raise exception
      'MIGRATION_239_PIRATA_AUTHORIZATION_NOT_READY';
  end if;
end;
$$;

commit;