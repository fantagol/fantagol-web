-- FANTAGOL S11-R22-R7-I — CANDIDATE ONLY / NOT AUTHORIZED FOR PRODUCTION.
-- Repairs the M362 test-device selector, preserving signature and service_role boundary.
-- IMPORTANT: This gates selection, but does not atomically serialize opt-out with provider delivery.
-- Require isolated-clone transactional canary and separate production approval.
BEGIN;

DO $preflight$
BEGIN
  IF to_regprocedure('public.push_server_select_test_device_rpc(uuid)') IS NULL
     OR to_regclass('public.push_devices') IS NULL
     OR to_regclass('public.push_preferences') IS NULL THEN
    RAISE EXCEPTION 'PUSH_R7I_PREREQUISITES_MISSING';
  END IF;
  IF (SELECT p.prosecdef IS NOT TRUE OR p.prorettype <> 'jsonb'::regtype
        FROM pg_catalog.pg_proc AS p
        WHERE p.oid = 'public.push_server_select_test_device_rpc(uuid)'::regprocedure) THEN
    RAISE EXCEPTION 'PUSH_R7I_EXISTING_CONTRACT_MISMATCH';
  END IF;
END;
$preflight$;

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
    AND EXISTS (
      SELECT 1
      FROM public.push_preferences AS pref
      WHERE pref.user_id = d.user_id
        AND pref.enabled IS TRUE
    )
  ORDER BY d.last_registered_at DESC, d.id DESC
  LIMIT 1;
  RETURN v_result;
END;
$function$;

ALTER FUNCTION public.push_server_select_test_device_rpc(uuid) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.push_server_select_test_device_rpc(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.push_server_select_test_device_rpc(uuid) TO service_role;

DO $postcheck$
BEGIN
  IF NOT (SELECT p.prosecdef AND p.proowner = 'postgres'::regrole AND
                 p.proconfig @> ARRAY['search_path=pg_catalog, pg_temp']::text[]
            FROM pg_catalog.pg_proc AS p
            WHERE p.oid = 'public.push_server_select_test_device_rpc(uuid)'::regprocedure)
     OR NOT has_function_privilege('service_role', 'public.push_server_select_test_device_rpc(uuid)', 'EXECUTE')
     OR has_function_privilege('authenticated', 'public.push_server_select_test_device_rpc(uuid)', 'EXECUTE')
     OR has_function_privilege('anon', 'public.push_server_select_test_device_rpc(uuid)', 'EXECUTE') THEN
    RAISE EXCEPTION 'PUSH_R7I_POSTCONDITION_FAILED';
  END IF;
END;
$postcheck$;
COMMIT;
