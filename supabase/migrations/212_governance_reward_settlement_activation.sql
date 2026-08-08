begin;

-- ============================================================================
-- FANTAGOL
-- MIGRATION 212
-- GOVERNANCE REWARD SETTLEMENT ACTIVATION
--
-- Activates ONLY:
--
--   reward source:
--     INTERNAL_ACHIEVEMENT
--
--   campaign:
--     LOYALTY_LEAGUE_FULL_8
--
--   policy:
--     POLICY_LEAGUE_FULL_8
--
-- Campaign activation uses the canonical Commercial Campaign Governance
-- Engine:
--
--   version
--     -> approval
--     -> readiness
--     -> activation request
--     -> activation approval
--
-- No runtime inbox event is processed by this migration.
-- Settlement happens only in the explicit WP3C E2E step afterwards.
-- ============================================================================


-- ============================================================================
-- 1. PRECONDITIONS
-- ============================================================================

do $pre$
declare
  v_pending integer;
begin

  select count(*)::integer
  into v_pending
  from public.loyalty_reward_runtime_inbox
  where event_code =
        'LEAGUE_REACHED_8_ACTIVE_MEMBERS'
    and event_status = 'pending';

  if v_pending <> 18 then
    raise exception
      'MIGRATION_212_EXPECTED_18_PENDING_RUNTIME_EVENTS found=%',
      v_pending;
  end if;


  if exists (
    select 1
    from public.loyalty_reward_events
  ) then
    raise exception
      'MIGRATION_212_REWARD_EVENTS_MUST_START_EMPTY';
  end if;


  if exists (
    select 1
    from public.reward_revelations
  ) then
    raise exception
      'MIGRATION_212_REVELATIONS_MUST_START_EMPTY';
  end if;

end;
$pre$;


-- ============================================================================
-- 2. ACTIVATE CERTIFIED INTERNAL ACHIEVEMENT SOURCE
--
-- Source stays backend-only and test_mode remains TRUE.
-- ============================================================================

update public.reward_sources
set
  enabled = true,

  configuration =
    configuration
    || jsonb_build_object(
      'activation_status',
        'wp3c_governance_controlled_activation'
    ),

  metadata =
    metadata
    || jsonb_build_object(
      'activated_by',
        'migration_212',
      'activation_scope',
        'LOYALTY_LEAGUE_FULL_8',
      'controlled_test_activation',
        true
    ),

  updated_at =
    clock_timestamp()

where source_code =
      'INTERNAL_ACHIEVEMENT'
  and enabled = false;


do $source$
declare
  v_source public.reward_sources%rowtype;
begin

  select *
  into strict v_source
  from public.reward_sources
  where source_code =
        'INTERNAL_ACHIEVEMENT';

  if not v_source.enabled then
    raise exception
      'MIGRATION_212_INTERNAL_ACHIEVEMENT_SOURCE_NOT_ENABLED';
  end if;

  if not v_source.test_mode then
    raise exception
      'MIGRATION_212_SOURCE_MUST_REMAIN_TEST_MODE';
  end if;

  if v_source.verification_mode <> 'backend' then
    raise exception
      'MIGRATION_212_SOURCE_BACKEND_VERIFICATION_REQUIRED';
  end if;


  perform public.commercial_append_event_internal(
    'REWARD_SOURCE_STATE_CHANGED',
    'REWARD_SOURCE',
    v_source.id,
    null,
    gen_random_uuid(),
    null,
    jsonb_build_object(
      'source_code',
        v_source.source_code,
      'enabled',
        true,
      'test_mode',
        v_source.test_mode,
      'reason',
        'C3 WP3C controlled Governance reward settlement activation'
    )
  );

end;
$source$;


-- ============================================================================
-- 3. ENABLE ONLY THE GOVERNANCE LOYALTY POLICY
-- ============================================================================

update public.loyalty_reward_policies
set
  enabled = true,

  metadata =
    metadata
    || jsonb_build_object(
      'activation_status',
        'wp3c_governance_controlled_activation',
      'activated_by',
        'migration_212'
    ),

  updated_at =
    clock_timestamp(),

  version =
    version + 1

where policy_code =
      'POLICY_LEAGUE_FULL_8'
  and enabled = false;


do $policy$
declare
  v_policy public.loyalty_reward_policies%rowtype;
begin

  select *
  into strict v_policy
  from public.loyalty_reward_policies
  where policy_code =
        'POLICY_LEAGUE_FULL_8';

  if not v_policy.enabled then
    raise exception
      'MIGRATION_212_GOVERNANCE_POLICY_NOT_ENABLED';
  end if;


  if (
    select count(*)
    from public.loyalty_reward_policies
    where enabled
  ) <> 1 then

    raise exception
      'MIGRATION_212_EXACTLY_ONE_POLICY_MUST_BE_ENABLED';

  end if;


  perform public.commercial_append_event_internal(
    'LOYALTY_REWARD_POLICY_STATE_CHANGED',
    'LOYALTY_REWARD_POLICY',
    v_policy.id,
    null,
    gen_random_uuid(),
    null,
    jsonb_build_object(
      'policy_code',
        v_policy.policy_code,
      'event_code',
        v_policy.event_code,
      'enabled',
        true,
      'reason',
        'C3 WP3C controlled Governance reward settlement activation'
    )
  );

end;
$policy$;


-- ============================================================================
-- 4. GOVERNED CAMPAIGN ACTIVATION
-- ============================================================================

do $campaign$
declare
  v_campaign public.reward_campaigns%rowtype;

  v_version public.commercial_campaign_versions%rowtype;
  v_approved_version public.commercial_campaign_versions%rowtype;

  v_readiness jsonb;

  v_request public.commercial_campaign_activation_requests%rowtype;
  v_runtime public.commercial_campaign_runtime_states%rowtype;

  v_existing_approved public.commercial_campaign_versions%rowtype;
begin

  select *
  into strict v_campaign
  from public.reward_campaigns
  where campaign_code =
        'LOYALTY_LEAGUE_FULL_8'
  for update;


  if v_campaign.public then
    raise exception
      'MIGRATION_212_LOYALTY_CAMPAIGN_MUST_REMAIN_PRIVATE';
  end if;


  -- Reuse an already approved configuration only if one exists and has
  -- no drift. Otherwise create and approve a fresh governed snapshot.

  select *
  into v_existing_approved
  from public.commercial_campaign_versions
  where campaign_id =
        v_campaign.id
    and version_status =
        'approved'
  limit 1;


  if v_existing_approved.id is not null
     and v_existing_approved.configuration_hash =
         md5(
           (
             to_jsonb(v_campaign)
             - array[
                 'issued_claims',
                 'issued_passes',
                 'created_at',
                 'updated_at'
               ]
           )::text
         )
  then

    v_approved_version :=
      v_existing_approved;

  else

    v_version :=
      public.create_commercial_campaign_version_internal(
        v_campaign.id,
        'fantagol-wp3c',
        'Governance reward controlled settlement activation',
        jsonb_build_object(
          'wp',
            'C3_WP3C',
          'controlled_activation',
            true
        ),
        gen_random_uuid(),
        null
      );


    v_approved_version :=
      public.approve_commercial_campaign_version_internal(
        v_version.id,
        'fantagol-wp3c',
        'Approved for Governance Reward E2E settlement',
        gen_random_uuid(),
        null
      );

  end if;


  v_readiness :=
    public.evaluate_commercial_campaign_readiness_internal(
      v_campaign.id,
      v_approved_version.id,
      null,
      null
    );


  if coalesce(
       (v_readiness ->> 'ready')::boolean,
       false
     ) = false
  then

    raise exception
      'MIGRATION_212_CAMPAIGN_READINESS_BLOCKED report=%',
      v_readiness;

  end if;


  v_request :=
    public.request_commercial_campaign_activation_internal(
      v_campaign.id,
      v_approved_version.id,
      'fantagol-wp3c',
      null,
      null,
      'Controlled activation for Governance Reward E2E settlement',
      jsonb_build_object(
        'wp',
          'C3_WP3C',
        'test_mode',
          true
      ),
      gen_random_uuid(),
      null
    );


  v_runtime :=
    public.approve_commercial_campaign_activation_internal(
      v_request.id,
      'fantagol-wp3c',
      'Governance Reward E2E activation approved',
      null
    );


  if v_runtime.runtime_state <> 'active' then
    raise exception
      'MIGRATION_212_CAMPAIGN_NOT_ACTIVE state=%',
      v_runtime.runtime_state;
  end if;


  select *
  into strict v_campaign
  from public.reward_campaigns
  where id = v_campaign.id;


  if not v_campaign.enabled then
    raise exception
      'MIGRATION_212_REWARD_CAMPAIGN_ENABLED_FLAG_FALSE';
  end if;


  if v_campaign.public then
    raise exception
      'MIGRATION_212_REWARD_CAMPAIGN_BECAME_PUBLIC';
  end if;

end;
$campaign$;


-- ============================================================================
-- 5. FINAL ACTIVATION ASSERTIONS
-- ============================================================================

do $assert$
begin

  if (
    select count(*)
    from public.reward_sources
    where enabled
      and source_code =
          'INTERNAL_ACHIEVEMENT'
  ) <> 1 then
    raise exception
      'MIGRATION_212_SOURCE_ACTIVATION_INVALID';
  end if;


  if (
    select count(*)
    from public.loyalty_reward_policies
    where enabled
  ) <> 1 then
    raise exception
      'MIGRATION_212_POLICY_ACTIVATION_SCOPE_INVALID';
  end if;


  if not exists (
    select 1
    from public.loyalty_reward_policies
    where policy_code =
          'POLICY_LEAGUE_FULL_8'
      and enabled
  ) then
    raise exception
      'MIGRATION_212_GOVERNANCE_POLICY_MISSING';
  end if;


  if (
    select count(*)
    from public.reward_campaigns
    where campaign_code like 'LOYALTY_%'
      and enabled
  ) <> 1 then
    raise exception
      'MIGRATION_212_CAMPAIGN_ACTIVATION_SCOPE_INVALID';
  end if;


  if not exists (
    select 1
    from public.reward_campaigns
    where campaign_code =
          'LOYALTY_LEAGUE_FULL_8'
      and enabled
      and public = false
  ) then
    raise exception
      'MIGRATION_212_GOVERNANCE_CAMPAIGN_MISSING';
  end if;


  if not exists (
    select 1
    from public.commercial_campaign_runtime_states s
    join public.reward_campaigns c
      on c.id = s.campaign_id
    where c.campaign_code =
          'LOYALTY_LEAGUE_FULL_8'
      and s.runtime_state =
          'active'
      and s.readiness_status =
          'ready'
  ) then
    raise exception
      'MIGRATION_212_GOVERNANCE_RUNTIME_NOT_ACTIVE_READY';
  end if;


  -- Nothing is settled during activation.
  if exists (
    select 1
    from public.loyalty_reward_events
  ) then
    raise exception
      'MIGRATION_212_SETTLEMENT_OCCURRED_DURING_ACTIVATION';
  end if;

end;
$assert$;

commit;