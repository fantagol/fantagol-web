-- ============================================================================
-- FANTAGOL
-- Migration 272
-- Round Terminal Game Objective Materialization
--
-- Canonical boundary:
--   completed round_certification workflow
--     -> FIRST_ROUND_COMPLETED achievement certification
--     -> achievement -> loyalty workflow bridge
--     -> profile_state_certification workflow fan-out
--
-- Safety:
--   - service_role only
--   - no trigger on round_certifications
--   - no direct loyalty producer wrapper
--   - no producer/binding/policy/campaign activation
--   - no historical scan/backfill
--   - invocation is explicit from the terminal worker hook only
-- ============================================================================

begin;

-- ============================================================================
-- 0. DEPENDENCY ASSERTIONS
-- ============================================================================

do $$
begin
  if to_regclass(
    'public.live_runtime_workflows'
  ) is null
     or to_regclass(
       'public.live_runtime_workflow_steps'
     ) is null
     or to_regclass(
       'public.round_certifications'
     ) is null
     or to_regclass(
       'public.achievement_certifications'
     ) is null then
    raise exception using
      errcode = 'P0001',
      message = 'R46_TERMINAL_GAME_OBJECTIVE_FOUNDATION_MISSING';
  end if;

  if to_regprocedure(
    'public.certify_achievement_internal(text,uuid,text,text,text,text,jsonb,timestamp with time zone,uuid,uuid,uuid,uuid,uuid,boolean,uuid,uuid,jsonb)'
  ) is null then
    raise exception using
      errcode = 'P0001',
      message = 'R46_ACHIEVEMENT_CERTIFIER_MISSING';
  end if;

  if to_regprocedure(
    'public.enqueue_workflow_loyalty_dispatch_internal(text,uuid,uuid,text,uuid,text,text,integer,jsonb,timestamp with time zone,uuid,uuid,uuid,uuid,uuid,uuid,jsonb,jsonb)'
  ) is null then
    raise exception using
      errcode = 'P0001',
      message = 'R46_ACHIEVEMENT_LOYALTY_BRIDGE_MISSING';
  end if;

  if to_regprocedure(
    'public.create_profile_state_certification_workflow_internal(uuid,uuid,uuid,jsonb)'
  ) is null then
    raise exception using
      errcode = 'P0001',
      message = 'R46_PROFILE_WORKFLOW_MATERIALIZER_MISSING';
  end if;
end;
$$;

-- ============================================================================
-- 1. TERMINAL ROUND GAME OBJECTIVE MATERIALIZER
-- ============================================================================

create or replace function
public.materialize_round_terminal_game_objectives_internal(
  p_workflow_instance_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_workflow public.live_runtime_workflows%rowtype;
  v_step public.live_runtime_workflow_steps%rowtype;

  v_round public.league_rounds%rowtype;
  v_certification public.round_certifications%rowtype;

  v_member record;

  v_achievement jsonb;
  v_achievement_id uuid;

  v_first_round_achievement
    public.achievement_certifications%rowtype;

  v_first_round_binding
    public.workflow_loyalty_producer_bindings%rowtype;

  v_first_round_evidence jsonb;

  v_profile_workflow jsonb;

  v_reference text;
  v_source_reference text;
  v_digest text;

  v_first_round_certified integer := 0;
  v_first_round_duplicates integer := 0;
  v_loyalty_dispatch_attempts integer := 0;

  v_profile_workflow_attempts integer := 0;
  v_profile_workflow_eligible_members integer := 0;

  v_is_first_round boolean := false;
begin
  if p_workflow_instance_id is null then
    raise exception using
      errcode = '22004',
      message = 'R46_WORKFLOW_INSTANCE_REQUIRED';
  end if;

  -- Serialize terminal materialization for this workflow.
  perform pg_advisory_xact_lock(
    hashtextextended(
      'r46-round-terminal-game-objectives:'
      || p_workflow_instance_id::text,
      0
    )
  );

  select w.*
  into v_workflow
  from public.live_runtime_workflows w
  where w.id = p_workflow_instance_id
  for share;

  if not found then
    raise exception using
      errcode = 'P0002',
      message = 'R46_TERMINAL_WORKFLOW_NOT_FOUND';
  end if;

  -- Non-target workflows are intentional no-ops.
  if v_workflow.workflow_type <> 'round_certification' then
    return jsonb_build_object(
      'handled', false,
      'reason', 'WORKFLOW_TYPE_NOT_TARGET',
      'workflow_id', v_workflow.id,
      'workflow_type', v_workflow.workflow_type,
      'workflow_status', v_workflow.status
    );
  end if;

  -- Never materialize achievements before terminal workflow evidence exists.
  if v_workflow.status <> 'completed' then
    return jsonb_build_object(
      'handled', false,
      'reason', 'WORKFLOW_NOT_COMPLETED',
      'workflow_id', v_workflow.id,
      'workflow_type', v_workflow.workflow_type,
      'workflow_status', v_workflow.status
    );
  end if;

  select s.*
  into v_step
  from public.live_runtime_workflow_steps s
  where s.workflow_id = v_workflow.id
    and s.step_key = 'certify_round'
  limit 1;

  if not found then
    raise exception using
      errcode = 'P0001',
      message = 'R46_CERTIFY_ROUND_STEP_NOT_FOUND';
  end if;

  if v_step.status <> 'completed' then
    raise exception using
      errcode = 'P0001',
      message = 'R46_CERTIFY_ROUND_STEP_NOT_COMPLETED';
  end if;

  if v_workflow.scope_type <> 'league_round' then
    raise exception using
      errcode = 'P0001',
      message = 'R46_ROUND_WORKFLOW_SCOPE_INVALID';
  end if;

  select lr.*
  into v_round
  from public.league_rounds lr
  where lr.id = v_workflow.scope_id;

  if not found then
    raise exception using
      errcode = 'P0002',
      message = 'R46_LEAGUE_ROUND_NOT_FOUND';
  end if;

  -- Canonical official certification only.
  select rc.*
  into v_certification
  from public.round_certifications rc
  where rc.league_round_id = v_round.id
    and rc.active = true
    and rc.status = 'official'
  order by
    coalesce(rc.committed_at, rc.created_at) desc,
    rc.id desc
  limit 1;

  if not found then
    return jsonb_build_object(
      'handled', false,
      'reason', 'OFFICIAL_ROUND_CERTIFICATION_NOT_AVAILABLE',
      'workflow_id', v_workflow.id,
      'league_round_id', v_round.id
    );
  end if;

  v_is_first_round :=
    v_round.league_round_number = 1;

  -- ========================================================================
  -- A. FIRST ROUND COMPLETED
  --
  -- This is an Achievement Engine certification, not direct Loyalty
  -- production. Idempotency is owned by certification_reference as hardened
  -- in migration 270.
  -- ========================================================================

  if v_is_first_round then
    for v_member in
      select
        lm.id as league_member_id,
        lm.user_id
      from public.league_members lm
      where lm.league_id = v_round.league_id
        and lm.status = 'active'
        and lm.user_id is not null
      order by lm.id
    loop
      v_reference :=
        'round-certification:'
        || v_round.league_id::text
        || ':first-round:'
        || v_member.user_id::text;

      v_source_reference :=
        'round-certification:'
        || v_certification.id::text;

      v_digest :=
        md5(
          concat_ws(
            ':',
            'FIRST_ROUND_COMPLETED',
            v_round.league_id::text,
            v_round.id::text,
            v_certification.id::text,
            v_member.league_member_id::text,
            v_member.user_id::text,
            coalesce(
              v_certification.certification_hash,
              ''
            )
          )
        );

      v_achievement :=
        public.certify_achievement_internal(
          p_achievement_code =>
            'FIRST_ROUND_COMPLETED',

          p_user_id =>
            v_member.user_id,

          p_source_family =>
            'round',

          p_source_reference =>
            v_source_reference,

          p_certification_reference =>
            v_reference,

          p_certification_digest =>
            v_digest,

          p_evidence =>
            jsonb_build_object(
              'certified', true,
              'workflow_completed', true,
              'step_completed', true,
              'workflow_code',
                'round_certification',
              'completion_step_code',
                'certify_round',
              'workflow_instance_id',
                v_workflow.id,
              'workflow_step_id',
                v_step.id,
              'round_certification_id',
                v_certification.id,
              'round_certification_status',
                v_certification.status,
              'round_certification_active',
                v_certification.active,
              'round_certification_version',
                v_certification.certification_version,
              'round_certification_hash',
                v_certification.certification_hash,
              'league_id',
                v_round.league_id,
              'league_round_id',
                v_round.id,
              'league_round_number',
                v_round.league_round_number,
              'league_member_id',
                v_member.league_member_id,
              'achievement_kind',
                'FIRST_ROUND_COMPLETED'
            ),

          p_occurred_at =>
            coalesce(
              v_certification.committed_at,
              v_certification.created_at
            ),

          p_league_id =>
            v_round.league_id,

          p_league_round_id =>
            v_round.id,

          p_league_member_id =>
            v_member.league_member_id,

          p_bootstrap =>
            false,

          p_correlation_id =>
            v_workflow.correlation_id,

          p_causation_id =>
            v_workflow.causation_id,

          p_metadata =>
            jsonb_build_object(
              'adapter',
                'materialize_round_terminal_game_objectives_internal',
              'adapter_version',
                '1.0.0',
              'terminal_workflow_id',
                v_workflow.id,
              'round_certification_id',
                v_certification.id
            )
        );

      v_achievement_id :=
        nullif(
          v_achievement
            ->> 'achievement_certification_id',
          ''
        )::uuid;

      if v_achievement_id is null then
        raise exception using
          errcode = 'P0001',
          message = 'R46_FIRST_ROUND_ACHIEVEMENT_ID_MISSING';
      end if;

      if coalesce(
        (v_achievement ->> 'duplicate')::boolean,
        false
      ) then
        v_first_round_duplicates :=
          v_first_round_duplicates + 1;
      else
        v_first_round_certified :=
          v_first_round_certified + 1;
      end if;

      -- The bridge itself owns producer/binding gating and idempotency.
      -- ------------------------------------------------------------------
      -- FIRST ROUND ACHIEVEMENT -> OPTIONAL LOYALTY DISPATCH
      --
      -- FIRST_ROUND_COMPLETED is game-state authority.
      -- Commercial reward activation is independent.
      --
      -- Disabled WF_LOYALTY_LEAGUE_FIRST_ROUND = governed no-op.
      -- Enabled binding = canonical binding-driven dispatch.
      -- ------------------------------------------------------------------

      select ac.*
      into strict v_first_round_achievement
      from public.achievement_certifications ac
      where ac.id = v_achievement_id;

      select b.*
      into v_first_round_binding
      from public.workflow_loyalty_producer_bindings b
      where b.binding_code =
            'WF_LOYALTY_LEAGUE_FIRST_ROUND';

      if not found then
        raise exception using
          errcode = 'P0002',
          message =
            'R46_FIRST_ROUND_LOYALTY_BINDING_NOT_FOUND';
      end if;

      if v_first_round_binding.enabled then

        v_first_round_evidence :=
          jsonb_build_object(
            'certified',
              true,

            'certified_at',
              v_first_round_achievement.certified_at,

            'certification_digest',
              v_first_round_achievement.certification_digest,

            'workflow_completed',
              true,

            'step_completed',
              true,

            'workflow_code',
              v_workflow.workflow_type,

            'completion_step_code',
              v_step.step_key,

            'workflow_instance_id',
              v_workflow.id,

            'workflow_step_id',
              v_step.id,

            'achievement_certification_id',
              v_first_round_achievement.id,

            'achievement_code',
              v_first_round_achievement.achievement_code,

            'league_member_id',
              v_first_round_achievement.league_member_id,

            'bootstrap',
              v_first_round_achievement.bootstrap,

            'achievement_evidence',
              v_first_round_achievement.evidence
          );

        perform
          public.enqueue_workflow_loyalty_dispatch_internal(
            p_binding_code =>
              'WF_LOYALTY_LEAGUE_FIRST_ROUND',

            p_workflow_instance_id =>
              v_workflow.id,

            p_workflow_step_id =>
              v_step.id,

            p_workflow_execution_key =>
              'achievement:'
              || v_first_round_achievement.id::text,

            p_user_id =>
              v_first_round_achievement.user_id,

            p_certification_reference =>
              v_first_round_achievement.certification_reference,

            p_certification_digest =>
              v_first_round_achievement.certification_digest,

            p_evidence_version =>
              v_first_round_achievement.evidence_version,

            p_evidence =>
              v_first_round_evidence,

            p_occurred_at =>
              v_first_round_achievement.occurred_at,

            p_league_id =>
              v_first_round_achievement.league_id,

            p_league_round_id =>
              v_first_round_achievement.league_round_id,

            p_season_id =>
              v_first_round_achievement.season_id,

            p_prediction_result_id =>
              v_first_round_achievement.prediction_result_id,

            p_correlation_id =>
              v_first_round_achievement.correlation_id,

            p_causation_id =>
              v_first_round_achievement.id,

            p_payload =>
              jsonb_build_object(
                'achievement_certification_id',
                  v_first_round_achievement.id,

                'achievement_code',
                  v_first_round_achievement.achievement_code,

                'league_member_id',
                  v_first_round_achievement.league_member_id,

                'bootstrap',
                  v_first_round_achievement.bootstrap
              ),

            p_metadata =>
              jsonb_build_object(
                'bridge',
                  'round_terminal_game_objective',

                'bridge_version',
                  '1.0.0',

                'binding_code',
                  'WF_LOYALTY_LEAGUE_FIRST_ROUND',

                'achievement_certification_id',
                  v_first_round_achievement.id,

                'commercial_activation_required',
                  true
              )
          );

        v_loyalty_dispatch_attempts :=
          v_loyalty_dispatch_attempts + 1;

      end if;

    end loop;
  end if;

  -- ========================================================================
  -- B. PROFILE WORKFLOW FAN-OUT
  --
  -- This does NOT certify profile completion here.
  -- It only materializes each active member's canonical profile-state workflow.
  -- The existing profile certifier remains the eligibility authority.
  -- ========================================================================

  for v_member in
    select
      lm.id as league_member_id,
      lm.user_id
    from public.league_members lm
    where lm.league_id = v_round.league_id
      and lm.status = 'active'
      and lm.user_id is not null
    order by lm.id
  loop
    v_profile_workflow :=
      public.create_profile_state_certification_workflow_internal(
        p_league_member_id =>
          v_member.league_member_id,

        p_correlation_id =>
          v_workflow.correlation_id,

        p_causation_id =>
          v_workflow.id,

        p_metadata =>
          jsonb_build_object(
            'source',
              'round_terminal_game_objectives',
            'source_workflow_id',
              v_workflow.id,
            'round_certification_id',
              v_certification.id,
            'league_round_id',
              v_round.id,
            'league_round_number',
              v_round.league_round_number
          )
      );

    v_profile_workflow_attempts :=
      v_profile_workflow_attempts + 1;

    if coalesce(
      (v_profile_workflow ->> 'eligible')::boolean,
      true
    ) then
      v_profile_workflow_eligible_members :=
        v_profile_workflow_eligible_members + 1;
    end if;
  end loop;

  return jsonb_build_object(
    'handled', true,
    'workflow_id', v_workflow.id,
    'workflow_type', v_workflow.workflow_type,
    'workflow_status', v_workflow.status,
    'workflow_step_id', v_step.id,
    'workflow_step_status', v_step.status,

    'league_id', v_round.league_id,
    'league_round_id', v_round.id,
    'league_round_number', v_round.league_round_number,

    'round_certification_id', v_certification.id,
    'round_certification_status', v_certification.status,

    'first_round', v_is_first_round,
    'first_round_achievement_created',
      v_first_round_certified,
    'first_round_achievement_duplicate',
      v_first_round_duplicates,
    'loyalty_dispatch_attempts',
      v_loyalty_dispatch_attempts,

    'profile_workflow_attempts',
      v_profile_workflow_attempts,
    'profile_workflow_eligible_members',
      v_profile_workflow_eligible_members
  );
end;
$$;

comment on function
public.materialize_round_terminal_game_objectives_internal(uuid)
is
'R46 terminal materializer invoked only after a round_certification workflow and certify_round step are physically completed. Certifies FIRST_ROUND_COMPLETED via Achievement Engine, delegates reward routing to the governed achievement-loyalty bridge, and fans out canonical profile-state workflows. Does not activate reward configuration or perform historical backfill.';

revoke all
on function
public.materialize_round_terminal_game_objectives_internal(uuid)
from public;

revoke all
on function
public.materialize_round_terminal_game_objectives_internal(uuid)
from anon;

revoke all
on function
public.materialize_round_terminal_game_objectives_internal(uuid)
from authenticated;

grant execute
on function
public.materialize_round_terminal_game_objectives_internal(uuid)
to service_role;

commit;