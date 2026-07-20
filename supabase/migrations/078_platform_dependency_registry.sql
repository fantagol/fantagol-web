-- ============================================================================
-- FANTAGOL
-- Migration 078: Platform Dependency Registry
-- Phase 8.2
--
-- Purpose
--   Introduce the canonical relational dependency graph for registered
--   platform engines, with cycle prevention, compatibility requirements,
--   deterministic read contracts and backward-compatible synchronization of
--   platform_engine_registry.dependencies.
--
-- Compatibility
--   Additive and backward compatible. The JSON dependencies column introduced
--   by migration 077 is retained as a synchronized compatibility cache.
--
-- Security model
--   - direct table access: service_role only;
--   - stable read contracts: authenticated and service_role;
--   - no client-side mutation RPC is introduced.
-- ============================================================================

begin;

-- --------------------------------------------------------------------------
-- 1. Canonical dependency aggregate
-- --------------------------------------------------------------------------

create table if not exists public.platform_engine_dependencies (
  dependent_engine_code text not null,
  dependency_engine_code text not null,
  dependency_type text not null default 'required',
  minimum_version text,
  maximum_version_exclusive text,
  require_runtime_enabled boolean not null default true,
  require_certified boolean not null default true,
  allowed_dependency_statuses text[] not null
    default array['active']::text[],
  enabled boolean not null default true,
  rationale text not null,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint platform_engine_dependencies_pk
    primary key (dependent_engine_code, dependency_engine_code),
  constraint platform_engine_dependencies_no_self_ck
    check (dependent_engine_code <> dependency_engine_code),
  constraint platform_engine_dependencies_type_ck
    check (dependency_type in ('required', 'optional', 'runtime', 'certification', 'ordering')),
  constraint platform_engine_dependencies_min_version_ck
    check (
      minimum_version is null
      or minimum_version ~ '^[0-9]+\.[0-9]+\.[0-9]+([+-][0-9A-Za-z.-]+)?$'
    ),
  constraint platform_engine_dependencies_max_version_ck
    check (
      maximum_version_exclusive is null
      or maximum_version_exclusive ~ '^[0-9]+\.[0-9]+\.[0-9]+([+-][0-9A-Za-z.-]+)?$'
    ),
  constraint platform_engine_dependencies_statuses_ck
    check (
      cardinality(allowed_dependency_statuses) > 0
      and allowed_dependency_statuses <@ array[
        'planned', 'installed', 'active', 'degraded',
        'disabled', 'deprecated', 'retired'
      ]::text[]
    ),
  constraint platform_engine_dependencies_rationale_ck
    check (btrim(rationale) <> ''),
  constraint platform_engine_dependencies_metadata_object_ck
    check (jsonb_typeof(metadata) = 'object'),
  constraint platform_engine_dependencies_dependent_fk
    foreign key (dependent_engine_code)
    references public.platform_engine_registry(engine_code)
    on update cascade
    on delete cascade,
  constraint platform_engine_dependencies_dependency_fk
    foreign key (dependency_engine_code)
    references public.platform_engine_registry(engine_code)
    on update cascade
    on delete restrict
);

create index if not exists platform_engine_dependencies_dependency_idx
  on public.platform_engine_dependencies (
    dependency_engine_code,
    enabled,
    dependency_type
  );

create index if not exists platform_engine_dependencies_dependent_idx
  on public.platform_engine_dependencies (
    dependent_engine_code,
    enabled,
    dependency_type
  );

comment on table public.platform_engine_dependencies is
  'Canonical directed dependency graph between registered FantaGol platform engines.';

-- --------------------------------------------------------------------------
-- 2. updated_at trigger
-- --------------------------------------------------------------------------

drop trigger if exists trg_platform_engine_dependencies_updated_at
  on public.platform_engine_dependencies;

create trigger trg_platform_engine_dependencies_updated_at
before update on public.platform_engine_dependencies
for each row
execute function public.set_platform_governance_updated_at();

-- --------------------------------------------------------------------------
-- 3. Dependency graph guards
--    - the dependency must precede the dependent engine in installation order;
--    - enabled edges may never introduce a directed cycle.
-- --------------------------------------------------------------------------

create or replace function public.validate_platform_engine_dependency()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $function$
declare
  v_dependent_order integer;
  v_dependency_order integer;
  v_cycle_found boolean;
begin
  if not new.enabled then
    return new;
  end if;

  select installation_order
    into v_dependent_order
  from public.platform_engine_registry
  where engine_code = new.dependent_engine_code;

  select installation_order
    into v_dependency_order
  from public.platform_engine_registry
  where engine_code = new.dependency_engine_code;

  if v_dependent_order is null or v_dependency_order is null then
    raise exception 'PLATFORM_DEPENDENCY_UNKNOWN_ENGINE: dependent=%, dependency=%',
      new.dependent_engine_code,
      new.dependency_engine_code
      using errcode = '23503';
  end if;

  if v_dependency_order >= v_dependent_order then
    raise exception
      'PLATFORM_DEPENDENCY_INSTALLATION_ORDER_INVALID: dependency % (%) must precede dependent % (%)',
      new.dependency_engine_code,
      v_dependency_order,
      new.dependent_engine_code,
      v_dependent_order
      using errcode = '23514';
  end if;

  if tg_op = 'UPDATE' then
    with recursive reachable(engine_code) as (
      select new.dependency_engine_code

      union

      select d.dependency_engine_code
      from public.platform_engine_dependencies d
      join reachable r
        on d.dependent_engine_code = r.engine_code
      where d.enabled
        and not (
          d.dependent_engine_code = old.dependent_engine_code
          and d.dependency_engine_code = old.dependency_engine_code
        )
    )
    select exists (
      select 1
      from reachable
      where engine_code = new.dependent_engine_code
    )
    into v_cycle_found;
  else
    with recursive reachable(engine_code) as (
      select new.dependency_engine_code

      union

      select d.dependency_engine_code
      from public.platform_engine_dependencies d
      join reachable r
        on d.dependent_engine_code = r.engine_code
      where d.enabled
    )
    select exists (
      select 1
      from reachable
      where engine_code = new.dependent_engine_code
    )
    into v_cycle_found;
  end if;

  if v_cycle_found then
    raise exception 'PLATFORM_DEPENDENCY_CYCLE_DETECTED: % -> %',
      new.dependent_engine_code,
      new.dependency_engine_code
      using errcode = '23514';
  end if;

  return new;
end;
$function$;

comment on function public.validate_platform_engine_dependency() is
  'Prevents invalid installation ordering and directed cycles in the canonical engine dependency graph.';

drop trigger if exists trg_validate_platform_engine_dependency
  on public.platform_engine_dependencies;

create trigger trg_validate_platform_engine_dependency
before insert or update on public.platform_engine_dependencies
for each row
execute function public.validate_platform_engine_dependency();

-- --------------------------------------------------------------------------
-- 4. Backward-compatible JSON cache synchronization
-- --------------------------------------------------------------------------

create or replace function public.refresh_platform_engine_dependencies_cache(
  p_engine_code text
)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $function$
begin
  if p_engine_code is null then
    return;
  end if;

  update public.platform_engine_registry e
  set dependencies = coalesce(
    (
      select jsonb_agg(d.dependency_engine_code order by dep.installation_order, d.dependency_engine_code)
      from public.platform_engine_dependencies d
      join public.platform_engine_registry dep
        on dep.engine_code = d.dependency_engine_code
      where d.dependent_engine_code = p_engine_code
        and d.enabled
    ),
    '[]'::jsonb
  )
  where e.engine_code = p_engine_code;
end;
$function$;

comment on function public.refresh_platform_engine_dependencies_cache(text) is
  'Refreshes the legacy engine-registry dependencies JSON cache from the canonical relational graph.';

create or replace function public.sync_platform_engine_dependencies_cache()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $function$
begin
  if tg_op = 'DELETE' then
    perform public.refresh_platform_engine_dependencies_cache(old.dependent_engine_code);
    return old;
  end if;

  perform public.refresh_platform_engine_dependencies_cache(new.dependent_engine_code);

  if tg_op = 'UPDATE'
     and old.dependent_engine_code is distinct from new.dependent_engine_code then
    perform public.refresh_platform_engine_dependencies_cache(old.dependent_engine_code);
  end if;

  return new;
end;
$function$;

drop trigger if exists trg_sync_platform_engine_dependencies_cache
  on public.platform_engine_dependencies;

create trigger trg_sync_platform_engine_dependencies_cache
after insert or update or delete on public.platform_engine_dependencies
for each row
execute function public.sync_platform_engine_dependencies_cache();

-- --------------------------------------------------------------------------
-- 5. Security
-- --------------------------------------------------------------------------

alter table public.platform_engine_dependencies enable row level security;

revoke all on table public.platform_engine_dependencies from public, anon, authenticated;
grant all on table public.platform_engine_dependencies to service_role;

drop policy if exists platform_engine_dependencies_service_all
  on public.platform_engine_dependencies;

create policy platform_engine_dependencies_service_all
  on public.platform_engine_dependencies
  for all
  to service_role
  using (true)
  with check (true);

-- Internal helper functions are not client contracts.
revoke all on function public.validate_platform_engine_dependency() from public, anon, authenticated;
revoke all on function public.refresh_platform_engine_dependencies_cache(text) from public, anon, authenticated;
revoke all on function public.sync_platform_engine_dependencies_cache() from public, anon, authenticated;
grant execute on function public.validate_platform_engine_dependency() to service_role;
grant execute on function public.refresh_platform_engine_dependencies_cache(text) to service_role;
grant execute on function public.sync_platform_engine_dependencies_cache() to service_role;

-- --------------------------------------------------------------------------
-- 6. Canonical dependency seed
-- --------------------------------------------------------------------------

insert into public.platform_engine_dependencies (
  dependent_engine_code,
  dependency_engine_code,
  dependency_type,
  minimum_version,
  require_runtime_enabled,
  require_certified,
  allowed_dependency_statuses,
  enabled,
  rationale,
  metadata
)
values
  ('competition_engine', 'core_engine', 'required', '1.0.0', true, true, array['active'], true,
    'Competition aggregates require the canonical core domain foundation.',
    '{"source":"migration-077-registry"}'::jsonb),

  ('live_state_engine', 'core_engine', 'required', '1.0.0', true, true, array['active'], true,
    'Live-state persistence and identity depend on the core foundation.',
    '{"source":"migration-077-registry"}'::jsonb),
  ('live_state_engine', 'competition_engine', 'required', '1.0.0', true, true, array['active'], true,
    'Live-state execution requires canonical competition fixtures and rounds.',
    '{"source":"migration-077-registry"}'::jsonb),

  ('round_simulation_engine', 'core_engine', 'required', '1.0.0', true, true, array['active'], true,
    'Simulation persistence depends on core platform identity and audit contracts.',
    '{"source":"migration-077-registry"}'::jsonb),
  ('round_simulation_engine', 'competition_engine', 'required', '1.0.0', true, true, array['active'], true,
    'Round simulations consume canonical competition fixtures and membership.',
    '{"source":"migration-077-registry"}'::jsonb),

  ('publication_engine', 'core_engine', 'required', '1.0.0', true, true, array['active'], true,
    'Publication receipts and snapshots depend on core persistence contracts.',
    '{"source":"migration-077-registry"}'::jsonb),
  ('publication_engine', 'round_simulation_engine', 'required', '1.0.0', true, true, array['active'], true,
    'Publication consumes deterministic round simulation outputs.',
    '{"source":"migration-077-registry"}'::jsonb),

  ('workflow_engine', 'core_engine', 'required', '1.0.0', true, true, array['active'], true,
    'Durable workflow state depends on the core platform foundation.',
    '{"source":"migration-077-registry"}'::jsonb),
  ('workflow_engine', 'publication_engine', 'runtime', '1.0.0', true, true, array['active'], true,
    'Runtime orchestration dispatches and supervises publication work.',
    '{"source":"migration-077-registry"}'::jsonb),

  ('round_certification_engine', 'competition_engine', 'certification', '1.0.0', true, true, array['active'], true,
    'Round certification validates canonical competition state.',
    '{"source":"migration-077-registry"}'::jsonb),
  ('round_certification_engine', 'round_simulation_engine', 'certification', '1.0.0', true, true, array['active'], true,
    'Round certification requires deterministic official simulation output.',
    '{"source":"migration-077-registry"}'::jsonb),
  ('round_certification_engine', 'publication_engine', 'certification', '1.0.0', true, true, array['active'], true,
    'Certified rounds require publication readiness and immutable snapshots.',
    '{"source":"migration-077-registry"}'::jsonb),
  ('round_certification_engine', 'workflow_engine', 'runtime', '1.0.0', true, true, array['active'], true,
    'Certification readiness and execution are orchestrated as durable jobs.',
    '{"source":"migration-077-registry"}'::jsonb),

  ('recovery_engine', 'workflow_engine', 'runtime', '1.0.0', true, true, array['active'], true,
    'Recovery evaluates and repairs durable workflow executions.',
    '{"source":"migration-077-registry"}'::jsonb),

  ('maintenance_engine', 'workflow_engine', 'runtime', '1.0.0', true, true, array['active'], true,
    'Maintenance plans and tasks execute through the workflow runtime.',
    '{"source":"migration-077-registry"}'::jsonb),
  ('maintenance_engine', 'recovery_engine', 'runtime', '1.0.0', true, true, array['active'], true,
    'Maintenance reconciliation integrates with deterministic recovery controls.',
    '{"source":"migration-077-registry"}'::jsonb),

  ('platform_governance_engine', 'core_engine', 'required', '1.0.0', true, true, array['active'], true,
    'Platform governance requires the canonical core database foundation.',
    '{"source":"migration-077-registry"}'::jsonb)
on conflict (dependent_engine_code, dependency_engine_code) do update
set
  dependency_type = excluded.dependency_type,
  minimum_version = excluded.minimum_version,
  maximum_version_exclusive = excluded.maximum_version_exclusive,
  require_runtime_enabled = excluded.require_runtime_enabled,
  require_certified = excluded.require_certified,
  allowed_dependency_statuses = excluded.allowed_dependency_statuses,
  enabled = excluded.enabled,
  rationale = excluded.rationale,
  metadata = public.platform_engine_dependencies.metadata || excluded.metadata;

-- Force a deterministic full cache refresh after the seed/upsert.
do $refresh_cache$
declare
  v_engine record;
begin
  for v_engine in
    select engine_code
    from public.platform_engine_registry
    order by installation_order
  loop
    perform public.refresh_platform_engine_dependencies_cache(v_engine.engine_code);
  end loop;
end;
$refresh_cache$;

-- --------------------------------------------------------------------------
-- 7. Stable read and validation contracts
-- --------------------------------------------------------------------------

create or replace function public.get_platform_engine_dependencies_rpc(
  p_engine_code text default null,
  p_include_disabled boolean default false
)
returns jsonb
language sql
stable
security definer
set search_path = public, pg_temp
as $function$
  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'dependent_engine_code', d.dependent_engine_code,
        'dependent_engine_name', dependent.engine_name,
        'dependency_engine_code', d.dependency_engine_code,
        'dependency_engine_name', dependency.engine_name,
        'dependency_type', d.dependency_type,
        'minimum_version', d.minimum_version,
        'maximum_version_exclusive', d.maximum_version_exclusive,
        'require_runtime_enabled', d.require_runtime_enabled,
        'require_certified', d.require_certified,
        'allowed_dependency_statuses', d.allowed_dependency_statuses,
        'enabled', d.enabled,
        'rationale', d.rationale,
        'metadata', d.metadata,
        'created_at', d.created_at,
        'updated_at', d.updated_at
      )
      order by dependent.installation_order, dependency.installation_order,
               d.dependency_engine_code
    ),
    '[]'::jsonb
  )
  from public.platform_engine_dependencies d
  join public.platform_engine_registry dependent
    on dependent.engine_code = d.dependent_engine_code
  join public.platform_engine_registry dependency
    on dependency.engine_code = d.dependency_engine_code
  where (
      p_engine_code is null
      or d.dependent_engine_code = p_engine_code
      or d.dependency_engine_code = p_engine_code
    )
    and (p_include_disabled or d.enabled);
$function$;

create or replace function public.validate_platform_dependency_graph_rpc(
  p_engine_code text default null
)
returns jsonb
language sql
stable
security definer
set search_path = public, pg_temp
as $function$
  with evaluated as (
    select
      d.dependent_engine_code,
      d.dependency_engine_code,
      d.dependency_type,
      d.enabled,
      dependent.installation_order as dependent_order,
      dependency.installation_order as dependency_order,
      dependency.engine_version as actual_version,
      dependency.lifecycle_status as actual_status,
      dependency.runtime_enabled as actual_runtime_enabled,
      dependency.is_certified as actual_certified,
      (
        d.enabled
        and dependency.installation_order < dependent.installation_order
        and dependency.lifecycle_status = any(d.allowed_dependency_statuses)
        and (not d.require_runtime_enabled or dependency.runtime_enabled)
        and (not d.require_certified or dependency.is_certified)
        and (
          d.minimum_version is null
          or string_to_array(regexp_replace(dependency.engine_version, '[^0-9.].*$', ''), '.')::int[]
             >= string_to_array(regexp_replace(d.minimum_version, '[^0-9.].*$', ''), '.')::int[]
        )
        and (
          d.maximum_version_exclusive is null
          or string_to_array(regexp_replace(dependency.engine_version, '[^0-9.].*$', ''), '.')::int[]
             < string_to_array(regexp_replace(d.maximum_version_exclusive, '[^0-9.].*$', ''), '.')::int[]
        )
      ) as is_satisfied,
      d.minimum_version,
      d.maximum_version_exclusive,
      d.require_runtime_enabled,
      d.require_certified,
      d.allowed_dependency_statuses
    from public.platform_engine_dependencies d
    join public.platform_engine_registry dependent
      on dependent.engine_code = d.dependent_engine_code
    join public.platform_engine_registry dependency
      on dependency.engine_code = d.dependency_engine_code
    where d.enabled
      and (p_engine_code is null or d.dependent_engine_code = p_engine_code)
  )
  select jsonb_build_object(
    'contract_version', 'platform-dependency-validation-v1',
    'generated_at', now(),
    'engine_code', p_engine_code,
    'total_dependencies', count(*),
    'satisfied_dependencies', count(*) filter (where is_satisfied),
    'unsatisfied_dependencies', count(*) filter (where not is_satisfied),
    'is_valid', coalesce(bool_and(is_satisfied), true),
    'dependencies', coalesce(
      jsonb_agg(
        jsonb_build_object(
          'dependent_engine_code', dependent_engine_code,
          'dependency_engine_code', dependency_engine_code,
          'dependency_type', dependency_type,
          'is_satisfied', is_satisfied,
          'actual_version', actual_version,
          'minimum_version', minimum_version,
          'maximum_version_exclusive', maximum_version_exclusive,
          'actual_status', actual_status,
          'allowed_dependency_statuses', allowed_dependency_statuses,
          'actual_runtime_enabled', actual_runtime_enabled,
          'require_runtime_enabled', require_runtime_enabled,
          'actual_certified', actual_certified,
          'require_certified', require_certified,
          'dependency_order', dependency_order,
          'dependent_order', dependent_order
        )
        order by dependent_order, dependency_order, dependency_engine_code
      ),
      '[]'::jsonb
    )
  )
  from evaluated;
$function$;

comment on function public.get_platform_engine_dependencies_rpc(text, boolean) is
  'Returns the canonical platform engine dependency graph, optionally scoped to one related engine.';
comment on function public.validate_platform_dependency_graph_rpc(text) is
  'Evaluates dependency availability, lifecycle, certification, runtime and semantic-version requirements.';

revoke all on function public.get_platform_engine_dependencies_rpc(text, boolean) from public, anon;
revoke all on function public.validate_platform_dependency_graph_rpc(text) from public, anon;
grant execute on function public.get_platform_engine_dependencies_rpc(text, boolean) to authenticated, service_role;
grant execute on function public.validate_platform_dependency_graph_rpc(text) to authenticated, service_role;

-- --------------------------------------------------------------------------
-- 8. Extend consolidated governance snapshot
-- --------------------------------------------------------------------------

create or replace function public.get_platform_governance_snapshot_rpc()
returns jsonb
language sql
stable
security definer
set search_path = public, pg_temp
as $function$
  select jsonb_build_object(
    'contract_version', 'platform-governance-v1',
    'generated_at', now(),
    'configuration', public.get_platform_configuration_rpc(),
    'engines', public.get_platform_engine_registry_rpc(false),
    'dependencies', public.get_platform_engine_dependencies_rpc(null, false),
    'dependency_validation', public.validate_platform_dependency_graph_rpc(null),
    'feature_flags', public.get_platform_feature_flags_rpc(null, false),
    'runtime_policies', public.get_platform_runtime_policies_rpc(null, false),
    'capabilities', public.get_platform_capabilities_rpc(null, false)
  );
$function$;

comment on function public.get_platform_governance_snapshot_rpc() is
  'Returns the consolidated Platform Governance Engine v1 read model, including the canonical dependency graph.';

revoke all on function public.get_platform_governance_snapshot_rpc() from public, anon;
grant execute on function public.get_platform_governance_snapshot_rpc() to authenticated, service_role;

-- --------------------------------------------------------------------------
-- 9. Platform metadata progression
-- --------------------------------------------------------------------------

update public.platform_configuration
set
  schema_version = greatest(schema_version, 78),
  metadata = metadata || jsonb_build_object(
    'dependency_registry_migration', 78,
    'dependency_contract', 'platform-dependency-validation-v1'
  )
where configuration_key = 'primary';

update public.platform_engine_registry
set metadata = metadata || jsonb_build_object(
  'dependency_registry', 'canonical-relational-v1',
  'dependency_registry_migration', 78
)
where engine_code = 'platform_governance_engine';

-- --------------------------------------------------------------------------
-- 10. Migration assertions
-- --------------------------------------------------------------------------

do $assertions$
declare
  v_dependency_count integer;
  v_cache_mismatch_count integer;
  v_validation jsonb;
begin
  select count(*)
    into v_dependency_count
  from public.platform_engine_dependencies
  where enabled;

  if v_dependency_count <> 17 then
    raise exception
      'PLATFORM_DEPENDENCY_ASSERTION_FAILED: expected 17 enabled dependencies, found %',
      v_dependency_count;
  end if;

  select count(*)
    into v_cache_mismatch_count
  from public.platform_engine_registry e
  where e.dependencies is distinct from coalesce(
    (
      select jsonb_agg(d.dependency_engine_code order by dep.installation_order, d.dependency_engine_code)
      from public.platform_engine_dependencies d
      join public.platform_engine_registry dep
        on dep.engine_code = d.dependency_engine_code
      where d.dependent_engine_code = e.engine_code
        and d.enabled
    ),
    '[]'::jsonb
  );

  if v_cache_mismatch_count <> 0 then
    raise exception
      'PLATFORM_DEPENDENCY_ASSERTION_FAILED: % engine dependency cache rows are inconsistent',
      v_cache_mismatch_count;
  end if;

  v_validation := public.validate_platform_dependency_graph_rpc(null);

  if coalesce((v_validation ->> 'is_valid')::boolean, false) is not true then
    raise exception
      'PLATFORM_DEPENDENCY_ASSERTION_FAILED: dependency graph validation failed: %',
      v_validation;
  end if;

  if exists (
    with recursive graph(root_engine, engine_code, path, cycle) as (
      select
        d.dependent_engine_code,
        d.dependency_engine_code,
        array[d.dependent_engine_code, d.dependency_engine_code]::text[],
        false
      from public.platform_engine_dependencies d
      where d.enabled

      union all

      select
        g.root_engine,
        d.dependency_engine_code,
        g.path || d.dependency_engine_code,
        d.dependency_engine_code = any(g.path)
      from graph g
      join public.platform_engine_dependencies d
        on d.dependent_engine_code = g.engine_code
      where d.enabled
        and not g.cycle
    )
    select 1
    from graph
    where cycle
  ) then
    raise exception 'PLATFORM_DEPENDENCY_ASSERTION_FAILED: cycle detected in dependency graph';
  end if;

  if not (
    public.get_platform_governance_snapshot_rpc() ? 'dependencies'
    and public.get_platform_governance_snapshot_rpc() ? 'dependency_validation'
  ) then
    raise exception
      'PLATFORM_DEPENDENCY_ASSERTION_FAILED: governance snapshot dependency keys missing';
  end if;
end;
$assertions$;

commit;
