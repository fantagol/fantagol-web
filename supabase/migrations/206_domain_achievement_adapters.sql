begin;

-- ============================================================================
-- FANTAGOL
-- MIGRATION 206
-- DOMAIN ACHIEVEMENT ADAPTERS
--
-- Certified domain state
--      ↓
-- Domain Achievement Adapter
--      ↓
-- certify_achievement_internal(...)
--      ↓
-- achievement_certifications
--
-- NO Loyalty dispatch.
-- NO producer activation.
-- NO wallet mutation.
-- NO Pass allocation.
-- ============================================================================


-- ============================================================================
-- 1. LEAGUE GOVERNANCE ACHIEVEMENT
--
-- Condition:
--   active league members >= 8
--
-- Award semantics:
--   every active member with a user_id receives the account-scoped
--   LEAGUE_REACHED_8_ACTIVE_MEMBERS achievement.
--
-- The threshold timestamp is the joined_at of the eighth active member.
-- ============================================================================

create or replace function public.certify_league_governance_achievements_internal(
  p_league_id uuid,
  p_bootstrap boolean default false,
  p_bootstrap_reference text default null,
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
  v_active_count integer;
  v_threshold_reached_at timestamptz;
  v_member record;
  v_result jsonb;

  v_created integer := 0;
  v_duplicates integer := 0;

  v_reference text;
  v_digest text;
begin
  if p_league_id is null then
    raise exception using
      errcode = '22004',
      message = 'ACHIEVEMENT_LEAGUE_ID_REQUIRED';
  end if;

  if not exists (
    select 1
    from public.leagues l
    where l.id = p_league_id
  ) then
    raise exception using
      errcode = 'P0002',
      message = 'ACHIEVEMENT_LEAGUE_NOT_FOUND';
  end if;

  perform pg_advisory_xact_lock(
    hashtextextended(
      'achievement:league-governance:'
      || p_league_id::text,
      0
    )
  );

  select count(*)::integer
  into v_active_count
  from public.league_members lm
  where lm.league_id = p_league_id
    and lm.status = 'active'
    and lm.user_id is not null;

  if v_active_count < 8 then
    return jsonb_build_object(
      'eligible', false,
      'achievement_code',
        'LEAGUE_REACHED_8_ACTIVE_MEMBERS',
      'league_id', p_league_id,
      'active_members', v_active_count,
      'minimum_active_members', 8,
      'created', 0,
      'duplicates', 0
    );
  end if;

  select threshold.joined_at
  into v_threshold_reached_at
  from (
    select
      lm.joined_at,
      row_number() over (
        order by lm.joined_at, lm.id
      ) as position_no
    from public.league_members lm
    where lm.league_id = p_league_id
      and lm.status = 'active'
      and lm.user_id is not null
  ) threshold
  where threshold.position_no = 8;

  v_threshold_reached_at :=
    coalesce(
      v_threshold_reached_at,
      clock_timestamp()
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

    -- IMPORTANT:
    -- certification_reference is globally unique in the Achievement ledger.
    -- It must therefore include the target member.
    v_reference :=
      'league-membership-certification:'
      || p_league_id::text
      || ':8-active-members:member:'
      || v_member.league_member_id::text;

    v_digest :=
      md5(
        concat_ws(
          ':',
          'LEAGUE_REACHED_8_ACTIVE_MEMBERS',
          p_league_id::text,
          v_member.league_member_id::text,
          v_active_count::text,
          v_threshold_reached_at::text
        )
      );

    v_result :=
      public.certify_achievement_internal(
        p_achievement_code =>
          'LEAGUE_REACHED_8_ACTIVE_MEMBERS',

        p_user_id =>
          v_member.user_id,

        p_source_family =>
          'league_governance',

        p_source_reference =>
          'league:' || p_league_id::text,

        p_certification_reference =>
          v_reference,

        p_certification_digest =>
          v_digest,

        p_evidence =>
          jsonb_build_object(
            'certified', true,
            'league_id', p_league_id,
            'league_member_id',
              v_member.league_member_id,
            'active_member_count',
              v_active_count,
            'minimum_active_members',
              8,
            'threshold_reached_at',
              v_threshold_reached_at,
            'member_joined_at',
              v_member.joined_at,
            'bootstrap',
              coalesce(p_bootstrap, false),
            'bootstrap_reference',
              p_bootstrap_reference
          ),

        p_occurred_at =>
          v_threshold_reached_at,

        p_league_id =>
          p_league_id,

        p_league_member_id =>
          v_member.league_member_id,

        p_bootstrap =>
          coalesce(p_bootstrap, false),

        p_correlation_id =>
          p_correlation_id,

        p_causation_id =>
          p_causation_id,

        p_metadata =>
          coalesce(p_metadata, '{}'::jsonb)
          || jsonb_build_object(
            'adapter',
              'certify_league_governance_achievements_internal',
            'adapter_version',
              '1.0.0',
            'bootstrap_reference',
              p_bootstrap_reference
          )
      );

    if coalesce(
      (v_result ->> 'duplicate')::boolean,
      false
    ) then
      v_duplicates := v_duplicates + 1;
    else
      v_created := v_created + 1;
    end if;

  end loop;

  return jsonb_build_object(
    'eligible', true,
    'achievement_code',
      'LEAGUE_REACHED_8_ACTIVE_MEMBERS',
    'league_id', p_league_id,
    'active_members', v_active_count,
    'minimum_active_members', 8,
    'threshold_reached_at',
      v_threshold_reached_at,
    'created', v_created,
    'duplicates', v_duplicates,
    'bootstrap', coalesce(p_bootstrap, false)
  );
end;
$function$;


comment on function public.certify_league_governance_achievements_internal(
  uuid,boolean,text,uuid,uuid,jsonb
)
is
  'Achievement adapter certifying LEAGUE_REACHED_8_ACTIVE_MEMBERS for every eligible active league member. Writes Achievement ledger only.';


-- ============================================================================
-- 2. REPAIR MIGRATION 201 ONE-SHOT BOOTSTRAP
--
-- The original bootstrap used one certification_reference for every member.
-- Since certification_reference is globally unique, that contract would fail
-- after the first member.
--
-- Bootstrap now delegates to the canonical Governance adapter.
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
begin
  if nullif(
    btrim(p_bootstrap_reference),
    ''
  ) is null then
    raise exception using
      errcode = '22023',
      message = 'ACHIEVEMENT_BOOTSTRAP_REFERENCE_REQUIRED';
  end if;

  return
    public.certify_league_governance_achievements_internal(
      p_league_id =>
        p_league_id,

      p_bootstrap =>
        true,

      p_bootstrap_reference =>
        btrim(p_bootstrap_reference),

      p_correlation_id =>
        gen_random_uuid(),

      p_causation_id =>
        null,

      p_metadata =>
        jsonb_build_object(
          'bootstrap_kind',
            'historical_pre_achievement_engine',
          'one_shot',
            true
        )
    );
end;
$function$;


comment on function public.bootstrap_league_8_members_achievement_internal(
  uuid,text
)
is
  'One-shot historical reconciliation delegating to the canonical League Governance Achievement adapter. Does not invoke Loyalty or Commercial rewards.';


-- ============================================================================
-- 3. PROFILE COMPLETION ACHIEVEMENT
--
-- FINAL FUNCTIONAL CONTRACT:
--
-- Required:
--   * Club/display identity present
--   * avatar selected
--   * kit configuration present
--   * >= 1 certified league round
--
-- Explicitly NOT required:
--   * real_name
--   * motto
--   * crest_url
--
-- Achievement is account-scoped and therefore can certify once per account,
-- even if several league careers later satisfy the same condition.
-- ============================================================================

create or replace function public.certify_profile_completion_achievement_internal(
  p_league_member_id uuid,
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
  v_member public.league_members%rowtype;
  v_profile public.league_member_profiles%rowtype;

  v_certified_round_count integer := 0;
  v_first_certified_round_id uuid;
  v_first_round_certified_at timestamptz;

  v_profile_complete boolean := false;
  v_eligible boolean := false;

  v_occurred_at timestamptz;
  v_reference text;
  v_digest text;

  v_result jsonb;
begin
  select lm.*
  into v_member
  from public.league_members lm
  where lm.id = p_league_member_id;

  if not found then
    raise exception using
      errcode = 'P0002',
      message = 'ACHIEVEMENT_LEAGUE_MEMBER_NOT_FOUND';
  end if;

  if v_member.user_id is null then
    return jsonb_build_object(
      'eligible', false,
      'reason', 'MEMBER_WITHOUT_USER',
      'league_member_id',
        p_league_member_id
    );
  end if;

  if v_member.status <> 'active' then
    return jsonb_build_object(
      'eligible', false,
      'reason', 'MEMBER_NOT_ACTIVE',
      'league_member_id',
        p_league_member_id
    );
  end if;

  select p.*
  into v_profile
  from public.league_member_profiles p
  where p.league_member_id =
        p_league_member_id;

  if not found then
    return jsonb_build_object(
      'eligible', false,
      'reason', 'PROFILE_NOT_FOUND',
      'league_member_id',
        p_league_member_id
    );
  end if;

  -- No real_name, motto or crest requirement.
  v_profile_complete :=
       nullif(btrim(v_profile.display_name), '') is not null
   and nullif(btrim(v_profile.club_name), '') is not null
   and nullif(btrim(v_profile.avatar_url), '') is not null
   and nullif(btrim(v_profile.kit_template), '') is not null
   and nullif(btrim(v_profile.kit_primary_color), '') is not null
   and nullif(btrim(v_profile.kit_secondary_color), '') is not null
   and nullif(btrim(v_profile.kit_third_color), '') is not null;

  select
    count(*)::integer,
    (
      array_agg(
        rc.league_round_id
        order by
          coalesce(
            rc.committed_at,
            rc.created_at
          ),
          rc.id
      )
    )[1],
    min(
      coalesce(
        rc.committed_at,
        rc.created_at
      )
    )
  into
    v_certified_round_count,
    v_first_certified_round_id,
    v_first_round_certified_at
  from public.round_certifications rc
  join public.league_rounds lr
    on lr.id = rc.league_round_id
  where lr.league_id = v_member.league_id
    and rc.active = true
    and rc.status = 'certified';

  v_certified_round_count :=
    coalesce(v_certified_round_count, 0);

  v_eligible :=
    v_profile_complete
    and v_certified_round_count >= 1;

  if not v_eligible then
    return jsonb_build_object(
      'eligible', false,
      'achievement_code',
        'PROFILE_COMPLETED_AFTER_FIRST_LEAGUE_ROUND',
      'league_member_id',
        p_league_member_id,
      'league_id',
        v_member.league_id,
      'profile_complete',
        v_profile_complete,
      'certified_round_count',
        v_certified_round_count,
      'requirements',
        jsonb_build_object(
          'club_identity', true,
          'avatar', true,
          'kit', true,
          'real_name_required', false,
          'motto_required', false,
          'crest_required', false,
          'minimum_certified_rounds', 1
        )
    );
  end if;

  v_occurred_at :=
    greatest(
      v_profile.updated_at,
      v_first_round_certified_at
    );

  v_occurred_at :=
    coalesce(
      v_occurred_at,
      clock_timestamp()
    );

  v_reference :=
    'profile-completion:account:'
    || v_member.user_id::text;

  v_digest :=
    md5(
      concat_ws(
        ':',
        'PROFILE_COMPLETED_AFTER_FIRST_LEAGUE_ROUND',
        v_member.user_id::text,
        v_member.league_id::text,
        p_league_member_id::text,
        v_profile.id::text,
        v_profile.profile_version::text,
        v_first_certified_round_id::text
      )
    );

  v_result :=
    public.certify_achievement_internal(
      p_achievement_code =>
        'PROFILE_COMPLETED_AFTER_FIRST_LEAGUE_ROUND',

      p_user_id =>
        v_member.user_id,

      p_source_family =>
        'profile',

      p_source_reference =>
        'league-member-profile:'
        || v_profile.id::text,

      p_certification_reference =>
        v_reference,

      p_certification_digest =>
        v_digest,

      p_evidence =>
        jsonb_build_object(
          'certified', true,
          'league_id',
            v_member.league_id,
          'league_member_id',
            p_league_member_id,
          'league_member_profile_id',
            v_profile.id,
          'profile_version',
            v_profile.profile_version,
          'display_name_present',
            true,
          'club_name_present',
            true,
          'avatar_present',
            true,
          'kit_present',
            true,
          'real_name_required',
            false,
          'motto_required',
            false,
          'crest_required',
            false,
          'certified_round_count',
            v_certified_round_count,
          'first_certified_round_id',
            v_first_certified_round_id,
          'first_round_certified_at',
            v_first_round_certified_at
        ),

      p_occurred_at =>
        v_occurred_at,

      p_league_id =>
        v_member.league_id,

      p_league_round_id =>
        v_first_certified_round_id,

      p_league_member_id =>
        p_league_member_id,

      p_bootstrap =>
        false,

      p_correlation_id =>
        p_correlation_id,

      p_causation_id =>
        p_causation_id,

      p_metadata =>
        coalesce(p_metadata, '{}'::jsonb)
        || jsonb_build_object(
          'adapter',
            'certify_profile_completion_achievement_internal',
          'adapter_version',
            '1.0.0'
        )
    );

  return jsonb_build_object(
    'eligible', true,
    'achievement_code',
      'PROFILE_COMPLETED_AFTER_FIRST_LEAGUE_ROUND',
    'league_id',
      v_member.league_id,
    'league_member_id',
      p_league_member_id,
    'profile_id',
      v_profile.id,
    'certified_round_count',
      v_certified_round_count,
    'achievement',
      v_result
  );
end;
$function$;


comment on function public.certify_profile_completion_achievement_internal(
  uuid,uuid,uuid,jsonb
)
is
  'Certifies account-scoped profile completion after the first certified league round. Requires Club identity, avatar and kit only; real name, motto and crest are explicitly excluded.';


-- ============================================================================
-- 4. COMPETITION SEASON COMPLETION ACHIEVEMENT
--
-- Conservative certification:
--
--   * league must have a season_id;
--   * linked season must contain >= 1 active match;
--   * every active match for that season must have finalised_at;
--
-- Every active league member with a user receives the account-scoped
-- LEAGUE_SEASON_CERTIFIED_COMPLETE achievement.
--
-- No certification occurs if season linkage is missing.
-- ============================================================================

create or replace function public.certify_competition_season_achievements_internal(
  p_league_id uuid,
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
  v_league public.leagues%rowtype;

  v_total_matches integer := 0;
  v_finalised_matches integer := 0;
  v_remaining_matches integer := 0;

  v_completed_at timestamptz;

  v_member record;
  v_result jsonb;

  v_created integer := 0;
  v_duplicates integer := 0;

  v_reference text;
  v_digest text;
begin
  select l.*
  into v_league
  from public.leagues l
  where l.id = p_league_id;

  if not found then
    raise exception using
      errcode = 'P0002',
      message = 'ACHIEVEMENT_LEAGUE_NOT_FOUND';
  end if;

  if v_league.season_id is null then
    return jsonb_build_object(
      'eligible', false,
      'achievement_code',
        'LEAGUE_SEASON_CERTIFIED_COMPLETE',
      'league_id',
        p_league_id,
      'reason',
        'LEAGUE_SEASON_NOT_LINKED'
    );
  end if;

  if not exists (
    select 1
    from public.seasons s
    where s.id = v_league.season_id
  ) then
    return jsonb_build_object(
      'eligible', false,
      'achievement_code',
        'LEAGUE_SEASON_CERTIFIED_COMPLETE',
      'league_id',
        p_league_id,
      'season_id',
        v_league.season_id,
      'reason',
        'SEASON_NOT_FOUND'
    );
  end if;

  select
    count(*)::integer,
    count(*) filter (
      where m.finalised_at is not null
    )::integer,
    count(*) filter (
      where m.finalised_at is null
    )::integer,
    max(m.finalised_at)
  into
    v_total_matches,
    v_finalised_matches,
    v_remaining_matches,
    v_completed_at
  from public.matches m
  where m.season_id = v_league.season_id
    and m.active = true;

  v_total_matches :=
    coalesce(v_total_matches, 0);

  v_finalised_matches :=
    coalesce(v_finalised_matches, 0);

  v_remaining_matches :=
    coalesce(v_remaining_matches, 0);

  if v_total_matches = 0
     or v_remaining_matches > 0 then

    return jsonb_build_object(
      'eligible', false,
      'achievement_code',
        'LEAGUE_SEASON_CERTIFIED_COMPLETE',
      'league_id',
        p_league_id,
      'season_id',
        v_league.season_id,
      'total_matches',
        v_total_matches,
      'finalised_matches',
        v_finalised_matches,
      'remaining_matches',
        v_remaining_matches
    );
  end if;

  v_completed_at :=
    coalesce(
      v_completed_at,
      clock_timestamp()
    );

  perform pg_advisory_xact_lock(
    hashtextextended(
      'achievement:competition-season:'
      || p_league_id::text
      || ':'
      || v_league.season_id::text,
      0
    )
  );

  for v_member in
    select
      lm.id as league_member_id,
      lm.user_id
    from public.league_members lm
    where lm.league_id = p_league_id
      and lm.status = 'active'
      and lm.user_id is not null
    order by lm.joined_at, lm.id
  loop

    v_reference :=
      'league-season-certification:'
      || p_league_id::text
      || ':'
      || v_league.season_id::text
      || ':member:'
      || v_member.league_member_id::text;

    v_digest :=
      md5(
        concat_ws(
          ':',
          'LEAGUE_SEASON_CERTIFIED_COMPLETE',
          p_league_id::text,
          v_league.season_id::text,
          v_member.league_member_id::text,
          v_total_matches::text,
          v_finalised_matches::text,
          v_completed_at::text
        )
      );

    v_result :=
      public.certify_achievement_internal(
        p_achievement_code =>
          'LEAGUE_SEASON_CERTIFIED_COMPLETE',

        p_user_id =>
          v_member.user_id,

        p_source_family =>
          'competition',

        p_source_reference =>
          'season:'
          || v_league.season_id::text,

        p_certification_reference =>
          v_reference,

        p_certification_digest =>
          v_digest,

        p_evidence =>
          jsonb_build_object(
            'certified', true,
            'league_id',
              p_league_id,
            'league_member_id',
              v_member.league_member_id,
            'season_id',
              v_league.season_id,
            'total_matches',
              v_total_matches,
            'finalised_matches',
              v_finalised_matches,
            'remaining_matches',
              0,
            'season_completed_at',
              v_completed_at
          ),

        p_occurred_at =>
          v_completed_at,

        p_league_id =>
          p_league_id,

        p_league_member_id =>
          v_member.league_member_id,

        p_season_id =>
          v_league.season_id,

        p_bootstrap =>
          false,

        p_correlation_id =>
          p_correlation_id,

        p_causation_id =>
          p_causation_id,

        p_metadata =>
          coalesce(p_metadata, '{}'::jsonb)
          || jsonb_build_object(
            'adapter',
              'certify_competition_season_achievements_internal',
            'adapter_version',
              '1.0.0'
          )
      );

    if coalesce(
      (v_result ->> 'duplicate')::boolean,
      false
    ) then
      v_duplicates := v_duplicates + 1;
    else
      v_created := v_created + 1;
    end if;

  end loop;

  return jsonb_build_object(
    'eligible', true,
    'achievement_code',
      'LEAGUE_SEASON_CERTIFIED_COMPLETE',
    'league_id',
      p_league_id,
    'season_id',
      v_league.season_id,
    'total_matches',
      v_total_matches,
    'finalised_matches',
      v_finalised_matches,
    'season_completed_at',
      v_completed_at,
    'created',
      v_created,
    'duplicates',
      v_duplicates
  );
end;
$function$;


comment on function public.certify_competition_season_achievements_internal(
  uuid,uuid,uuid,jsonb
)
is
  'Conservatively certifies League Season Complete only when the linked season exists and every active season match is finalised. Writes Achievement ledger only.';


-- ============================================================================
-- 5. PRIVILEGE BOUNDARY
-- ============================================================================

revoke all
on function public.certify_league_governance_achievements_internal(
  uuid,boolean,text,uuid,uuid,jsonb
)
from public, anon, authenticated;

grant execute
on function public.certify_league_governance_achievements_internal(
  uuid,boolean,text,uuid,uuid,jsonb
)
to service_role;


revoke all
on function public.certify_profile_completion_achievement_internal(
  uuid,uuid,uuid,jsonb
)
from public, anon, authenticated;

grant execute
on function public.certify_profile_completion_achievement_internal(
  uuid,uuid,uuid,jsonb
)
to service_role;


revoke all
on function public.certify_competition_season_achievements_internal(
  uuid,uuid,uuid,jsonb
)
from public, anon, authenticated;

grant execute
on function public.certify_competition_season_achievements_internal(
  uuid,uuid,uuid,jsonb
)
to service_role;


revoke all
on function public.bootstrap_league_8_members_achievement_internal(
  uuid,text
)
from public, anon, authenticated;

grant execute
on function public.bootstrap_league_8_members_achievement_internal(
  uuid,text
)
to service_role;


-- ============================================================================
-- 6. ASSERTIONS
-- ============================================================================

do $assertions$
declare
  v_bootstrap_definition text;
  v_profile_definition text;
begin

  if to_regprocedure(
    'public.certify_league_governance_achievements_internal(uuid,boolean,text,uuid,uuid,jsonb)'
  ) is null then
    raise exception
      'MIGRATION_206_GOVERNANCE_ADAPTER_MISSING';
  end if;


  if to_regprocedure(
    'public.certify_profile_completion_achievement_internal(uuid,uuid,uuid,jsonb)'
  ) is null then
    raise exception
      'MIGRATION_206_PROFILE_ADAPTER_MISSING';
  end if;


  if to_regprocedure(
    'public.certify_competition_season_achievements_internal(uuid,uuid,uuid,jsonb)'
  ) is null then
    raise exception
      'MIGRATION_206_SEASON_ADAPTER_MISSING';
  end if;


  select pg_get_functiondef(
    'public.bootstrap_league_8_members_achievement_internal(uuid,text)'
      ::regprocedure
  )
  into v_bootstrap_definition;

  if position(
      'certify_league_governance_achievements_internal'
      in v_bootstrap_definition
    ) = 0 then

    raise exception
      'MIGRATION_206_BOOTSTRAP_DELEGATION_MISSING';
  end if;


  select pg_get_functiondef(
    'public.certify_profile_completion_achievement_internal(uuid,uuid,uuid,jsonb)'
      ::regprocedure
  )
  into v_profile_definition;

  if position(
      'real_name'
      in v_profile_definition
    ) > 0
    and position(
      'real_name_required'
      in v_profile_definition
    ) = 0 then

    raise exception
      'MIGRATION_206_PROFILE_REAL_NAME_CONTRACT_INVALID';
  end if;


  if position(
      'motto_required'
      in v_profile_definition
    ) = 0
    or position(
      'crest_required'
      in v_profile_definition
    ) = 0 then

    raise exception
      'MIGRATION_206_PROFILE_OPTIONAL_FIELDS_CONTRACT_MISSING';
  end if;

end;
$assertions$;

commit;