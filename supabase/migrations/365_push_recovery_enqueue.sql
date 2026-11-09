-- FANTAGOL S11-R22-R12 / M365 RECOVERY PRODUCER -- SOURCE MIGRATION; NOT DEPLOYED
-- DO NOT APPLY TO PRODUCTION. No scheduler, no delivery, no grants.
-- Requires separately audited claim/ACK changes before activation.
-- Each authorization UUID is the member-scoped immutable recovery window_key.
-- A previously USED authorization is never retried as a new window.
BEGIN;
SET LOCAL statement_timeout = '15s';
SET LOCAL lock_timeout = '3s';

DO $pre$
DECLARE v_check text;
BEGIN
  IF to_regprocedure('public.push_server_enqueue_due_recovery_internal()') IS NOT NULL THEN
    RAISE EXCEPTION 'PUSH365_PRODUCER_ALREADY_EXISTS';
  END IF;
  IF EXISTS (
    SELECT 1 FROM (VALUES
      ('prediction_recovery_authorizations','id'),
      ('prediction_recovery_authorizations','league_round_id'),
      ('prediction_recovery_authorizations','target_member_id'),
      ('prediction_recovery_authorizations','opened_at'),
      ('prediction_recovery_authorizations','expires_at'),
      ('prediction_recovery_authorizations','status'),
      ('prediction_recovery_cycles','league_round_id'),
      ('prediction_recovery_cycles','status'),
      ('league_rounds','id'), ('league_rounds','enabled'),
      ('league_rounds','status'),('league_rounds','fantagol_round_id'),
      ('league_members','id'), ('league_members','user_id'),
      ('league_members','status'),
      ('push_preferences','user_id'),('push_preferences','enabled'),
      ('push_devices','user_id'),('push_devices','channel'),
      ('push_devices','enabled'),('push_devices','invalidated_at'),
      ('push_delivery_events','user_id'),
      ('push_delivery_events','fantagol_round_id'),
      ('push_delivery_events','notification_kind'),
      ('push_delivery_events','window_key'),
      ('push_delivery_events','state')
    ) AS r(t,c)
    WHERE NOT EXISTS (
      SELECT 1 FROM information_schema.columns i
      WHERE i.table_schema = 'public' AND i.table_name=r.t AND i.column_name=r.c
    )
  ) THEN RAISE EXCEPTION 'PUSH365_SCHEMA_INCOMPLETE'; END IF;

  IF to_regprocedure('public.member_needs_prediction_recovery_internal(uuid,uuid,timestamp with time zone)') IS NULL
  THEN RAISE EXCEPTION 'PUSH365_MISSING_CANONICAL_MISSING_AUTHORITY'; END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_indexes
    WHERE schemaname='public'
      AND tablename='prediction_recovery_authorizations'
      AND indexname='prediction_recovery_open_member_round_unique'
      AND indexdef ILIKE '%UNIQUE INDEX%'
      AND indexdef ILIKE '%WHERE (status = ''open''%'
  ) THEN RAISE EXCEPTION 'PUSH365_RECOVERY_MULTIWINDOW_UNCERTIFIED'; END IF;

  SELECT pg_get_constraintdef(c.oid) INTO v_check
  FROM pg_constraint c
  WHERE c.conrelid = 'public.push_delivery_events'::regclass
    AND c.conname='push_delivery_events_notification_kind_check'
    AND c.contype='c';
  IF v_check IS NULL OR v_check NOT LIKE '%predictions_open%'
     OR v_check NOT LIKE '%reminder_2h%' OR v_check NOT LIKE '%reminder_10m%'
  THEN RAISE EXCEPTION 'PUSH365_NOTIFICATION_KIND_CONTRACT_MISMATCH'; END IF;
END;
$pre$;

-- Extend existing event taxonomy without changing ordinary event keys.
ALTER TABLE public.push_delivery_events
  DROP CONSTRAINT push_delivery_events_notification_kind_check;
ALTER TABLE public.push_delivery_events
  ADD CONSTRAINT push_delivery_events_notification_kind_check CHECK (
    notification_kind IN (
      'predictions_open', 'reminder_2h', 'reminder_10m',
      'recovery_open', 'recovery_reminder_2h', 'recovery_reminder_10m'
    )
  );

CREATE FUNCTION public.push_server_enqueue_due_recovery_internal()
RETURNS TABLE(notification_kind text, inserted_count bigint)
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $fn$
DECLARE v_now timestamptz := clock_timestamp();
BEGIN
  RETURN QUERY
  WITH eligible AS MATERIALIZED (
    SELECT lm.user_id, lr.fantagol_round_id AS round_id,
           pra.id::text AS window_key,
           k.kind
    FROM public.prediction_recovery_authorizations pra
    JOIN public.prediction_recovery_cycles prc
      ON prc.league_round_id=pra.league_round_id AND prc.status='active'
    JOIN public.league_rounds lr
      ON lr.id=pra.league_round_id AND lr.enabled
      AND lr.status IN ('predictions_locked','live','waiting_postponed')
    JOIN public.league_members lm
      ON lm.id=pra.target_member_id AND lm.league_id=lr.league_id
      AND lm.status='active' AND lm.user_id IS NOT NULL
    JOIN public.push_preferences pref
      ON pref.user_id=lm.user_id AND pref.enabled
    CROSS JOIN LATERAL (
      VALUES
        ('recovery_open'::text,
          v_now >= pra.opened_at AND v_now < LEAST(pra.opened_at + interval '5 minutes', pra.expires_at)),
        ('recovery_reminder_2h'::text,
          pra.expires_at - pra.opened_at > interval '2 hours'
          AND v_now >= pra.expires_at - interval '2 hours'
          AND v_now < LEAST(pra.expires_at - interval '2 hours' + interval '3 minutes',pra.expires_at)),
        ('recovery_reminder_10m'::text,
          pra.expires_at - pra.opened_at > interval '10 minutes'
          AND v_now >= pra.expires_at - interval '10 minutes'
          AND v_now < LEAST(pra.expires_at - interval '10 minutes' + interval '3 minutes',pra.expires_at))
    ) k(kind,is_due)
    WHERE pra.status='open'
      AND pra.opened_at <= v_now AND v_now < pra.expires_at
      AND k.is_due
      AND public.member_needs_prediction_recovery_internal(pra.league_round_id,pra.target_member_id,v_now)
      AND EXISTS (
        SELECT 1 FROM public.push_devices d
        WHERE d.user_id=lm.user_id AND d.channel='web_push'
          AND d.enabled AND d.invalidated_at IS NULL
      )
  ), added AS (
    INSERT INTO public.push_delivery_events
      (user_id, fantagol_round_id, notification_kind, window_key, state)
    SELECT e.user_id,e.round_id,e.kind,e.window_key,'pending'
    FROM eligible e
    ON CONFLICT ON CONSTRAINT push_delivery_events_dedup DO NOTHING
    RETURNING push_delivery_events.notification_kind
  )
  SELECT a.notification_kind, count(*)::bigint FROM added a GROUP BY a.notification_kind;
END;
$fn$;

REVOKE ALL ON FUNCTION public.push_server_enqueue_due_recovery_internal()
  FROM PUBLIC, anon, authenticated, service_role;

DO $post$
BEGIN
  IF has_function_privilege('anon','public.push_server_enqueue_due_recovery_internal()','EXECUTE')
     OR has_function_privilege('authenticated','public.push_server_enqueue_due_recovery_internal()','EXECUTE')
     OR has_function_privilege('service_role','public.push_server_enqueue_due_recovery_internal()','EXECUTE')
  THEN RAISE EXCEPTION 'PUSH365_FUNCTION_GRANTS_UNSAFE'; END IF;
END;
$post$;
COMMIT;
