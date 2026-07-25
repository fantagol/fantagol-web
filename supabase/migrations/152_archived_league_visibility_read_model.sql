-- ============================================================================
-- FANTAGOL
-- Migration 152
-- Archived league visibility read model
--
-- Purpose:
--   1. Preserve the existing automatic end-of-season archive lifecycle.
--   2. Preserve membership-scoped access to archived leagues.
--   3. Expose canonical league visibility for public/private archive identity.
--
-- This migration DOES NOT:
--   - introduce manual archival;
--   - create a second archive;
--   - change lifecycle transitions;
--   - expose archived leagues to non-participants.
-- ============================================================================

begin;

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
  visibility text,
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
    l.visibility::text as visibility,
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
  'Returns archived leagues in which auth.uid() participated, including canonical public/private visibility for archive presentation.';

revoke all on function public.get_my_archived_leagues_rpc()
  from public, anon;

grant execute on function public.get_my_archived_leagues_rpc()
  to authenticated, service_role;

do $assertions$
declare
  v_definition text;
begin
  if to_regprocedure('public.get_my_archived_leagues_rpc()') is null then
    raise exception
      'ARCHIVED_LEAGUE_VISIBILITY_ASSERTION_FAILED: get_my_archived_leagues_rpc missing';
  end if;

  select pg_get_functiondef(
    'public.get_my_archived_leagues_rpc()'::regprocedure
  )
  into v_definition;

  if v_definition not like '%l.visibility::text as visibility%' then
    raise exception
      'ARCHIVED_LEAGUE_VISIBILITY_ASSERTION_FAILED: visibility projection missing';
  end if;

  if v_definition not like '%lm.user_id = auth.uid()%' then
    raise exception
      'ARCHIVED_LEAGUE_VISIBILITY_ASSERTION_FAILED: membership access guard missing';
  end if;

  if v_definition not like '%l.lifecycle_status = ''archived''%' then
    raise exception
      'ARCHIVED_LEAGUE_VISIBILITY_ASSERTION_FAILED: archived lifecycle guard missing';
  end if;
end;
$assertions$;

commit;

-- ============================================================================
-- POST-MIGRATION VERIFICATION
-- ============================================================================

select
  p.oid::regprocedure::text as function_signature,
  pg_get_functiondef(p.oid) like '%l.visibility::text as visibility%'
    as has_visibility_projection,
  pg_get_functiondef(p.oid) like '%lm.user_id = auth.uid()%'
    as has_membership_guard,
  pg_get_functiondef(p.oid) like '%l.lifecycle_status = ''archived''%'
    as has_archive_guard
from pg_proc p
join pg_namespace n
  on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname = 'get_my_archived_leagues_rpc';