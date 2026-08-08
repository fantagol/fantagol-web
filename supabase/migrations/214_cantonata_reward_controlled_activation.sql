begin;

-- ============================================================================
-- FANTAGOL
-- MIGRATION 214
-- CANTONATA REWARD CONTROLLED ACTIVATION
--
-- Activates ONLY:
--
--   PREDICTION_RESULT_CANTONATA
--   POLICY_CANTONATA_ACHIEVED
--   LOYALTY_CANTONATA_ACHIEVED
--
-- Producer remains TEST MODE.
-- Campaign remains private.
-- No reward is emitted by this migration.
-- ============================================================================


select public.set_loyalty_event_producer_state_internal(
  'PREDICTION_RESULT_CANTONATA',
  true,
  true,
  'C3 WP3F controlled Cantonata reward E2E'
);


update public.loyalty_reward_policies
set
  enabled = true,

  metadata =
    metadata
    || jsonb_build_object(
      'activated_by',
        'migration_214',
      'activation_status',
        'wp3f_cantonata_controlled_activation'
    ),

  updated_at =
    clock_timestamp(),

  version =
    version + 1

where policy_code =
      'POLICY_CANTONATA_ACHIEVED'
  and enabled = false;


do $campaign$
declare
  v_campaign public.reward_campaigns%rowtype;

  v_version public.commercial_campaign_versions%rowtype;
  v_approved public.commercial_campaign_versions%rowtype;

  v_readiness jsonb;

  v_request public.commercial_campaign_activation_requests%rowtype;
  v_runtime public.commercial_campaign_runtime_states%rowtype;
begin

  select *
  into strict v_campaign
  from public.reward_campaigns
  where campaign_code =
        'LOYALTY_CANTONATA_ACHIEVED'
  for update;


  if v_campaign.public then
    raise exception
      'MIGRATION_214_CANTONATA_CAMPAIGN_MUST_REMAIN_PRIVATE';
  end if;


  v_version :=
    public.create_commercial_campaign_version_internal(
      v_campaign.id,
      'fantagol-wp3f',
      'Cantonata reward controlled E2E activation',
      jsonb_build_object(
        'wp',
          'C3_WP3F',
        'controlled_cantonata_test',
          true
      ),
      gen_random_uuid(),
      null
    );


  v_approved :=
    public.approve_commercial_campaign_version_internal(
      v_version.id,
      'fantagol-wp3f',
      'Approved for controlled Cantonata Reward E2E',
      gen_random_uuid(),
      null
    );


  v_readiness :=
    public.evaluate_commercial_campaign_readiness_internal(
      v_campaign.id,
      v_approved.id,
      null,
      null
    );


  if coalesce(
       (v_readiness ->> 'ready')::boolean,
       false
     ) = false
  then
    raise exception
      'MIGRATION_214_CANTONATA_CAMPAIGN_NOT_READY report=%',
      v_readiness;
  end if;


  v_request :=
    public.request_commercial_campaign_activation_internal(
      v_campaign.id,
      v_approved.id,
      'fantagol-wp3f',
      null,
      null,
      'Controlled Cantonata Reward E2E',
      jsonb_build_object(
        'test_mode',
          true,
        'wp',
          'C3_WP3F'
      ),
      gen_random_uuid(),
      null
    );


  v_runtime :=
    public.approve_commercial_campaign_activation_internal(
      v_request.id,
      'fantagol-wp3f',
      'Cantonata Reward E2E activation approved',
      null
    );


  if v_runtime.runtime_state <> 'active' then
    raise exception
      'MIGRATION_214_CANTONATA_CAMPAIGN_ACTIVATION_FAILED state=%',
      v_runtime.runtime_state;
  end if;

end;
$campaign$;


do $assert$
begin

  if not exists (
    select 1
    from public.loyalty_event_producers
    where producer_code =
          'PREDICTION_RESULT_CANTONATA'
      and enabled
      and test_mode
  ) then
    raise exception
      'MIGRATION_214_CANTONATA_PRODUCER_NOT_ACTIVE';
  end if;


  if not exists (
    select 1
    from public.loyalty_reward_policies
    where policy_code =
          'POLICY_CANTONATA_ACHIEVED'
      and event_code =
          'CERTIFIED_CANTONATA_ACHIEVED'
      and enabled
  ) then
    raise exception
      'MIGRATION_214_CANTONATA_POLICY_NOT_ACTIVE';
  end if;


  if not exists (
    select 1
    from public.reward_campaigns c
    join public.commercial_campaign_runtime_states s
      on s.campaign_id = c.id
    where c.campaign_code =
          'LOYALTY_CANTONATA_ACHIEVED'
      and c.enabled
      and c.public = false
      and s.runtime_state = 'active'
      and s.readiness_status = 'ready'
  ) then
    raise exception
      'MIGRATION_214_CANTONATA_CAMPAIGN_NOT_ACTIVE';
  end if;

end;
$assert$;

commit;