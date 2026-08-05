-- FANTAGOL
-- Migration 196
-- League Identity Name Canonicalization and Legacy Decoupling.
--
-- Mission:
--   1. The mandatory Club Name chosen during league creation/join is
--      the only source for display_name and club_name at bootstrap.
--   2. Legacy public.clubs data may bootstrap cosmetic attributes,
--      but may no longer override the league-scoped Club Name.
--   3. real_name remains optional and is not inherited automatically.
--   4. Existing profiles created during the regression window are
--      deterministically remediated.
--
-- Canonical identity semantics:
--   display_name = mandatory league-scoped Club Name
--   club_name    = same mandatory league-scoped Club Name
--   real_name    = optional; null until explicitly supplied

begin;

do $patch_bootstrap$
declare
  v_signature regprocedure :=
    'public.ensure_league_member_profile_internal(uuid,text)'::regprocedure;

  v_definition text;
  v_patched text;

  v_old_club_name_expression text :=
$old$
    coalesce(
      nullif(trim(v_legacy_club.name), ''),
      nullif(trim(v_membership.display_name), ''),
      'FantaGol Club'
    ),
$old$;

  v_new_club_name_expression text :=
$new$
    coalesce(
      nullif(trim(v_membership.display_name), ''),
      nullif(trim(v_legacy_club.name), ''),
      'Giocatore'
    ),
$new$;

  v_old_real_name_expression text :=
$old_real$
    nullif(trim(v_legacy_club.real_name), ''),
$old_real$;

  v_new_real_name_expression text :=
$new_real$
    null,
$new_real$;
begin
  select pg_get_functiondef(v_signature)
  into v_definition;

  if v_definition is null then
    raise exception using
      errcode = 'P0001',
      message =
        'LEAGUE_IDENTITY_BOOTSTRAP_FUNCTION_NOT_FOUND';
  end if;

  v_patched := v_definition;

  if position(
    v_old_club_name_expression in v_patched
  ) > 0 then
    v_patched := replace(
      v_patched,
      v_old_club_name_expression,
      v_new_club_name_expression
    );

  elsif v_patched ilike
        '%nullif(trim(v_membership.display_name), '''')%'
    and v_patched not ilike
        '%nullif(trim(v_legacy_club.name), ''''),%nullif(trim(v_membership.display_name), ''''),%''FantaGol Club''%' then
    raise notice
      'LEAGUE_IDENTITY_CLUB_NAME_BOOTSTRAP_ALREADY_CANONICAL';

  else
    raise exception using
      errcode = 'P0001',
      message =
        'LEAGUE_IDENTITY_CLUB_NAME_PATCH_TARGET_NOT_FOUND';
  end if;

  if position(
    v_old_real_name_expression in v_patched
  ) > 0 then
    v_patched := replace(
      v_patched,
      v_old_real_name_expression,
      v_new_real_name_expression
    );

  elsif v_patched not ilike
        '%nullif(trim(v_legacy_club.real_name), '''')%' then
    raise notice
      'LEAGUE_IDENTITY_REAL_NAME_BOOTSTRAP_ALREADY_CANONICAL';

  else
    raise exception using
      errcode = 'P0001',
      message =
        'LEAGUE_IDENTITY_REAL_NAME_PATCH_TARGET_NOT_FOUND';
  end if;

  if v_patched is distinct from v_definition then
    execute v_patched;

    raise notice
      'LEAGUE_IDENTITY_BOOTSTRAP_CANONICALIZED=%',
      v_signature::text;
  end if;
end;
$patch_bootstrap$;

-- ------------------------------------------------------------
-- Existing profile remediation
--
-- Case 1:
--   The frontend accidentally promoted "FantaGol Club" to
--   display_name while the mandatory membership name remained valid.
--
-- Case 2:
--   display_name is valid, but club_name still contains a legacy
--   global Club value.
--
-- The profile display_name remains authoritative except for the
-- known regression placeholder "FantaGol Club".
-- ------------------------------------------------------------

with canonical_profiles as (
  select
    lmp.id as profile_id,

    case
      when lower(btrim(lmp.display_name)) =
             lower('FantaGol Club')
       and nullif(btrim(lm.display_name), '') is not null
       and lower(btrim(lm.display_name)) <>
             lower('FantaGol Club')
        then btrim(lm.display_name)

      else coalesce(
        nullif(btrim(lmp.display_name), ''),
        nullif(btrim(lm.display_name), ''),
        'Giocatore'
      )
    end as canonical_club_name

  from public.league_member_profiles lmp
  join public.league_members lm
    on lm.id = lmp.league_member_id
),
remediated as (
  update public.league_member_profiles lmp
  set
    display_name = canonical.canonical_club_name,
    club_name = canonical.canonical_club_name,
    profile_version = lmp.profile_version + 1
  from canonical_profiles canonical
  where canonical.profile_id = lmp.id
    and (
      lmp.display_name is distinct from
        canonical.canonical_club_name

      or lmp.club_name is distinct from
        canonical.canonical_club_name
    )
  returning
    lmp.id,
    lmp.league_member_id,
    lmp.profile_version
)
insert into public.league_identity_events (
  league_id,
  league_member_id,
  profile_id,

  event_type,
  event_version,

  actor_user_id,
  actor_member_id,

  previous_version,
  new_version,

  payload
)
select
  lm.league_id,
  remediation.league_member_id,
  remediation.id,

  'identity_updated',
  1,

  auth.uid(),
  null,

  remediation.profile_version - 1,
  remediation.profile_version,

  jsonb_build_object(
    'reason',
    'migration_196_name_canonicalization',

    'canonical_name',
    lmp.display_name,

    'display_name_aligned',
    true,

    'club_name_aligned',
    true
  )
from remediated remediation
join public.league_member_profiles lmp
  on lmp.id = remediation.id
join public.league_members lm
  on lm.id = remediation.league_member_id;

comment on function
public.ensure_league_member_profile_internal(uuid, text) is
  'Creates one league-scoped identity. The mandatory membership Club Name initializes both display_name and club_name; legacy clubs may bootstrap cosmetic attributes only. real_name remains null until explicitly supplied.';

-- ------------------------------------------------------------
-- Certification
-- ------------------------------------------------------------

do $certification$
declare
  v_definition text;
  v_incoherent_profiles bigint;
  v_placeholder_profiles bigint;
begin
  select pg_get_functiondef(
    'public.ensure_league_member_profile_internal(uuid,text)'::regprocedure
  )
  into v_definition;

  if v_definition ilike
     '%nullif(trim(v_legacy_club.name), ''''),%nullif(trim(v_membership.display_name), ''''),%''FantaGol Club''%' then
    raise exception using
      errcode = 'P0001',
      message =
        'LEAGUE_IDENTITY_LEGACY_CLUB_NAME_PRIORITY_STILL_PRESENT';
  end if;

  if v_definition ilike
     '%nullif(trim(v_legacy_club.real_name), '''')%' then
    raise exception using
      errcode = 'P0001',
      message =
        'LEAGUE_IDENTITY_LEGACY_REAL_NAME_BOOTSTRAP_STILL_PRESENT';
  end if;

  select count(*)
  into v_incoherent_profiles
  from public.league_member_profiles lmp
  where nullif(btrim(lmp.display_name), '') is null
     or nullif(btrim(lmp.club_name), '') is null
     or btrim(lmp.display_name) is distinct from
        btrim(lmp.club_name);

  if v_incoherent_profiles <> 0 then
    raise exception using
      errcode = 'P0001',
      message =
        'LEAGUE_IDENTITY_NAME_CANONICALIZATION_FAILED',
      detail =
        jsonb_build_object(
          'incoherent_profile_count',
          v_incoherent_profiles
        )::text;
  end if;

  select count(*)
  into v_placeholder_profiles
  from public.league_member_profiles lmp
  join public.league_members lm
    on lm.id = lmp.league_member_id
  where lower(btrim(lmp.display_name)) =
          lower('FantaGol Club')
    and nullif(btrim(lm.display_name), '') is not null
    and lower(btrim(lm.display_name)) <>
          lower('FantaGol Club');

  if v_placeholder_profiles <> 0 then
    raise exception using
      errcode = 'P0001',
      message =
        'LEAGUE_IDENTITY_PLACEHOLDER_REMEDIATION_FAILED',
      detail =
        jsonb_build_object(
          'placeholder_profile_count',
          v_placeholder_profiles
        )::text;
  end if;
end;
$certification$;

select
  case
    when to_regprocedure(
      'public.ensure_league_member_profile_internal(uuid,text)'
    ) is not null
     and not exists (
       select 1
       from public.league_member_profiles lmp
       where nullif(btrim(lmp.display_name), '') is null
          or nullif(btrim(lmp.club_name), '') is null
          or btrim(lmp.display_name) is distinct from
             btrim(lmp.club_name)
     )
      then 'PASS'
    else 'FAIL'
  end as league_identity_name_canonicalization_certification;

commit;
