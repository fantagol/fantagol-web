-- ============================================================================
-- FANTAGOL 016 - LEAGUE COMPETITION SCHEDULE ENGINE
-- Versioned Fantacalcio / One-to-One H2H schedule generation
-- ============================================================================

begin;

-- --------------------------------------------------------------------------
-- 1. Extend governance event vocabulary.
-- --------------------------------------------------------------------------

alter table public.league_admin_events
  drop constraint if exists league_admin_events_action_type_check;

alter table public.league_admin_events
  add constraint league_admin_events_action_type_check
  check (
    action_type = any (array[
      'league_created'::text,
      'member_joined'::text,
      'member_rejoined'::text,
      'roster_locked'::text,
      'roster_reopened'::text,
      'league_started'::text,
      'league_archived'::text,
      'vice_assigned'::text,
      'vice_revoked'::text,
      'admin_resigned'::text,
      'admin_demoted_for_inactivity'::text,
      'vice_promoted_to_admin'::text,
      'admin_assigned_from_ranking'::text,
      'admin_assigned_by_seniority'::text,
      'member_removed'::text,
      'member_reinstated'::text,
      'member_withdrawn'::text,
      'league_schedules_generated'::text,
      'league_schedules_regenerated'::text,
      'league_schedules_preserved'::text,
      'league_schedules_locked'::text,
      'prediction_recovery_opened'::text,
      'prediction_recovery_used'::text,
      'prediction_recovery_revoked'::text,
      'prediction_recovery_expired'::text,
      'postponed_match_detected'::text,
      'postponed_match_reopened'::text,
      'postponed_match_excluded'::text,
      'calculation_preview_created'::text,
      'calculation_preview_failed'::text,
      'round_certification_committed'::text,
      'round_certification_superseded'::text,
      'scoring_profile_changed'::text,
      'league_settings_changed'::text
    ])
  );

-- --------------------------------------------------------------------------
-- 2. Schedule versions.
-- One active version per league. Old versions remain available for audit.
-- --------------------------------------------------------------------------

create table if not exists public.league_schedule_versions (
  id uuid primary key default gen_random_uuid(),
  league_id uuid not null
    references public.leagues(id) on delete cascade,
  version integer not null,
  roster_member_ids uuid[] not null,
  roster_hash text not null,
  member_count integer not null,
  has_bye boolean not null,
  generated_by_member_id uuid null
    references public.league_members(id) on delete set null,
  reason text not null,
  active boolean not null default true,
  generated_at timestamptz not null default now(),
  locked_at timestamptz null,
  constraint league_schedule_versions_league_version_unique
    unique (league_id, version),
  constraint league_schedule_versions_version_positive
    check (version > 0),
  constraint league_schedule_versions_member_count_minimum
    check (member_count >= 2),
  constraint league_schedule_versions_roster_not_empty
    check (cardinality(roster_member_ids) >= 2),
  constraint league_schedule_versions_reason_not_blank
    check (trim(reason) <> '')
);

create unique index if not exists league_schedule_versions_one_active_idx
  on public.league_schedule_versions (league_id)
  where active = true;

create index if not exists league_schedule_versions_league_idx
  on public.league_schedule_versions (league_id, version desc);

alter table public.league_schedule_versions enable row level security;

drop policy if exists league_schedule_versions_select_members
  on public.league_schedule_versions;

create policy league_schedule_versions_select_members
on public.league_schedule_versions
for select
to authenticated
using (
  exists (
    select 1
    from public.league_members lm
    where lm.league_id = league_schedule_versions.league_id
      and lm.user_id = auth.uid()
  )
);

-- --------------------------------------------------------------------------
-- 3. Versioned H2H fixtures.
--
-- A BYE (Turno di riposo) is represented by:
--   is_bye = true
--   home_member_id = member receiving the rest turn
--   away_member_id = null
-- --------------------------------------------------------------------------

create table if not exists public.league_fixtures (
  id uuid primary key default gen_random_uuid(),
  schedule_version_id uuid not null
    references public.league_schedule_versions(id) on delete cascade,
  league_id uuid not null
    references public.leagues(id) on delete cascade,
  league_round_id uuid not null
    references public.league_rounds(id) on delete cascade,
  mode text not null,
  cycle_number integer not null,
  leg_number integer not null,
  pairing_round_number integer not null,
  home_member_id uuid not null
    references public.league_members(id) on delete restrict,
  away_member_id uuid null
    references public.league_members(id) on delete restrict,
  is_bye boolean not null default false,
  created_at timestamptz not null default now(),
  constraint league_fixtures_mode_check
    check (mode in ('fantacalcio', 'one_to_one')),
  constraint league_fixtures_cycle_positive
    check (cycle_number > 0),
  constraint league_fixtures_leg_check
    check (leg_number in (1, 2)),
  constraint league_fixtures_pairing_round_positive
    check (pairing_round_number > 0),
  constraint league_fixtures_members_distinct
    check (away_member_id is null or home_member_id <> away_member_id),
  constraint league_fixtures_bye_consistency
    check (
      (is_bye = true and away_member_id is null)
      or
      (is_bye = false and away_member_id is not null)
    )
);

create unique index if not exists league_fixtures_unique_pairing_idx
  on public.league_fixtures (
    schedule_version_id,
    mode,
    league_round_id,
    home_member_id,
    coalesce(away_member_id, '00000000-0000-0000-0000-000000000000'::uuid)
  );

create index if not exists league_fixtures_league_round_mode_idx
  on public.league_fixtures (league_id, league_round_id, mode);

create index if not exists league_fixtures_home_member_idx
  on public.league_fixtures (home_member_id, league_round_id, mode);

create index if not exists league_fixtures_away_member_idx
  on public.league_fixtures (away_member_id, league_round_id, mode)
  where away_member_id is not null;

alter table public.league_fixtures enable row level security;

drop policy if exists league_fixtures_select_members
  on public.league_fixtures;

create policy league_fixtures_select_members
on public.league_fixtures
for select
to authenticated
using (
  exists (
    select 1
    from public.league_members lm
    where lm.league_id = league_fixtures.league_id
      and lm.user_id = auth.uid()
  )
);

-- --------------------------------------------------------------------------
-- 4. Pure roster hash helper.
-- --------------------------------------------------------------------------

create or replace function public.compute_league_roster_hash(
  p_member_ids uuid[]
)
returns text
language sql
immutable
set search_path to public
as $function$
  select public.compute_jsonb_sha256(to_jsonb(p_member_ids));
$function$;

-- --------------------------------------------------------------------------
-- 5. Generate a complete round-robin schedule for both H2H modes.
--
-- Rules:
--   * active members only;
--   * odd roster gets one BYE (Turno di riposo) per pairing round;
--   * first and second legs reverse home/away;
--   * complete two-leg cycles repeat until all League Rounds are covered;
--   * Fantacalcio and One-to-One receive independent deterministic shuffles;
--   * previous active schedule version becomes inactive, never deleted.
-- --------------------------------------------------------------------------

create or replace function public.generate_league_competitions(
  p_league_id uuid,
  p_generated_by_member_id uuid,
  p_reason text default 'Roster lock schedule generation'
)
returns table (
  schedule_version_id uuid,
  schedule_version integer,
  fixture_count integer,
  bye_fixture_count integer,
  member_count integer,
  has_bye boolean
)
language plpgsql
security definer
set search_path to public
as $function$
declare
  v_league public.leagues%rowtype;
  v_member_ids uuid[];
  v_member_count integer;
  v_has_bye boolean;
  v_roster_hash text;
  v_next_version integer;
  v_schedule_version_id uuid;
  v_round_ids uuid[];
  v_round_count integer;
  v_mode text;
  v_seed text;
  v_ordered_ids uuid[];
  v_positions uuid[];
  v_slot_count integer;
  v_rotating_count integer;
  v_round_index integer;
  v_base_round integer;
  v_cycle_number integer;
  v_leg_number integer;
  v_pair_index integer;
  v_position_index integer;
  v_rotated_index integer;
  v_home uuid;
  v_away uuid;
  v_tmp uuid;
  v_fixture_count integer := 0;
  v_bye_count integer := 0;
begin
  select l.*
  into v_league
  from public.leagues l
  where l.id = p_league_id
  for update;

  if v_league.id is null then
    raise exception using errcode = 'P0001', message = 'LEAGUE_NOT_FOUND';
  end if;

  select array_agg(lm.id order by lm.id)
  into v_member_ids
  from public.league_members lm
  where lm.league_id = p_league_id
    and lm.status = 'active';

  v_member_count := coalesce(cardinality(v_member_ids), 0);

  if v_member_count < 2 then
    raise exception using errcode = 'P0001', message = 'MINIMUM_TWO_ACTIVE_MEMBERS_REQUIRED';
  end if;

  if p_generated_by_member_id is null
     or not exists (
       select 1
       from public.league_members lm
       where lm.id = p_generated_by_member_id
         and lm.league_id = p_league_id
         and lm.role = 'admin'
         and lm.status = 'active'
     ) then
    raise exception using errcode = 'P0001', message = 'ACTIVE_ADMIN_REQUIRED';
  end if;

  select array_agg(lr.id order by lr.league_round_number)
  into v_round_ids
  from public.league_rounds lr
  where lr.league_id = p_league_id
    and lr.enabled = true
    and lr.status <> 'cancelled';

  v_round_count := coalesce(cardinality(v_round_ids), 0);

  if v_round_count = 0 then
    raise exception using errcode = 'P0001', message = 'LEAGUE_ROUNDS_REQUIRED';
  end if;

  v_has_bye := mod(v_member_count, 2) = 1;
  v_roster_hash := public.compute_league_roster_hash(v_member_ids);

  select coalesce(max(lsv.version), 0) + 1
  into v_next_version
  from public.league_schedule_versions lsv
  where lsv.league_id = p_league_id;

  update public.league_schedule_versions
  set active = false
  where league_id = p_league_id
    and active = true;

  insert into public.league_schedule_versions (
    league_id,
    version,
    roster_member_ids,
    roster_hash,
    member_count,
    has_bye,
    generated_by_member_id,
    reason,
    active
  )
  values (
    p_league_id,
    v_next_version,
    v_member_ids,
    v_roster_hash,
    v_member_count,
    v_has_bye,
    p_generated_by_member_id,
    coalesce(nullif(trim(p_reason), ''), 'Roster lock schedule generation'),
    true
  )
  returning id into v_schedule_version_id;

  foreach v_mode in array array['fantacalcio'::text, 'one_to_one'::text]
  loop
    v_seed := v_schedule_version_id::text || ':' || v_mode;

    select array_agg(x.member_id order by md5(x.member_id::text || v_seed))
    into v_ordered_ids
    from unnest(v_member_ids) as x(member_id);

    if v_has_bye then
      v_ordered_ids := array_append(v_ordered_ids, null::uuid);
    end if;

    v_slot_count := cardinality(v_ordered_ids);
    v_rotating_count := v_slot_count - 1;

    for v_round_index in 1..v_round_count
    loop
      v_base_round := mod(v_round_index - 1, v_slot_count - 1) + 1;
      v_cycle_number := ((v_round_index - 1) / ((v_slot_count - 1) * 2)) + 1;
      v_leg_number := mod((v_round_index - 1) / (v_slot_count - 1), 2) + 1;

      v_positions := array_fill(null::uuid, array[v_slot_count]);
      v_positions[1] := v_ordered_ids[1];

      for v_position_index in 2..v_slot_count
      loop
        v_rotated_index :=
          2 + mod(
            (v_position_index - 2) - (v_base_round - 1) + (v_rotating_count * 1000),
            v_rotating_count
          );
        v_positions[v_position_index] := v_ordered_ids[v_rotated_index];
      end loop;

      for v_pair_index in 1..(v_slot_count / 2)
      loop
        v_home := v_positions[v_pair_index];
        v_away := v_positions[v_slot_count - v_pair_index + 1];

        -- Reverse home/away on the second leg.
        if v_leg_number = 2 then
          v_tmp := v_home;
          v_home := v_away;
          v_away := v_tmp;
        end if;

        -- Keep the actual member in home_member_id for BYE rows.
        if v_home is null and v_away is not null then
          v_home := v_away;
          v_away := null;
        end if;

        if v_home is null then
          raise exception using errcode = 'P0001', message = 'INVALID_SCHEDULE_PAIRING';
        end if;

        insert into public.league_fixtures (
          schedule_version_id,
          league_id,
          league_round_id,
          mode,
          cycle_number,
          leg_number,
          pairing_round_number,
          home_member_id,
          away_member_id,
          is_bye
        )
        values (
          v_schedule_version_id,
          p_league_id,
          v_round_ids[v_round_index],
          v_mode,
          v_cycle_number,
          v_leg_number,
          v_base_round,
          v_home,
          v_away,
          v_away is null
        );

        v_fixture_count := v_fixture_count + 1;
        if v_away is null then
          v_bye_count := v_bye_count + 1;
        end if;
      end loop;
    end loop;
  end loop;

  return query
  select
    v_schedule_version_id,
    v_next_version,
    v_fixture_count,
    v_bye_count,
    v_member_count,
    v_has_bye;
end;
$function$;

-- --------------------------------------------------------------------------
-- 6. Read current schedule state for the hamburger / UI.
-- --------------------------------------------------------------------------

create or replace function public.get_league_lifecycle_state_rpc(
  target_league_id uuid
)
returns table (
  league_id uuid,
  lifecycle_status text,
  roster_status text,
  first_scored_at timestamptz,
  starts_from_fantagol_round_id uuid,
  first_round_lock_at timestamptz,
  active_member_count integer,
  active_vice_count integer,
  schedule_version integer,
  schedule_roster_hash text,
  schedule_member_count integer,
  schedule_has_bye boolean,
  schedule_generated_at timestamptz
)
language plpgsql
stable
security definer
set search_path to public
as $function$
declare
  v_user_id uuid := auth.uid();
begin
  if v_user_id is null then
    raise exception using errcode = 'P0001', message = 'AUTH_REQUIRED';
  end if;

  if not exists (
    select 1
    from public.league_members lm
    where lm.league_id = target_league_id
      and lm.user_id = v_user_id
  ) then
    raise exception using errcode = 'P0001', message = 'LEAGUE_MEMBERSHIP_REQUIRED';
  end if;

  return query
  select
    l.id,
    l.lifecycle_status,
    l.roster_status,
    l.first_scored_at,
    l.starts_from_fantagol_round_id,
    fr.lock_at,
    (
      select count(*)::integer
      from public.league_members lm
      where lm.league_id = l.id
        and lm.status = 'active'
    ),
    (
      select count(*)::integer
      from public.league_members lm
      where lm.league_id = l.id
        and lm.status = 'active'
        and lm.role = 'vice'
    ),
    lsv.version,
    lsv.roster_hash,
    lsv.member_count,
    lsv.has_bye,
    lsv.generated_at
  from public.leagues l
  left join public.fantagol_rounds fr
    on fr.id = l.starts_from_fantagol_round_id
  left join public.league_schedule_versions lsv
    on lsv.league_id = l.id
   and lsv.active = true
  where l.id = target_league_id;
end;
$function$;

-- --------------------------------------------------------------------------
-- 7. Replace roster lock RPC.
--
-- regenerate_schedules:
--   true  -> create a new schedule version;
--   false -> preserve only if active roster hash is unchanged.
-- A changed roster always forces regeneration.
-- --------------------------------------------------------------------------

drop function if exists public.lock_league_roster_rpc(uuid);

create or replace function public.lock_league_roster_rpc(
  target_league_id uuid,
  regenerate_schedules boolean default true
)
returns table(
  league_id uuid,
  starts_from_fantagol_round_id uuid,
  generated_league_rounds integer,
  first_league_round_id uuid
)
language plpgsql
security definer
set search_path to public
as $function$
declare
  v_user_id uuid := auth.uid();
  v_admin_member_id uuid;
  v_league public.leagues%rowtype;
  v_active_member_ids uuid[];
  v_active_member_count integer;
  v_active_vice_count integer;
  v_current_roster_hash text;
  v_existing_schedule public.league_schedule_versions%rowtype;
  v_start_round public.fantagol_rounds%rowtype;
  v_inserted_count integer := 0;
  v_first_league_round_id uuid;
  v_generated_schedule record;
  v_schedule_action text;
begin
  if v_user_id is null then
    raise exception using errcode = 'P0001', message = 'AUTH_REQUIRED';
  end if;

  v_admin_member_id := public.get_active_admin_member_id(target_league_id, v_user_id);
  if v_admin_member_id is null then
    raise exception using errcode = 'P0001', message = 'ACTIVE_ADMIN_REQUIRED';
  end if;

  select l.*
  into v_league
  from public.leagues l
  where l.id = target_league_id
  for update;

  if v_league.id is null then
    raise exception using errcode = 'P0001', message = 'LEAGUE_NOT_FOUND';
  end if;

  if v_league.lifecycle_status in ('completed', 'archived') then
    raise exception using errcode = 'P0001', message = 'LEAGUE_NOT_LOCKABLE';
  end if;

  if v_league.first_scored_at is not null then
    raise exception using errcode = 'P0001', message = 'LEAGUE_ALREADY_SCORED';
  end if;

  select array_agg(lm.id order by lm.id)
  into v_active_member_ids
  from public.league_members lm
  where lm.league_id = target_league_id
    and lm.status = 'active';

  v_active_member_count := coalesce(cardinality(v_active_member_ids), 0);

  if v_active_member_count < 2 then
    raise exception using errcode = 'P0001', message = 'MINIMUM_TWO_ACTIVE_MEMBERS_REQUIRED';
  end if;

  select count(*)::integer
  into v_active_vice_count
  from public.league_members lm
  where lm.league_id = target_league_id
    and lm.role = 'vice'
    and lm.status = 'active';

  if v_league.vice_required and v_active_vice_count <> 1 then
    raise exception using errcode = 'P0001', message = 'ACTIVE_VICE_REQUIRED';
  end if;

  if v_league.starts_from_fantagol_round_id is not null then
    select fr.*
    into v_start_round
    from public.fantagol_rounds fr
    where fr.id = v_league.starts_from_fantagol_round_id
      and fr.edition_id = v_league.edition_id
      and fr.active = true;

    if v_start_round.id is null or now() >= v_start_round.lock_at then
      raise exception using errcode = 'P0001', message = 'LEAGUE_FIRST_ROUND_ALREADY_STARTED';
    end if;
  else
    select fr.*
    into v_start_round
    from public.fantagol_rounds fr
    where fr.edition_id = v_league.edition_id
      and fr.active = true
      and fr.lock_at > now()
      and fr.status not in ('cancelled', 'final_official', 'recalculated')
    order by fr.lock_at, fr.sequence
    limit 1;

    if v_start_round.id is null then
      raise exception using errcode = 'P0001', message = 'NO_FUTURE_FANTAGOL_ROUND_AVAILABLE';
    end if;
  end if;

  insert into public.league_rounds (
    league_id,
    fantagol_round_id,
    league_round_number,
    status,
    enabled
  )
  select
    target_league_id,
    fr.id,
    row_number() over (order by fr.sequence)::integer,
    case
      when fr.id = v_start_round.id and now() >= fr.opens_at and now() < fr.lock_at
        then 'predictions_open'
      else 'scheduled'
    end,
    true
  from public.fantagol_rounds fr
  where fr.edition_id = v_league.edition_id
    and fr.active = true
    and fr.sequence >= v_start_round.sequence
    and fr.status <> 'cancelled'
  order by fr.sequence
  on conflict (league_id, fantagol_round_id) do nothing;

  get diagnostics v_inserted_count = row_count;

  select lr.id
  into v_first_league_round_id
  from public.league_rounds lr
  where lr.league_id = target_league_id
    and lr.fantagol_round_id = v_start_round.id
  limit 1;

  v_current_roster_hash :=
    public.compute_league_roster_hash(v_active_member_ids);

  select lsv.*
  into v_existing_schedule
  from public.league_schedule_versions lsv
  where lsv.league_id = target_league_id
    and lsv.active = true
  limit 1
  for update;

  if v_existing_schedule.id is null
     or v_existing_schedule.roster_hash <> v_current_roster_hash
     or regenerate_schedules then

    select *
    into v_generated_schedule
    from public.generate_league_competitions(
      target_league_id,
      v_admin_member_id,
      case
        when v_existing_schedule.id is null
          then 'Initial roster lock schedule generation'
        when v_existing_schedule.roster_hash <> v_current_roster_hash
          then 'Mandatory regeneration because active roster changed'
        else 'Admin requested schedule regeneration'
      end
    );

    v_schedule_action :=
      case
        when v_existing_schedule.id is null
          then 'league_schedules_generated'
        else 'league_schedules_regenerated'
      end;
  else
    v_schedule_action := 'league_schedules_preserved';
  end if;

  update public.leagues
  set
    starts_from_fantagol_round_id = v_start_round.id,
    roster_status = 'locked',
    roster_locked_at = now(),
    lifecycle_status = 'locked',
    started_at = coalesce(started_at, v_start_round.starts_at)
  where id = target_league_id;

  perform public.write_league_admin_event(
    target_league_id,
    v_admin_member_id,
    v_user_id,
    'member',
    v_schedule_action,
    null,
    v_first_league_round_id,
    jsonb_build_object(
      'active_member_count', v_active_member_count,
      'has_bye', mod(v_active_member_count, 2) = 1,
      'roster_hash', v_current_roster_hash,
      'regeneration_requested', regenerate_schedules,
      'schedule_version',
        case
          when v_schedule_action = 'league_schedules_preserved'
            then v_existing_schedule.version
          else v_generated_schedule.schedule_version
        end
    )
  );

  perform public.write_league_admin_event(
    target_league_id,
    v_admin_member_id,
    v_user_id,
    'member',
    'roster_locked',
    null,
    v_first_league_round_id,
    jsonb_build_object(
      'active_member_count', v_active_member_count,
      'start_fantagol_round_id', v_start_round.id,
      'start_sequence', v_start_round.sequence,
      'first_lock_at', v_start_round.lock_at,
      'generated_league_rounds', v_inserted_count,
      'h2h_schedules_ready', true
    )
  );

  return query
  select target_league_id, v_start_round.id, v_inserted_count, v_first_league_round_id;
end;
$function$;

-- --------------------------------------------------------------------------
-- 8. Grants.
-- --------------------------------------------------------------------------

revoke all on function public.compute_league_roster_hash(uuid[])
from public, anon, authenticated;

revoke all on function public.generate_league_competitions(uuid, uuid, text)
from public, anon, authenticated;

revoke all on function public.get_league_lifecycle_state_rpc(uuid)
from public, anon;

revoke all on function public.lock_league_roster_rpc(uuid, boolean)
from public, anon;

grant execute on function public.get_league_lifecycle_state_rpc(uuid)
to authenticated;

grant execute on function public.lock_league_roster_rpc(uuid, boolean)
to authenticated;

-- --------------------------------------------------------------------------
-- 9. Installation audit.
-- --------------------------------------------------------------------------

insert into public.competition_audit_log (
  actor_id,
  action,
  aggregate_type,
  aggregate_id,
  before_json,
  after_json,
  reason,
  correlation_id
)
values (
  null,
  'league_competition_schedule_engine_installed',
  'competition_edition',
  '00000000-0000-4000-8000-000000000201'::uuid,
  null,
  jsonb_build_object(
    'schedule_versions', true,
    'fantacalcio_fixtures', true,
    'one_to_one_fixtures', true,
    'round_robin', true,
    'double_leg', true,
    'bye_turno_di_riposo', true,
    'controlled_regeneration', true
  ),
  'Install versioned league H2H competition schedule engine',
  null
);

commit;
