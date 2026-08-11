-- ============================================================================
-- FANTAGOL
-- Migration 231: Support Runtime Bridge Reactivation
-- Global Completeness Audit R4-B1
--
-- The canonical support foundation already exists in repository migration 167
-- but is absent from the current runtime database. This repair migration
-- intentionally replays the exact canonical 167 contract so the repository
-- records the runtime reactivation at the current migration frontier.
--
-- CANONICAL SOURCE: 167_support_request_foundation.sql
-- ============================================================================
-- ============================================================================
-- FANTAGOL
-- MIGRATION 167
-- SUPPORT REQUEST FOUNDATION
-- ============================================================================
--
-- Purpose:
--   - provide a minimal authenticated support-request intake;
--   - allow one optional private screenshot per request;
--   - preserve technical context useful for diagnosis;
--   - avoid introducing a ticket workflow or support engine.
--
-- Security posture:
--   - authenticated users can create and read only their own requests;
--   - users cannot update or delete submitted requests;
--   - screenshots are stored in a private bucket;
--   - screenshot paths are scoped by auth.uid().
-- ============================================================================

begin;

create table if not exists public.support_requests (
  id uuid primary key default gen_random_uuid(),

  user_id uuid not null
    references auth.users(id)
    on delete cascade,

  league_id uuid null
    references public.leagues(id)
    on delete set null,

  category text not null,
  subject text not null,
  description text not null,

  screenshot_path text null,

  source_page text null,
  user_agent text null,
  locale text null,

  status text not null default 'new',

  created_at timestamptz not null default now(),

  constraint support_requests_category_check
    check (
      category in (
        'account_access',
        'league_invite',
        'predictions',
        'scores_rankings',
        'public_leagues',
        'premium_pass',
        'app_website',
        'other'
      )
    ),

  constraint support_requests_subject_check
    check (
      char_length(btrim(subject)) between 3 and 120
    ),

  constraint support_requests_description_check
    check (
      char_length(btrim(description)) between 10 and 4000
    ),

  constraint support_requests_screenshot_path_check
    check (
      screenshot_path is null
      or (
        char_length(screenshot_path) between 10 and 500
        and screenshot_path !~ '(^|/)\.\.(/|$)'
      )
    ),

  constraint support_requests_status_check
    check (
      status in ('new', 'in_progress', 'resolved', 'closed')
    )
);

comment on table public.support_requests is
  'Minimal authenticated support intake for FantaGol web and future mobile clients.';

comment on column public.support_requests.screenshot_path is
  'Private support-screenshots bucket object path.';

create index if not exists support_requests_user_created_idx
  on public.support_requests(user_id, created_at desc);

create index if not exists support_requests_status_created_idx
  on public.support_requests(status, created_at asc);

create index if not exists support_requests_league_created_idx
  on public.support_requests(league_id, created_at desc)
  where league_id is not null;

alter table public.support_requests enable row level security;

revoke all on table public.support_requests
  from public, anon, authenticated;

grant select, insert on table public.support_requests
  to authenticated;

drop policy if exists support_requests_insert_own
  on public.support_requests;

create policy support_requests_insert_own
  on public.support_requests
  for insert
  to authenticated
  with check (
    user_id = auth.uid()
    and status = 'new'
    and (
      league_id is null
      or exists (
        select 1
        from public.league_members lm
        where lm.league_id = support_requests.league_id
          and lm.user_id = auth.uid()
          and lm.status = 'active'
      )
    )
    and (
      screenshot_path is null
      or split_part(screenshot_path, '/', 1) = auth.uid()::text
    )
  );

drop policy if exists support_requests_select_own
  on public.support_requests;

create policy support_requests_select_own
  on public.support_requests
  for select
  to authenticated
  using (
    user_id = auth.uid()
  );

insert into storage.buckets (
  id,
  name,
  public,
  file_size_limit,
  allowed_mime_types
)
values (
  'support-screenshots',
  'support-screenshots',
  false,
  1048576,
  array[
    'image/jpeg',
    'image/png',
    'image/webp'
  ]::text[]
)
on conflict (id) do update
set
  public = excluded.public,
  file_size_limit = excluded.file_size_limit,
  allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists support_screenshots_insert_own
  on storage.objects;

create policy support_screenshots_insert_own
  on storage.objects
  for insert
  to authenticated
  with check (
    bucket_id = 'support-screenshots'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

drop policy if exists support_screenshots_select_own
  on storage.objects;

create policy support_screenshots_select_own
  on storage.objects
  for select
  to authenticated
  using (
    bucket_id = 'support-screenshots'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

drop policy if exists support_screenshots_delete_own
  on storage.objects;

create policy support_screenshots_delete_own
  on storage.objects
  for delete
  to authenticated
  using (
    bucket_id = 'support-screenshots'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

commit;