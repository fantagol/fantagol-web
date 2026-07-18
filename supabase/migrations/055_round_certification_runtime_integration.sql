-- ============================================================================
-- FANTAGOL
-- Migration 055: Round Certification Runtime Integration
--
-- Scope:
-- - extend the persistent Live Runtime queue with round certification jobs;
-- - preserve every previously admitted job type;
-- - allow the application Runtime to orchestrate readiness and certification
--   through the command RPCs introduced by migration 054.
--
-- No new scope type is required: both jobs use league_round scope.
-- ============================================================================

begin;

do $migration$
declare
  v_constraint_name text := 'live_runtime_jobs_type_check';
  v_definition text;
  v_values text;
  v_sql text;
begin
  select pg_get_constraintdef(c.oid)
    into v_definition
  from pg_constraint c
  join pg_class t
    on t.oid = c.conrelid
  join pg_namespace n
    on n.oid = t.relnamespace
  where n.nspname = 'public'
    and t.relname = 'live_runtime_jobs'
    and c.conname = v_constraint_name
    and c.contype = 'c';

  if v_definition is null then
    raise exception using
      errcode = 'P0001',
      message = 'LIVE_RUNTIME_JOB_TYPE_CONSTRAINT_NOT_FOUND';
  end if;

  select string_agg(
    format('%L', x.value),
    ', '
    order by x.value
  )
  into v_values
  from (
    select distinct m[1] as value
    from regexp_matches(
      v_definition,
      '''([^'']+)''',
      'g'
    ) as m

    union

    select 'evaluate_round_certification_readiness'

    union

    select 'certify_round'
  ) x;

  execute
    'alter table public.live_runtime_jobs drop constraint '
    || quote_ident(v_constraint_name);

  v_sql :=
    'alter table public.live_runtime_jobs add constraint '
    || quote_ident(v_constraint_name)
    || ' check (job_type in ('
    || v_values
    || '))';

  execute v_sql;
end
$migration$;

comment on constraint live_runtime_jobs_type_check
on public.live_runtime_jobs is
'Allowed persistent Live Runtime job types, including Match Result and League Round certification workflows.';

commit;
