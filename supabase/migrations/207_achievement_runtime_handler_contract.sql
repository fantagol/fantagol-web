begin;

-- ============================================================================
-- FANTAGOL
-- MIGRATION 207
-- ACHIEVEMENT RUNTIME HANDLER CONTRACT
--
-- Single runtime dispatcher:
--
-- certify_achievement_state
--        ↓
-- certify_achievement_state_rpc(...)
--        ↓
-- Domain adapter
--        ↓
-- achievement_certifications
--
-- Participation intentionally remains blocked here until its certified
-- completeness/streak semantics are installed in the Achievement ledger.
--
-- NO Loyalty dispatch.
-- NO Pass allocation.
-- ============================================================================

create or replace function public.certify_achievement_state_rpc(
  p_workflow_type text,
  p_workflow_step_key text,
  p_scope_type text,
  p_scope_id uuid,
  p_payload jsonb default '{}'::jsonb,
  p_correlation_id uuid default null,
  p_causation_id uuid default null
)
returns table (
  result jsonb
)
language plpgsql
security definer
set search_path = public, pg_temp
as $function$
declare
  v_workflow_type text :=
    lower(btrim(p_workflow_type));

  v_step_key text :=
    lower(btrim(p_workflow_step_key));

  v_payload jsonb :=
    coalesce(p_payload, '{}'::jsonb);

  v_result jsonb;
begin

  if nullif(v_workflow_type, '') is null then
    raise exception using
      errcode = '22023',
      message = 'ACHIEVEMENT_WORKFLOW_TYPE_REQUIRED';
  end if;

  if nullif(v_step_key, '') is null then
    raise exception using
      errcode = '22023',
      message = 'ACHIEVEMENT_WORKFLOW_STEP_REQUIRED';
  end if;

  if p_scope_id is null then
    raise exception using
      errcode = '22004',
      message = 'ACHIEVEMENT_SCOPE_ID_REQUIRED';
  end if;


  -- ========================================================================
  -- LEAGUE GOVERNANCE
  -- ========================================================================

  if v_workflow_type = 'league_governance_certification'
     and v_step_key = 'certify_active_membership_threshold'
  then

    if p_scope_type <> 'league' then
      raise exception using
        errcode = '22023',
        message = 'ACHIEVEMENT_GOVERNANCE_SCOPE_INVALID';
    end if;

    v_result :=
      public.certify_league_governance_achievements_internal(
        p_league_id =>
          p_scope_id,

        p_bootstrap =>
          coalesce(
            (v_payload ->> 'bootstrap')::boolean,
            false
          ),

        p_bootstrap_reference =>
          nullif(
            btrim(
              v_payload ->> 'bootstrap_reference'
            ),
            ''
          ),

        p_correlation_id =>
          p_correlation_id,

        p_causation_id =>
          p_causation_id,

        p_metadata =>
          jsonb_build_object(
            'runtime_dispatcher',
              'certify_achievement_state_rpc',
            'workflow_type',
              v_workflow_type,
            'workflow_step_key',
              v_step_key
          )
      );


  -- ========================================================================
  -- PROFILE
  -- ========================================================================

  elsif v_workflow_type = 'profile_state_certification'
        and v_step_key = 'certify_profile_completion'
  then

    if p_scope_type <> 'league_member' then
      raise exception using
        errcode = '22023',
        message = 'ACHIEVEMENT_PROFILE_SCOPE_INVALID';
    end if;

    v_result :=
      public.certify_profile_completion_achievement_internal(
        p_league_member_id =>
          p_scope_id,

        p_correlation_id =>
          p_correlation_id,

        p_causation_id =>
          p_causation_id,

        p_metadata =>
          jsonb_build_object(
            'runtime_dispatcher',
              'certify_achievement_state_rpc',
            'workflow_type',
              v_workflow_type,
            'workflow_step_key',
              v_step_key
          )
      );


  -- ========================================================================
  -- COMPETITION SEASON
  -- ========================================================================

  elsif v_workflow_type = 'competition_season_certification'
        and v_step_key = 'certify_league_season'
  then

    if p_scope_type <> 'league' then
      raise exception using
        errcode = '22023',
        message = 'ACHIEVEMENT_SEASON_SCOPE_INVALID';
    end if;

    v_result :=
      public.certify_competition_season_achievements_internal(
        p_league_id =>
          p_scope_id,

        p_correlation_id =>
          p_correlation_id,

        p_causation_id =>
          p_causation_id,

        p_metadata =>
          jsonb_build_object(
            'runtime_dispatcher',
              'certify_achievement_state_rpc',
            'workflow_type',
              v_workflow_type,
            'workflow_step_key',
              v_step_key
          )
      );


  -- ========================================================================
  -- PARTICIPATION
  --
  -- Legacy helpers found by the audit write directly into Loyalty.
  -- They are deliberately NOT called here.
  -- ========================================================================

  elsif v_workflow_type = 'participation_certification'
  then

    raise exception using
      errcode = 'P0001',
      message = 'ACHIEVEMENT_PARTICIPATION_ADAPTER_NOT_READY',
      detail =
        'Participation must first certify into achievement_certifications; direct legacy Loyalty emission is forbidden.';


  else

    raise exception using
      errcode = '22023',
      message = 'ACHIEVEMENT_WORKFLOW_CONTRACT_INVALID',
      detail =
        'workflow_type='
        || coalesce(v_workflow_type, '<null>')
        || ', step_key='
        || coalesce(v_step_key, '<null>');

  end if;


  return query
  select coalesce(
    v_result,
    '{}'::jsonb
  );
end;
$function$;


comment on function public.certify_achievement_state_rpc(
  text,text,text,uuid,jsonb,uuid,uuid
)
is
  'Canonical Live Runtime dispatcher for Achievement state certification. Routes certified workflow state to Achievement ledger adapters only; never directly to Loyalty or Commercial wallet.';


revoke all
on function public.certify_achievement_state_rpc(
  text,text,text,uuid,jsonb,uuid,uuid
)
from public, anon, authenticated;

grant execute
on function public.certify_achievement_state_rpc(
  text,text,text,uuid,jsonb,uuid,uuid
)
to service_role;


do $assertions$
begin

  if to_regprocedure(
    'public.certify_achievement_state_rpc(text,text,text,uuid,jsonb,uuid,uuid)'
  ) is null then
    raise exception
      'MIGRATION_207_ACHIEVEMENT_DISPATCHER_MISSING';
  end if;

  if position(
      'certify_league_governance_achievements_internal'
      in pg_get_functiondef(
        'public.certify_achievement_state_rpc(text,text,text,uuid,jsonb,uuid,uuid)'
          ::regprocedure
      )
    ) = 0 then
    raise exception
      'MIGRATION_207_GOVERNANCE_ROUTE_MISSING';
  end if;

  if position(
      'certify_profile_completion_achievement_internal'
      in pg_get_functiondef(
        'public.certify_achievement_state_rpc(text,text,text,uuid,jsonb,uuid,uuid)'
          ::regprocedure
      )
    ) = 0 then
    raise exception
      'MIGRATION_207_PROFILE_ROUTE_MISSING';
  end if;

  if position(
      'certify_competition_season_achievements_internal'
      in pg_get_functiondef(
        'public.certify_achievement_state_rpc(text,text,text,uuid,jsonb,uuid,uuid)'
          ::regprocedure
      )
    ) = 0 then
    raise exception
      'MIGRATION_207_SEASON_ROUTE_MISSING';
  end if;

  if position(
      'ACHIEVEMENT_PARTICIPATION_ADAPTER_NOT_READY'
      in pg_get_functiondef(
        'public.certify_achievement_state_rpc(text,text,text,uuid,jsonb,uuid,uuid)'
          ::regprocedure
      )
    ) = 0 then
    raise exception
      'MIGRATION_207_PARTICIPATION_SAFETY_GATE_MISSING';
  end if;

end;
$assertions$;

commit;