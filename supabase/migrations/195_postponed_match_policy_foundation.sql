-- ============================================================================
-- FANTAGOL
-- Migration 195
-- Postponed Match Policy Foundation
--
-- Adds the league-level administrative preference used when a Match belonging
-- to a League Round is postponed.
--
-- Canonical policies:
--
--   wait_keep_predictions
--     Wait for the rescheduled Match and preserve every Prediction already
--     acquired for that Match.
--
--   wait_reopen_predictions
--     Wait for the rescheduled Match and reopen only the Predictions belonging
--     to that Match. Other Round Predictions remain locked and acquired.
--
--   exclude_from_round
--     Exclude the postponed Match from the League Round calculation so that the
--     Round may proceed without waiting for the rescheduled Match.
--
-- This migration creates the configuration contract only.
-- Automatic provider-driven application and per-Match administrative commands
-- are completed by subsequent runtime migrations.
-- ============================================================================

begin;

-- ============================================================================
-- 1. CANONICAL LEAGUE POLICY
-- ============================================================================

create table if not exists public.league_postponed_match_policies (
  league_id uuid primary key
    references public.leagues(id)
    on delete cascade,

  policy text not null
    default 'wait_reopen_predictions',

  updated_by_member_id uuid
    references public.league_members(id)
    on delete set null,

  reason text,

  version integer not null
    default 1,

  created_at timestamptz not null
    default now(),

  updated_at timestamptz not null
    default now(),

  constraint league_postponed_match_policies_policy_check
    check (
      policy in (
        'wait_keep_predictions',
        'wait_reopen_predictions',
        'exclude_from_round'
      )
    ),

  constraint league_postponed_match_policies_version_positive_check
    check (version > 0),

  constraint league_postponed_match_policies_reason_length_check
    check (
      reason is null
      or char_length(reason) <= 500
    )
);

comment on table public.league_postponed_match_policies is
  'Canonical league-level preference for postponed Match governance.';

comment on column public.league_postponed_match_policies.policy is
  'wait_keep_predictions, wait_reopen_predictions, or exclude_from_round.';

comment on column public.league_postponed_match_policies.reason is
  'Optional administrator explanation recorded with the latest policy change.';

alter table public.league_postponed_match_policies
  alter column policy
  set default 'wait_reopen_predictions';

-- Align only untouched installation defaults.
update public.league_postponed_match_policies
set
  policy = 'wait_reopen_predictions',
  reason = 'Default policy aligned by migration 195',
  updated_at = now()
where version = 1
  and updated_by_member_id is null
  and policy = 'wait_keep_predictions'
  and reason in (
    'Default policy installed by migration 195',
    'Default policy created with the league',
    'Default policy created during first update'
  );

-- Existing leagues receive the flexible default policy.
insert into public.league_postponed_match_policies (
  league_id,
  policy,
  updated_by_member_id,
  reason,
  version,
  created_at,
  updated_at
)
select
  l.id,
  'wait_reopen_predictions',
  null,
  'Default policy installed by migration 195',
  1,
  now(),
  now()
from public.leagues l
on conflict on constraint
    league_postponed_match_policies_pkey
  do nothing;

-- ============================================================================
-- 2. DEFAULT POLICY FOR FUTURE LEAGUES
-- ============================================================================

create or replace function public.create_default_postponed_match_policy_internal()
returns trigger
language plpgsql
security definer
set search_path to public, pg_temp
as $function$
begin
  insert into public.league_postponed_match_policies (
    league_id,
    policy,
    updated_by_member_id,
    reason,
    version,
    created_at,
    updated_at
  )
  values (
    new.id,
    'wait_reopen_predictions',
    null,
    'Default policy created with the league',
    1,
    now(),
    now()
  )
  on conflict on constraint
    league_postponed_match_policies_pkey
  do nothing;

  return new;
end;
$function$;

revoke all on function
  public.create_default_postponed_match_policy_internal()
from public;

drop trigger if exists create_default_postponed_match_policy
  on public.leagues;

create trigger create_default_postponed_match_policy
after insert on public.leagues
for each row
execute function
  public.create_default_postponed_match_policy_internal();

-- ============================================================================
-- 3. ROW LEVEL SECURITY
-- ============================================================================

alter table public.league_postponed_match_policies
  enable row level security;

drop policy if exists
  league_postponed_match_policies_select_members
on public.league_postponed_match_policies;

create policy
  league_postponed_match_policies_select_members
on public.league_postponed_match_policies
for select
to authenticated
using (
  exists (
    select 1
    from public.league_members lm
    where lm.league_id =
      league_postponed_match_policies.league_id
      and lm.user_id = auth.uid()
      and lm.status = 'active'
  )
);

revoke all on table
  public.league_postponed_match_policies
from public;

grant select on table
  public.league_postponed_match_policies
to authenticated;

-- Direct writes remain forbidden.
revoke insert, update, delete on table
  public.league_postponed_match_policies
from authenticated;

-- ============================================================================
-- 4. MEMBER READ CONTRACT
-- ============================================================================

create or replace function
  public.get_my_league_postponed_match_policy_rpc(
    target_league_id uuid
  )
returns table(
  league_id uuid,
  policy text,
  policy_version integer,
  reason text,
  updated_by_member_id uuid,
  updated_at timestamptz,
  can_manage boolean
)
language plpgsql
stable
security definer
set search_path to public, pg_temp
as $function$
declare
  v_user_id uuid := auth.uid();
  v_member public.league_members%rowtype;
begin
  if v_user_id is null then
    raise exception using
      errcode = 'P0001',
      message = 'AUTH_REQUIRED';
  end if;

  if target_league_id is null then
    raise exception using
      errcode = 'P0001',
      message = 'LEAGUE_REQUIRED';
  end if;

  select lm.*
  into v_member
  from public.league_members lm
  where lm.league_id = target_league_id
    and lm.user_id = v_user_id
    and lm.status = 'active'
  order by lm.joined_at, lm.id
  limit 1;

  if v_member.id is null then
    raise exception using
      errcode = 'P0001',
      message = 'ACTIVE_LEAGUE_MEMBERSHIP_REQUIRED';
  end if;

  return query
  select
    target_league_id,
    coalesce(
      lpmp.policy,
      'wait_reopen_predictions'
    ),
    coalesce(lpmp.version, 1),
    lpmp.reason,
    lpmp.updated_by_member_id,
    lpmp.updated_at,
    v_member.role = 'admin'
  from (
    select 1
  ) seed
  left join public.league_postponed_match_policies lpmp
    on lpmp.league_id = target_league_id;
end;
$function$;

revoke all on function
  public.get_my_league_postponed_match_policy_rpc(uuid)
from public;

grant execute on function
  public.get_my_league_postponed_match_policy_rpc(uuid)
to authenticated;

comment on function
  public.get_my_league_postponed_match_policy_rpc(uuid)
is
  'Returns the postponed Match policy visible to an active League member.';

-- ============================================================================
-- 5. ADMIN UPDATE CONTRACT
-- ============================================================================

create or replace function
  public.update_my_league_postponed_match_policy_rpc(
    target_league_id uuid,
    expected_policy_version integer,
    new_policy text,
    change_reason text default null
  )
returns table(
  league_id uuid,
  policy text,
  policy_version integer,
  reason text,
  updated_by_member_id uuid,
  updated_at timestamptz
)
language plpgsql
volatile
security definer
set search_path to public, pg_temp
as $function$
declare
  v_user_id uuid := auth.uid();
  v_admin_member_id uuid;
  v_current public.league_postponed_match_policies%rowtype;
  v_updated public.league_postponed_match_policies%rowtype;
  v_policy text := lower(btrim(coalesce(new_policy, '')));
  v_reason text := nullif(btrim(change_reason), '');
begin
  if v_user_id is null then
    raise exception using
      errcode = 'P0001',
      message = 'AUTH_REQUIRED';
  end if;

  if target_league_id is null then
    raise exception using
      errcode = 'P0001',
      message = 'LEAGUE_REQUIRED';
  end if;

  if expected_policy_version is null
     or expected_policy_version < 1 then
    raise exception using
      errcode = 'P0001',
      message = 'EXPECTED_POLICY_VERSION_REQUIRED';
  end if;

  if v_policy not in (
    'wait_keep_predictions',
    'wait_reopen_predictions',
    'exclude_from_round'
  ) then
    raise exception using
      errcode = 'P0001',
      message = 'INVALID_POSTPONED_MATCH_POLICY';
  end if;

  if v_reason is not null
     and char_length(v_reason) > 500 then
    raise exception using
      errcode = 'P0001',
      message = 'POSTPONED_MATCH_POLICY_REASON_TOO_LONG';
  end if;

  select lm.id
  into v_admin_member_id
  from public.league_members lm
  where lm.league_id = target_league_id
    and lm.user_id = v_user_id
    and lm.role = 'admin'
    and lm.status = 'active'
  order by lm.joined_at, lm.id
  limit 1;

  if v_admin_member_id is null then
    raise exception using
      errcode = 'P0001',
      message = 'ACTIVE_LEAGUE_ADMIN_REQUIRED';
  end if;

  perform pg_advisory_xact_lock(
    hashtextextended(
      'postponed-match-policy:'
        || target_league_id::text,
      0
    )
  );

  insert into public.league_postponed_match_policies (
    league_id,
    policy,
    updated_by_member_id,
    reason,
    version,
    created_at,
    updated_at
  )
  values (
    target_league_id,
    'wait_reopen_predictions',
    null,
    'Default policy created during first update',
    1,
    now(),
    now()
  )
  on conflict on constraint
    league_postponed_match_policies_pkey
  do nothing;

  select lpmp.*
  into v_current
  from public.league_postponed_match_policies lpmp
  where lpmp.league_id = target_league_id
  for update;

  if v_current.version <> expected_policy_version then
    raise exception using
      errcode = 'P0001',
      message = 'POSTPONED_MATCH_POLICY_VERSION_CONFLICT';
  end if;

  if v_current.policy = v_policy
     and v_current.reason is not distinct from v_reason then
    return query
    select
      v_current.league_id,
      v_current.policy,
      v_current.version,
      v_current.reason,
      v_current.updated_by_member_id,
      v_current.updated_at;

    return;
  end if;

  update public.league_postponed_match_policies lpmp
  set
    policy = v_policy,
    updated_by_member_id = v_admin_member_id,
    reason = v_reason,
    version = lpmp.version + 1,
    updated_at = clock_timestamp()
  where lpmp.league_id = target_league_id
    and lpmp.version = expected_policy_version
  returning lpmp.*
  into v_updated;

  if v_updated.league_id is null then
    raise exception using
      errcode = 'P0001',
      message = 'POSTPONED_MATCH_POLICY_VERSION_CONFLICT';
  end if;

  perform public.write_league_admin_event(
    target_league_id,
    v_admin_member_id,
    v_user_id,
    'member',
    'league_settings_changed',
    null,
    null,
    jsonb_build_object(
      'setting', 'postponed_match_policy',
      'previous_policy', v_current.policy,
      'new_policy', v_updated.policy,
      'previous_version', v_current.version,
      'new_version', v_updated.version,
      'reason', v_updated.reason
    )
  );

  return query
  select
    v_updated.league_id,
    v_updated.policy,
    v_updated.version,
    v_updated.reason,
    v_updated.updated_by_member_id,
    v_updated.updated_at;
end;
$function$;

revoke all on function
  public.update_my_league_postponed_match_policy_rpc(
    uuid,
    integer,
    text,
    text
  )
from public;

grant execute on function
  public.update_my_league_postponed_match_policy_rpc(
    uuid,
    integer,
    text,
    text
  )
to authenticated;

comment on function
  public.update_my_league_postponed_match_policy_rpc(
    uuid,
    integer,
    text,
    text
  )
is
  'Updates the postponed Match policy for an active League Admin and records the change in the League administration journal.';

-- ============================================================================
-- 6. INSTALLATION CERTIFICATION
-- ============================================================================

do $certification$
declare
  v_policy_count integer;
begin
  if to_regclass(
    'public.league_postponed_match_policies'
  ) is null then
    raise exception
      'POSTPONED_MATCH_POLICY_TABLE_NOT_FOUND';
  end if;

  if to_regprocedure(
    'public.get_my_league_postponed_match_policy_rpc(uuid)'
  ) is null then
    raise exception
      'POSTPONED_MATCH_POLICY_READ_RPC_NOT_FOUND';
  end if;

  if to_regprocedure(
    'public.update_my_league_postponed_match_policy_rpc(uuid,integer,text,text)'
  ) is null then
    raise exception
      'POSTPONED_MATCH_POLICY_UPDATE_RPC_NOT_FOUND';
  end if;

  select count(*)
  into v_policy_count
  from public.league_postponed_match_policies lpmp
  where lpmp.policy not in (
    'wait_keep_predictions',
    'wait_reopen_predictions',
    'exclude_from_round'
  );

  if v_policy_count <> 0 then
    raise exception
      'POSTPONED_MATCH_POLICY_INVALID_ROWS_FOUND';
  end if;

  if exists (
    select 1
    from public.leagues l
    left join public.league_postponed_match_policies lpmp
      on lpmp.league_id = l.id
    where lpmp.league_id is null
  ) then
    raise exception
      'POSTPONED_MATCH_POLICY_EXISTING_LEAGUE_BACKFILL_INCOMPLETE';
  end if;
end;
$certification$;

select
  'PASS'
    as postponed_match_policy_foundation_certification;

commit;