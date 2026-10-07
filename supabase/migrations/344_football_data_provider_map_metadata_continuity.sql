-- FANTAGOL MIGRATION 344
-- FOOTBALL-DATA PROVIDER MAP METADATA CONTINUITY
--
-- Purpose:
--   Keep provider_entity_maps mutable schedule metadata aligned with each
--   admitted Football-Data poll even when the canonical match is already
--   aligned and change detection correctly returns NO_CHANGE.
--
-- This function does NOT mutate canonical match state and does NOT enqueue
-- rebuild work. It only refreshes provider-owned mutable metadata.

create or replace function public.sync_provider_match_metadata_internal(
  p_provider_code text,
  p_match_id uuid,
  p_external_id text,
  p_kickoff_at timestamptz,
  p_status text,
  p_provider_updated_at timestamptz
)
returns table (
  provider_map_id uuid,
  applied boolean,
  previous_kickoff_at timestamptz,
  current_kickoff_at timestamptz,
  previous_provider_updated_at timestamptz,
  current_provider_updated_at timestamptz
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_provider_id uuid;
  v_map public.provider_entity_maps%rowtype;
  v_previous_kickoff timestamptz;
  v_previous_provider_updated timestamptz;
begin
  if p_provider_code is null or btrim(p_provider_code) = '' then
    raise exception 'PROVIDER_CODE_REQUIRED';
  end if;

  if p_match_id is null then
    raise exception 'MATCH_ID_REQUIRED';
  end if;

  if p_external_id is null or btrim(p_external_id) = '' then
    raise exception 'EXTERNAL_ID_REQUIRED';
  end if;

  if p_kickoff_at is null then
    raise exception 'KICKOFF_REQUIRED';
  end if;

  select id
  into v_provider_id
  from public.data_providers
  where code = p_provider_code
    and active
  order by priority asc, id
  limit 1;

  if v_provider_id is null then
    raise exception 'ACTIVE_PROVIDER_NOT_FOUND:%', p_provider_code;
  end if;

  select *
  into v_map
  from public.provider_entity_maps
  where provider_id = v_provider_id
    and entity_type = 'match'
    and internal_id = p_match_id
    and active
  for update;

  if not found then
    raise exception 'ACTIVE_PROVIDER_MATCH_MAP_NOT_FOUND:%:%',
      p_provider_code, p_match_id;
  end if;

  if v_map.external_id <> p_external_id then
    raise exception 'PROVIDER_MATCH_EXTERNAL_ID_MISMATCH:%:%:%:%',
      p_provider_code, p_match_id, v_map.external_id, p_external_id;
  end if;

  v_previous_kickoff :=
    nullif(v_map.metadata->>'kickoff_at','')::timestamptz;
  v_previous_provider_updated :=
    nullif(v_map.metadata->>'provider_updated_at','')::timestamptz;

  update public.provider_entity_maps
  set
    metadata =
      coalesce(metadata, '{}'::jsonb)
      || jsonb_build_object(
        'kickoff_at', p_kickoff_at,
        'status', p_status,
        'provider_updated_at', p_provider_updated_at
      ),
    updated_at = clock_timestamp()
  where id = v_map.id
    and (
      v_previous_kickoff is distinct from p_kickoff_at
      or coalesce(v_map.metadata->>'status','') is distinct from coalesce(p_status,'')
      or v_previous_provider_updated is distinct from p_provider_updated_at
    );

  provider_map_id := v_map.id;
  applied := found;
  previous_kickoff_at := v_previous_kickoff;
  current_kickoff_at := p_kickoff_at;
  previous_provider_updated_at := v_previous_provider_updated;
  current_provider_updated_at := p_provider_updated_at;
  return next;
end;
$$;

revoke all on function public.sync_provider_match_metadata_internal(
  text, uuid, text, timestamptz, text, timestamptz
) from public;

grant execute on function public.sync_provider_match_metadata_internal(
  text, uuid, text, timestamptz, text, timestamptz
) to service_role;

grant execute on function public.sync_provider_match_metadata_internal(
  text, uuid, text, timestamptz, text, timestamptz
) to postgres;

comment on function public.sync_provider_match_metadata_internal(
  text, uuid, text, timestamptz, text, timestamptz
) is
'Keeps mutable provider match metadata aligned with admitted provider polls without changing canonical match state or triggering runtime rebuilds.';