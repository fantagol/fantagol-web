-- FANTAGOL MIGRATION 358 — Dedicated Push API login identity (CANDIDATE ONLY).
-- Intentionally NOLOGIN: separate secret provisioning and enablement are required.
-- Prerequisite: 357 created fantagol_push_api_executor; 356 functions remain closed.
-- DO NOT apply in production until independently reviewed and locally certified.
BEGIN;
SET LOCAL statement_timeout = '15s';
DO $pre$
DECLARE v_sig text; v_role text;
BEGIN
 IF current_setting('server_version_num')::integer < 160000 THEN
   RAISE EXCEPTION 'PUSH358_REQUIRES_PG16_MEMBERSHIP_OPTIONS';
 END IF;
 IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname='fantagol_push_api_login') THEN
   RAISE EXCEPTION 'PUSH358_LOGIN_ROLE_ALREADY_EXISTS';
 END IF;
 IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='fantagol_push_api_executor'
     AND NOT rolcanlogin AND NOT rolinherit AND NOT rolbypassrls AND NOT rolsuper
     AND NOT rolcreaterole AND NOT rolcreatedb) THEN
   RAISE EXCEPTION 'PUSH358_EXECUTOR_ROLE_NOT_CERTIFIED';
 END IF;
 FOREACH v_sig IN ARRAY ARRAY[
  'public.push_server_set_preference_internal(uuid,boolean)',
  'public.push_server_register_device_internal(uuid,text,text,bytea)',
  'public.push_server_revoke_device_internal(uuid,uuid)',
  'public.push_server_claim_pending_internal(uuid,integer)',
  'public.push_server_expire_lease_internal(uuid,uuid)'
 ] LOOP
   IF to_regprocedure(v_sig) IS NULL THEN RAISE EXCEPTION 'PUSH358_MISSING_FUNCTION %',v_sig; END IF;
   FOREACH v_role IN ARRAY ARRAY['anon','authenticated','service_role'] LOOP
     IF NOT EXISTS(SELECT 1 FROM pg_roles WHERE rolname=v_role)
         OR has_function_privilege(v_role,v_sig,'EXECUTE') THEN
       RAISE EXCEPTION 'PUSH358_BASELINE_GRANTS_NOT_CLOSED role=% function=%',v_role,v_sig;
     END IF;
   END LOOP;
 END LOOP;
 IF EXISTS (SELECT 1 FROM (VALUES
  ('public.push_server_set_preference_internal(uuid,boolean)',true),
  ('public.push_server_register_device_internal(uuid,text,text,bytea)',true),
  ('public.push_server_revoke_device_internal(uuid,uuid)',true),
  ('public.push_server_claim_pending_internal(uuid,integer)',false),
  ('public.push_server_expire_lease_internal(uuid,uuid)',false)
 ) f(sig,allowed) WHERE has_function_privilege('fantagol_push_api_executor',f.sig,'EXECUTE') IS DISTINCT FROM f.allowed) THEN
   RAISE EXCEPTION 'PUSH358_EXECUTOR_SCOPE_MISMATCH';
 END IF;
END
$pre$;

CREATE ROLE fantagol_push_api_login
  NOLOGIN NOINHERIT NOBYPASSRLS NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION;
GRANT fantagol_push_api_executor TO fantagol_push_api_login
  WITH ADMIN FALSE, INHERIT TRUE, SET FALSE;

DO $post$
DECLARE v_sig text; v_role text;
BEGIN
 IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='fantagol_push_api_login'
   AND NOT rolcanlogin AND NOT rolinherit AND NOT rolbypassrls AND NOT rolsuper
   AND NOT rolcreatedb AND NOT rolcreaterole AND NOT rolreplication) THEN
   RAISE EXCEPTION 'PUSH358_LOGIN_PROPERTIES_FAIL';
 END IF;
 IF (SELECT count(*) FROM pg_auth_members WHERE member='fantagol_push_api_login'::regrole) <> 1
   OR NOT EXISTS (SELECT 1 FROM pg_auth_members
     WHERE member='fantagol_push_api_login'::regrole
       AND roleid='fantagol_push_api_executor'::regrole
       AND NOT admin_option AND inherit_option AND NOT set_option) THEN
   RAISE EXCEPTION 'PUSH358_MEMBERSHIP_FAIL';
 END IF;
 IF EXISTS(SELECT 1 FROM pg_auth_members WHERE roleid='fantagol_push_api_login'::regrole) THEN
   RAISE EXCEPTION 'PUSH358_UNEXPECTED_INCOMING_MEMBERSHIP';
 END IF;
 IF EXISTS (SELECT 1 FROM (VALUES
  ('public.push_server_set_preference_internal(uuid,boolean)',true),
  ('public.push_server_register_device_internal(uuid,text,text,bytea)',true),
  ('public.push_server_revoke_device_internal(uuid,uuid)',true),
  ('public.push_server_claim_pending_internal(uuid,integer)',false),
  ('public.push_server_expire_lease_internal(uuid,uuid)',false)
 ) f(sig,allowed) WHERE has_function_privilege('fantagol_push_api_login',f.sig,'EXECUTE') IS DISTINCT FROM f.allowed) THEN
   RAISE EXCEPTION 'PUSH358_LOGIN_EXECUTE_SCOPE_FAIL';
 END IF;
 IF EXISTS (SELECT 1 FROM (VALUES ('push_devices'),('push_preferences'),('push_delivery_events')) t(name)
  WHERE has_table_privilege('fantagol_push_api_login','public.'||t.name,'SELECT')
     OR has_table_privilege('fantagol_push_api_login','public.'||t.name,'INSERT')
     OR has_table_privilege('fantagol_push_api_login','public.'||t.name,'UPDATE')
     OR has_table_privilege('fantagol_push_api_login','public.'||t.name,'DELETE')) THEN
   RAISE EXCEPTION 'PUSH358_DIRECT_TABLE_PRIVILEGE_FAIL';
 END IF;
 IF has_schema_privilege('fantagol_push_api_login','public','CREATE') THEN
   RAISE EXCEPTION 'PUSH358_SCHEMA_CREATE_UNEXPECTED';
 END IF;
 FOREACH v_sig IN ARRAY ARRAY[
  'public.push_server_set_preference_internal(uuid,boolean)',
  'public.push_server_register_device_internal(uuid,text,text,bytea)',
  'public.push_server_revoke_device_internal(uuid,uuid)',
  'public.push_server_claim_pending_internal(uuid,integer)',
  'public.push_server_expire_lease_internal(uuid,uuid)'
 ] LOOP
   FOREACH v_role IN ARRAY ARRAY['anon','authenticated','service_role'] LOOP
     IF has_function_privilege(v_role,v_sig,'EXECUTE') THEN
       RAISE EXCEPTION 'PUSH358_CLIENT_GRANT_REGRESSION role=% function=%',v_role,v_sig;
     END IF;
   END LOOP;
 END LOOP;
 RAISE NOTICE 'PUSH358_TRANSACTION_POSTCONDITION_PASS';
END
$post$;
COMMIT;
