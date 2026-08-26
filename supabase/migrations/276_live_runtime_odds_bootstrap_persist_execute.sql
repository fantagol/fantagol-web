begin;

-- ============================================================
-- FANTAGOL - MIGRATION 276
-- LIVE RUNTIME THE ODDS BOOTSTRAP PERSIST EXECUTE
-- ============================================================
--
-- The Odds bootstrap discovery runtime reaches the canonical
-- persistence authority:
--
--   persist_the_odds_round_mapping_bootstrap_internal(uuid,jsonb)
--
-- The function is SECURITY DEFINER and intentionally denied to
-- public/client roles. Production Live Runtime executes through
-- service_role, which currently lacks EXECUTE.
--
-- Minimal privilege extension only:
--
--   service_role -> EXECUTE exact persistence function
--
-- public / anon / authenticated remain denied.
-- No table privilege changes.
-- No RLS changes.
-- No function body changes.
-- ============================================================

grant execute
on function public.persist_the_odds_round_mapping_bootstrap_internal(
    uuid,
    jsonb
)
to service_role;

do $assert$
declare
    v_function regprocedure :=
        'public.persist_the_odds_round_mapping_bootstrap_internal(uuid,jsonb)'::regprocedure;
begin
    if not has_function_privilege(
        'service_role',
        v_function,
        'EXECUTE'
    ) then
        raise exception
            'LIVE_RUNTIME_ODDS_BOOTSTRAP_PERSIST_SERVICE_ROLE_EXECUTE_NOT_GRANTED';
    end if;

    if has_function_privilege(
        'anon',
        v_function,
        'EXECUTE'
    ) then
        raise exception
            'LIVE_RUNTIME_ODDS_BOOTSTRAP_PERSIST_ANON_EXECUTE_UNEXPECTED';
    end if;

    if has_function_privilege(
        'authenticated',
        v_function,
        'EXECUTE'
    ) then
        raise exception
            'LIVE_RUNTIME_ODDS_BOOTSTRAP_PERSIST_AUTHENTICATED_EXECUTE_UNEXPECTED';
    end if;

    if has_function_privilege(
        'public',
        v_function,
        'EXECUTE'
    ) then
        raise exception
            'LIVE_RUNTIME_ODDS_BOOTSTRAP_PERSIST_PUBLIC_EXECUTE_UNEXPECTED';
    end if;
end
$assert$;

comment on function
public.persist_the_odds_round_mapping_bootstrap_internal(
    uuid,
    jsonb
)
is
'Canonical The Odds API round bootstrap mapping persistence authority. service_role EXECUTE is required by production Live Runtime; public, anon and authenticated remain denied.';

commit;