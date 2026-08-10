begin;

-- =====================================================================
-- FANTAGOL - A8D.6.7E-R19
-- CALCULATION RUN DISCARD GOVERNANCE FOUNDATION
--
-- Purpose:
--   Formalize the already-supported `discarded` Calculation Run state.
--
-- Contract:
--   - no runtime artifact deletion
--   - no prediction mutation
--   - no Simulation mutation
--   - no Simulation Event mutation
--   - no certification mutation
--   - only an uncommitted, non-publishable runtime lineage may be discarded
--   - discard operation is idempotent
-- =====================================================================

alter table public.round_calculation_runs
  add column if not exists discarded_at timestamptz,
  add column if not exists discard_reason text,
  add column if not exists discard_correlation_id uuid;

alter table public.round_calculation_runs
  drop constraint if exists round_calculation_runs_discard_metadata_check;

alter table public.round_calculation_runs
  add constraint round_calculation_runs_discard_metadata_check
  check (
    (
      status = 'discarded'
      and discarded_at is not null
      and nullif(btrim(discard_reason), '') is not null
    )
    or
    (
      status <> 'discarded'
      and discarded_at is null
      and discard_reason is null
      and discard_correlation_id is null
    )
  );

comment on column public.round_calculation_runs.discarded_at is
'Timestamp at which an uncommitted Calculation Run was terminally discarded.';

comment on column public.round_calculation_runs.discard_reason is
'Mandatory governance reason for a Calculation Run transition to discarded.';

comment on column public.round_calculation_runs.discard_correlation_id is
'Optional correlation identifier for the governance operation that discarded the Calculation Run.';

create or replace function public.discard_round_calculation_run_internal(
  p_calculation_run_id uuid,
  p_reason text,
  p_correlation_id uuid default null
)
returns table (
  calculation_run_id uuid,
  league_round_id uuid,
  previous_status text,
  current_status text,
  discarded_at timestamptz,
  discard_reason text,
  discard_correlation_id uuid,
  changed boolean
)
language plpgsql
security definer
set search_path = public, pg_temp
as $function$
declare
  v_run public.round_calculation_runs%rowtype;
  v_previous_status text;
  v_now timestamptz := clock_timestamp();
begin
  if p_calculation_run_id is null then
    raise exception using
      errcode = '22004',
      message = 'CALCULATION_RUN_REQUIRED';
  end if;

  if nullif(btrim(p_reason), '') is null then
    raise exception using
      errcode = '22023',
      message = 'CALCULATION_RUN_DISCARD_REASON_REQUIRED';
  end if;

  select rcr.*
  into v_run
  from public.round_calculation_runs rcr
  where rcr.id = p_calculation_run_id
  for update;

  if not found then
    raise exception using
      errcode = 'P0001',
      message = 'CALCULATION_RUN_NOT_FOUND';
  end if;

  v_previous_status := v_run.status;

  -- ---------------------------------------------------------------
  -- Idempotent terminal fast path.
  -- ---------------------------------------------------------------

  if v_run.status = 'discarded' then
    return query
    select
      v_run.id,
      v_run.league_round_id,
      v_previous_status,
      v_run.status,
      v_run.discarded_at,
      v_run.discard_reason,
      v_run.discard_correlation_id,
      false;

    return;
  end if;

  -- ---------------------------------------------------------------
  -- Only non-authoritative runtime previews may be discarded.
  -- `building` must finish/fail first.
  -- `committed` is immutable official lineage.
  -- ---------------------------------------------------------------

  if v_run.status not in ('preview_ready', 'failed') then
    raise exception using
      errcode = 'P0001',
      message = 'CALCULATION_RUN_NOT_DISCARDABLE',
      detail = v_run.status;
  end if;

  if v_run.committed_certification_id is not null then
    raise exception using
      errcode = 'P0001',
      message = 'CALCULATION_RUN_ALREADY_COMMITTED';
  end if;

  -- ---------------------------------------------------------------
  -- No Certification may reference this run.
  -- ---------------------------------------------------------------

  if exists (
    select 1
    from public.round_certifications rc
    where rc.source_run_id = v_run.id
  ) then
    raise exception using
      errcode = 'P0001',
      message = 'CALCULATION_RUN_CERTIFICATION_EXISTS';
  end if;

  -- ---------------------------------------------------------------
  -- No publishable / certification-bound Simulation may survive.
  --
  -- Historical preview_invalidated / archived Simulations and their
  -- append-only Events remain untouched as audit lineage.
  -- ---------------------------------------------------------------

  if exists (
    select 1
    from public.round_simulations rs
    where rs.calculation_run_id = v_run.id
      and (
        rs.publishable = true
        or rs.certification_id is not null
        or rs.status in (
          'building',
          'preview_ready',
          'awaiting_certification',
          'certified'
        )
      )
  ) then
    raise exception using
      errcode = 'P0001',
      message = 'CALCULATION_RUN_ACTIVE_SIMULATION_EXISTS';
  end if;

  -- Any linked Simulation must already be terminally non-publishable.
  if exists (
    select 1
    from public.round_simulations rs
    where rs.calculation_run_id = v_run.id
      and rs.status not in (
        'preview_invalidated',
        'archived',
        'failed'
      )
  ) then
    raise exception using
      errcode = 'P0001',
      message = 'CALCULATION_RUN_SIMULATION_NOT_TERMINAL';
  end if;

  update public.round_calculation_runs rcr
  set
    status = 'discarded',
    discarded_at = v_now,
    discard_reason = btrim(p_reason),
    discard_correlation_id = p_correlation_id
  where rcr.id = v_run.id
  returning rcr.*
  into v_run;

  return query
  select
    v_run.id,
    v_run.league_round_id,
    v_previous_status,
    v_run.status,
    v_run.discarded_at,
    v_run.discard_reason,
    v_run.discard_correlation_id,
    true;
end;
$function$;

comment on function public.discard_round_calculation_run_internal(
  uuid,
  text,
  uuid
) is
'Terminal governance transition for an uncommitted Calculation Run. Preserves score results, Simulations and append-only Simulation Events as historical lineage.';

revoke all
on function public.discard_round_calculation_run_internal(
  uuid,
  text,
  uuid
)
from public, anon, authenticated;

grant execute
on function public.discard_round_calculation_run_internal(
  uuid,
  text,
  uuid
)
to service_role;

commit;