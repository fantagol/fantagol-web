begin;

-- ===========================================================================
-- FANTAGOL SUPPORT SCREENSHOT RETENTION RUNTIME
--
-- Policy:
--   - screenshot lifetime: 30 days from support_requests.created_at
--   - ticket text / metadata / workflow status are preserved
--   - Storage object is deleted first by the server runtime through Storage API
--   - only after successful Storage deletion may DB screenshot_path be nulled
--   - finalization is service-role only, idempotent and audit logged
-- ===========================================================================

alter table public.support_request_events
  drop constraint if exists support_request_events_type_check;

alter table public.support_request_events
  add constraint support_request_events_type_check
    check (
      event_type in (
        'status_changed',
        'screenshot_expired'
      )
    );

create or replace function public.apply_support_request_operational_transition()
returns trigger
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_retention_mode boolean :=
    coalesce(
      current_setting(
        'fantagol.support_screenshot_retention',
        true
      ),
      ''
    ) = '1';
begin
  if tg_op <> 'UPDATE' then
    return new;
  end if;

  if new.id is distinct from old.id
     or new.user_id is distinct from old.user_id
     or new.league_id is distinct from old.league_id
     or new.category is distinct from old.category
     or new.subject is distinct from old.subject
     or new.description is distinct from old.description
     or new.source_page is distinct from old.source_page
     or new.user_agent is distinct from old.user_agent
     or new.locale is distinct from old.locale
     or new.created_at is distinct from old.created_at
  then
    raise exception using
      errcode = '42501',
      message = 'SUPPORT_REQUEST_CORE_IMMUTABLE';
  end if;

  if new.screenshot_path is distinct from old.screenshot_path then
    if not (
      v_retention_mode
      and old.screenshot_path is not null
      and new.screenshot_path is null
      and old.created_at <= now() - interval '30 days'
    ) then
      raise exception using
        errcode = '42501',
        message = 'SUPPORT_REQUEST_SCREENSHOT_MUTATION_DENIED';
    end if;
  end if;

  if new.status is distinct from old.status then
    if not (
      (old.status = 'new' and new.status = 'in_progress')
      or (old.status = 'in_progress' and new.status = 'resolved')
      or (old.status = 'resolved' and new.status = 'closed')
      or (old.status = 'resolved' and new.status = 'in_progress')
    ) then
      raise exception using
        errcode = '22023',
        message = 'SUPPORT_REQUEST_STATUS_TRANSITION_INVALID';
    end if;

    if new.handled_by is null then
      raise exception using
        errcode = '22023',
        message = 'SUPPORT_REQUEST_OPERATOR_REQUIRED';
    end if;

    if old.status = 'new' and new.status = 'in_progress' then
      new.handled_at := coalesce(old.handled_at, clock_timestamp());
      new.resolved_at := null;
      new.closed_at := null;
    elsif old.status = 'in_progress' and new.status = 'resolved' then
      new.handled_at := coalesce(old.handled_at, clock_timestamp());
      new.resolved_at := clock_timestamp();
      new.closed_at := null;
    elsif old.status = 'resolved' and new.status = 'closed' then
      new.resolved_at := coalesce(old.resolved_at, clock_timestamp());
      new.closed_at := clock_timestamp();
    elsif old.status = 'resolved' and new.status = 'in_progress' then
      new.handled_at := coalesce(old.handled_at, clock_timestamp());
      new.resolved_at := null;
      new.closed_at := null;
    end if;

    insert into public.support_request_events (
      support_request_id,
      event_type,
      from_status,
      to_status,
      operator_user_id,
      metadata
    )
    values (
      old.id,
      'status_changed',
      old.status,
      new.status,
      new.handled_by,
      '{}'::jsonb
    );
  end if;

  new.updated_at := clock_timestamp();

  return new;
end;
$$;

revoke all on function
  public.apply_support_request_operational_transition()
  from public, anon, authenticated;

grant execute on function
  public.apply_support_request_operational_transition()
  to service_role;

create or replace function public.finalize_support_screenshot_retention_internal(
  p_support_request_id uuid,
  p_expected_screenshot_path text
)
returns boolean
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_updated boolean := false;
begin
  if p_support_request_id is null
     or nullif(trim(p_expected_screenshot_path), '') is null
  then
    return false;
  end if;

  perform set_config(
    'fantagol.support_screenshot_retention',
    '1',
    true
  );

  update public.support_requests
  set screenshot_path = null
  where id = p_support_request_id
    and screenshot_path = p_expected_screenshot_path
    and created_at <= now() - interval '30 days';

  v_updated := found;

  if v_updated then
    insert into public.support_request_events (
      support_request_id,
      event_type,
      from_status,
      to_status,
      operator_user_id,
      metadata
    )
    select
      sr.id,
      'screenshot_expired',
      sr.status,
      sr.status,
      null,
      jsonb_build_object(
        'retention_days',
        30,
        'expired_screenshot_path',
        p_expected_screenshot_path
      )
    from public.support_requests sr
    where sr.id = p_support_request_id;
  end if;

  perform set_config(
    'fantagol.support_screenshot_retention',
    '0',
    true
  );

  return v_updated;
exception
  when others then
    perform set_config(
      'fantagol.support_screenshot_retention',
      '0',
      true
    );
    raise;
end;
$$;

comment on function public.finalize_support_screenshot_retention_internal(uuid,text) is
  'Service-only DB finalizer called only after the Support screenshot object has been removed through Storage API.';

revoke all on function
  public.finalize_support_screenshot_retention_internal(uuid,text)
  from public, anon, authenticated;

grant execute on function
  public.finalize_support_screenshot_retention_internal(uuid,text)
  to service_role;

do $$
begin
  if has_function_privilege(
    'anon',
    'public.finalize_support_screenshot_retention_internal(uuid,text)',
    'EXECUTE'
  ) or has_function_privilege(
    'authenticated',
    'public.finalize_support_screenshot_retention_internal(uuid,text)',
    'EXECUTE'
  ) then
    raise exception 'SUPPORT_RETENTION_FINALIZER_CLIENT_EXPOSED';
  end if;

  if not has_function_privilege(
    'service_role',
    'public.finalize_support_screenshot_retention_internal(uuid,text)',
    'EXECUTE'
  ) then
    raise exception 'SUPPORT_RETENTION_FINALIZER_SERVICE_ACCESS_MISSING';
  end if;

  raise notice '[PASS] Support screenshot 30-day retention DB foundation certified';
end
$$;

commit;