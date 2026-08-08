begin;
-- ============================================================================
-- MIGRATION_210_COMMERCIAL_EVENT_AGGREGATE_VOCABULARY
--
-- Migrations 105-107 introduced operational Commercial Platform events using:
--
--   LOYALTY_RUNTIME_EVENT
--   LOYALTY_EVENT_PRODUCER
--   LOYALTY_PRODUCER_RECEIPT
--   WORKFLOW_LOYALTY_BINDING
--   WORKFLOW_LOYALTY_DISPATCH
--
-- Their administration/runtime functions already emit these canonical
-- aggregate types through commercial_append_event_internal(), but the shared
-- Commercial Event Bus constraint was never extended accordingly.
--
-- Preserve every aggregate type currently installed and append only the
-- missing canonical Loyalty/Workflow types.
-- ============================================================================

do $extend_commercial_event_aggregate_vocabulary$
declare
  v_definition text;
  v_values text;
begin

  select pg_get_constraintdef(c.oid)
  into v_definition
  from pg_constraint c
  where c.conrelid =
        'public.commercial_platform_events'::regclass
    and c.conname =
        'commercial_platform_events_aggregate_type_check'
    and c.contype = 'c';

  if v_definition is null then
    raise exception
      'MIGRATION_210_COMMERCIAL_EVENT_AGGREGATE_CONSTRAINT_MISSING';
  end if;


  select string_agg(
    quote_literal(value),
    ','
    order by value
  )
  into v_values
  from (
    select distinct value
    from (
      select m[1] as value
      from regexp_matches(
        v_definition,
        '''([^'']+)''',
        'g'
      ) m

      union all

      select 'LOYALTY_RUNTIME_EVENT'

      union all

      select 'LOYALTY_EVENT_PRODUCER'

      union all

      select 'LOYALTY_PRODUCER_RECEIPT'

      union all

      select 'WORKFLOW_LOYALTY_BINDING'

      union all

      select 'WORKFLOW_LOYALTY_DISPATCH'
    ) vocabulary
  ) canonical;


  if v_values is null then
    raise exception
      'MIGRATION_210_COMMERCIAL_EVENT_AGGREGATE_PARSE_FAILED';
  end if;


  alter table public.commercial_platform_events
    drop constraint
      commercial_platform_events_aggregate_type_check;


  execute
    'alter table public.commercial_platform_events ' ||
    'add constraint commercial_platform_events_aggregate_type_check ' ||
    'check (aggregate_type in (' ||
    v_values ||
    '))';

end;
$extend_commercial_event_aggregate_vocabulary$;


do $assert_commercial_event_aggregate_vocabulary$
declare
  v_definition text;
begin

  select pg_get_constraintdef(c.oid)
  into v_definition
  from pg_constraint c
  where c.conrelid =
        'public.commercial_platform_events'::regclass
    and c.conname =
        'commercial_platform_events_aggregate_type_check';


  foreach v_definition in array array[
    pg_get_constraintdef(
      (
        select c.oid
        from pg_constraint c
        where c.conrelid =
              'public.commercial_platform_events'::regclass
          and c.conname =
              'commercial_platform_events_aggregate_type_check'
      )
    )
  ]
  loop
    null;
  end loop;


  if position(
      '''LOYALTY_RUNTIME_EVENT'''
      in v_definition
    ) = 0 then
    raise exception
      'MIGRATION_210_LOYALTY_RUNTIME_EVENT_AGGREGATE_MISSING';
  end if;

  if position(
      '''LOYALTY_EVENT_PRODUCER'''
      in v_definition
    ) = 0 then
    raise exception
      'MIGRATION_210_LOYALTY_EVENT_PRODUCER_AGGREGATE_MISSING';
  end if;

  if position(
      '''LOYALTY_PRODUCER_RECEIPT'''
      in v_definition
    ) = 0 then
    raise exception
      'MIGRATION_210_LOYALTY_PRODUCER_RECEIPT_AGGREGATE_MISSING';
  end if;

  if position(
      '''WORKFLOW_LOYALTY_BINDING'''
      in v_definition
    ) = 0 then
    raise exception
      'MIGRATION_210_WORKFLOW_LOYALTY_BINDING_AGGREGATE_MISSING';
  end if;

  if position(
      '''WORKFLOW_LOYALTY_DISPATCH'''
      in v_definition
    ) = 0 then
    raise exception
      'MIGRATION_210_WORKFLOW_LOYALTY_DISPATCH_AGGREGATE_MISSING';
  end if;

end;
$assert_commercial_event_aggregate_vocabulary$;


-- ============================================================================
-- FANTAGOL
-- MIGRATION 210
-- GOVERNANCE ACHIEVEMENT -> LOYALTY BRIDGE
--
-- Architecture:
--
-- achievement_certifications
--      ↓
-- enqueue_achievement_loyalty_dispatch_internal(...)
--      ↓
-- workflow_loyalty_dispatch_outbox
--      ↓
-- Migration 107 dispatcher
--      ↓
-- Migration 106 certified producer
--      ↓
-- loyalty_reward_runtime_inbox
--
-- ACTIVATED IN THIS MIGRATION:
--   WF_LOYALTY_LEAGUE_8_MEMBERS       enabled / test_mode
--   LEAGUE_REACHED_8_MEMBERS          enabled / test_mode
--
-- REMAINS DISABLED:
--   loyalty reward policy
--   loyalty reward campaign
--   INTERNAL_ACHIEVEMENT source
--   all other bindings/producers
--
-- Therefore this migration cannot settle Pass rewards.
-- ============================================================================


-- ============================================================================
-- 1. CANONICAL ACHIEVEMENT -> WORKFLOW LOYALTY ADAPTER
-- ============================================================================

create or replace function public.enqueue_achievement_loyalty_dispatch_internal(
  p_achievement_certification_id uuid,
  p_workflow_instance_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $function$
declare
  v_achievement public.achievement_certifications%rowtype;
  v_workflow public.live_runtime_workflows%rowtype;
  v_step public.live_runtime_workflow_steps%rowtype;

  v_evidence jsonb;
  v_result jsonb;
begin

  if p_achievement_certification_id is null then
    raise exception using
      errcode = '22004',
      message = 'ACHIEVEMENT_LOYALTY_CERTIFICATION_ID_REQUIRED';
  end if;

  if p_workflow_instance_id is null then
    raise exception using
      errcode = '22004',
      message = 'ACHIEVEMENT_LOYALTY_WORKFLOW_ID_REQUIRED';
  end if;


  select ac.*
  into v_achievement
  from public.achievement_certifications ac
  where ac.id = p_achievement_certification_id;

  if not found then
    raise exception using
      errcode = 'P0002',
      message = 'ACHIEVEMENT_LOYALTY_CERTIFICATION_NOT_FOUND';
  end if;


  if v_achievement.achievement_code <>
       'LEAGUE_REACHED_8_ACTIVE_MEMBERS'
  then
    raise exception using
      errcode = '22023',
      message = 'ACHIEVEMENT_LOYALTY_GOVERNANCE_CODE_INVALID';
  end if;


  select w.*
  into v_workflow
  from public.live_runtime_workflows w
  where w.id = p_workflow_instance_id
    and w.workflow_type =
        'league_governance_certification'
    and w.status = 'completed';

  if not found then
    raise exception using
      errcode = '55000',
      message = 'ACHIEVEMENT_LOYALTY_WORKFLOW_NOT_COMPLETED';
  end if;


  if v_workflow.scope_type <> 'league'
     or v_workflow.scope_id
        is distinct from v_achievement.league_id
  then
    raise exception using
      errcode = '22023',
      message = 'ACHIEVEMENT_LOYALTY_WORKFLOW_SCOPE_MISMATCH';
  end if;


  select s.*
  into v_step
  from public.live_runtime_workflow_steps s
  where s.workflow_id = v_workflow.id
    and s.step_key =
        'certify_active_membership_threshold'
    and s.status = 'completed'
  limit 1;

  if not found then
    raise exception using
      errcode = '55000',
      message = 'ACHIEVEMENT_LOYALTY_STEP_NOT_COMPLETED';
  end if;


  if v_achievement.user_id is null then
    raise exception using
      errcode = '22004',
      message = 'ACHIEVEMENT_LOYALTY_USER_ID_REQUIRED';
  end if;


  if nullif(
       btrim(v_achievement.certification_reference),
       ''
     ) is null
     or nullif(
       btrim(v_achievement.certification_digest),
       ''
     ) is null
  then
    raise exception using
      errcode = '22023',
      message = 'ACHIEVEMENT_LOYALTY_CERTIFICATION_EVIDENCE_INVALID';
  end if;


  v_evidence :=
    jsonb_build_object(
      'certified',
        true,

      'certified_at',
        v_achievement.certified_at,

      'certification_digest',
        v_achievement.certification_digest,

      'workflow_completed',
        true,

      'step_completed',
        true,

      'workflow_code',
        v_workflow.workflow_type,

      'completion_step_code',
        v_step.step_key,

      'workflow_instance_id',
        v_workflow.id,

      'workflow_step_id',
        v_step.id,

      'league_id',
        v_achievement.league_id,

      'achievement_kind',
        v_achievement.achievement_code,

      'achievement_certification_id',
        v_achievement.id,

      'league_member_id',
        v_achievement.league_member_id,

      'bootstrap',
        v_achievement.bootstrap,

      'achievement_evidence',
        v_achievement.evidence
    );


  v_result :=
    public.enqueue_workflow_loyalty_dispatch_internal(
      p_binding_code =>
        'WF_LOYALTY_LEAGUE_8_MEMBERS',

      p_workflow_instance_id =>
        v_workflow.id,

      p_workflow_step_id =>
        v_step.id,

      -- One canonical execution key per immutable Achievement certification.
      p_workflow_execution_key =>
        'achievement:'
        || v_achievement.id::text,

      p_user_id =>
        v_achievement.user_id,

      p_certification_reference =>
        v_achievement.certification_reference,

      p_certification_digest =>
        v_achievement.certification_digest,

      p_evidence_version =>
        1,

      p_evidence =>
        v_evidence,

      p_occurred_at =>
        v_achievement.occurred_at,

      p_league_id =>
        v_achievement.league_id,

      p_league_round_id =>
        v_achievement.league_round_id,

      p_season_id =>
        v_achievement.season_id,

      p_prediction_result_id =>
        null,

      p_correlation_id =>
        v_workflow.correlation_id,

      p_causation_id =>
        v_achievement.id,

      p_payload =>
        jsonb_build_object(
          'achievement_certification_id',
            v_achievement.id,
          'achievement_code',
            v_achievement.achievement_code,
          'league_member_id',
            v_achievement.league_member_id,
          'bootstrap',
            v_achievement.bootstrap
        ),

      p_metadata =>
        jsonb_build_object(
          'bridge',
            'achievement_loyalty',
          'bridge_version',
            '1.0.0',
          'achievement_certification_id',
            v_achievement.id,
          'historical_reconciliation',
            v_achievement.bootstrap
        )
    );


  return
    coalesce(
      v_result,
      '{}'::jsonb
    )
    || jsonb_build_object(
      'achievement_certification_id',
        v_achievement.id,
      'achievement_code',
        v_achievement.achievement_code,
      'workflow_instance_id',
        v_workflow.id,
      'workflow_step_id',
        v_step.id
    );

end;
$function$;


comment on function public.enqueue_achievement_loyalty_dispatch_internal(
  uuid,uuid
)
is
  'Canonical Achievement Ledger -> Workflow Loyalty outbox bridge. v1 supports certified LEAGUE_REACHED_8_ACTIVE_MEMBERS only.';


revoke all
on function public.enqueue_achievement_loyalty_dispatch_internal(
  uuid,uuid
)
from public, anon, authenticated;

grant execute
on function public.enqueue_achievement_loyalty_dispatch_internal(
  uuid,uuid
)
to service_role;


-- ============================================================================
-- 2. CONTROLLED GOVERNANCE BINDING ACTIVATION
-- ============================================================================

select public.set_workflow_loyalty_binding_state_internal(
  'WF_LOYALTY_LEAGUE_8_MEMBERS',
  true,
  true,
  'C3 WP3B controlled Governance bridge activation'
);


-- ============================================================================
-- 3. CONTROLLED GOVERNANCE PRODUCER ACTIVATION
-- ============================================================================

select public.set_loyalty_event_producer_state_internal(
  'LEAGUE_REACHED_8_MEMBERS',
  true,
  true,
  'C3 WP3B controlled Governance producer activation'
);


-- ============================================================================
-- 4. HARD SAFETY ASSERTIONS
-- ============================================================================

do $assertions$
declare
  v_enabled_bindings integer;
  v_enabled_producers integer;
begin

  if to_regprocedure(
    'public.enqueue_achievement_loyalty_dispatch_internal(uuid,uuid)'
  ) is null then
    raise exception
      'MIGRATION_210_BRIDGE_FUNCTION_MISSING';
  end if;


  select count(*)::integer
  into v_enabled_bindings
  from public.workflow_loyalty_producer_bindings
  where enabled;

  if v_enabled_bindings <> 1 then
    raise exception
      'MIGRATION_210_EXPECTED_ONE_ENABLED_BINDING count=%',
      v_enabled_bindings;
  end if;


  if not exists (
    select 1
    from public.workflow_loyalty_producer_bindings
    where binding_code =
          'WF_LOYALTY_LEAGUE_8_MEMBERS'
      and enabled
      and test_mode
  ) then
    raise exception
      'MIGRATION_210_GOVERNANCE_BINDING_NOT_ACTIVE';
  end if;


  select count(*)::integer
  into v_enabled_producers
  from public.loyalty_event_producers
  where enabled;

  if v_enabled_producers <> 1 then
    raise exception
      'MIGRATION_210_EXPECTED_ONE_ENABLED_PRODUCER count=%',
      v_enabled_producers;
  end if;


  if not exists (
    select 1
    from public.loyalty_event_producers
    where producer_code =
          'LEAGUE_REACHED_8_MEMBERS'
      and enabled
      and test_mode
  ) then
    raise exception
      'MIGRATION_210_GOVERNANCE_PRODUCER_NOT_ACTIVE';
  end if;


  -- Settlement layer must remain completely disabled.
  if exists (
    select 1
    from public.loyalty_reward_policies
    where enabled
  ) then
    raise exception
      'MIGRATION_210_REWARD_POLICY_MUST_REMAIN_DISABLED';
  end if;


  if exists (
    select 1
    from public.reward_campaigns
    where campaign_code like 'LOYALTY_%'
      and enabled
  ) then
    raise exception
      'MIGRATION_210_REWARD_CAMPAIGN_MUST_REMAIN_DISABLED';
  end if;


  if exists (
    select 1
    from public.reward_sources
    where source_code =
          'INTERNAL_ACHIEVEMENT'
      and enabled
  ) then
    raise exception
      'MIGRATION_210_REWARD_SOURCE_MUST_REMAIN_DISABLED';
  end if;

end;
$assertions$;

commit;