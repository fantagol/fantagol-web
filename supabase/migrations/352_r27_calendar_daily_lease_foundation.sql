-- R27-B: durable once-daily calendar scan lease, independent of LIVE governance.
-- Apply only after explicit review; no cron or provider calls are created here.
create table if not exists public.r27_calendar_sync_state (
  singleton boolean primary key default true check (singleton),
  next_due_at timestamptz not null default now(),
  lease_token uuid,
  lease_until timestamptz,
  last_started_at timestamptz,
  last_succeeded_at timestamptz,
  last_error text,
  updated_at timestamptz not null default now()
);
insert into public.r27_calendar_sync_state(singleton) values(true) on conflict do nothing;
revoke all on public.r27_calendar_sync_state from public, anon, authenticated;
grant select on public.r27_calendar_sync_state to service_role;
create or replace function public.r27_claim_calendar_sync_rpc()
returns table(claimed boolean, token uuid, next_due_at timestamptz)
language plpgsql security definer set search_path = public
as $$
declare v public.r27_calendar_sync_state%rowtype; v_token uuid;
begin
  if auth.role() IS DISTINCT FROM 'service_role' then raise exception 'R27_SERVICE_ROLE_REQUIRED'; end if;
  select * into v from public.r27_calendar_sync_state where singleton = true for update;
  if not found then raise exception 'R27_STATE_MISSING'; end if;
  if now() < v.next_due_at or (v.lease_until is not null and v.lease_until > now()) then
    return query select false, null::uuid, v.next_due_at; return;
  end if;
  v_token := gen_random_uuid();
  update public.r27_calendar_sync_state set lease_token=v_token, lease_until=now()+interval '12 minutes',
    last_started_at=now(), updated_at=now() where singleton=true;
  return query select true,v_token,v.next_due_at;
end $$;
create or replace function public.r27_finalize_calendar_sync_rpc(p_token uuid,p_success boolean,p_error text default null)
returns boolean language plpgsql security definer set search_path=public
as $$
declare n integer;
begin
  if auth.role() IS DISTINCT FROM 'service_role' then raise exception 'R27_SERVICE_ROLE_REQUIRED'; end if;
  update public.r27_calendar_sync_state set
    lease_token=null,lease_until=null,updated_at=now(),
    last_succeeded_at=case when p_success then now() else last_succeeded_at end,
    next_due_at=case when p_success then now()+interval '24 hours' else now()+interval '15 minutes' end,
    last_error=case when p_success then null else left(coalesce(p_error,'UNKNOWN'),300) end
  where singleton=true and lease_token=p_token;
  get diagnostics n=row_count;
  return n=1;
end $$;
revoke all on function public.r27_claim_calendar_sync_rpc() from public,anon,authenticated;
revoke all on function public.r27_finalize_calendar_sync_rpc(uuid,boolean,text) from public,anon,authenticated;
grant execute on function public.r27_claim_calendar_sync_rpc() to service_role;
grant execute on function public.r27_finalize_calendar_sync_rpc(uuid,boolean,text) to service_role;
