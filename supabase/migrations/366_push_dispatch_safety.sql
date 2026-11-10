-- FANTAGOL S11-R22-R15 / M366 DISPATCH SAFETY -- SOURCE MIGRATION; DEPLOYMENT GOVERNED
-- PRODUCTION INSTALLATION: passive M366 only, after certified persistent M365 and dedicated R6-H preflight.
-- M365/M366 integrated canary is certified; deploy M366 separately with post-commit verification.
-- No scheduler or API route activation, function invocation, provider delivery, or new client RPC grants.
-- All server functions remain inaccessible to anon/authenticated/service_role; M367 requires separate certification.

DO $pre$
BEGIN
 IF to_regprocedure('public.push_server_claim_pending_internal(uuid,integer)') IS NULL
    OR to_regprocedure('public.member_needs_prediction_recovery_internal(uuid,uuid,timestamp with time zone)') IS NULL
    OR to_regprocedure('public.push_server_ack_delivery_internal(uuid,uuid,text,text)') IS NOT NULL
    OR to_regprocedure('public.push_server_prepare_leased_web_delivery_internal(uuid,uuid)') IS NOT NULL
 THEN RAISE EXCEPTION 'PUSH366_AUTHORITY_PRECONDITION_FAILED'; END IF;
 IF NOT EXISTS (
   SELECT 1 FROM pg_constraint WHERE conrelid='public.push_delivery_events'::regclass
   AND conname='push_delivery_events_notification_kind_check'
   AND pg_get_constraintdef(oid) LIKE '%recovery_reminder_10m%'
 ) THEN RAISE EXCEPTION 'PUSH366_M365_TAXONOMY_REQUIRED'; END IF;
END;
$pre$;

-- Reusable server-only predicate; account ownership is checked again on every claim/prepare.
CREATE FUNCTION public.push_server_recovery_event_eligible_internal(
 p_event_id uuid, p_at timestamptz DEFAULT clock_timestamp()
) RETURNS boolean
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path=pg_catalog,public,pg_temp AS $fn$
DECLARE v_kind text; v_user uuid; v_round uuid; v_key text;
BEGIN
 SELECT e.notification_kind,e.user_id,e.fantagol_round_id,e.window_key
 INTO v_kind,v_user,v_round,v_key
 FROM public.push_delivery_events e WHERE e.id=p_event_id;
 IF NOT FOUND OR v_kind NOT IN ('recovery_open','recovery_reminder_2h','recovery_reminder_10m')
    OR v_key IS NULL OR v_key !~ '^[0-9a-fA-F-]{36}$' THEN RETURN false; END IF;
 RETURN EXISTS (
 SELECT 1 FROM public.prediction_recovery_authorizations pra
 JOIN public.prediction_recovery_cycles prc
   ON prc.league_round_id=pra.league_round_id AND prc.status='active'
 JOIN public.league_rounds lr
   ON lr.id=pra.league_round_id AND lr.enabled
   AND lr.status IN ('predictions_locked','live','waiting_postponed')
 JOIN public.league_members lm
   ON lm.id=pra.target_member_id AND lm.league_id=lr.league_id
   AND lm.status='active' AND lm.user_id=v_user
 WHERE pra.id::text=v_key AND pra.status='open'
   AND lr.fantagol_round_id=v_round
   AND p_at>=pra.opened_at AND p_at<pra.expires_at
   AND public.member_needs_prediction_recovery_internal(pra.league_round_id,pra.target_member_id,p_at)
   AND CASE v_kind
     WHEN 'recovery_open' THEN p_at < LEAST(pra.opened_at+interval '5 minutes',pra.expires_at)
     WHEN 'recovery_reminder_2h' THEN
       pra.expires_at-pra.opened_at>interval '2 hours'
       AND p_at>=pra.expires_at-interval '2 hours'
       AND p_at<LEAST(pra.expires_at-interval '117 minutes',pra.expires_at)
     WHEN 'recovery_reminder_10m' THEN
       pra.expires_at-pra.opened_at>interval '10 minutes'
       AND p_at>=pra.expires_at-interval '10 minutes'
       AND p_at<LEAST(pra.expires_at-interval '7 minutes',pra.expires_at)
     ELSE false END
 );
END;
$fn$;

-- Existing signature/return type preserved. No automatic retries and no Android selection.
CREATE OR REPLACE FUNCTION public.push_server_claim_pending_internal(
 p_event_id uuid,p_lease_seconds integer DEFAULT 90
) RETURNS TABLE(event_id uuid,claim_token uuid,selected_device_id uuid,
                selected_channel text,lease_until timestamptz)
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public,pg_temp AS $fn$
DECLARE v_event public.push_delivery_events%rowtype;
DECLARE v_device public.push_devices%rowtype;
DECLARE v_token uuid;
BEGIN
 IF p_event_id IS NULL OR p_lease_seconds IS NULL
    OR p_lease_seconds<30 OR p_lease_seconds>300
 THEN RAISE EXCEPTION 'PUSH366_CLAIM_ARGUMENTS_INVALID'; END IF;
 SELECT * INTO v_event FROM public.push_delivery_events e
 WHERE e.id=p_event_id AND e.state='pending' FOR UPDATE SKIP LOCKED;
 IF NOT FOUND THEN RETURN; END IF;
 IF NOT EXISTS (SELECT 1 FROM public.push_preferences p
                WHERE p.user_id=v_event.user_id AND p.enabled) THEN
   UPDATE public.push_delivery_events SET state='cancelled',updated_at=clock_timestamp()
   WHERE id=v_event.id;
   RETURN;
 END IF;
 IF v_event.notification_kind IN ('reminder_2h','reminder_10m') AND EXISTS (
   SELECT 1 FROM public.push_manual_points_submissions m
   WHERE m.user_id=v_event.user_id AND m.fantagol_round_id=v_event.fantagol_round_id
 ) THEN
   UPDATE public.push_delivery_events SET state='cancelled',updated_at=clock_timestamp()
   WHERE id=v_event.id;
   RETURN;
 END IF;
 IF v_event.notification_kind LIKE 'recovery_%' AND NOT
   public.push_server_recovery_event_eligible_internal(v_event.id,clock_timestamp()) THEN
   UPDATE public.push_delivery_events SET state='cancelled',updated_at=clock_timestamp()
   WHERE id=v_event.id;
   RETURN;
 END IF;
 SELECT * INTO v_device FROM public.push_devices d
 WHERE d.user_id=v_event.user_id AND d.channel='web_push'
   AND d.enabled AND d.invalidated_at IS NULL
 ORDER BY d.last_registered_at DESC,d.id LIMIT 1;
 IF NOT FOUND THEN RETURN; END IF;
 v_token:=gen_random_uuid();
 UPDATE public.push_delivery_events e SET state='leased',device_id=v_device.id,
   attempts=e.attempts+1,lease_token=v_token,
   lease_expires_at=clock_timestamp()+make_interval(secs=>p_lease_seconds),
   updated_at=clock_timestamp() WHERE e.id=v_event.id
 RETURNING e.lease_expires_at INTO lease_until;
 event_id:=v_event.id;claim_token:=v_token;selected_device_id:=v_device.id;
 selected_channel:='web_push';RETURN NEXT;
END;
$fn$;

-- Final eligibility check and credential retrieval immediately before network I/O.
-- Caller must discard returned payload if it cannot send immediately.
CREATE FUNCTION public.push_server_prepare_leased_web_delivery_internal(
 p_event_id uuid,p_claim_token uuid
) RETURNS jsonb
LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path=pg_catalog,public,pg_temp AS $fn$
DECLARE v_event public.push_delivery_events%rowtype;
DECLARE v_device public.push_devices%rowtype;
BEGIN
 IF p_event_id IS NULL OR p_claim_token IS NULL THEN
   RAISE EXCEPTION 'PUSH366_PREPARE_ARGUMENTS_INVALID'; END IF;
 SELECT * INTO v_event FROM public.push_delivery_events e WHERE e.id=p_event_id
   AND e.state='leased' AND e.lease_token=p_claim_token
   AND e.lease_expires_at>clock_timestamp() FOR UPDATE;
 IF NOT FOUND THEN RETURN NULL; END IF;
 IF NOT EXISTS(SELECT 1 FROM public.push_preferences p
               WHERE p.user_id=v_event.user_id AND p.enabled)
 OR (v_event.notification_kind IN ('reminder_2h','reminder_10m') AND EXISTS(
   SELECT 1 FROM public.push_manual_points_submissions m
   WHERE m.user_id=v_event.user_id AND m.fantagol_round_id=v_event.fantagol_round_id))
 OR (v_event.notification_kind LIKE 'recovery_%' AND NOT
   public.push_server_recovery_event_eligible_internal(v_event.id,clock_timestamp())) THEN
   UPDATE public.push_delivery_events SET state='cancelled',lease_token=NULL,
     lease_expires_at=NULL,updated_at=clock_timestamp() WHERE id=v_event.id;
   RETURN NULL;
 END IF;
 SELECT * INTO v_device FROM public.push_devices d WHERE d.id=v_event.device_id
   AND d.user_id=v_event.user_id AND d.channel='web_push'
   AND d.enabled AND d.invalidated_at IS NULL;
 IF NOT FOUND THEN
   UPDATE public.push_delivery_events SET state='cancelled',lease_token=NULL,
     lease_expires_at=NULL,updated_at=clock_timestamp() WHERE id=v_event.id;
   RETURN NULL;
 END IF;
 RETURN jsonb_build_object('event_id',v_event.id,'user_id',v_event.user_id,
   'notification_kind',v_event.notification_kind,'window_key',v_event.window_key,
   'fingerprint',v_device.endpoint_fingerprint,
   'encrypted_credentials_hex',encode(v_device.encrypted_credentials,'hex'));
END;
$fn$;

-- Outcome values are final. NEVER auto-retry 'failed' or 'unknown'.
-- An expired lease cannot be acknowledged and must be reconciled as UNKNOWN.
CREATE FUNCTION public.push_server_ack_delivery_internal(
 p_event_id uuid,p_claim_token uuid,p_outcome text,p_provider_message_id text
) RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public,pg_temp AS $fn$
BEGIN
 IF p_event_id IS NULL OR p_claim_token IS NULL
 OR p_outcome NOT IN ('sent','failed','unknown') OR p_outcome IS NULL
 OR length(coalesce(p_provider_message_id,''))>256
 THEN RAISE EXCEPTION 'PUSH366_ACK_ARGUMENTS_INVALID'; END IF;
 UPDATE public.push_delivery_events e SET
   state=p_outcome,
   sent_at=CASE WHEN p_outcome='sent' THEN clock_timestamp() ELSE e.sent_at END,
   provider_message_id=CASE WHEN p_outcome='sent' THEN p_provider_message_id ELSE NULL END,
   lease_token=NULL,lease_expires_at=NULL,updated_at=clock_timestamp()
 WHERE e.id=p_event_id AND e.state='leased' AND e.lease_token=p_claim_token
   AND e.lease_expires_at>clock_timestamp();
 RETURN FOUND;
END;
$fn$;

REVOKE ALL ON FUNCTION public.push_server_recovery_event_eligible_internal(uuid,timestamp with time zone)
 FROM PUBLIC,anon,authenticated,service_role;
REVOKE ALL ON FUNCTION public.push_server_claim_pending_internal(uuid,integer)
 FROM PUBLIC,anon,authenticated,service_role;
REVOKE ALL ON FUNCTION public.push_server_prepare_leased_web_delivery_internal(uuid,uuid)
 FROM PUBLIC,anon,authenticated,service_role;
REVOKE ALL ON FUNCTION public.push_server_ack_delivery_internal(uuid,uuid,text,text)
 FROM PUBLIC,anon,authenticated,service_role;

DO $post$
DECLARE v_sig text;
BEGIN
 FOREACH v_sig IN ARRAY ARRAY[
  'public.push_server_recovery_event_eligible_internal(uuid,timestamp with time zone)',
  'public.push_server_claim_pending_internal(uuid,integer)',
  'public.push_server_prepare_leased_web_delivery_internal(uuid,uuid)',
  'public.push_server_ack_delivery_internal(uuid,uuid,text,text)'] LOOP
  IF to_regprocedure(v_sig) IS NULL THEN RAISE EXCEPTION 'PUSH366_FUNCTION_MISSING %',v_sig; END IF;
  IF has_function_privilege('anon',v_sig,'EXECUTE')
    OR has_function_privilege('authenticated',v_sig,'EXECUTE')
    OR has_function_privilege('service_role',v_sig,'EXECUTE')
  THEN RAISE EXCEPTION 'PUSH366_GRANT_UNSAFE %',v_sig; END IF;
 END LOOP;
END;
$post$;
