-- FANTAGOL MIGRATION 304
-- Tuttoilcalcio LIVE provider registry + certified G3 match bindings
--
-- Authority boundaries:
-- - this registry row DOES NOT make Tuttoilcalcio canonical match authority;
-- - PRE-LIVE schedule and OFFICIAL_FINAL remain Football-Data authority;
-- - M302 live_match_authority_states remains the sole LIVE authority selector;
-- - no canonical matches / Football-Data receipts / certifications are mutated.
--
-- Binding evidence:
-- R113 dual field certification, 2026-09-06.
-- Parma Calcio 1913 - AC Monza:
--   FantaGol match 1fdbc489-635a-4f4d-9564-6f86bc6f41bf
--   Tutto fixture 102740
-- Frosinone Calcio - Venezia FC:
--   FantaGol match b71adb41-a41f-46b0-9a8a-3b853ee683c6
--   Tutto fixture 102739

do $migration$
declare
  v_provider_id uuid;
begin
  select dp.id
  into v_provider_id
  from public.data_providers dp
  where dp.code = 'tuttoilcalcio';

  if v_provider_id is null then
    v_provider_id := gen_random_uuid();

    insert into public.data_providers (
      id,
      code,
      name,
      provider_type,
      active,
      priority,
      base_url,
      rate_limit_per_minute
    )
    values (
      v_provider_id,
      'tuttoilcalcio',
      'Tuttoilcalcio',
      'live_score',
      true,
      100,
      'https://tuttoilcalcio.com/api/v1',
      null
    );
  else
    if not exists (
      select 1
      from public.data_providers dp
      where dp.id = v_provider_id
        and dp.provider_type = 'live_score'
        and dp.active = true
    ) then
      raise exception using
        errcode = 'P0001',
        message =
          'TUTTOILCALCIO_PROVIDER_REGISTRY_CONFLICT';
    end if;
  end if;

  -- Fail closed if the internal match already has a different Tutto binding.
  if exists (
    select 1
    from public.provider_entity_maps pem
    where pem.provider_id = v_provider_id
      and pem.entity_type = 'match'
      and pem.internal_id =
        '1fdbc489-635a-4f4d-9564-6f86bc6f41bf'::uuid
      and pem.external_id <> '102740'
  ) then
    raise exception using
      errcode = 'P0001',
      message =
        'TUTTOILCALCIO_PARMA_MONZA_BINDING_CONFLICT';
  end if;

  if exists (
    select 1
    from public.provider_entity_maps pem
    where pem.provider_id = v_provider_id
      and pem.entity_type = 'match'
      and pem.internal_id =
        'b71adb41-a41f-46b0-9a8a-3b853ee683c6'::uuid
      and pem.external_id <> '102739'
  ) then
    raise exception using
      errcode = 'P0001',
      message =
        'TUTTOILCALCIO_FROSINONE_VENEZIA_BINDING_CONFLICT';
  end if;

  insert into public.provider_entity_maps (
    id,
    provider_id,
    entity_type,
    internal_id,
    external_id,
    external_parent_id,
    metadata,
    active
  )
  values
  (
    gen_random_uuid(),
    v_provider_id,
    'match',
    '1fdbc489-635a-4f4d-9564-6f86bc6f41bf'::uuid,
    '102740',
    '278',
    jsonb_build_object(
      'binding_authority', 'R113_DUAL_FIELD_CERTIFICATION',
      'certified_date', '2026-09-06',
      'fixture_slug',
        'parma-calcio-vs-ac-monza-2026-09-06-71945240',
      'home_name', 'Parma Calcio',
      'away_name', 'AC Monza',
      'kickoff_utc', '2026-09-06T13:00:00Z',
      'provider_league_id', '278'
    ),
    true
  )
  on conflict (provider_id, entity_type, internal_id)
  do nothing;

  insert into public.provider_entity_maps (
    id,
    provider_id,
    entity_type,
    internal_id,
    external_id,
    external_parent_id,
    metadata,
    active
  )
  values
  (
    gen_random_uuid(),
    v_provider_id,
    'match',
    'b71adb41-a41f-46b0-9a8a-3b853ee683c6'::uuid,
    '102739',
    '278',
    jsonb_build_object(
      'binding_authority', 'R113_DUAL_FIELD_CERTIFICATION',
      'certified_date', '2026-09-06',
      'fixture_slug',
        'frosinone-calcio-vs-venezia-2026-09-06-71945232',
      'home_name', 'Frosinone Calcio',
      'away_name', 'Venezia',
      'kickoff_utc', '2026-09-06T13:00:00Z',
      'provider_league_id', '278'
    ),
    true
  )
  on conflict (provider_id, entity_type, internal_id)
  do nothing;

  if (
    select count(*)
    from public.provider_entity_maps pem
    where pem.provider_id = v_provider_id
      and pem.entity_type = 'match'
      and pem.active = true
      and (
        (
          pem.internal_id =
            '1fdbc489-635a-4f4d-9564-6f86bc6f41bf'::uuid
          and pem.external_id = '102740'
        )
        or
        (
          pem.internal_id =
            'b71adb41-a41f-46b0-9a8a-3b853ee683c6'::uuid
          and pem.external_id = '102739'
        )
      )
  ) <> 2 then
    raise exception using
      errcode = 'P0001',
      message =
        'TUTTOILCALCIO_CERTIFIED_BINDING_SET_INCOMPLETE';
  end if;
end
$migration$;

comment on table public.provider_entity_maps is
'Provider-specific durable entity identity registry. Tuttoilcalcio match bindings remain LIVE overlay identity only and never replace canonical Football-Data match authority.';
