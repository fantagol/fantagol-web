-- ============================================================================
-- FANTAGOL - MIGRATION 297
-- PROFILE STATE WORKFLOW CREATE -> ENQUEUE HANDOFF
-- ============================================================================
--
-- Authority:
--   materialize_round_terminal_game_objectives_internal(uuid)
--
-- Purpose:
--   Complete the targeted terminal profile fan-out by immediately enqueueing
--   ready steps for each canonical profile_state_certification workflow that
--   the round-terminal materializer creates or reuses.
--
-- Governance:
--   * Do NOT change create_live_runtime_workflow_rpc generic semantics.
--   * Do NOT auto-enqueue all workflow types globally.
--   * Keep profile eligibility/certification in the existing profile handler.
--   * Reuse enqueue_ready_live_runtime_workflow_steps_rpc for canonical
--     job idempotency, workflow-step linking and event emission.
--   * Replays remain safe: the profile workflow is state-idempotent and the
--     ready-step enqueue RPC only acts on currently ready due steps.
-- ============================================================================

create or replace function public.materialize_round_terminal_game_objectives_internal(
  p_workflow_instance_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
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
  v_profile_workflow_id uuid;
  v_profile_enqueue record;

  v_reference text;
  v_source_reference text;
  v_digest text;

  v_first_round_certified integer := 0;
  v_first_round_duplicates integer := 0;
  v_loyalty_dispatch_attempts integer := 0;

  v_profile_workflow_attempts integer := 0;
  v_profile_workflow_eligible_members integer := 0;
  v_profile_enqueue_calls integer := 0;
  v_profile_enqueued_steps integer := 0;
  v_is_first_round boolean := false;
begin
  if p_workflow_instance_id is null then
    raise exception using
      errcode = '22004',
      message = 'R46_WORKFLOW_INSTANCE_REQUIRED';
  end if;

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

  if v_workflow.workflow_type <> 'round_certification' then
    return jsonb_build_object(
      'handled', false,
      'reason', 'WORKFLOW_TYPE_NOT_TARGET',
      'workflow_id', v_workflow.id,
      'workflow_type', v_workflow.workflow_type,
      'workflow_status', v_workflow.status
    );
  end if;

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
            coalesce(v_certification.certification_hash, '')
          )
        );

      v_achievement :=
        public.certify_achievement_internal(
          p_achievement_code => 'FIRST_ROUND_COMPLETED',
          p_user_id => v_member.user_id,
          p_source_family => 'round',
          p_source_reference => v_source_reference,
          p_certification_reference => v_reference,
          p_certification_digest => v_digest,
          p_evidence =>
            jsonb_build_object(
              'certified', true,
              'workflow_completed', true,
              'step_completed', true,
              'workflow_code', 'round_certification',
              'completion_step_code', 'certify_round',
              'workflow_instance_id', v_workflow.id,
              'workflow_step_id', v_step.id,
              'round_certification_id', v_certification.id,
              'round_certification_status', v_certification.status,
              'round_certification_active', v_certification.active,
              'round_certification_version', v_certification.certification_version,
              'round_certification_hash', v_certification.certification_hash,
              'league_id', v_round.league_id,
              'league_round_id', v_round.id,
              'league_round_number', v_round.league_round_number,
              'league_member_id', v_member.league_member_id,
              'achievement_kind', 'FIRST_ROUND_COMPLETED'
            ),
          p_occurred_at =>
            coalesce(v_certification.committed_at, v_certification.created_at),
          p_league_id => v_round.league_id,
          p_league_round_id => v_round.id,
          p_league_member_id => v_member.league_member_id,
          p_bootstrap => false,
          p_correlation_id => v_workflow.correlation_id,
          p_causation_id => v_workflow.causation_id,
          p_metadata =>
            jsonb_build_object(
              'adapter', 'materialize_round_terminal_game_objectives_internal',
              'adapter_version', '1.0.0',
              'terminal_workflow_id', v_workflow.id,
              'round_certification_id', v_certification.id
            )
        );

      v_achievement_id :=
        nullif(v_achievement ->> 'achievement_certification_id', '')::uuid;

      if v_achievement_id is null then
        raise exception using
          errcode = 'P0001',
          message = 'R46_FIRST_ROUND_ACHIEVEMENT_ID_MISSING';
      end if;

      if coalesce((v_achievement ->> 'duplicate')::boolean, false) then
        v_first_round_duplicates := v_first_round_duplicates + 1;
      else
        v_first_round_certified := v_first_round_certified + 1;
      end if;

      select ac.*
      into strict v_first_round_achievement
      from public.achievement_certifications ac
      where ac.id = v_achievement_id;

      select b.*
      into v_first_round_binding
      from public.workflow_loyalty_producer_bindings b
      where b.binding_code = 'WF_LOYALTY_LEAGUE_FIRST_ROUND';

      if not found then
        raise exception using
          errcode = 'P0002',
          message = 'R46_FIRST_ROUND_LOYALTY_BINDING_NOT_FOUND';
      end if;

      if v_first_round_binding.enabled then
        v_first_round_evidence :=
          jsonb_build_object(
            'certified', true,
            'certified_at', v_first_round_achievement.certified_at,
            'certification_digest', v_first_round_achievement.certification_digest,
            'workflow_completed', true,
            'step_completed', true,
            'workflow_code', v_workflow.workflow_type,
            'completion_step_code', v_step.step_key,
            'workflow_instance_id', v_workflow.id,
            'workflow_step_id', v_step.id,
            'achievement_certification_id', v_first_round_achievement.id,
            'achievement_code', v_first_round_achievement.achievement_code,
            'league_member_id', v_first_round_achievement.league_member_id,
            'bootstrap', v_first_round_achievement.bootstrap,
            'achievement_evidence', v_first_round_achievement.evidence
          );

        perform public.enqueue_workflow_loyalty_dispatch_internal(
          p_binding_code => 'WF_LOYALTY_LEAGUE_FIRST_ROUND',
          p_workflow_instance_id => v_workflow.id,
          p_workflow_step_id => v_step.id,
          p_workflow_execution_key =>
            'achievement:' || v_first_round_achievement.id::text,
          p_user_id => v_first_round_achievement.user_id,
          p_certification_reference =>
            v_first_round_achievement.certification_reference,
          p_certification_digest =>
            v_first_round_achievement.certification_digest,
          p_evidence_version => v_first_round_achievement.evidence_version,
          p_evidence => v_first_round_evidence,
          p_occurred_at => v_first_round_achievement.occurred_at,
          p_league_id => v_first_round_achievement.league_id,
          p_league_round_id => v_first_round_achievement.league_round_id,
          p_season_id => v_first_round_achievement.season_id,
          p_prediction_result_id =>
            v_first_round_achievement.prediction_result_id,
          p_correlation_id => v_first_round_achievement.correlation_id,
          p_causation_id => v_first_round_achievement.id,
          p_payload =>
            jsonb_build_object(
              'achievement_certification_id', v_first_round_achievement.id,
              'achievement_code', v_first_round_achievement.achievement_code,
              'league_member_id', v_first_round_achievement.league_member_id,
              'bootstrap', v_first_round_achievement.bootstrap
            ),
          p_metadata =>
            jsonb_build_object(
              'bridge', 'round_terminal_game_objective',
              'bridge_version', '1.0.0',
              'binding_code', 'WF_LOYALTY_LEAGUE_FIRST_ROUND',
              'achievement_certification_id', v_first_round_achievement.id,
              'commercial_activation_required', true
            )
        );

        v_loyalty_dispatch_attempts := v_loyalty_dispatch_attempts + 1;
      end if;
    end loop;
  end if;

  -- Targeted profile fan-out + immediate canonical ready-step enqueue.
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
        p_league_member_id => v_member.league_member_id,
        p_correlation_id => v_workflow.correlation_id,
        p_causation_id => v_workflow.id,
        p_metadata =>
          jsonb_build_object(
            'source', 'round_terminal_game_objectives',
            'source_workflow_id', v_workflow.id,
            'round_certification_id', v_certification.id,
            'league_round_id', v_round.id,
            'league_round_number', v_round.league_round_number
          )
      );

    v_profile_workflow_attempts := v_profile_workflow_attempts + 1;

    if coalesce((v_profile_workflow ->> 'eligible')::boolean, true) then
      v_profile_workflow_eligible_members :=
        v_profile_workflow_eligible_members + 1;
    end if;

    v_profile_workflow_id :=
      nullif(v_profile_workflow ->> 'workflow_id', '')::uuid;

    if v_profile_workflow_id is null then
      raise exception using
        errcode = 'P0001',
        message = 'R54_PROFILE_WORKFLOW_ID_MISSING';
    end if;

    v_profile_enqueue_calls := v_profile_enqueue_calls + 1;

    for v_profile_enqueue in
      select *
      from public.enqueue_ready_live_runtime_workflow_steps_rpc(
        p_workflow_id => v_profile_workflow_id,
        p_limit => 25
      )
    loop
      v_profile_enqueued_steps := v_profile_enqueued_steps + 1;
    end loop;
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
    'first_round_achievement_created', v_first_round_certified,
    'first_round_achievement_duplicate', v_first_round_duplicates,
    'loyalty_dispatch_attempts', v_loyalty_dispatch_attempts,
    'profile_workflow_attempts', v_profile_workflow_attempts,
    'profile_workflow_eligible_members', v_profile_workflow_eligible_members,
    'profile_enqueue_calls', v_profile_enqueue_calls,
    'profile_enqueued_steps', v_profile_enqueued_steps
  );
end;
$function$;

revoke all on function public.materialize_round_terminal_game_objectives_internal(uuid)
from public;

grant execute on function public.materialize_round_terminal_game_objectives_internal(uuid)
to service_role;