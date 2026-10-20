-- MIGRATION 346: COMMUNITY LOCK SNAPSHOT TRANSITION GUARD
-- R13 functional canary and R14-R3 two-execution rollback canary passed.
-- This migration is STAGED FOR REVIEW ONLY; production application requires separate authorization.
-- Recognizes only the certified prior guard or exact corrected definition.
-- Preserves immutable/append-only protections and production drift rejection.
DO $r14_guard_preflight$
DECLARE
    v_definition text;
    v_original_hash constant text := 'f3d269e11f9df64f6a912b5627bd6527';
    v_original_clause constant text := $r14_original$    if old.status = 'building' and new.status not in ('building','ready','failed') then$r14_original$;
    v_corrected_clause constant text := $r14_corrected$    if old.status = 'building'
       and new.status not in ('building','ready','failed')
       and not (
           old.phase = 'lock'
           and new.phase = 'lock'
           and new.status = 'frozen'
       ) then$r14_corrected$;
BEGIN
    SELECT pg_get_functiondef('public.guard_community_snapshot_update()'::regprocedure)
      INTO v_definition;

    IF md5(v_definition) = v_original_hash THEN
        RAISE NOTICE 'R14_CERTIFIED_ORIGINAL_GUARD';
    ELSIF strpos(v_definition, v_corrected_clause) > 0
      AND md5(replace(v_definition, v_corrected_clause, v_original_clause)) = v_original_hash THEN
        RAISE NOTICE 'R14_CERTIFIED_ALREADY_CORRECTED_GUARD';
    ELSE
        RAISE EXCEPTION 'R14_GUARD_PRODUCTION_DRIFT: %', md5(v_definition);
    END IF;
END
$r14_guard_preflight$;

create or replace function public.guard_community_snapshot_update()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
    if tg_op = 'DELETE' then
        raise exception using
            errcode = '55000',
            message = 'COMMUNITY_SNAPSHOT_APPEND_ONLY';
    end if;

    if old.status in ('ready','frozen','archived') then
        if old.status = 'ready'
           and new.status in ('frozen','archived')
           and new.fantagol_round_id = old.fantagol_round_id
           and new.snapshot_version = old.snapshot_version
           and new.phase = old.phase
           and new.source_prediction_count = old.source_prediction_count
           and new.source_member_count = old.source_member_count
           and new.source_league_count = old.source_league_count
           and new.source_match_count = old.source_match_count
           and new.eligible_prediction_count = old.eligible_prediction_count
           and new.excluded_prediction_count = old.excluded_prediction_count
           and new.quality_status = old.quality_status
           and new.quality_score = old.quality_score
           and new.minimum_sample_satisfied = old.minimum_sample_satisfied
           and new.input_hash = old.input_hash
           and new.output_hash = old.output_hash
           and new.engine_version = old.engine_version
           and new.snapshot_schema_version = old.snapshot_schema_version
           and new.requested_at = old.requested_at
           and new.built_at = old.built_at
           and new.metadata = old.metadata then
            return new;
        end if;

        raise exception using
            errcode = '55000',
            message = 'COMMUNITY_SNAPSHOT_IMMUTABLE';
    end if;

    if old.status = 'building'
       and new.status not in ('building','ready','failed')
       and not (
           old.phase = 'lock'
           and new.phase = 'lock'
           and new.status = 'frozen'
       ) then
        raise exception using
            errcode = '55000',
            message = 'COMMUNITY_SNAPSHOT_INVALID_TRANSITION';
    end if;

    return new;
end;
$$;
