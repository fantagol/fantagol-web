-- ============================================================================
-- FANTAGOL
-- Migration 175: Account Lifecycle Finalization Foundation
-- Milestone 13.8.6
-- INSTALLATION ONLY - ALL EXECUTION FLAGS REMAIN DISABLED
-- ============================================================================

begin;
set local lock_timeout = '10s';
set local statement_timeout = '0';

-- --------------------------------------------------------------------------
-- 0. Baseline assertions
-- --------------------------------------------------------------------------
do $preflight$
declare
  v_schema_version integer;
  v_runtime_enabled boolean;
  v_certified boolean;
  v_automatic boolean;
begin
  select schema_version into v_schema_version
  from public.platform_configuration
  where configuration_key = 'primary';
  if v_schema_version is null or v_schema_version < 174 then
    raise exception 'ACCOUNT_FINALIZATION_REQUIRES_SCHEMA_174';
  end if;

  if to_regclass('public.account_lifecycle') is null
     or to_regclass('public.account_erasure_runs') is null
     or to_regclass('public.account_erasure_steps') is null
     or to_regclass('public.account_deletion_audit') is null then
    raise exception 'ACCOUNT_FINALIZATION_BASELINE_OBJECT_MISSING';
  end if;

  if to_regprocedure('public.get_account_erasure_handler_context_internal(uuid)') is null
     or to_regprocedure('public.complete_account_erasure_step_internal(uuid,bigint,bigint,jsonb)') is null
     or to_regprocedure('public.block_account_erasure_step_internal(uuid,text,jsonb)') is null then
    raise exception 'ACCOUNT_FINALIZATION_BASELINE_FUNCTION_MISSING';
  end if;

  select runtime_enabled, is_certified
    into v_runtime_enabled, v_certified
  from public.platform_engine_registry
  where engine_code = 'account_lifecycle_engine';

  select automatic_execution_enabled into v_automatic
  from public.account_lifecycle_policies
  where policy_code = 'ACCOUNT_DELETION_STANDARD' and policy_version = 1;

  if coalesce(v_runtime_enabled,false) or coalesce(v_certified,false)
     or coalesce(v_automatic,false) then
    raise exception 'ACCOUNT_FINALIZATION_INSTALL_REQUIRES_DISABLED_ENGINE';
  end if;
end;
$preflight$;

-- --------------------------------------------------------------------------
-- 1. External command, attempt, receipt and Storage registry
-- --------------------------------------------------------------------------
create table if not exists public.account_erasure_external_commands (
  id uuid primary key default extensions.gen_random_uuid(),
  account_lifecycle_id uuid not null references public.account_lifecycle(id) on delete restrict,
  erasure_run_id uuid not null references public.account_erasure_runs(id) on delete restrict,
  erasure_step_id uuid not null references public.account_erasure_steps(id) on delete restrict,
  command_type text not null,
  command_status text not null default 'prepared',
  provider_code text not null,
  provider_operation text not null,
  idempotency_key text not null,
  command_version integer not null default 1,
  target_digest text not null,
  request_digest text not null,
  restricted_payload jsonb not null default '{}'::jsonb,
  public_metadata jsonb not null default '{}'::jsonb,
  prepared_at timestamptz not null default clock_timestamp(),
  dispatched_at timestamptz,
  completed_at timestamptz,
  failed_at timestamptz,
  attempt_count integer not null default 0,
  last_error_code text,
  last_error_message text,
  lease_owner text,
  lease_token uuid,
  leased_at timestamptz,
  lease_expires_at timestamptz,
  version bigint not null default 1,
  created_at timestamptz not null default clock_timestamp(),
  updated_at timestamptz not null default clock_timestamp(),
  constraint account_erasure_external_commands_type_ck check (command_type in ('DELETE_STORAGE_ASSETS','DELETE_SUPABASE_AUTH_IDENTITY')),
  constraint account_erasure_external_commands_status_ck check (command_status in ('prepared','dispatched','completed','failed','ambiguous','cancelled')),
  constraint account_erasure_external_commands_attempt_ck check (attempt_count >= 0 and command_version > 0 and version > 0),
  constraint account_erasure_external_commands_json_ck check (jsonb_typeof(restricted_payload)='object' and jsonb_typeof(public_metadata)='object'),
  constraint account_erasure_external_commands_completion_ck check (
    (command_status='completed' and completed_at is not null and failed_at is null) or
    (command_status='failed' and failed_at is not null and completed_at is null) or
    (command_status not in ('completed','failed') and completed_at is null and failed_at is null)
  ),
  constraint account_erasure_external_commands_lease_ck check (
    (lease_token is null and lease_owner is null and leased_at is null and lease_expires_at is null) or
    (lease_token is not null and lease_owner is not null and leased_at is not null and lease_expires_at is not null and lease_expires_at > leased_at)
  ),
  constraint account_erasure_external_commands_step_uq unique(erasure_step_id),
  constraint account_erasure_external_commands_idempotency_uq unique(idempotency_key)
);

create table if not exists public.account_erasure_external_attempts (
  id uuid primary key default extensions.gen_random_uuid(),
  command_id uuid not null references public.account_erasure_external_commands(id) on delete restrict,
  attempt_number integer not null,
  attempt_status text not null default 'started',
  worker_id text not null,
  correlation_id uuid not null,
  provider_request_id text,
  started_at timestamptz not null default clock_timestamp(),
  completed_at timestamptz,
  error_code text,
  error_class text,
  retryable boolean,
  request_digest text not null,
  response_digest text,
  restricted_response jsonb not null default '{}'::jsonb,
  public_evidence jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default clock_timestamp(),
  constraint account_erasure_external_attempts_number_ck check (attempt_number >= 1),
  constraint account_erasure_external_attempts_status_ck check (attempt_status in ('started','succeeded','failed','ambiguous')),
  constraint account_erasure_external_attempts_json_ck check (jsonb_typeof(restricted_response)='object' and jsonb_typeof(public_evidence)='object'),
  constraint account_erasure_external_attempts_uq unique(command_id, attempt_number)
);

create table if not exists public.account_erasure_external_receipts (
  id uuid primary key default extensions.gen_random_uuid(),
  command_id uuid not null references public.account_erasure_external_commands(id) on delete restrict,
  attempt_id uuid not null references public.account_erasure_external_attempts(id) on delete restrict,
  receipt_type text not null,
  receipt_status text not null,
  provider_code text not null,
  provider_operation text not null,
  provider_request_id text,
  result_digest text not null,
  evidence_digest text not null,
  affected_object_count bigint not null default 0,
  residual_object_count bigint,
  restricted_evidence jsonb not null default '{}'::jsonb,
  public_evidence jsonb not null default '{}'::jsonb,
  verified_at timestamptz not null default clock_timestamp(),
  created_at timestamptz not null default clock_timestamp(),
  constraint account_erasure_external_receipts_type_ck check (receipt_type in ('STORAGE_DELETION','AUTH_DELETION')),
  constraint account_erasure_external_receipts_status_ck check (receipt_status in ('verified_success','verified_already_absent','verified_failure','ambiguous')),
  constraint account_erasure_external_receipts_counts_ck check (affected_object_count >= 0 and (residual_object_count is null or residual_object_count >= 0)),
  constraint account_erasure_external_receipts_json_ck check (jsonb_typeof(restricted_evidence)='object' and jsonb_typeof(public_evidence)='object'),
  constraint account_erasure_external_receipts_command_uq unique(command_id)
);

create table if not exists public.account_erasure_storage_registry (
  id uuid primary key default extensions.gen_random_uuid(),
  bucket_code text not null,
  registry_version integer not null,
  active boolean not null default false,
  approved boolean not null default false,
  discovery_strategies jsonb not null default '[]'::jsonb,
  path_normalization_version integer not null default 1,
  delete_batch_size integer not null default 100,
  max_objects_per_account integer not null default 1000,
  requires_residual_scan boolean not null default true,
  effective_from timestamptz not null default clock_timestamp(),
  retired_at timestamptz,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default clock_timestamp(),
  updated_at timestamptz not null default clock_timestamp(),
  constraint account_erasure_storage_registry_uq unique(bucket_code, registry_version),
  constraint account_erasure_storage_registry_values_ck check (btrim(bucket_code)<>'' and registry_version>0 and path_normalization_version>0 and delete_batch_size between 1 and 1000 and max_objects_per_account between 1 and 100000),
  constraint account_erasure_storage_registry_json_ck check (jsonb_typeof(discovery_strategies)='array' and jsonb_typeof(metadata)='object'),
  constraint account_erasure_storage_registry_window_ck check (retired_at is null or retired_at > effective_from)
);

create index if not exists account_erasure_external_commands_status_idx on public.account_erasure_external_commands(command_status, lease_expires_at);
create index if not exists account_erasure_external_commands_run_idx on public.account_erasure_external_commands(erasure_run_id, created_at);
create index if not exists account_erasure_external_commands_lifecycle_idx on public.account_erasure_external_commands(account_lifecycle_id, created_at);
create index if not exists account_erasure_external_attempts_command_idx on public.account_erasure_external_attempts(command_id, attempt_number desc);
create index if not exists account_erasure_external_attempts_correlation_idx on public.account_erasure_external_attempts(correlation_id);
create index if not exists account_erasure_storage_registry_active_idx on public.account_erasure_storage_registry(bucket_code, registry_version desc) where active and approved and retired_at is null;

insert into public.account_erasure_storage_registry(bucket_code,registry_version,active,approved,discovery_strategies,path_normalization_version,delete_batch_size,max_objects_per_account,requires_residual_scan,metadata)
values ('club-avatars',1,false,true,'["profile_avatar_url","club_crest_url","storage_owner","uuid_prefix"]'::jsonb,1,100,1000,true,jsonb_build_object('installed_by_migration',175,'contract_version','1.0.0'))
on conflict (bucket_code,registry_version) do update set approved=true, active=false, updated_at=clock_timestamp(), metadata=excluded.metadata;

-- --------------------------------------------------------------------------
-- 2. RLS and Service Role ownership
-- --------------------------------------------------------------------------
alter table public.account_erasure_external_commands enable row level security;
alter table public.account_erasure_external_commands force row level security;
alter table public.account_erasure_external_attempts enable row level security;
alter table public.account_erasure_external_attempts force row level security;
alter table public.account_erasure_external_receipts enable row level security;
alter table public.account_erasure_external_receipts force row level security;
alter table public.account_erasure_storage_registry enable row level security;
alter table public.account_erasure_storage_registry force row level security;

revoke all on table public.account_erasure_external_commands from public,anon,authenticated;
revoke all on table public.account_erasure_external_attempts from public,anon,authenticated;
revoke all on table public.account_erasure_external_receipts from public,anon,authenticated;
revoke all on table public.account_erasure_storage_registry from public,anon,authenticated;
grant select,insert,update,delete on table public.account_erasure_external_commands to service_role;
grant select,insert,update,delete on table public.account_erasure_external_attempts to service_role;
grant select,insert on table public.account_erasure_external_receipts to service_role;
grant select,insert,update on table public.account_erasure_storage_registry to service_role;

-- --------------------------------------------------------------------------
-- 3. Immutable guards
-- --------------------------------------------------------------------------
create or replace function public.guard_account_erasure_external_command_transition()
returns trigger language plpgsql security definer set search_path=public,pg_catalog as $f$
begin
  if tg_op='DELETE' then raise exception 'ACCOUNT_ERASURE_EXTERNAL_COMMAND_DELETE_FORBIDDEN'; end if;
  if old.command_status in ('completed','cancelled') then raise exception 'ACCOUNT_ERASURE_EXTERNAL_COMMAND_TERMINAL'; end if;
  if new.account_lifecycle_id<>old.account_lifecycle_id or new.erasure_run_id<>old.erasure_run_id or new.erasure_step_id<>old.erasure_step_id or new.command_type<>old.command_type or new.idempotency_key<>old.idempotency_key or new.target_digest<>old.target_digest or new.request_digest<>old.request_digest then raise exception 'ACCOUNT_ERASURE_EXTERNAL_COMMAND_IDENTITY_IMMUTABLE'; end if;
  if old.command_status='dispatched' and new.restricted_payload<>old.restricted_payload then raise exception 'ACCOUNT_ERASURE_EXTERNAL_COMMAND_TARGET_IMMUTABLE_AFTER_DISPATCH'; end if;
  if not ((old.command_status='prepared' and new.command_status in ('prepared','dispatched','failed','cancelled')) or (old.command_status='dispatched' and new.command_status in ('dispatched','completed','failed','ambiguous','cancelled')) or (old.command_status in ('failed','ambiguous') and new.command_status in (old.command_status,'dispatched','cancelled'))) then raise exception 'ACCOUNT_ERASURE_EXTERNAL_COMMAND_TRANSITION_INVALID'; end if;
  return new;
end;$f$;
drop trigger if exists trg_guard_account_erasure_external_command on public.account_erasure_external_commands;
create trigger trg_guard_account_erasure_external_command before update or delete on public.account_erasure_external_commands for each row execute function public.guard_account_erasure_external_command_transition();

create or replace function public.guard_account_erasure_external_attempt()
returns trigger language plpgsql security definer set search_path=public,pg_catalog as $f$
begin
  if tg_op='DELETE' then raise exception 'ACCOUNT_ERASURE_EXTERNAL_ATTEMPT_DELETE_FORBIDDEN'; end if;
  if old.attempt_status<>'started' then raise exception 'ACCOUNT_ERASURE_EXTERNAL_ATTEMPT_TERMINAL'; end if;
  if new.command_id<>old.command_id or new.attempt_number<>old.attempt_number then raise exception 'ACCOUNT_ERASURE_EXTERNAL_ATTEMPT_IDENTITY_IMMUTABLE'; end if;
  if new.attempt_status not in ('started','succeeded','failed','ambiguous') then raise exception 'ACCOUNT_ERASURE_EXTERNAL_ATTEMPT_TRANSITION_INVALID'; end if;
  return new;
end;$f$;
drop trigger if exists trg_guard_account_erasure_external_attempt on public.account_erasure_external_attempts;
create trigger trg_guard_account_erasure_external_attempt before update or delete on public.account_erasure_external_attempts for each row execute function public.guard_account_erasure_external_attempt();

create or replace function public.protect_account_erasure_external_receipt_immutable()
returns trigger language plpgsql security definer set search_path=public,pg_catalog as $f$
begin raise exception 'ACCOUNT_ERASURE_EXTERNAL_RECEIPT_IMMUTABLE'; end;$f$;
drop trigger if exists trg_protect_account_erasure_external_receipt on public.account_erasure_external_receipts;
create trigger trg_protect_account_erasure_external_receipt before update or delete on public.account_erasure_external_receipts for each row execute function public.protect_account_erasure_external_receipt_immutable();

-- --------------------------------------------------------------------------
-- 4. Command preparation and lease contract
-- --------------------------------------------------------------------------
create or replace function public.prepare_account_erasure_external_command_internal(p_erasure_step_id uuid,p_worker_id text,p_correlation_id uuid)
returns jsonb language plpgsql security definer set search_path=public,extensions,pg_catalog as $f$
declare v_context jsonb; v_step_code text; v_type text; v_provider text; v_operation text; v_payload jsonb; v_target text; v_request text; v_idem text; v_command public.account_erasure_external_commands%rowtype; v_user uuid;
begin
  v_context:=public.get_account_erasure_handler_context_internal(p_erasure_step_id);
  perform public.assert_account_finalization_enabled_internal(v_context,case v_context->>'step_code' when 'DELETE_STORAGE_ASSETS' then 'storage_deletion_enabled' when 'DELETE_SUPABASE_AUTH_IDENTITY' then 'auth_deletion_enabled' else null end);
  v_step_code:=v_context->>'step_code'; v_user:=nullif(v_context->>'auth_user_id','')::uuid;
  if v_step_code='DELETE_STORAGE_ASSETS' then
    v_type:='DELETE_STORAGE_ASSETS'; v_provider:='supabase_storage'; v_operation:='storage.remove';
    v_payload:=jsonb_build_object('bucket_code','club-avatars','auth_user_id',v_user,'normalized_paths','[]'::jsonb,'candidate_count',0,'requires_residual_scan',true);
  elsif v_step_code='DELETE_SUPABASE_AUTH_IDENTITY' then
    if not exists(select 1 from public.account_erasure_steps where erasure_run_id=(v_context->>'erasure_run_id')::uuid and step_code='VERIFY_PRE_AUTH_DELETION_INVARIANTS' and step_status='completed') then raise exception 'ACCOUNT_ERASURE_PRE_AUTH_CERTIFICATION_REQUIRED'; end if;
    v_type:='DELETE_SUPABASE_AUTH_IDENTITY'; v_provider:='supabase_auth'; v_operation:='admin.deleteUser'; v_payload:=jsonb_build_object('auth_user_id',v_user,'hard_delete',true);
  else raise exception 'ACCOUNT_ERASURE_EXTERNAL_STEP_REQUIRED'; end if;
  v_target:=encode(extensions.digest(convert_to(v_payload::text,'UTF8'),'sha256'),'hex');
  v_idem:=format('account-erasure:%s:%s',p_erasure_step_id,v_target);
  v_request:=encode(extensions.digest(convert_to(jsonb_build_object('type',v_type,'target',v_target,'version',1)::text,'UTF8'),'sha256'),'hex');
  insert into public.account_erasure_external_commands(account_lifecycle_id,erasure_run_id,erasure_step_id,command_type,provider_code,provider_operation,idempotency_key,target_digest,request_digest,restricted_payload,public_metadata)
  values((v_context->>'account_lifecycle_id')::uuid,(v_context->>'erasure_run_id')::uuid,p_erasure_step_id,v_type,v_provider,v_operation,v_idem,v_target,v_request,v_payload,jsonb_build_object('correlation_id',p_correlation_id,'prepared_by',p_worker_id,'contract_version','1.0.0'))
  on conflict(erasure_step_id) do nothing;
  select * into v_command from public.account_erasure_external_commands where erasure_step_id=p_erasure_step_id;
  if v_command.target_digest<>v_target then raise exception 'ACCOUNT_ERASURE_EXTERNAL_COMMAND_TARGET_MISMATCH'; end if;
  return jsonb_build_object('command_id',v_command.id,'command_type',v_command.command_type,'command_status',v_command.command_status,'provider_code',v_command.provider_code,'provider_operation',v_command.provider_operation,'request_digest',v_command.request_digest,'idempotency_key',v_command.idempotency_key,'restricted_payload',v_command.restricted_payload);
end;$f$;

create or replace function
public.claim_account_erasure_external_command_internal(
  p_command_id uuid,
  p_worker_id text,
  p_correlation_id uuid,
  p_lease_interval interval default interval '2 minutes'
)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions, pg_catalog
as $function$
declare
  v_command public.account_erasure_external_commands%rowtype;
  v_attempt public.account_erasure_external_attempts%rowtype;
  v_token uuid := extensions.gen_random_uuid();
begin
  if p_lease_interval <= interval '0 seconds'
     or p_lease_interval > interval '15 minutes'
  then
    raise exception 'ACCOUNT_ERASURE_EXTERNAL_LEASE_INVALID';
  end if;

  update public.account_erasure_external_commands
  set
    command_status = 'dispatched',
    dispatched_at = clock_timestamp(),
    failed_at = null,
    completed_at = null,
    last_error_code = null,
    last_error_message = null,
    attempt_count = attempt_count + 1,
    lease_owner = p_worker_id,
    lease_token = v_token,
    leased_at = clock_timestamp(),
    lease_expires_at =
      clock_timestamp() + p_lease_interval,
    version = version + 1,
    updated_at = clock_timestamp()
  where id = p_command_id
    and command_status in (
      'prepared',
      'failed',
      'ambiguous'
    )
    and (
      lease_expires_at is null
      or lease_expires_at <= clock_timestamp()
    )
  returning * into v_command;

  if not found then
    raise exception
      'ACCOUNT_ERASURE_EXTERNAL_COMMAND_NOT_CLAIMABLE';
  end if;

  insert into public.account_erasure_external_attempts (
    command_id,
    attempt_number,
    worker_id,
    correlation_id,
    request_digest
  )
  values (
    v_command.id,
    v_command.attempt_count,
    p_worker_id,
    p_correlation_id,
    v_command.request_digest
  )
  returning * into v_attempt;

  return jsonb_build_object(
    'command_id', v_command.id,
    'attempt_id', v_attempt.id,
    'attempt_number', v_attempt.attempt_number,
    'lease_token', v_token,
    'lease_expires_at', v_command.lease_expires_at,
    'command_type', v_command.command_type,
    'provider_code', v_command.provider_code,
    'provider_operation', v_command.provider_operation,
    'request_digest', v_command.request_digest,
    'idempotency_key', v_command.idempotency_key,
    'restricted_payload', v_command.restricted_payload
  );
end;
$function$;

revoke all on function
  public.handle_account_erasure_090_competitive_internal(uuid)
from public, anon, authenticated;

grant execute on function
  public.handle_account_erasure_090_competitive_internal(uuid)
to service_role;


create or replace function public.assert_account_finalization_enabled_internal(
  p_context jsonb,
  p_required_flag text default null
)
returns void
language plpgsql
security definer
stable
set search_path = public, pg_catalog
as $function$
declare
  v_policy_config jsonb := coalesce(p_context -> 'policy_config', '{}'::jsonb);
begin
  perform public.assert_account_domain_handler_enabled_internal(
    p_context,
    null
  );

  if not coalesce(
    (v_policy_config ->> 'finalization_handlers_enabled')::boolean,
    false
  ) then
    raise exception using
      errcode = '55000',
      message = 'ACCOUNT_DELETION_FINALIZATION_HANDLERS_DISABLED';
  end if;

  if p_required_flag is not null
     and not coalesce(
       (v_policy_config ->> p_required_flag)::boolean,
       false
     ) then
    raise exception using
      errcode = '55000',
      message = 'ACCOUNT_DELETION_REQUIRED_FEATURE_DISABLED',
      detail = p_required_flag;
  end if;
end;
$function$;

revoke all on function
  public.assert_account_finalization_enabled_internal(jsonb, text)
from public, anon, authenticated;

grant execute on function
  public.assert_account_finalization_enabled_internal(jsonb, text)
to service_role;


create or replace function public.get_account_erasure_execution_bundle_internal(
  p_account_lifecycle_id uuid
)
returns jsonb
language plpgsql
security definer
stable
set search_path = public, pg_catalog
as $function$
declare
  v_lifecycle public.account_lifecycle%rowtype;
  v_run public.account_erasure_runs%rowtype;
  v_policy public.account_lifecycle_policies%rowtype;
  v_steps jsonb;
  v_storage_paths jsonb;
begin
  select l.*
    into v_lifecycle
  from public.account_lifecycle l
  where l.id = p_account_lifecycle_id;

  if not found then
    raise exception using
      errcode = 'P0002',
      message = 'ACCOUNT_LIFECYCLE_NOT_FOUND';
  end if;

  select r.*
    into v_run
  from public.account_erasure_runs r
  where r.id = v_lifecycle.active_erasure_run_id;

  select p.*
    into v_policy
  from public.account_lifecycle_policies p
  where p.id = v_lifecycle.policy_id;

  select jsonb_agg(
    jsonb_build_object(
      'id', s.id,
      'step_order', s.step_order,
      'step_code', s.step_code,
      'step_status', s.step_status
    )
    order by s.step_order
  )
  into v_steps
  from public.account_erasure_steps s
  where s.erasure_run_id = v_run.id;

  select coalesce(
    jsonb_agg(distinct x.path) filter (where x.path is not null),
    '[]'::jsonb
  )
  into v_storage_paths
  from (
    select p.avatar_url as path
    from public.profiles p
    where p.id = v_lifecycle.auth_user_id

    union all

    select c.crest_url
    from public.clubs c
    where c.crest_url is not null
      and (
        c.crest_url like '%' || coalesce(v_lifecycle.auth_user_id::text, '') || '%'
        or c.name like 'Utente eliminato %'
      )
  ) x;

  return jsonb_build_object(
    'account_lifecycle_id', v_lifecycle.id,
    'auth_user_id', v_lifecycle.auth_user_id,
    'subject_token', v_lifecycle.subject_token,
    'retention_subject_id', v_lifecycle.retention_subject_id,
    'lifecycle_status', v_lifecycle.lifecycle_status,
    'erasure_run_id', v_run.id,
    'run_status', v_run.run_status,
    'policy_config', v_policy.policy_config,
    'automatic_execution_enabled', v_policy.automatic_execution_enabled,
    'storage_bucket', 'club-avatars',
    'storage_paths', v_storage_paths,
    'steps', coalesce(v_steps, '[]'::jsonb)
  );
end;
$function$;

revoke all on function
  public.get_account_erasure_execution_bundle_internal(uuid)
from public, anon, authenticated;

grant execute on function
  public.get_account_erasure_execution_bundle_internal(uuid)
to service_role;


create or replace function public.complete_account_erasure_external_step_internal(
  p_erasure_step_id uuid,
  p_expected_step_code text,
  p_affected_row_count bigint,
  p_affected_object_count bigint,
  p_evidence_summary jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_catalog
as $function$
declare
  v_context jsonb;
  v_step_code text;
  v_required_flag text;
begin
  v_context :=
    public.get_account_erasure_handler_context_internal(p_erasure_step_id);

  v_step_code := v_context ->> 'step_code';

  if v_step_code <> p_expected_step_code then
    raise exception using
      errcode = '22023',
      message = 'ACCOUNT_ERASURE_STEP_CODE_MISMATCH';
  end if;

  v_required_flag :=
    case v_step_code
      when 'DELETE_STORAGE_ASSETS' then 'storage_deletion_enabled'
      when 'DELETE_SUPABASE_AUTH_IDENTITY' then 'auth_deletion_enabled'
      else null
    end;

  if v_required_flag is null then
    raise exception using
      errcode = '0A000',
      message = 'ACCOUNT_ERASURE_EXTERNAL_STEP_UNSUPPORTED';
  end if;

  perform public.assert_account_finalization_enabled_internal(
    v_context,
    v_required_flag
  );

  return public.complete_account_erasure_step_internal(
    p_erasure_step_id,
    p_affected_row_count,
    p_affected_object_count,
    coalesce(p_evidence_summary, '{}'::jsonb)
      || jsonb_build_object(
        'external_boundary', true,
        'handler_version', '1.0.0'
      )
  );
end;
$function$;

revoke all on function
  public.complete_account_erasure_external_step_internal(
    uuid, text, bigint, bigint, jsonb
  )
from public, anon, authenticated;

grant execute on function
  public.complete_account_erasure_external_step_internal(
    uuid, text, bigint, bigint, jsonb
  )
to service_role;


create or replace function public.handle_account_erasure_130_profile_internal(
  p_erasure_step_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_catalog
as $function$
declare
  v_context jsonb;
  v_user_id uuid;
  v_rows bigint := 0;
  v_current bigint;
begin
  v_context :=
    public.get_account_erasure_handler_context_internal(p_erasure_step_id);

  perform public.assert_account_finalization_enabled_internal(
    v_context,
    'profile_deletion_enabled'
  );

  if v_context ->> 'step_code' <> 'DELETE_PROFILE_PERSONAL_DATA' then
    raise exception 'ACCOUNT_ERASURE_STEP_CODE_MISMATCH';
  end if;

  v_user_id := (v_context ->> 'auth_user_id')::uuid;

  delete from public.profiles p
  where p.id = v_user_id;
  get diagnostics v_current = row_count;
  v_rows := v_rows + v_current;

  update public.clubs c
  set
    crest_url = null,
    motto = null,
    real_name = null
  where c.crest_url is not null
    and (
      c.crest_url like '%' || v_user_id::text || '%'
      or c.name like 'Utente eliminato %'
    );
  get diagnostics v_current = row_count;
  v_rows := v_rows + v_current;

  return public.complete_account_erasure_step_internal(
    p_erasure_step_id,
    v_rows,
    2,
    jsonb_build_object(
      'profile_deleted', true,
      'club_personal_asset_references_cleared', true,
      'handler_version', '1.0.0'
    )
  );
end;
$function$;


create or replace function public.handle_account_erasure_140_pre_auth_internal(
  p_erasure_step_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_catalog
as $function$
declare
  v_context jsonb;
  v_user_id uuid;
  v_blockers jsonb := '[]'::jsonb;
  v_count bigint;
begin
  v_context :=
    public.get_account_erasure_handler_context_internal(p_erasure_step_id);

  perform public.assert_account_finalization_enabled_internal(
    v_context,
    'pre_auth_certification_enabled'
  );

  if v_context ->> 'step_code'
     <> 'VERIFY_PRE_AUTH_DELETION_INVARIANTS' then
    raise exception 'ACCOUNT_ERASURE_STEP_CODE_MISMATCH';
  end if;

  v_user_id := (v_context ->> 'auth_user_id')::uuid;

  select count(*) into v_count
  from public.account_erasure_steps s
  where s.erasure_run_id = (v_context ->> 'erasure_run_id')::uuid
    and s.step_order < 140
    and s.mandatory
    and s.step_status <> 'completed';

  if v_count > 0 then
    v_blockers := v_blockers || jsonb_build_array(
      jsonb_build_object('code','PRIOR_MANDATORY_STEPS_INCOMPLETE','count',v_count)
    );
  end if;

  select count(*) into v_count from public.profiles where id = v_user_id;
  if v_count > 0 then
    v_blockers := v_blockers || jsonb_build_array(
      jsonb_build_object('code','PROFILE_REMAINS','count',v_count)
    );
  end if;

  select count(*) into v_count
  from public.leagues where owner_id = v_user_id;
  if v_count > 0 then
    v_blockers := v_blockers || jsonb_build_array(
      jsonb_build_object('code','LEAGUE_OWNER_REFERENCE_REMAINS','count',v_count)
    );
  end if;

  select count(*) into v_count
  from public.league_members
  where user_id = v_user_id
     or (
       status = 'active'
       and role in ('admin','vice')
       and display_name like 'Utente eliminato %'
     );
  if v_count > 0 then
    v_blockers := v_blockers || jsonb_build_array(
      jsonb_build_object('code','MEMBERSHIP_AUTH_OR_GOVERNANCE_REMAINS','count',v_count)
    );
  end if;

  select
      (select count(*) from public.predictions where user_id = v_user_id)
    + (select count(*) from public.strategies where user_id = v_user_id)
    + (select count(*) from public.commercial_wallets where user_id = v_user_id)
    + (select count(*) from public.commercial_ledger where user_id = v_user_id)
    + (select count(*) from public.commercial_purchases where user_id = v_user_id)
    + (select count(*) from public.premium_access_sessions where user_id = v_user_id)
  into v_count;

  if v_count > 0 then
    v_blockers := v_blockers || jsonb_build_array(
      jsonb_build_object('code','DOMAIN_AUTH_REFERENCES_REMAIN','count',v_count)
    );
  end if;

  if jsonb_array_length(v_blockers) > 0 then
    return public.block_account_erasure_step_internal(
      p_erasure_step_id,
      'PRE_AUTH_INVARIANTS_FAILED',
      jsonb_build_object('blockers', v_blockers)
    );
  end if;

  return public.complete_account_erasure_step_internal(
    p_erasure_step_id,
    0,
    5,
    jsonb_build_object(
      'pre_auth_invariants_valid', true,
      'handler_version', '1.0.0'
    )
  );
end;
$function$;


create or replace function
public.handle_account_erasure_160_post_auth_internal(
  p_erasure_step_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_catalog
as $function$
declare
  v_context jsonb;
  v_lifecycle_id uuid;
  v_erasure_run_id uuid;
  v_original_user_id uuid;
  v_auth_count bigint;
  v_profile_count bigint;
  v_receipt_count bigint;
begin
  v_context :=
    public.get_account_erasure_handler_context_internal(
      p_erasure_step_id
    );

  perform public.assert_account_finalization_enabled_internal(
    v_context,
    'post_auth_certification_enabled'
  );

  if v_context ->> 'step_code'
     <> 'VERIFY_POST_AUTH_DELETION_INVARIANTS'
  then
    raise exception 'ACCOUNT_ERASURE_STEP_CODE_MISMATCH';
  end if;

  v_lifecycle_id :=
    (v_context ->> 'account_lifecycle_id')::uuid;

  v_erasure_run_id :=
    (v_context ->> 'erasure_run_id')::uuid;

  select
    nullif(
      r.restricted_evidence ->> 'deleted_auth_user_id',
      ''
    )::uuid,
    count(*) over ()
  into
    v_original_user_id,
    v_receipt_count
  from public.account_erasure_external_receipts r
  join public.account_erasure_external_commands c
    on c.id = r.command_id
  where c.erasure_run_id = v_erasure_run_id
    and c.command_type =
      'DELETE_SUPABASE_AUTH_IDENTITY'
    and c.command_status = 'completed'
    and r.receipt_type = 'AUTH_DELETION'
    and r.receipt_status in (
      'verified_success',
      'verified_already_absent'
    )
    and coalesce(
      (
        r.public_evidence
        ->> 'verified_absent'
      )::boolean,
      false
    )
  order by r.created_at desc
  limit 1;

  if v_original_user_id is null then
    select nullif(
      c.restricted_payload ->> 'auth_user_id',
      ''
    )::uuid
    into v_original_user_id
    from public.account_erasure_external_commands c
    where c.erasure_run_id = v_erasure_run_id
      and c.command_type =
        'DELETE_SUPABASE_AUTH_IDENTITY'
      and c.command_status = 'completed'
    order by c.completed_at desc nulls last
    limit 1;
  end if;

  select count(*)
    into v_auth_count
  from auth.users u
  where u.id = v_original_user_id;

  select count(*)
    into v_profile_count
  from public.profiles p
  where p.id = v_original_user_id;

  if v_original_user_id is null
     or coalesce(v_receipt_count, 0) <> 1
     or v_auth_count <> 0
     or v_profile_count <> 0
  then
    return public.block_account_erasure_step_internal(
      p_erasure_step_id,
      'POST_AUTH_INVARIANTS_FAILED',
      jsonb_build_object(
        'auth_user_count', v_auth_count,
        'profile_count', v_profile_count,
        'verified_auth_receipt_count',
          coalesce(v_receipt_count, 0),
        'deleted_auth_user_id_evidence_present',
          v_original_user_id is not null
      )
    );
  end if;

  update public.account_lifecycle l
  set
    auth_deleted_at =
      coalesce(
        l.auth_deleted_at,
        clock_timestamp()
      ),
    version = l.version + 1,
    updated_at = clock_timestamp()
  where l.id = v_lifecycle_id;

  return public.complete_account_erasure_step_internal(
    p_erasure_step_id,
    0,
    3,
    jsonb_build_object(
      'auth_identity_absent', true,
      'profile_absent', true,
      'verified_auth_receipt_present', true,
      'deleted_auth_user_id_digest',
        encode(
          extensions.digest(
            convert_to(
              v_original_user_id::text,
              'UTF8'
            ),
            'sha256'
          ),
          'hex'
        ),
      'handler_version', '1.0.1'
    )
  );
end;
$function$;


create or replace function public.handle_account_erasure_170_audit_internal(
  p_erasure_step_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_catalog
as $function$
declare
  v_context jsonb;
  v_audit_id uuid;
  v_digest text;
begin
  v_context :=
    public.get_account_erasure_handler_context_internal(p_erasure_step_id);

  perform public.assert_account_finalization_enabled_internal(
    v_context,
    'final_audit_enabled'
  );

  if v_context ->> 'step_code'
     <> 'WRITE_FINAL_NON_IDENTIFYING_AUDIT' then
    raise exception 'ACCOUNT_ERASURE_STEP_CODE_MISMATCH';
  end if;

  select encode(
    extensions.digest(
      convert_to(
        jsonb_build_object(
          'subject_token', (
            select l.subject_token
            from public.account_lifecycle l
            where l.id =
              (v_context ->> 'account_lifecycle_id')::uuid
          ),
          'erasure_run_id', v_context ->> 'erasure_run_id',
          'result', 'ACCOUNT_DELETED'
        )::text,
        'UTF8'
      ),
      'sha256'
    ),
    'hex'
  )
  into v_digest;

  v_audit_id :=
    public.append_account_deletion_audit_internal(
      (v_context ->> 'account_lifecycle_id')::uuid,
      (v_context ->> 'erasure_run_id')::uuid,
      'ACCOUNT_DELETED',
      'completed',
      'WRITE_FINAL_NON_IDENTIFYING_AUDIT',
      0,
      1,
      v_digest,
      null,
      null,
      null,
      null,
      jsonb_build_object(
        'non_identifying', true,
        'contract', 'account-deletion-final-audit-v1'
      )
    );

  return public.complete_account_erasure_step_internal(
    p_erasure_step_id,
    1,
    1,
    jsonb_build_object(
      'audit_id', v_audit_id,
      'audit_event_code', 'ACCOUNT_DELETED',
      'handler_version', '1.0.0'
    )
  );
end;
$function$;


create or replace function public.handle_account_erasure_180_certify_internal(
  p_erasure_step_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_catalog
as $function$
declare
  v_context jsonb;
  v_run_id uuid;
  v_lifecycle_id uuid;
  v_request_id uuid;
  v_incomplete bigint;
  v_audit_count bigint;
  v_result jsonb;
begin
  v_context :=
    public.get_account_erasure_handler_context_internal(p_erasure_step_id);

  perform public.assert_account_finalization_enabled_internal(
    v_context,
    'terminal_certification_enabled'
  );

  if v_context ->> 'step_code' <> 'CERTIFY_ACCOUNT_DELETION' then
    raise exception 'ACCOUNT_ERASURE_STEP_CODE_MISMATCH';
  end if;

  v_run_id := (v_context ->> 'erasure_run_id')::uuid;
  v_lifecycle_id := (v_context ->> 'account_lifecycle_id')::uuid;

  select r.deletion_request_id
    into v_request_id
  from public.account_erasure_runs r
  where r.id = v_run_id;

  select count(*) into v_incomplete
  from public.account_erasure_steps s
  where s.erasure_run_id = v_run_id
    and s.mandatory
    and s.id <> p_erasure_step_id
    and s.step_status <> 'completed';

  select count(*) into v_audit_count
  from public.account_deletion_audit a
  where a.account_lifecycle_id = v_lifecycle_id
    and a.erasure_run_id = v_run_id
    and a.event_code = 'ACCOUNT_DELETED'
    and a.event_result = 'completed';

  if v_incomplete > 0 or v_audit_count = 0 then
    return public.block_account_erasure_step_internal(
      p_erasure_step_id,
      'FINAL_CERTIFICATION_INVARIANTS_FAILED',
      jsonb_build_object(
        'incomplete_mandatory_step_count', v_incomplete,
        'final_audit_count', v_audit_count
      )
    );
  end if;

  v_result := public.complete_account_erasure_step_internal(
    p_erasure_step_id,
    0,
    1,
    jsonb_build_object(
      'certified', true,
      'handler_version', '1.0.0'
    )
  );

  update public.account_deletion_requests d
  set
    request_status = 'completed',
    updated_at = clock_timestamp()
  where d.id = v_request_id;

  update public.account_erasure_runs r
  set
    run_status = 'completed',
    completed_at = coalesce(r.completed_at, clock_timestamp()),
    lease_owner = null,
    lease_token = null,
    leased_at = null,
    lease_expires_at = null,
    version = r.version + 1,
    updated_at = clock_timestamp()
  where r.id = v_run_id;

  update public.account_lifecycle l
  set
    lifecycle_status = 'deleted',
    auth_user_id = null,
    auth_deleted_at = coalesce(l.auth_deleted_at, clock_timestamp()),
    completed_at = coalesce(l.completed_at, clock_timestamp()),
    blocker_code = null,
    failure_code = null,
    failure_message = null,
    version = l.version + 1,
    updated_at = clock_timestamp()
  where l.id = v_lifecycle_id;

  return v_result || jsonb_build_object(
    'lifecycle_status', 'deleted',
    'run_status', 'completed',
    'request_status', 'completed'
  );
end;
$function$;


create or replace function public.execute_account_erasure_finalization_step_internal(
  p_erasure_step_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_catalog
as $function$
declare
  v_step_code text;
begin
  select s.step_code into v_step_code
  from public.account_erasure_steps s
  where s.id = p_erasure_step_id;

  if not found then
    raise exception using
      errcode = 'P0002',
      message = 'ACCOUNT_ERASURE_STEP_NOT_FOUND';
  end if;

  case v_step_code
    when 'DELETE_PROFILE_PERSONAL_DATA' then
      return public.handle_account_erasure_130_profile_internal(
        p_erasure_step_id
      );
    when 'VERIFY_PRE_AUTH_DELETION_INVARIANTS' then
      return public.handle_account_erasure_140_pre_auth_internal(
        p_erasure_step_id
      );
    when 'VERIFY_POST_AUTH_DELETION_INVARIANTS' then
      return public.handle_account_erasure_160_post_auth_internal(
        p_erasure_step_id
      );
    when 'WRITE_FINAL_NON_IDENTIFYING_AUDIT' then
      return public.handle_account_erasure_170_audit_internal(
        p_erasure_step_id
      );
    when 'CERTIFY_ACCOUNT_DELETION' then
      return public.handle_account_erasure_180_certify_internal(
        p_erasure_step_id
      );
    else
      raise exception using
        errcode = '0A000',
        message = 'ACCOUNT_ERASURE_FINALIZATION_STEP_UNSUPPORTED',
        detail = v_step_code;
  end case;
end;
$function$;


do $grants$
declare
  v_signature text;
begin
  foreach v_signature in array array[
    'public.handle_account_erasure_130_profile_internal(uuid)',
    'public.handle_account_erasure_140_pre_auth_internal(uuid)',
    'public.handle_account_erasure_160_post_auth_internal(uuid)',
    'public.handle_account_erasure_170_audit_internal(uuid)',
    'public.handle_account_erasure_180_certify_internal(uuid)',
    'public.execute_account_erasure_finalization_step_internal(uuid)'
  ]
  loop
    execute format(
      'revoke all on function %s from public, anon, authenticated',
      v_signature
    );
    execute format(
      'grant execute on function %s to service_role',
      v_signature
    );
  end loop;
end;
$grants$;



-- --------------------------------------------------------------------------
-- 8. Grants for all new functions
-- --------------------------------------------------------------------------
do $grants$
declare v_sig text;
begin
  foreach v_sig in array array[
    'public.guard_account_erasure_external_command_transition()',
    'public.guard_account_erasure_external_attempt()',
    'public.protect_account_erasure_external_receipt_immutable()',
    'public.prepare_account_erasure_external_command_internal(uuid,text,uuid)',
    'public.claim_account_erasure_external_command_internal(uuid,text,uuid,interval)',
    'public.heartbeat_account_erasure_external_command_internal(uuid,text,uuid,interval)',
    'public.record_account_erasure_external_receipt_internal(uuid,uuid,text,uuid,text,text,text,jsonb,jsonb,bigint,bigint)'
  ] loop
    execute format('revoke all on function %s from public,anon,authenticated',v_sig);
    execute format('grant execute on function %s to service_role',v_sig);
  end loop;
end;$grants$;

-- --------------------------------------------------------------------------
-- 9. Dormant metadata: installation is not activation
-- --------------------------------------------------------------------------
update public.account_lifecycle_policies
set policy_config=policy_config||jsonb_build_object(
  'finalization_handlers_installed',true,
  'finalization_handlers_version','1.0.0',
  'finalization_handlers_enabled',false,
  'server_orchestrator_installed',true,
  'server_orchestrator_version','1.0.0',
  'server_orchestrator_enabled',false,
  'storage_registry_installed',true,
  'storage_deletion_enabled',false,
  'profile_deletion_enabled',false,
  'pre_auth_certification_enabled',false,
  'auth_deletion_enabled',false,
  'post_auth_certification_enabled',false,
  'final_audit_enabled',false,
  'terminal_certification_enabled',false,
  'external_command_execution_enabled',false,
  'external_receipt_acceptance_enabled',false,
  'runtime_launch_enabled',false
),updated_at=clock_timestamp()
where policy_code='ACCOUNT_DELETION_STANDARD' and policy_version=1;

update public.platform_engine_registry
set runtime_enabled=false,is_certified=false,metadata=metadata||jsonb_build_object(
  'finalization_database_foundation','installed',
  'finalization_database_version','1.0.0',
  'finalization_schema_migration',175,
  'server_execution_contract_version','1.0.0',
  'installed_step_range','010-180',
  'destructive_handlers_installed',true,
  'runtime_launch_enabled',false
),updated_at=now()
where engine_code='account_lifecycle_engine';

update public.platform_configuration
set schema_version=greatest(schema_version,175),metadata=metadata||jsonb_build_object(
  'account_lifecycle_finalization_foundation','1.0.0',
  'account_lifecycle_finalization_migration',175,
  'account_lifecycle_server_execution_contract','1.0.0',
  'account_lifecycle_finalization_enabled',false
),updated_at=now()
where configuration_key='primary';

-- --------------------------------------------------------------------------
-- 10. Safety assertions
-- --------------------------------------------------------------------------
do $assert$
declare v_policy public.account_lifecycle_policies%rowtype; v_engine public.platform_engine_registry%rowtype;
begin
  select * into v_policy from public.account_lifecycle_policies where policy_code='ACCOUNT_DELETION_STANDARD' and policy_version=1;
  select * into v_engine from public.platform_engine_registry where engine_code='account_lifecycle_engine';
  if v_policy.automatic_execution_enabled or v_engine.runtime_enabled or v_engine.is_certified then raise exception 'ACCOUNT_FINALIZATION_SAFETY_ASSERTION_FAILED'; end if;
  if coalesce((v_policy.policy_config->>'finalization_handlers_enabled')::boolean,true)
     or coalesce((v_policy.policy_config->>'server_orchestrator_enabled')::boolean,true)
     or coalesce((v_policy.policy_config->>'storage_deletion_enabled')::boolean,true)
     or coalesce((v_policy.policy_config->>'profile_deletion_enabled')::boolean,true)
     or coalesce((v_policy.policy_config->>'auth_deletion_enabled')::boolean,true)
     or coalesce((v_policy.policy_config->>'terminal_certification_enabled')::boolean,true)
     or coalesce((v_policy.policy_config->>'external_command_execution_enabled')::boolean,true)
     or coalesce((v_policy.policy_config->>'external_receipt_acceptance_enabled')::boolean,true) then raise exception 'ACCOUNT_FINALIZATION_DESTRUCTIVE_FLAG_ENABLED'; end if;
  if exists(select 1 from public.account_erasure_storage_registry where bucket_code='club-avatars' and registry_version=1 and active) then raise exception 'ACCOUNT_FINALIZATION_STORAGE_REGISTRY_ACTIVE'; end if;
  if exists(select 1 from public.account_erasure_external_commands) or exists(select 1 from public.account_erasure_external_attempts) or exists(select 1 from public.account_erasure_external_receipts) then raise exception 'ACCOUNT_FINALIZATION_INSTALL_CREATED_OPERATIONAL_DATA'; end if;
end;$assert$;

commit;
