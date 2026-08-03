-- FANTAGOL
-- Migration 192
-- Standings Presentation Identity Hydration.
--
-- Mission:
-- hydrate league-scoped display names at read time for simulation-backed
-- standings and member presentation payloads.
--
-- The persisted simulation remains immutable:
--   - no round_simulations updates;
--   - no digital_twin rewrites;
--   - no hash changes;
--   - no certification changes.
--
-- Canonical identity is resolved exclusively through:
--   league_member_id -> resolve_league_member_display_name(uuid).

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
begin
  if target_object is null then
    return null;
  end if;

  if jsonb_typeof(target_object) <> 'object' then
    return target_object;
  end if;

  v_member_id_text :=
    nullif(
      btrim(target_object ->> 'league_member_id'),
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

  if v_canonical_name is null then
    return target_object;
  end if;

  return jsonb_set(
    target_object,
    '{display_name}',
    to_jsonb(v_canonical_name),
    true
  );
end;
$function$;

create or replace function
public.hydrate_league_member_display_name_array(
  target_array jsonb
)
returns jsonb
language sql
stable
security definer
set search_path = public, pg_temp
as $function$
  select case
    when target_array is null then null

    when jsonb_typeof(target_array) <> 'array'
      then target_array

    else coalesce(
      (
        select jsonb_agg(
          public.hydrate_league_member_display_name_object(
            array_item.value
          )
          order by array_item.ordinality
        )
        from jsonb_array_elements(target_array)
          with ordinality as array_item(value, ordinality)
      ),
      '[]'::jsonb
    )
  end;
$function$;

create or replace function
public.hydrate_round_simulation_identity_presentation(
  target_digital_twin jsonb
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
  if target_digital_twin is null then
    return null;
  end if;

  if jsonb_typeof(target_digital_twin) <> 'object' then
    return target_digital_twin;
  end if;

  v_result := target_digital_twin;

  ------------------------------------------------------------------
  -- Member presentation array
  ------------------------------------------------------------------

  if jsonb_typeof(v_result -> 'members') = 'array' then
    v_result := jsonb_set(
      v_result,
      '{members}',
      public.hydrate_league_member_display_name_array(
        v_result -> 'members'
      ),
      true
    );
  end if;

  ------------------------------------------------------------------
  -- Rankings for all standings modes
  ------------------------------------------------------------------

  v_modes :=
    v_result #> '{standings_preview,modes}';

  if jsonb_typeof(v_modes) = 'object' then
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

    v_result := jsonb_set(
      v_result,
      '{standings_preview,modes}',
      v_hydrated_modes,
      true
    );
  end if;

  return v_result;
end;
$function$;

revoke all
on function
  public.hydrate_league_member_display_name_object(jsonb)
from public, anon, authenticated;

revoke all
on function
  public.hydrate_league_member_display_name_array(jsonb)
from public, anon, authenticated;

revoke all
on function
  public.hydrate_round_simulation_identity_presentation(jsonb)
from public, anon, authenticated;

grant execute
on function
  public.hydrate_league_member_display_name_object(jsonb)
to authenticated, service_role;

grant execute
on function
  public.hydrate_league_member_display_name_array(jsonb)
to authenticated, service_role;

grant execute
on function
  public.hydrate_round_simulation_identity_presentation(jsonb)
to authenticated, service_role;

comment on function
public.hydrate_league_member_display_name_object(jsonb) is
  'Hydrates one JSON presentation object using its league_member_id without modifying persisted data.';

comment on function
public.hydrate_league_member_display_name_array(jsonb) is
  'Hydrates display names in one JSON array while preserving original element order.';

comment on function
public.hydrate_round_simulation_identity_presentation(jsonb) is
  'Hydrates members and standings rankings in an in-memory simulation digital twin for presentation only.';

do $patch$
declare
  v_signature regprocedure :=
    'public.get_my_standings_preview_rpc(uuid)'::regprocedure;

  v_definition text;
  v_patched text;
begin
  select pg_get_functiondef(v_signature)
  into v_definition;

  v_patched := v_definition;

  ------------------------------------------------------------------
  -- Simulation-backed branch.
  --
  -- Hydrate only the local row variable after selecting the persisted
  -- simulation. All existing response construction then consumes the
  -- hydrated local copy. The database row remains unchanged.
  ------------------------------------------------------------------

  if v_patched not ilike
     '%hydrate_round_simulation_identity_presentation%' then
    v_patched := regexp_replace(
      v_patched,
      'if[[:space:]]+found[[:space:]]+then[[:space:]]+select[[:space:]]+value',
      $replacement$
if found then
    v_simulation.digital_twin :=
      public.hydrate_round_simulation_identity_presentation(
        v_simulation.digital_twin
      );

    select value
$replacement$,
      'i'
    );

    if v_patched = v_definition then
      raise exception using
        errcode = 'P0001',
        message =
          'STANDINGS_PRESENTATION_SIMULATION_PATCH_TARGET_NOT_FOUND';
    end if;

    if v_patched not ilike
       '%v_simulation.digital_twin :=%hydrate_round_simulation_identity_presentation%' then
      raise exception using
        errcode = 'P0001',
        message =
          'STANDINGS_PRESENTATION_SIMULATION_PATCH_VERIFICATION_FAILED';
    end if;
  end if;

  ------------------------------------------------------------------
  -- Bootstrap member view.
  ------------------------------------------------------------------

  if v_patched not ilike
     '%resolve_league_member_display_name(lm.id)%' then
    declare
      v_bootstrap_start integer;
      v_bootstrap_tail_start integer;
      v_bootstrap_tail_relative integer;
    begin
      v_bootstrap_start := position(
        '''display_name'', coalesce('
        in v_patched
      );

      if v_bootstrap_start = 0 then
        raise exception using
          errcode = 'P0001',
          message =
            'STANDINGS_PRESENTATION_BOOTSTRAP_START_NOT_FOUND';
      end if;

      v_bootstrap_tail_relative := position(
        '''role'', lm.role'
        in substring(
          v_patched
          from v_bootstrap_start
        )
      );

      if v_bootstrap_tail_relative = 0 then
        raise exception using
          errcode = 'P0001',
          message =
            'STANDINGS_PRESENTATION_BOOTSTRAP_END_NOT_FOUND';
      end if;

      v_bootstrap_tail_start :=
        v_bootstrap_start
        + v_bootstrap_tail_relative
        - 1;

      v_patched :=
        substring(
          v_patched
          from 1
          for v_bootstrap_start - 1
        )
        ||
        $replacement$
'display_name',
      public.resolve_league_member_display_name(lm.id),
    $replacement$
        ||
        substring(
          v_patched
          from v_bootstrap_tail_start
        );

      if v_patched not ilike
         '%resolve_league_member_display_name(lm.id)%'
         or v_patched ilike
           '%''display_name'', coalesce(%'
      then
        raise exception using
          errcode = 'P0001',
          message =
            'STANDINGS_PRESENTATION_BOOTSTRAP_POSITION_PATCH_FAILED';
      end if;
    end;
  end if;

  if v_patched = v_definition then
    if v_definition ilike
       '%hydrate_round_simulation_identity_presentation%'
       and v_definition ilike
       '%public.resolve_league_member_display_name(lm.id)%'
    then
      raise notice
        'STANDINGS_PRESENTATION_IDENTITY_HYDRATION_ALREADY_PRESENT';
    else
      raise exception using
        errcode = 'P0001',
        message =
          'STANDINGS_PRESENTATION_PATCH_TARGET_NOT_FOUND';
    end if;
  else
    execute v_patched;

    raise notice
      'STANDINGS_PRESENTATION_IDENTITY_HYDRATION_PATCHED';
  end if;
end;
$patch$;

do $certification$
declare
  v_rpc_definition text;
  v_helper_definition text;
begin
  if to_regprocedure(
    'public.hydrate_league_member_display_name_object(jsonb)'
  ) is null then
    raise exception
      'STANDINGS_PRESENTATION_OBJECT_HYDRATOR_MISSING';
  end if;

  if to_regprocedure(
    'public.hydrate_league_member_display_name_array(jsonb)'
  ) is null then
    raise exception
      'STANDINGS_PRESENTATION_ARRAY_HYDRATOR_MISSING';
  end if;

  if to_regprocedure(
    'public.hydrate_round_simulation_identity_presentation(jsonb)'
  ) is null then
    raise exception
      'STANDINGS_PRESENTATION_DIGITAL_TWIN_HYDRATOR_MISSING';
  end if;

  select pg_get_functiondef(
    'public.get_my_standings_preview_rpc(uuid)'::regprocedure
  )
  into v_rpc_definition;

  if v_rpc_definition not ilike
     '%hydrate_round_simulation_identity_presentation%' then
    raise exception
      'STANDINGS_PRESENTATION_RPC_NOT_HYDRATED';
  end if;

  if v_rpc_definition not ilike
     '%public.resolve_league_member_display_name(lm.id)%' then
    raise exception
      'STANDINGS_BOOTSTRAP_MEMBER_NAME_NOT_CANONICAL';
  end if;

  select pg_get_functiondef(
    'public.hydrate_round_simulation_identity_presentation(jsonb)'::regprocedure
  )
  into v_helper_definition;

  if v_helper_definition ilike
     '%update public.round_simulations%' then
    raise exception
      'STANDINGS_PRESENTATION_HYDRATOR_MUTATES_SIMULATIONS';
  end if;

  if v_rpc_definition ilike
     '%update public.round_simulations%' then
    raise exception
      'STANDINGS_PRESENTATION_RPC_MUTATES_SIMULATIONS';
  end if;
end;
$certification$;

select
  case
    when to_regprocedure(
      'public.hydrate_round_simulation_identity_presentation(jsonb)'
    ) is not null
     and pg_get_functiondef(
       'public.get_my_standings_preview_rpc(uuid)'::regprocedure
     ) ilike
       '%hydrate_round_simulation_identity_presentation%'
     and pg_get_functiondef(
       'public.get_my_standings_preview_rpc(uuid)'::regprocedure
     ) ilike
       '%resolve_league_member_display_name(lm.id)%'
      then 'PASS'
    else 'FAIL'
  end as standings_presentation_identity_hydration_certification;
