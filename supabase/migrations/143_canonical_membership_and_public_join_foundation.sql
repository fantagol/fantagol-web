-- ============================================================================
-- FANTAGOL
-- MIGRATION 143
-- CANONICAL MEMBERSHIP AND PUBLIC JOIN FOUNDATION
--
-- Milestone 12.6
--
-- Covers:
--   - canonical transactional league membership join function
--   - legacy invite join refactor onto the canonical function
--   - authenticated public league join RPC
--   - idempotent active membership handling
--   - left membership reactivation
--   - removed membership self-service protection
--
-- Does not cover yet:
--   - authenticated invitation continuation
--   - post-login entry routing
--   - public catalog UI
--   - automatic roster closure workflow
--   - inactivity cleanup workflow
-- ============================================================================

begin;

-- ----------------------------------------------------------------------------
-- 1. CANONICAL MEMBERSHIP JOIN FUNCTION
-- ----------------------------------------------------------------------------

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
      'calendar_changed', false
    )
  );

  return query
  select
    v_league.id,
    v_member_id,
    v_join_result;
end;
$function$;

comment on function public.join_league_membership_internal(
  uuid,
  uuid,
  text,
  text,
  uuid,
  timestamptz
)
is 'Canonical transactional membership join function shared by invite and public catalog channels. Returns already_active, reactivated, or created.';

-- ----------------------------------------------------------------------------
-- 2. LEGACY INVITE JOIN COMPATIBILITY WRAPPER
-- ----------------------------------------------------------------------------

create or replace function public.join_league_rpc(
  target_invite_code text,
  member_display_name text
)
returns table(joined_league_id uuid)
language plpgsql
security definer
set search_path to public
as $function$
declare
  v_user_id uuid := auth.uid();
  v_league_id uuid;
  v_error_message text;
begin
  if v_user_id is null then
    raise exception using errcode = 'P0001', message = 'AUTH_REQUIRED';
  end if;

  if nullif(trim(target_invite_code), '') is null then
    raise exception using errcode = 'P0001', message = 'INVITE_CODE_REQUIRED';
  end if;

  if nullif(trim(member_display_name), '') is null then
    raise exception using errcode = 'P0001', message = 'DISPLAY_NAME_REQUIRED';
  end if;

  select l.id
  into v_league_id
  from public.leagues l
  where upper(l.invite_code) = upper(trim(target_invite_code))
    and l.status = 'active'
    and l.lifecycle_status not in ('completed', 'archived')
  order by l.id
  limit 1;

  if v_league_id is null then
    raise exception using errcode = 'P0001', message = 'INVALID_OR_EXPIRED_INVITE_CODE';
  end if;

  begin
    perform *
    from public.join_league_membership_internal(
      v_league_id,
      v_user_id,
      member_display_name,
      'invite',
      v_user_id,
      now()
    );
  exception
    when others then
      get stacked diagnostics v_error_message = message_text;

      if v_error_message = 'LEAGUE_MEMBER_REMOVED_REQUIRES_REINSTATEMENT' then
        raise exception using errcode = 'P0001', message = 'ADMIN_REINSTATEMENT_REQUIRED';
      elsif v_error_message in ('LEAGUE_NOT_FOUND', 'LEAGUE_NOT_JOINABLE') then
        raise exception using errcode = 'P0001', message = 'INVALID_OR_EXPIRED_INVITE_CODE';
      elsif v_error_message = 'LEAGUE_ROSTER_CLOSED' then
        raise exception using errcode = 'P0001', message = 'LEAGUE_ROSTER_CLOSED';
      else
        raise;
      end if;
  end;

  return query select v_league_id;
end;
$function$;

comment on function public.join_league_rpc(text, text)
is 'Legacy invite join RPC preserved for frontend compatibility and routed through the canonical membership join function.';

-- ----------------------------------------------------------------------------
-- 3. AUTHENTICATED PUBLIC LEAGUE JOIN RPC
-- ----------------------------------------------------------------------------

create or replace function public.join_public_league_rpc(
  target_league_id uuid,
  member_display_name text
)
returns table(
  joined_league_id uuid,
  membership_id uuid,
  join_result text
)
language plpgsql
security definer
set search_path to public
as $function$
declare
  v_user_id uuid := auth.uid();
  v_league public.leagues%rowtype;
  v_edition_visible boolean;
  v_join record;
  v_error_message text;
begin
  if v_user_id is null then
    raise exception using errcode = 'P0001', message = 'AUTH_REQUIRED';
  end if;

  if target_league_id is null then
    raise exception using errcode = 'P0001', message = 'PUBLIC_LEAGUE_NOT_FOUND';
  end if;

  if nullif(trim(member_display_name), '') is null then
    raise exception using errcode = 'P0001', message = 'DISPLAY_NAME_REQUIRED';
  end if;

  select l.*
  into v_league
  from public.leagues l
  where l.id = target_league_id
  for update;

  if v_league.id is null
     or v_league.status <> 'active'
     or v_league.lifecycle_status = 'archived' then
    raise exception using errcode = 'P0001', message = 'PUBLIC_LEAGUE_NOT_FOUND';
  end if;

  if v_league.visibility <> 'public' then
    raise exception using errcode = 'P0001', message = 'PUBLIC_LEAGUE_NOT_PUBLIC';
  end if;

  select exists (
    select 1
    from public.competition_editions ce
    join public.competitions c
      on c.id = ce.competition_id
    where ce.id = v_league.edition_id
      and ce.active = true
      and ce.status in ('scheduled', 'active')
      and c.enabled = true
  )
  into v_edition_visible;

  if not coalesce(v_edition_visible, false) then
    raise exception using errcode = 'P0001', message = 'PUBLIC_LEAGUE_NOT_JOINABLE';
  end if;

  begin
    select *
    into v_join
    from public.join_league_membership_internal(
      v_league.id,
      v_user_id,
      member_display_name,
      'public_catalog',
      v_user_id,
      now()
    );
  exception
    when others then
      get stacked diagnostics v_error_message = message_text;

      if v_error_message = 'LEAGUE_MEMBER_REMOVED_REQUIRES_REINSTATEMENT' then
        raise exception using
          errcode = 'P0001',
          message = 'LEAGUE_MEMBER_REMOVED_REQUIRES_REINSTATEMENT';
      elsif v_error_message = 'LEAGUE_ROSTER_CLOSED' then
        raise exception using errcode = 'P0001', message = 'PUBLIC_LEAGUE_ROSTER_LOCKED';
      elsif v_error_message in ('LEAGUE_NOT_FOUND', 'LEAGUE_NOT_JOINABLE') then
        raise exception using errcode = 'P0001', message = 'PUBLIC_LEAGUE_NOT_JOINABLE';
      else
        raise;
      end if;
  end;

  return query
  select
    v_join.league_id,
    v_join.membership_id,
    v_join.join_result;
end;
$function$;

comment on function public.join_public_league_rpc(uuid, text)
is 'Atomically joins an authenticated user to a visible public league through the canonical membership join foundation.';

-- ----------------------------------------------------------------------------
-- 4. PRIVILEGE BOUNDARY
-- ----------------------------------------------------------------------------

revoke all on function public.join_league_membership_internal(
  uuid,
  uuid,
  text,
  text,
  uuid,
  timestamptz
) from public;

revoke all on function public.join_league_membership_internal(
  uuid,
  uuid,
  text,
  text,
  uuid,
  timestamptz
) from anon;

revoke all on function public.join_league_membership_internal(
  uuid,
  uuid,
  text,
  text,
  uuid,
  timestamptz
) from authenticated;

grant execute on function public.join_league_membership_internal(
  uuid,
  uuid,
  text,
  text,
  uuid,
  timestamptz
) to service_role;

revoke all on function public.join_league_rpc(text, text) from public;
revoke all on function public.join_league_rpc(text, text) from anon;
grant execute on function public.join_league_rpc(text, text) to authenticated;
grant execute on function public.join_league_rpc(text, text) to service_role;

revoke all on function public.join_public_league_rpc(uuid, text) from public;
revoke all on function public.join_public_league_rpc(uuid, text) from anon;
grant execute on function public.join_public_league_rpc(uuid, text) to authenticated;
grant execute on function public.join_public_league_rpc(uuid, text) to service_role;

commit;
