-- FANTAGOL
-- Migration 187
-- League Member Profiles Backfill & Parity Certification.
--
-- Additive migration:
--   - bootstraps one autonomous profile per existing membership
--   - does not alter league_members
--   - does not alter clubs
--   - does not replace legacy RPCs
--   - is idempotent through ensure_league_member_profile_internal

do $backfill$
declare
  v_membership record;
  v_profile_id uuid;
  v_processed_count integer := 0;
begin
  for v_membership in
    select
      lm.id as league_member_id
    from public.league_members lm
    order by lm.joined_at, lm.id
  loop
    v_profile_id :=
      public.ensure_league_member_profile_internal(
        v_membership.league_member_id,
        'migration'
      );

    if v_profile_id is null then
      raise exception using
        errcode = 'P0001',
        message = 'LEAGUE_IDENTITY_BACKFILL_PROFILE_NOT_CREATED',
        detail =
          jsonb_build_object(
            'league_member_id',
            v_membership.league_member_id
          )::text;
    end if;

    v_processed_count := v_processed_count + 1;
  end loop;

  raise notice
    'LEAGUE_IDENTITY_BACKFILL_PROCESSED_COUNT=%',
    v_processed_count;
end;
$backfill$;

do $certification$
declare
  v_membership_count bigint;
  v_profile_count bigint;
  v_missing_count bigint;
  v_duplicate_count bigint;
  v_cross_scope_count bigint;
  v_invalid_bootstrap_count bigint;
begin
  select count(*)
  into v_membership_count
  from public.league_members;

  select count(*)
  into v_profile_count
  from public.league_member_profiles;

  select count(*)
  into v_missing_count
  from public.league_members lm
  left join public.league_member_profiles lmp
    on lmp.league_member_id = lm.id
  where lmp.id is null;

  select count(*)
  into v_duplicate_count
  from (
    select
      lmp.league_member_id
    from public.league_member_profiles lmp
    group by lmp.league_member_id
    having count(*) > 1
  ) duplicates;

  select count(*)
  into v_cross_scope_count
  from public.league_member_profiles lmp
  left join public.league_members lm
    on lm.id = lmp.league_member_id
  where lm.id is null
     or lm.league_id is null;

  select count(*)
  into v_invalid_bootstrap_count
  from public.league_member_profiles lmp
  where lmp.bootstrap_source is null
     or lmp.profile_version <= 0
     or nullif(trim(lmp.display_name), '') is null
     or nullif(trim(lmp.club_name), '') is null;

  if v_membership_count <> v_profile_count then
    raise exception using
      errcode = 'P0001',
      message = 'LEAGUE_IDENTITY_BACKFILL_COUNT_MISMATCH',
      detail =
        jsonb_build_object(
          'membership_count', v_membership_count,
          'profile_count', v_profile_count
        )::text;
  end if;

  if v_missing_count <> 0 then
    raise exception using
      errcode = 'P0001',
      message = 'LEAGUE_IDENTITY_BACKFILL_MISSING_PROFILES',
      detail =
        jsonb_build_object(
          'missing_count', v_missing_count
        )::text;
  end if;

  if v_duplicate_count <> 0 then
    raise exception using
      errcode = 'P0001',
      message = 'LEAGUE_IDENTITY_BACKFILL_DUPLICATE_PROFILES',
      detail =
        jsonb_build_object(
          'duplicate_count', v_duplicate_count
        )::text;
  end if;

  if v_cross_scope_count <> 0 then
    raise exception using
      errcode = 'P0001',
      message = 'LEAGUE_IDENTITY_BACKFILL_SCOPE_VIOLATION',
      detail =
        jsonb_build_object(
          'cross_scope_count', v_cross_scope_count
        )::text;
  end if;

  if v_invalid_bootstrap_count <> 0 then
    raise exception using
      errcode = 'P0001',
      message = 'LEAGUE_IDENTITY_BACKFILL_INVALID_PROFILE',
      detail =
        jsonb_build_object(
          'invalid_profile_count',
          v_invalid_bootstrap_count
        )::text;
  end if;
end;
$certification$;

select
  case
    when (
      select count(*)
      from public.league_members
    ) = (
      select count(*)
      from public.league_member_profiles
    )
    and not exists (
      select 1
      from public.league_members lm
      left join public.league_member_profiles lmp
        on lmp.league_member_id = lm.id
      where lmp.id is null
    )
    and not exists (
      select 1
      from public.league_member_profiles lmp
      group by lmp.league_member_id
      having count(*) > 1
    )
      then 'PASS'
    else 'FAIL'
  end as league_member_profiles_backfill_certification;
