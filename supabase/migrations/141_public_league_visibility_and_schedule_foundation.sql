-- ============================================================================
-- FANTAGOL
-- MIGRATION 141
-- PUBLIC LEAGUE VISIBILITY AND SCHEDULE FOUNDATION
--
-- Milestone 12.4
--
-- Covers:
--   - canonical league visibility
--   - public league schedule snapshots
--   - automatic join-close timestamp
--   - inactivity evaluation round and timestamp
--   - deterministic first useful round resolver
--   - authenticated preview RPC
--
-- Does not cover yet:
--   - create_league_v2_rpc
--   - public catalog
--   - public join
--   - automatic roster closure workflow
--   - inactivity cleanup workflow
-- ============================================================================

begin;

-- ----------------------------------------------------------------------------
-- 1. EXTEND THE CANONICAL LEAGUES TABLE
-- ----------------------------------------------------------------------------
-- starts_from_fantagol_round_id already exists and remains the canonical
-- reference to the first FantaGol Round used by the league.

alter table public.leagues
  add column if not exists visibility text not null default 'private',
  add column if not exists first_useful_kickoff_at timestamptz,
  add column if not exists automatic_join_close_at timestamptz,
  add column if not exists inactivity_evaluation_round_id uuid,
  add column if not exists inactivity_evaluation_at timestamptz,
  add column if not exists public_schedule_version integer not null default 1;

-- Existing leagues are private by definition at migration time.
update public.leagues
set visibility = 'private'
where visibility is null
   or visibility not in ('private', 'public');

-- ----------------------------------------------------------------------------
-- 2. FOREIGN KEYS AND CHECK CONSTRAINTS
-- ----------------------------------------------------------------------------

do $$
begin
  if not exists (
    select 1
    from pg_constraint
    where conrelid = 'public.leagues'::regclass
      and conname = 'leagues_inactivity_evaluation_round_id_fkey'
  ) then
    alter table public.leagues
      add constraint leagues_inactivity_evaluation_round_id_fkey
      foreign key (inactivity_evaluation_round_id)
      references public.fantagol_rounds(id)
      on delete restrict;
  end if;

  if not exists (
    select 1
    from pg_constraint
    where conrelid = 'public.leagues'::regclass
      and conname = 'leagues_visibility_check'
  ) then
    alter table public.leagues
      add constraint leagues_visibility_check
      check (visibility in ('private', 'public'));
  end if;

  if not exists (
    select 1
    from pg_constraint
    where conrelid = 'public.leagues'::regclass
      and conname = 'leagues_public_schedule_version_positive_check'
  ) then
    alter table public.leagues
      add constraint leagues_public_schedule_version_positive_check
      check (public_schedule_version > 0);
  end if;

  if not exists (
    select 1
    from pg_constraint
    where conrelid = 'public.leagues'::regclass
      and conname = 'leagues_public_schedule_required_check'
  ) then
    alter table public.leagues
      add constraint leagues_public_schedule_required_check
      check (
        visibility <> 'public'
        or (
          starts_from_fantagol_round_id is not null
          and first_useful_kickoff_at is not null
          and automatic_join_close_at is not null
          and inactivity_evaluation_round_id is not null
          and inactivity_evaluation_at is not null
        )
      );
  end if;

  if not exists (
    select 1
    from pg_constraint
    where conrelid = 'public.leagues'::regclass
      and conname = 'leagues_public_join_close_exact_check'
  ) then
    alter table public.leagues
      add constraint leagues_public_join_close_exact_check
      check (
        automatic_join_close_at is null
        or first_useful_kickoff_at is null
        or automatic_join_close_at = first_useful_kickoff_at - interval '24 hours'
      );
  end if;

  if not exists (
    select 1
    from pg_constraint
    where conrelid = 'public.leagues'::regclass
      and conname = 'leagues_public_inactivity_after_start_check'
  ) then
    alter table public.leagues
      add constraint leagues_public_inactivity_after_start_check
      check (
        inactivity_evaluation_at is null
        or first_useful_kickoff_at is null
        or inactivity_evaluation_at > first_useful_kickoff_at
      );
  end if;

  if not exists (
    select 1
    from pg_constraint
    where conrelid = 'public.leagues'::regclass
      and conname = 'leagues_public_schedule_all_or_none_check'
  ) then
    alter table public.leagues
      add constraint leagues_public_schedule_all_or_none_check
      check (
        (
          first_useful_kickoff_at is null
          and automatic_join_close_at is null
          and inactivity_evaluation_round_id is null
          and inactivity_evaluation_at is null
        )
        or
        (
          starts_from_fantagol_round_id is not null
          and first_useful_kickoff_at is not null
          and automatic_join_close_at is not null
          and inactivity_evaluation_round_id is not null
          and inactivity_evaluation_at is not null
        )
      );
  end if;
end;
$$;

-- ----------------------------------------------------------------------------
-- 3. INDEXES
-- ----------------------------------------------------------------------------

create index if not exists leagues_visibility_idx
  on public.leagues(visibility);

create index if not exists leagues_public_catalog_foundation_idx
  on public.leagues(edition_id, roster_status, created_at desc)
  where visibility = 'public';

create index if not exists leagues_public_join_close_due_idx
  on public.leagues(automatic_join_close_at)
  where visibility = 'public'
    and roster_status = 'open';

create index if not exists leagues_public_inactivity_due_idx
  on public.leagues(inactivity_evaluation_at)
  where visibility = 'public';

create index if not exists leagues_inactivity_evaluation_round_idx
  on public.leagues(inactivity_evaluation_round_id)
  where inactivity_evaluation_round_id is not null;

-- ----------------------------------------------------------------------------
-- 4. INTERNAL DETERMINISTIC SCHEDULE RESOLVER
-- ----------------------------------------------------------------------------

create or replace function public.resolve_public_league_schedule_internal(
  target_edition_id uuid,
  reference_at timestamptz
)
returns table(
  starts_from_fantagol_round_id uuid,
  starts_from_round_sequence integer,
  starts_from_round_name text,
  first_useful_kickoff_at timestamptz,
  automatic_join_close_at timestamptz,
  inactivity_evaluation_round_id uuid,
  inactivity_evaluation_at timestamptz,
  schedule_version integer
)
language plpgsql
stable
security definer
set search_path to public
as $function$
declare
  v_reference_at timestamptz := coalesce(reference_at, now());
  v_start_round public.fantagol_rounds%rowtype;
  v_inactivity_round public.fantagol_rounds%rowtype;
begin
  if target_edition_id is null then
    raise exception using
      errcode = 'P0001',
      message = 'PUBLIC_LEAGUE_EDITION_REQUIRED';
  end if;

  if not exists (
    select 1
    from public.competition_editions ce
    where ce.id = target_edition_id
      and ce.active = true
      and ce.status in ('scheduled', 'active')
  ) then
    raise exception using
      errcode = 'P0001',
      message = 'PUBLIC_LEAGUE_EDITION_NOT_FOUND';
  end if;

  select fr.*
  into v_start_round
  from public.fantagol_rounds fr
  where fr.edition_id = target_edition_id
    and fr.active = true
    and fr.status not in ('draft', 'cancelled', 'final_official', 'recalculated')
    and fr.starts_at is not null
    and v_reference_at < fr.starts_at - interval '24 hours'
  order by
    fr.sequence asc,
    fr.starts_at asc,
    fr.id asc
  limit 1;

  if v_start_round.id is null then
    raise exception using
      errcode = 'P0001',
      message = 'PUBLIC_LEAGUE_NO_ELIGIBLE_START_ROUND';
  end if;

  select fr.*
  into v_inactivity_round
  from public.fantagol_rounds fr
  where fr.edition_id = target_edition_id
    and fr.active = true
    and fr.status not in ('draft', 'cancelled')
    and fr.starts_at is not null
    and (
      fr.sequence > v_start_round.sequence
      or (
        fr.sequence = v_start_round.sequence
        and fr.starts_at > v_start_round.starts_at
      )
      or (
        fr.sequence = v_start_round.sequence
        and fr.starts_at = v_start_round.starts_at
        and fr.id > v_start_round.id
      )
    )
  order by
    fr.sequence asc,
    fr.starts_at asc,
    fr.id asc
  limit 1;

  if v_inactivity_round.id is null then
    raise exception using
      errcode = 'P0001',
      message = 'PUBLIC_LEAGUE_NO_INACTIVITY_EVALUATION_ROUND';
  end if;

  if v_start_round.starts_at is null
     or v_inactivity_round.starts_at is null
     or v_inactivity_round.starts_at <= v_start_round.starts_at then
    raise exception using
      errcode = 'P0001',
      message = 'PUBLIC_LEAGUE_ROUND_SCHEDULE_INVALID';
  end if;

  return query
  select
    v_start_round.id,
    v_start_round.sequence,
    v_start_round.name,
    v_start_round.starts_at,
    v_start_round.starts_at - interval '24 hours',
    v_inactivity_round.id,
    v_inactivity_round.starts_at,
    1;
end;
$function$;

comment on function public.resolve_public_league_schedule_internal(uuid, timestamptz)
is 'Internal deterministic resolver for the first useful public league round, automatic join closure and inactivity evaluation reference.';

-- ----------------------------------------------------------------------------
-- 5. AUTHENTICATED PREVIEW RPC
-- ----------------------------------------------------------------------------

create or replace function public.resolve_public_league_schedule_rpc(
  target_edition_id uuid,
  reference_at timestamptz default now()
)
returns table(
  starts_from_fantagol_round_id uuid,
  starts_from_round_sequence integer,
  starts_from_round_name text,
  first_useful_kickoff_at timestamptz,
  automatic_join_close_at timestamptz,
  inactivity_evaluation_round_id uuid,
  inactivity_evaluation_at timestamptz,
  schedule_version integer
)
language plpgsql
stable
security definer
set search_path to public
as $function$
begin
  if auth.uid() is null then
    raise exception using
      errcode = 'P0001',
      message = 'AUTH_REQUIRED';
  end if;

  return query
  select *
  from public.resolve_public_league_schedule_internal(
    target_edition_id,
    coalesce(reference_at, now())
  );
end;
$function$;

comment on function public.resolve_public_league_schedule_rpc(uuid, timestamptz)
is 'Returns the backend-authoritative public league schedule preview for an authenticated user.';

-- ----------------------------------------------------------------------------
-- 6. PRIVILEGES
-- ----------------------------------------------------------------------------

revoke all on function public.resolve_public_league_schedule_internal(uuid, timestamptz)
  from public;
revoke all on function public.resolve_public_league_schedule_internal(uuid, timestamptz)
  from anon;
revoke all on function public.resolve_public_league_schedule_internal(uuid, timestamptz)
  from authenticated;

grant execute on function public.resolve_public_league_schedule_internal(uuid, timestamptz)
  to service_role;

revoke all on function public.resolve_public_league_schedule_rpc(uuid, timestamptz)
  from public;
revoke all on function public.resolve_public_league_schedule_rpc(uuid, timestamptz)
  from anon;

grant execute on function public.resolve_public_league_schedule_rpc(uuid, timestamptz)
  to authenticated;
grant execute on function public.resolve_public_league_schedule_rpc(uuid, timestamptz)
  to service_role;

-- ----------------------------------------------------------------------------
-- 7. DOCUMENTATION
-- ----------------------------------------------------------------------------

comment on column public.leagues.visibility
is 'Canonical league visibility: private or public. It does not replace roster_status.';

comment on column public.leagues.first_useful_kickoff_at
is 'Immutable schedule snapshot of the first kickoff of the public league starting round.';

comment on column public.leagues.automatic_join_close_at
is 'Canonical public join closure timestamp, exactly 24 hours before first_useful_kickoff_at.';

comment on column public.leagues.inactivity_evaluation_round_id
is 'Second useful FantaGol Round used as the inactivity evaluation reference.';

comment on column public.leagues.inactivity_evaluation_at
is 'Earliest timestamp at which public league inactivity may be evaluated.';

comment on column public.leagues.public_schedule_version
is 'Version of the public league schedule contract persisted on the league.';

commit;
