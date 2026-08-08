begin;

-- ============================================================================
-- FANTAGOL
-- MIGRATION 203
-- WORKFLOW LOYALTY CANONICAL NAMING ALIGNMENT
--
-- Purpose:
--   Align Migration 107 Loyalty bindings with the canonical Live Runtime
--   workflow vocabulary.
--
-- Existing canonical runtime conventions:
--   match_result_certification / certify_match_result
--   round_certification        / certify_round
--
-- Future Achievement workflow families follow the same snake_case contract.
--
-- Safety:
--   * bindings remain disabled;
--   * test_mode remains enabled;
--   * no workflow is created;
--   * no outbox event is created;
--   * no producer is enabled;
--   * no reward / wallet mutation occurs.
-- ============================================================================


-- ============================================================================
-- 1. ALIGN EXISTING REAL WORKFLOW FAMILIES
-- ============================================================================

update public.workflow_loyalty_producer_bindings
set
  workflow_code = 'match_result_certification',
  completion_step_code = 'certify_match_result',
  updated_at = clock_timestamp()
where binding_code in (
  'WF_LOYALTY_PREDICTION_EXACT',
  'WF_LOYALTY_PREDICTION_GRAND_SLAM',
  'WF_LOYALTY_PREDICTION_CANTONATA'
);


update public.workflow_loyalty_producer_bindings
set
  workflow_code = 'round_certification',
  completion_step_code = 'certify_round',
  updated_at = clock_timestamp()
where binding_code = 'WF_LOYALTY_LEAGUE_FIRST_ROUND';


-- ============================================================================
-- 2. FREEZE CANONICAL NAMES FOR FUTURE ACHIEVEMENT WORKFLOWS
-- ============================================================================

update public.workflow_loyalty_producer_bindings
set
  workflow_code = 'league_governance_certification',
  completion_step_code = 'certify_active_membership_threshold',
  updated_at = clock_timestamp()
where binding_code = 'WF_LOYALTY_LEAGUE_8_MEMBERS';


update public.workflow_loyalty_producer_bindings
set
  workflow_code = 'competition_season_certification',
  completion_step_code = 'certify_league_season',
  updated_at = clock_timestamp()
where binding_code = 'WF_LOYALTY_LEAGUE_SEASON_COMPLETE';


update public.workflow_loyalty_producer_bindings
set
  workflow_code = 'profile_state_certification',
  completion_step_code = 'certify_profile_completion',
  updated_at = clock_timestamp()
where binding_code = 'WF_LOYALTY_PROFILE_AFTER_FIRST_ROUND';


update public.workflow_loyalty_producer_bindings
set
  workflow_code = 'participation_certification',
  completion_step_code = 'certify_prediction_streak',
  updated_at = clock_timestamp()
where binding_code in (
  'WF_LOYALTY_PARTICIPATION_STREAK_5',
  'WF_LOYALTY_PARTICIPATION_STREAK_10'
);


update public.workflow_loyalty_producer_bindings
set
  workflow_code = 'participation_certification',
  completion_step_code = 'certify_full_season_participation',
  updated_at = clock_timestamp()
where binding_code = 'WF_LOYALTY_PARTICIPATION_FULL_SEASON';


-- ============================================================================
-- 3. ASSERT EXACT CONTRACT
-- ============================================================================

do $assertions$
declare
  v_count integer;
begin

  select count(*)
  into v_count
  from public.workflow_loyalty_producer_bindings
  where binding_code in (
      'WF_LOYALTY_PREDICTION_EXACT',
      'WF_LOYALTY_PREDICTION_GRAND_SLAM',
      'WF_LOYALTY_PREDICTION_CANTONATA'
    )
    and workflow_code = 'match_result_certification'
    and completion_step_code = 'certify_match_result'
    and enabled = false
    and test_mode = true;

  if v_count <> 3 then
    raise exception
      'MIGRATION_203_MATCH_RESULT_BINDING_ALIGNMENT_FAILED count=%',
      v_count;
  end if;


  select count(*)
  into v_count
  from public.workflow_loyalty_producer_bindings
  where binding_code = 'WF_LOYALTY_LEAGUE_FIRST_ROUND'
    and workflow_code = 'round_certification'
    and completion_step_code = 'certify_round'
    and enabled = false
    and test_mode = true;

  if v_count <> 1 then
    raise exception
      'MIGRATION_203_ROUND_BINDING_ALIGNMENT_FAILED';
  end if;


  select count(*)
  into v_count
  from public.workflow_loyalty_producer_bindings
  where binding_code in (
    'WF_LOYALTY_LEAGUE_8_MEMBERS',
    'WF_LOYALTY_LEAGUE_FIRST_ROUND',
    'WF_LOYALTY_LEAGUE_SEASON_COMPLETE',
    'WF_LOYALTY_PARTICIPATION_FULL_SEASON',
    'WF_LOYALTY_PARTICIPATION_STREAK_10',
    'WF_LOYALTY_PARTICIPATION_STREAK_5',
    'WF_LOYALTY_PREDICTION_CANTONATA',
    'WF_LOYALTY_PREDICTION_EXACT',
    'WF_LOYALTY_PREDICTION_GRAND_SLAM',
    'WF_LOYALTY_PROFILE_AFTER_FIRST_ROUND'
  )
  and enabled = false
  and test_mode = true;

  if v_count <> 10 then
    raise exception
      'MIGRATION_203_BINDING_SAFETY_STATE_FAILED count=%',
      v_count;
  end if;


  if exists (
    select 1
    from public.workflow_loyalty_producer_bindings
    where workflow_code like '%-%'
       or completion_step_code like '%-%'
  ) then
    raise exception
      'MIGRATION_203_NON_CANONICAL_BINDING_NAME_REMAINS';
  end if;

end;
$assertions$;

commit;