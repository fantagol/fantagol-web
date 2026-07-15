-- ============================================================================
-- FANTAGOL
-- Migration 022: Current League Round Resolver
-- Resolves the most relevant enabled League Round for the authenticated member.
-- ============================================================================

begin;

create or replace function public.get_my_current_league_round_rpc(
  p_league_id uuid
)
returns table (
  league_id uuid,
  league_round_id uuid,
  league_round_number integer,
  league_round_status text,
  fantagol_round_id uuid,
  round_opens_at timestamptz,
  round_lock_at timestamptz,
  round_starts_at timestamptz
)
language plpgsql
security definer
set search_path to public, pg_temp
as $function$
declare
  v_user_id uuid;
begin
  v_user_id := auth.uid();

  if v_user_id is null then
    raise exception using
      errcode = 'P0001',
      message = 'AUTHENTICATION_REQUIRED';
  end if;

  if p_league_id is null then
    raise exception using
      errcode = 'P0001',
      message = 'LEAGUE_REQUIRED';
  end if;

  if not exists (
    select 1
    from public.league_members lm
    where lm.league_id = p_league_id
      and lm.user_id = v_user_id
      and lm.status = 'active'
  ) then
    raise exception using
      errcode = 'P0001',
      message = 'ACTIVE_LEAGUE_MEMBERSHIP_REQUIRED';
  end if;

  return query
  select
    lr.league_id,
    lr.id,
    lr.league_round_number,
    lr.status,
    lr.fantagol_round_id,
    fr.opens_at,
    fr.lock_at,
    fr.starts_at
  from public.league_rounds lr
  join public.fantagol_rounds fr
    on fr.id = lr.fantagol_round_id
  where lr.league_id = p_league_id
    and lr.enabled
    and lr.status not in ('archived', 'cancelled')
  order by
    case
      when lr.status = 'predictions_open'
       and clock_timestamp() >= fr.opens_at
       and clock_timestamp() < fr.lock_at
        then 1
      when lr.status in (
        'predictions_locked',
        'live',
        'waiting_postponed',
        'final_calculable',
        'scoring'
      )
        then 2
      when lr.status = 'scheduled'
       and fr.starts_at >= clock_timestamp()
        then 3
      when lr.status = 'official'
        then 4
      when lr.status = 'recalculated'
        then 5
      else 6
    end,
    case
      when fr.starts_at >= clock_timestamp() then fr.starts_at
      else null
    end asc nulls last,
    fr.starts_at desc,
    lr.league_round_number asc
  limit 1;

  if not found then
    raise exception using
      errcode = 'P0001',
      message = 'CURRENT_LEAGUE_ROUND_NOT_FOUND';
  end if;
end;
$function$;

comment on function public.get_my_current_league_round_rpc(uuid)
is 'Resolves the current or next relevant enabled League Round for an authenticated active league member.';

revoke all on function public.get_my_current_league_round_rpc(uuid) from public;
revoke all on function public.get_my_current_league_round_rpc(uuid) from anon;
grant execute on function public.get_my_current_league_round_rpc(uuid) to authenticated;

commit;
