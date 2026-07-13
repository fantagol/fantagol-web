-- ============================================================================
-- FANTAGOL 017 - SCHEDULE ENGINE AMBIGUOUS LEAGUE ID HOTFIX
-- Qualifies league_id references inside RETURNS TABLE PL/pgSQL functions.
-- ============================================================================

begin;

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

  update public.league_schedule_versions as lsv
  set active = false
  where lsv.league_id = p_league_id
    and lsv.active = true;

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
  on conflict on constraint league_rounds_league_fantagol_unique do nothing;

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
  'schedule_engine_ambiguous_league_id_hotfix_installed',
  'competition_edition',
  '00000000-0000-4000-8000-000000000201'::uuid,
  null,
  jsonb_build_object(
    'qualified_schedule_version_update', true,
    'named_league_round_conflict_constraint', true
  ),
  'Fix ambiguous league_id references in schedule generation and roster lock',
  null
);

commit;
