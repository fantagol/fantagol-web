-- R27-B: atomic, service-role-only, provider-evidence-bound future-round admission.
-- Requires reviewed/applied migration 352. No cron changes, no LIVE/odds/score writes.
create or replace function public.r27_admit_calendar_round_rpc(
  p_round_number integer, p_matches jsonb, p_idempotency_key text
) returns table(job_id uuid, inserted boolean, job_status text)
language plpgsql security definer set search_path=public
as $fn$
declare
  v_round public.fantagol_rounds%rowtype;
  v_round_count integer;
  v_new_min timestamptz;
  v_count integer;
  v_changes integer;
  v_active integer;
  v_payload jsonb;
  v_output record;
begin
  if auth.role() IS DISTINCT FROM 'service_role' then raise exception 'R27_SERVICE_ROLE_REQUIRED'; end if;
  if p_round_number not between 1 and 38 then raise exception 'R27_ROUND_OUT_OF_RANGE'; end if;
  if p_idempotency_key is null or length(p_idempotency_key) not between 16 and 180 then raise exception 'R27_BAD_KEY'; end if;
  if jsonb_typeof(p_matches) <> 'array' or jsonb_array_length(p_matches) <> 10 then
    raise exception 'R27_EXPECTED_TEN_PROVIDER_MATCHES';
  end if;
  if exists (
    select 1 from jsonb_to_recordset(p_matches)
      as x(external_id text,kickoff_utc text,provider_status text)
    where x.external_id is null or x.external_id !~ '^[0-9]+$'
       or x.kickoff_utc is null
       or x.kickoff_utc !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$'
       or x.provider_status is distinct from 'TIMED'
  ) then raise exception 'R27_INVALID_OR_PARTIAL_PROVIDER_EVIDENCE'; end if;

  -- Reject ambiguous active round authority before choosing FOR UPDATE row.
  select count(*) into v_round_count from public.fantagol_rounds
  where sequence=p_round_number and active=true;
  if v_round_count<>1 then raise exception 'R27_ACTIVE_ROUND_NOT_UNIQUE:%',v_round_count; end if;

  -- Lock same canonical round row as round-timing reconciliation.
  select * into v_round from public.fantagol_rounds
  where sequence=p_round_number and active=true for update;
  if not found or v_round.target_match_count<>10 or v_round.status not in ('scheduled','predictions_open') then
    raise exception 'R27_ROUND_NOT_ELIGIBLE';
  end if;
  if v_round.lock_at is null or v_round.starts_at is null
    or v_round.lock_at <= now() or v_round.starts_at <= now() then
    raise exception 'R27_ROUND_ALREADY_DUE'; end if;
  if v_round.opens_at is null or v_round.opens_at >= v_round.lock_at then
    raise exception 'R27_ROUND_OPENING_INVALID'; end if;
  if exists(select 1 from public.current_fantagol_round_view v where v.round_id=v_round.id) then
    raise exception 'R27_CURRENT_OWNER_FORBIDDEN';
  end if;

  -- Lock all match rows before checking; ensures consistent membership and state.
  perform m.id from public.fantagol_round_matches frm
  join public.matches m on m.id=frm.match_id
  where frm.fantagol_round_id=v_round.id and frm.required=true and frm.removed_at is null
  order by m.id for update of m;

  -- Validate provider input and canonical mappings EXACTLY, not just an aggregate count.
  with evidence as (
    select x.external_id, x.kickoff_utc::timestamptz as kickoff,
           x.provider_status from jsonb_to_recordset(p_matches)
           as x(external_id text,kickoff_utc text,provider_status text)
  ), canonical as (
    select m.id, pem.external_id, m.kickoff, m.status, m.active
    from public.fantagol_round_matches frm
    join public.matches m on m.id=frm.match_id
    join public.provider_entity_maps pem on pem.internal_id=m.id and pem.entity_type='match' and pem.active=true
    join public.data_providers dp on dp.id=pem.provider_id and dp.code='football_data' and dp.active=true
    where frm.fantagol_round_id=v_round.id and frm.required=true and frm.removed_at is null
  )
  select count(*),count(*) filter(where e.kickoff is distinct from c.kickoff),min(e.kickoff)
  into v_count,v_changes,v_new_min
  from evidence e join canonical c on c.external_id=e.external_id
  where e.external_id ~ '^[0-9]+$' and e.provider_status='TIMED'
    and e.kickoff>now() and c.status='scheduled' and c.active=true;
  if v_count<>10 or (
    select count(distinct x.external_id) from jsonb_to_recordset(p_matches) as x(external_id text)
  )<>10 then raise exception 'R27_EVIDENCE_MAP_OR_STATUS_INVALID'; end if;
  if (select count(distinct m.id) from public.fantagol_round_matches frm join public.matches m on m.id=frm.match_id
      where frm.fantagol_round_id=v_round.id and frm.required=true and frm.removed_at is null)<>10 then
    raise exception 'R27_NONUNIQUE_MATCHES';
  end if;
  if (select count(*) from public.fantagol_round_matches frm
      where frm.fantagol_round_id=v_round.id and frm.required=true and frm.removed_at is null)<>10 then
    raise exception 'R27_CANONICAL_MATCH_COUNT_INVALID';
  end if;
  if v_new_min <= v_round.opens_at then raise exception 'R27_OPENING_AFTER_NEW_KICKOFF'; end if;
  if v_changes=0 then return; end if;

  select count(*) into v_active from public.live_runtime_jobs j
  where j.job_type='poll_batch' and j.scope_type='fantagol_round' and j.scope_id=v_round.id
  and j.status in ('pending','claimed','running','retry_wait');
  if v_active<>0 then raise exception 'R27_POLL_ALREADY_ACTIVE'; end if;

  select jsonb_build_object(
    'provider_code','football_data', 'mode','prematch', 'competition_code','SA',
    'polling_band','future_schedule_guarded', 'polling_reason','future_schedule_due',
    'match_targets', jsonb_agg(jsonb_build_object(
      'match_id',m.id,'external_match_id',pem.external_id,'fantagol_round_id',v_round.id,
      'league_round_ids',coalesce((select jsonb_agg(lr.id::text order by lr.id)
        from public.league_rounds lr where lr.fantagol_round_id=v_round.id and lr.enabled=true),'[]'::jsonb),
      'kickoff_at',m.kickoff,'current_status',m.status
    ) order by pem.external_id)
  ) into v_payload
  from public.fantagol_round_matches frm
  join public.matches m on m.id=frm.match_id
  join public.provider_entity_maps pem on pem.internal_id=m.id and pem.entity_type='match' and pem.active=true
  join public.data_providers dp on dp.id=pem.provider_id and dp.code='football_data' and dp.active=true
  where frm.fantagol_round_id=v_round.id and frm.required=true and frm.removed_at is null;

  select * into v_output from public.enqueue_football_data_pending_intent_rpc(
    p_fantagol_round_id=>v_round.id,p_mode=>'prematch',
    p_polling_band=>'future_schedule_guarded',p_polling_reason=>'future_schedule_due',
    p_idempotency_key=>p_idempotency_key,p_priority=>10,p_scheduled_at=>now(),
    p_payload=>v_payload,p_max_attempts=>5,p_correlation_id=>null,p_causation_id=>null
  );
  return query select v_output.job_id::uuid,v_output.inserted::boolean,v_output.job_status::text;
end
$fn$;
revoke all on function public.r27_admit_calendar_round_rpc(integer,jsonb,text) from public,anon,authenticated;
grant execute on function public.r27_admit_calendar_round_rpc(integer,jsonb,text) to service_role;
