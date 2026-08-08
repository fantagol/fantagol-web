begin;

-- ============================================================================
-- FANTAGOL
-- MIGRATION 208
-- ACHIEVEMENT WORKFLOW STATE-BASED IDEMPOTENCY
--
-- PRINCIPLE
--
-- Workflow idempotency:
--   identifies one evaluation of one certified domain state.
--
-- Achievement idempotency:
--   remains account-scoped and one-shot in achievement_certifications.
--
-- Therefore a workflow may legitimately run again when relevant source state
-- changes, while certify_achievement_internal() prevents duplicate awards.
--
-- Participation is intentionally NOT changed here.
-- It remains disabled until its canonical Achievement adapter is installed.
--
-- NO workflow is executed by this migration.
-- NO Achievement is created.
-- NO Loyalty / Commercial mutation occurs.
-- ============================================================================


-- ============================================================================
-- 1. LEAGUE GOVERNANCE WORKFLOW
--
-- Relevant state:
--   exact set of active members with user identity.
--
-- Examples:
--   7 -> 8 members     => new state / new workflow
--   18 -> 19 members   => new state / new workflow
--   member removed     => new state / new workflow
--
-- Achievement ledger remains one-shot per account.
-- ============================================================================

create or replace function public.create_league_governance_certification_workflow_internal(
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
  v_workflow record;

  v_active_member_count integer := 0;
  v_state_fingerprint text;

  v_bootstrap boolean := false;
  v_bootstrap_reference text;
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

  select
    count(*)::integer,

    md5(
      coalesce(
        string_agg(
          lm.id::text
          || ':'
          || lm.user_id::text
          || ':'
          || lm.joined_at::text,
          '|'
          order by lm.joined_at, lm.id
        ),
        'no-active-members'
      )
    )

  into
    v_active_member_count,
    v_state_fingerprint

  from public.league_members lm

  where lm.league_id = p_league_id
    and lm.status = 'active'
    and lm.user_id is not null;


  v_bootstrap :=
    case lower(
      coalesce(
        p_metadata ->> 'bootstrap',
        'false'
      )
    )
      when 'true' then true
      when '1' then true
      else false
    end;


  v_bootstrap_reference :=
    nullif(
      btrim(
        p_metadata ->> 'bootstrap_reference'
      ),
      ''
    );


  select *
  into v_workflow
  from public.create_live_runtime_workflow_rpc(

    p_workflow_type =>
      'league_governance_certification',

    p_scope_type =>
      'league',

    p_scope_id =>
      p_league_id,

    p_idempotency_key =>
      'league-governance-certification:'
      || p_league_id::text
      || ':state:'
      || v_state_fingerprint
      || ':v1',

    p_steps =>
      jsonb_build_array(
        jsonb_build_object(

          'step_key',
            'certify_active_membership_threshold',

          'step_order',
            10,

          'job_type',
            'certify_achievement_state',

          'scope_type',
            'league',

          'scope_id',
            p_league_id,

          'priority',
            100,

          'max_attempts',
            5,

          'payload',
            jsonb_build_object(
              'achievement_family',
                'league_governance',

              'certification_kind',
                'active_membership_threshold',

              'minimum_active_members',
                8,

              'active_member_count',
                v_active_member_count,

              'state_fingerprint',
                v_state_fingerprint,

              'bootstrap',
                v_bootstrap,

              'bootstrap_reference',
                v_bootstrap_reference
            )
        )
      ),

    p_workflow_version =>
      1,

    p_metadata =>
      coalesce(
        p_metadata,
        '{}'::jsonb
      )
      || jsonb_build_object(
        'achievement_engine',
          true,

        'achievement_family',
          'league_governance',

        'state_fingerprint',
          v_state_fingerprint,

        'active_member_count',
          v_active_member_count,

        'state_based_idempotency',
          true,

        'runtime_contract_version',
          '1.1.0'
      ),

    p_correlation_id =>
      p_correlation_id,

    p_causation_id =>
      p_causation_id
  );


  return jsonb_build_object(

    'workflow_id',
      v_workflow.workflow_id,

    'workflow_status',
      v_workflow.workflow_status,

    'inserted',
      v_workflow.inserted,

    'step_count',
      v_workflow.step_count,

    'correlation_id',
      v_workflow.correlation_id,

    'state_fingerprint',
      v_state_fingerprint,

    'active_member_count',
      v_active_member_count,

    'bootstrap',
      v_bootstrap,

    'bootstrap_reference',
      v_bootstrap_reference
  );

end;
$function$;


comment on function public.create_league_governance_certification_workflow_internal(
  uuid,uuid,uuid,jsonb
)
is
  'Creates a state-idempotent League Governance Achievement workflow. A changed active-member set creates a new evaluation workflow while Achievement ledger idempotency prevents duplicate account awards.';


-- ============================================================================
-- 2. PROFILE STATE WORKFLOW
--
-- Relevant state:
--   * league_member identity
--   * profile identity/version
--   * complete set of active certified league rounds
--
-- Therefore:
--   profile edit                    => new workflow
--   first certified round appears  => new workflow
--   later certification changes    => new workflow
--
-- Achievement remains one-shot per account.
-- ============================================================================

create or replace function public.create_profile_state_certification_workflow_internal(
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

  v_profile_id uuid;
  v_profile_version integer;

  v_certified_round_count integer := 0;
  v_round_state_fingerprint text;
  v_state_fingerprint text;

  v_workflow record;
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


  select
    p.id,
    p.profile_version
  into
    v_profile_id,
    v_profile_version
  from public.league_member_profiles p
  where p.league_member_id =
        p_league_member_id;


  select
    count(*)::integer,

    md5(
      coalesce(
        string_agg(
          rc.id::text
          || ':'
          || rc.certification_version::text
          || ':'
          || coalesce(
               rc.certification_hash,
               ''
             )
          || ':'
          || coalesce(
               rc.committed_at::text,
               rc.created_at::text
             ),
          '|'
          order by
            coalesce(
              rc.committed_at,
              rc.created_at
            ),
            rc.id
        ),
        'no-certified-rounds'
      )
    )

  into
    v_certified_round_count,
    v_round_state_fingerprint

  from public.round_certifications rc

  join public.league_rounds lr
    on lr.id = rc.league_round_id

  where lr.league_id =
          v_member.league_id
    and rc.active = true
    and rc.status = 'certified';


  v_state_fingerprint :=
    md5(
      concat_ws(
        ':',

        p_league_member_id::text,

        coalesce(
          v_profile_id::text,
          'no-profile'
        ),

        coalesce(
          v_profile_version::text,
          'no-profile-version'
        ),

        v_certified_round_count::text,

        v_round_state_fingerprint
      )
    );


  select *
  into v_workflow
  from public.create_live_runtime_workflow_rpc(

    p_workflow_type =>
      'profile_state_certification',

    p_scope_type =>
      'league_member',

    p_scope_id =>
      p_league_member_id,

    p_idempotency_key =>
      'profile-state-certification:'
      || p_league_member_id::text
      || ':state:'
      || v_state_fingerprint
      || ':v1',

    p_steps =>
      jsonb_build_array(
        jsonb_build_object(

          'step_key',
            'certify_profile_completion',

          'step_order',
            10,

          'job_type',
            'certify_achievement_state',

          'scope_type',
            'league_member',

          'scope_id',
            p_league_member_id,

          'priority',
            100,

          'max_attempts',
            5,

          'payload',
            jsonb_build_object(
              'achievement_family',
                'profile',

              'certification_kind',
                'profile_completion',

              'league_id',
                v_member.league_id,

              'user_id',
                v_member.user_id,

              'league_member_profile_id',
                v_profile_id,

              'profile_version',
                v_profile_version,

              'certified_round_count',
                v_certified_round_count,

              'state_fingerprint',
                v_state_fingerprint
            )
        )
      ),

    p_workflow_version =>
      1,

    p_metadata =>
      coalesce(
        p_metadata,
        '{}'::jsonb
      )
      || jsonb_build_object(
        'achievement_engine',
          true,

        'achievement_family',
          'profile',

        'league_id',
          v_member.league_id,

        'user_id',
          v_member.user_id,

        'league_member_profile_id',
          v_profile_id,

        'profile_version',
          v_profile_version,

        'certified_round_count',
          v_certified_round_count,

        'state_fingerprint',
          v_state_fingerprint,

        'state_based_idempotency',
          true,

        'runtime_contract_version',
          '1.1.0'
      ),

    p_correlation_id =>
      p_correlation_id,

    p_causation_id =>
      p_causation_id
  );


  return jsonb_build_object(

    'workflow_id',
      v_workflow.workflow_id,

    'workflow_status',
      v_workflow.workflow_status,

    'inserted',
      v_workflow.inserted,

    'step_count',
      v_workflow.step_count,

    'correlation_id',
      v_workflow.correlation_id,

    'state_fingerprint',
      v_state_fingerprint,

    'profile_id',
      v_profile_id,

    'profile_version',
      v_profile_version,

    'certified_round_count',
      v_certified_round_count
  );

end;
$function$;


comment on function public.create_profile_state_certification_workflow_internal(
  uuid,uuid,uuid,jsonb
)
is
  'Creates a state-idempotent Profile Achievement workflow keyed by profile version and active certified-round state.';


-- ============================================================================
-- 3. COMPETITION SEASON WORKFLOW
--
-- Aggregate owner remains league.
--
-- Relevant state:
--   league.season_id
--   complete current state of every active match in that season.
--
-- A future match finalisation changes the fingerprint and permits a new
-- evaluation. Achievement remains one-shot per account.
-- ============================================================================

create or replace function public.create_competition_season_certification_workflow_internal(
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

  v_match_state_fingerprint text;
  v_state_fingerprint text;

  v_workflow record;
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

    v_total_matches := 0;
    v_finalised_matches := 0;

    v_match_state_fingerprint :=
      md5('league-season-not-linked');

  else

    select
      count(*)::integer,

      count(*) filter (
        where m.finalised_at is not null
      )::integer,

      md5(
        coalesce(
          string_agg(
            m.id::text
            || ':'
            || m.status
            || ':'
            || coalesce(
                 m.finalised_at::text,
                 'not-finalised'
               )
            || ':'
            || m.version::text,
            '|'
            order by m.kickoff, m.id
          ),
          'no-active-matches'
        )
      )

    into
      v_total_matches,
      v_finalised_matches,
      v_match_state_fingerprint

    from public.matches m

    where m.season_id =
            v_league.season_id
      and m.active = true;

  end if;


  v_total_matches :=
    coalesce(
      v_total_matches,
      0
    );

  v_finalised_matches :=
    coalesce(
      v_finalised_matches,
      0
    );


  v_state_fingerprint :=
    md5(
      concat_ws(
        ':',

        p_league_id::text,

        coalesce(
          v_league.season_id::text,
          'no-season'
        ),

        v_total_matches::text,

        v_finalised_matches::text,

        v_match_state_fingerprint
      )
    );


  select *
  into v_workflow
  from public.create_live_runtime_workflow_rpc(

    p_workflow_type =>
      'competition_season_certification',

    p_scope_type =>
      'league',

    p_scope_id =>
      p_league_id,

    p_idempotency_key =>
      'competition-season-certification:'
      || p_league_id::text
      || ':state:'
      || v_state_fingerprint
      || ':v1',

    p_steps =>
      jsonb_build_array(
        jsonb_build_object(

          'step_key',
            'certify_league_season',

          'step_order',
            10,

          'job_type',
            'certify_achievement_state',

          'scope_type',
            'league',

          'scope_id',
            p_league_id,

          'priority',
            100,

          'max_attempts',
            5,

          'payload',
            jsonb_build_object(
              'achievement_family',
                'competition',

              'certification_kind',
                'league_season',

              'season_id',
                v_league.season_id,

              'total_matches',
                v_total_matches,

              'finalised_matches',
                v_finalised_matches,

              'state_fingerprint',
                v_state_fingerprint
            )
        )
      ),

    p_workflow_version =>
      1,

    p_metadata =>
      coalesce(
        p_metadata,
        '{}'::jsonb
      )
      || jsonb_build_object(
        'achievement_engine',
          true,

        'achievement_family',
          'competition',

        'season_id',
          v_league.season_id,

        'total_matches',
          v_total_matches,

        'finalised_matches',
          v_finalised_matches,

        'state_fingerprint',
          v_state_fingerprint,

        'state_based_idempotency',
          true,

        'runtime_contract_version',
          '1.1.0'
      ),

    p_correlation_id =>
      p_correlation_id,

    p_causation_id =>
      p_causation_id
  );


  return jsonb_build_object(

    'workflow_id',
      v_workflow.workflow_id,

    'workflow_status',
      v_workflow.workflow_status,

    'inserted',
      v_workflow.inserted,

    'step_count',
      v_workflow.step_count,

    'correlation_id',
      v_workflow.correlation_id,

    'state_fingerprint',
      v_state_fingerprint,

    'season_id',
      v_league.season_id,

    'total_matches',
      v_total_matches,

    'finalised_matches',
      v_finalised_matches
  );

end;
$function$;


comment on function public.create_competition_season_certification_workflow_internal(
  uuid,uuid,uuid,jsonb
)
is
  'Creates a state-idempotent Competition Season Achievement workflow keyed by linked season and current active-match state.';


-- ============================================================================
-- 4. ASSERTIONS
-- ============================================================================

do $assertions$
declare
  v_governance text;
  v_profile text;
  v_season text;
begin

  select pg_get_functiondef(
    'public.create_league_governance_certification_workflow_internal(uuid,uuid,uuid,jsonb)'
      ::regprocedure
  )
  into v_governance;

  select pg_get_functiondef(
    'public.create_profile_state_certification_workflow_internal(uuid,uuid,uuid,jsonb)'
      ::regprocedure
  )
  into v_profile;

  select pg_get_functiondef(
    'public.create_competition_season_certification_workflow_internal(uuid,uuid,uuid,jsonb)'
      ::regprocedure
  )
  into v_season;


  if position(
      ':state:'
      in v_governance
    ) = 0
    or position(
      'state_fingerprint'
      in v_governance
    ) = 0
  then
    raise exception
      'MIGRATION_208_GOVERNANCE_STATE_IDEMPOTENCY_MISSING';
  end if;


  if position(
      'bootstrap_reference'
      in v_governance
    ) = 0
  then
    raise exception
      'MIGRATION_208_GOVERNANCE_BOOTSTRAP_PAYLOAD_MISSING';
  end if;


  if position(
      ':state:'
      in v_profile
    ) = 0
    or position(
      'profile_version'
      in v_profile
    ) = 0
    or position(
      'certified_round_count'
      in v_profile
    ) = 0
  then
    raise exception
      'MIGRATION_208_PROFILE_STATE_IDEMPOTENCY_MISSING';
  end if;


  if position(
      ':state:'
      in v_season
    ) = 0
    or position(
      'finalised_matches'
      in v_season
    ) = 0
  then
    raise exception
      'MIGRATION_208_SEASON_STATE_IDEMPOTENCY_MISSING';
  end if;

end;
$assertions$;

commit;