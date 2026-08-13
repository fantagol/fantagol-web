-- Migration 224
-- FantaGol Live Runtime Scheduler Capability Activation
--
-- R39-E6-B
--
-- PURPOSE:
--   Enable Supabase-native scheduling/network capabilities only.
--
-- ENABLES:
--   - pg_cron
--   - pg_net
--
-- DOES NOT:
--   - create cron jobs
--   - invoke net.http_post / net.http_get
--   - call any provider
--   - enqueue live runtime work
--   - execute workers
--   - modify application/domain data

begin;

create extension if not exists pg_cron;
create extension if not exists pg_net;

do $$
begin
  if not exists (
    select 1
    from pg_extension
    where extname = 'pg_cron'
  ) then
    raise exception
      'MIGRATION_224_PG_CRON_NOT_INSTALLED';
  end if;

  if not exists (
    select 1
    from pg_extension
    where extname = 'pg_net'
  ) then
    raise exception
      'MIGRATION_224_PG_NET_NOT_INSTALLED';
  end if;

  if not exists (
    select 1
    from pg_extension
    where extname = 'supabase_vault'
  ) then
    raise exception
      'MIGRATION_224_VAULT_REGRESSION';
  end if;

  if to_regclass('cron.job') is null then
    raise exception
      'MIGRATION_224_CRON_CATALOG_MISSING';
  end if;

  if to_regclass('cron.job_run_details') is null then
    raise exception
      'MIGRATION_224_CRON_RUN_CATALOG_MISSING';
  end if;

  if to_regclass('net.http_request_queue') is null then
    raise exception
      'MIGRATION_224_PG_NET_QUEUE_MISSING';
  end if;

  if to_regclass('net._http_response') is null then
    raise exception
      'MIGRATION_224_PG_NET_RESPONSE_MISSING';
  end if;

  if (
    select count(*)
    from cron.job
  ) <> 0 then
    raise exception
      'MIGRATION_224_UNEXPECTED_CRON_JOB_PRESENT';
  end if;

  if (
    select count(*)
    from net.http_request_queue
  ) <> 0 then
    raise exception
      'MIGRATION_224_UNEXPECTED_HTTP_REQUEST_PRESENT';
  end if;
end
$$;

commit;