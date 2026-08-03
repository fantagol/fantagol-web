-- FANTAGOL
-- Migration 194
-- Standings Avatar Presentation Hydration.
--
-- Mission:
--   - propagate the league-scoped avatar_url into standings ranking rows;
--   - preserve the already-certified canonical display_name hydration;
--   - hydrate both simulation-backed and bootstrap standings responses;
--   - never mutate persisted round_simulations or certified snapshots;
--   - never introduce crest_url into the standings contract.
--
-- Presentation contract:
--   league_member_id
--     -> league_member_profiles.display_name
--     -> league_member_profiles.avatar_url
--
-- Fallback behavior remains a frontend responsibility:
--   avatar_url present -> render image
--   avatar_url absent  -> render display-name initial

create or replace function
public.resolve_league_member_avatar_url(
  target_league_member_id uuid
)
returns text
language sql
stable
security definer
set search_path = public, pg_temp
as $function$
  select nullif(
    btrim(lmp.avatar_url),
    ''
  )::text
  from public.league_member_profiles lmp
  where lmp.league_member_id =
    target_league_member_id;
$function$;

revoke all
on function public.resolve_league_member_avatar_url(uuid)
from public, anon, authenticated;

grant execute
on function public.resolve_league_member_avatar_url(uuid)
to authenticated, service_role;

comment on function
public.resolve_league_member_avatar_url(uuid) is
  'Returns the canonical league-scoped avatar URL for one League Member. No crest fallback is applied.';

create or replace function
public.hydrate_league_member_display_name_object(
  target_object jsonb
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $function$
declare
  v_member_id_text text;
  v_member_id uuid;

  v_canonical_name text;
  v_avatar_url text;

  v_result jsonb;
begin
  if target_object is null then
    return null;
  end if;

  if jsonb_typeof(target_object) <> 'object' then
    return target_object;
  end if;

  v_member_id_text :=
    nullif(
      btrim(
        target_object ->> 'league_member_id'
      ),
      ''
    );

  if v_member_id_text is null
     or v_member_id_text !~*
       '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'
  then
    return target_object;
  end if;

  v_member_id := v_member_id_text::uuid;

  v_canonical_name :=
    public.resolve_league_member_display_name(
      v_member_id
    );

  v_avatar_url :=
    public.resolve_league_member_avatar_url(
      v_member_id
    );

  v_result := target_object;

  if v_canonical_name is not null then
    v_result := jsonb_set(
      v_result,
      '{display_name}',
      to_jsonb(v_canonical_name),
      true
    );
  end if;

  v_result := jsonb_set(
    v_result,
    '{avatar_url}',
    coalesce(
      to_jsonb(v_avatar_url),
      'null'::jsonb
    ),
    true
  );

  return v_result;
end;
$function$;

comment on function
public.hydrate_league_member_display_name_object(jsonb) is
  'Hydrates one presentation object with canonical league-scoped display_name and avatar_url. The historical function name is preserved for compatibility.';

create or replace function
public.hydrate_standings_preview_identity_presentation(
  target_standings_preview jsonb
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $function$
declare
  v_result jsonb;
  v_modes jsonb;
  v_hydrated_modes jsonb := '{}'::jsonb;

  v_mode_name text;
  v_mode_payload jsonb;
  v_hydrated_mode_payload jsonb;
begin
  if target_standings_preview is null then
    return null;
  end if;

  if jsonb_typeof(target_standings_preview) <> 'object' then
    return target_standings_preview;
  end if;

  v_result := target_standings_preview;
  v_modes := v_result -> 'modes';

  if jsonb_typeof(v_modes) <> 'object' then
    return v_result;
  end if;

  for v_mode_name, v_mode_payload in
    select mode.key, mode.value
    from jsonb_each(v_modes) as mode
  loop
    v_hydrated_mode_payload :=
      v_mode_payload;

    if jsonb_typeof(
      v_mode_payload -> 'ranking'
    ) = 'array' then
      v_hydrated_mode_payload := jsonb_set(
        v_mode_payload,
        '{ranking}',
        public.hydrate_league_member_display_name_array(
          v_mode_payload -> 'ranking'
        ),
        true
      );
    end if;

    v_hydrated_modes :=
      v_hydrated_modes ||
      jsonb_build_object(
        v_mode_name,
        v_hydrated_mode_payload
      );
  end loop;

  return jsonb_set(
    v_result,
    '{modes}',
    v_hydrated_modes,
    true
  );
end;
$function$;

revoke all
on function
public.hydrate_standings_preview_identity_presentation(jsonb)
from public, anon, authenticated;

grant execute
on function
public.hydrate_standings_preview_identity_presentation(jsonb)
to authenticated, service_role;

comment on function
public.hydrate_standings_preview_identity_presentation(jsonb) is
  'Hydrates all standings ranking rows with canonical display_name and avatar_url without changing persisted simulation artifacts.';

do $patch$
declare
  v_signature regprocedure :=
    'public.get_my_standings_preview_rpc(uuid)'::regprocedure;

  v_definition text;
  v_patched text;
begin
  select pg_get_functiondef(v_signature)
  into v_definition;

  if position(
    'hydrate_standings_preview_identity_presentation'
    in v_definition
  ) > 0 then
    raise notice
      'STANDINGS_AVATAR_BOOTSTRAP_HYDRATION_ALREADY_PRESENT';

  else
    v_patched := regexp_replace(
      v_definition,
      'v_bootstrap[[:space:]]*:=[[:space:]]*public\.build_zero_standings_preview_internal\([[:space:]]*p_league_round_id[[:space:]]*\)[[:space:]]*;',
      'v_bootstrap := public.hydrate_standings_preview_identity_presentation(public.build_zero_standings_preview_internal(p_league_round_id));',
      'i'
    );

    if v_patched = v_definition then
      raise exception
        'STANDINGS_AVATAR_BOOTSTRAP_PATCH_TARGET_NOT_FOUND';
    end if;

    if position(
      'hydrate_standings_preview_identity_presentation'
      in v_patched
    ) = 0 then
      raise exception
        'STANDINGS_AVATAR_BOOTSTRAP_PATCH_VERIFICATION_FAILED';
    end if;

    execute v_patched;

    raise notice
      'STANDINGS_AVATAR_BOOTSTRAP_HYDRATION_PATCHED';
  end if;
end;
$patch$;

do $certification$
declare
  v_rpc_definition text;
  v_object_definition text;
begin
  if to_regprocedure(
    'public.resolve_league_member_avatar_url(uuid)'
  ) is null then
    raise exception
      'STANDINGS_AVATAR_RESOLVER_MISSING';
  end if;

  if to_regprocedure(
    'public.hydrate_standings_preview_identity_presentation(jsonb)'
  ) is null then
    raise exception
      'STANDINGS_AVATAR_PREVIEW_HYDRATOR_MISSING';
  end if;

  select pg_get_functiondef(
    'public.hydrate_league_member_display_name_object(jsonb)'::regprocedure
  )
  into v_object_definition;

  if position(
    'resolve_league_member_avatar_url'
    in v_object_definition
  ) = 0 then
    raise exception
      'STANDINGS_AVATAR_OBJECT_HYDRATION_MISSING';
  end if;

  if position(
    '''{avatar_url}'''
    in v_object_definition
  ) = 0 then
    raise exception
      'STANDINGS_AVATAR_OBJECT_FIELD_MISSING';
  end if;

  if position(
    'crest_url'
    in v_object_definition
  ) > 0 then
    raise exception
      'STANDINGS_AVATAR_HYDRATION_CONTAINS_CREST';
  end if;

  select pg_get_functiondef(
    'public.get_my_standings_preview_rpc(uuid)'::regprocedure
  )
  into v_rpc_definition;

  if position(
    'hydrate_round_simulation_identity_presentation'
    in v_rpc_definition
  ) = 0 then
    raise exception
      'STANDINGS_AVATAR_SIMULATION_HYDRATION_MISSING';
  end if;

  if position(
    'hydrate_standings_preview_identity_presentation'
    in v_rpc_definition
  ) = 0 then
    raise exception
      'STANDINGS_AVATAR_BOOTSTRAP_HYDRATION_MISSING';
  end if;

  if v_rpc_definition ~*
    'update[[:space:]]+public\.round_simulations'
  then
    raise exception
      'STANDINGS_AVATAR_RPC_MUTATES_SIMULATIONS';
  end if;

  if v_rpc_definition ~*
    'insert[[:space:]]+into[[:space:]]+public\.round_simulations'
  then
    raise exception
      'STANDINGS_AVATAR_RPC_MUTATES_SIMULATIONS';
  end if;

  if v_rpc_definition ~*
    'delete[[:space:]]+from[[:space:]]+public\.round_simulations'
  then
    raise exception
      'STANDINGS_AVATAR_RPC_MUTATES_SIMULATIONS';
  end if;
end;
$certification$;

select
  case
    when to_regprocedure(
      'public.resolve_league_member_avatar_url(uuid)'
    ) is not null
    and to_regprocedure(
      'public.hydrate_standings_preview_identity_presentation(jsonb)'
    ) is not null
    and position(
      'resolve_league_member_avatar_url'
      in pg_get_functiondef(
        'public.hydrate_league_member_display_name_object(jsonb)'::regprocedure
      )
    ) > 0
    and position(
      'hydrate_standings_preview_identity_presentation'
      in pg_get_functiondef(
        'public.get_my_standings_preview_rpc(uuid)'::regprocedure
      )
    ) > 0
      then 'PASS'
    else 'FAIL'
  end as standings_avatar_presentation_hydration_certification;
