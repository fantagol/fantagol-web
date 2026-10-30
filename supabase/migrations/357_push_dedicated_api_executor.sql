-- FANTAGOL MIGRATION 357 — Dedicated Push API grant role (DRAFT; NOT APPROVED FOR PRODUCTION).
-- Depends on production migration 356 and its closed permissions.
-- NOLOGIN role is non-operational until a separate, audited connection and membership design.
-- No secrets, passwords, LOGIN roles, memberships, worker grants, table grants or HTTP routes.
BEGIN;
SET LOCAL statement_timeout = '15s';
DO $gate$
DECLARE
 v_sig text;
 v_role text;
BEGIN
 IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname='fantagol_push_api_executor') THEN
   RAISE EXCEPTION 'PUSH357_ROLE_ALREADY_EXISTS';
 END IF;
 FOREACH v_sig IN ARRAY ARRAY[
   'public.push_server_set_preference_internal(uuid,boolean)',
   'public.push_server_register_device_internal(uuid,text,text,bytea)',
   'public.push_server_revoke_device_internal(uuid,uuid)',
   'public.push_server_claim_pending_internal(uuid,integer)',
   'public.push_server_expire_lease_internal(uuid,uuid)'
 ] LOOP
   IF to_regprocedure(v_sig) IS NULL THEN
     RAISE EXCEPTION 'PUSH357_MISSING_FUNCTION %',v_sig;
   END IF;
   FOREACH v_role IN ARRAY ARRAY['anon','authenticated','service_role'] LOOP
     IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname=v_role) THEN
       RAISE EXCEPTION 'PUSH357_MISSING_ROLE %',v_role;
     END IF;
     IF has_function_privilege(v_role,v_sig,'EXECUTE') THEN
       RAISE EXCEPTION 'PUSH357_EXISTING_GRANT_OPEN role=% function=%',v_role,v_sig;
     END IF;
   END LOOP;
 END LOOP;
END
$gate$;
CREATE ROLE fantagol_push_api_executor NOLOGIN NOINHERIT NOBYPASSRLS;
GRANT USAGE ON SCHEMA public TO fantagol_push_api_executor;
GRANT EXECUTE ON FUNCTION public.push_server_set_preference_internal(uuid,boolean) TO fantagol_push_api_executor;
GRANT EXECUTE ON FUNCTION public.push_server_register_device_internal(uuid,text,text,bytea) TO fantagol_push_api_executor;
GRANT EXECUTE ON FUNCTION public.push_server_revoke_device_internal(uuid,uuid) TO fantagol_push_api_executor;
DO $assert$
DECLARE
 v_sig text;
 v_role text;
BEGIN
 IF EXISTS (
   SELECT 1 FROM (VALUES
    ('public.push_server_set_preference_internal(uuid,boolean)',true),
    ('public.push_server_register_device_internal(uuid,text,text,bytea)',true),
    ('public.push_server_revoke_device_internal(uuid,uuid)',true),
    ('public.push_server_claim_pending_internal(uuid,integer)',false),
    ('public.push_server_expire_lease_internal(uuid,uuid)',false)
   ) a(sig,allowed)
   WHERE has_function_privilege('fantagol_push_api_executor',a.sig,'EXECUTE') IS DISTINCT FROM a.allowed
 ) THEN RAISE EXCEPTION 'PUSH357_API_EXECUTE_SCOPE_FAIL'; END IF;
 IF EXISTS (
   SELECT 1 FROM (VALUES ('push_devices'),('push_preferences'),('push_delivery_events')) t(name)
   WHERE has_table_privilege('fantagol_push_api_executor','public.'||t.name,'SELECT')
      OR has_table_privilege('fantagol_push_api_executor','public.'||t.name,'INSERT')
      OR has_table_privilege('fantagol_push_api_executor','public.'||t.name,'UPDATE')
      OR has_table_privilege('fantagol_push_api_executor','public.'||t.name,'DELETE')
 ) THEN RAISE EXCEPTION 'PUSH357_DIRECT_TABLE_ACCESS_FAIL'; END IF;
 SELECT rolcanlogin::text INTO v_sig FROM pg_roles WHERE rolname='fantagol_push_api_executor';
 IF v_sig IS DISTINCT FROM 'false' THEN RAISE EXCEPTION 'PUSH357_ROLE_LOGIN_UNEXPECTED'; END IF;
 FOREACH v_role IN ARRAY ARRAY['anon','authenticated','service_role'] LOOP
   FOREACH v_sig IN ARRAY ARRAY[
     'public.push_server_set_preference_internal(uuid,boolean)',
     'public.push_server_register_device_internal(uuid,text,text,bytea)',
     'public.push_server_revoke_device_internal(uuid,uuid)',
     'public.push_server_claim_pending_internal(uuid,integer)',
     'public.push_server_expire_lease_internal(uuid,uuid)'
   ] LOOP
     IF has_function_privilege(v_role,v_sig,'EXECUTE') THEN
       RAISE EXCEPTION 'PUSH357_EXISTING_GRANT_REGRESSION role=% function=%',v_role,v_sig;
     END IF;
   END LOOP;
 END LOOP;
 RAISE NOTICE 'PUSH357_POSTCONDITION_PASS';
END
$assert$;
COMMIT;
