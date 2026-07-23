-- =============================================================================
-- FANTAGOL
-- Migration: 119_commercial_provider_adapter_digest_schema_hotfix.sql
-- Milestone: Commercial Platform - Provider Adapter Contract Hotfix
--
-- Purpose:
--   Fix the persisted adapter-version factory introduced by migration 117.
--   In Supabase, pgcrypto is installed in schema "extensions"; the function
--   search_path is intentionally restricted to public, pg_temp, so digest()
--   must be schema-qualified.
--
-- Scope:
--   - Replaces only create_commercial_provider_adapter_version_internal(...)
--   - Preserves signature, behavior, security-definer boundary and event flow
--   - Uses extensions.digest(..., 'sha256')
-- =============================================================================

\set ON_ERROR_STOP on

begin;

set local statement_timeout = '120s';
set local lock_timeout = '15s';

do $$
begin
  if to_regnamespace('extensions') is null
     or to_regprocedure('extensions.digest(text,text)') is null then
    raise exception 'MIGRATION_119_REQUIRES_EXTENSIONS_PGCRYPTO_DIGEST';
  end if;

  if to_regclass('public.commercial_provider_adapter_contracts') is null
     or to_regclass('public.commercial_provider_adapter_versions') is null
     or to_regclass('public.commercial_provider_adapter_events') is null then
    raise exception 'MIGRATION_119_REQUIRES_MIGRATION_117';
  end if;
end
$$;

create or replace function public.create_commercial_provider_adapter_version_internal(
  p_adapter_contract_id uuid,
  p_request_envelope_schema jsonb,
  p_response_envelope_schema jsonb,
  p_callback_envelope_schema jsonb,
  p_error_envelope_schema jsonb,
  p_change_summary text,
  p_created_by text,
  p_metadata jsonb default '{}'::jsonb
)
returns public.commercial_provider_adapter_versions
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_contract public.commercial_provider_adapter_contracts;
  v_next_version integer;
  v_snapshot jsonb;
  v_result public.commercial_provider_adapter_versions;
begin
  select *
  into strict v_contract
  from public.commercial_provider_adapter_contracts
  where id = p_adapter_contract_id
  for update;

  if v_contract.contract_status in ('suspended','retired') then
    raise exception 'COMMERCIAL_PROVIDER_ADAPTER_CONTRACT_NOT_VERSIONABLE';
  end if;

  select coalesce(max(version_number), 0) + 1
  into v_next_version
  from public.commercial_provider_adapter_versions
  where adapter_contract_id = p_adapter_contract_id;

  v_snapshot := jsonb_build_object(
    'adapter_key', v_contract.adapter_key,
    'protocol_name', v_contract.protocol_name,
    'protocol_major_version', v_contract.protocol_major_version,
    'execution_mode', v_contract.execution_mode,
    'request_envelope_schema', coalesce(p_request_envelope_schema, '{}'::jsonb),
    'response_envelope_schema', coalesce(p_response_envelope_schema, '{}'::jsonb),
    'callback_envelope_schema', coalesce(p_callback_envelope_schema, '{}'::jsonb),
    'error_envelope_schema', coalesce(p_error_envelope_schema, '{}'::jsonb)
  );

  insert into public.commercial_provider_adapter_versions (
    adapter_contract_id,
    version_number,
    version_status,
    request_envelope_schema,
    response_envelope_schema,
    callback_envelope_schema,
    error_envelope_schema,
    contract_snapshot,
    content_hash,
    change_summary,
    created_by,
    metadata
  ) values (
    p_adapter_contract_id,
    v_next_version,
    'draft',
    coalesce(p_request_envelope_schema, '{}'::jsonb),
    coalesce(p_response_envelope_schema, '{}'::jsonb),
    coalesce(p_callback_envelope_schema, '{}'::jsonb),
    coalesce(p_error_envelope_schema, '{}'::jsonb),
    v_snapshot,
    encode(extensions.digest(v_snapshot::text, 'sha256'), 'hex'),
    p_change_summary,
    btrim(p_created_by),
    coalesce(p_metadata, '{}'::jsonb)
  )
  returning * into v_result;

  perform public.append_commercial_provider_adapter_event_internal(
    'ADAPTER_VERSION_CREATED',
    p_created_by,
    p_adapter_contract_id,
    v_result.id,
    null,
    null,
    null,
    null,
    null,
    null,
    'draft',
    p_change_summary,
    null,
    null,
    jsonb_build_object(
      'version_number', v_result.version_number,
      'content_hash', v_result.content_hash
    )
  );

  return v_result;
end
$$;

revoke all on function public.create_commercial_provider_adapter_version_internal(
  uuid,jsonb,jsonb,jsonb,jsonb,text,text,jsonb
) from public, anon, authenticated;

grant execute on function public.create_commercial_provider_adapter_version_internal(
  uuid,jsonb,jsonb,jsonb,jsonb,text,text,jsonb
) to service_role;

do $$
declare
  v_definition text;
begin
  select pg_get_functiondef(
    'public.create_commercial_provider_adapter_version_internal(uuid,jsonb,jsonb,jsonb,jsonb,text,text,jsonb)'::regprocedure
  )
  into v_definition;

  if position('extensions.digest' in v_definition) = 0 then
    raise exception 'MIGRATION_119_DIGEST_QUALIFICATION_ASSERTION_FAILED';
  end if;

  if position('security definer' in lower(v_definition)) = 0 then
    raise exception 'MIGRATION_119_SECURITY_DEFINER_ASSERTION_FAILED';
  end if;

  if position('SET search_path TO ''public'', ''pg_temp''' in v_definition) = 0
     and position('SET search_path TO public, pg_temp' in v_definition) = 0 then
    raise exception 'MIGRATION_119_SEARCH_PATH_ASSERTION_FAILED definition=%',
      v_definition;
  end if;

  raise notice
    'MIGRATION_119_CERTIFIED function=create_commercial_provider_adapter_version_internal, digest_schema=extensions, algorithm=sha256, signature_preserved=true, security_definer=true, restricted_search_path=true';
end
$$;

commit;
