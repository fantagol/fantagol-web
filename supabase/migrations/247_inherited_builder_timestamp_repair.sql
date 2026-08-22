-- =====================================================================
-- FANTAGOL
-- Migration 247
-- Inherited simulation builder timestamp repair
--
-- Context:
-- Derived preview simulations register already-completed builder
-- dependencies inherited from source simulations.
--
-- Historical valid contract:
--   created_at = inherited started_at
--   started_at = inherited source timestamp
--
-- Current derived RPCs preserve started_at from the source but let the
-- new row default created_at to now(), causing:
--
--   started_at < created_at
--
-- and violating:
--   round_simulation_builder_runs_dates_check
--
-- This trigger normalizes ONLY explicitly inherited builder rows.
-- Executed builders remain completely untouched.
-- =====================================================================

create or replace function public.normalize_inherited_builder_run_timestamp_internal()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $function$
begin
    /*
     * Only inheritance registry rows participate.
     *
     * metadata.inherited is part of the explicit builder inheritance
     * contract used by Fantacalcio, One-to-One and Standings Preview.
     */
    if coalesce(
        lower(new.metadata ->> 'inherited') = 'true',
        false
    )
    and new.started_at is not null
    and (
        new.created_at is null
        or new.started_at < new.created_at
    )
    then
        new.created_at := new.started_at;
    end if;

    return new;
end;
$function$;

drop trigger if exists
    normalize_inherited_builder_run_timestamp_trg
on public.round_simulation_builder_runs;

create trigger normalize_inherited_builder_run_timestamp_trg
before insert
on public.round_simulation_builder_runs
for each row
execute function public.normalize_inherited_builder_run_timestamp_internal();

comment on function public.normalize_inherited_builder_run_timestamp_internal() is
'Normalizes created_at to inherited started_at only for round_simulation_builder_runs rows explicitly marked metadata.inherited=true. Preserves the builder run dates constraint and leaves executed builders untouched.';

comment on trigger normalize_inherited_builder_run_timestamp_trg
on public.round_simulation_builder_runs is
'Preserves historical timestamp semantics for inherited simulation builder registry rows before the dates constraint is evaluated.';