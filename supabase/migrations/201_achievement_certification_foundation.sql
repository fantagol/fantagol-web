begin;

-- ============================================================================
-- FANTAGOL
-- MIGRATION 201
-- ACHIEVEMENT CERTIFICATION FOUNDATION
--
-- Rules:
--   * Game domain certifies facts only.
--   * Achievement Engine persists certified achievements.
--   * No commercial wallet / ledger mutation occurs here.
--   * No loyalty producer is called here.
--   * Workflow -> Loyalty dispatch remains Migration 107 responsibility.
-- ============================================================================

-- ============================================================================
-- 1. ACHIEVEMENT CERTIFICATIONS
-- ============================================================================

create table if not exists public.achievement_certifications (
  id uuid primary key default gen_random_uuid(),

  achievement_code text not null,

  user_id uuid not null
    references auth.users(id)
    on delete restrict,

  league_id uuid null
    references public.leagues(id)
    on delete restrict,

  league_round_id uuid null
    references public.league_rounds(id)
    on delete restrict,

  league_member_id uuid null
    references public.league_members(id)
    on delete restrict,

  season_id uuid null,

  prediction_result_id uuid null,

  source_family text not null,

  source_reference text not null,
  certification_reference text not null,
  certification_digest text not null,

  evidence_version integer not null default 1,
  evidence jsonb not null,

  certification_status text not null default 'certified',

  bootstrap boolean not null default false,

  occurred_at timestamptz not null,
  certified_at timestamptz not null default clock_timestamp(),

  correlation_id uuid not null default gen_random_uuid(),
  causation_id uuid null,

  metadata jsonb not null default '{}'::jsonb,

  created_at timestamptz not null default clock_timestamp(),

  constraint achievement_certifications_code_check
    check (
      achievement_code ~ '^[A-Z][A-Z0-9_]{2,149}$'
    ),

  constraint achievement_certifications_source_family_check
    check (
      source_family in (
        'league_governance',
        'round',
        'competition',
        'profile',
        'prediction_result',
        'participation'
      )
    ),

  constraint achievement_certifications_reference_check
    check (
      length(trim(source_reference)) between 8 and 500
    ),

  constraint achievement_certifications_cert_reference_check
    check (
      length(trim(certification_reference)) between 8 and 500
    ),

  constraint achievement_certifications_digest_check
    check (
      length(trim(certification_digest)) between 8 and 500
    ),

  constraint achievement_certifications_evidence_version_check
    check (
      evidence_version between 1 and 1000
    ),

  constraint achievement_certifications_evidence_check
    check (
      jsonb_typeof(evidence) = 'object'
      and evidence <> '{}'::jsonb
    ),

  constraint achievement_certifications_status_check
    check (
      certification_status in (
        'certified',
        'superseded',
        'revoked'
      )
    ),

  constraint achievement_certifications_metadata_check
    check (
      jsonb_typeof(metadata) = 'object'
    )
);

comment on table public.achievement_certifications is
  'Canonical certified Achievement Engine ledger. Records certified game achievements without assigning commercial rewards.';

-- ============================================================================
-- 2. ACCOUNT-SCOPE IDEMPOTENCY
--
-- Current reward policies are account scoped.
-- Therefore each achievement_code may certify once per user.
--
-- Context is retained for evidence, but does not create repeat awards.
-- ============================================================================

create unique index if not exists
achievement_certifications_user_code_unique
on public.achievement_certifications (
  user_id,
  achievement_code
)
where certification_status = 'certified';

create unique index if not exists
achievement_certifications_reference_unique
on public.achievement_certifications (
  certification_reference
)
where certification_status = 'certified';

create index if not exists
achievement_certifications_user_idx
on public.achievement_certifications (
  user_id,
  certified_at desc
);

create index if not exists
achievement_certifications_league_idx
on public.achievement_certifications (
  league_id,
  certified_at desc
)
where league_id is not null;

create index if not exists
achievement_certifications_code_idx
on public.achievement_certifications (
  achievement_code,
  certified_at desc
);

-- ============================================================================
-- 3. CANONICAL CERTIFIER
-- ============================================================================

create or replace function public.certify_achievement_internal(
  p_achievement_code text,
  p_user_id uuid,
  p_source_family text,
  p_source_reference text,
  p_certification_reference text,
  p_certification_digest text,
  p_evidence jsonb,
  p_occurred_at timestamptz,
  p_league_id uuid default null,
  p_league_round_id uuid default null,
  p_league_member_id uuid default null,
  p_season_id uuid default null,
  p_prediction_result_id uuid default null,
  p_bootstrap boolean default false,
  p_correlation_id uuid default null,
  p_causation_id uuid default null,
  p_metadata jsonb default '{}'::jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $function$
declare
  v_code text := upper(trim(p_achievement_code));
  v_existing public.achievement_certifications;
  v_created public.achievement_certifications;
begin
  if p_user_id is null then
    raise exception using
      errcode = 'P0001',
      message = 'ACHIEVEMENT_USER_REQUIRED';
  end if;

  if v_code is null or v_code = '' then
    raise exception using
      errcode = 'P0001',
      message = 'ACHIEVEMENT_CODE_REQUIRED';
  end if;

  if nullif(trim(p_source_reference), '') is null then
    raise exception using
      errcode = 'P0001',
      message = 'ACHIEVEMENT_SOURCE_REFERENCE_REQUIRED';
  end if;

  if nullif(trim(p_certification_reference), '') is null then
    raise exception using
      errcode = 'P0001',
      message = 'ACHIEVEMENT_CERTIFICATION_REFERENCE_REQUIRED';
  end if;

  if nullif(trim(p_certification_digest), '') is null then
    raise exception using
      errcode = 'P0001',
      message = 'ACHIEVEMENT_CERTIFICATION_DIGEST_REQUIRED';
  end if;

  if p_evidence is null
     or jsonb_typeof(p_evidence) <> 'object'
     or p_evidence = '{}'::jsonb then
    raise exception using
      errcode = 'P0001',
      message = 'ACHIEVEMENT_EVIDENCE_REQUIRED';
  end if;

  if p_occurred_at is null then
    raise exception using
      errcode = 'P0001',
      message = 'ACHIEVEMENT_OCCURRED_AT_REQUIRED';
  end if;

  -- Account-scope idempotency.
  select *
  into v_existing
  from public.achievement_certifications
  where user_id = p_user_id
    and achievement_code = v_code
    and certification_status = 'certified'
  limit 1;

  if v_existing.id is not null then
    return jsonb_build_object(
      'certified', true,
      'duplicate', true,
      'achievement_certification_id', v_existing.id,
      'achievement_code', v_existing.achievement_code,
      'user_id', v_existing.user_id,
      'bootstrap', v_existing.bootstrap
    );
  end if;

  insert into public.achievement_certifications (
    achievement_code,
    user_id,
    league_id,
    league_round_id,
    league_member_id,
    season_id,
    prediction_result_id,
    source_family,
    source_reference,
    certification_reference,
    certification_digest,
    evidence_version,
    evidence,
    certification_status,
    bootstrap,
    occurred_at,
    correlation_id,
    causation_id,
    metadata
  )
  values (
    v_code,
    p_user_id,
    p_league_id,
    p_league_round_id,
    p_league_member_id,
    p_season_id,
    p_prediction_result_id,
    trim(p_source_family),
    trim(p_source_reference),
    trim(p_certification_reference),
    trim(p_certification_digest),
    1,
    p_evidence,
    'certified',
    coalesce(p_bootstrap, false),
    p_occurred_at,
    coalesce(p_correlation_id, gen_random_uuid()),
    p_causation_id,
    coalesce(p_metadata, '{}'::jsonb)
  )
  returning *
  into v_created;

  return jsonb_build_object(
    'certified', true,
    'duplicate', false,
    'achievement_certification_id', v_created.id,
    'achievement_code', v_created.achievement_code,
    'user_id', v_created.user_id,
    'bootstrap', v_created.bootstrap
  );
end;
$function$;

comment on function public.certify_achievement_internal(
  text,
  uuid,
  text,
  text,
  text,
  text,
  jsonb,
  timestamptz,
  uuid,
  uuid,
  uuid,
  uuid,
  uuid,
  boolean,
  uuid,
  uuid,
  jsonb
)
is
  'Canonical backend Achievement Engine certifier. Persists idempotent account-scoped certified achievements without invoking commercial reward logic.';

-- ============================================================================
-- 4. ONE-SHOT HISTORICAL LEAGUE >= 8 BOOTSTRAP
--
-- Generic function, service_role only.
-- This does not run automatically.
-- It certifies every currently active member when the league already has >= 8.
-- ============================================================================

create or replace function public.bootstrap_league_8_members_achievement_internal(
  p_league_id uuid,
  p_bootstrap_reference text
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $function$
declare
  v_active_count integer;
  v_member record;
  v_result jsonb;
  v_created integer := 0;
  v_duplicate integer := 0;
  v_digest text;
begin
  if p_league_id is null then
    raise exception using
      errcode = 'P0001',
      message = 'ACHIEVEMENT_BOOTSTRAP_LEAGUE_REQUIRED';
  end if;

  if nullif(trim(p_bootstrap_reference), '') is null then
    raise exception using
      errcode = 'P0001',
      message = 'ACHIEVEMENT_BOOTSTRAP_REFERENCE_REQUIRED';
  end if;

  perform pg_advisory_xact_lock(
    hashtextextended(
      'achievement:league8:' || p_league_id::text,
      0
    )
  );

  select count(*)::integer
  into v_active_count
  from public.league_members
  where league_id = p_league_id
    and status = 'active';

  if v_active_count < 8 then
    return jsonb_build_object(
      'eligible', false,
      'league_id', p_league_id,
      'active_members', v_active_count,
      'created', 0,
      'duplicates', 0
    );
  end if;

  v_digest := md5(
    concat(
      'LEAGUE_REACHED_8_ACTIVE_MEMBERS:',
      p_league_id::text,
      ':',
      v_active_count::text,
      ':',
      trim(p_bootstrap_reference)
    )
  );

  for v_member in
    select
      lm.id as league_member_id,
      lm.user_id,
      lm.joined_at
    from public.league_members lm
    where lm.league_id = p_league_id
      and lm.status = 'active'
      and lm.user_id is not null
    order by lm.joined_at, lm.id
  loop

    v_result :=
      public.certify_achievement_internal(
        'LEAGUE_REACHED_8_ACTIVE_MEMBERS',
        v_member.user_id,
        'league_governance',
        'league:' || p_league_id::text,
        'league-membership-certification:'
          || p_league_id::text
          || ':8-active-members',
        v_digest,
        jsonb_build_object(
          'league_id', p_league_id,
          'active_member_count', v_active_count,
          'minimum_active_members', 8,
          'league_member_id', v_member.league_member_id,
          'bootstrap_reference', trim(p_bootstrap_reference)
        ),
        clock_timestamp(),
        p_league_id,
        null,
        v_member.league_member_id,
        null,
        null,
        true,
        gen_random_uuid(),
        null,
        jsonb_build_object(
          'bootstrap_kind', 'historical_pre_achievement_engine',
          'one_shot', true
        )
      );

    if coalesce((v_result ->> 'duplicate')::boolean, false) then
      v_duplicate := v_duplicate + 1;
    else
      v_created := v_created + 1;
    end if;

  end loop;

  return jsonb_build_object(
    'eligible', true,
    'league_id', p_league_id,
    'active_members', v_active_count,
    'created', v_created,
    'duplicates', v_duplicate
  );
end;
$function$;

comment on function public.bootstrap_league_8_members_achievement_internal(
  uuid,
  text
)
is
  'Service-role one-shot reconciliation for leagues that already satisfied the 8-active-member achievement before Achievement Engine activation. Does not dispatch commercial rewards.';

-- ============================================================================
-- 5. PRIVILEGE BOUNDARY
-- ============================================================================

alter table public.achievement_certifications
  enable row level security;

revoke all
on table public.achievement_certifications
from public, anon, authenticated;

grant all
on table public.achievement_certifications
to service_role;

revoke all
on function public.certify_achievement_internal(
  text,
  uuid,
  text,
  text,
  text,
  text,
  jsonb,
  timestamptz,
  uuid,
  uuid,
  uuid,
  uuid,
  uuid,
  boolean,
  uuid,
  uuid,
  jsonb
)
from public, anon, authenticated;

grant execute
on function public.certify_achievement_internal(
  text,
  uuid,
  text,
  text,
  text,
  text,
  jsonb,
  timestamptz,
  uuid,
  uuid,
  uuid,
  uuid,
  uuid,
  boolean,
  uuid,
  uuid,
  jsonb
)
to service_role;

revoke all
on function public.bootstrap_league_8_members_achievement_internal(
  uuid,
  text
)
from public, anon, authenticated;

grant execute
on function public.bootstrap_league_8_members_achievement_internal(
  uuid,
  text
)
to service_role;

-- ============================================================================
-- 6. INSTALLATION ASSERTIONS
-- ============================================================================

do $assertions$
begin
  if to_regclass(
    'public.achievement_certifications'
  ) is null then
    raise exception
      'ACHIEVEMENT_CERTIFICATIONS_TABLE_MISSING';
  end if;

  if to_regprocedure(
    'public.certify_achievement_internal(text,uuid,text,text,text,text,jsonb,timestamp with time zone,uuid,uuid,uuid,uuid,uuid,boolean,uuid,uuid,jsonb)'
  ) is null then
    raise exception
      'ACHIEVEMENT_CERTIFIER_MISSING';
  end if;

  if to_regprocedure(
    'public.bootstrap_league_8_members_achievement_internal(uuid,text)'
  ) is null then
    raise exception
      'ACHIEVEMENT_BOOTSTRAP_MISSING';
  end if;
end;
$assertions$;

commit;