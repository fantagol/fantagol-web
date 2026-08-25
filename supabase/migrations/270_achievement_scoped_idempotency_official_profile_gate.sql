-- ============================================================================
-- FANTAGOL - 270
-- ACHIEVEMENT SCOPED IDEMPOTENCY + OFFICIAL PROFILE GATE
--
-- PURPOSE
--   Align Achievement certification idempotency with Loyalty reward scope.
--
--   Prediction-result achievements are repeatable across different certified
--   prediction results and deduplicated by immutable certification reference.
--
--   First-round / profile / governance achievements remain independently
--   deduplicated by their own canonical certification reference.
--
--   Profile completion authority is aligned with the canonical official round
--   certification status.
--
-- SAFETY
--   This migration does NOT:
--     - enable Loyalty policies;
--     - enable Reward campaigns;
--     - enable Loyalty producers/bindings;
--     - emit Loyalty events;
--     - award Premium Passes;
--     - backfill historical achievements;
--     - alter 8-member eligibility semantics.
-- ============================================================================

-- ============================================================================
-- 1. REMOVE INCORRECT ACCOUNT-WIDE ACHIEVEMENT UNIQUENESS
-- ============================================================================

drop index if exists public.achievement_certifications_user_code_unique;

-- Canonical immutable certification-reference uniqueness remains authoritative.
create unique index if not exists achievement_certifications_reference_unique
on public.achievement_certifications(certification_reference)
where certification_status = 'certified';


-- ============================================================================
-- 2. CERTIFY ACHIEVEMENT - CERTIFICATION-REFERENCE IDEMPOTENCY
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
as $$
declare
  v_code text := upper(trim(p_achievement_code));
  v_reference text := trim(p_certification_reference);
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

  if nullif(v_reference, '') is null then
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

  /*
   * Canonical idempotency authority:
   *
   * certification_reference encodes the immutable business scope.
   *
   * Examples:
   *   prediction-result-certification:<result>:exact
   *   prediction-result-certification:<result>:grand-slam
   *   prediction-result-certification:<result>:cantonata
   *   round-certification:<league>:first-round:<user>
   *   profile-completion:account:<user>
   *
   * This intentionally replaces account-wide user+achievement deduplication.
   */
  select ac.*
  into v_existing
  from public.achievement_certifications ac
  where ac.certification_reference = v_reference
    and ac.certification_status = 'certified'
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
    v_reference,
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
$$;


-- ============================================================================
-- 3. PROFILE CERTIFIER - OFFICIAL ROUND AUTHORITY
-- ============================================================================
--
-- Preserve the installed function contract and body, changing only the
-- canonical round status authority from legacy "certified" to "official".
-- The body replacement below is applied through catalog extraction so the
-- patch cannot silently diverge from the installed/source implementation.
-- ============================================================================

do $$
declare
  v_definition text;
begin
  select pg_get_functiondef(
    'public.certify_profile_completion_achievement_internal(uuid,uuid,uuid,jsonb)'::regprocedure
  )
  into v_definition;

  if position(
       'and rc.status = ''certified'';'
       in v_definition
     ) = 0 then
    raise exception using
      errcode = 'P0001',
      message =
        'R46_PROFILE_CERTIFIER_LEGACY_GATE_NOT_FOUND';
  end if;

  v_definition :=
    replace(
      v_definition,
      'and rc.status = ''certified'';',
      'and rc.status = ''official'';'
    );

  execute v_definition;
end;
$$;


-- ============================================================================
-- 4. PROFILE WORKFLOW CREATOR - OFFICIAL ROUND AUTHORITY
-- ============================================================================

do $$
declare
  v_definition text;
begin
  select pg_get_functiondef(
    'public.create_profile_state_certification_workflow_internal(uuid,uuid,uuid,jsonb)'::regprocedure
  )
  into v_definition;

  if position(
       'and rc.status = ''certified'';'
       in v_definition
     ) = 0 then
    raise exception using
      errcode = 'P0001',
      message =
        'R46_PROFILE_WORKFLOW_LEGACY_GATE_NOT_FOUND';
  end if;

  v_definition :=
    replace(
      v_definition,
      'and rc.status = ''certified'';',
      'and rc.status = ''official'';'
    );

  execute v_definition;
end;
$$;


-- ============================================================================
-- 5. MIGRATION CONTRACT
-- ============================================================================

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
) is
  'Canonical Achievement certifier. Idempotency is governed by immutable certification_reference, allowing repeatable prediction-result achievements while preserving independent business scopes.';
