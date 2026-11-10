-- FANTAGOL S11-R22-R19 / M367 ORDINARY SAFETY -- SOURCE MIGRATION; DEPLOYMENT GOVERNED (after M365 + M366)
-- PRODUCTION INSTALLATION: passive M367 only, after certified persistent M365/M366 and dedicated R6-I preflight.
-- No scheduler or API route activation, function invocation, provider delivery, or new client RPC grants.
-- Push activation requires separate runtime certification and authorization after post-commit M367 verification.
-- Current-round logic is a scoped *read-only projection* of Production resolver
-- definition MD5=1f48cb21c9ffa59ccd2ef872f184229b, observed S11-R22-R18.
-- If Production authority changes, the predicate returns FALSE (fail closed).
-- Do not call get_my_current_league_round_rpc from server: it requires auth.uid().
DO $r19pre$
DECLARE v_md5 text;
BEGIN
 SELECT md5(pg_get_functiondef(to_regprocedure('public.get_my_current_league_round_rpc(uuid)'))) INTO v_md5;
 IF v_md5 IS DISTINCT FROM '1f48cb21c9ffa59ccd2ef872f184229b'
 THEN RAISE EXCEPTION 'PUSH367_RESOLVER_DEFINITION_CHANGED'; END IF;
 IF to_regprocedure('public.push_server_recovery_event_eligible_internal(uuid,timestamp with time zone)') IS NULL
 OR to_regprocedure('public.push_server_ack_delivery_internal(uuid,uuid,text,text)') IS NULL
 OR to_regprocedure('public.push_server_enqueue_due_reminders_internal()') IS NOT NULL
 OR to_regprocedure('public.push_server_ordinary_user_eligible_internal(uuid,uuid,text,timestamp with time zone)') IS NOT NULL
 THEN RAISE EXCEPTION 'PUSH367_PREREQUISITES_MISMATCH'; END IF;
END;
$r19pre$;

-- One canonical server-only eligibility predicate shared by enqueue, claim and prepare.
CREATE FUNCTION public.push_server_ordinary_user_eligible_internal(
 p_user uuid,p_round uuid,p_kind text,p_at timestamptz DEFAULT clock_timestamp()
) RETURNS boolean LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path=pg_catalog,public,pg_temp AS $fn$
BEGIN
 IF p_user IS NULL OR p_round IS NULL OR p_at IS NULL
  OR p_kind NOT IN ('predictions_open','reminder_2h','reminder_10m')
 THEN RETURN false; END IF;
 -- A change to the canonical operational resolver invalidates this projection.
 IF md5(pg_get_functiondef('public.get_my_current_league_round_rpc(uuid)'::regprocedure))
    IS DISTINCT FROM '1f48cb21c9ffa59ccd2ef872f184229b' THEN RETURN false; END IF;
 IF EXISTS (SELECT 1 FROM public.push_manual_points_submissions s
            WHERE s.user_id=p_user AND s.fantagol_round_id=p_round) THEN RETURN false; END IF;
 IF NOT EXISTS (SELECT 1 FROM public.push_preferences p
                WHERE p.user_id=p_user AND p.enabled) THEN RETURN false; END IF;
 RETURN EXISTS (
  WITH eligible_memberships AS MATERIALIZED (
   SELECT DISTINCT lm.league_id
   FROM public.league_members lm
   JOIN public.leagues l ON l.id=lm.league_id
   WHERE lm.user_id=p_user AND lm.status='active'
     AND l.status='active'
     AND l.lifecycle_status NOT IN ('completed','archived')
  ), closure_round AS MATERIALIZED (
   SELECT lr.league_id,lr.id AS league_round_id,
          coalesce(c.handoff_at,eligible.last_ft+interval '12 hours') AS handoff_at
   FROM public.league_rounds lr
   JOIN eligible_memberships em ON em.league_id=lr.league_id
   JOIN public.fantagol_rounds fr ON fr.id=lr.fantagol_round_id
   LEFT JOIN public.round_ordinary_live_closures c ON c.fantagol_round_id=lr.fantagol_round_id
   LEFT JOIN LATERAL (
    SELECT max(m.finalised_at) FILTER (WHERE m.status IN ('finished','awarded')) AS last_ft,
           count(*)::integer AS total,
           count(*) FILTER (WHERE m.status IN ('finished','awarded'))::integer AS finished,
           count(*) FILTER (WHERE m.status='postponed')::integer AS postponed,
           count(*) FILTER (WHERE m.status IS NULL OR m.status NOT IN ('finished','awarded','postponed'))::integer AS other,
           count(*) FILTER (WHERE m.status IN ('finished','awarded') AND m.finalised_at IS NULL)::integer AS missing_anchor
    FROM public.fantagol_round_matches frm
    JOIN public.matches m ON m.id=frm.match_id
    WHERE frm.fantagol_round_id=lr.fantagol_round_id
      AND frm.required IS TRUE AND frm.removed_at IS NULL
   ) eligible ON c.fantagol_round_id IS NULL
   WHERE lr.enabled AND (c.fantagol_round_id IS NOT NULL OR (
    fr.starts_at IS NOT NULL AND fr.starts_at<=p_at
    AND eligible.total>0 AND eligible.finished>0 AND eligible.other=0
    AND eligible.missing_anchor=0 AND eligible.total=eligible.finished+eligible.postponed
    AND eligible.last_ft IS NOT NULL AND eligible.last_ft<=p_at
   ))
  ), freeze_round AS MATERIALIZED (
   SELECT DISTINCT ON (league_id) league_id,league_round_id
   FROM closure_round WHERE p_at<handoff_at
   ORDER BY league_id,handoff_at DESC,league_round_id
  ), candidates AS MATERIALIZED (
   SELECT lr.league_id,lr.id,lr.fantagol_round_id,lr.status,lr.league_round_number,
          fr.opens_at,fr.lock_at,fr.starts_at,
          CASE
           WHEN frz.league_round_id IS NOT NULL THEN 0
           WHEN closed.league_round_id IS NOT NULL THEN 9
           WHEN EXISTS (
             SELECT 1 FROM public.league_rounds newer_lr
             JOIN public.round_ordinary_live_closures newer_closure
               ON newer_closure.fantagol_round_id=newer_lr.fantagol_round_id
             WHERE newer_lr.league_id=lr.league_id AND newer_lr.enabled
               AND newer_lr.league_round_number>lr.league_round_number
           ) THEN 9
           WHEN lr.status IN ('predictions_locked','live','waiting_postponed','final_calculable','scoring') THEN 1
           WHEN lr.status='predictions_open' AND p_at>=fr.opens_at AND p_at<fr.lock_at THEN 2
           WHEN lr.status='scheduled' AND fr.starts_at>=p_at THEN 3
           WHEN lr.status='official' THEN 4
           WHEN lr.status='recalculated' THEN 5
           ELSE 6 END AS resolver_priority
   FROM public.league_rounds lr
   JOIN eligible_memberships em ON em.league_id=lr.league_id
   JOIN public.fantagol_rounds fr ON fr.id=lr.fantagol_round_id
   LEFT JOIN freeze_round frz ON frz.league_id=lr.league_id AND frz.league_round_id=lr.id
   LEFT JOIN closure_round closed ON closed.league_round_id=lr.id
   WHERE lr.enabled AND lr.status NOT IN ('archived','cancelled')
  ), current_rounds AS (
    SELECT DISTINCT ON (league_id) * FROM candidates
    ORDER BY league_id,resolver_priority,
      CASE WHEN starts_at>=p_at THEN starts_at ELSE NULL END ASC NULLS LAST,
      starts_at DESC,league_round_number DESC
  )
  SELECT 1 FROM current_rounds cur
  JOIN public.fantagol_rounds fr ON fr.id=cur.fantagol_round_id
  WHERE NOT EXISTS (SELECT 1 FROM freeze_round frz_active WHERE frz_active.league_id=cur.league_id)
    AND cur.fantagol_round_id=p_round
    AND cur.status='predictions_open' AND fr.status='predictions_open'
    AND fr.active IS TRUE AND cur.opens_at<=p_at AND p_at<cur.lock_at
    AND CASE p_kind
      WHEN 'predictions_open' THEN p_at<LEAST(fr.opens_at+interval '5 minutes',fr.lock_at)
      WHEN 'reminder_2h' THEN fr.lock_at-fr.opens_at>interval '2 hours'
       AND p_at>=fr.lock_at-interval '2 hours'
       AND p_at<LEAST(fr.lock_at-interval '115 minutes',fr.lock_at)
      WHEN 'reminder_10m' THEN fr.lock_at-fr.opens_at>interval '10 minutes'
       AND p_at>=fr.lock_at-interval '10 minutes'
       AND p_at<LEAST(fr.lock_at-interval '7 minutes',fr.lock_at)
      ELSE false END
 );
END;
$fn$;

CREATE FUNCTION public.push_server_ordinary_event_eligible_internal(
 p_event_id uuid,p_at timestamptz DEFAULT clock_timestamp()
) RETURNS boolean LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path=pg_catalog,public,pg_temp AS $fn$
DECLARE e public.push_delivery_events%rowtype;
BEGIN
 SELECT * INTO e FROM public.push_delivery_events WHERE id=p_event_id;
 IF NOT FOUND OR e.window_key IS DISTINCT FROM 'ordinary' THEN RETURN false; END IF;
 RETURN public.push_server_ordinary_user_eligible_internal(e.user_id,e.fantagol_round_id,e.notification_kind,p_at);
END;
$fn$;

CREATE FUNCTION public.push_server_enqueue_due_reminders_internal()
RETURNS TABLE(notification_kind text,inserted_count bigint)
LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path=pg_catalog,public,pg_temp AS $fn$
DECLARE v_now timestamptz:=clock_timestamp();
BEGIN
 RETURN QUERY
 WITH due AS MATERIALIZED (
  SELECT fr.id AS round_id,k.kind
  FROM public.fantagol_rounds fr
  CROSS JOIN LATERAL (VALUES
   ('predictions_open'::text, v_now>=fr.opens_at AND v_now<LEAST(fr.opens_at+interval '5 minutes',fr.lock_at)),
   ('reminder_2h'::text, fr.lock_at-fr.opens_at>interval '2 hours' AND v_now>=fr.lock_at-interval '2 hours' AND v_now<LEAST(fr.lock_at-interval '115 minutes',fr.lock_at)),
   ('reminder_10m'::text, fr.lock_at-fr.opens_at>interval '10 minutes' AND v_now>=fr.lock_at-interval '10 minutes' AND v_now<LEAST(fr.lock_at-interval '7 minutes',fr.lock_at))
  ) AS k(kind,is_due)
  WHERE fr.active IS TRUE AND fr.status='predictions_open'
    AND fr.opens_at<=v_now AND v_now<fr.lock_at AND k.is_due
 ), candidates AS MATERIALIZED (
  SELECT DISTINCT lm.user_id,d.round_id,d.kind
  FROM due d JOIN public.league_rounds lr ON lr.fantagol_round_id=d.round_id
  JOIN public.league_members lm ON lm.league_id=lr.league_id
  WHERE lr.enabled AND lr.status='predictions_open'
    AND lm.status='active' AND lm.user_id IS NOT NULL
    AND public.push_server_ordinary_user_eligible_internal(lm.user_id,d.round_id,d.kind,v_now)
    AND EXISTS(SELECT 1 FROM public.push_devices dev WHERE dev.user_id=lm.user_id
      AND dev.channel='web_push' AND dev.enabled AND dev.invalidated_at IS NULL)
 ), added AS (
  INSERT INTO public.push_delivery_events (user_id,fantagol_round_id,notification_kind,window_key,state)
  SELECT c.user_id,c.round_id,c.kind,'ordinary','pending' FROM candidates c
  ON CONFLICT ON CONSTRAINT push_delivery_events_dedup DO NOTHING
  RETURNING push_delivery_events.notification_kind
 ) SELECT a.notification_kind,count(*)::bigint FROM added a GROUP BY a.notification_kind;
END;
$fn$;

-- Replace only the two functions M366 introduced/modified, preserving signatures.
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
 IF v_event.notification_kind IN ('predictions_open','reminder_2h','reminder_10m') AND NOT
   public.push_server_ordinary_event_eligible_internal(v_event.id,clock_timestamp()) THEN
   UPDATE public.push_delivery_events SET state='cancelled',updated_at=clock_timestamp() WHERE id=v_event.id;
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

CREATE OR REPLACE FUNCTION public.push_server_prepare_leased_web_delivery_internal(
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
 OR (v_event.notification_kind IN ('predictions_open','reminder_2h','reminder_10m') AND NOT
   public.push_server_ordinary_event_eligible_internal(v_event.id,clock_timestamp()))
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


REVOKE ALL ON FUNCTION public.push_server_ordinary_user_eligible_internal(uuid,uuid,text,timestamp with time zone)
 FROM PUBLIC,anon,authenticated,service_role;
REVOKE ALL ON FUNCTION public.push_server_ordinary_event_eligible_internal(uuid,timestamp with time zone)
 FROM PUBLIC,anon,authenticated,service_role;
REVOKE ALL ON FUNCTION public.push_server_enqueue_due_reminders_internal()
 FROM PUBLIC,anon,authenticated,service_role;
REVOKE ALL ON FUNCTION public.push_server_claim_pending_internal(uuid,integer)
 FROM PUBLIC,anon,authenticated,service_role;
REVOKE ALL ON FUNCTION public.push_server_prepare_leased_web_delivery_internal(uuid,uuid)
 FROM PUBLIC,anon,authenticated,service_role;
DO $r19post$
DECLARE sig text;
BEGIN
 FOREACH sig IN ARRAY ARRAY[
 'public.push_server_ordinary_user_eligible_internal(uuid,uuid,text,timestamp with time zone)',
 'public.push_server_ordinary_event_eligible_internal(uuid,timestamp with time zone)',
 'public.push_server_enqueue_due_reminders_internal()',
 'public.push_server_claim_pending_internal(uuid,integer)',
 'public.push_server_prepare_leased_web_delivery_internal(uuid,uuid)'
 ] LOOP
 IF to_regprocedure(sig) IS NULL
 OR has_function_privilege('anon',sig,'EXECUTE')
 OR has_function_privilege('authenticated',sig,'EXECUTE')
 OR has_function_privilege('service_role',sig,'EXECUTE')
 THEN RAISE EXCEPTION 'PUSH367_PRIVILEGE_OR_FUNCTION_FAIL %',sig; END IF;
 END LOOP;
END;
$r19post$;
