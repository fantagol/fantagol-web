-- FANTAGOL
-- Migration 059
-- Competition Engine v1.1
-- Deterministic cross-mode BYE coordination
--
-- Invariant:
-- For odd-sized rosters, the same member must not receive a BYE in both
-- Fantacalcio and One-to-One in the same league round.
--
-- Historical schedule versions are not modified.
-- The invariant applies only to newly generated schedule versions.

begin;

create or replace function public.generate_league_competitions(
  p_league_id uuid,
  p_generated_by_member_id uuid,
  p_reason text default 'Roster lock schedule generation'::text
)
returns table(
  schedule_version_id uuid,
  schedule_version integer,
  fixture_count integer,
  bye_fixture_count integer,
  member_count integer,
  has_bye boolean
)
language plpgsql
security definer
set search_path to 'public'
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
  v_fantacalcio_ordered_ids uuid[];
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
    raise exception using
      errcode = 'P0001',
      message = 'LEAGUE_NOT_FOUND';
  end if;

  select array_agg(lm.id order by lm.id)
  into v_member_ids
  from public.league_members lm
  where lm.league_id = p_league_id
    and lm.status = 'active';

  v_member_count := coalesce(cardinality(v_member_ids), 0);

  if v_member_count < 2 then
    raise exception using
      errcode = 'P0001',
      message = 'MINIMUM_TWO_ACTIVE_MEMBERS_REQUIRED';
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
    raise exception using
      errcode = 'P0001',
      message = 'ACTIVE_ADMIN_REQUIRED';
  end if;

  select array_agg(lr.id order by lr.league_round_number)
  into v_round_ids
  from public.league_rounds lr
  where lr.league_id = p_league_id
    and lr.enabled = true
    and lr.status <> 'cancelled';

  v_round_count := coalesce(cardinality(v_round_ids), 0);

  if v_round_count = 0 then
    raise exception using
      errcode = 'P0001',
      message = 'LEAGUE_ROUNDS_REQUIRED';
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
    coalesce(
      nullif(trim(p_reason), ''),
      'Roster lock schedule generation'
    ),
    true
  )
  returning id into v_schedule_version_id;

  foreach v_mode in array array[
    'fantacalcio'::text,
    'one_to_one'::text
  ]
  loop
    if v_mode = 'fantacalcio' then
      v_seed := v_schedule_version_id::text || ':fantacalcio';

      select array_agg(
        x.member_id
        order by md5(x.member_id::text || v_seed)
      )
      into v_ordered_ids
      from unnest(v_member_ids) as x(member_id);

      v_fantacalcio_ordered_ids := v_ordered_ids;
    else
      if v_has_bye then
        /*
         * Cross-mode BYE coordination.
         *
         * The Circle Method remains unchanged. One-to-One starts from the
         * deterministic Fantacalcio ordering rotated by one member.
         *
         * For an odd roster this shifts the complete BYE sequence by one
         * participant for every pairing round and every repeated cycle.
         * Therefore the same member cannot be in BYE in both modes during
         * the same league round.
         */
        v_ordered_ids :=
          v_fantacalcio_ordered_ids[2:v_member_count]
          || array[v_fantacalcio_ordered_ids[1]];
      else
        /*
         * Even rosters have no BYE. Preserve the independently seeded
         * One-to-One ordering used by the previous engine version.
         */
        v_seed := v_schedule_version_id::text || ':one_to_one';

        select array_agg(
          x.member_id
          order by md5(x.member_id::text || v_seed)
        )
        into v_ordered_ids
        from unnest(v_member_ids) as x(member_id);
      end if;
    end if;

    if v_has_bye then
      v_ordered_ids := array_append(v_ordered_ids, null::uuid);
    end if;

    v_slot_count := cardinality(v_ordered_ids);
    v_rotating_count := v_slot_count - 1;

    for v_round_index in 1..v_round_count
    loop
      v_base_round :=
        mod(v_round_index - 1, v_slot_count - 1) + 1;

      v_cycle_number :=
        ((v_round_index - 1) / ((v_slot_count - 1) * 2)) + 1;

      v_leg_number :=
        mod(
          (v_round_index - 1) / (v_slot_count - 1),
          2
        ) + 1;

      v_positions :=
        array_fill(null::uuid, array[v_slot_count]);

      v_positions[1] := v_ordered_ids[1];

      for v_position_index in 2..v_slot_count
      loop
        v_rotated_index :=
          2 + mod(
            (v_position_index - 2)
            - (v_base_round - 1)
            + (v_rotating_count * 1000),
            v_rotating_count
          );

        v_positions[v_position_index] :=
          v_ordered_ids[v_rotated_index];
      end loop;

      for v_pair_index in 1..(v_slot_count / 2)
      loop
        v_home := v_positions[v_pair_index];
        v_away :=
          v_positions[v_slot_count - v_pair_index + 1];

        if v_leg_number = 2 then
          v_tmp := v_home;
          v_home := v_away;
          v_away := v_tmp;
        end if;

        if v_home is null and v_away is not null then
          v_home := v_away;
          v_away := null;
        end if;

        if v_home is null then
          raise exception using
            errcode = 'P0001',
            message = 'INVALID_SCHEDULE_PAIRING';
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

  /*
   * Atomic post-generation certification.
   *
   * If a future modification breaks the optimizer, the exception rolls
   * back the complete generation transaction, including schedule activation.
   */
  if v_has_bye and exists (
    select 1
    from public.league_fixtures ff
    join public.league_fixtures ofx
      on ofx.schedule_version_id = ff.schedule_version_id
     and ofx.league_round_id = ff.league_round_id
     and ofx.mode = 'one_to_one'
     and ofx.is_bye = true
    where ff.schedule_version_id = v_schedule_version_id
      and ff.mode = 'fantacalcio'
      and ff.is_bye = true
      and ff.home_member_id = ofx.home_member_id
  ) then
    raise exception using
      errcode = 'P0001',
      message = 'SIMULTANEOUS_CROSS_MODE_BYE_DETECTED';
  end if;

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

comment on function public.generate_league_competitions(uuid, uuid, text)
is
  'Competition Engine v1.1. Generates deterministic versioned league fixtures and coordinates BYE distribution across Fantacalcio and One-to-One so the same member does not rest in both modes during the same round for odd rosters.';

commit;
