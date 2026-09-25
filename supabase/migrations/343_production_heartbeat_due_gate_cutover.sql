-- FANTAGOL MIGRATION 343
-- Production heartbeat due-gate cutover.
--
-- Authority chain:
--   Supabase pg_cron (every minute, postgres)
--     -> claim_production_heartbeat_wakeup_rpc(...)
--     -> stop inside DB when claimed=false
--     -> net.http_post only when claimed=true
--     -> HTTP body carries leaseToken
--     -> deployed application finalizes lease via service_role RPC
--
-- This migration intentionally:
--   * preserves cron cadence "* * * * *"
--   * preserves job id/name/database/owner
--   * preserves existing Vault bearer authorization
--   * does NOT move provider cadence policy into SQL
--   * does NOT change LIVE/FINAL authority semantics
--   * does NOT modify M342
--
-- Prerequisite:
--   M342 wake-up authority already applied.
--   Application lease/finalize contract already deployed.

do $m343_preflight$
begin
  if to_regclass('public.live_runtime_heartbeat_state') is null then
    raise exception
      'M343_REQUIRES_M342_HEARTBEAT_STATE';
  end if;

  if to_regprocedure(
       'public.claim_production_heartbeat_wakeup_rpc(text,integer)'
     ) is null
  then
    raise exception
      'M343_REQUIRES_M342_CLAIM_RPC';
  end if;

  if to_regprocedure(
       'public.finalize_production_heartbeat_wakeup_rpc(uuid,boolean,text)'
     ) is null
  then
    raise exception
      'M343_REQUIRES_M342_FINALIZE_RPC';
  end if;

  if not exists (
    select 1
    from cron.job
    where jobid = 4
      and jobname = 'fantagol-production-heartbeat'
      and schedule = '* * * * *'
      and username = 'postgres'
      and database = 'postgres'
      and active
  ) then
    raise exception
      'M343_PRODUCTION_HEARTBEAT_CRON_BASELINE_NOT_FOUND';
  end if;
end
$m343_preflight$;

select cron.schedule(
  'fantagol-production-heartbeat',
  '* * * * *',
  $cron$
do $heartbeat_gate$
declare
  v_claim jsonb;
begin
  select public.claim_production_heartbeat_wakeup_rpc(
    'supabase-pg-cron-production-heartbeat',
    180
  )
  into v_claim;

  if coalesce(
       (v_claim->>'claimed')::boolean,
       false
     )
  then
    perform net.http_post(
      url :=
        'https://www.fantagol.app/api/live-runtime/heartbeat',
      body :=
        jsonb_build_object(
          'source',
          'supabase-pg-cron-production-heartbeat',
          'leaseToken',
          v_claim->>'lease_token'
        ),
      params :=
        '{}'::jsonb,
      headers :=
        jsonb_build_object(
          'Content-Type',
          'application/json',
          'Authorization',
          'Bearer ' || (
            select decrypted_secret
            from vault.decrypted_secrets
            where name =
              'fantagol_live_runtime_heartbeat_cron_secret'
            limit 1
          )
        ),
      timeout_milliseconds :=
        30000
    );
  end if;
end
$heartbeat_gate$;
$cron$
);

do $m343_postcondition$
begin
  if not exists (
    select 1
    from cron.job
    where jobid = 4
      and jobname = 'fantagol-production-heartbeat'
      and schedule = '* * * * *'
      and username = 'postgres'
      and database = 'postgres'
      and active
      and command ilike
        '%claim_production_heartbeat_wakeup_rpc%'
      and command ilike
        '%leaseToken%'
      and command ilike
        '%net.http_post%'
      and command ilike
        '%if coalesce%'
  ) then
    raise exception
      'M343_PRODUCTION_HEARTBEAT_GATE_POSTCONDITION_FAILED';
  end if;
end
$m343_postcondition$;