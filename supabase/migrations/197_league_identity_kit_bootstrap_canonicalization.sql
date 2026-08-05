-- FANTAGOL
-- Migration 197
-- League Identity Kit Bootstrap Canonicalization.
--
-- Mission:
--   1. Every new league-scoped identity starts with one complete,
--      coherent and UI-supported default FantaGol kit.
--   2. Legacy clubs and membership placeholders may no longer
--      contribute individual kit fields during bootstrap.
--   3. Profiles never explicitly updated through the canonical
--      kit RPC are remediated to the standard kit.
--   4. The known Gianni dgg regression is restored to the
--      black-and-white vertical-striped kit selected by the user.
--
-- Canonical default kit:
--   template       = solid
--   primary        = #A6E824
--   secondary      = #111417
--   third          = #FFFFFF
--   logo mode      = center_horizontal
--   crest position = left_chest

begin;

-- ============================================================
-- CANONICALIZE FUTURE BOOTSTRAP
-- ============================================================

do $patch_bootstrap$
declare
  v_signature regprocedure :=
    'public.ensure_league_member_profile_internal(uuid,text)'::regprocedure;

  v_definition text;
  v_patched text;

  v_old_template text :=
$old$
    coalesce(
      nullif(trim(v_membership.kit_pattern), ''),
      nullif(trim(v_legacy_club.kit_template), ''),
      'solid'
    ),
$old$;

  v_old_primary text :=
$old$
    coalesce(
      nullif(trim(v_membership.kit_primary_color), ''),
      nullif(trim(v_legacy_club.kit_primary_color), ''),
      '#A6E824'
    ),
$old$;

  v_old_secondary text :=
$old$
    coalesce(
      nullif(trim(v_membership.kit_secondary_color), ''),
      nullif(trim(v_legacy_club.kit_secondary_color), ''),
      '#111417'
    ),
$old$;

  v_old_third text :=
$old$
    coalesce(
      nullif(trim(v_legacy_club.kit_third_color), ''),
      '#FFFFFF'
    ),
$old$;

  v_old_logo_mode text :=
$old$
    coalesce(
      nullif(trim(v_legacy_club.kit_logo_mode), ''),
      'center_horizontal'
    ),
$old$;

  v_old_crest_position text :=
$old$
    coalesce(
      nullif(trim(v_legacy_club.kit_crest_position), ''),
      'left_chest'
    ),
$old$;
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

  if position(v_old_template in v_patched) > 0 then
    v_patched := replace(
      v_patched,
      v_old_template,
      E'    ''solid'',\n'
    );
  elsif v_patched ilike '%''solid'',%'
    and v_patched not ilike '%v_membership.kit_pattern%' then
    raise notice
      'KIT_TEMPLATE_BOOTSTRAP_ALREADY_CANONICAL';
  else
    raise exception using
      errcode = 'P0001',
      message =
        'KIT_TEMPLATE_BOOTSTRAP_PATCH_TARGET_NOT_FOUND';
  end if;

  if position(v_old_primary in v_patched) > 0 then
    v_patched := replace(
      v_patched,
      v_old_primary,
      E'    ''#A6E824'',\n'
    );
  elsif v_patched not ilike
        '%v_membership.kit_primary_color%'
    and v_patched not ilike
        '%v_legacy_club.kit_primary_color%' then
    raise notice
      'KIT_PRIMARY_BOOTSTRAP_ALREADY_CANONICAL';
  else
    raise exception using
      errcode = 'P0001',
      message =
        'KIT_PRIMARY_BOOTSTRAP_PATCH_TARGET_NOT_FOUND';
  end if;

  if position(v_old_secondary in v_patched) > 0 then
    v_patched := replace(
      v_patched,
      v_old_secondary,
      E'    ''#111417'',\n'
    );
  elsif v_patched not ilike
        '%v_membership.kit_secondary_color%'
    and v_patched not ilike
        '%v_legacy_club.kit_secondary_color%' then
    raise notice
      'KIT_SECONDARY_BOOTSTRAP_ALREADY_CANONICAL';
  else
    raise exception using
      errcode = 'P0001',
      message =
        'KIT_SECONDARY_BOOTSTRAP_PATCH_TARGET_NOT_FOUND';
  end if;

  if position(v_old_third in v_patched) > 0 then
    v_patched := replace(
      v_patched,
      v_old_third,
      E'    ''#FFFFFF'',\n'
    );
  elsif v_patched not ilike
        '%v_legacy_club.kit_third_color%' then
    raise notice
      'KIT_THIRD_BOOTSTRAP_ALREADY_CANONICAL';
  else
    raise exception using
      errcode = 'P0001',
      message =
        'KIT_THIRD_BOOTSTRAP_PATCH_TARGET_NOT_FOUND';
  end if;

  if position(v_old_logo_mode in v_patched) > 0 then
    v_patched := replace(
      v_patched,
      v_old_logo_mode,
      E'    ''center_horizontal'',\n'
    );
  elsif v_patched not ilike
        '%v_legacy_club.kit_logo_mode%' then
    raise notice
      'KIT_LOGO_MODE_BOOTSTRAP_ALREADY_CANONICAL';
  else
    raise exception using
      errcode = 'P0001',
      message =
        'KIT_LOGO_MODE_BOOTSTRAP_PATCH_TARGET_NOT_FOUND';
  end if;

  if position(v_old_crest_position in v_patched) > 0 then
    v_patched := replace(
      v_patched,
      v_old_crest_position,
      E'    ''left_chest'',\n'
    );
  elsif v_patched not ilike
        '%v_legacy_club.kit_crest_position%' then
    raise notice
      'KIT_CREST_POSITION_BOOTSTRAP_ALREADY_CANONICAL';
  else
    raise exception using
      errcode = 'P0001',
      message =
        'KIT_CREST_POSITION_BOOTSTRAP_PATCH_TARGET_NOT_FOUND';
  end if;

  if v_patched is distinct from v_definition then
    execute v_patched;

    raise notice
      'LEAGUE_IDENTITY_KIT_BOOTSTRAP_CANONICALIZED=%',
      v_signature::text;
  end if;
end;
$patch_bootstrap$;

-- ============================================================
-- REMEDIATE PROFILES NEVER EXPLICITLY UPDATED
-- ============================================================

with candidates as (
  select
    lmp.id as profile_id,
    lmp.league_member_id,
    lmp.profile_version
  from public.league_member_profiles lmp
  where not exists (
    select 1
    from public.league_identity_events e
    where e.league_member_id = lmp.league_member_id
      and e.event_type = 'kit_updated'
  )
  and (
    lmp.kit_template is distinct from 'solid'
    or upper(lmp.kit_primary_color)
         is distinct from '#A6E824'
    or upper(lmp.kit_secondary_color)
         is distinct from '#111417'
    or upper(lmp.kit_third_color)
         is distinct from '#FFFFFF'
    or lmp.kit_logo_mode
         is distinct from 'center_horizontal'
    or lmp.kit_crest_position
         is distinct from 'left_chest'
  )
),
remediated as (
  update public.league_member_profiles lmp
  set
    kit_template = 'solid',
    kit_primary_color = '#A6E824',
    kit_secondary_color = '#111417',
    kit_third_color = '#FFFFFF',
    kit_logo_mode = 'center_horizontal',
    kit_crest_position = 'left_chest',
    profile_version = lmp.profile_version + 1
  from candidates candidate
  where candidate.profile_id = lmp.id
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

  'kit_updated',
  1,

  auth.uid(),
  null,

  remediation.profile_version - 1,
  remediation.profile_version,

  jsonb_build_object(
    'reason',
    'migration_197_standard_kit_remediation',

    'kit_template',
    'solid',

    'kit_primary_color',
    '#A6E824',

    'kit_secondary_color',
    '#111417',

    'kit_third_color',
    '#FFFFFF',

    'kit_logo_mode',
    'center_horizontal',

    'kit_crest_position',
    'left_chest'
  )
from remediated remediation
join public.league_members lm
  on lm.id = remediation.league_member_id;

-- ============================================================
-- RESTORE GIANNI DGG KNOWN USER-SELECTED KIT
-- ============================================================

with gianni_target as (
  select
    lmp.id as profile_id,
    lmp.league_member_id,
    lmp.profile_version
  from public.league_member_profiles lmp
  join public.league_members lm
    on lm.id = lmp.league_member_id
  join public.leagues l
    on l.id = lm.league_id
  where l.name = 'La Grande Bellezza 2.0'
    and lm.user_id =
      '809578d5-ce66-46d4-b6ab-80129e0ddc55'::uuid
),
gianni_restored as (
  update public.league_member_profiles lmp
  set
    kit_template = 'thin_stripes',
    kit_primary_color = '#111417',
    kit_secondary_color = '#FFFFFF',
    kit_third_color = '#FFFFFF',
    kit_logo_mode = 'center_horizontal',
    kit_crest_position = 'left_chest',
    profile_version = lmp.profile_version + 1
  from gianni_target target
  where target.profile_id = lmp.id
    and (
      lmp.kit_template is distinct from 'thin_stripes'
      or upper(lmp.kit_primary_color)
           is distinct from '#111417'
      or upper(lmp.kit_secondary_color)
           is distinct from '#FFFFFF'
      or upper(lmp.kit_third_color)
           is distinct from '#FFFFFF'
      or lmp.kit_logo_mode
           is distinct from 'center_horizontal'
      or lmp.kit_crest_position
           is distinct from 'left_chest'
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
  restoration.league_member_id,
  restoration.id,

  'kit_updated',
  1,

  auth.uid(),
  null,

  restoration.profile_version - 1,
  restoration.profile_version,

  jsonb_build_object(
    'reason',
    'migration_197_known_gianni_kit_restore',

    'kit_template',
    'thin_stripes',

    'kit_primary_color',
    '#111417',

    'kit_secondary_color',
    '#FFFFFF',

    'kit_third_color',
    '#FFFFFF',

    'kit_logo_mode',
    'center_horizontal',

    'kit_crest_position',
    'left_chest'
  )
from gianni_restored restoration
join public.league_members lm
  on lm.id = restoration.league_member_id;

comment on function
public.ensure_league_member_profile_internal(uuid, text) is
  'Creates one autonomous league-scoped identity. Names come from the mandatory membership identity. New kits always start from one complete standard FantaGol configuration; legacy clubs and membership placeholders do not contribute individual kit fields.';

-- ============================================================
-- CERTIFICATION
-- ============================================================

do $certification$
declare
  v_definition text;
  v_uncanonical_bootstrap boolean;
  v_nonstandard_unmodified_profiles bigint;
  v_gianni_failures bigint;
begin
  select pg_get_functiondef(
    'public.ensure_league_member_profile_internal(uuid,text)'::regprocedure
  )
  into v_definition;

  v_uncanonical_bootstrap :=
    v_definition ilike '%v_membership.kit_pattern%'
    or v_definition ilike
       '%v_membership.kit_primary_color%'
    or v_definition ilike
       '%v_membership.kit_secondary_color%'
    or v_definition ilike
       '%v_legacy_club.kit_template%'
    or v_definition ilike
       '%v_legacy_club.kit_primary_color%'
    or v_definition ilike
       '%v_legacy_club.kit_secondary_color%'
    or v_definition ilike
       '%v_legacy_club.kit_third_color%'
    or v_definition ilike
       '%v_legacy_club.kit_logo_mode%'
    or v_definition ilike
       '%v_legacy_club.kit_crest_position%';

  if v_uncanonical_bootstrap then
    raise exception using
      errcode = 'P0001',
      message =
        'LEAGUE_IDENTITY_KIT_BOOTSTRAP_LEGACY_DEPENDENCY_REMAINS';
  end if;

  select count(*)
  into v_nonstandard_unmodified_profiles
  from public.league_member_profiles lmp
  where not exists (
    select 1
    from public.league_identity_events e
    where e.league_member_id = lmp.league_member_id
      and e.event_type = 'kit_updated'
  )
  and (
    lmp.kit_template is distinct from 'solid'
    or upper(lmp.kit_primary_color)
         is distinct from '#A6E824'
    or upper(lmp.kit_secondary_color)
         is distinct from '#111417'
    or upper(lmp.kit_third_color)
         is distinct from '#FFFFFF'
    or lmp.kit_logo_mode
         is distinct from 'center_horizontal'
    or lmp.kit_crest_position
         is distinct from 'left_chest'
  );

  if v_nonstandard_unmodified_profiles <> 0 then
    raise exception using
      errcode = 'P0001',
      message =
        'LEAGUE_IDENTITY_STANDARD_KIT_REMEDIATION_FAILED',
      detail =
        jsonb_build_object(
          'failure_count',
          v_nonstandard_unmodified_profiles
        )::text;
  end if;

  select count(*)
  into v_gianni_failures
  from public.league_member_profiles lmp
  join public.league_members lm
    on lm.id = lmp.league_member_id
  join public.leagues l
    on l.id = lm.league_id
  where l.name = 'La Grande Bellezza 2.0'
    and lm.user_id =
      '809578d5-ce66-46d4-b6ab-80129e0ddc55'::uuid
    and (
      lmp.kit_template is distinct from 'thin_stripes'
      or upper(lmp.kit_primary_color)
           is distinct from '#111417'
      or upper(lmp.kit_secondary_color)
           is distinct from '#FFFFFF'
      or upper(lmp.kit_third_color)
           is distinct from '#FFFFFF'
      or lmp.kit_logo_mode
           is distinct from 'center_horizontal'
      or lmp.kit_crest_position
           is distinct from 'left_chest'
    );

  if v_gianni_failures <> 0 then
    raise exception using
      errcode = 'P0001',
      message =
        'GIANNI_KNOWN_KIT_RESTORATION_FAILED';
  end if;
end;
$certification$;

select
  case
    when pg_get_functiondef(
      'public.ensure_league_member_profile_internal(uuid,text)'::regprocedure
    ) not ilike '%v_legacy_club.kit_%'
     and pg_get_functiondef(
      'public.ensure_league_member_profile_internal(uuid,text)'::regprocedure
    ) not ilike '%v_membership.kit_%'
      then 'PASS'
    else 'FAIL'
  end as league_identity_kit_bootstrap_canonicalization_certification;

commit;
