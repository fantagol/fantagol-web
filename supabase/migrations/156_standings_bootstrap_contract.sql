-- ============================================================================
-- FANTAGOL
-- Migration 153: Standings Bootstrap Contract
--
-- Scope:
-- - return a complete zero standings payload when no valid simulation exists;
-- - expose all active League Members in all three game modes;
-- - keep the existing get_my_standings_preview_rpc return signature;
-- - avoid creating synthetic Round Simulations or certified ledger data;
-- - provide one backend contract shared by Web and Android clients.
--
-- Out of scope:
-- - scoring;
-- - simulation creation;
-- - certification;
-- - Ranking Ledger writes;
-- - mutation of League Round state.
-- ============================================================================

begin;

-- ============================================================================
-- 1. INTERNAL ZERO STANDINGS BUILDER
-- ============================================================================

create or replace function public.build_zero_standings_preview_internal(
  p_league_round_id uuid
)
returns jsonb
language plpgsql
stable
security definer
set search_path to public, pg_temp
as $function$
declare
  v_round public.league_rounds%rowtype;
  v_member_count integer := 0;
  v_generated_at timestamptz := now();

  v_pure_points_ranking jsonb := '[]'::jsonb;
  v_fantacalcio_ranking jsonb := '[]'::jsonb;
  v_one_to_one_ranking jsonb := '[]'::jsonb;
begin
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

  with active_members as (
    select
      lm.id as league_member_id,
      coalesce(
        nullif(btrim(c.name), ''),
        nullif(btrim(lm.display_name), ''),
        'Club FantaGol'
      )::text as display_name,
      lm.joined_at
    from public.league_members lm
    left join public.clubs c
      on c.id = lm.club_id
    where lm.league_id = v_round.league_id
      and lm.status = 'active'
  )
  select
    count(*)::integer,
    coalesce(
      jsonb_agg(
        jsonb_build_object(
          'league_member_id', am.league_member_id,
          'display_name', am.display_name,
          'position_preview', 1,
          'baseline_position', 1,
          'movement_preview', 0,
          'baseline_points', 0,
          'round_points', 0,
          'projected_points', 0,
          'pending', false,
          'score_phase', 'waiting',
          'round_stats', jsonb_build_object(
            'exact_count', 0,
            'bonus_count', 0,
            'malus_count', 0
          ),
          'baseline_reference', jsonb_build_object(
            'ledger_entry_count', 0,
            'latest_certification_id', null
          ),
          'tiebreaker_preview', jsonb_build_object(
            'policy', 'all_members_tied_before_first_score',
            'preview_only', true,
            'deterministic_fallback', 'league_member_id'
          )
        )
        order by lower(am.display_name), am.joined_at, am.league_member_id
      ),
      '[]'::jsonb
    )
  into
    v_member_count,
    v_pure_points_ranking
  from active_members am;

  with active_members as (
    select
      lm.id as league_member_id,
      coalesce(
        nullif(btrim(c.name), ''),
        nullif(btrim(lm.display_name), ''),
        'Club FantaGol'
      )::text as display_name,
      lm.joined_at
    from public.league_members lm
    left join public.clubs c
      on c.id = lm.club_id
    where lm.league_id = v_round.league_id
      and lm.status = 'active'
  )
  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'league_member_id', am.league_member_id,
        'display_name', am.display_name,
        'position_preview', 1,
        'baseline_position', 1,
        'movement_preview', 0,
        'baseline_points', 0,
        'round_points', 0,
        'projected_points', 0,
        'pending', false,
        'score_phase', 'waiting',
        'round_stats', jsonb_build_object(
          'wins', 0,
          'draws', 0,
          'losses', 0,
          'goals_for', 0,
          'goals_against', 0,
          'goal_difference', 0
        ),
        'baseline_reference', jsonb_build_object(
          'ledger_entry_count', 0,
          'latest_certification_id', null
        ),
        'tiebreaker_preview', jsonb_build_object(
          'policy', 'all_members_tied_before_first_score',
          'preview_only', true,
          'deterministic_fallback', 'league_member_id'
        )
      )
      order by lower(am.display_name), am.joined_at, am.league_member_id
    ),
    '[]'::jsonb
  )
  into v_fantacalcio_ranking
  from active_members am;

  with active_members as (
    select
      lm.id as league_member_id,
      coalesce(
        nullif(btrim(c.name), ''),
        nullif(btrim(lm.display_name), ''),
        'Club FantaGol'
      )::text as display_name,
      lm.joined_at
    from public.league_members lm
    left join public.clubs c
      on c.id = lm.club_id
    where lm.league_id = v_round.league_id
      and lm.status = 'active'
  )
  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'league_member_id', am.league_member_id,
        'display_name', am.display_name,
        'position_preview', 1,
        'baseline_position', 1,
        'movement_preview', 0,
        'baseline_points', 0,
        'round_points', 0,
        'projected_points', 0,
        'pending', false,
        'score_phase', 'waiting',
        'round_stats', jsonb_build_object(
          'wins', 0,
          'draws', 0,
          'losses', 0,
          'mini_wins', 0,
          'mini_draws', 0,
          'mini_losses', 0,
          'mini_difference', 0
        ),
        'baseline_reference', jsonb_build_object(
          'ledger_entry_count', 0,
          'latest_certification_id', null
        ),
        'tiebreaker_preview', jsonb_build_object(
          'policy', 'all_members_tied_before_first_score',
          'preview_only', true,
          'deterministic_fallback', 'league_member_id'
        )
      )
      order by lower(am.display_name), am.joined_at, am.league_member_id
    ),
    '[]'::jsonb
  )
  into v_one_to_one_ranking
  from active_members am;

  return jsonb_build_object(
    'schema_version', 1,
    'builder', 'StandingsBootstrapBuilder',
    'builder_version', 'standings-bootstrap-v1',
    'generated_at', v_generated_at,
    'preview', true,
    'official', false,
    'bootstrap', true,
    'bootstrap_reason', 'no_valid_standings_simulation',
    'member_count', v_member_count,
    'mode_count', 3,
    'modes', jsonb_build_object(
      'pure_points', jsonb_build_object(
        'mode', 'pure_points',
        'preview', true,
        'bootstrap', true,
        'baseline_source', 'empty_league_ranking_ledger',
        'round_source', 'zero_standings_bootstrap',
        'member_count', v_member_count,
        'pending_member_count', 0,
        'ranking', v_pure_points_ranking
      ),
      'fantacalcio', jsonb_build_object(
        'mode', 'fantacalcio',
        'preview', true,
        'bootstrap', true,
        'baseline_source', 'empty_league_ranking_ledger',
        'round_source', 'zero_standings_bootstrap',
        'member_count', v_member_count,
        'pending_member_count', 0,
        'ranking', v_fantacalcio_ranking
      ),
      'one_to_one', jsonb_build_object(
        'mode', 'one_to_one',
        'preview', true,
        'bootstrap', true,
        'baseline_source', 'empty_league_ranking_ledger',
        'round_source', 'zero_standings_bootstrap',
        'member_count', v_member_count,
        'pending_member_count', 0,
        'ranking', v_one_to_one_ranking
      )
    )
  );
end;
$function$;

-- ============================================================================
-- 2. AUTHENTICATED STANDINGS READ CONTRACT
-- ============================================================================

create or replace function public.get_my_standings_preview_rpc(
  p_league_round_id uuid
)
returns table (
  simulation_id uuid,
  simulation_version integer,
  simulation_status text,
  simulation_hash text,
  manifest jsonb,
  round_view jsonb,
  member_view jsonb,
  standings_preview jsonb
)
language plpgsql
stable
security definer
set search_path to public, pg_temp
as $function$
declare
  v_user_id uuid;
  v_member_id uuid;
  v_round public.league_rounds%rowtype;
  v_simulation public.round_simulations%rowtype;
  v_member_view jsonb;
  v_bootstrap jsonb;
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

  select lm.id
  into v_member_id
  from public.league_members lm
  where lm.league_id = v_round.league_id
    and lm.user_id = v_user_id
    and lm.status = 'active'
  limit 1;

  if v_member_id is null then
    raise exception using
      errcode = 'P0001',
      message = 'ACTIVE_LEAGUE_MEMBERSHIP_REQUIRED';
  end if;

  select rs.*
  into v_simulation
  from public.round_simulations rs
  where rs.league_round_id = p_league_round_id
    and rs.status in (
      'preview_ready',
      'awaiting_certification',
      'certified'
    )
    and rs.digital_twin ? 'standings_preview'
  order by
    rs.publishable desc,
    rs.simulation_version desc
  limit 1;

  if found then
    select value
    into v_member_view
    from jsonb_array_elements(
      coalesce(v_simulation.digital_twin -> 'members', '[]'::jsonb)
    ) value
    where value ->> 'league_member_id' = v_member_id::text
    limit 1;

    return query
    select
      v_simulation.id,
      v_simulation.simulation_version,
      v_simulation.status,
      v_simulation.simulation_hash,
      v_simulation.digital_twin -> 'manifest',
      v_simulation.digital_twin -> 'round',
      coalesce(v_member_view, '{}'::jsonb),
      jsonb_build_object(
        'schema_version', coalesce(
          (
            v_simulation.digital_twin #>>
              '{standings_preview,schema_version}'
          )::integer,
          1
        ),
        'builder', v_simulation.digital_twin #>>
          '{standings_preview,builder}',
        'builder_version', v_simulation.digital_twin #>>
          '{standings_preview,builder_version}',
        'generated_at', v_simulation.digital_twin #>
          '{standings_preview,generated_at}',
        'preview', true,
        'official', coalesce(
          (
            v_simulation.digital_twin #>>
              '{standings_preview,official}'
          )::boolean,
          false
        ),
        'bootstrap', false,
        'member_count', coalesce(
          (
            v_simulation.digital_twin #>>
              '{standings_preview,member_count}'
          )::integer,
          0
        ),
        'mode_count', coalesce(
          (
            v_simulation.digital_twin #>>
              '{standings_preview,mode_count}'
          )::integer,
          0
        ),
        'member', jsonb_build_object(
          'league_member_id', v_member_id,
          'pure_points', coalesce(
            (
              select ranking_row
              from jsonb_array_elements(
                coalesce(
                  v_simulation.digital_twin #>
                    '{standings_preview,modes,pure_points,ranking}',
                  '[]'::jsonb
                )
              ) ranking_row
              where ranking_row ->> 'league_member_id' =
                v_member_id::text
              limit 1
            ),
            '{}'::jsonb
          ),
          'fantacalcio', coalesce(
            (
              select ranking_row
              from jsonb_array_elements(
                coalesce(
                  v_simulation.digital_twin #>
                    '{standings_preview,modes,fantacalcio,ranking}',
                  '[]'::jsonb
                )
              ) ranking_row
              where ranking_row ->> 'league_member_id' =
                v_member_id::text
              limit 1
            ),
            '{}'::jsonb
          ),
          'one_to_one', coalesce(
            (
              select ranking_row
              from jsonb_array_elements(
                coalesce(
                  v_simulation.digital_twin #>
                    '{standings_preview,modes,one_to_one,ranking}',
                  '[]'::jsonb
                )
              ) ranking_row
              where ranking_row ->> 'league_member_id' =
                v_member_id::text
              limit 1
            ),
            '{}'::jsonb
          )
        ),
        'modes', coalesce(
          v_simulation.digital_twin #> '{standings_preview,modes}',
          '{}'::jsonb
        )
      );

    return;
  end if;

  v_bootstrap :=
    public.build_zero_standings_preview_internal(p_league_round_id);

  select jsonb_build_object(
    'league_member_id', lm.id,
    'league_id', lm.league_id,
    'display_name', coalesce(
      nullif(btrim(c.name), ''),
      nullif(btrim(lm.display_name), ''),
      'Club FantaGol'
    ),
    'role', lm.role,
    'status', lm.status,
    'score_phase', 'waiting',
    'bootstrap', true
  )
  into v_member_view
  from public.league_members lm
  left join public.clubs c
    on c.id = lm.club_id
  where lm.id = v_member_id;

  return query
  select
    null::uuid,
    0::integer,
    'bootstrap'::text,
    null::text,
    jsonb_build_object(
      'schema_version', 1,
      'engine', 'StandingsBootstrapEngine',
      'engine_version', 'standings-bootstrap-v1',
      'league_round_id', v_round.id,
      'league_id', v_round.league_id,
      'simulation_backed', false,
      'generated_at', v_bootstrap -> 'generated_at'
    ),
    jsonb_build_object(
      'league_round_id', v_round.id,
      'league_id', v_round.league_id,
      'round_number', v_round.league_round_number,
      'round_status', v_round.status,
      'enabled', v_round.enabled,
      'bootstrap', true
    ),
    coalesce(v_member_view, '{}'::jsonb),
    v_bootstrap;
end;
$function$;

-- ============================================================================
-- 3. PRIVILEGES
-- ============================================================================

revoke all on function
  public.build_zero_standings_preview_internal(uuid)
from public, anon, authenticated;

grant execute on function
  public.build_zero_standings_preview_internal(uuid)
to service_role;

revoke all on function
  public.get_my_standings_preview_rpc(uuid)
from public, anon, service_role;

grant execute on function
  public.get_my_standings_preview_rpc(uuid)
to authenticated;

-- ============================================================================
-- 4. COMMENTS
-- ============================================================================

comment on function
  public.build_zero_standings_preview_internal(uuid)
is
'Builds an ephemeral zero standings payload for all active League Members and all three FantaGol modes when no valid Standings Simulation exists. It performs no writes and creates no synthetic simulation or ledger entry.';

comment on function
  public.get_my_standings_preview_rpc(uuid)
is
'Returns the latest valid merged Standings Preview when available; otherwise returns a complete ephemeral zero standings bootstrap payload with the same client-facing modes contract. Authenticated active League Members only.';

commit;