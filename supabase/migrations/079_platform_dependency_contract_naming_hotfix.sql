-- ============================================================================
-- FANTAGOL
-- Migration 079: Platform Dependency Contract Naming Hotfix
-- Phase 8.2.1
--
-- Purpose
--   Normalize dependency requirement naming from imperative singular forms
--   (require_*) to declarative boolean forms (requires_*), consistently across
--   the relational schema and JSON read contracts.
--
-- Compatibility
--   Data-preserving and behavior-preserving. No dependency edge is changed.
--   Existing RPC signatures remain unchanged; only two JSON property names are
--   normalized. The migration is safe to re-run after successful application.
-- ============================================================================

begin;

-- --------------------------------------------------------------------------
-- 1. Normalize canonical column names
-- --------------------------------------------------------------------------

do $rename_columns$
begin
  if exists (
    select 1
    from information_schema.columns
    where table_schema = 'public'
      and table_name = 'platform_engine_dependencies'
      and column_name = 'require_runtime_enabled'
  ) and not exists (
    select 1
    from information_schema.columns
    where table_schema = 'public'
      and table_name = 'platform_engine_dependencies'
      and column_name = 'requires_runtime_enabled'
  ) then
    alter table public.platform_engine_dependencies
      rename column require_runtime_enabled to requires_runtime_enabled;
  end if;

  if exists (
    select 1
    from information_schema.columns
    where table_schema = 'public'
      and table_name = 'platform_engine_dependencies'
      and column_name = 'require_certified'
  ) and not exists (
    select 1
    from information_schema.columns
    where table_schema = 'public'
      and table_name = 'platform_engine_dependencies'
      and column_name = 'requires_certification'
  ) then
    alter table public.platform_engine_dependencies
      rename column require_certified to requires_certification;
  end if;
end;
$rename_columns$;

comment on column public.platform_engine_dependencies.requires_runtime_enabled is
  'Whether the dependency engine must currently be runtime-enabled for the edge to be satisfied.';

comment on column public.platform_engine_dependencies.requires_certification is
  'Whether the dependency engine must be certified for the edge to be satisfied.';

-- --------------------------------------------------------------------------
-- 2. Normalize canonical dependency read contract
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
        'requires_runtime_enabled', d.requires_runtime_enabled,
        'requires_certification', d.requires_certification,
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

comment on function public.get_platform_engine_dependencies_rpc(text, boolean) is
  'Returns the canonical platform engine dependency graph using normalized requires_* boolean properties.';

-- --------------------------------------------------------------------------
-- 3. Normalize dependency validation contract
-- --------------------------------------------------------------------------

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
        and (not d.requires_runtime_enabled or dependency.runtime_enabled)
        and (not d.requires_certification or dependency.is_certified)
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
      d.requires_runtime_enabled,
      d.requires_certification,
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
    'contract_version', 'platform-dependency-validation-v1.1',
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
          'requires_runtime_enabled', requires_runtime_enabled,
          'actual_certified', actual_certified,
          'requires_certification', requires_certification,
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

comment on function public.validate_platform_dependency_graph_rpc(text) is
  'Evaluates dependency requirements and exposes normalized requires_* boolean properties (contract v1.1).';

revoke all on function public.get_platform_engine_dependencies_rpc(text, boolean) from public, anon;
revoke all on function public.validate_platform_dependency_graph_rpc(text) from public, anon;
grant execute on function public.get_platform_engine_dependencies_rpc(text, boolean) to authenticated, service_role;
grant execute on function public.validate_platform_dependency_graph_rpc(text) to authenticated, service_role;

-- --------------------------------------------------------------------------
-- 4. Platform metadata progression
-- --------------------------------------------------------------------------

update public.platform_configuration
set
  schema_version = greatest(schema_version, 79),
  metadata = metadata || jsonb_build_object(
    'dependency_contract_naming_hotfix_migration', 79,
    'dependency_contract', 'platform-dependency-validation-v1.1'
  )
where configuration_key = 'primary';

update public.platform_engine_registry
set metadata = metadata || jsonb_build_object(
  'dependency_contract', 'platform-dependency-validation-v1.1',
  'dependency_contract_naming_hotfix_migration', 79
)
where engine_code = 'platform_governance_engine';

-- --------------------------------------------------------------------------
-- 5. Contract assertions
-- --------------------------------------------------------------------------

do $assertions$
declare
  v_dependency_count integer;
  v_read_contract jsonb;
  v_validation jsonb;
begin
  if not exists (
    select 1
    from information_schema.columns
    where table_schema = 'public'
      and table_name = 'platform_engine_dependencies'
      and column_name = 'requires_runtime_enabled'
  ) then
    raise exception
      'PLATFORM_DEPENDENCY_NAMING_ASSERTION_FAILED: requires_runtime_enabled column missing';
  end if;

  if not exists (
    select 1
    from information_schema.columns
    where table_schema = 'public'
      and table_name = 'platform_engine_dependencies'
      and column_name = 'requires_certification'
  ) then
    raise exception
      'PLATFORM_DEPENDENCY_NAMING_ASSERTION_FAILED: requires_certification column missing';
  end if;

  if exists (
    select 1
    from information_schema.columns
    where table_schema = 'public'
      and table_name = 'platform_engine_dependencies'
      and column_name in ('require_runtime_enabled', 'require_certified')
  ) then
    raise exception
      'PLATFORM_DEPENDENCY_NAMING_ASSERTION_FAILED: legacy require_* columns still present';
  end if;

  select count(*)
    into v_dependency_count
  from public.platform_engine_dependencies
  where enabled;

  if v_dependency_count <> 17 then
    raise exception
      'PLATFORM_DEPENDENCY_NAMING_ASSERTION_FAILED: expected 17 enabled dependencies, found %',
      v_dependency_count;
  end if;

  v_read_contract := public.get_platform_engine_dependencies_rpc(null, false);

  if jsonb_array_length(v_read_contract) <> 17 then
    raise exception
      'PLATFORM_DEPENDENCY_NAMING_ASSERTION_FAILED: read contract expected 17 dependencies';
  end if;

  if exists (
    select 1
    from jsonb_array_elements(v_read_contract) edge
    where not (
      edge ? 'requires_runtime_enabled'
      and edge ? 'requires_certification'
    )
  ) then
    raise exception
      'PLATFORM_DEPENDENCY_NAMING_ASSERTION_FAILED: normalized read-contract keys missing';
  end if;

  if exists (
    select 1
    from jsonb_array_elements(v_read_contract) edge
    where edge ? 'require_runtime_enabled'
       or edge ? 'require_certified'
  ) then
    raise exception
      'PLATFORM_DEPENDENCY_NAMING_ASSERTION_FAILED: legacy read-contract keys still exposed';
  end if;

  v_validation := public.validate_platform_dependency_graph_rpc(null);

  if coalesce((v_validation ->> 'is_valid')::boolean, false) is not true
     or coalesce((v_validation ->> 'unsatisfied_dependencies')::integer, -1) <> 0 then
    raise exception
      'PLATFORM_DEPENDENCY_NAMING_ASSERTION_FAILED: graph validation failed: %',
      v_validation;
  end if;

  if v_validation ->> 'contract_version' <> 'platform-dependency-validation-v1.1' then
    raise exception
      'PLATFORM_DEPENDENCY_NAMING_ASSERTION_FAILED: unexpected validation contract version: %',
      v_validation ->> 'contract_version';
  end if;

  if exists (
    select 1
    from jsonb_array_elements(v_validation -> 'dependencies') edge
    where not (
      edge ? 'requires_runtime_enabled'
      and edge ? 'requires_certification'
    )
  ) then
    raise exception
      'PLATFORM_DEPENDENCY_NAMING_ASSERTION_FAILED: normalized validation keys missing';
  end if;
end;
$assertions$;

commit;
