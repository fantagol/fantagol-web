-- FANTAGOL MIGRATION 361-R2
-- CANDIDATE_NOT_APPROVED
-- Combines original 361-R1 boundary and new quota authority.
-- DO NOT APPLY TO PRODUCTION.

BEGIN;

-- FANTAGOL R13-D5
-- MIGRATION 361 CANDIDATE - NOT APPROVED
-- SERVER-SIDE PUSH DEVICE REGISTRATION BOUNDARY
-- DO NOT APPLY TO PRODUCTION WITHOUT CERTIFICATION


CREATE OR REPLACE FUNCTION public.push_server_register_device_rpc(
    p_user_id uuid,
    p_channel text,
    p_endpoint_fingerprint text,
    p_encrypted_credentials bytea
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $function$
BEGIN
    IF p_user_id IS NULL
       OR p_channel IS NULL
       OR p_channel NOT IN ('web_push', 'android_fcm')
       OR p_endpoint_fingerprint IS NULL
       OR p_endpoint_fingerprint !~ '^[a-f0-9]{64}$'
       OR p_encrypted_credentials IS NULL
       OR octet_length(p_encrypted_credentials) < 32
       OR get_byte(p_encrypted_credentials, 0) <> 1
    THEN
        RAISE EXCEPTION 'PUSH_REGISTRATION_INVALID'
            USING ERRCODE = '22023';
    END IF;

    RETURN public.push_server_register_device_internal(
        p_user_id,
        p_channel,
        p_endpoint_fingerprint,
        p_encrypted_credentials
    );
END;
$function$;

REVOKE ALL ON FUNCTION public.push_server_register_device_rpc(
    uuid, text, text, bytea
) FROM PUBLIC;

REVOKE ALL ON FUNCTION public.push_server_register_device_rpc(
    uuid, text, text, bytea
) FROM anon, authenticated, service_role;

GRANT EXECUTE ON FUNCTION public.push_server_register_device_rpc(
    uuid, text, text, bytea
) TO service_role;

DO $postcondition$
DECLARE
    v_function oid;
BEGIN
    SELECT to_regprocedure(
        'public.push_server_register_device_rpc(uuid,text,text,bytea)'
    )::oid INTO v_function;

    IF v_function IS NULL THEN
        RAISE EXCEPTION 'R13_D5_FUNCTION_MISSING';
    END IF;

    IF NOT has_function_privilege(
        'service_role', v_function, 'EXECUTE'
    ) THEN
        RAISE EXCEPTION 'R13_D5_SERVICE_ROLE_DENIED';
    END IF;

    IF has_function_privilege(
        'anon', v_function, 'EXECUTE'
    ) OR has_function_privilege(
        'authenticated', v_function, 'EXECUTE'
    ) THEN
        RAISE EXCEPTION 'R13_D5_CLIENT_EXECUTE_EXPOSED';
    END IF;

    RAISE NOTICE 'R13_D5_REGISTRATION_BOUNDARY_POSTCONDITION_PASS';
END;
$postcondition$;



-- R13-D9-B2 - Persistent, per-user registration quotas.
-- This is a candidate, NOT APPROVED for production.
--
-- 12 new/reactivated registrations per rolling anchored 60-minute window.
-- 60 accepted registration requests (including renewals) per window.
-- 10 simultaneously active devices per user.
-- Rejected transactions roll back counters; HTTP ingress control is separate.

CREATE SCHEMA IF NOT EXISTS push_private;

REVOKE ALL ON SCHEMA push_private FROM PUBLIC;
REVOKE ALL ON SCHEMA push_private FROM anon, authenticated, service_role;

CREATE TABLE push_private.registration_quotas (
    user_id uuid PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
    window_started_at timestamptz NOT NULL,
    request_count integer NOT NULL DEFAULT 0,
    registration_count integer NOT NULL DEFAULT 0,
    updated_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT push_registration_request_count_check
        CHECK (request_count BETWEEN 0 AND 60),
    CONSTRAINT push_registration_new_count_check
        CHECK (registration_count BETWEEN 0 AND 12)
);

REVOKE ALL ON TABLE push_private.registration_quotas FROM PUBLIC;
REVOKE ALL ON TABLE push_private.registration_quotas
    FROM anon, authenticated, service_role;

ALTER TABLE push_private.registration_quotas ENABLE ROW LEVEL SECURITY;

CREATE OR REPLACE FUNCTION public.push_server_register_device_rpc(
    p_user_id uuid,
    p_channel text,
    p_endpoint_fingerprint text,
    p_encrypted_credentials bytea
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $function$
DECLARE
    v_now timestamptz;
    v_started timestamptz;
    v_requests integer;
    v_registrations integer;
    v_existing_owner uuid;
    v_existing_active boolean := false;
    v_existing_found boolean := false;
    v_active_count integer;
    v_id uuid;
BEGIN
    IF p_user_id IS NULL
       OR p_channel NOT IN ('web_push', 'android_fcm')
       OR p_channel IS NULL
       OR p_endpoint_fingerprint IS NULL
       OR p_endpoint_fingerprint !~ '^[a-f0-9]{64}$'
       OR p_encrypted_credentials IS NULL
       OR octet_length(p_encrypted_credentials) < 32
       OR get_byte(p_encrypted_credentials, 0) <> 1
    THEN
        RAISE EXCEPTION 'PUSH_REGISTRATION_INVALID'
            USING ERRCODE = '22023';
    END IF;

    -- Serialize all registration operations for the same user across
    -- concurrent PostgreSQL connections and serverless instances.
    PERFORM pg_catalog.pg_advisory_xact_lock(
        pg_catalog.hashtextextended(p_user_id::text, 920361)
    );

    v_now := clock_timestamp();

    SELECT q.window_started_at, q.request_count, q.registration_count
      INTO v_started, v_requests, v_registrations
      FROM push_private.registration_quotas AS q
     WHERE q.user_id = p_user_id
     FOR UPDATE;

    IF NOT FOUND THEN
        v_started := v_now;
        v_requests := 0;
        v_registrations := 0;

        INSERT INTO push_private.registration_quotas(
            user_id, window_started_at,
            request_count, registration_count, updated_at
        )
        VALUES (p_user_id, v_now, 0, 0, v_now);
    ELSIF v_now >= v_started + interval '60 minutes' THEN
        v_started := v_now;
        v_requests := 0;
        v_registrations := 0;
    END IF;

    IF v_requests >= 60 THEN
        RAISE EXCEPTION 'PUSH_REQUEST_QUOTA_EXCEEDED'
            USING ERRCODE = 'P0001';
    END IF;

    SELECT d.user_id, (d.enabled AND d.invalidated_at IS NULL)
      INTO v_existing_owner, v_existing_active
      FROM public.push_devices AS d
     WHERE d.channel = p_channel
       AND d.endpoint_fingerprint = p_endpoint_fingerprint;

    v_existing_found := FOUND;

    IF v_existing_found AND v_existing_owner <> p_user_id THEN
        RAISE EXCEPTION 'PUSH_ENDPOINT_OWNED_BY_ANOTHER_USER'
            USING ERRCODE = 'P0001';
    END IF;

    -- A currently active endpoint is a renewal, not an additional device.
    -- Every accepted renewal still consumes the request budget.
    IF NOT v_existing_found OR NOT v_existing_active THEN
        IF v_registrations >= 12 THEN
            RAISE EXCEPTION 'PUSH_REGISTRATION_QUOTA_EXCEEDED'
                USING ERRCODE = 'P0001';
        END IF;

        SELECT count(*)::integer
          INTO v_active_count
          FROM public.push_devices AS d
         WHERE d.user_id = p_user_id
           AND d.enabled
           AND d.invalidated_at IS NULL;

        IF v_active_count >= 10 THEN
            RAISE EXCEPTION 'PUSH_ACTIVE_DEVICE_LIMIT'
                USING ERRCODE = 'P0001';
        END IF;

        v_registrations := v_registrations + 1;
    END IF;

    -- Increments and registration are in one transaction.
    UPDATE push_private.registration_quotas
       SET window_started_at = v_started,
           request_count = v_requests + 1,
           registration_count = v_registrations,
           updated_at = v_now
     WHERE user_id = p_user_id;

    v_id := public.push_server_register_device_internal(
        p_user_id,
        p_channel,
        p_endpoint_fingerprint,
        p_encrypted_credentials
    );

    RETURN v_id;
END;
$function$;

REVOKE ALL ON FUNCTION public.push_server_register_device_rpc(
    uuid, text, text, bytea
) FROM PUBLIC;

REVOKE ALL ON FUNCTION public.push_server_register_device_rpc(
    uuid, text, text, bytea
) FROM anon, authenticated, service_role;

GRANT EXECUTE ON FUNCTION public.push_server_register_device_rpc(
    uuid, text, text, bytea
) TO service_role;

DO $postcondition$
DECLARE
    v_fn oid;
BEGIN
    v_fn := to_regprocedure(
        'public.push_server_register_device_rpc(uuid,text,text,bytea)'
    )::oid;

    IF v_fn IS NULL
       OR NOT has_function_privilege('service_role', v_fn, 'EXECUTE')
       OR has_function_privilege('anon', v_fn, 'EXECUTE')
       OR has_function_privilege('authenticated', v_fn, 'EXECUTE')
       OR has_schema_privilege('service_role', 'push_private', 'USAGE')
       OR has_table_privilege(
            'service_role',
            'push_private.registration_quotas',
            'SELECT'
       )
       OR NOT (
           SELECT c.relrowsecurity
           FROM pg_class AS c
           WHERE c.oid = 'push_private.registration_quotas'::regclass
       )
    THEN
        RAISE EXCEPTION 'R13_D9_B2_QUOTA_POSTCONDITION_FAILED';
    END IF;

    RAISE NOTICE 'R13_D9_B2_QUOTA_POSTCONDITION_PASS';
END;
$postcondition$;

COMMIT;