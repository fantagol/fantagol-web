-- FANTAGOL
-- Odds snapshot RPC ambiguity hotfix
--
-- Fix:
--   ON CONFLICT (provider_id, external_match_id, snapshot_hash)
-- becomes:
--   ON CONFLICT ON CONSTRAINT odds_market_snapshots_provider_hash_unique
--
-- This avoids PL/pgSQL ambiguity with RETURNS TABLE output-column variables.

begin;

create or replace function public.create_odds_market_snapshot_rpc(
  p_match_id uuid,
  p_provider_code text,
  p_external_match_id text,
  p_collected_at timestamp with time zone,
  p_provider_payload jsonb,
  p_canonical_payload jsonb,
  p_consensus_payload jsonb default null::jsonb,
  p_quality_payload jsonb default '{}'::jsonb,
  p_snapshot_schema_version integer default 1
)
returns table(
  odds_market_snapshot_id uuid,
  match_id uuid,
  provider_id uuid,
  collected_at timestamp with time zone,
  snapshot_hash text,
  inserted boolean
)
language plpgsql
security definer
set search_path to 'public', 'extensions', 'pg_temp'
as $function$
declare
  v_provider_id uuid;
  v_snapshot_hash text;
  v_snapshot_id uuid;
  v_inserted boolean := false;
begin
  if p_match_id is null then
    raise exception 'p_match_id is required';
  end if;

  if btrim(coalesce(p_provider_code, '')) = '' then
    raise exception 'p_provider_code is required';
  end if;

  if btrim(coalesce(p_external_match_id, '')) = '' then
    raise exception 'p_external_match_id is required';
  end if;

  if p_collected_at is null then
    raise exception 'p_collected_at is required';
  end if;

  if p_canonical_payload is null then
    raise exception 'p_canonical_payload is required';
  end if;

  select dp.id
    into v_provider_id
  from public.data_providers dp
  where dp.code = p_provider_code
    and dp.active = true
    and dp.provider_type in ('odds', 'multi')
  order by dp.priority asc, dp.id asc
  limit 1;

  if v_provider_id is null then
    raise exception 'active odds provider not found: %', p_provider_code;
  end if;

  if not exists (
    select 1
    from public.matches m
    where m.id = p_match_id
  ) then
    raise exception 'match not found: %', p_match_id;
  end if;

  v_snapshot_hash := encode(
    extensions.digest(
      convert_to(
        jsonb_build_object(
          'schema_version', p_snapshot_schema_version,
          'match_id', p_match_id,
          'provider_id', v_provider_id,
          'external_match_id', p_external_match_id,
          'collected_at', p_collected_at,
          'canonical_payload', p_canonical_payload,
          'consensus_payload', p_consensus_payload,
          'quality_payload', coalesce(p_quality_payload, '{}'::jsonb)
        )::text,
        'UTF8'
      ),
      'sha256'
    ),
    'hex'
  );

  insert into public.odds_market_snapshots (
    match_id,
    provider_id,
    external_match_id,
    collected_at,
    provider_payload,
    canonical_payload,
    consensus_payload,
    quality_payload,
    snapshot_schema_version,
    snapshot_hash
  )
  values (
    p_match_id,
    v_provider_id,
    p_external_match_id,
    p_collected_at,
    coalesce(p_provider_payload, '{}'::jsonb),
    p_canonical_payload,
    p_consensus_payload,
    coalesce(p_quality_payload, '{}'::jsonb),
    p_snapshot_schema_version,
    v_snapshot_hash
  )
  on conflict on constraint odds_market_snapshots_provider_hash_unique
  do nothing
  returning id into v_snapshot_id;

  if v_snapshot_id is null then
    select oms.id
      into v_snapshot_id
    from public.odds_market_snapshots oms
    where oms.provider_id = v_provider_id
      and oms.external_match_id = p_external_match_id
      and oms.snapshot_hash = v_snapshot_hash;

    v_inserted := false;
  else
    v_inserted := true;
  end if;

  return query
  select
    oms.id,
    oms.match_id,
    oms.provider_id,
    oms.collected_at,
    oms.snapshot_hash,
    v_inserted
  from public.odds_market_snapshots oms
  where oms.id = v_snapshot_id;
end;
$function$;

comment on function public.create_odds_market_snapshot_rpc(
  uuid,
  text,
  text,
  timestamp with time zone,
  jsonb,
  jsonb,
  jsonb,
  jsonb,
  integer
) is
'Creates an immutable odds market snapshot idempotently. Hotfix: conflict target uses the named unique constraint to avoid PL/pgSQL output-column ambiguity.';

commit;
