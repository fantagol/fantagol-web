begin;

create or replace function public.control_room_read_access_allowed()
returns boolean
language sql
stable
security definer
set search_path = public, auth, pg_temp
as $function$
    select
        coalesce(
            current_setting('request.jwt.claim.role', true),
            ''
        ) = 'service_role'
        or session_user in ('postgres', 'supabase_admin')
        or (
            auth.uid() is not null
            and exists (
                select 1
                from public.premium_access_sessions pas
                where pas.user_id = auth.uid()
                  and pas.resource_code = 'CONTROL_ROOM'
                  and pas.status = 'active'
                  and pas.expires_at > now()
            )
        )
$function$;

comment on function public.control_room_read_access_allowed() is
'Server-side authorization gate for Control Room readers. Authenticated users require an active, unexpired CONTROL_ROOM premium access session. Service role and database administration are allowed for runtime/maintenance operations.';

revoke all on function public.control_room_read_access_allowed()
from public;

revoke all on function public.control_room_read_access_allowed()
from anon;

revoke all on function public.control_room_read_access_allowed()
from authenticated;

grant execute on function public.control_room_read_access_allowed()
to service_role;

/*
  Rebind only the six public Control Room reader RPCs.
  We deliberately do NOT change community_read_access_allowed(), because
  it is a wider Community Intelligence authentication gate.

  CREATE OR REPLACE preserves each function signature and its existing
  grants.  The migration derives each current body from PostgreSQL and
  changes only the authorization predicate.
*/
do $$
declare
    r record;
    v_definition text;
    v_patched text;
    v_changed_count integer := 0;
begin
    for r in
        select p.oid, p.proname
        from pg_proc p
        join pg_namespace n
          on n.oid = p.pronamespace
        where n.nspname = 'public'
          and p.proname in (
              'get_control_room_overview_rpc',
              'get_control_room_match_rpc',
              'get_control_room_trend_rpc',
              'get_control_room_market_round_rpc',
              'get_control_room_market_match_rpc',
              'get_control_room_daily_intelligence_metrics_rpc'
          )
        order by p.proname
    loop
        v_definition := pg_get_functiondef(r.oid);

        if position(
            'community_read_access_allowed()'
            in v_definition
        ) = 0 then
            raise exception
                'R38C6C12S1_EXPECTED_OLD_GATE_MISSING function=%',
                r.proname;
        end if;

        if position(
            'control_room_read_access_allowed()'
            in v_definition
        ) > 0 then
            raise exception
                'R38C6C12S1_NEW_GATE_ALREADY_PRESENT function=%',
                r.proname;
        end if;

        v_patched := replace(
            v_definition,
            'community_read_access_allowed()',
            'control_room_read_access_allowed()'
        );

        execute v_patched;
        v_changed_count := v_changed_count + 1;
    end loop;

    if v_changed_count <> 6 then
        raise exception
            'R38C6C12S1_PATCHED_FUNCTION_COUNT=%',
            v_changed_count;
    end if;

    raise notice
        '[PASS] rebound % Control Room readers to premium server-side gate',
        v_changed_count;
end
$$;

do $$
declare
    v_without_new_gate integer;
    v_still_old_gate integer;
begin
    select count(*)
    into v_without_new_gate
    from pg_proc p
    join pg_namespace n
      on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.proname in (
          'get_control_room_overview_rpc',
          'get_control_room_match_rpc',
          'get_control_room_trend_rpc',
          'get_control_room_market_round_rpc',
          'get_control_room_market_match_rpc',
          'get_control_room_daily_intelligence_metrics_rpc'
      )
      and position(
          'control_room_read_access_allowed()'
          in pg_get_functiondef(p.oid)
      ) = 0;

    select count(*)
    into v_still_old_gate
    from pg_proc p
    join pg_namespace n
      on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.proname in (
          'get_control_room_overview_rpc',
          'get_control_room_match_rpc',
          'get_control_room_trend_rpc',
          'get_control_room_market_round_rpc',
          'get_control_room_market_match_rpc',
          'get_control_room_daily_intelligence_metrics_rpc'
      )
      and position(
          'community_read_access_allowed()'
          in pg_get_functiondef(p.oid)
      ) > 0;

    if v_without_new_gate <> 0 then
        raise exception
            'R38C6C12S1_MISSING_PREMIUM_GATE=%',
            v_without_new_gate;
    end if;

    if v_still_old_gate <> 0 then
        raise exception
            'R38C6C12S1_OLD_GATE_REMAINS=%',
            v_still_old_gate;
    end if;

    raise notice
        '[PASS] all six Control Room readers use only control_room_read_access_allowed()';
end
$$;

commit;