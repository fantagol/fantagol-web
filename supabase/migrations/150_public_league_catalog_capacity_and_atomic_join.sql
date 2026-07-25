-- ============================================================================
-- FANTAGOL
-- MIGRATION 150
-- PUBLIC LEAGUE CATALOG CAPACITY AND ATOMIC JOIN
--
-- Milestone 12.9.5.3
--
-- Covers:
--   - capacity-aware protected public league catalog
--   - public registration state in catalog responses
--   - human-facing catalog status contract
--   - completion-oriented catalog ordering
--   - atomic public join capacity enforcement
--   - first-round-start protection for public joins
--
-- Does not:
--   - change private invitation joins
--   - introduce automatic registration closure
--   - change league schedules or BYE handling
--   - expose internal identifiers through the public catalog
-- ============================================================================

begin;

-- ----------------------------------------------------------------------------
-- 1. CAPACITY-AWARE PROTECTED PUBLIC CATALOG READ MODEL
-- ----------------------------------------------------------------------------

create or replace view public.public_league_catalog_v1
with (security_invoker = false)
as
select
  l.id as league_id,
  l.name as league_name,
  l.edition_id,
  coalesce(
    nullif(to_jsonb(ce) ->> 'label', ''),
    nullif(to_jsonb(ce) ->> 'name', ''),
    ce.id::text
  ) as edition_label,
  l.owner_id as admin_user_id,
  admin_member.display_name as admin_display_name,
  coalesce(member_counts.active_member_count, 0)::integer
    as active_member_count,
  l.roster_status,
  case
    when (
      l.first_scored_at is not null
      or (
        start_round.lock_at is not null
        and clock_timestamp() >= start_round.lock_at
      )
    ) then 'started'

    when coalesce(member_counts.active_member_count, 0)
         >= l.max_participants then 'full'

    when l.public_registrations_open = false
      or l.roster_status <> 'open'
      or l.lifecycle_status not in ('draft', 'open')
      then 'closed'

    else 'open'
  end as join_status,
  l.visibility,
  l.starts_from_fantagol_round_id,
  start_round.name as starts_from_round_name,
  start_round.sequence as starts_from_round_sequence,
  l.first_useful_kickoff_at,
  l.automatic_join_close_at,
  l.lifecycle_status,
  l.status as league_status,
  l.created_at,
  l.max_participants,
  l.public_registrations_open,
  greatest(
    l.max_participants
      - coalesce(member_counts.active_member_count, 0),
    0
  )::integer as available_slots,
  (
    l.first_scored_at is not null
    or (
      start_round.lock_at is not null
      and clock_timestamp() >= start_round.lock_at
    )
  ) as competition_started
from public.leagues l
join public.competition_editions ce
  on ce.id = l.edition_id
left join public.fantagol_rounds start_round
  on start_round.id = l.starts_from_fantagol_round_id
left join lateral (
  select lm.display_name
  from public.league_members lm
  where lm.league_id = l.id
    and lm.role = 'admin'
    and lm.status = 'active'
  order by lm.id
  limit 1
) admin_member on true
left join lateral (
  select count(*)::integer as active_member_count
  from public.league_members lm
  where lm.league_id = l.id
    and lm.status = 'active'
) member_counts on true
where l.visibility = 'public'
  and l.status = 'active'
  and l.lifecycle_status <> 'archived'
  and ce.active = true
  and ce.status in ('scheduled', 'active');

comment on view public.public_league_catalog_v1
is
'Protected capacity-aware read model for public leagues. It derives open, closed, full and started catalog states without exposing private administration identifiers to clients.';

revoke all on public.public_league_catalog_v1 from public;
revoke all on public.public_league_catalog_v1 from anon;
revoke all on public.public_league_catalog_v1 from authenticated;

-- ----------------------------------------------------------------------------
-- 2. CAPACITY-AWARE AUTHENTICATED PUBLIC CATALOG RPC
--
-- The function signature remains unchanged for frontend compatibility.
-- Its returned record is extended with capacity and catalog-state fields.
--
-- The legacy created_at cursor cannot represent the completion-oriented
-- ordering key. Non-null cursors are therefore rejected explicitly until
-- a complete composite cursor contract is introduced.
-- ----------------------------------------------------------------------------

drop function if exists public.get_public_leagues_rpc(
  integer,
  timestamptz,
  uuid,
  text
);

create function public.get_public_leagues_rpc(
  page_size integer default 30,
  cursor_created_at timestamptz default null,
  cursor_league_id uuid default null,
  roster_filter text default 'all'
)
returns table(
  league_id uuid,
  league_name text,
  edition_id uuid,
  edition_label text,
  admin_display_name text,
  active_member_count integer,
  roster_status text,
  join_status text,
  visibility text,
  starts_from_fantagol_round_id uuid,
  starts_from_round_name text,
  starts_from_round_sequence integer,
  first_useful_kickoff_at timestamptz,
  automatic_join_close_at timestamptz,
  lifecycle_status text,
  league_status text,
  created_at timestamptz,
  viewer_membership_status text,
  viewer_is_member boolean,
  viewer_can_join boolean,
  max_participants integer,
  public_registrations_open boolean,
  available_slots integer,
  competition_started boolean,
  catalog_status text
)
language plpgsql
stable
security definer
set search_path to public
as $function$
declare
  v_user_id uuid := auth.uid();
  v_page_size integer := coalesce(page_size, 30);
  v_roster_filter text :=
    lower(trim(coalesce(roster_filter, 'all')));
begin
  if v_user_id is null then
    raise exception using
      errcode = 'P0001',
      message = 'AUTH_REQUIRED';
  end if;

  if v_page_size < 1 or v_page_size > 100 then
    raise exception using
      errcode = 'P0001',
      message = 'PUBLIC_LEAGUE_INVALID_PAGE_SIZE';
  end if;

  if v_roster_filter not in ('all', 'open', 'locked') then
    raise exception using
      errcode = 'P0001',
      message = 'PUBLIC_LEAGUE_INVALID_ROSTER_FILTER';
  end if;

  if cursor_created_at is not null
     or cursor_league_id is not null then
    raise exception using
      errcode = 'P0001',
      message =
        'PUBLIC_LEAGUE_COMPLETION_ORDER_CURSOR_NOT_SUPPORTED';
  end if;

  return query
  select
    c.league_id,
    c.league_name,
    c.edition_id,
    c.edition_label,
    c.admin_display_name,
    c.active_member_count,
    c.roster_status,
    c.join_status,
    c.visibility,
    c.starts_from_fantagol_round_id,
    c.starts_from_round_name,
    c.starts_from_round_sequence,
    c.first_useful_kickoff_at,
    c.automatic_join_close_at,
    c.lifecycle_status,
    c.league_status,
    c.created_at,
    viewer_member.status as viewer_membership_status,
    (viewer_member.status = 'active') as viewer_is_member,
    (
      viewer_member.id is null
      and c.join_status = 'open'
    ) as viewer_can_join,
    c.max_participants,
    c.public_registrations_open,
    c.available_slots,
    c.competition_started,
    case c.join_status
      when 'started' then 'competition_started'
      when 'full' then 'full'
      when 'closed' then 'registrations_closed'
      else 'registrations_open'
    end as catalog_status
  from public.public_league_catalog_v1 c
  left join public.league_members viewer_member
    on viewer_member.league_id = c.league_id
   and viewer_member.user_id = v_user_id
  where (
      v_roster_filter = 'all'
      or (
        v_roster_filter = 'open'
        and c.join_status = 'open'
      )
      or (
        v_roster_filter = 'locked'
        and c.join_status <> 'open'
      )
    )
  order by
    case c.join_status
      when 'open' then 1
      when 'closed' then 2
      when 'full' then 3
      when 'started' then 4
      else 5
    end asc,

    case
      when c.join_status = 'open'
        then c.available_slots
      else null
    end asc nulls last,

    case
      when c.join_status = 'open'
        then (
          c.active_member_count::numeric
          / nullif(c.max_participants, 0)::numeric
        )
      else null
    end desc nulls last,

    c.created_at asc,
    lower(c.league_name) asc,
    c.league_id asc
  limit v_page_size;
end;
$function$;

comment on function public.get_public_leagues_rpc(
  integer,
  timestamptz,
  uuid,
  text
)
is
'Returns the authenticated public league catalog with finite capacity, effective registration state, human-facing status and completion-oriented ordering. Legacy created-at cursors are rejected because they cannot safely represent the new composite ordering key.';

revoke all on function public.get_public_leagues_rpc(
  integer,
  timestamptz,
  uuid,
  text
) from public;

revoke all on function public.get_public_leagues_rpc(
  integer,
  timestamptz,
  uuid,
  text
) from anon;

grant execute on function public.get_public_leagues_rpc(
  integer,
  timestamptz,
  uuid,
  text
) to authenticated;

grant execute on function public.get_public_leagues_rpc(
  integer,
  timestamptz,
  uuid,
  text
) to service_role;

-- ----------------------------------------------------------------------------
-- 3. ATOMIC PUBLIC JOIN CAPACITY CONTRACT
--
-- The league row is locked before checking:
--   - registration switch
--   - lifecycle and roster
--   - first-round start
--   - active member capacity
--
-- Existing active memberships remain idempotent.
-- Reactivations and new memberships consume one capacity slot.
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
  v_existing_member public.league_members%rowtype;
  v_start_round_lock_at timestamptz;
  v_edition_visible boolean;
  v_active_member_count integer;
  v_join record;
  v_error_message text;
begin
  if v_user_id is null then
    raise exception using
      errcode = 'P0001',
      message = 'AUTH_REQUIRED';
  end if;

  if target_league_id is null then
    raise exception using
      errcode = 'P0001',
      message = 'PUBLIC_LEAGUE_NOT_FOUND';
  end if;

  if nullif(trim(member_display_name), '') is null then
    raise exception using
      errcode = 'P0001',
      message = 'DISPLAY_NAME_REQUIRED';
  end if;

  select l.*
  into v_league
  from public.leagues l
  where l.id = target_league_id
  for update;

  if v_league.id is null
     or v_league.status <> 'active'
     or v_league.lifecycle_status = 'archived' then
    raise exception using
      errcode = 'P0001',
      message = 'PUBLIC_LEAGUE_NOT_FOUND';
  end if;

  if v_league.visibility <> 'public' then
    raise exception using
      errcode = 'P0001',
      message = 'PUBLIC_LEAGUE_NOT_PUBLIC';
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
    raise exception using
      errcode = 'P0001',
      message = 'PUBLIC_LEAGUE_NOT_JOINABLE';
  end if;

  select lm.*
  into v_existing_member
  from public.league_members lm
  where lm.league_id = v_league.id
    and lm.user_id = v_user_id
  limit 1
  for update;

  -- Existing active membership remains idempotent even when the league
  -- has subsequently become full, closed or started.
  if v_existing_member.id is null
     or v_existing_member.status <> 'active' then

    if v_existing_member.status = 'removed' then
      raise exception using
        errcode = 'P0001',
        message =
          'LEAGUE_MEMBER_REMOVED_REQUIRES_REINSTATEMENT';
    end if;

    if v_league.public_registrations_open is distinct from true then
      raise exception using
        errcode = 'P0001',
        message = 'PUBLIC_LEAGUE_REGISTRATIONS_CLOSED';
    end if;

    if v_league.roster_status <> 'open'
       or v_league.lifecycle_status not in ('draft', 'open') then
      raise exception using
        errcode = 'P0001',
        message = 'PUBLIC_LEAGUE_ROSTER_LOCKED';
    end if;

    select fr.lock_at
    into v_start_round_lock_at
    from public.fantagol_rounds fr
    where fr.id = v_league.starts_from_fantagol_round_id
      and fr.edition_id = v_league.edition_id
    limit 1;

    if v_league.first_scored_at is not null
       or v_start_round_lock_at is null
       or clock_timestamp() >= v_start_round_lock_at then
      raise exception using
        errcode = 'P0001',
        message = 'PUBLIC_LEAGUE_COMPETITION_STARTED';
    end if;

    select count(*)::integer
    into v_active_member_count
    from public.league_members lm
    where lm.league_id = v_league.id
      and lm.status = 'active';

    if v_league.max_participants is null
       or v_league.max_participants < 2
       or v_league.max_participants > 20 then
      raise exception using
        errcode = 'P0001',
        message =
          'PUBLIC_LEAGUE_INVALID_MAX_PARTICIPANTS';
    end if;

    if v_active_member_count >= v_league.max_participants then
      raise exception using
        errcode = 'P0001',
        message = 'PUBLIC_LEAGUE_FULL';
    end if;
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
      clock_timestamp()
    );
  exception
    when others then
      get stacked diagnostics
        v_error_message = message_text;

      if v_error_message =
         'LEAGUE_MEMBER_REMOVED_REQUIRES_REINSTATEMENT' then
        raise exception using
          errcode = 'P0001',
          message =
            'LEAGUE_MEMBER_REMOVED_REQUIRES_REINSTATEMENT';

      elsif v_error_message = 'LEAGUE_ROSTER_CLOSED' then
        raise exception using
          errcode = 'P0001',
          message = 'PUBLIC_LEAGUE_ROSTER_LOCKED';

      elsif v_error_message in (
        'LEAGUE_NOT_FOUND',
        'LEAGUE_NOT_JOINABLE'
      ) then
        raise exception using
          errcode = 'P0001',
          message = 'PUBLIC_LEAGUE_NOT_JOINABLE';

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
is
'Atomically joins an authenticated user to a visible public league while enforcing administrator registration state, first-round start and finite active-member capacity.';

revoke all on function public.join_public_league_rpc(uuid, text)
  from public;

revoke all on function public.join_public_league_rpc(uuid, text)
  from anon;

grant execute on function public.join_public_league_rpc(uuid, text)
  to authenticated;

grant execute on function public.join_public_league_rpc(uuid, text)
  to service_role;

-- ----------------------------------------------------------------------------
-- 4. DATABASE CERTIFICATION
-- ----------------------------------------------------------------------------

do $verification$
declare
  v_invalid_capacity_rows integer;
  v_over_capacity_leagues integer;
  v_catalog_column_count integer;
  v_catalog_function_count integer;
  v_join_function_count integer;
  v_view_definition text;
  v_catalog_definition text;
  v_join_definition text;
begin
  select count(*)::integer
  into v_invalid_capacity_rows
  from public.leagues l
  where l.visibility = 'public'
    and (
      l.max_participants is null
      or l.max_participants < 2
      or l.max_participants > 20
      or l.public_registrations_open is null
    );

  if v_invalid_capacity_rows <> 0 then
    raise exception
      'INVALID_PUBLIC_LEAGUE_CAPACITY_ROWS: %',
      v_invalid_capacity_rows;
  end if;

  select count(*)::integer
  into v_over_capacity_leagues
  from public.leagues l
  where l.visibility = 'public'
    and (
      select count(*)
      from public.league_members lm
      where lm.league_id = l.id
        and lm.status = 'active'
    ) > l.max_participants;

  if v_over_capacity_leagues <> 0 then
    raise exception
      'PUBLIC_LEAGUES_ALREADY_OVER_CAPACITY: %',
      v_over_capacity_leagues;
  end if;

  select count(*)::integer
  into v_catalog_column_count
  from information_schema.columns c
  where c.table_schema = 'public'
    and c.table_name = 'public_league_catalog_v1'
    and c.column_name in (
      'max_participants',
      'public_registrations_open',
      'available_slots',
      'competition_started',
      'join_status'
    );

  if v_catalog_column_count <> 5 then
    raise exception
      'PUBLIC_LEAGUE_CATALOG_CAPACITY_COLUMNS_MISSING';
  end if;

  select count(*)::integer
  into v_catalog_function_count
  from pg_proc p
  join pg_namespace n
    on n.oid = p.pronamespace
  where n.nspname = 'public'
    and p.proname = 'get_public_leagues_rpc'
    and pg_get_function_identity_arguments(p.oid) =
      'page_size integer, cursor_created_at timestamp with time zone, cursor_league_id uuid, roster_filter text';

  if v_catalog_function_count <> 1 then
    raise exception
      'PUBLIC_LEAGUE_CATALOG_RPC_SIGNATURE_INVALID';
  end if;

  select count(*)::integer
  into v_join_function_count
  from pg_proc p
  join pg_namespace n
    on n.oid = p.pronamespace
  where n.nspname = 'public'
    and p.proname = 'join_public_league_rpc'
    and pg_get_function_identity_arguments(p.oid) =
      'target_league_id uuid, member_display_name text';

  if v_join_function_count <> 1 then
    raise exception
      'PUBLIC_LEAGUE_JOIN_RPC_SIGNATURE_INVALID';
  end if;

  select pg_get_viewdef(
    'public.public_league_catalog_v1'::regclass,
    true
  )
  into v_view_definition;

  if position('max_participants' in v_view_definition) = 0
     or position(
       'public_registrations_open'
       in v_view_definition
     ) = 0
     or position('available_slots' in v_view_definition) = 0 then
    raise exception
      'PUBLIC_LEAGUE_CATALOG_VIEW_CONTRACT_INVALID';
  end if;

  select pg_get_functiondef(p.oid)
  into v_catalog_definition
  from pg_proc p
  join pg_namespace n
    on n.oid = p.pronamespace
  where n.nspname = 'public'
    and p.proname = 'get_public_leagues_rpc'
    and pg_get_function_identity_arguments(p.oid) =
      'page_size integer, cursor_created_at timestamp with time zone, cursor_league_id uuid, roster_filter text';

  if position('c.available_slots' in v_catalog_definition) = 0
     or position(
       'c.active_member_count::numeric'
       in v_catalog_definition
     ) = 0
     or position(
       'c.created_at asc'
       in v_catalog_definition
     ) = 0
     or position(
       'PUBLIC_LEAGUE_COMPLETION_ORDER_CURSOR_NOT_SUPPORTED'
       in v_catalog_definition
     ) = 0
     or position(
       '(c.created_at, c.league_id)'
       in v_catalog_definition
     ) <> 0 then
    raise exception
      'PUBLIC_LEAGUE_COMPLETION_ORDER_INVALID';
  end if;

  select pg_get_functiondef(p.oid)
  into v_join_definition
  from pg_proc p
  join pg_namespace n
    on n.oid = p.pronamespace
  where n.nspname = 'public'
    and p.proname = 'join_public_league_rpc'
    and pg_get_function_identity_arguments(p.oid) =
      'target_league_id uuid, member_display_name text';

  if position(
       'PUBLIC_LEAGUE_REGISTRATIONS_CLOSED'
       in v_join_definition
     ) = 0
     or position(
       'PUBLIC_LEAGUE_COMPETITION_STARTED'
       in v_join_definition
     ) = 0
     or position(
       'PUBLIC_LEAGUE_FULL'
       in v_join_definition
     ) = 0
     or position(
       'for update'
       in lower(v_join_definition)
     ) = 0 then
    raise exception
      'PUBLIC_LEAGUE_ATOMIC_JOIN_CONTRACT_INVALID';
  end if;

  raise notice
    'PUBLIC_LEAGUE_CATALOG_CAPACITY_AND_ATOMIC_JOIN_OK';
end;
$verification$;

commit;