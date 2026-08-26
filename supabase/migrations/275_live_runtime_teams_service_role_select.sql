begin;

-- ============================================================
-- FANTAGOL - MIGRATION 275
-- LIVE RUNTIME TEAMS SERVICE ROLE SELECT
-- ============================================================
--
-- R47-G2-R16 bootstrap discovery hydrates canonical team names
-- through:
--
--   matches.home_team_id / away_team_id
--     -> teams.id
--     -> teams.name
--
-- The production Live Runtime already has service_role SELECT on
-- public.matches, but public.teams was not part of the historical
-- runtime read contract.
--
-- Minimal privilege extension only:
--   service_role -> SELECT public.teams
--
-- No anon/authenticated privilege changes.
-- No mutation privilege.
-- No RLS policy change.
-- ============================================================

grant select
on table public.teams
to service_role;

do $assert$
begin
    if not has_table_privilege(
        'service_role',
        'public.teams',
        'SELECT'
    ) then
        raise exception
            'LIVE_RUNTIME_TEAMS_SERVICE_ROLE_SELECT_NOT_GRANTED';
    end if;

    if has_table_privilege(
        'anon',
        'public.teams',
        'SELECT'
    ) then
        raise exception
            'LIVE_RUNTIME_TEAMS_ANON_SELECT_UNEXPECTED';
    end if;

    if has_table_privilege(
        'authenticated',
        'public.teams',
        'SELECT'
    ) then
        raise exception
            'LIVE_RUNTIME_TEAMS_AUTHENTICATED_SELECT_UNEXPECTED';
    end if;
end
$assert$;

comment on table public.teams is
'Canonical football Team registry. service_role SELECT is required by the certified Live Runtime The Odds bootstrap team-hydration path.';

commit;