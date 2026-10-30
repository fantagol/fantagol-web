-- FANTAGOL PUSH V1-L7-R7: SECURE DEVICE & ATOMIC CLAIM FOUNDATION.
-- SQL canaries passed; functions remain ungranted. No provider delivery, event enqueue, scheduler or production activation authorized.
-- Provider credentials MUST be encrypted/authenticated by the server prior to calling.
-- No client grants, provider delivery, scheduling or event enqueue authority.

create or replace function public.push_server_set_preference_internal(
  p_user_id uuid, p_enabled boolean
) returns void
language plpgsql security definer set search_path = pg_catalog, public, pg_temp
as $$
begin
  if p_user_id is null or p_enabled is null then
    raise exception 'invalid preference arguments';
  end if;
  insert into public.push_preferences(user_id, enabled, updated_at)
    values (p_user_id, p_enabled, now())
    on conflict (user_id) do update set enabled = excluded.enabled, updated_at = now();
end;
$$;

create or replace function public.push_server_register_device_internal(
  p_user_id uuid, p_channel text, p_endpoint_fingerprint text,
  p_encrypted_credentials bytea
) returns uuid
language plpgsql security definer set search_path = pg_catalog, public, pg_temp
as $$
declare v_id uuid;
begin
  if p_user_id is null or p_channel is null
     or p_channel not in ('android_fcm','web_push')
     or p_endpoint_fingerprint is null
     or p_endpoint_fingerprint !~ '^[a-f0-9]{64}$'
     or p_encrypted_credentials is null
     or octet_length(p_encrypted_credentials) < 32 then
    raise exception 'invalid device registration arguments';
  end if;
  -- The unique fingerprint prevents the same endpoint from being silently reassigned.
  insert into public.push_devices
      (user_id, channel, endpoint_fingerprint, encrypted_credentials, enabled,
       invalidated_at, last_registered_at)
  values (p_user_id, p_channel, p_endpoint_fingerprint, p_encrypted_credentials,
          true, null, now())
  on conflict (channel, endpoint_fingerprint) do update set
      encrypted_credentials = excluded.encrypted_credentials,
      enabled = true,
      invalidated_at = null,
      last_registered_at = now()
  where public.push_devices.user_id = excluded.user_id
  returning id into v_id;
  if v_id is null then
    raise exception 'endpoint belongs to a different user';
  end if;
  return v_id;
end;
$$;

create or replace function public.push_server_revoke_device_internal(
  p_user_id uuid, p_device_id uuid
) returns boolean
language plpgsql security definer set search_path = pg_catalog, public, pg_temp
as $$
begin
  if p_user_id is null or p_device_id is null then
    raise exception 'invalid revoke arguments';
  end if;
  update public.push_devices set enabled = false, invalidated_at = now()
    where id = p_device_id and user_id = p_user_id;
  return found;
end;
$$;

-- This claim only operates on previously authorized pending events.
-- The event-enqueue eligibility authority is intentionally not implemented here.
-- No retry of 'unknown', 'failed' or expired leased events.
create or replace function public.push_server_claim_pending_internal(
  p_event_id uuid, p_lease_seconds integer default 90
) returns table(event_id uuid, claim_token uuid, selected_device_id uuid,
                selected_channel text, lease_until timestamptz)
language plpgsql security definer set search_path = pg_catalog, public, pg_temp
as $$
declare v_event public.push_delivery_events%rowtype;
declare v_device public.push_devices%rowtype;
declare v_token uuid;
declare v_expiry timestamptz;
begin
  if p_event_id is null or p_lease_seconds is null or p_lease_seconds < 30
     or p_lease_seconds > 300 then
    raise exception 'invalid claim arguments';
  end if;
  select * into v_event from public.push_delivery_events e
    where e.id = p_event_id and e.state = 'pending'
    for update skip locked;
  if not found then return; end if;
  if not exists (
    select 1 from public.push_preferences p
     where p.user_id = v_event.user_id and p.enabled
  ) then return; end if;
  if v_event.notification_kind in ('reminder_2h','reminder_10m') and exists (
    select 1 from public.push_manual_points_submissions m
     where m.user_id = v_event.user_id
       and m.fantagol_round_id = v_event.fantagol_round_id
  ) then return; end if;
  select * into v_device from public.push_devices d
   where d.user_id = v_event.user_id and d.enabled and d.invalidated_at is null
   order by case d.channel when 'android_fcm' then 0 else 1 end,
            d.last_registered_at desc, d.id
   limit 1;
  if not found then return; end if;
  v_token := gen_random_uuid();
  v_expiry := clock_timestamp() + make_interval(secs => p_lease_seconds);
  update public.push_delivery_events e
   set state = 'leased', device_id = v_device.id, attempts = attempts + 1,
       lease_token = v_token, lease_expires_at = v_expiry, updated_at = now()
   where e.id = v_event.id;
  event_id := v_event.id;
  claim_token := v_token;
  selected_device_id := v_device.id;
  selected_channel := v_device.channel;
  lease_until := v_expiry;
  return next;
end;
$$;

-- A worker must mark an expired lease UNKNOWN, never reset to pending.
-- A provider submission worker will require a separate acknowledgement authority.
create or replace function public.push_server_expire_lease_internal(
  p_event_id uuid, p_claim_token uuid
) returns boolean
language plpgsql security definer set search_path = pg_catalog, public, pg_temp
as $$
begin
  if p_event_id is null or p_claim_token is null then
    raise exception 'invalid expiry arguments';
  end if;
  update public.push_delivery_events set state = 'unknown', lease_token = null,
    lease_expires_at = null, updated_at = now()
  where id = p_event_id and state = 'leased' and lease_token = p_claim_token
    and lease_expires_at <= clock_timestamp();
  return found;
end;
$$;

-- Keep public API completely closed until server routes are independently certified.
revoke all on function public.push_server_set_preference_internal(uuid,boolean)
  from public, anon, authenticated, service_role;
revoke all on function public.push_server_register_device_internal(uuid,text,text,bytea)
  from public, anon, authenticated, service_role;
revoke all on function public.push_server_revoke_device_internal(uuid,uuid)
  from public, anon, authenticated, service_role;
revoke all on function public.push_server_claim_pending_internal(uuid,integer)
  from public, anon, authenticated, service_role;
revoke all on function public.push_server_expire_lease_internal(uuid,uuid)
  from public, anon, authenticated, service_role;
-- Deliberately NO GRANT even to service_role in R2.
