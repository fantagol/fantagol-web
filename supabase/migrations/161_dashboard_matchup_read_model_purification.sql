-- ============================================================
-- FANTAGOL
-- Migration 161
-- Dashboard Matchup Read Model Purification
--
-- Purpose:
--   Purify the canonical dashboard matchup read model introduced
--   by migration 160.
--
-- Permanent architectural boundary:
--
--   Schedule Engine
--     - league_schedule_versions
--     - league_fixtures
--     - league_members
--     - structural matchup truth
--
--   Round Simulation Engine
--     - preview RPCs
--     - simulated points and goals
--     - optional derived state
--
-- The matchup RPC must remain valid when:
--   - no simulation exists;
--   - a simulation was invalidated;
--   - a round was reopened;
--   - preview generation has not yet occurred.
--
-- This migration intentionally removes every field and dependency
-- belonging to the Round Simulation Engine.
-- ============================================================

begin;

drop function if exists
    public.get_my_dashboard_matchups_rpc(uuid);

create function public.get_my_dashboard_matchups_rpc(
    p_league_round_id uuid
)
returns table (
    league_round_id uuid,
    league_round_number integer,
    league_round_status text,

    schedule_version_id uuid,
    schedule_version integer,

    fixture_id uuid,
    mode text,
    cycle_number integer,
    leg_number integer,
    pairing_round_number integer,

    current_member_id uuid,
    current_side text,

    home_member_id uuid,
    home_display_name text,

    away_member_id uuid,
    away_display_name text,

    opponent_member_id uuid,
    opponent_display_name text,

    is_bye boolean,
    fixture_phase text
)
language plpgsql
security definer
set search_path = public, pg_temp
as $function$
declare
    v_user_id uuid;
    v_round public.league_rounds%rowtype;
    v_member public.league_members%rowtype;
    v_schedule public.league_schedule_versions%rowtype;
begin
    v_user_id := auth.uid();

    if v_user_id is null then
        raise exception using
            errcode = 'P0001',
            message = 'AUTHENTICATION_REQUIRED';
    end if;

    if p_league_round_id is null then
        raise exception using
            errcode = 'P0001',
            message = 'LEAGUE_ROUND_REQUIRED';
    end if;

    select lr.*
    into v_round
    from public.league_rounds lr
    where lr.id = p_league_round_id;

    if not found then
        raise exception using
            errcode = 'P0001',
            message = 'LEAGUE_ROUND_NOT_FOUND';
    end if;

    select lm.*
    into v_member
    from public.league_members lm
    where lm.league_id = v_round.league_id
      and lm.user_id = v_user_id
      and lm.status = 'active'
    limit 1;

    if not found then
        raise exception using
            errcode = 'P0001',
            message = 'ACTIVE_LEAGUE_MEMBERSHIP_REQUIRED';
    end if;

    select lsv.*
    into v_schedule
    from public.league_schedule_versions lsv
    where lsv.league_id = v_round.league_id
      and lsv.active = true
    order by lsv.version desc
    limit 1;

    if not found then
        return;
    end if;

    return query
    select
        v_round.id as league_round_id,
        v_round.league_round_number,
        v_round.status as league_round_status,

        v_schedule.id as schedule_version_id,
        v_schedule.version as schedule_version,

        lf.id as fixture_id,
        lf.mode,
        lf.cycle_number,
        lf.leg_number,
        lf.pairing_round_number,

        v_member.id as current_member_id,

        case
            when lf.home_member_id = v_member.id then 'home'
            when lf.away_member_id = v_member.id then 'away'
            else null
        end as current_side,

        lf.home_member_id,
        hm.display_name as home_display_name,

        lf.away_member_id,
        am.display_name as away_display_name,

        case
            when lf.is_bye then null
            when lf.home_member_id = v_member.id then lf.away_member_id
            when lf.away_member_id = v_member.id then lf.home_member_id
            else null
        end as opponent_member_id,

        case
            when lf.is_bye then null
            when lf.home_member_id = v_member.id then am.display_name
            when lf.away_member_id = v_member.id then hm.display_name
            else null
        end as opponent_display_name,

        lf.is_bye,

        case
            when lf.is_bye then 'bye'
            else 'scheduled'
        end as fixture_phase

    from public.league_fixtures lf

    join public.league_members hm
      on hm.id = lf.home_member_id

    left join public.league_members am
      on am.id = lf.away_member_id

    where lf.league_id = v_round.league_id
      and lf.league_round_id = v_round.id
      and lf.schedule_version_id = v_schedule.id
      and lf.mode in ('fantacalcio', 'one_to_one')
      and (
            lf.home_member_id = v_member.id
            or lf.away_member_id = v_member.id
          )

    order by
        case lf.mode
            when 'fantacalcio' then 1
            when 'one_to_one' then 2
            else 99
        end;
end;
$function$;

revoke all
on function public.get_my_dashboard_matchups_rpc(uuid)
from public;

revoke all
on function public.get_my_dashboard_matchups_rpc(uuid)
from anon;

revoke all
on function public.get_my_dashboard_matchups_rpc(uuid)
from authenticated;

grant execute
on function public.get_my_dashboard_matchups_rpc(uuid)
to authenticated;

comment on function public.get_my_dashboard_matchups_rpc(uuid) is
'Returns the authenticated active league member canonical Fantacalcio and One-to-One scheduled fixtures for one League Round. The active League Schedule is the sole structural source of truth. Simulation and preview state are intentionally outside this contract.';

commit;