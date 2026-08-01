-- ============================================================================
-- FANTAGOL
-- Migration 174 v3: Account Deletion Domain Handlers
-- Phase 13.7.4
--
-- Purpose
--   Install the executable domain handlers for Account Deletion workflow
--   steps 10-110. The handlers are service-only and remain disabled until
--   explicit certification/activation flags are enabled.
--
-- Installed handlers
--   010 ACQUIRE_ACCOUNT_LIFECYCLE_LEASE
--   020 FREEZE_ACCOUNT_MUTATIONS
--   030 EVALUATE_ERASURE_READINESS
--   040 RESOLVE_LEAGUE_GOVERNANCE
--   050 REVOKE_ACTIVE_COMMERCIAL_ACCESS
--   060 CLOSE_COMMERCIAL_WALLET
--   070 CREATE_OR_RESOLVE_RETENTION_SUBJECT
--   080 PSEUDONYMIZE_COMMERCIAL_AND_LOYALTY_DOMAINS
--   090 ANONYMIZE_COMPETITIVE_IDENTITY
--   100 DETACH_LEGACY_AUTH_REFERENCES
--   110 SCRUB_JSONB_PERSONAL_IDENTIFIERS
--
-- Safety
--   - migration performs no erasure;
--   - no scheduled lifecycle/run/step is advanced;
--   - runtime, worker and domain handler flags remain false;
--   - storage/profile/Auth handlers remain uninstalled and disabled.
-- ============================================================================

begin;

-- --------------------------------------------------------------------------
-- 0. League governance terminal bridge
-- --------------------------------------------------------------------------

-- Account erasure must never be blocked indefinitely because a League has no
-- eligible successor. The existing archived lifecycle is the canonical
-- read-only terminal state, so owner_id must be detachable from Auth.
alter table public.leagues
  alter column owner_id drop not null;

alter table public.leagues
  drop constraint if exists leagues_owner_id_fkey;

alter table public.leagues
  add constraint leagues_owner_id_fkey
  foreign key (owner_id)
  references auth.users(id)
  on delete set null;

-- --------------------------------------------------------------------------
-- 1. Shared handler context and evidence helpers
-- --------------------------------------------------------------------------

create or replace function public.get_account_erasure_handler_context_internal(
  p_erasure_step_id uuid
)
returns jsonb
language plpgsql
security definer
stable
set search_path = public, pg_catalog
as $function$
declare
  v_step public.account_erasure_steps%rowtype;
  v_run public.account_erasure_runs%rowtype;
  v_lifecycle public.account_lifecycle%rowtype;
  v_request public.account_deletion_requests%rowtype;
  v_policy public.account_lifecycle_policies%rowtype;
begin
  select s.*
    into v_step
  from public.account_erasure_steps s
  where s.id = p_erasure_step_id;

  if not found then
    raise exception using
      errcode = 'P0002',
      message = 'ACCOUNT_ERASURE_STEP_NOT_FOUND';
  end if;

  select r.*
    into v_run
  from public.account_erasure_runs r
  where r.id = v_step.erasure_run_id;

  select l.*
    into v_lifecycle
  from public.account_lifecycle l
  where l.id = v_run.account_lifecycle_id;

  select d.*
    into v_request
  from public.account_deletion_requests d
  where d.id = v_run.deletion_request_id;

  select p.*
    into v_policy
  from public.account_lifecycle_policies p
  where p.id = v_run.policy_id;

  return jsonb_build_object(
    'step_id', v_step.id,
    'step_code', v_step.step_code,
    'step_status', v_step.step_status,
    'erasure_run_id', v_run.id,
    'run_status', v_run.run_status,
    'account_lifecycle_id', v_lifecycle.id,
    'auth_user_id', v_lifecycle.auth_user_id,
    'retention_subject_id', v_lifecycle.retention_subject_id,
    'lifecycle_status', v_lifecycle.lifecycle_status,
    'deletion_request_id', v_request.id,
    'request_status', v_request.request_status,
    'policy_id', v_policy.id,
    'policy_code', v_policy.policy_code,
    'policy_version', v_policy.policy_version,
    'policy_config', v_policy.policy_config,
    'automatic_execution_enabled',
      v_policy.automatic_execution_enabled
  );
end;
$function$;

revoke all on function
  public.get_account_erasure_handler_context_internal(uuid)
from public, anon, authenticated;

grant execute on function
  public.get_account_erasure_handler_context_internal(uuid)
to service_role;


create or replace function public.assert_account_domain_handler_enabled_internal(
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
  if not coalesce(
    (p_context ->> 'automatic_execution_enabled')::boolean,
    false
  ) then
    raise exception using
      errcode = '55000',
      message = 'ACCOUNT_DELETION_AUTOMATIC_EXECUTION_DISABLED';
  end if;

  if not coalesce(
    (v_policy_config ->> 'domain_handlers_enabled')::boolean,
    false
  ) then
    raise exception using
      errcode = '55000',
      message = 'ACCOUNT_DELETION_DOMAIN_HANDLERS_DISABLED';
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
  public.assert_account_domain_handler_enabled_internal(jsonb, text)
from public, anon, authenticated;

grant execute on function
  public.assert_account_domain_handler_enabled_internal(jsonb, text)
to service_role;


create or replace function public.complete_account_erasure_step_internal(
  p_erasure_step_id uuid,
  p_affected_row_count bigint,
  p_affected_object_count bigint,
  p_evidence_summary jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions, pg_catalog
as $function$
declare
  v_step public.account_erasure_steps%rowtype;
  v_summary jsonb := coalesce(p_evidence_summary, '{}'::jsonb);
  v_digest text;
begin
  if jsonb_typeof(v_summary) <> 'object' then
    raise exception using
      errcode = '22023',
      message = 'ACCOUNT_ERASURE_EVIDENCE_OBJECT_REQUIRED';
  end if;

  v_digest := encode(
    extensions.digest(
      convert_to(v_summary::text, 'UTF8'),
      'sha256'
    ),
    'hex'
  );

  update public.account_erasure_steps s
  set
    step_status = 'completed',
    completed_at = coalesce(s.completed_at, clock_timestamp()),
    affected_row_count = greatest(coalesce(p_affected_row_count, 0), 0),
    affected_object_count =
      greatest(coalesce(p_affected_object_count, 0), 0),
    evidence_digest = v_digest,
    evidence_summary = v_summary,
    blocker_code = null,
    error_code = null,
    error_message = null,
    lease_owner = null,
    lease_token = null,
    leased_at = null,
    lease_expires_at = null,
    version = s.version + 1,
    updated_at = clock_timestamp()
  where s.id = p_erasure_step_id
    and s.step_status in ('pending','leased','running','retry_scheduled')
  returning s.* into v_step;

  if not found then
    select s.*
      into v_step
    from public.account_erasure_steps s
    where s.id = p_erasure_step_id;

    if v_step.step_status <> 'completed' then
      raise exception using
        errcode = '55000',
        message = 'ACCOUNT_ERASURE_STEP_NOT_COMPLETABLE';
    end if;
  end if;

  return jsonb_build_object(
    'completed', true,
    'step_id', v_step.id,
    'step_code', v_step.step_code,
    'affected_row_count', v_step.affected_row_count,
    'affected_object_count', v_step.affected_object_count,
    'evidence_digest', v_step.evidence_digest,
    'idempotent_replay', v_step.completed_at is not null
  );
end;
$function$;

revoke all on function
  public.complete_account_erasure_step_internal(uuid, bigint, bigint, jsonb)
from public, anon, authenticated;

grant execute on function
  public.complete_account_erasure_step_internal(uuid, bigint, bigint, jsonb)
to service_role;


create or replace function public.block_account_erasure_step_internal(
  p_erasure_step_id uuid,
  p_blocker_code text,
  p_evidence_summary jsonb default '{}'::jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_catalog
as $function$
declare
  v_step public.account_erasure_steps%rowtype;
  v_run public.account_erasure_runs%rowtype;
  v_lifecycle public.account_lifecycle%rowtype;
  v_code text := upper(nullif(btrim(p_blocker_code), ''));
begin
  if v_code is null then
    raise exception using
      errcode = '22023',
      message = 'ACCOUNT_ERASURE_BLOCKER_CODE_REQUIRED';
  end if;

  update public.account_erasure_steps s
  set
    step_status = 'blocked',
    blocked_at = clock_timestamp(),
    blocker_code = v_code,
    evidence_summary = coalesce(p_evidence_summary, '{}'::jsonb),
    lease_owner = null,
    lease_token = null,
    leased_at = null,
    lease_expires_at = null,
    version = s.version + 1,
    updated_at = clock_timestamp()
  where s.id = p_erasure_step_id
  returning s.* into v_step;

  if not found then
    raise exception using
      errcode = 'P0002',
      message = 'ACCOUNT_ERASURE_STEP_NOT_FOUND';
  end if;

  update public.account_erasure_runs r
  set
    run_status = 'blocked',
    blocked_at = clock_timestamp(),
    blocker_code = v_code,
    version = r.version + 1
  where r.id = v_step.erasure_run_id
  returning r.* into v_run;

  update public.account_lifecycle l
  set
    lifecycle_status = 'erasure_blocked',
    blocker_code = v_code,
    version = l.version + 1,
    updated_at = clock_timestamp()
  where l.id = v_run.account_lifecycle_id
  returning l.* into v_lifecycle;

  return jsonb_build_object(
    'blocked', true,
    'step_id', v_step.id,
    'step_code', v_step.step_code,
    'blocker_code', v_code,
    'erasure_run_id', v_run.id,
    'account_lifecycle_id', v_lifecycle.id
  );
end;
$function$;

revoke all on function
  public.block_account_erasure_step_internal(uuid, text, jsonb)
from public, anon, authenticated;

grant execute on function
  public.block_account_erasure_step_internal(uuid, text, jsonb)
to service_role;

-- --------------------------------------------------------------------------
-- 2. Step 010 - lease evidence
-- --------------------------------------------------------------------------

create or replace function public.handle_account_erasure_010_lease_internal(
  p_erasure_step_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_catalog
as $function$
declare
  v_context jsonb;
begin
  v_context :=
    public.get_account_erasure_handler_context_internal(p_erasure_step_id);

  perform public.assert_account_domain_handler_enabled_internal(
    v_context,
    null
  );

  if v_context ->> 'step_code' <> 'ACQUIRE_ACCOUNT_LIFECYCLE_LEASE' then
    raise exception 'ACCOUNT_ERASURE_STEP_CODE_MISMATCH';
  end if;

  return public.complete_account_erasure_step_internal(
    p_erasure_step_id,
    1,
    1,
    jsonb_build_object(
      'lease_boundary', 'workflow_and_run_lease_validated',
      'erasure_run_id', v_context ->> 'erasure_run_id',
      'handler_version', '1.0.0'
    )
  );
end;
$function$;

-- --------------------------------------------------------------------------
-- 3. Step 020 - mutation freeze
-- --------------------------------------------------------------------------

create or replace function public.handle_account_erasure_020_freeze_internal(
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
  v_rows bigint;
begin
  v_context :=
    public.get_account_erasure_handler_context_internal(p_erasure_step_id);

  perform public.assert_account_domain_handler_enabled_internal(
    v_context,
    null
  );

  if v_context ->> 'step_code' <> 'FREEZE_ACCOUNT_MUTATIONS' then
    raise exception 'ACCOUNT_ERASURE_STEP_CODE_MISMATCH';
  end if;

  v_lifecycle_id :=
    (v_context ->> 'account_lifecycle_id')::uuid;

  update public.account_lifecycle l
  set
    lifecycle_status = 'erasure_running',
    mutation_frozen_at = coalesce(
      l.mutation_frozen_at,
      clock_timestamp()
    ),
    erasure_started_at = coalesce(
      l.erasure_started_at,
      clock_timestamp()
    ),
    version = l.version + 1,
    updated_at = clock_timestamp()
  where l.id = v_lifecycle_id
    and l.lifecycle_status in (
      'deletion_scheduled',
      'erasure_running'
    );

  get diagnostics v_rows = row_count;

  return public.complete_account_erasure_step_internal(
    p_erasure_step_id,
    v_rows,
    1,
    jsonb_build_object(
      'mutation_frozen', true,
      'account_lifecycle_id', v_lifecycle_id,
      'handler_version', '1.0.0'
    )
  );
end;
$function$;

-- --------------------------------------------------------------------------
-- 4. Step 030 - readiness evaluation
-- --------------------------------------------------------------------------

create or replace function public.handle_account_erasure_030_readiness_internal(
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
  v_admin_leagues bigint;
  v_nonterminal_purchases bigint;
  v_auth_exists bigint;
  v_profile_exists bigint;
  v_evidence jsonb;
begin
  v_context :=
    public.get_account_erasure_handler_context_internal(p_erasure_step_id);

  perform public.assert_account_domain_handler_enabled_internal(
    v_context,
    null
  );

  if v_context ->> 'step_code' <> 'EVALUATE_ERASURE_READINESS' then
    raise exception 'ACCOUNT_ERASURE_STEP_CODE_MISMATCH';
  end if;

  v_user_id := (v_context ->> 'auth_user_id')::uuid;

  select count(*)
    into v_admin_leagues
  from public.leagues l
  where l.owner_id = v_user_id;

  select count(*)
    into v_nonterminal_purchases
  from public.commercial_purchases p
  where p.user_id = v_user_id
    and p.purchase_status not in (
      'confirmed','cancelled','failed','refunded'
    );

  select count(*)
    into v_auth_exists
  from auth.users u
  where u.id = v_user_id;

  select count(*)
    into v_profile_exists
  from public.profiles p
  where p.id = v_user_id;

  v_evidence := jsonb_build_object(
    'auth_user_present', v_auth_exists = 1,
    'profile_present', v_profile_exists = 1,
    'owned_league_count', v_admin_leagues,
    'nonterminal_purchase_count', v_nonterminal_purchases,
    'handler_version', '1.0.0'
  );

  if v_auth_exists <> 1 then
    return public.block_account_erasure_step_internal(
      p_erasure_step_id,
      'AUTH_USER_NOT_FOUND',
      v_evidence
    );
  end if;

  if v_nonterminal_purchases > 0 then
    return public.block_account_erasure_step_internal(
      p_erasure_step_id,
      'NONTERMINAL_COMMERCIAL_PURCHASES',
      v_evidence
    );
  end if;

  return public.complete_account_erasure_step_internal(
    p_erasure_step_id,
    0,
    2,
    v_evidence
  );
end;
$function$;

-- --------------------------------------------------------------------------
-- 5. Step 040 - League Governance resolution
-- --------------------------------------------------------------------------

create or replace function public.handle_account_erasure_040_governance_internal(
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
  v_member record;
  v_successor public.league_members%rowtype;
  v_changed bigint := 0;
  v_objects bigint := 0;
  v_other_member_count bigint := 0;
  v_blocked_leagues jsonb := '[]'::jsonb;
  v_resolved_leagues jsonb := '[]'::jsonb;
  v_deleted_leagues jsonb := '[]'::jsonb;
begin
  v_context :=
    public.get_account_erasure_handler_context_internal(p_erasure_step_id);

  perform public.assert_account_domain_handler_enabled_internal(
    v_context,
    null
  );

  if v_context ->> 'step_code' <> 'RESOLVE_LEAGUE_GOVERNANCE' then
    raise exception 'ACCOUNT_ERASURE_STEP_CODE_MISMATCH';
  end if;

  v_user_id := (v_context ->> 'auth_user_id')::uuid;

  for v_member in
    select
      lm.*,
      l.owner_id,
      l.name as league_name
    from public.league_members lm
    join public.leagues l
      on l.id = lm.league_id
    where lm.user_id = v_user_id
      and lm.status = 'active'
    order by lm.joined_at, lm.id
    for update of lm
  loop
    v_objects := v_objects + 1;

    if v_member.role = 'admin'
       or v_member.owner_id = v_user_id then

      select lm.*
        into v_successor
      from public.league_members lm
      where lm.league_id = v_member.league_id
        and lm.id <> v_member.id
        and lm.role = 'vice'
        and lm.status = 'active'
        and lm.user_id is not null
        and exists (
          select 1
          from auth.users au
          where au.id = lm.user_id
        )
      order by lm.joined_at, lm.id
      limit 1
      for update;

      if v_successor.id is null then
        select lm.*
          into v_successor
        from public.league_members lm
        left join lateral (
          select
            coalesce(sum(rcr.pure_points), 0) as cumulative_points,
            coalesce(sum(rcr.exact_count), 0) as cumulative_exact
          from public.round_certification_results rcr
          join public.round_certifications rc
            on rc.id = rcr.certification_id
          join public.league_rounds lr
            on lr.id = rc.league_round_id
          where lr.league_id = v_member.league_id
            and rc.status = 'official'
            and rc.active = true
            and rcr.league_member_id = lm.id
        ) ranking on true
        where lm.league_id = v_member.league_id
          and lm.id <> v_member.id
          and lm.status = 'active'
          and lm.user_id is not null
          and exists (
            select 1
            from auth.users au
            where au.id = lm.user_id
          )
        order by
          ranking.cumulative_points desc,
          ranking.cumulative_exact desc,
          lm.joined_at,
          lm.id
        limit 1
        for update;
      end if;

      if v_successor.id is null then
        select count(*)
          into v_other_member_count
        from public.league_members lm
        where lm.league_id = v_member.league_id
          and lm.id <> v_member.id;

        if v_other_member_count = 0 then
          -- A League whose only membership is the deleting Admin has no
          -- competitive community or governance continuity to preserve.
          -- Delete the League atomically and allow account erasure to proceed.
          delete from public.leagues l
          where l.id = v_member.league_id;

          v_changed := v_changed + 1;
          v_deleted_leagues :=
            v_deleted_leagues ||
            jsonb_build_array(
              jsonb_build_object(
                'league_id', v_member.league_id,
                'league_name', v_member.league_name,
                'reason', 'SOLE_ADMIN_ACCOUNT_DELETION'
              )
            );

          continue;
        end if;

        -- Other memberships exist but none can assume governance. Account
        -- erasure must still proceed: preserve all competitive history by
        -- moving the League to its canonical archived, read-only lifecycle.
        update public.leagues l
        set
          owner_id = null,
          lifecycle_status = 'archived',
          roster_status = 'locked',
          roster_locked_at = coalesce(
            l.roster_locked_at,
            clock_timestamp()
          ),
          archived_at = coalesce(
            l.archived_at,
            clock_timestamp()
          ),
          archive_reason =
            'SYSTEM_ARCHIVED_ACCOUNT_DELETION_NO_SUCCESSOR',
          vice_required = false,
          public_registrations_open =
            case
              when l.visibility = 'public' then false
              else l.public_registrations_open
            end,
          version = l.version + 1,
          updated_at = clock_timestamp()
        where l.id = v_member.league_id;

        update public.league_members lm
        set role = 'member'
        where lm.league_id = v_member.league_id
          and lm.role in ('admin', 'vice');

        update public.league_governance_states g
        set
          current_admin_member_id = null,
          consecutive_admin_missed_rounds = 0,
          warning_issued_at = null,
          succession_blocked_at = null,
          succession_blocked_reason = null
        where g.league_id = v_member.league_id;

        v_changed := v_changed + 2;
        v_resolved_leagues :=
          v_resolved_leagues ||
          jsonb_build_array(
            jsonb_build_object(
              'league_id', v_member.league_id,
              'league_name', v_member.league_name,
              'other_member_count', v_other_member_count,
              'outcome', 'LEAGUE_SYSTEM_ARCHIVED',
              'archive_reason',
                'SYSTEM_ARCHIVED_ACCOUNT_DELETION_NO_SUCCESSOR'
            )
          );

        continue;
      end if;

      update public.league_members
      set role = 'member'
      where id = v_member.id;

      update public.league_members
      set role = 'admin'
      where id = v_successor.id;

      update public.league_members
      set role = 'member'
      where league_id = v_member.league_id
        and id <> v_successor.id
        and role = 'vice'
        and status = 'active';

      update public.leagues
      set owner_id = v_successor.user_id
      where id = v_member.league_id;

      insert into public.league_governance_states (
        league_id,
        current_admin_member_id,
        consecutive_admin_missed_rounds,
        warning_issued_at,
        succession_completed_at,
        succession_blocked_at,
        succession_blocked_reason
      )
      values (
        v_member.league_id,
        v_successor.id,
        0,
        null,
        clock_timestamp(),
        null,
        null
      )
      on conflict (league_id)
      do update set
        current_admin_member_id =
          excluded.current_admin_member_id,
        consecutive_admin_missed_rounds = 0,
        warning_issued_at = null,
        succession_completed_at = clock_timestamp(),
        succession_blocked_at = null,
        succession_blocked_reason = null;

      perform public.write_league_admin_event(
        v_member.league_id,
        null,
        null,
        'system',
        'admin_transferred_for_account_deletion',
        v_member.id,
        null,
        jsonb_build_object(
          'successor_member_id', v_successor.id,
          'successor_user_id', v_successor.user_id,
          'former_admin_member_id', v_member.id,
          'account_deletion_workflow', true
        )
      );

      v_changed := v_changed + 3;
      v_resolved_leagues :=
        v_resolved_leagues ||
        jsonb_build_array(
          jsonb_build_object(
            'league_id', v_member.league_id,
            'former_admin_member_id', v_member.id,
            'new_admin_member_id', v_successor.id
          )
        );

    elsif v_member.role = 'vice' then
      update public.league_members
      set role = 'member'
      where id = v_member.id;

      v_changed := v_changed + 1;
      v_resolved_leagues :=
        v_resolved_leagues ||
        jsonb_build_array(
          jsonb_build_object(
            'league_id', v_member.league_id,
            'former_vice_member_id', v_member.id,
            'new_role', 'member'
          )
        );
    end if;
  end loop;

  return public.complete_account_erasure_step_internal(
    p_erasure_step_id,
    v_changed,
    v_objects,
    jsonb_build_object(
      'resolved_leagues', v_resolved_leagues,
      'blocked_leagues', v_blocked_leagues,
      'deleted_sole_admin_leagues', v_deleted_leagues,
      'governance_never_blocks_account_erasure', true,
      'handler_version', '1.0.2'
    )
  );
end;
$function$;

-- --------------------------------------------------------------------------
-- 6. Step 050 - revoke Premium access
-- --------------------------------------------------------------------------

create or replace function public.handle_account_erasure_050_access_internal(
  p_erasure_step_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions, pg_catalog
as $function$
declare
  v_context jsonb;
  v_user_id uuid;
  v_session record;
  v_revoked bigint := 0;
begin
  v_context :=
    public.get_account_erasure_handler_context_internal(p_erasure_step_id);

  perform public.assert_account_domain_handler_enabled_internal(
    v_context,
    'commercial_detach_enabled'
  );

  if v_context ->> 'step_code'
     <> 'REVOKE_ACTIVE_COMMERCIAL_ACCESS' then
    raise exception 'ACCOUNT_ERASURE_STEP_CODE_MISMATCH';
  end if;

  v_user_id := (v_context ->> 'auth_user_id')::uuid;

  for v_session in
    select s.id
    from public.premium_access_sessions s
    where s.user_id = v_user_id
      and s.status = 'active'
    order by s.started_at, s.id
  loop
    perform public.revoke_premium_access_session_internal(
      v_session.id,
      'ACCOUNT_DELETION',
      extensions.gen_random_uuid()
    );
    v_revoked := v_revoked + 1;
  end loop;

  return public.complete_account_erasure_step_internal(
    p_erasure_step_id,
    v_revoked,
    v_revoked,
    jsonb_build_object(
      'revoked_session_count', v_revoked,
      'handler_version', '1.0.0'
    )
  );
end;
$function$;

-- --------------------------------------------------------------------------
-- 7. Step 060 - close Commercial wallet
-- --------------------------------------------------------------------------

create or replace function public.handle_account_erasure_060_wallet_internal(
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
  v_wallet public.commercial_wallets%rowtype;
  v_changed bigint := 0;
begin
  v_context :=
    public.get_account_erasure_handler_context_internal(p_erasure_step_id);

  perform public.assert_account_domain_handler_enabled_internal(
    v_context,
    'commercial_detach_enabled'
  );

  if v_context ->> 'step_code' <> 'CLOSE_COMMERCIAL_WALLET' then
    raise exception 'ACCOUNT_ERASURE_STEP_CODE_MISMATCH';
  end if;

  v_user_id := (v_context ->> 'auth_user_id')::uuid;

  select w.*
    into v_wallet
  from public.commercial_wallets w
  where w.user_id = v_user_id
  for update;

  if found then
    perform set_config(
      'fantagol.commercial_internal_write',
      'on',
      true
    );

    update public.commercial_wallets w
    set
      status = 'closed',
      available_passes = 0,
      lifetime_consumed =
        w.lifetime_consumed + w.available_passes,
      ledger_version = w.ledger_version + 1,
      version = w.version + 1,
      updated_at = clock_timestamp()
    where w.id = v_wallet.id
      and (
        w.status <> 'closed'
        or w.available_passes <> 0
      );

    get diagnostics v_changed = row_count;
  end if;

  return public.complete_account_erasure_step_internal(
    p_erasure_step_id,
    v_changed,
    case when v_wallet.id is null then 0 else 1 end,
    jsonb_build_object(
      'wallet_found', v_wallet.id is not null,
      'wallet_id', v_wallet.id,
      'passes_forfeited',
        coalesce(v_wallet.available_passes, 0),
      'handler_version', '1.0.0'
    )
  );
end;
$function$;

-- --------------------------------------------------------------------------
-- 8. Step 070 - retention subject
-- --------------------------------------------------------------------------

create or replace function public.handle_account_erasure_070_retention_internal(
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
  v_subject_id uuid;
begin
  v_context :=
    public.get_account_erasure_handler_context_internal(p_erasure_step_id);

  perform public.assert_account_domain_handler_enabled_internal(
    v_context,
    null
  );

  if v_context ->> 'step_code'
     <> 'CREATE_OR_RESOLVE_RETENTION_SUBJECT' then
    raise exception 'ACCOUNT_ERASURE_STEP_CODE_MISMATCH';
  end if;

  v_user_id := (v_context ->> 'auth_user_id')::uuid;

  v_subject_id :=
    public.resolve_data_retention_subject_internal(
      v_user_id,
      'mixed'
    );

  return public.complete_account_erasure_step_internal(
    p_erasure_step_id,
    1,
    1,
    jsonb_build_object(
      'retention_subject_id', v_subject_id,
      'handler_version', '1.0.0'
    )
  );
end;
$function$;

-- --------------------------------------------------------------------------
-- 9. Step 080 - commercial and loyalty pseudonymization
-- --------------------------------------------------------------------------

create or replace function public.handle_account_erasure_080_commercial_internal(
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
  v_subject_id uuid;
  v_rows bigint := 0;
  v_current bigint;
  v_nonterminal bigint;
begin
  v_context :=
    public.get_account_erasure_handler_context_internal(p_erasure_step_id);

  perform public.assert_account_domain_handler_enabled_internal(
    v_context,
    'commercial_detach_enabled'
  );

  if v_context ->> 'step_code'
     <> 'PSEUDONYMIZE_COMMERCIAL_AND_LOYALTY_DOMAINS' then
    raise exception 'ACCOUNT_ERASURE_STEP_CODE_MISMATCH';
  end if;

  v_user_id := (v_context ->> 'auth_user_id')::uuid;
  v_subject_id :=
    public.resolve_data_retention_subject_internal(v_user_id, 'mixed');

  select
      (select count(*) from public.commercial_purchases
        where user_id = v_user_id
          and purchase_status not in (
            'confirmed','cancelled','failed','refunded'
          ))
    + (select count(*) from public.premium_access_sessions
        where user_id = v_user_id
          and status not in ('expired','revoked'))
    + (select count(*) from public.loyalty_event_producer_receipts
        where user_id = v_user_id
          and receipt_status not in (
            'enqueued','duplicate','rejected'
          ))
    + (select count(*) from public.loyalty_reward_events
        where user_id = v_user_id
          and event_status not in (
            'rewarded','ignored','failed'
          ))
    + (select count(*) from public.loyalty_reward_runtime_inbox
        where user_id = v_user_id
          and event_status not in (
            'rewarded','skipped','failed','dead_letter'
          ))
    + (select count(*) from public.reward_claims
        where user_id = v_user_id
          and claim_status not in (
            'rejected','settled','expired'
          ))
    + (select count(*) from public.reward_revelations
        where user_id = v_user_id
          and revelation_status <> 'seen')
    + (select count(*) from public.workflow_loyalty_dispatch_outbox
        where user_id = v_user_id
          and dispatch_status not in (
            'dispatched','duplicate','rejected','dead_letter'
          ))
  into v_nonterminal;

  if v_nonterminal > 0 then
    return public.block_account_erasure_step_internal(
      p_erasure_step_id,
      'NONTERMINAL_COMMERCIAL_DOMAIN_ROWS',
      jsonb_build_object(
        'nonterminal_row_count', v_nonterminal,
        'handler_version', '1.0.0'
      )
    );
  end if;

  update public.commercial_wallets
  set
    retention_subject_id = v_subject_id,
    user_id = null
  where user_id = v_user_id;
  get diagnostics v_current = row_count;
  v_rows := v_rows + v_current;

  update public.commercial_ledger
  set
    retention_subject_id = v_subject_id,
    user_id = null
  where user_id = v_user_id;
  get diagnostics v_current = row_count;
  v_rows := v_rows + v_current;

  update public.commercial_purchases
  set
    retention_subject_id = v_subject_id,
    user_id = null
  where user_id = v_user_id;
  get diagnostics v_current = row_count;
  v_rows := v_rows + v_current;

  update public.premium_access_sessions
  set
    retention_subject_id = v_subject_id,
    user_id = null
  where user_id = v_user_id;
  get diagnostics v_current = row_count;
  v_rows := v_rows + v_current;

  update public.loyalty_event_producer_receipts
  set
    retention_subject_id = v_subject_id,
    user_id = null
  where user_id = v_user_id;
  get diagnostics v_current = row_count;
  v_rows := v_rows + v_current;

  update public.loyalty_reward_events
  set
    retention_subject_id = v_subject_id,
    user_id = null
  where user_id = v_user_id;
  get diagnostics v_current = row_count;
  v_rows := v_rows + v_current;

  update public.loyalty_reward_runtime_inbox
  set
    retention_subject_id = v_subject_id,
    user_id = null
  where user_id = v_user_id;
  get diagnostics v_current = row_count;
  v_rows := v_rows + v_current;

  update public.reward_claims
  set
    retention_subject_id = v_subject_id,
    user_id = null
  where user_id = v_user_id;
  get diagnostics v_current = row_count;
  v_rows := v_rows + v_current;

  update public.reward_revelations
  set
    retention_subject_id = v_subject_id,
    user_id = null
  where user_id = v_user_id;
  get diagnostics v_current = row_count;
  v_rows := v_rows + v_current;

  update public.workflow_loyalty_dispatch_outbox
  set
    retention_subject_id = v_subject_id,
    user_id = null
  where user_id = v_user_id;
  get diagnostics v_current = row_count;
  v_rows := v_rows + v_current;

  return public.complete_account_erasure_step_internal(
    p_erasure_step_id,
    v_rows,
    10,
    jsonb_build_object(
      'retention_subject_id', v_subject_id,
      'detached_row_count', v_rows,
      'handler_version', '1.0.0'
    )
  );
end;
$function$;

-- --------------------------------------------------------------------------
-- 10. Step 090 - competitive anonymization
-- --------------------------------------------------------------------------

create or replace function public.protect_strategy_version_immutability()
returns trigger
language plpgsql
security definer
set search_path = public
as $function$
begin
  if tg_op = 'DELETE'
     and current_setting(
       'fantagol.allow_strategy_version_delete',
       true
     ) = 'on'
  then
    return old;
  end if;

  if tg_op = 'UPDATE'
     and current_setting(
       'fantagol.account_erasure_strategy_version_detach',
       true
     ) = 'on'
     and old.changed_by_user_id is not null
     and new.changed_by_user_id is null
     and new.id is not distinct from old.id
     and new.strategy_id is not distinct from old.strategy_id
     and new.version is not distinct from old.version
     and new.payload is not distinct from old.payload
     and new.status is not distinct from old.status
     and new.source is not distinct from old.source
     and new.changed_by_member_id is not distinct from old.changed_by_member_id
     and new.changed_at is not distinct from old.changed_at
     and new.metadata is not distinct from old.metadata
  then
    return new;
  end if;

  raise exception using
    errcode = 'P0001',
    message = 'STRATEGY_VERSION_IMMUTABLE';
end;
$function$;

create or replace function public.handle_account_erasure_090_competitive_internal(
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
  v_subject_token text;
  v_label text;
  v_rows bigint := 0;
  v_current bigint;
begin
  v_context :=
    public.get_account_erasure_handler_context_internal(p_erasure_step_id);

  perform public.assert_account_domain_handler_enabled_internal(
    v_context,
    'competitive_anonymization_enabled'
  );

  if v_context ->> 'step_code'
     <> 'ANONYMIZE_COMPETITIVE_IDENTITY' then
    raise exception 'ACCOUNT_ERASURE_STEP_CODE_MISMATCH';
  end if;

  v_user_id := (v_context ->> 'auth_user_id')::uuid;

  select l.subject_token
    into v_subject_token
  from public.account_lifecycle l
  where l.id = (v_context ->> 'account_lifecycle_id')::uuid;

  v_label := 'Utente eliminato ' || upper(left(v_subject_token, 8));

  update public.clubs c
  set
    owner_id = null,
    name = v_label,
    motto = null,
    crest_url = null,
    real_name = null,
    avatar_zoom = 1,
    avatar_x = 0,
    avatar_y = 0
  where c.owner_id = v_user_id;
  get diagnostics v_current = row_count;
  v_rows := v_rows + v_current;

  update public.league_members lm
  set
    user_id = null,
    display_name = v_label,
    role = 'member',
    avatar_url = null
  where lm.user_id = v_user_id;
  get diagnostics v_current = row_count;
  v_rows := v_rows + v_current;

  update public.predictions p
  set user_id = null
  where p.user_id = v_user_id;
  get diagnostics v_current = row_count;
  v_rows := v_rows + v_current;

  perform set_config(
    'fantagol.account_erasure_competitive_detach',
    'on',
    true
  );

  update public.strategies s
  set user_id = null
  where s.user_id = v_user_id;
  get diagnostics v_current = row_count;
  v_rows := v_rows + v_current;

  perform set_config(
    'fantagol.account_erasure_competitive_detach',
    'off',
    true
  );

  update public.prediction_versions pv
  set changed_by_user_id = null
  where pv.changed_by_user_id = v_user_id;
  get diagnostics v_current = row_count;
  v_rows := v_rows + v_current;

  perform set_config(
    'fantagol.account_erasure_strategy_version_detach',
    'on',
    true
  );

  update public.strategy_versions sv
  set changed_by_user_id = null
  where sv.changed_by_user_id = v_user_id;
  get diagnostics v_current = row_count;
  v_rows := v_rows + v_current;

  perform set_config(
    'fantagol.account_erasure_strategy_version_detach',
    'off',
    true
  );

  return public.complete_account_erasure_step_internal(
    p_erasure_step_id,
    v_rows,
    6,
    jsonb_build_object(
      'anonymous_label', v_label,
      'detached_row_count', v_rows,
      'historical_member_identity_preserved', true,
      'handler_version', '1.0.0'
    )
  );
end;
$function$;

-- --------------------------------------------------------------------------
-- 11. Step 100 - remaining nullable Auth references
-- --------------------------------------------------------------------------

create or replace function public.handle_account_erasure_100_detach_internal(
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
  v_owned_leagues bigint;
begin
  v_context :=
    public.get_account_erasure_handler_context_internal(p_erasure_step_id);

  perform public.assert_account_domain_handler_enabled_internal(
    v_context,
    'competitive_anonymization_enabled'
  );

  if v_context ->> 'step_code'
     <> 'DETACH_LEGACY_AUTH_REFERENCES' then
    raise exception 'ACCOUNT_ERASURE_STEP_CODE_MISMATCH';
  end if;

  v_user_id := (v_context ->> 'auth_user_id')::uuid;

  select count(*)
    into v_owned_leagues
  from public.leagues l
  where l.owner_id = v_user_id;

  if v_owned_leagues > 0 then
    return public.block_account_erasure_step_internal(
      p_erasure_step_id,
      'LEAGUE_OWNER_REFERENCE_REMAINS',
      jsonb_build_object(
        'owned_league_count', v_owned_leagues,
        'handler_version', '1.0.0'
      )
    );
  end if;

  update public.competition_audit_log
  set actor_id = null
  where actor_id = v_user_id;
  get diagnostics v_current = row_count;
  v_rows := v_rows + v_current;

  update public.league_admin_events
  set actor_user_id = null
  where actor_user_id = v_user_id;
  get diagnostics v_current = row_count;
  v_rows := v_rows + v_current;

  update public.match_set_versions
  set created_by = null
  where created_by = v_user_id;
  get diagnostics v_current = row_count;
  v_rows := v_rows + v_current;

  update public.account_deletion_reauth_grants
  set grant_status = 'revoked',
      revoked_at = coalesce(revoked_at, clock_timestamp())
  where user_id = v_user_id
    and grant_status not in ('consumed','revoked','expired');
  get diagnostics v_current = row_count;
  v_rows := v_rows + v_current;

  return public.complete_account_erasure_step_internal(
    p_erasure_step_id,
    v_rows,
    4,
    jsonb_build_object(
      'detached_row_count', v_rows,
      'league_owner_reference_count', 0,
      'handler_version', '1.0.0'
    )
  );
end;
$function$;

-- --------------------------------------------------------------------------
-- 12. Step 110 - JSONB scrub catalog
-- --------------------------------------------------------------------------

create or replace function public.handle_account_erasure_110_jsonb_internal(
  p_erasure_step_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_catalog
as $function$
declare
  v_context jsonb;
  v_rule_count bigint;
begin
  v_context :=
    public.get_account_erasure_handler_context_internal(p_erasure_step_id);

  perform public.assert_account_domain_handler_enabled_internal(
    v_context,
    null
  );

  if v_context ->> 'step_code'
     <> 'SCRUB_JSONB_PERSONAL_IDENTIFIERS' then
    raise exception 'ACCOUNT_ERASURE_STEP_CODE_MISMATCH';
  end if;

  select count(*)
    into v_rule_count
  from public.data_erasure_jsonb_rules r
  where r.active
    and r.effective_from <= clock_timestamp()
    and (
      r.retired_at is null
      or r.retired_at > clock_timestamp()
    );

  if v_rule_count > 0 then
    return public.block_account_erasure_step_internal(
      p_erasure_step_id,
      'JSONB_RULE_EXECUTOR_NOT_CERTIFIED',
      jsonb_build_object(
        'active_rule_count', v_rule_count,
        'handler_version', '1.0.0'
      )
    );
  end if;

  return public.complete_account_erasure_step_internal(
    p_erasure_step_id,
    0,
    0,
    jsonb_build_object(
      'active_rule_count', 0,
      'catalog_empty', true,
      'handler_version', '1.0.0'
    )
  );
end;
$function$;

-- --------------------------------------------------------------------------
-- 13. Generic dispatcher for steps 010-110
-- --------------------------------------------------------------------------

create or replace function public.execute_account_erasure_domain_step_internal(
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
  select s.step_code
    into v_step_code
  from public.account_erasure_steps s
  where s.id = p_erasure_step_id;

  if not found then
    raise exception using
      errcode = 'P0002',
      message = 'ACCOUNT_ERASURE_STEP_NOT_FOUND';
  end if;

  case v_step_code
    when 'ACQUIRE_ACCOUNT_LIFECYCLE_LEASE' then
      return public.handle_account_erasure_010_lease_internal(
        p_erasure_step_id
      );
    when 'FREEZE_ACCOUNT_MUTATIONS' then
      return public.handle_account_erasure_020_freeze_internal(
        p_erasure_step_id
      );
    when 'EVALUATE_ERASURE_READINESS' then
      return public.handle_account_erasure_030_readiness_internal(
        p_erasure_step_id
      );
    when 'RESOLVE_LEAGUE_GOVERNANCE' then
      return public.handle_account_erasure_040_governance_internal(
        p_erasure_step_id
      );
    when 'REVOKE_ACTIVE_COMMERCIAL_ACCESS' then
      return public.handle_account_erasure_050_access_internal(
        p_erasure_step_id
      );
    when 'CLOSE_COMMERCIAL_WALLET' then
      return public.handle_account_erasure_060_wallet_internal(
        p_erasure_step_id
      );
    when 'CREATE_OR_RESOLVE_RETENTION_SUBJECT' then
      return public.handle_account_erasure_070_retention_internal(
        p_erasure_step_id
      );
    when 'PSEUDONYMIZE_COMMERCIAL_AND_LOYALTY_DOMAINS' then
      return public.handle_account_erasure_080_commercial_internal(
        p_erasure_step_id
      );
    when 'ANONYMIZE_COMPETITIVE_IDENTITY' then
      return public.handle_account_erasure_090_competitive_internal(
        p_erasure_step_id
      );
    when 'DETACH_LEGACY_AUTH_REFERENCES' then
      return public.handle_account_erasure_100_detach_internal(
        p_erasure_step_id
      );
    when 'SCRUB_JSONB_PERSONAL_IDENTIFIERS' then
      return public.handle_account_erasure_110_jsonb_internal(
        p_erasure_step_id
      );
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
        message = 'ACCOUNT_ERASURE_DOMAIN_STEP_UNSUPPORTED',
        detail = v_step_code;
  end case;
end;
$function$;

-- --------------------------------------------------------------------------
-- 14. Function privileges
-- --------------------------------------------------------------------------

do $grants$
declare
  v_signature text;
begin
  foreach v_signature in array array[
    'public.handle_account_erasure_010_lease_internal(uuid)',
    'public.handle_account_erasure_020_freeze_internal(uuid)',
    'public.handle_account_erasure_030_readiness_internal(uuid)',
    'public.handle_account_erasure_040_governance_internal(uuid)',
    'public.handle_account_erasure_050_access_internal(uuid)',
    'public.handle_account_erasure_060_wallet_internal(uuid)',
    'public.handle_account_erasure_070_retention_internal(uuid)',
    'public.handle_account_erasure_080_commercial_internal(uuid)',
    'public.handle_account_erasure_090_competitive_internal(uuid)',
    'public.handle_account_erasure_100_detach_internal(uuid)',
    'public.handle_account_erasure_110_jsonb_internal(uuid)',
    'public.execute_account_erasure_domain_step_internal(uuid)'
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
-- 15. Metadata and disabled feature state
-- --------------------------------------------------------------------------

update public.account_lifecycle_policies
set
  policy_config = policy_config || jsonb_build_object(
    'domain_handlers_installed', true,
    'domain_handlers_version', '1.0.2',
    'domain_handlers_enabled', false,
    'governance_no_successor_policy', 'SYSTEM_ARCHIVE_OR_DELETE',
    'governance_can_block_erasure', false,
    'commercial_detach_enabled', false,
    'competitive_anonymization_enabled', false,
    'jsonb_scrub_executor_certified', false,
    'storage_handlers_installed', false,
    'profile_handler_installed', false,
    'auth_handler_installed', false
  ),
  updated_at = clock_timestamp()
where policy_code = 'ACCOUNT_DELETION_STANDARD'
  and policy_version = 1;

update public.platform_configuration
set
  schema_version = greatest(schema_version, 174),
  metadata = metadata || jsonb_build_object(
    'account_deletion_domain_handlers_migration', 174,
    'account_deletion_domain_handlers_contract',
      'account-deletion-domain-handlers-v1.0.2',
    'account_deletion_domain_handlers_enabled', false
  ),
  updated_at = now()
where configuration_key = 'primary';

update public.platform_engine_registry
set
  metadata = metadata || jsonb_build_object(
    'domain_handlers_migration', 174,
    'domain_handlers_contract',
      'account-deletion-domain-handlers-v1.0.2',
    'domain_handlers_installed', true,
    'domain_handlers_enabled', false,
    'installed_step_range', '010-110',
    'storage_handlers_installed', false,
    'profile_handler_installed', false,
    'auth_handler_installed', false,
    'destructive_handlers_installed', false
  ),
  updated_at = now()
where engine_code = 'account_lifecycle_engine';

-- --------------------------------------------------------------------------
-- 16. Assertions: installation only, zero execution
-- --------------------------------------------------------------------------

do $assertions$
declare
  v_policy public.account_lifecycle_policies%rowtype;
  v_engine public.platform_engine_registry%rowtype;
  v_workflow_count bigint;
  v_job_count bigint;
  v_advanced_steps bigint;
begin
  select *
    into v_policy
  from public.account_lifecycle_policies
  where policy_code = 'ACCOUNT_DELETION_STANDARD'
    and policy_version = 1;

  select *
    into v_engine
  from public.platform_engine_registry
  where engine_code = 'account_lifecycle_engine';

  if v_policy.automatic_execution_enabled
     or coalesce(
       (v_policy.policy_config ->> 'runtime_launch_enabled')::boolean,
       true
     )
     or coalesce(
       (v_policy.policy_config ->> 'runtime_worker_enabled')::boolean,
       true
     )
     or coalesce(
       (v_policy.policy_config ->> 'domain_handlers_enabled')::boolean,
       true
     )
     or coalesce(
       (v_policy.policy_config ->> 'commercial_detach_enabled')::boolean,
       true
     )
     or coalesce(
       (
         v_policy.policy_config
         ->> 'competitive_anonymization_enabled'
       )::boolean,
       true
     )
     or coalesce(
       (v_policy.policy_config ->> 'storage_deletion_enabled')::boolean,
       true
     )
     or coalesce(
       (v_policy.policy_config ->> 'auth_deletion_enabled')::boolean,
       true
     ) then
    raise exception
      'ACCOUNT_DOMAIN_HANDLER_ASSERTION_FAILED: execution flag enabled';
  end if;

  if not coalesce(
    (v_policy.policy_config ->> 'domain_handlers_installed')::boolean,
    false
  ) then
    raise exception
      'ACCOUNT_DOMAIN_HANDLER_ASSERTION_FAILED: installed marker missing';
  end if;

  if v_engine.lifecycle_status <> 'installed'
     or v_engine.runtime_enabled
     or v_engine.is_certified then
    raise exception
      'ACCOUNT_DOMAIN_HANDLER_ASSERTION_FAILED: engine state changed';
  end if;

  if to_regprocedure(
    'public.execute_account_erasure_domain_step_internal(uuid)'
  ) is null then
    raise exception
      'ACCOUNT_DOMAIN_HANDLER_ASSERTION_FAILED: dispatcher missing';
  end if;

  select count(*) into v_workflow_count
  from public.live_runtime_workflows
  where workflow_type = 'ACCOUNT_DELETION_V1';

  select count(*) into v_job_count
  from public.live_runtime_jobs
  where job_type = 'execute_account_erasure_step';

  select count(*) into v_advanced_steps
  from public.account_erasure_steps
  where step_status <> 'pending';

  if v_workflow_count <> 0
     or v_job_count <> 0
     or v_advanced_steps <> 0 then
    raise exception
      'ACCOUNT_DOMAIN_HANDLER_ASSERTION_FAILED: migration executed runtime data';
  end if;

  if exists (
    select 1
    from public.account_lifecycle l
    where l.lifecycle_status = 'deletion_scheduled'
      and (
        l.workflow_id is not null
        or l.erasure_started_at is not null
        or l.mutation_frozen_at is not null
      )
  ) then
    raise exception
      'ACCOUNT_DOMAIN_HANDLER_ASSERTION_FAILED: lifecycle advanced';
  end if;
end;
$assertions$;

commit;
