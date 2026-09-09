-- ============================================================================
-- FANTAGOL MIGRATION 310
-- LOYALTY REWARD RUNTIME ROUND-CERTIFICATION AUTHORITY
--
-- Permanent rule:
--   A round-terminal reward intent may reach award_loyalty_reward_internal
--   only while its referenced Round Certification is still the active
--   official authority for the same League Round.
--
-- Superseded / inactive / missing authority:
--   - terminal status: skipped
--   - zero loyalty reward event
--   - zero reward claim
--   - zero PASS_REWARD ledger entry
--
-- Non round_terminal_game_objectives events preserve the existing runtime.
-- ============================================================================

create or replace function public.loyalty_runtime_has_round_authority_internal(
  p_inbox_event_id uuid
)
returns boolean
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_inbox public.loyalty_reward_runtime_inbox;
  v_certification_id uuid;
  v_authorized boolean := false;
begin
  select *
  into v_inbox
  from public.loyalty_reward_runtime_inbox
  where id = p_inbox_event_id;

  if not found then
    raise exception using
      errcode = 'P0002',
      message = 'LOYALTY_RUNTIME_INBOX_EVENT_NOT_FOUND';
  end if;

  if coalesce(v_inbox.payload ->> 'source', '') <> 'round_terminal_game_objectives' then
    return true;
  end if;

  begin
    v_certification_id :=
      nullif(v_inbox.payload ->> 'round_certification_id', '')::uuid;
  exception
    when others then
      return false;
  end;

  if v_certification_id is null then
    return false;
  end if;

  select true
  into v_authorized
  from public.round_certifications rc
  where rc.id = v_certification_id
    and rc.league_round_id = v_inbox.league_round_id
    and rc.status = 'official'
    and rc.active = true
  for share;

  return coalesce(v_authorized, false);
end;
$$;

comment on function public.loyalty_runtime_has_round_authority_internal(uuid)
is 'Returns true for non-round-terminal loyalty events; for round_terminal_game_objectives requires referenced Round Certification to be active official authority for the same League Round.';

revoke all on function public.loyalty_runtime_has_round_authority_internal(uuid)
from public, anon, authenticated;

grant execute on function public.loyalty_runtime_has_round_authority_internal(uuid)
to service_role;

create or replace function public.skip_loyalty_runtime_round_authority_internal(
  p_inbox_event_id uuid,
  p_worker_id text
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_worker_id text := nullif(trim(p_worker_id), '');
  v_inbox public.loyalty_reward_runtime_inbox;
begin
  select *
  into v_inbox
  from public.loyalty_reward_runtime_inbox
  where id = p_inbox_event_id
  for update;

  if not found then
    raise exception using
      errcode = 'P0002',
      message = 'LOYALTY_RUNTIME_INBOX_EVENT_NOT_FOUND';
  end if;

  if v_inbox.event_status in ('rewarded','skipped','dead_letter') then
    return jsonb_build_object(
      'processed', true,
      'already_terminal', true,
      'skipped', v_inbox.event_status = 'skipped',
      'rewarded', v_inbox.event_status = 'rewarded',
      'inbox_event_id', v_inbox.id,
      'event_status', v_inbox.event_status,
      'loyalty_reward_event_id', v_inbox.loyalty_reward_event_id,
      'server_time', clock_timestamp()
    );
  end if;

  if v_inbox.event_status <> 'leased'
     or v_inbox.lease_owner is distinct from v_worker_id
     or v_inbox.lease_expires_at <= clock_timestamp() then
    raise exception using
      errcode = '55000',
      message = 'LOYALTY_RUNTIME_VALID_LEASE_REQUIRED';
  end if;

  update public.loyalty_reward_runtime_inbox
  set
    event_status = 'skipped',
    processed_at = clock_timestamp(),
    lease_owner = null,
    leased_at = null,
    lease_expires_at = null,
    last_error_code = 'LOYALTY_RUNTIME_SUPERSEDED_ROUND_CERTIFICATION',
    last_error_message =
      'Round-terminal reward intent skipped because its referenced Round Certification is not the active official authority.'
  where id = v_inbox.id
  returning * into v_inbox;

  perform public.commercial_append_event_internal(
    'LOYALTY_RUNTIME_EVENT_SKIPPED',
    'LOYALTY_RUNTIME_EVENT',
    v_inbox.id,
    v_inbox.user_id,
    v_inbox.correlation_id,
    v_inbox.causation_id,
    jsonb_build_object(
      'inbox_event_id', v_inbox.id,
      'event_code', v_inbox.event_code,
      'event_status', 'skipped',
      'reason', 'superseded_round_certification',
      'loyalty_reward_event_id', null
    )
  );

  return jsonb_build_object(
    'processed', true,
    'rewarded', false,
    'skipped', true,
    'authority_skipped', true,
    'inbox_event_id', v_inbox.id,
    'event_status', v_inbox.event_status,
    'loyalty_reward_event_id', null,
    'server_time', clock_timestamp()
  );
end;
$$;

comment on function public.skip_loyalty_runtime_round_authority_internal(uuid,text)
is 'Terminalizes a currently leased stale round-terminal loyalty event as skipped without invoking the reward award engine.';

revoke all on function public.skip_loyalty_runtime_round_authority_internal(uuid,text)
from public, anon, authenticated;

grant execute on function public.skip_loyalty_runtime_round_authority_internal(uuid,text)
to service_role;

create or replace function public.dispatch_loyalty_reward_runtime_batch_internal(
  p_worker_id text,
  p_limit integer default 25,
  p_lease_seconds integer default 120
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_limit integer := least(greatest(coalesce(p_limit, 25), 1), 200);
  v_claimed public.loyalty_reward_runtime_inbox;
  v_result jsonb;
  v_results jsonb := '[]'::jsonb;
  v_claimed_count integer := 0;
  v_rewarded_count integer := 0;
  v_skipped_count integer := 0;
  v_authority_skipped_count integer := 0;
  v_retry_count integer := 0;
  v_dead_letter_count integer := 0;
begin
  for v_claimed_count in 1..v_limit loop
    v_claimed :=
      public.claim_next_loyalty_reward_runtime_event_internal(
        p_worker_id,
        p_lease_seconds
      );

    exit when v_claimed.id is null;

    if not public.loyalty_runtime_has_round_authority_internal(
      v_claimed.id
    ) then
      v_result :=
        public.skip_loyalty_runtime_round_authority_internal(
          v_claimed.id,
          p_worker_id
        );
    else
      v_result :=
        public.process_loyalty_reward_runtime_event_internal(
          v_claimed.id,
          p_worker_id
        );
    end if;

    v_results := v_results || jsonb_build_array(v_result);

    if coalesce((v_result ->> 'rewarded')::boolean, false) then
      v_rewarded_count := v_rewarded_count + 1;
    end if;

    if coalesce((v_result ->> 'skipped')::boolean, false) then
      v_skipped_count := v_skipped_count + 1;
    end if;

    if coalesce((v_result ->> 'authority_skipped')::boolean, false) then
      v_authority_skipped_count := v_authority_skipped_count + 1;
    end if;

    if coalesce((v_result ->> 'retry_scheduled')::boolean, false) then
      v_retry_count := v_retry_count + 1;
    end if;

    if coalesce((v_result ->> 'dead_lettered')::boolean, false) then
      v_dead_letter_count := v_dead_letter_count + 1;
    end if;
  end loop;

  return jsonb_build_object(
    'worker_id', p_worker_id,
    'processed_count', jsonb_array_length(v_results),
    'rewarded_count', v_rewarded_count,
    'skipped_count', v_skipped_count,
    'authority_skipped_count', v_authority_skipped_count,
    'retry_scheduled_count', v_retry_count,
    'dead_letter_count', v_dead_letter_count,
    'results', v_results,
    'server_time', clock_timestamp()
  );
end;
$$;

comment on function public.dispatch_loyalty_reward_runtime_batch_internal(text, integer, integer)
is 'Dispatches bounded loyalty runtime events with per-event active Round Certification authority enforcement before award.';

revoke all on function public.dispatch_loyalty_reward_runtime_batch_internal(text, integer, integer)
from public, anon, authenticated;

grant execute on function public.dispatch_loyalty_reward_runtime_batch_internal(text, integer, integer)
to service_role;
