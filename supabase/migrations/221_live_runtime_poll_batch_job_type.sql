-- ============================================================================
-- FANTAGOL
-- Migration 221
-- Live Runtime poll_batch job type activation
--
-- Purpose:
--   Extend the existing persistent Live Runtime execution bus with the
--   aggregated Football Data polling job type.
--
-- Scope:
--   * vocabulary only
--   * no jobs created
--   * no provider execution
--   * no Match mutation
-- ============================================================================

begin;

do $extend_live_runtime_job_types$
declare
  v_definition text;
  v_values text;
begin
  select pg_get_constraintdef(c.oid)
  into v_definition
  from pg_constraint c
  where c.conrelid =
        'public.live_runtime_jobs'::regclass
    and c.conname =
        'live_runtime_jobs_type_check'
    and c.contype = 'c';

  if v_definition is null then
    raise exception
      'LIVE_RUNTIME_JOB_TYPE_CONSTRAINT_NOT_FOUND';
  end if;

  if position(
      'poll_batch'
      in v_definition
    ) = 0 then

    select string_agg(
      quote_literal(x.value),
      ','
      order by x.value
    )
    into v_values
    from (
      select distinct
        match_row[1] as value
      from regexp_matches(
        v_definition,
        '''([^'']+)''',
        'g'
      ) match_row

      union

      select 'poll_batch'
    ) x;

    if v_values is null then
      raise exception
        'LIVE_RUNTIME_JOB_TYPE_PARSE_FAILED';
    end if;

    alter table public.live_runtime_jobs
      drop constraint
      live_runtime_jobs_type_check;

    execute
      'alter table public.live_runtime_jobs ' ||
      'add constraint live_runtime_jobs_type_check ' ||
      'check (job_type in (' ||
      v_values ||
      '))';
  end if;
end;
$extend_live_runtime_job_types$;

comment on constraint
  live_runtime_jobs_type_check
on public.live_runtime_jobs is
  'Allowed persistent Live Runtime job types, including aggregated provider polling through poll_batch.';

do $migration_assertions$
declare
  v_definition text;
  v_poll_batch_jobs bigint;
begin
  select pg_get_constraintdef(c.oid)
  into v_definition
  from pg_constraint c
  where c.conrelid =
        'public.live_runtime_jobs'::regclass
    and c.conname =
        'live_runtime_jobs_type_check';

  if position(
      'poll_batch'
      in coalesce(v_definition, '')
    ) = 0 then
    raise exception
      'MIGRATION_221_POLL_BATCH_JOB_TYPE_MISSING';
  end if;

  select count(*)
  into v_poll_batch_jobs
  from public.live_runtime_jobs
  where job_type = 'poll_batch';

  if v_poll_batch_jobs <> 0 then
    raise exception
      'MIGRATION_221_CREATED_RUNTIME_EXECUTION_DATA';
  end if;
end;
$migration_assertions$;

commit;