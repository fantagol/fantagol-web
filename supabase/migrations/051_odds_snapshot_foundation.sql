begin;

create table if not exists public.odds_market_snapshots (
  id uuid primary key default gen_random_uuid(),
  match_id uuid not null references public.matches(id) on delete restrict,
  provider_id uuid not null references public.data_providers(id) on delete restrict,
  external_match_id text not null,
  market_code text not null default 'h2h',
  odds_format text not null default 'decimal',
  collected_at timestamptz not null,
  provider_payload jsonb not null default '{}'::jsonb,
  canonical_payload jsonb not null,
  consensus_payload jsonb,
  quality_payload jsonb not null default '{}'::jsonb,
  snapshot_schema_version integer not null default 1,
  snapshot_hash text not null,
  created_at timestamptz not null default now(),
  constraint odds_market_snapshots_external_match_nonempty
    check (btrim(external_match_id) <> ''),
  constraint odds_market_snapshots_market_h2h
    check (market_code = 'h2h'),
  constraint odds_market_snapshots_decimal_only
    check (odds_format = 'decimal'),
  constraint odds_market_snapshots_schema_version_positive
    check (snapshot_schema_version > 0),
  constraint odds_market_snapshots_hash_nonempty
    check (btrim(snapshot_hash) <> ''),
  constraint odds_market_snapshots_provider_hash_unique
    unique (provider_id, external_match_id, snapshot_hash)
);

create index if not exists odds_market_snapshots_match_collected_idx
  on public.odds_market_snapshots(match_id, collected_at desc);

create index if not exists odds_market_snapshots_provider_external_idx
  on public.odds_market_snapshots(provider_id, external_match_id, collected_at desc);

create table if not exists public.official_match_odds_snapshots (
  id uuid primary key default gen_random_uuid(),
  match_id uuid not null unique references public.matches(id) on delete restrict,
  odds_market_snapshot_id uuid not null
    references public.odds_market_snapshots(id) on delete restrict,
  frozen_at timestamptz not null default now(),
  freeze_reason text not null default 'round_lock',
  policy_version text not null default 'official_match_odds_v1',
  official_hash text not null,
  created_at timestamptz not null default now(),
  constraint official_match_odds_freeze_reason_nonempty
    check (btrim(freeze_reason) <> ''),
  constraint official_match_odds_policy_nonempty
    check (btrim(policy_version) <> ''),
  constraint official_match_odds_hash_nonempty
    check (btrim(official_hash) <> '')
);

create index if not exists official_match_odds_snapshot_idx
  on public.official_match_odds_snapshots(odds_market_snapshot_id);

create or replace function public.prevent_official_match_odds_mutation()
returns trigger
language plpgsql
security invoker
set search_path = public, pg_temp
as $$
begin
  raise exception
    'official_match_odds_snapshots are immutable';
end;
$$;

drop trigger if exists official_match_odds_immutable_trigger
  on public.official_match_odds_snapshots;

create trigger official_match_odds_immutable_trigger
before update or delete on public.official_match_odds_snapshots
for each row execute function public.prevent_official_match_odds_mutation();

create or replace function public.create_odds_market_snapshot_rpc(
  p_match_id uuid,
  p_provider_code text,
  p_external_match_id text,
  p_collected_at timestamptz,
  p_provider_payload jsonb,
  p_canonical_payload jsonb,
  p_consensus_payload jsonb default null,
  p_quality_payload jsonb default '{}'::jsonb,
  p_snapshot_schema_version integer default 1
)
returns table (
  odds_market_snapshot_id uuid,
  match_id uuid,
  provider_id uuid,
  collected_at timestamptz,
  snapshot_hash text,
  inserted boolean
)
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
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
  on conflict (provider_id, external_match_id, snapshot_hash)
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
$$;

create or replace function public.freeze_match_odds_snapshot_rpc(
  p_match_id uuid,
  p_freeze_at timestamptz default now(),
  p_freeze_reason text default 'round_lock',
  p_policy_version text default 'official_match_odds_v1'
)
returns table (
  official_match_odds_snapshot_id uuid,
  match_id uuid,
  odds_market_snapshot_id uuid,
  source_collected_at timestamptz,
  official_hash text,
  already_frozen boolean
)
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
declare
  v_existing public.official_match_odds_snapshots%rowtype;
  v_source public.odds_market_snapshots%rowtype;
  v_official_id uuid;
  v_official_hash text;
begin
  if p_match_id is null then
    raise exception 'p_match_id is required';
  end if;

  if p_freeze_at is null then
    raise exception 'p_freeze_at is required';
  end if;

  if btrim(coalesce(p_freeze_reason, '')) = '' then
    raise exception 'p_freeze_reason is required';
  end if;

  if btrim(coalesce(p_policy_version, '')) = '' then
    raise exception 'p_policy_version is required';
  end if;

  perform pg_advisory_xact_lock(
    hashtextextended(
      'official-match-odds:' || p_match_id::text,
      0
    )
  );

  select *
    into v_existing
  from public.official_match_odds_snapshots omos
  where omos.match_id = p_match_id;

  if found then
    return query
    select
      v_existing.id,
      v_existing.match_id,
      v_existing.odds_market_snapshot_id,
      oms.collected_at,
      v_existing.official_hash,
      true
    from public.odds_market_snapshots oms
    where oms.id = v_existing.odds_market_snapshot_id;
    return;
  end if;

  select oms.*
    into v_source
  from public.odds_market_snapshots oms
  where oms.match_id = p_match_id
    and oms.collected_at <= p_freeze_at
    and oms.consensus_payload is not null
    and coalesce((oms.quality_payload ->> 'hasConsensus')::boolean, false) = true
  order by oms.collected_at desc, oms.created_at desc
  limit 1;

  if v_source.id is null then
    raise exception
      'no valid odds snapshot available for match % at or before %',
      p_match_id,
      p_freeze_at;
  end if;

  v_official_hash := encode(
    extensions.digest(
      convert_to(
        jsonb_build_object(
          'policy_version', p_policy_version,
          'match_id', p_match_id,
          'odds_market_snapshot_id', v_source.id,
          'source_snapshot_hash', v_source.snapshot_hash,
          'freeze_at', p_freeze_at,
          'freeze_reason', p_freeze_reason
        )::text,
        'UTF8'
      ),
      'sha256'
    ),
    'hex'
  );

  insert into public.official_match_odds_snapshots (
    match_id,
    odds_market_snapshot_id,
    frozen_at,
    freeze_reason,
    policy_version,
    official_hash
  )
  values (
    p_match_id,
    v_source.id,
    p_freeze_at,
    p_freeze_reason,
    p_policy_version,
    v_official_hash
  )
  returning id into v_official_id;

  return query
  select
    v_official_id,
    p_match_id,
    v_source.id,
    v_source.collected_at,
    v_official_hash,
    false;
end;
$$;

alter table public.odds_market_snapshots enable row level security;
alter table public.official_match_odds_snapshots enable row level security;

revoke all on public.odds_market_snapshots from anon, authenticated;
revoke all on public.official_match_odds_snapshots from anon, authenticated;
revoke all on function public.create_odds_market_snapshot_rpc(
  uuid, text, text, timestamptz, jsonb, jsonb, jsonb, jsonb, integer
) from public, anon, authenticated;
revoke all on function public.freeze_match_odds_snapshot_rpc(
  uuid, timestamptz, text, text
) from public, anon, authenticated;

grant select, insert on public.odds_market_snapshots to service_role;
grant select, insert on public.official_match_odds_snapshots to service_role;
grant execute on function public.create_odds_market_snapshot_rpc(
  uuid, text, text, timestamptz, jsonb, jsonb, jsonb, jsonb, integer
) to service_role;
grant execute on function public.freeze_match_odds_snapshot_rpc(
  uuid, timestamptz, text, text
) to service_role;

commit;
