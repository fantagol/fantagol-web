-- ============================================================
-- FANTAGOL MIGRATION 001 — STRATEGY CORE
-- Non-destructive extension of the existing Supabase schema.
-- Review in staging before production.
-- ============================================================

begin;

-- ------------------------------------------------------------
-- 1. EXISTING TABLE EXTENSIONS
-- ------------------------------------------------------------

alter table public.matchdays
  add column if not exists lock_at timestamptz,
  add column if not exists status text not null default 'scheduled',
  add column if not exists official_at timestamptz,
  add column if not exists updated_at timestamptz not null default now();

alter table public.matchdays
  drop constraint if exists matchdays_status_check;

alter table public.matchdays
  add constraint matchdays_status_check
  check (status in ('scheduled','open','locked','live','partial','final','recalculated'));

alter table public.matches
  add column if not exists provider_name text,
  add column if not exists provider_match_id text,
  add column if not exists minute integer,
  add column if not exists live_updated_at timestamptz,
  add column if not exists result_version integer not null default 1,
  add column if not exists updated_at timestamptz not null default now();

alter table public.matches
  drop constraint if exists matches_minute_check;

alter table public.matches
  add constraint matches_minute_check
  check (minute is null or (minute >= 0 and minute <= 150));

alter table public.predictions
  add column if not exists status text not null default 'submitted',
  add column if not exists submitted_at timestamptz,
  add column if not exists locked_at timestamptz,
  add column if not exists version integer not null default 1;

update public.predictions
set submitted_at = coalesce(submitted_at, created_at)
where submitted_at is null;

alter table public.predictions
  alter column submitted_at set default now();

alter table public.predictions
  drop constraint if exists predictions_status_check;

alter table public.predictions
  add constraint predictions_status_check
  check (status in ('draft','submitted','locked','void'));

-- ------------------------------------------------------------
-- 2. LEAGUE MODES
-- ------------------------------------------------------------

create table if not exists public.league_modes (
  league_id uuid not null references public.leagues(id) on delete cascade,
  mode text not null,
  enabled boolean not null default true,
  settings jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key (league_id, mode),
  constraint league_modes_mode_check
    check (mode in ('punti_puri','fantacalcio','one_to_one'))
);

insert into public.league_modes (league_id, mode, enabled)
select l.id, m.mode, true
from public.leagues l
cross join (values ('punti_puri'),('fantacalcio'),('one_to_one')) as m(mode)
on conflict (league_id, mode) do nothing;

-- ------------------------------------------------------------
-- 3. USER-TO-USER FIXTURES
-- ------------------------------------------------------------

create table if not exists public.league_fixtures (
  id uuid primary key default gen_random_uuid(),
  league_id uuid not null references public.leagues(id) on delete cascade,
  matchday_id uuid not null references public.matchdays(id) on delete cascade,
  mode text not null,
  home_user_id uuid not null references auth.users(id) on delete cascade,
  away_user_id uuid not null references auth.users(id) on delete cascade,
  status text not null default 'scheduled',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint league_fixtures_mode_check
    check (mode in ('fantacalcio','one_to_one')),
  constraint league_fixtures_users_different_check
    check (home_user_id <> away_user_id),
  constraint league_fixtures_status_check
    check (status in ('scheduled','open','locked','live','final','recalculated')),
  constraint league_fixtures_unique_pair
    unique (league_id, matchday_id, mode, home_user_id, away_user_id)
);

-- ------------------------------------------------------------
-- 4. FANTACALCIO ATTACK / DEFENSE
-- ------------------------------------------------------------

create table if not exists public.fantacalcio_allocations (
  league_id uuid not null references public.leagues(id) on delete cascade,
  matchday_id uuid not null references public.matchdays(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  match_id uuid not null references public.matches(id) on delete cascade,
  phase text not null,
  position smallint not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key (league_id, matchday_id, user_id, match_id),
  constraint fantacalcio_allocations_phase_check
    check (phase in ('attack','defense')),
  constraint fantacalcio_allocations_position_check
    check (position between 1 and 5),
  constraint fantacalcio_allocations_phase_position_unique
    unique (league_id, matchday_id, user_id, phase, position)
);

-- ------------------------------------------------------------
-- 5. ONE TO ONE MATRICES
-- ------------------------------------------------------------

create table if not exists public.one_to_one_matrix_entries (
  id uuid primary key default gen_random_uuid(),
  fixture_id uuid not null references public.league_fixtures(id) on delete cascade,
  strategist_user_id uuid not null references auth.users(id) on delete cascade,
  opponent_user_id uuid not null references auth.users(id) on delete cascade,
  source_match_id uuid not null references public.matches(id) on delete cascade,
  target_match_id uuid not null references public.matches(id) on delete cascade,
  slot_number smallint not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint one_to_one_matrix_users_different_check
    check (strategist_user_id <> opponent_user_id),
  constraint one_to_one_matrix_slot_check
    check (slot_number between 1 and 10),
  constraint one_to_one_matrix_source_unique
    unique (fixture_id, strategist_user_id, source_match_id),
  constraint one_to_one_matrix_target_unique
    unique (fixture_id, strategist_user_id, target_match_id),
  constraint one_to_one_matrix_slot_unique
    unique (fixture_id, strategist_user_id, slot_number)
);

-- ------------------------------------------------------------
-- 6. INDEXES
-- ------------------------------------------------------------

create index if not exists matches_matchday_kickoff_idx
  on public.matches (matchday_id, kickoff);

create unique index if not exists matches_provider_external_unique_idx
  on public.matches (provider_name, provider_match_id)
  where provider_name is not null and provider_match_id is not null;

create index if not exists predictions_league_match_idx
  on public.predictions (league_id, match_id);

create index if not exists predictions_user_match_idx
  on public.predictions (user_id, match_id);

create index if not exists fantacalcio_allocations_lookup_idx
  on public.fantacalcio_allocations (league_id, matchday_id, user_id);

create index if not exists league_fixtures_lookup_idx
  on public.league_fixtures (league_id, matchday_id, mode);

create index if not exists one_to_one_matrix_lookup_idx
  on public.one_to_one_matrix_entries (fixture_id, strategist_user_id);

-- ------------------------------------------------------------
-- 7. UPDATED_AT TRIGGER FUNCTION
-- ------------------------------------------------------------

create or replace function public.set_updated_at()
returns trigger
language plpgsql
security invoker
set search_path = public
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

create or replace trigger set_matchdays_updated_at
before update on public.matchdays
for each row execute function public.set_updated_at();

create or replace trigger set_matches_updated_at
before update on public.matches
for each row execute function public.set_updated_at();

create or replace trigger set_league_modes_updated_at
before update on public.league_modes
for each row execute function public.set_updated_at();

create or replace trigger set_league_fixtures_updated_at
before update on public.league_fixtures
for each row execute function public.set_updated_at();

create or replace trigger set_fantacalcio_allocations_updated_at
before update on public.fantacalcio_allocations
for each row execute function public.set_updated_at();

create or replace trigger set_one_to_one_matrix_entries_updated_at
before update on public.one_to_one_matrix_entries
for each row execute function public.set_updated_at();

-- ------------------------------------------------------------
-- 8. HELPER FUNCTIONS
-- ------------------------------------------------------------

create or replace function public.is_active_league_member(
  p_league_id uuid,
  p_user_id uuid default auth.uid()
)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1
    from public.league_members lm
    join public.leagues l on l.id = lm.league_id
    where lm.league_id = p_league_id
      and lm.user_id = p_user_id
      and lm.status = 'active'
      and l.status = 'active'
  );
$$;

create or replace function public.is_matchday_open(p_matchday_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1
    from public.matchdays md
    where md.id = p_matchday_id
      and md.status in ('scheduled','open')
      and (md.lock_at is null or now() < md.lock_at)
  );
$$;

-- ------------------------------------------------------------
-- 9. SAVE FANTACALCIO STRATEGY RPC
-- ------------------------------------------------------------

create or replace function public.save_fantacalcio_strategy_rpc(
  p_league_id uuid,
  p_matchday_id uuid,
  p_attack_match_ids uuid[],
  p_defense_match_ids uuid[]
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_all_match_ids uuid[];
  v_unique_count integer;
  v_valid_count integer;
  v_match_id uuid;
  v_position integer;
begin
  if auth.uid() is null then
    raise exception 'User not authenticated';
  end if;

  if not public.is_active_league_member(p_league_id, auth.uid()) then
    raise exception 'User is not an active league member';
  end if;

  if not public.is_matchday_open(p_matchday_id) then
    raise exception 'Matchday is locked';
  end if;

  if coalesce(array_length(p_attack_match_ids, 1), 0) <> 5
     or coalesce(array_length(p_defense_match_ids, 1), 0) <> 5 then
    raise exception 'Fantacalcio strategy requires exactly 5 attack and 5 defense matches';
  end if;

  v_all_match_ids := p_attack_match_ids || p_defense_match_ids;

  select count(distinct x)
  into v_unique_count
  from unnest(v_all_match_ids) as x;

  if v_unique_count <> 10 then
    raise exception 'All 10 matches must be unique';
  end if;

  select count(*)
  into v_valid_count
  from public.matches m
  where m.matchday_id = p_matchday_id
    and m.id = any(v_all_match_ids);

  if v_valid_count <> 10 then
    raise exception 'One or more matches do not belong to the selected matchday';
  end if;

  delete from public.fantacalcio_allocations
  where league_id = p_league_id
    and matchday_id = p_matchday_id
    and user_id = auth.uid();

  v_position := 0;
  foreach v_match_id in array p_attack_match_ids loop
    v_position := v_position + 1;
    insert into public.fantacalcio_allocations (
      league_id, matchday_id, user_id, match_id, phase, position
    ) values (
      p_league_id, p_matchday_id, auth.uid(), v_match_id, 'attack', v_position
    );
  end loop;

  v_position := 0;
  foreach v_match_id in array p_defense_match_ids loop
    v_position := v_position + 1;
    insert into public.fantacalcio_allocations (
      league_id, matchday_id, user_id, match_id, phase, position
    ) values (
      p_league_id, p_matchday_id, auth.uid(), v_match_id, 'defense', v_position
    );
  end loop;
end;
$$;

-- ------------------------------------------------------------
-- 10. SAVE ONE TO ONE MATRIX RPC
-- ------------------------------------------------------------

create or replace function public.save_one_to_one_matrix_rpc(
  p_fixture_id uuid,
  p_source_match_ids uuid[],
  p_target_match_ids uuid[]
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_fixture public.league_fixtures%rowtype;
  v_opponent_user_id uuid;
  v_unique_source_count integer;
  v_unique_target_count integer;
  v_valid_source_count integer;
  v_valid_target_count integer;
  v_index integer;
begin
  if auth.uid() is null then
    raise exception 'User not authenticated';
  end if;

  select *
  into v_fixture
  from public.league_fixtures
  where id = p_fixture_id
    and mode = 'one_to_one';

  if not found then
    raise exception 'One To One fixture not found';
  end if;

  if auth.uid() = v_fixture.home_user_id then
    v_opponent_user_id := v_fixture.away_user_id;
  elsif auth.uid() = v_fixture.away_user_id then
    v_opponent_user_id := v_fixture.home_user_id;
  else
    raise exception 'User is not part of this fixture';
  end if;

  if not public.is_matchday_open(v_fixture.matchday_id) then
    raise exception 'Matchday is locked';
  end if;

  if coalesce(array_length(p_source_match_ids, 1), 0) <> 10
     or coalesce(array_length(p_target_match_ids, 1), 0) <> 10 then
    raise exception 'One To One matrix requires 10 source and 10 target matches';
  end if;

  select count(distinct x) into v_unique_source_count
  from unnest(p_source_match_ids) as x;

  select count(distinct x) into v_unique_target_count
  from unnest(p_target_match_ids) as x;

  if v_unique_source_count <> 10 or v_unique_target_count <> 10 then
    raise exception 'Source and target match lists must be permutations without duplicates';
  end if;

  select count(*) into v_valid_source_count
  from public.matches m
  where m.matchday_id = v_fixture.matchday_id
    and m.id = any(p_source_match_ids);

  select count(*) into v_valid_target_count
  from public.matches m
  where m.matchday_id = v_fixture.matchday_id
    and m.id = any(p_target_match_ids);

  if v_valid_source_count <> 10 or v_valid_target_count <> 10 then
    raise exception 'All matrix matches must belong to the fixture matchday';
  end if;

  delete from public.one_to_one_matrix_entries
  where fixture_id = p_fixture_id
    and strategist_user_id = auth.uid();

  for v_index in 1..10 loop
    insert into public.one_to_one_matrix_entries (
      fixture_id,
      strategist_user_id,
      opponent_user_id,
      source_match_id,
      target_match_id,
      slot_number
    ) values (
      p_fixture_id,
      auth.uid(),
      v_opponent_user_id,
      p_source_match_ids[v_index],
      p_target_match_ids[v_index],
      v_index
    );
  end loop;
end;
$$;

-- ------------------------------------------------------------
-- 11. RLS
-- ------------------------------------------------------------

alter table public.league_modes enable row level security;
alter table public.league_fixtures enable row level security;
alter table public.fantacalcio_allocations enable row level security;
alter table public.one_to_one_matrix_entries enable row level security;

-- league_modes
create policy "League members can read league modes"
on public.league_modes
for select
to authenticated
using (public.is_active_league_member(league_id, auth.uid()));

-- fixtures
create policy "League members can read fixtures"
on public.league_fixtures
for select
to authenticated
using (public.is_active_league_member(league_id, auth.uid()));

-- Fantacalcio allocations: owner may read own strategy; league members may read after lock.
create policy "Users can read visible fantacalcio allocations"
on public.fantacalcio_allocations
for select
to authenticated
using (
  user_id = auth.uid()
  or (
    public.is_active_league_member(league_id, auth.uid())
    and not public.is_matchday_open(matchday_id)
  )
);

-- One To One matrix: author before lock; both fixture users after lock.
create policy "Users can read visible one to one matrices"
on public.one_to_one_matrix_entries
for select
to authenticated
using (
  strategist_user_id = auth.uid()
  or exists (
    select 1
    from public.league_fixtures f
    where f.id = fixture_id
      and auth.uid() in (f.home_user_id, f.away_user_id)
      and not public.is_matchday_open(f.matchday_id)
  )
);

-- No direct client writes: strategy writes go through SECURITY DEFINER RPCs.

-- ------------------------------------------------------------
-- 12. FUNCTION PRIVILEGES
-- ------------------------------------------------------------

revoke all on function public.save_fantacalcio_strategy_rpc(uuid, uuid, uuid[], uuid[]) from public;
grant execute on function public.save_fantacalcio_strategy_rpc(uuid, uuid, uuid[], uuid[]) to authenticated;

revoke all on function public.save_one_to_one_matrix_rpc(uuid, uuid[], uuid[]) from public;
grant execute on function public.save_one_to_one_matrix_rpc(uuid, uuid[], uuid[]) to authenticated;

revoke all on function public.is_active_league_member(uuid, uuid) from public;
grant execute on function public.is_active_league_member(uuid, uuid) to authenticated, service_role;

revoke all on function public.is_matchday_open(uuid) from public;
grant execute on function public.is_matchday_open(uuid) to authenticated, service_role;

commit;
