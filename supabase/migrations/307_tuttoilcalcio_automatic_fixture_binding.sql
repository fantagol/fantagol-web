-- FANTAGOL MIGRATION 307
-- R114-R5 R56
-- Atomic/idempotent Tuttoilcalcio automatic fixture binding persistence.
-- Discovery does not promote LIVE authority and does not certify results.

create or replace function public.persist_tuttoilcalcio_match_binding_internal(
  p_internal_match_id uuid,
  p_external_id text,
  p_external_parent_id text,
  p_metadata jsonb default '{}'::jsonb
)
returns table(
  mapping_id uuid,
  binding_action text,
  internal_match_id uuid,
  external_match_id text
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_provider_id uuid;
  v_internal public.provider_entity_maps%rowtype;
  v_external public.provider_entity_maps%rowtype;
  v_inserted public.provider_entity_maps%rowtype;
begin
  if p_internal_match_id is null then
    raise exception 'TUTTO_BINDING_INTERNAL_MATCH_ID_REQUIRED';
  end if;

  if coalesce(trim(p_external_id), '') = '' then
    raise exception 'TUTTO_BINDING_EXTERNAL_ID_REQUIRED';
  end if;

  perform pg_advisory_xact_lock(
    hashtextextended(
      'tuttoilcalcio_match_binding:' || p_internal_match_id::text,
      0
    )
  );

  select id
  into v_provider_id
  from public.data_providers
  where code = 'tuttoilcalcio'
    and active = true
  order by created_at asc
  limit 1;

  if v_provider_id is null then
    raise exception 'TUTTO_BINDING_PROVIDER_MISSING';
  end if;

  select *
  into v_internal
  from public.provider_entity_maps
  where provider_id = v_provider_id
    and entity_type = 'match'
    and internal_id = p_internal_match_id
  limit 1;

  if v_internal.id is not null then
    if v_internal.external_id <> trim(p_external_id) then
      raise exception
        'TUTTO_BINDING_INTERNAL_CONFLICT:%:%:%',
        p_internal_match_id,
        v_internal.external_id,
        trim(p_external_id);
    end if;

    if v_internal.active is false then
      raise exception
        'TUTTO_BINDING_EXISTING_INACTIVE:%:%',
        p_internal_match_id,
        v_internal.external_id;
    end if;

    return query
    select
      v_internal.id,
      'existing'::text,
      v_internal.internal_id,
      v_internal.external_id;
    return;
  end if;

  select *
  into v_external
  from public.provider_entity_maps
  where provider_id = v_provider_id
    and entity_type = 'match'
    and external_id = trim(p_external_id)
  limit 1;

  if v_external.id is not null then
    raise exception
      'TUTTO_BINDING_EXTERNAL_CONFLICT:%:%:%',
      trim(p_external_id),
      v_external.internal_id,
      p_internal_match_id;
  end if;

  insert into public.provider_entity_maps(
    provider_id,
    entity_type,
    internal_id,
    external_id,
    external_parent_id,
    active,
    metadata
  )
  values(
    v_provider_id,
    'match',
    p_internal_match_id,
    trim(p_external_id),
    nullif(trim(p_external_parent_id), ''),
    true,
    coalesce(p_metadata, '{}'::jsonb)
  )
  returning *
  into v_inserted;

  return query
  select
    v_inserted.id,
    'inserted'::text,
    v_inserted.internal_id,
    v_inserted.external_id;
end;
$$;

revoke all on function public.persist_tuttoilcalcio_match_binding_internal(
  uuid,
  text,
  text,
  jsonb
) from public, anon, authenticated;

grant execute on function public.persist_tuttoilcalcio_match_binding_internal(
  uuid,
  text,
  text,
  jsonb
) to service_role;

comment on function public.persist_tuttoilcalcio_match_binding_internal(
  uuid,
  text,
  text,
  jsonb
) is
'R114-R5 R56: atomic fail-closed Tutto match binding persistence. Does not promote LIVE authority or certify results.';
