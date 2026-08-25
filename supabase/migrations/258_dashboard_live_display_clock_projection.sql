begin;

do $$
begin
  if to_regprocedure(
    'public.get_my_dashboard_matchups_rpc(uuid)'
  ) is null then
    raise exception
      'R43_DASHBOARD_CANONICAL_RPC_MISSING';
  end if;
end
$$;

create or replace function
public.decorate_dashboard_live_clock_internal(
  p_payload jsonb
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_result jsonb;
  v_match_id uuid;

  v_status text;
  v_minute integer;
  v_kickoff timestamptz;

  v_half_time_at timestamptz;
  v_restart_at timestamptz;

  v_live_half integer;
  v_phase_started_at timestamptz;
begin
  if p_payload is null then
    return null;
  end if;

  if jsonb_typeof(p_payload) = 'array' then

    select
      coalesce(
        jsonb_agg(
          public.decorate_dashboard_live_clock_internal(
            item.value
          )
          order by item.ordinality
        ),
        '[]'::jsonb
      )
    into v_result
    from jsonb_array_elements(p_payload)
         with ordinality as item(value, ordinality);

    return v_result;

  elsif jsonb_typeof(p_payload) = 'object' then

    select
      coalesce(
        jsonb_object_agg(
          entry.key,
          public.decorate_dashboard_live_clock_internal(
            entry.value
          )
        ),
        '{}'::jsonb
      )
    into v_result
    from jsonb_each(p_payload)
         as entry(key, value);

    if p_payload ? 'match_id' then

      begin
        v_match_id :=
          nullif(
            btrim(p_payload ->> 'match_id'),
            ''
          )::uuid;
      exception
        when invalid_text_representation then
          v_match_id := null;
      end;

      if v_match_id is not null then

        select
          lower(coalesce(m.status, '')),
          m.minute,
          m.kickoff
        into
          v_status,
          v_minute,
          v_kickoff
        from public.matches m
        where m.id = v_match_id;

        if found then

          v_half_time_at := null;
          v_restart_at := null;
          v_live_half := null;
          v_phase_started_at := null;

          /*
           * Provider remains phase authority.
           *
           * We derive only a DISPLAY clock because football-data
           * does not expose minute/injuryTime in the real LIVE
           * responses observed by R43.
           */
          select
            max(r.created_at)
          into v_half_time_at
          from public.live_match_update_receipts r
          where r.match_id = v_match_id
            and r.created_at >=
              v_kickoff - interval '5 minutes'
            and lower(
              coalesce(
                r.normalized_payload ->> 'status',
                ''
              )
            ) in (
              'halftime',
              'paused'
            );

          if
            v_status like 'live_%'
            or v_status in (
              'in_play',
              'extra_time',
              'penalties'
            )
          then

            if v_half_time_at is null then

              v_live_half := 1;
              v_phase_started_at := v_kickoff;

            else

              select
                min(r.created_at)
              into v_restart_at
              from public.live_match_update_receipts r
              where r.match_id = v_match_id
                and r.created_at > v_half_time_at
                and lower(
                  coalesce(
                    r.normalized_payload ->> 'status',
                    ''
                  )
                ) like 'live_%'
                   or (
                     r.match_id = v_match_id
                     and r.created_at > v_half_time_at
                     and lower(
                       coalesce(
                         r.normalized_payload ->> 'status',
                         ''
                       )
                     ) in (
                       'in_play',
                       'extra_time',
                       'penalties'
                     )
                   );

              if v_restart_at is not null then
                v_live_half := 2;
                v_phase_started_at := v_restart_at;
              end if;

            end if;

          elsif v_status in (
            'halftime',
            'paused'
          ) then

            v_live_half := 1;

          end if;

          v_result :=
            v_result ||
            jsonb_build_object(
              'minute',
                v_minute,
              'live_half',
                v_live_half,
              'live_phase_started_at',
                v_phase_started_at
            );

        end if;

      end if;

    end if;

    return v_result;

  end if;

  return p_payload;
end;
$$;


revoke all
on function
public.decorate_dashboard_live_clock_internal(jsonb)
from public;


create or replace function
public.get_my_dashboard_matchups_live_rpc(
  p_league_id uuid
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_base jsonb;
begin
  if auth.uid() is null then
    raise exception 'AUTH_REQUIRED';
  end if;

  /*
   * Canonical dashboard RPC remains the ownership,
   * visibility and matchup authority.
   */
  v_base :=
    public.get_my_dashboard_matchups_rpc(
      p_league_id
    );

  return
    public.decorate_dashboard_live_clock_internal(
      v_base
    );
end;
$$;


revoke all
on function
public.get_my_dashboard_matchups_live_rpc(uuid)
from public;

grant execute
on function
public.get_my_dashboard_matchups_live_rpc(uuid)
to authenticated;

commit;