begin;

-- ---------------------------------------------------------------------------
-- A. Remove abandoned Support email-delivery foundation.
-- Migration 232 was applied during an abandoned, uncommitted experiment.
-- No email provider was ever enabled. The repository intentionally no longer
-- contains that migration; this repair closes the DB/source divergence.
-- ---------------------------------------------------------------------------

drop table if exists public.support_notification_deliveries;

drop function if exists public.set_support_notification_delivery_updated_at();

-- ---------------------------------------------------------------------------
-- B. Extend canonical support_requests for internal operations.
-- User intake permissions remain unchanged.
-- ---------------------------------------------------------------------------

alter table public.support_requests
  add column if not exists updated_at timestamptz not null default now(),
  add column if not exists handled_by uuid null
    references auth.users(id) on delete set null,
  add column if not exists handled_at timestamptz null,
  add column if not exists resolved_at timestamptz null,
  add column if not exists closed_at timestamptz null;

create index if not exists support_requests_console_queue_idx
  on public.support_requests(status, created_at asc);

create index if not exists support_requests_handled_by_idx
  on public.support_requests(handled_by, updated_at desc)
  where handled_by is not null;

-- ---------------------------------------------------------------------------
-- C. Append-only support operations ledger.
-- ---------------------------------------------------------------------------

create table if not exists public.support_request_events (
  id uuid primary key default gen_random_uuid(),

  support_request_id uuid not null
    references public.support_requests(id) on delete cascade,

  event_type text not null,
  from_status text null,
  to_status text null,

  operator_user_id uuid null
    references auth.users(id) on delete set null,

  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),

  constraint support_request_events_type_check
    check (event_type in ('status_changed')),

  constraint support_request_events_status_check
    check (
      from_status is null
      or from_status in ('new','in_progress','resolved','closed')
    ),

  constraint support_request_events_to_status_check
    check (
      to_status is null
      or to_status in ('new','in_progress','resolved','closed')
    ),

  constraint support_request_events_metadata_check
    check (jsonb_typeof(metadata) = 'object')
);

create index if not exists support_request_events_request_idx
  on public.support_request_events(support_request_id, created_at asc);

alter table public.support_request_events enable row level security;

-- ---------------------------------------------------------------------------
-- D. Transition trigger.
-- Canonical workflow:
-- new -> in_progress -> resolved -> closed
-- resolved -> in_progress is allowed for explicit reopening.
-- ---------------------------------------------------------------------------

create or replace function public.apply_support_request_operational_transition()
returns trigger
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
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
     or new.screenshot_path is distinct from old.screenshot_path
     or new.source_page is distinct from old.source_page
     or new.user_agent is distinct from old.user_agent
     or new.locale is distinct from old.locale
     or new.created_at is distinct from old.created_at
  then
    raise exception using
      errcode = '42501',
      message = 'SUPPORT_REQUEST_CORE_IMMUTABLE';
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

revoke all on function public.apply_support_request_operational_transition()
  from public, anon, authenticated;

grant execute on function public.apply_support_request_operational_transition()
  to service_role;

drop trigger if exists support_requests_operational_transition
  on public.support_requests;

create trigger support_requests_operational_transition
before update on public.support_requests
for each row
execute function public.apply_support_request_operational_transition();

-- ---------------------------------------------------------------------------
-- E. ACL boundary.
-- Authenticated intake stays SELECT + INSERT only.
-- Support operations are server-side service_role only.
-- No delete permission is introduced for tickets or event ledger.
-- ---------------------------------------------------------------------------

revoke update, delete on table public.support_requests
  from public, anon, authenticated;

grant select, update on table public.support_requests
  to service_role;

revoke all on table public.support_request_events
  from public, anon, authenticated;

grant select, insert on table public.support_request_events
  to service_role;

-- ---------------------------------------------------------------------------
-- F. Hard assertions.
-- ---------------------------------------------------------------------------

do $$
declare
  v_email_table_exists boolean;
  v_email_function_exists boolean;
begin
  select to_regclass(
    'public.support_notification_deliveries'
  ) is not null
  into v_email_table_exists;

  select to_regprocedure(
    'public.set_support_notification_delivery_updated_at()'
  ) is not null
  into v_email_function_exists;

  if v_email_table_exists or v_email_function_exists then
    raise exception 'SUPPORT_EMAIL_FOUNDATION_RESIDUE_REMAINS';
  end if;

  if has_table_privilege(
      'authenticated',
      'public.support_requests',
      'UPDATE'
    )
    or has_table_privilege(
      'authenticated',
      'public.support_requests',
      'DELETE'
    )
  then
    raise exception 'SUPPORT_REQUEST_CLIENT_MUTATION_EXPOSED';
  end if;

  if not has_table_privilege(
      'service_role',
      'public.support_requests',
      'SELECT'
    )
    or not has_table_privilege(
      'service_role',
      'public.support_requests',
      'UPDATE'
    )
  then
    raise exception 'SUPPORT_CONSOLE_SERVICE_PRIVILEGES_MISSING';
  end if;

  if has_table_privilege(
      'authenticated',
      'public.support_request_events',
      'SELECT'
    )
    or has_table_privilege(
      'authenticated',
      'public.support_request_events',
      'INSERT'
    )
  then
    raise exception 'SUPPORT_EVENT_LEDGER_CLIENT_EXPOSED';
  end if;

  raise notice '[PASS] Support Console operations foundation certified';
end
$$;

commit;