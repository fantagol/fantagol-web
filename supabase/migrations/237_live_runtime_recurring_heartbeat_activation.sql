-- FantaGol R39-E6-F2-R1
-- Recurring governed production heartbeat activation.
--
-- Supabase is the authoritative clock.
-- Heartbeat cadence is one minute.
-- Provider cadence remains governed by runtime policies.
-- Automatic worker execution remains disabled in the HTTP boundary.

do $preflight$
begin
    if not exists (
        select 1
        from pg_extension
        where extname = 'pg_cron'
    ) then
        raise exception
            'R39_E6_F2_R1_PG_CRON_NOT_INSTALLED';
    end if;

    if not exists (
        select 1
        from pg_extension
        where extname = 'pg_net'
    ) then
        raise exception
            'R39_E6_F2_R1_PG_NET_NOT_INSTALLED';
    end if;

    if not exists (
        select 1
        from vault.decrypted_secrets
        where
            name =
                'fantagol_live_runtime_heartbeat_cron_secret'
            and nullif(
                btrim(decrypted_secret),
                ''
            ) is not null
    ) then
        raise exception
            'R39_E6_F2_R1_VAULT_SECRET_MISSING';
    end if;

    if exists (
        select 1
        from cron.job
        where jobname =
            'fantagol-production-heartbeat'
    ) then
        raise exception
            'R39_E6_F2_R1_CRON_ALREADY_EXISTS';
    end if;
end
$preflight$;

select cron.schedule(
    'fantagol-production-heartbeat',
    '* * * * *',
    $cron$
        select net.http_post(
            url :=
                'https://www.fantagol.app/api/live-runtime/heartbeat',

            body :=
                jsonb_build_object(
                    'source',
                    'supabase-pg-cron-production-heartbeat'
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
    $cron$
);

do $poststate$
declare
    v_count integer;
begin
    select count(*)
    into v_count
    from cron.job
    where
        jobname =
            'fantagol-production-heartbeat'
        and schedule =
            '* * * * *'
        and active;

    if v_count <> 1 then
        raise exception
            'R39_E6_F2_R1_CRON_POSTSTATE_INVALID count=%',
            v_count;
    end if;

    raise notice
        '[PASS] recurring production heartbeat activated';
end
$poststate$;