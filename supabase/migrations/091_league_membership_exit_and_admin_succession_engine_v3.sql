-- ============================================================================
-- FANTAGOL
-- Migration 091
-- League Membership Exit and Automatic Admin Succession Engine
--
-- Completes the League Governance Engine with:
--   * voluntary admin resignation in favour of the active Vice
--   * certified per-round admin activity ledger
--   * first missed-round warning
--   * automatic succession after two consecutive complete-submission misses
--   * Vice-first succession
--   * deterministic ranking/seniority fallback
--   * automatic evaluation after an official Round Certification
--
-- Existing contract intentionally reused:
--   * leave_league_rpc(uuid)
--   * write_league_admin_event(...)
--   * round_certifications
--   * round_certification_predictions
--   * round_certification_results
-- ============================================================================

begin;

-- ============================================================================
-- 1. Extend the governance event vocabulary.
-- ============================================================================

alter table public.league_admin_events
  drop constraint if exists league_admin_events_action_type_check;

alter table public.league_admin_events
  add constraint league_admin_events_action_type_check
  check (
    action_type = any (array[
      'league_created'::text,
      'member_joined'::text,
      'member_rejoined'::text,
      'roster_locked'::text,
      'roster_reopened'::text,
      'league_started'::text,
      'league_archived'::text,
      'vice_assigned'::text,
      'vice_revoked'::text,
      'admin_resigned'::text,
      'admin_inactivity_warning'::text,
      'admin_demoted_for_inactivity'::text,
      'vice_promoted_to_admin'::text,
      'admin_assigned_from_ranking'::text,
      'admin_assigned_by_seniority'::text,
      'admin_succession_blocked'::text,
      'member_removed'::text,
      'member_reinstated'::text,
      'member_withdrawn'::text,
      'league_schedules_generated'::text,
      'league_schedules_regenerated'::text,
      'league_schedules_preserved'::text,
      'league_schedules_locked'::text,
      'prediction_recovery_opened'::text,
      'prediction_recovery_used'::text,
      'prediction_recovery_revoked'::text,
      'prediction_recovery_expired'::text,
      'postponed_match_detected'::text,
      'postponed_match_reopened'::text,
      'postponed_match_excluded'::text,
      'calculation_preview_created'::text,
      'calculation_preview_failed'::text,
      'round_certification_committed'::text,
      'round_certification_superseded'::text,
      'scoring_profile_changed'::text,
      'league_settings_changed'::text
    ])
  );

-- ============================================================================
-- 2. Current governance state.
-- One row per League, kept for O(1) activity evaluation.
-- ============================================================================

create table if not exists public.league_governance_states (
  league_id uuid primary key
    references public.leagues(id)
    on delete cascade,

  current_admin_member_id uuid
    references public.league_members(id)
    on delete set null,

  consecutive_admin_missed_rounds integer not null default 0,

  last_evaluated_league_round_id uuid
    references public.league_rounds(id)
    on delete set null,

  last_evaluated_certification_id uuid
    references public.round_certifications(id)
    on delete set null,

  last_admin_submission_complete boolean,

  warning_issued_at timestamptz,
  succession_completed_at timestamptz,
  succession_blocked_at timestamptz,
  succession_blocked_reason text,

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint league_governance_states_missed_rounds_check
    check (consecutive_admin_missed_rounds >= 0)
);

create index if not exists league_governance_states_admin_idx
  on public.league_governance_states(current_admin_member_id);

create index if not exists league_governance_states_last_round_idx
  on public.league_governance_states(last_evaluated_league_round_id);

-- ============================================================================
-- 3. Immutable per-round governance evaluation ledger.
-- Prevents duplicate evaluation and provides a certified audit trail.
-- ============================================================================

create table if not exists public.league_admin_activity_evaluations (
  id uuid primary key default gen_random_uuid(),

  league_id uuid not null
    references public.leagues(id)
    on delete cascade,

  league_round_id uuid not null
    references public.league_rounds(id)
    on delete cascade,

  certification_id uuid not null
    references public.round_certifications(id)
    on delete cascade,

  evaluated_admin_member_id uuid not null
    references public.league_members(id)
    on delete restrict,

  admin_submission_complete boolean not null,
  previous_consecutive_missed_rounds integer not null,
  resulting_consecutive_missed_rounds integer not null,

  succession_required boolean not null default false,

  successor_member_id uuid
    references public.league_members(id)
    on delete set null,

  succession_method text,
  evaluation_status text not null default 'evaluated',
  details jsonb not null default '{}'::jsonb,

  evaluated_at timestamptz not null default now(),

  constraint league_admin_activity_evaluation_round_unique
    unique (league_round_id),

  constraint league_admin_activity_evaluation_certification_unique
    unique (certification_id),

  constraint league_admin_activity_evaluation_previous_check
    check (previous_consecutive_missed_rounds >= 0),

  constraint league_admin_activity_evaluation_resulting_check
    check (resulting_consecutive_missed_rounds >= 0),

  constraint league_admin_activity_evaluation_method_check
    check (
      succession_method is null
      or succession_method in ('vice', 'ranking', 'seniority')
    ),

  constraint league_admin_activity_evaluation_status_check
    check (
      evaluation_status in (
        'evaluated',
        'warning_issued',
        'succession_completed',
        'succession_blocked',
        'skipped'
      )
    )
);

create index if not exists league_admin_activity_eval_league_idx
  on public.league_admin_activity_evaluations(
    league_id,
    evaluated_at desc
  );

create index if not exists league_admin_activity_eval_admin_idx
  on public.league_admin_activity_evaluations(
    evaluated_admin_member_id,
    evaluated_at desc
  );

-- ============================================================================
-- 4. updated_at trigger for governance state.
-- ============================================================================

drop trigger if exists set_league_governance_states_updated_at
  on public.league_governance_states;

create trigger set_league_governance_states_updated_at
before update on public.league_governance_states
for each row
execute function public.set_updated_at();

-- ============================================================================
-- 5. RLS.
-- Public clients never write governance state or evaluation rows directly.
-- Active League members may read their League governance history.
-- ============================================================================

alter table public.league_governance_states enable row level security;
alter table public.league_admin_activity_evaluations enable row level security;

drop policy if exists league_governance_states_select_members
  on public.league_governance_states;

create policy league_governance_states_select_members
on public.league_governance_states
for select
to authenticated
using (
  exists (
    select 1
    from public.league_members lm
    where lm.league_id = league_governance_states.league_id
      and lm.user_id = auth.uid()
      and lm.status = 'active'
  )
);

drop policy if exists league_admin_activity_eval_select_members
  on public.league_admin_activity_evaluations;

create policy league_admin_activity_eval_select_members
on public.league_admin_activity_evaluations
for select
to authenticated
using (
  exists (
    select 1
    from public.league_members lm
    where lm.league_id = league_admin_activity_evaluations.league_id
      and lm.user_id = auth.uid()
      and lm.status = 'active'
  )
);

-- ============================================================================
-- 6. Seed current governance state for existing Leagues.
-- ============================================================================

insert into public.league_governance_states (
  league_id,
  current_admin_member_id,
  consecutive_admin_missed_rounds
)
select
  l.id,
  admin_member.id,
  0
from public.leagues l
left join lateral (
  select lm.id
  from public.league_members lm
  where lm.league_id = l.id
    and lm.role = 'admin'
    and lm.status = 'active'
  order by lm.joined_at, lm.id
  limit 1
) admin_member on true
on conflict (league_id) do update
set current_admin_member_id =
  coalesce(
    excluded.current_admin_member_id,
    public.league_governance_states.current_admin_member_id
  );

-- ============================================================================
-- 7. Voluntary Admin resignation.
--
-- Rules:
--   * authenticated active Admin only
--   * an eligible active Vice must exist
--   * Vice becomes Admin atomically
--   * former Admin remains an active ordinary member
--   * former Admin may subsequently call existing leave_league_rpc()
-- ============================================================================

create or replace function public.resign_league_admin_rpc(
  target_league_id uuid
)
returns table(
  former_admin_member_id uuid,
  new_admin_member_id uuid
)
language plpgsql
security definer
set search_path = public, pg_temp
as $function$
declare
  v_user_id uuid := auth.uid();
  v_admin public.league_members%rowtype;
  v_vice public.league_members%rowtype;
begin
  if v_user_id is null then
    raise exception using errcode = 'P0001', message = 'AUTH_REQUIRED';
  end if;

  perform 1
  from public.leagues l
  where l.id = target_league_id
    and l.lifecycle_status not in ('completed', 'archived')
  for update;

  if not found then
    raise exception using errcode = 'P0001', message = 'LEAGUE_NOT_EDITABLE';
  end if;

  select lm.*
  into v_admin
  from public.league_members lm
  where lm.league_id = target_league_id
    and lm.user_id = v_user_id
    and lm.role = 'admin'
    and lm.status = 'active'
  for update;

  if v_admin.id is null then
    raise exception using errcode = 'P0001', message = 'ACTIVE_ADMIN_REQUIRED';
  end if;

  select lm.*
  into v_vice
  from public.league_members lm
  where lm.league_id = target_league_id
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

  if v_vice.id is null then
    raise exception using errcode = 'P0001', message = 'ELIGIBLE_ACTIVE_VICE_REQUIRED';
  end if;

  update public.league_members
  set role = 'member'
  where id = v_admin.id;

  update public.league_members
  set role = 'admin'
  where id = v_vice.id;

  insert into public.league_governance_states (
    league_id,
    current_admin_member_id,
    consecutive_admin_missed_rounds,
    warning_issued_at,
    succession_completed_at,
    succession_blocked_at,
    succession_blocked_reason
  )
  values (
    target_league_id,
    v_vice.id,
    0,
    null,
    now(),
    null,
    null
  )
  on conflict (league_id) do update
  set
    current_admin_member_id = excluded.current_admin_member_id,
    consecutive_admin_missed_rounds = 0,
    warning_issued_at = null,
    succession_completed_at = now(),
    succession_blocked_at = null,
    succession_blocked_reason = null;

  perform public.write_league_admin_event(
    target_league_id,
    v_admin.id,
    v_user_id,
    'member',
    'admin_resigned',
    v_admin.id,
    null,
    jsonb_build_object(
      'new_admin_member_id', v_vice.id,
      'former_admin_new_role', 'member',
      'reason', 'voluntary_resignation'
    )
  );

  perform public.write_league_admin_event(
    target_league_id,
    v_admin.id,
    v_user_id,
    'member',
    'vice_promoted_to_admin',
    v_vice.id,
    null,
    jsonb_build_object(
      'former_admin_member_id', v_admin.id,
      'succession_method', 'vice',
      'reason', 'voluntary_admin_resignation'
    )
  );

  return query
  select v_admin.id, v_vice.id;
end;
$function$;

-- ============================================================================
-- 8. Certified Admin activity evaluation and succession.
--
-- A complete submission means:
--   * the official certification contains rows for the Admin
--   * every certified row has prediction_id and prediction_version
--
-- This deliberately does NOT use score, correctness or draft state.
-- ============================================================================

create or replace function public.evaluate_league_admin_activity_rpc(
  target_certification_id uuid
)
returns table(
  league_id uuid,
  league_round_id uuid,
  evaluated_admin_member_id uuid,
  submission_complete boolean,
  consecutive_missed_rounds integer,
  succession_status text,
  successor_member_id uuid,
  succession_method text
)
language plpgsql
security definer
set search_path = public, pg_temp
as $function$
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
  on conflict (league_id) do nothing;

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
    where league_id = v_round.league_id;
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
    where league_id = v_round.league_id;

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
      where league_id = v_round.league_id;

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
        where league_id = v_round.league_id;

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
          where league_id = v_round.league_id
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
        where league_id = v_round.league_id;

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

-- ============================================================================
-- 9. Automatic integration with official Round Certification.
-- ============================================================================

create or replace function public.trigger_evaluate_league_admin_activity()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $function$
begin
  if new.status = 'official'
     and new.active = true
     and (
       tg_op = 'INSERT'
       or old.status is distinct from new.status
       or old.active is distinct from new.active
     )
  then
    perform public.evaluate_league_admin_activity_rpc(new.id);
  end if;

  return new;
end;
$function$;

drop trigger if exists evaluate_admin_activity_after_round_certification
  on public.round_certifications;

create trigger evaluate_admin_activity_after_round_certification
after insert or update of status, active
on public.round_certifications
for each row
execute function public.trigger_evaluate_league_admin_activity();

-- ============================================================================
-- 10. Read model for the League Administration page.
-- ============================================================================

create or replace function public.get_league_governance_state_rpc(
  target_league_id uuid
)
returns table(
  league_id uuid,
  current_admin_member_id uuid,
  consecutive_admin_missed_rounds integer,
  last_evaluated_league_round_id uuid,
  last_admin_submission_complete boolean,
  warning_issued_at timestamptz,
  succession_completed_at timestamptz,
  succession_blocked_at timestamptz,
  succession_blocked_reason text
)
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $function$
declare
  v_user_id uuid := auth.uid();
begin
  if v_user_id is null then
    raise exception using errcode = 'P0001', message = 'AUTH_REQUIRED';
  end if;

  perform 1
  from public.league_members lm
  where lm.league_id = target_league_id
    and lm.user_id = v_user_id
    and lm.status = 'active';

  if not found then
    raise exception using
      errcode = 'P0001',
      message = 'ACTIVE_LEAGUE_MEMBER_REQUIRED';
  end if;

  return query
  select
    lgs.league_id,
    lgs.current_admin_member_id,
    lgs.consecutive_admin_missed_rounds,
    lgs.last_evaluated_league_round_id,
    lgs.last_admin_submission_complete,
    lgs.warning_issued_at,
    lgs.succession_completed_at,
    lgs.succession_blocked_at,
    lgs.succession_blocked_reason
  from public.league_governance_states lgs
  where lgs.league_id = target_league_id;
end;
$function$;

-- ============================================================================
-- 11. Privileges.
-- ============================================================================

revoke all on table public.league_governance_states
  from anon, authenticated;
revoke all on table public.league_admin_activity_evaluations
  from anon, authenticated;

grant select on table public.league_governance_states
  to authenticated;
grant select on table public.league_admin_activity_evaluations
  to authenticated;

revoke all on function public.resign_league_admin_rpc(uuid)
  from public, anon;
grant execute on function public.resign_league_admin_rpc(uuid)
  to authenticated;

revoke all on function public.evaluate_league_admin_activity_rpc(uuid)
  from public, anon, authenticated;
grant execute on function public.evaluate_league_admin_activity_rpc(uuid)
  to postgres, service_role;

revoke all on function public.trigger_evaluate_league_admin_activity()
  from public, anon, authenticated;

revoke all on function public.get_league_governance_state_rpc(uuid)
  from public, anon;
grant execute on function public.get_league_governance_state_rpc(uuid)
  to authenticated;

commit;
