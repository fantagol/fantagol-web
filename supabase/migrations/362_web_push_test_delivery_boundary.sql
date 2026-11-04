-- FANTAGOL WEB PUSH V1 — DRAFT ONLY; must never be auto-run against Supabase Cloud.
-- Depends on migration 361 registration boundary and public.push_devices existing.
-- Does not grant SELECT/UPDATE on public.push_devices to service_role.
-- Deploy only after isolated clone tests, explicit DBA review and approved rollout.
BEGIN;

CREATE TABLE IF NOT EXISTS push_private.web_push_test_delivery_quotas (
  user_id uuid PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  window_started_at timestamptz NOT NULL,
  window_count integer NOT NULL CHECK (window_count BETWEEN 0 AND 1),
  day_started_at timestamptz NOT NULL,
  day_count integer NOT NULL CHECK (day_count BETWEEN 0 AND 5)
);

ALTER TABLE push_private.web_push_test_delivery_quotas ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE push_private.web_push_test_delivery_quotas FROM PUBLIC, anon, authenticated, service_role;

CREATE OR REPLACE FUNCTION public.push_server_select_test_device_rpc(p_user_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $function$
DECLARE
  v_result jsonb;
BEGIN
  IF p_user_id IS NULL THEN
    RAISE EXCEPTION 'PUSH_TEST_USER_INVALID' USING ERRCODE = '22023';
  END IF;
  SELECT jsonb_build_object(
    'endpoint_fingerprint', d.endpoint_fingerprint,
    'encrypted_credentials_hex', encode(d.encrypted_credentials, 'hex')
  ) INTO v_result
  FROM public.push_devices AS d
  WHERE d.user_id = p_user_id
    AND d.channel = 'web_push'
    AND d.enabled = true
    AND d.invalidated_at IS NULL
  ORDER BY d.last_registered_at DESC, d.id DESC
  LIMIT 1;
  RETURN v_result;
END;
$function$;

CREATE OR REPLACE FUNCTION public.push_server_reserve_test_delivery_rpc(p_user_id uuid)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $function$
DECLARE
  v_now timestamptz := clock_timestamp();
  v_window_started timestamptz;
  v_window_count integer;
  v_day_started timestamptz;
  v_day_count integer;
BEGIN
  IF p_user_id IS NULL THEN
    RAISE EXCEPTION 'PUSH_TEST_USER_INVALID' USING ERRCODE = '22023';
  END IF;
  -- User-specific advisory transaction lock serializes concurrent reservations.
  PERFORM pg_advisory_xact_lock(hashtextextended(p_user_id::text, 362));

  SELECT q.window_started_at, q.window_count, q.day_started_at, q.day_count
  INTO v_window_started, v_window_count, v_day_started, v_day_count
  FROM push_private.web_push_test_delivery_quotas AS q
  WHERE q.user_id = p_user_id;

  IF NOT FOUND THEN
    INSERT INTO push_private.web_push_test_delivery_quotas
      (user_id, window_started_at, window_count, day_started_at, day_count)
    VALUES (p_user_id, v_now, 1, v_now, 1);
    RETURN true;
  END IF;

  IF v_window_started <= v_now - interval '5 minutes' THEN
    v_window_started := v_now;
    v_window_count := 0;
  END IF;
  IF v_day_started <= v_now - interval '24 hours' THEN
    v_day_started := v_now;
    v_day_count := 0;
  END IF;

  IF v_window_count >= 1 OR v_day_count >= 5 THEN
    RETURN false;
  END IF;

  UPDATE push_private.web_push_test_delivery_quotas
    SET window_started_at = v_window_started,
        window_count = v_window_count + 1,
        day_started_at = v_day_started,
        day_count = v_day_count + 1
  WHERE user_id = p_user_id;
  RETURN true;
END;
$function$;

ALTER FUNCTION public.push_server_select_test_device_rpc(uuid) OWNER TO postgres;
ALTER FUNCTION public.push_server_reserve_test_delivery_rpc(uuid) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.push_server_select_test_device_rpc(uuid) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.push_server_reserve_test_delivery_rpc(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.push_server_select_test_device_rpc(uuid) TO service_role;
GRANT EXECUTE ON FUNCTION public.push_server_reserve_test_delivery_rpc(uuid) TO service_role;

COMMIT;
