-- ============================================================================
-- FANTAGOL
-- Migration 268: League Governance league_id Ambiguity Hardening
--
-- Purpose:
--   Remove PL/pgSQL league_id ambiguity from
--   evaluate_league_admin_activity_rpc.
--
-- Repairs:
--   1. ON CONFLICT (league_id)
--      -> ON CONFLICT ON CONSTRAINT league_governance_states_pkey
--
--   2. Five league_governance_states UPDATE predicates
--      -> league_governance_states.league_id
--
--   3. One league_members UPDATE predicate
--      -> league_members.league_id
--
-- Root cause:
--   RETURNS TABLE exposes league_id as a PL/pgSQL output variable,
--   making unqualified SQL references ambiguous.
--
-- Safety:
--   - qualification only;
--   - no behavioral or policy change;
--   - no table/schema mutation;
--   - no publication/job activity.
-- ============================================================================
CREATE OR REPLACE FUNCTION public.evaluate_league_admin_activity_rpc(target_certification_id uuid)
 RETURNS TABLE(league_id uuid, league_round_id uuid, evaluated_admin_member_id uuid, submission_complete boolean, consecutive_missed_rounds integer, succession_status text, successor_member_id uuid, succession_method text)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_certification public.round_certifications%rowtype;
  v_round public.league_rounds%rowtype;
  v_admin public.league_members%rowtype;
  v_state public.league_governance_states%rowtype;

  v_submission_row_count integer := 0;
  v_submission_complete boolean := false;
  v_previous_missed integer := 0;
  v_resulting_missed integer := 0;

  v_successor public.league_members%rowtype;
  v_successor_method text;
  v_has_official_ranking boolean := false;
  v_status text := 'evaluated';
begin
  select rc.*
  into v_certification
  from public.round_certifications rc
  where rc.id = target_certification_id
    and rc.status = 'official'
    and rc.active = true
  for update;

  if v_certification.id is null then
    raise exception using
      errcode = 'P0001',
      message = 'ACTIVE_OFFICIAL_ROUND_CERTIFICATION_REQUIRED';
  end if;

  select lr.*
  into v_round
  from public.league_rounds lr
  where lr.id = v_certification.league_round_id
  for update;

  if v_round.id is null then
    raise exception using errcode = 'P0001', message = 'LEAGUE_ROUND_NOT_FOUND';
  end if;

  -- Idempotency: one certified evaluation per League Round.
  if exists (
    select 1
    from public.league_admin_activity_evaluations e
    where e.league_round_id = v_round.id
  ) then
    return query
    select
      e.league_id,
      e.league_round_id,
      e.evaluated_admin_member_id,
      e.admin_submission_complete,
      e.resulting_consecutive_missed_rounds,
      e.evaluation_status,
      e.successor_member_id,
      e.succession_method
    from public.league_admin_activity_evaluations e
    where e.league_round_id = v_round.id
    limit 1;

    return;
  end if;

  perform 1
  from public.leagues l
  where l.id = v_round.league_id
  for update;

  select lm.*
  into v_admin
  from public.league_members lm
  where lm.league_id = v_round.league_id
    and lm.role = 'admin'
    and lm.status = 'active'
  order by lm.joined_at, lm.id
  limit 1
  for update;

  if v_admin.id is null then
    raise exception using
      errcode = 'P0001',
      message = 'ACTIVE_LEAGUE_ADMIN_NOT_FOUND';
  end if;

  insert into public.league_governance_states (
    league_id,
    current_admin_member_id,
    consecutive_admin_missed_rounds
  )
  values (
    v_round.league_id,
    v_admin.id,
    0
  )
  on conflict on constraint league_governance_states_pkey do nothing;

  select lgs.*
  into v_state
  from public.league_governance_states lgs
  where lgs.league_id = v_round.league_id
  for update;

  -- A new Admin always starts from a clean inactivity sequence.
  if v_state.current_admin_member_id is distinct from v_admin.id then
    v_previous_missed := 0;

    update public.league_governance_states
    set
      current_admin_member_id = v_admin.id,
      consecutive_admin_missed_rounds = 0,
      warning_issued_at = null,
      succession_blocked_at = null,
      succession_blocked_reason = null
    where league_governance_states.league_id = v_round.league_id;
  else
    v_previous_missed := v_state.consecutive_admin_missed_rounds;
  end if;

  select
    count(*)::integer,
    coalesce(
      bool_and(
        rcp.prediction_id is not null
        and rcp.prediction_version is not null
      ),
      false
    )
  into
    v_submission_row_count,
    v_submission_complete
  from public.round_certification_predictions rcp
  where rcp.certification_id = v_certification.id
    and rcp.league_member_id = v_admin.id;

  v_submission_complete :=
    v_submission_row_count > 0
    and v_submission_complete;

  if v_submission_complete then
    v_resulting_missed := 0;
    v_status := 'evaluated';

    update public.league_governance_states
    set
      current_admin_member_id = v_admin.id,
      consecutive_admin_missed_rounds = 0,
      last_evaluated_league_round_id = v_round.id,
      last_evaluated_certification_id = v_certification.id,
      last_admin_submission_complete = true,
      warning_issued_at = null,
      succession_blocked_at = null,
      succession_blocked_reason = null
    where league_governance_states.league_id = v_round.league_id;

  else
    v_resulting_missed := v_previous_missed + 1;

    if v_resulting_missed = 1 then
      v_status := 'warning_issued';

      update public.league_governance_states
      set
        current_admin_member_id = v_admin.id,
        consecutive_admin_missed_rounds = 1,
        last_evaluated_league_round_id = v_round.id,
        last_evaluated_certification_id = v_certification.id,
        last_admin_submission_complete = false,
        warning_issued_at = now(),
        succession_blocked_at = null,
        succession_blocked_reason = null
      where league_governance_states.league_id = v_round.league_id;

      perform public.write_league_admin_event(
        v_round.league_id,
        null,
        null,
        'system',
        'admin_inactivity_warning',
        v_admin.id,
        v_round.id,
        jsonb_build_object(
          'certification_id', v_certification.id,
          'consecutive_missed_rounds', 1,
          'threshold', 2,
          'submission_definition', 'complete_official_prediction_snapshot',
          'next_consecutive_miss_causes_succession', true
        )
      );

    else
      -- ----------------------------------------------------------------------
      -- Successor selection 1: eligible active Vice.
      -- ----------------------------------------------------------------------

      select lm.*
      into v_successor
      from public.league_members lm
      where lm.league_id = v_round.league_id
        and lm.id <> v_admin.id
        and lm.role = 'vice'
        and lm.status = 'active'
        and lm.user_id is not null
        and exists (
          select 1
          from auth.users au
          where au.id = lm.user_id
        )
      order by lm.joined_at, lm.id
      limit 1
      for update;

      if v_successor.id is not null then
        v_successor_method := 'vice';
      else
        -- --------------------------------------------------------------------
        -- Successor selection 2: current certified Points Pure ranking.
        -- Tie-break: exact count, League seniority, membership UUID.
        -- --------------------------------------------------------------------

        select exists (
          select 1
          from public.round_certification_results rcr
          join public.round_certifications rc
            on rc.id = rcr.certification_id
          join public.league_rounds lr
            on lr.id = rc.league_round_id
          where lr.league_id = v_round.league_id
            and rc.status = 'official'
            and rc.active = true
        )
        into v_has_official_ranking;

        if v_has_official_ranking then
          select lm.*
          into v_successor
          from public.league_members lm
          left join lateral (
            select
              coalesce(sum(rcr.pure_points), 0) as cumulative_points,
              coalesce(sum(rcr.exact_count), 0) as cumulative_exact
            from public.round_certification_results rcr
            join public.round_certifications rc
              on rc.id = rcr.certification_id
            join public.league_rounds lr
              on lr.id = rc.league_round_id
            where lr.league_id = v_round.league_id
              and rc.status = 'official'
              and rc.active = true
              and rcr.league_member_id = lm.id
          ) ranking on true
          where lm.league_id = v_round.league_id
            and lm.id <> v_admin.id
            and lm.status = 'active'
            and lm.user_id is not null
            and exists (
              select 1
              from auth.users au
              where au.id = lm.user_id
            )
          order by
            ranking.cumulative_points desc,
            ranking.cumulative_exact desc,
            lm.joined_at,
            lm.id
          limit 1
          for update;

          if v_successor.id is not null then
            v_successor_method := 'ranking';
          end if;
        end if;

        -- --------------------------------------------------------------------
        -- Successor selection 3: League seniority.
        -- --------------------------------------------------------------------

        if v_successor.id is null then
          select lm.*
          into v_successor
          from public.league_members lm
          where lm.league_id = v_round.league_id
            and lm.id <> v_admin.id
            and lm.status = 'active'
            and lm.user_id is not null
            and exists (
              select 1
              from auth.users au
              where au.id = lm.user_id
            )
          order by lm.joined_at, lm.id
          limit 1
          for update;

          if v_successor.id is not null then
            v_successor_method := 'seniority';
          end if;
        end if;
      end if;

      if v_successor.id is null then
        -- Never leave the League without an Admin.
        -- The old Admin remains in office and succession is retried at the next
        -- official certification.
        v_status := 'succession_blocked';

        update public.league_governance_states
        set
          current_admin_member_id = v_admin.id,
          consecutive_admin_missed_rounds = v_resulting_missed,
          last_evaluated_league_round_id = v_round.id,
          last_evaluated_certification_id = v_certification.id,
          last_admin_submission_complete = false,
          succession_blocked_at = now(),
          succession_blocked_reason = 'NO_ELIGIBLE_SUCCESSOR'
        where league_governance_states.league_id = v_round.league_id;

        perform public.write_league_admin_event(
          v_round.league_id,
          null,
          null,
          'system',
          'admin_succession_blocked',
          v_admin.id,
          v_round.id,
          jsonb_build_object(
            'certification_id', v_certification.id,
            'consecutive_missed_rounds', v_resulting_missed,
            'reason', 'NO_ELIGIBLE_SUCCESSOR',
            'admin_preserved_to_prevent_governance_vacuum', true,
            'retry_on_next_certified_round', true
          )
        );

      else
        v_status := 'succession_completed';

        update public.league_members
        set role = 'member'
        where id = v_admin.id;

        update public.league_members
        set role = 'admin'
        where id = v_successor.id;

        -- Defensive normalization: no active Vice remains after a non-Vice
        -- fallback unless explicitly reassigned later by the new Admin.
        if v_successor_method <> 'vice' then
          update public.league_members
          set role = 'member'
          where league_members.league_id = v_round.league_id
            and role = 'vice'
            and status = 'active';
        end if;

        update public.league_governance_states
        set
          current_admin_member_id = v_successor.id,
          consecutive_admin_missed_rounds = 0,
          last_evaluated_league_round_id = v_round.id,
          last_evaluated_certification_id = v_certification.id,
          last_admin_submission_complete = false,
          warning_issued_at = null,
          succession_completed_at = now(),
          succession_blocked_at = null,
          succession_blocked_reason = null
        where league_governance_states.league_id = v_round.league_id;

        perform public.write_league_admin_event(
          v_round.league_id,
          null,
          null,
          'system',
          'admin_demoted_for_inactivity',
          v_admin.id,
          v_round.id,
          jsonb_build_object(
            'certification_id', v_certification.id,
            'consecutive_missed_rounds', v_resulting_missed,
            'threshold', 2,
            'new_role', 'member',
            'successor_member_id', v_successor.id,
            'succession_method', v_successor_method
          )
        );

        if v_successor_method = 'vice' then
          perform public.write_league_admin_event(
            v_round.league_id,
            null,
            null,
            'system',
            'vice_promoted_to_admin',
            v_successor.id,
            v_round.id,
            jsonb_build_object(
              'former_admin_member_id', v_admin.id,
              'certification_id', v_certification.id,
              'reason', 'automatic_inactivity_succession'
            )
          );
        elsif v_successor_method = 'ranking' then
          perform public.write_league_admin_event(
            v_round.league_id,
            null,
            null,
            'system',
            'admin_assigned_from_ranking',
            v_successor.id,
            v_round.id,
            jsonb_build_object(
              'former_admin_member_id', v_admin.id,
              'certification_id', v_certification.id,
              'ranking', 'certified_points_pure',
              'tie_break_1', 'certified_exact_count',
              'tie_break_2', 'joined_at',
              'tie_break_3', 'membership_id'
            )
          );
        else
          perform public.write_league_admin_event(
            v_round.league_id,
            null,
            null,
            'system',
            'admin_assigned_by_seniority',
            v_successor.id,
            v_round.id,
            jsonb_build_object(
              'former_admin_member_id', v_admin.id,
              'certification_id', v_certification.id,
              'tie_break_1', 'joined_at',
              'tie_break_2', 'membership_id'
            )
          );
        end if;
      end if;
    end if;
  end if;

  insert into public.league_admin_activity_evaluations (
    league_id,
    league_round_id,
    certification_id,
    evaluated_admin_member_id,
    admin_submission_complete,
    previous_consecutive_missed_rounds,
    resulting_consecutive_missed_rounds,
    succession_required,
    successor_member_id,
    succession_method,
    evaluation_status,
    details
  )
  values (
    v_round.league_id,
    v_round.id,
    v_certification.id,
    v_admin.id,
    v_submission_complete,
    v_previous_missed,
    v_resulting_missed,
    (not v_submission_complete and v_resulting_missed >= 2),
    v_successor.id,
    v_successor_method,
    v_status,
    jsonb_build_object(
      'certified_prediction_row_count', v_submission_row_count,
      'submission_definition', 'all_certified_rows_have_prediction_id_and_version',
      'former_admin_retained_membership', true,
      'league_always_has_admin', true
    )
  );

  return query
  select
    v_round.league_id,
    v_round.id,
    v_admin.id,
    v_submission_complete,
    v_resulting_missed,
    v_status,
    v_successor.id,
    v_successor_method;
end;
$function$;
