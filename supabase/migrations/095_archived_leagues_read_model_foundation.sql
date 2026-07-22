-- ============================================================================
-- FANTAGOL
-- Migration 095
-- Archived leagues read model foundation
--
-- Purpose:
--   1. Add the canonical archive timestamp to leagues.
--   2. Expose the authenticated user's archived leagues through a read-only RPC.
--   3. Expose a single league context RPC that can later be reused by the
--      read-only archived league experience.
--
-- This migration DOES NOT archive any league and DOES NOT introduce a manual
-- archive command. Automatic end-of-season archival remains a separate engine
-- milestone.
-- ============================================================================

begin;

alter table public.leagues
  add column if not exists archived_at timestamptz;

alter table public.leagues
  add column if not exists archive_reason text;

comment on column public.leagues.archived_at is
  'Canonical timestamp set only when the league becomes permanently archived.';

comment on column public.leagues.archive_reason is
  'Machine-readable reason for archival, normally end_of_competition.';

create index if not exists leagues_archived_membership_read_idx
  on public.leagues (archived_at desc, id)
  where lifecycle_status = 'archived';

-- ----------------------------------------------------------------------------
-- Authenticated archive index
-- ----------------------------------------------------------------------------

drop function if exists public.get_my_archived_leagues_rpc();

create or replace function public.get_my_archived_leagues_rpc()
returns table (
  membership_id uuid,
  league_id uuid,
  league_name text,
  display_name text,
  role text,
  membership_status text,
  lifecycle_status text,
  archived_at timestamptz,
  archive_reason text,
  edition_id uuid,
  season_label text,
  competition_name text
)
language sql
security definer
set search_path = public
stable
as $function$
  select
    lm.id as membership_id,
    l.id as league_id,
    l.name::text as league_name,
    lm.display_name::text as display_name,
    lm.role::text as role,
    lm.status::text as membership_status,
    l.lifecycle_status::text as lifecycle_status,
    l.archived_at,
    l.archive_reason,
    l.edition_id,
    coalesce(
      nullif(to_jsonb(ce) ->> 'label', ''),
      nullif(to_jsonb(s) ->> 'name', ''),
      nullif(to_jsonb(s) ->> 'label', ''),
      nullif(to_jsonb(s) ->> 'season', ''),
      'Stagione conclusa'
    )::text as season_label,
    coalesce(
      nullif(to_jsonb(c) ->> 'name', ''),
      nullif(to_jsonb(c) ->> 'display_name', ''),
      nullif(to_jsonb(c) ->> 'code', ''),
      'Campionato'
    )::text as competition_name
  from public.league_members lm
  join public.leagues l
    on l.id = lm.league_id
  left join public.competition_editions ce
    on ce.id = l.edition_id
  left join public.competitions c
    on c.id = ce.competition_id
  left join public.seasons s
    on s.id = l.season_id
  where lm.user_id = auth.uid()
    and lm.status in ('active', 'archived')
    and l.lifecycle_status = 'archived'
  order by
    l.archived_at desc nulls last,
    l.updated_at desc,
    l.created_at desc;
$function$;

comment on function public.get_my_archived_leagues_rpc() is
  'Returns only permanently archived leagues in which auth.uid() participated. Read-only archive index.';

revoke all on function public.get_my_archived_leagues_rpc() from public;
grant execute on function public.get_my_archived_leagues_rpc() to authenticated;
grant execute on function public.get_my_archived_leagues_rpc() to service_role;

-- ----------------------------------------------------------------------------
-- League context read model
--
-- This intentionally allows both active and archived leagues. It does not
-- expose mutation capabilities and will be used by the future unified league
-- UI to enter an archived league in permanent read-only mode.
-- ----------------------------------------------------------------------------

drop function if exists public.get_my_league_context_rpc(uuid);

create or replace function public.get_my_league_context_rpc(
  p_league_id uuid
)
returns table (
  membership_id uuid,
  league_id uuid,
  league_name text,
  invite_code text,
  display_name text,
  role text,
  membership_status text,
  league_status text,
  lifecycle_status text,
  roster_status text,
  is_archived boolean,
  archived_at timestamptz,
  archive_reason text,
  edition_id uuid,
  season_label text,
  competition_name text
)
language sql
security definer
set search_path = public
stable
as $function$
  select
    lm.id as membership_id,
    l.id as league_id,
    l.name::text as league_name,
    l.invite_code::text as invite_code,
    lm.display_name::text as display_name,
    lm.role::text as role,
    lm.status::text as membership_status,
    l.status::text as league_status,
    l.lifecycle_status::text as lifecycle_status,
    l.roster_status::text as roster_status,
    (l.lifecycle_status = 'archived') as is_archived,
    l.archived_at,
    l.archive_reason,
    l.edition_id,
    coalesce(
      nullif(to_jsonb(ce) ->> 'label', ''),
      nullif(to_jsonb(s) ->> 'name', ''),
      nullif(to_jsonb(s) ->> 'label', ''),
      nullif(to_jsonb(s) ->> 'season', ''),
      'Stagione'
    )::text as season_label,
    coalesce(
      nullif(to_jsonb(c) ->> 'name', ''),
      nullif(to_jsonb(c) ->> 'display_name', ''),
      nullif(to_jsonb(c) ->> 'code', ''),
      'Campionato'
    )::text as competition_name
  from public.league_members lm
  join public.leagues l
    on l.id = lm.league_id
  left join public.competition_editions ce
    on ce.id = l.edition_id
  left join public.competitions c
    on c.id = ce.competition_id
  left join public.seasons s
    on s.id = l.season_id
  where lm.user_id = auth.uid()
    and lm.league_id = p_league_id
    and lm.status in ('active', 'archived')
    and l.lifecycle_status in (
      'draft',
      'open',
      'locked',
      'active',
      'completed',
      'archived'
    )
  limit 1;
$function$;

comment on function public.get_my_league_context_rpc(uuid) is
  'Returns the authenticated member context for one active or archived league. Archived context is read-only by contract.';

revoke all on function public.get_my_league_context_rpc(uuid) from public;
grant execute on function public.get_my_league_context_rpc(uuid) to authenticated;
grant execute on function public.get_my_league_context_rpc(uuid) to service_role;

-- ----------------------------------------------------------------------------
-- Contract assertions
-- ----------------------------------------------------------------------------

do $assertions$
begin
  if not exists (
    select 1
    from information_schema.columns
    where table_schema = 'public'
      and table_name = 'leagues'
      and column_name = 'archived_at'
  ) then
    raise exception 'ARCHIVE_READ_MODEL_ASSERTION_FAILED: leagues.archived_at missing';
  end if;

  if to_regprocedure('public.get_my_archived_leagues_rpc()') is null then
    raise exception 'ARCHIVE_READ_MODEL_ASSERTION_FAILED: get_my_archived_leagues_rpc missing';
  end if;

  if to_regprocedure('public.get_my_league_context_rpc(uuid)') is null then
    raise exception 'ARCHIVE_READ_MODEL_ASSERTION_FAILED: get_my_league_context_rpc missing';
  end if;
end;
$assertions$;

commit;

-- ============================================================================
-- POST-MIGRATION VERIFICATION
-- Run after \i if desired.
-- ============================================================================

select
  routine_name,
  security_type,
  data_type
from information_schema.routines
where routine_schema = 'public'
  and routine_name in (
    'get_my_archived_leagues_rpc',
    'get_my_league_context_rpc'
  )
order by routine_name;

select
  column_name,
  data_type,
  is_nullable
from information_schema.columns
where table_schema = 'public'
  and table_name = 'leagues'
  and column_name in ('archived_at', 'archive_reason')
order by column_name;
