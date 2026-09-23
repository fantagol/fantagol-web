-- ============================================================================
-- MIGRATION 332
-- Versioned retention execution activation authority.
--
-- Purpose:
--   - provide an explicit postgres-only authority for execution activation
--   - preserve immutable target-version lineage
--   - never toggle execution_enabled in place on the active version
--
-- Safety:
--   - expected-version optimistic guard
--   - advisory lock per target key
--   - requires active planner-enabled, execution-disabled, destructive target
--   - clones target definition exactly into next version
--   - new version is planner_enabled=true, execution_enabled=true
--   - no service_role execute grant
-- ============================================================================

create or replace function public.activate_retention_target_execution_rpc(
  p_target_key text,
  p_expected_current_version integer,
  p_activated_by uuid,
  p_reason text
)
returns public.retention_targets
language plpgsql
security definer
set search_path to 'public', 'extensions', 'pg_temp'
as $function$
declare
  v_current public.retention_targets%rowtype;
  v_new public.retention_targets%rowtype;
  v_reason text;
begin
  if btrim(coalesce(p_target_key, '')) = '' then
    raise exception using
      errcode = '22023',
      message = 'RETENTION_TARGET_KEY_REQUIRED';
  end if;

  if p_expected_current_version is null or p_expected_current_version <= 0 then
    raise exception using
      errcode = '22023',
      message = 'RETENTION_EXPECTED_VERSION_REQUIRED';
  end if;

  if p_activated_by is null then
    raise exception using
      errcode = '22023',
      message = 'RETENTION_EXECUTION_ACTIVATOR_REQUIRED';
  end if;

  v_reason := nullif(btrim(coalesce(p_reason, '')), '');

  if v_reason is null then
    raise exception using
      errcode = '22023',
      message = 'RETENTION_EXECUTION_ACTIVATION_REASON_REQUIRED';
  end if;

  perform pg_advisory_xact_lock(
    hashtextextended('retention-target-execution:' || btrim(p_target_key), 0)
  );

  select rt.*
    into v_current
  from public.retention_targets rt
  where rt.target_key = btrim(p_target_key)
    and rt.retired_at is null
  for update;

  if v_current.id is null then
    raise exception using
      errcode = 'P0002',
      message = 'RETENTION_TARGET_NOT_FOUND';
  end if;

  if v_current.target_version <> p_expected_current_version then
    raise exception using
      errcode = '40001',
      message = 'RETENTION_TARGET_VERSION_MISMATCH',
      detail = format(
        'expected=%s actual=%s',
        p_expected_current_version,
        v_current.target_version
      );
  end if;

  if not v_current.planner_enabled then
    raise exception using
      errcode = '55000',
      message = 'RETENTION_TARGET_PLANNER_DISABLED';
  end if;

  if v_current.execution_enabled then
    raise exception using
      errcode = '55000',
      message = 'RETENTION_TARGET_EXECUTION_ALREADY_ENABLED';
  end if;

  if not v_current.destructive then
    raise exception using
      errcode = '55000',
      message = 'RETENTION_TARGET_NOT_DESTRUCTIVE';
  end if;

  perform public.validate_retention_target_definition(
    v_current.target_schema,
    v_current.target_table,
    v_current.identity_column,
    v_current.timestamp_column,
    v_current.status_column,
    v_current.additional_predicate_sql
  );

  update public.retention_targets
     set retired_at = clock_timestamp(),
         planner_enabled = false,
         execution_enabled = false,
         updated_at = clock_timestamp()
   where id = v_current.id;

  insert into public.retention_targets (
    target_key,
    target_version,
    display_name,
    description,
    target_schema,
    target_table,
    identity_column,
    timestamp_column,
    status_column,
    terminal_statuses,
    additional_predicate_sql,
    default_retention_interval,
    default_batch_size,
    maximum_batch_size,
    dependency_class,
    planner_enabled,
    execution_enabled,
    destructive,
    target_config,
    created_by
  )
  values (
    v_current.target_key,
    v_current.target_version + 1,
    v_current.display_name,
    v_current.description,
    v_current.target_schema,
    v_current.target_table,
    v_current.identity_column,
    v_current.timestamp_column,
    v_current.status_column,
    v_current.terminal_statuses,
    v_current.additional_predicate_sql,
    v_current.default_retention_interval,
    v_current.default_batch_size,
    v_current.maximum_batch_size,
    v_current.dependency_class,
    true,
    true,
    v_current.destructive,
    v_current.target_config || jsonb_build_object(
      'execution_activation',
      jsonb_build_object(
        'authority', 'activate_retention_target_execution_rpc',
        'source_target_version', v_current.target_version,
        'activated_by', p_activated_by,
        'reason', v_reason,
        'activated_at', clock_timestamp()
      )
    ),
    p_activated_by
  )
  returning * into v_new;

  return v_new;
end;
$function$;

revoke all on function public.activate_retention_target_execution_rpc(
  text,integer,uuid,text
) from public;

revoke all on function public.activate_retention_target_execution_rpc(
  text,integer,uuid,text
) from service_role;