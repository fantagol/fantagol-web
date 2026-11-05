-- FANTAGOL S11-R13 - Push preferences after authorized device registration.
-- Candidate only. Review migration number before production application.
-- No direct table grants, no authenticated RPC grants, no delivery automation.
BEGIN;

DO $assert$
BEGIN
  IF to_regprocedure('public.push_server_register_device_with_preference_rpc(uuid,text,text,bytea)') IS NOT NULL
     OR to_regprocedure('public.push_server_read_preference_rpc(uuid,text)') IS NOT NULL
     OR to_regprocedure('public.push_server_update_preference_rpc(uuid,boolean,text)') IS NOT NULL THEN
    RAISE EXCEPTION 'PUSH_R13_FUNCTION_ALREADY_EXISTS';
  END IF;
  IF to_regprocedure('public.push_server_register_device_rpc(uuid,text,text,bytea)') IS NULL
     OR to_regclass('public.push_preferences') IS NULL
     OR to_regclass('public.push_devices') IS NULL THEN
    RAISE EXCEPTION 'PUSH_R13_PREREQUISITES_MISSING';
  END IF;
END;
$assert$;

CREATE FUNCTION public.push_server_register_device_with_preference_rpc(
  p_user_id uuid, p_channel text, p_endpoint_fingerprint text,
  p_encrypted_credentials bytea
) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $fn$
DECLARE
  v_device_id uuid;
BEGIN
  -- Canonical registration validates ownership, rate limits and envelope.
  v_device_id := public.push_server_register_device_rpc(
    p_user_id, p_channel, p_endpoint_fingerprint, p_encrypted_credentials
  );
  IF v_device_id IS NULL THEN
    RAISE EXCEPTION 'PUSH_R13_DEVICE_REGISTRATION_NOT_CONFIRMED';
  END IF;
  -- First authorized device sets the application default. Never override
  -- an explicit false; renewals must not turn notifications back on.
  INSERT INTO public.push_preferences (user_id, enabled, updated_at)
  VALUES (p_user_id, true, clock_timestamp())
  ON CONFLICT (user_id) DO NOTHING;
  RETURN v_device_id;
END;
$fn$;

CREATE FUNCTION public.push_server_read_preference_rpc(p_user_id uuid, p_endpoint_fingerprint text)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $fn$
DECLARE
  v_enabled boolean;
  v_has_device boolean;
  v_has_current_device boolean;
BEGIN
  IF p_user_id IS NULL THEN RAISE EXCEPTION 'PUSH_R13_USER_REQUIRED'; END IF;
  SELECT p.enabled INTO v_enabled
  FROM public.push_preferences p WHERE p.user_id = p_user_id;
  SELECT EXISTS (
    SELECT 1 FROM public.push_devices d
    WHERE d.user_id = p_user_id AND d.channel = 'web_push'
      AND d.enabled AND d.invalidated_at IS NULL
  ) INTO v_has_device;
  SELECT EXISTS (
    SELECT 1 FROM public.push_devices d
    WHERE d.user_id = p_user_id AND d.channel = 'web_push'
      AND d.enabled AND d.invalidated_at IS NULL
      AND d.endpoint_fingerprint = p_endpoint_fingerprint
  ) INTO v_has_current_device;
  RETURN jsonb_build_object(
    'enabled', coalesce(v_enabled, false),
    'hasWebPushDevice', v_has_device,
    'currentDeviceRegistered', v_has_current_device
  );
END;
$fn$;

CREATE FUNCTION public.push_server_update_preference_rpc(
  p_user_id uuid, p_enabled boolean, p_endpoint_fingerprint text
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $fn$
DECLARE
  v_has_device boolean;
BEGIN
  IF p_user_id IS NULL OR p_enabled IS NULL OR p_endpoint_fingerprint IS NULL
    OR p_endpoint_fingerprint !~ '^[a-f0-9]{64}$' THEN
    RAISE EXCEPTION 'PUSH_R13_PREFERENCE_ARGUMENTS_INVALID';
  END IF;
  -- Serialize explicit preference changes for this user.
  PERFORM pg_advisory_xact_lock(hashtextextended(p_user_id::text, 920361));
  SELECT EXISTS (
    SELECT 1 FROM public.push_devices d
    WHERE d.user_id = p_user_id AND d.channel = 'web_push'
      AND d.enabled AND d.invalidated_at IS NULL
  ) INTO v_has_device;
  IF NOT EXISTS (
    SELECT 1 FROM public.push_devices d
    WHERE d.user_id = p_user_id AND d.channel = 'web_push'
      AND d.endpoint_fingerprint = p_endpoint_fingerprint
      AND d.enabled AND d.invalidated_at IS NULL
  ) THEN
    RAISE EXCEPTION 'PUSH_R13_CURRENT_DEVICE_NOT_OWNED';
  END IF;
  INSERT INTO public.push_preferences (user_id, enabled, updated_at)
  VALUES (p_user_id, p_enabled, clock_timestamp())
  ON CONFLICT (user_id) DO UPDATE
    SET enabled = EXCLUDED.enabled, updated_at = EXCLUDED.updated_at;
  RETURN jsonb_build_object('enabled', p_enabled, 'hasWebPushDevice', v_has_device,
    'currentDeviceRegistered', true);
END;
$fn$;

REVOKE ALL ON FUNCTION public.push_server_register_device_with_preference_rpc(uuid,text,text,bytea)
  FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.push_server_read_preference_rpc(uuid,text)
  FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.push_server_update_preference_rpc(uuid,boolean,text)
  FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.push_server_register_device_with_preference_rpc(uuid,text,text,bytea)
  TO service_role;
GRANT EXECUTE ON FUNCTION public.push_server_read_preference_rpc(uuid,text) TO service_role;
GRANT EXECUTE ON FUNCTION public.push_server_update_preference_rpc(uuid,boolean,text) TO service_role;

DO $post$
DECLARE v_signature text;
BEGIN
 FOR v_signature IN SELECT unnest(ARRAY[
  'public.push_server_register_device_with_preference_rpc(uuid,text,text,bytea)',
  'public.push_server_read_preference_rpc(uuid,text)',
  'public.push_server_update_preference_rpc(uuid,boolean,text)'
 ]) LOOP
  IF NOT has_function_privilege('service_role',v_signature,'EXECUTE')
    OR has_function_privilege('authenticated',v_signature,'EXECUTE')
    OR has_function_privilege('anon',v_signature,'EXECUTE') THEN
    RAISE EXCEPTION 'PUSH_R13_PERMISSION_POSTCONDITION_FAILED';
  END IF;
 END LOOP;
END;
$post$;
COMMIT;
