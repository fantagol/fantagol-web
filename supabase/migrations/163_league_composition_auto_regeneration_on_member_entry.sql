-- ============================================================================
-- FANTAGOL
-- MILESTONE 12.9.5.12
-- LEAGUE COMPOSITION AUTO REGENERATION ON MEMBER ENTRY
--
-- Extends the canonical pre-deadline composition governance engine introduced
-- by migration 162.
--
-- Covered entry paths:
--   - private league invite join
--   - public league catalog join
--   - eligible membership reactivation
--   - administrative member reinstatement
--
-- Private and public self-service joins are governed centrally through:
--   public.join_league_membership_internal(...)
--
-- Existing active memberships remain idempotent and do not regenerate.
-- All changes remain atomic with the membership mutation.
-- ============================================================================

begin;
create or replace function public.join_league_membership_internal(
  target_league_id uuid,
  target_user_id uuid,
  member_display_name text,
  join_channel text,
  actor_id uuid,
  occurred_at timestamptz default now()
)
returns table(
  league_id uuid,
  membership_id uuid,
  join_result text
)
language plpgsql
security definer
set search_path to public
as $function$
declare
  v_league public.leagues%rowtype;
  v_existing_member public.league_members%rowtype;
  v_club_id uuid;
  v_member_id uuid;
  v_join_result text;
  v_action_type text;
  v_composition_reason text;
  v_composition_change record;
  v_channel text := lower(trim(coalesce(join_channel, '')));
  v_occurred_at timestamptz := coalesce(occurred_at, now());
begin
  if target_league_id is null then
    raise exception using errcode = 'P0001', message = 'LEAGUE_ID_REQUIRED';
  end if;

  if target_user_id is null then
    raise exception using errcode = 'P0001', message = 'TARGET_USER_REQUIRED';
  end if;

  if actor_id is null then
    raise exception using errcode = 'P0001', message = 'ACTOR_REQUIRED';
  end if;

  if actor_id <> target_user_id and v_channel in ('invite', 'public_catalog') then
    raise exception using errcode = 'P0001', message = 'SELF_SERVICE_ACTOR_MISMATCH';
  end if;

  if nullif(trim(member_display_name), '') is null then
    raise exception using errcode = 'P0001', message = 'DISPLAY_NAME_REQUIRED';
  end if;

  if v_channel not in ('invite', 'public_catalog', 'admin_reinstate', 'system') then
    raise exception using errcode = 'P0001', message = 'INVALID_JOIN_CHANNEL';
  end if;

  select l.*
  into v_league
  from public.leagues l
  where l.id = target_league_id
  for update;

  if v_league.id is null then
    raise exception using errcode = 'P0001', message = 'LEAGUE_NOT_FOUND';
  end if;

  if v_league.status <> 'active'
     or v_league.lifecycle_status in ('completed', 'archived') then
    raise exception using errcode = 'P0001', message = 'LEAGUE_NOT_JOINABLE';
  end if;

  select lm.*
  into v_existing_member
  from public.league_members lm
  where lm.league_id = v_league.id
    and lm.user_id = target_user_id
  limit 1
  for update;

  if v_existing_member.id is not null then
    if v_existing_member.status = 'removed'
       and v_channel in ('invite', 'public_catalog') then
      raise exception using
        errcode = 'P0001',
        message = 'LEAGUE_MEMBER_REMOVED_REQUIRES_REINSTATEMENT';
    end if;

    if v_existing_member.status = 'active' then
      update public.profiles
      set last_active_league_id = v_league.id
      where id = target_user_id;

      return query
      select
        v_league.id,
        v_existing_member.id,
        'already_active'::text;

      return;
    end if;

    update public.league_members
    set
      status = 'active',
      display_name = trim(member_display_name)
    where id = v_existing_member.id
    returning id into v_member_id;

    v_join_result := 'reactivated';
    v_action_type := 'member_rejoined';
  else
    if v_league.roster_status <> 'open'
       or v_league.lifecycle_status not in ('draft', 'open') then
      raise exception using errcode = 'P0001', message = 'LEAGUE_ROSTER_CLOSED';
    end if;

    select c.id
    into v_club_id
    from public.clubs c
    where c.owner_id = target_user_id
    order by c.created_at, c.id
    limit 1;

    if v_club_id is null then
      insert into public.clubs (owner_id, name)
      values (target_user_id, 'FantaGol Club')
      returning id into v_club_id;
    end if;

    insert into public.league_members (
      league_id,
      user_id,
      club_id,
      display_name,
      role,
      status
    )
    values (
      v_league.id,
      target_user_id,
      v_club_id,
      trim(member_display_name),
      'member',
      'active'
    )
    returning id into v_member_id;

    v_join_result := 'created';
    v_action_type := 'member_joined';
  end if;

  update public.profiles
  set last_active_league_id = v_league.id
  where id = target_user_id;

  v_composition_reason :=
    case v_join_result
      when 'created' then 'MEMBER_JOINED'
      when 'reactivated' then 'MEMBER_RESTORED'
      else null
    end;

  if v_composition_reason is not null then
    select *
    into v_composition_change
    from public.apply_league_composition_change(
      v_league.id,
      v_composition_reason
    );
  end if;

  perform public.write_league_admin_event(
    v_league.id,
    v_member_id,
    actor_id,
    'member',
    v_action_type,
    v_member_id,
    null,
    jsonb_build_object(
      'join_channel', v_channel,
      'join_result', v_join_result,
      'occurred_at', v_occurred_at,
      'missed_rounds_recovered', false,
      'calendar_changed', coalesce(v_composition_change.calendar_changed, false)
    )
  );

  return query
  select
    v_league.id,
    v_member_id,
    v_join_result;
end;
$function$;

create or replace function public.reinstate_league_member_rpc(
  target_league_id uuid,
  target_member_id uuid
)
returns void
language plpgsql
security definer
set search_path to public
as $function$
declare
  v_user_id uuid := auth.uid();
  v_admin_member_id uuid;
  v_target public.league_members%rowtype;
  v_composition_change record;
begin
  if v_user_id is null then
    raise exception using errcode = 'P0001', message = 'AUTH_REQUIRED';
  end if;

  v_admin_member_id := public.get_active_admin_member_id(target_league_id, v_user_id);
  if v_admin_member_id is null then
    raise exception using errcode = 'P0001', message = 'ACTIVE_ADMIN_REQUIRED';
  end if;

  select lm.*
  into v_target
  from public.league_members lm
  where lm.id = target_member_id
    and lm.league_id = target_league_id
    and lm.status = 'removed'
  for update;

  if v_target.id is null then
    raise exception using errcode = 'P0001', message = 'REMOVED_MEMBER_NOT_FOUND';
  end if;

  update public.league_members
  set
    status = 'active',
    role = 'member'
  where id = target_member_id;

  select *
  into v_composition_change
  from public.apply_league_composition_change(
    target_league_id,
    'MEMBER_RESTORED'
  );

  perform public.write_league_admin_event(
    target_league_id,
    v_admin_member_id,
    v_user_id,
    'member',
    'member_reinstated',
    target_member_id,
    null,
    jsonb_build_object(
      'missed_rounds_recovered', false,
      'calendar_changed', coalesce(v_composition_change.calendar_changed, false)
    )
  );
end;
$function$;
comment on function public.join_league_membership_internal(
  uuid,
  uuid,
  text,
  text,
  uuid,
  timestamptz
) is
  'Canonical private/public membership entry path with atomic pre-deadline league composition regeneration.';

comment on function public.reinstate_league_member_rpc(
  uuid,
  uuid
) is
  'Administrative member reinstatement with atomic pre-deadline league composition regeneration.';

commit;