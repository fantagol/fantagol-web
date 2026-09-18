-- ============================================================================
-- FANTAGOL
-- Admin Governance Deferred Certification Evaluation
--
-- ROOT CAUSE
-- ----------
-- evaluate_admin_activity_after_round_certification was an immediate
-- AFTER INSERT / UPDATE trigger on round_certifications.
--
-- certify_round materializes:
--
--   1. round_certifications
--   2. round_certification_matches
--   3. round_certification_predictions
--   4. round_certification_results
--
-- The governance trigger therefore evaluated the parent certification before
-- round_certification_predictions existed.
--
-- A valid admin with a complete prediction submission could consequently be
-- persisted as:
--
--   certified_prediction_row_count = 0
--   admin_submission_complete       = false
--
-- FIX
-- ---
-- 1. Preserve evaluate_league_admin_activity_rpc as canonical authority.
-- 2. Replace the immediate trigger with a DEFERRABLE / INITIALLY DEFERRED
--    constraint trigger.
-- 3. At deferred execution time re-read current certification authority.
-- 4. Require a physically complete admin certification snapshot before
--    governance evaluation.
-- 5. Treat zero/partial physical coverage as "not ready", never as inactivity.
--
-- Genuine missing predictions remain detectable because certify_round writes
-- explicit round_certification_predictions rows whose prediction_id and
-- prediction_version are NULL.
--
-- HISTORICAL EFFECTS
-- ------------------
-- This migration intentionally does NOT reconcile existing governance state,
-- roles, evaluations or events.
-- ============================================================================

begin;

create or replace function public.trigger_evaluate_league_admin_activity()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $function$
declare
  v_current_status text;
  v_current_active boolean;
  v_league_id uuid;

  v_admin_member_id uuid;

  v_expected_match_count integer := 0;
  v_admin_prediction_row_count integer := 0;
begin
  -- ------------------------------------------------------------------------
  -- UPDATE events that do not change the certification authority fields
  -- cannot create a new governance evaluation.
  --
  -- Keep OLD access strictly inside the UPDATE branch.
  -- ------------------------------------------------------------------------

  if tg_op = 'UPDATE' then
    if old.status is not distinct from new.status
       and old.active is not distinct from new.active
    then
      return new;
    end if;
  end if;

  -- ------------------------------------------------------------------------
  -- This trigger is deferred. Always re-read the CURRENT row instead of
  -- trusting the event-time NEW image.
  --
  -- This also handles a certification that was inserted active/official and
  -- then superseded later in the same transaction.
  -- ------------------------------------------------------------------------

  select
    rc.status,
    rc.active,
    lr.league_id
  into
    v_current_status,
    v_current_active,
    v_league_id
  from public.round_certifications rc
  join public.league_rounds lr
    on lr.id = rc.league_round_id
  where rc.id = new.id;

  if not found then
    return new;
  end if;

  -- Existing governance RPC accepts only the active official certification.
  if v_current_status <> 'official'
     or v_current_active is distinct from true
  then
    return new;
  end if;

  -- ------------------------------------------------------------------------
  -- Resolve canonical current active league admin using the same ordering
  -- contract used by the governance engine.
  -- ------------------------------------------------------------------------

  select lm.id
  into v_admin_member_id
  from public.league_members lm
  where lm.league_id = v_league_id
    and lm.role = 'admin'
    and lm.status = 'active'
  order by lm.joined_at, lm.id
  limit 1;

  -- Preserve existing invariant behavior. If there is no active admin, the
  -- canonical RPC remains responsible for raising the governed error.
  if v_admin_member_id is null then
    perform public.evaluate_league_admin_activity_rpc(new.id);
    return new;
  end if;

  -- ------------------------------------------------------------------------
  -- PHYSICAL CERTIFICATION READINESS
  --
  -- expected:
  --   all included matches physically materialized for this certification.
  --
  -- actual:
  --   all corresponding certification prediction rows physically present for
  --   the current admin.
  --
  -- IMPORTANT:
  -- A genuine missing prediction still has a physical RCP row. Its
  -- prediction_id / prediction_version are NULL and the canonical governance
  -- RPC will correctly classify that completed snapshot as incomplete.
  --
  -- Zero rows or partial row coverage instead means the certification
  -- snapshot is not physically ready and MUST NOT count as inactivity.
  -- ------------------------------------------------------------------------

  select count(*)::integer
  into v_expected_match_count
  from public.round_certification_matches rcm
  where rcm.certification_id = new.id
    and rcm.included = true;

  select count(*)::integer
  into v_admin_prediction_row_count
  from public.round_certification_predictions rcp
  join public.round_certification_matches rcm
    on rcm.certification_id = rcp.certification_id
   and rcm.match_id = rcp.match_id
  where rcp.certification_id = new.id
    and rcp.league_member_id = v_admin_member_id
    and rcm.included = true;

  if v_expected_match_count <= 0 then
    return new;
  end if;

  if v_admin_prediction_row_count <> v_expected_match_count then
    return new;
  end if;

  -- ------------------------------------------------------------------------
  -- Canonical business authority.
  -- ------------------------------------------------------------------------

  perform public.evaluate_league_admin_activity_rpc(new.id);

  return new;
end;
$function$;

drop trigger if exists evaluate_admin_activity_after_round_certification
  on public.round_certifications;

create constraint trigger evaluate_admin_activity_after_round_certification
after insert or update
on public.round_certifications
deferrable initially deferred
for each row
execute function public.trigger_evaluate_league_admin_activity();

comment on function public.trigger_evaluate_league_admin_activity() is
'Deferred Round Certification governance hook. Re-evaluates current certification authority at transaction end and invokes evaluate_league_admin_activity_rpc only after the current admin certification prediction snapshot has complete physical coverage. Zero or partial physical coverage is treated as certification-not-ready and never as admin inactivity.';

commit;