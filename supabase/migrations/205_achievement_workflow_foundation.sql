begin;

-- ============================================================================
-- FANTAGOL
-- MIGRATION 205
-- ACHIEVEMENT WORKFLOW FOUNDATION
--
-- Missing workflow families:
--
--   league_governance_certification
--     -> certify_active_membership_threshold
--
--   competition_season_certification
--     -> certify_league_season
--
--   profile_state_certification
--     -> certify_profile_completion
--
--   participation_certification
--     -> certify_prediction_streak
--     -> certify_full_season_participation
--
-- Runtime execution job:
--   certify_achievement_state
--
-- This migration installs workflow creation contracts only.
--
-- It DOES NOT:
--   * execute workflows;
--   * certify achievements;
--   * enable Loyalty bindings;
--   * create Commercial rewards;
--   * mutate wallets.
-- ============================================================================


-- ============================================================================
-- 1. EXTEND LIVE RUNTIME JOB TYPE
-- ============================================================================

do $extend_job_types$
declare
  v_definition text;
  v_values text;
begin
  select pg_get_constraintdef(c.oid)
  into v_definition
  from pg_constraint c
  where c.conrelid =
        'public.live_runtime_jobs'::regclass
    and c.conname =
        'live_runtime_jobs_type_check'
    and c.contype = 'c';

  if v_definition is null then
    raise exception
      'ACHIEVEMENT_WORKFLOW_JOB_TYPE_CONSTRAINT_MISSING';
  end if;

  if position(
      'certify_achievement_state'
      in v_definition
    ) = 0 then

    select string_agg(
      quote_literal(x.value),
      ','
      order by x.value
    )
    into v_values
    from (
      select distinct m[1] as value
      from regexp_matches(
        v_definition,
        '''([^'']+)''',
        'g'
      ) m
    ) x;

    if v_values is null then
      raise exception
        'ACHIEVEMENT_WORKFLOW_JOB_TYPE_PARSE_FAILED';
    end if;

    alter table public.live_runtime_jobs
      drop constraint live_runtime_jobs_type_check;

    execute
      'alter table public.live_runtime_jobs ' ||
      'add constraint live_runtime_jobs_type_check ' ||
      'check (job_type in (' ||
      v_values || ',' ||
      quote_literal('certify_achievement_state') ||
      '))';
  end if;
end;
$extend_job_types$;


comment on constraint live_runtime_jobs_type_check
on public.live_runtime_jobs is
  'Allowed persistent Live Runtime job types, including generic certified Achievement workflow execution.';


-- ============================================================================
-- 2. LEAGUE GOVERNANCE WORKFLOW CREATOR
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
                8
            )
        )
      ),

    p_workflow_version =>
      1,

    p_metadata =>
      coalesce(p_metadata, '{}'::jsonb)
      || jsonb_build_object(
        'achievement_engine',
          true,
        'achievement_family',
          'league_governance',
        'runtime_contract_version',
          '1.0.0'
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
      v_workflow.correlation_id
  );
end;
$function$;


-- ============================================================================
-- 3. COMPETITION SEASON WORKFLOW CREATOR
--
-- Aggregate owner = league.
-- season_id remains certified metadata/evidence.
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
      || ':'
      || coalesce(
           v_league.season_id::text,
           'no-season'
         )
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
                v_league.season_id
            )
        )
      ),

    p_workflow_version =>
      1,

    p_metadata =>
      coalesce(p_metadata, '{}'::jsonb)
      || jsonb_build_object(
        'achievement_engine',
          true,
        'achievement_family',
          'competition',
        'season_id',
          v_league.season_id,
        'runtime_contract_version',
          '1.0.0'
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
      v_workflow.correlation_id
  );
end;
$function$;


-- ============================================================================
-- 4. PROFILE STATE WORKFLOW CREATOR
--
-- Aggregate owner = league_member.
-- profile identity remains metadata/evidence.
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

  select p.id
  into v_profile_id
  from public.league_member_profiles p
  where p.league_member_id = p_league_member_id;

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
                v_profile_id
            )
        )
      ),

    p_workflow_version =>
      1,

    p_metadata =>
      coalesce(p_metadata, '{}'::jsonb)
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
        'runtime_contract_version',
          '1.0.0'
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
      v_workflow.correlation_id
  );
end;
$function$;


-- ============================================================================
-- 5. PARTICIPATION WORKFLOW CREATOR
--
-- One workflow per league_member + season context.
-- Two independent certification steps:
--
--   certify_prediction_streak
--   certify_full_season_participation
--
-- They intentionally share no dependency.
-- Both derive exclusively from certified participation state.
-- ============================================================================

create or replace function public.create_participation_certification_workflow_internal(
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
  v_league public.leagues%rowtype;
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

  select l.*
  into v_league
  from public.leagues l
  where l.id = v_member.league_id;

  if not found then
    raise exception using
      errcode = 'P0002',
      message = 'ACHIEVEMENT_LEAGUE_NOT_FOUND';
  end if;

  select *
  into v_workflow
  from public.create_live_runtime_workflow_rpc(
    p_workflow_type =>
      'participation_certification',

    p_scope_type =>
      'league_member',

    p_scope_id =>
      p_league_member_id,

    p_idempotency_key =>
      'participation-certification:'
      || p_league_member_id::text
      || ':'
      || coalesce(
           v_league.season_id::text,
           'no-season'
         )
      || ':v1',

    p_steps =>
      jsonb_build_array(

        jsonb_build_object(
          'step_key',
            'certify_prediction_streak',
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
                'participation',
              'certification_kind',
                'prediction_streak',
              'league_id',
                v_member.league_id,
              'user_id',
                v_member.user_id,
              'season_id',
                v_league.season_id
            )
        ),

        jsonb_build_object(
          'step_key',
            'certify_full_season_participation',
          'step_order',
            20,
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
                'participation',
              'certification_kind',
                'full_season_participation',
              'league_id',
                v_member.league_id,
              'user_id',
                v_member.user_id,
              'season_id',
                v_league.season_id
            )
        )

      ),

    p_workflow_version =>
      1,

    p_metadata =>
      coalesce(p_metadata, '{}'::jsonb)
      || jsonb_build_object(
        'achievement_engine',
          true,
        'achievement_family',
          'participation',
        'league_id',
          v_member.league_id,
        'user_id',
          v_member.user_id,
        'season_id',
          v_league.season_id,
        'runtime_contract_version',
          '1.0.0'
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
      v_workflow.correlation_id
  );
end;
$function$;


-- ============================================================================
-- 6. PRIVILEGE BOUNDARY
-- ============================================================================

revoke all
on function public.create_league_governance_certification_workflow_internal(
  uuid,uuid,uuid,jsonb
)
from public, anon, authenticated;

grant execute
on function public.create_league_governance_certification_workflow_internal(
  uuid,uuid,uuid,jsonb
)
to service_role;


revoke all
on function public.create_competition_season_certification_workflow_internal(
  uuid,uuid,uuid,jsonb
)
from public, anon, authenticated;

grant execute
on function public.create_competition_season_certification_workflow_internal(
  uuid,uuid,uuid,jsonb
)
to service_role;


revoke all
on function public.create_profile_state_certification_workflow_internal(
  uuid,uuid,uuid,jsonb
)
from public, anon, authenticated;

grant execute
on function public.create_profile_state_certification_workflow_internal(
  uuid,uuid,uuid,jsonb
)
to service_role;


revoke all
on function public.create_participation_certification_workflow_internal(
  uuid,uuid,uuid,jsonb
)
from public, anon, authenticated;

grant execute
on function public.create_participation_certification_workflow_internal(
  uuid,uuid,uuid,jsonb
)
to service_role;


-- ============================================================================
-- 7. ASSERTIONS
-- ============================================================================

do $assertions$
declare
  v_definition text;
begin

  select pg_get_constraintdef(c.oid)
  into v_definition
  from pg_constraint c
  where c.conrelid =
        'public.live_runtime_jobs'::regclass
    and c.conname =
        'live_runtime_jobs_type_check';

  if position(
      'certify_achievement_state'
      in v_definition
    ) = 0 then
    raise exception
      'MIGRATION_205_JOB_TYPE_NOT_INSTALLED';
  end if;


  if to_regprocedure(
    'public.create_league_governance_certification_workflow_internal(uuid,uuid,uuid,jsonb)'
  ) is null then
    raise exception
      'MIGRATION_205_GOVERNANCE_WORKFLOW_MISSING';
  end if;


  if to_regprocedure(
    'public.create_competition_season_certification_workflow_internal(uuid,uuid,uuid,jsonb)'
  ) is null then
    raise exception
      'MIGRATION_205_SEASON_WORKFLOW_MISSING';
  end if;


  if to_regprocedure(
    'public.create_profile_state_certification_workflow_internal(uuid,uuid,uuid,jsonb)'
  ) is null then
    raise exception
      'MIGRATION_205_PROFILE_WORKFLOW_MISSING';
  end if;


  if to_regprocedure(
    'public.create_participation_certification_workflow_internal(uuid,uuid,uuid,jsonb)'
  ) is null then
    raise exception
      'MIGRATION_205_PARTICIPATION_WORKFLOW_MISSING';
  end if;

end;
$assertions$;

commit;