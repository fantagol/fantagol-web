begin;

-- ============================================================================
-- FANTAGOL
-- MIGRATION 211
-- LOYALTY LEAGUE PER-MEMBER EVENT KEY HOTFIX
--
-- Root cause:
--
-- LEAGUE_REACHED_8_ACTIVE_MEMBERS is an "award each eligible member" event.
--
-- Migration 105 generated:
--
--   league:<league_id>:LEAGUE_REACHED_8_ACTIVE_MEMBERS
--
-- for every eligible member.
--
-- loyalty_reward_runtime_inbox.event_key is globally UNIQUE, therefore only
-- the first member could enter the runtime inbox.
--
-- Canonical v2 key:
--
--   league:<league_id>:user:<user_id>:LEAGUE_REACHED_8_ACTIVE_MEMBERS
--
-- Other league event families retain their existing semantics.
-- ============================================================================


create or replace function public.enqueue_certified_league_loyalty_event_internal(
  p_user_id uuid,
  p_event_code text,
  p_league_id uuid,
  p_certification_reference text,
  p_league_round_id uuid default null,
  p_season_id uuid default null,
  p_occurred_at timestamptz default clock_timestamp(),
  p_correlation_id uuid default null,
  p_causation_id uuid default null,
  p_payload jsonb default '{}'::jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $function$
declare
  v_event_code text :=
    upper(trim(p_event_code));

  v_scope_key text;
begin

  if v_event_code not in (
    'LEAGUE_REACHED_8_ACTIVE_MEMBERS',
    'LEAGUE_FIRST_ROUND_CERTIFIED',
    'LEAGUE_SEASON_CERTIFIED_COMPLETE'
  ) then

    raise exception using
      errcode = '22023',
      message =
        'LOYALTY_RUNTIME_LEAGUE_EVENT_CODE_INVALID';

  end if;


  if p_user_id is null then

    raise exception using
      errcode = '22004',
      message =
        'LOYALTY_RUNTIME_USER_ID_REQUIRED';

  end if;


  if p_league_id is null then

    raise exception using
      errcode = '22004',
      message =
        'LOYALTY_RUNTIME_LEAGUE_ID_REQUIRED';

  end if;


  v_scope_key :=
    case v_event_code

      -- Per-member reward:
      -- each eligible account must receive an independent runtime event.
      when 'LEAGUE_REACHED_8_ACTIVE_MEMBERS'
        then
            'league:'
          || p_league_id::text
          || ':user:'
          || p_user_id::text

      -- Existing semantics preserved.
      when 'LEAGUE_FIRST_ROUND_CERTIFIED'
        then
            'league-round:'
          || coalesce(
               p_league_round_id::text,
               'missing'
             )

      when 'LEAGUE_SEASON_CERTIFIED_COMPLETE'
        then
            'league-season:'
          || p_league_id::text
          || ':'
          || coalesce(
               p_season_id::text,
               'missing'
             )

    end;


  return public.enqueue_loyalty_certified_event_internal(

    p_user_id,

    v_event_code,

    v_scope_key
      || ':'
      || v_event_code,

    p_certification_reference,

    p_occurred_at,

    p_league_id,

    p_league_round_id,

    p_season_id,

    null,

    p_correlation_id,

    p_causation_id,

    coalesce(
      p_payload,
      '{}'::jsonb
    ),

    jsonb_build_object(
      'producer_adapter',
        'certified_league_loyalty_event',
      'producer_version',
        '1.1',
      'event_key_scope',
        case
          when v_event_code =
               'LEAGUE_REACHED_8_ACTIVE_MEMBERS'
            then 'league_user'
          else 'legacy_league_scope'
        end
    )
  );

end;
$function$;


comment on function public.enqueue_certified_league_loyalty_event_internal(
  uuid,text,uuid,text,uuid,uuid,timestamp with time zone,uuid,uuid,jsonb
)
is
  'Certified league Loyalty adapter. LEAGUE_REACHED_8_ACTIVE_MEMBERS uses league+user event-key identity because the reward is granted independently to every eligible member.';


-- ============================================================================
-- 2. REALIGN THE SINGLE PRE-HOTFIX GOVERNANCE INBOX EVENT
--
-- WP3B produced exactly one runtime event before the collision was detected.
-- It is still pending and has no Loyalty reward event attached.
--
-- Update only that non-terminal event to the canonical per-member key.
-- ============================================================================

update public.loyalty_reward_runtime_inbox
set
  event_key =
      'league:'
      || league_id::text
      || ':user:'
      || user_id::text
      || ':'
      || event_code,

  metadata =
    metadata
    || jsonb_build_object(
      'event_key_migrated_by',
        'migration_211',
      'previous_event_key_scope',
        'league',
      'event_key_scope',
        'league_user'
    )

where event_code =
      'LEAGUE_REACHED_8_ACTIVE_MEMBERS'

  and league_id is not null

  and event_status = 'pending'

  and loyalty_reward_event_id is null

  and event_key =
      'league:'
      || league_id::text
      || ':'
      || event_code;


-- ============================================================================
-- 3. ASSERTIONS
-- ============================================================================

do $assert$
declare
  v_definition text;
  v_old_keys integer;
begin

  select pg_get_functiondef(
    'public.enqueue_certified_league_loyalty_event_internal(uuid,text,uuid,text,uuid,uuid,timestamp with time zone,uuid,uuid,jsonb)'
      ::regprocedure
  )
  into v_definition;


  if position(
      ''':user:'''
      in v_definition
    ) = 0
  then
    raise exception
      'MIGRATION_211_USER_SCOPED_EVENT_KEY_MISSING';
  end if;


  if position(
      '''LEAGUE_REACHED_8_ACTIVE_MEMBERS'''
      in v_definition
    ) = 0
  then
    raise exception
      'MIGRATION_211_GOVERNANCE_EVENT_ROUTE_MISSING';
  end if;


  select count(*)::integer
  into v_old_keys
  from public.loyalty_reward_runtime_inbox
  where event_code =
        'LEAGUE_REACHED_8_ACTIVE_MEMBERS'
    and event_key =
        'league:'
        || league_id::text
        || ':'
        || event_code;


  if v_old_keys <> 0 then
    raise exception
      'MIGRATION_211_OLD_GOVERNANCE_KEYS_REMAIN count=%',
      v_old_keys;
  end if;

end;
$assert$;

commit;