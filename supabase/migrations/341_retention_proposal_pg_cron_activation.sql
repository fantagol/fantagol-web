-- ============================================================================
-- MIGRATION 341
-- Supabase pg_cron activation for the canonical retention proposal cycle.
--
-- Scheduler:
--   pg_cron, direct SQL, daily at 03:27 UTC.
--
-- Privilege model:
--   * postgres provisions the job only;
--   * service_role receives temporary USAGE on schema cron;
--   * the job is created under SET ROLE service_role;
--   * schema USAGE is revoked immediately after provisioning;
--   * the persisted job therefore executes as service_role;
--   * service_role can execute M340 proposal authority;
--   * service_role cannot execute journaled retention deletion.
--
-- No HTTP / no Vercel route / no net.http_post.
-- No retention plan approval or destructive execution.
-- ============================================================================

grant usage on schema cron to service_role;

set role service_role;

select cron.schedule(
  'fantagol-retention-proposal-cycle',
  '27 3 * * *',
  $cron$
    select public.run_retention_proposal_cycle_rpc(
      null,
      jsonb_build_object(
        'source', 'supabase-pg-cron',
        'job', 'fantagol-retention-proposal-cycle',
        'proposal_only', true
      )
    );
  $cron$
);

reset role;

revoke usage on schema cron from service_role;