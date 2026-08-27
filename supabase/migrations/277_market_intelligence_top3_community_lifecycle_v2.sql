begin;

-- ============================================================================
-- FANTAGOL
-- MIGRATION 277
-- MARKET INTELLIGENCE TOP3 COMMUNITY LIFECYCLE V2
--
-- Authority:
--   1. every active league freezes its own Top3 Punti Puri cohort;
--   2. cohort basis is the previous FantaGol Round;
--   3. cohort is immutable for the target round;
--   4. PACKAGE refreshes the current leaders' submitted predictions;
--   5. ADVANCED reuses the latest Top3 snapshot;
--   6. Market Intelligence persists aggregate expert evidence only.
-- ============================================================================

create table if not exists public.community_top3_cohort_members (
  id uuid primary key default gen_random_uuid(),

  target_fantagol_round_id uuid not null
    references public.fantagol_rounds(id)
    on delete cascade,

  basis_fantagol_round_id uuid not null
    references public.fantagol_rounds(id)
    on delete restrict,

  league_id uuid not null
    references public.leagues(id)
    on delete cascade,

  league_member_id uuid not null
    references public.league_members(id)
    on delete restrict,

  user_id uuid not null
    references auth.users(id)
    on delete restrict,

  rank smallint not null
    check (rank between 1 and 3),

  pure_points numeric not null,

  rank_weight numeric not null
    check (rank_weight > 0 and rank_weight <= 1),

  frozen_at timestamptz not null
    default now(),

  created_at timestamptz not null
    default now(),

  unique (
    target_fantagol_round_id,
    league_id,
    rank
  ),

  unique (
    target_fantagol_round_id,
    league_id,
    user_id
  )
);

create index if not exists
  community_top3_cohort_target_idx
on public.community_top3_cohort_members (
  target_fantagol_round_id,
  league_id,
  rank
);

create table if not exists public.community_top3_expert_snapshots (
  id uuid primary key default gen_random_uuid(),

  fantagol_round_id uuid not null
    references public.fantagol_rounds(id)
    on delete cascade,

  snapshot_version integer not null,

  captured_at timestamptz not null,

  snapshot_source text not null
    check (
      snapshot_source in (
        'PACKAGE',
        'ADVANCED_FALLBACK'
      )
    ),

  league_count integer not null
    check (league_count >= 0),

  cohort_member_count integer not null
    check (cohort_member_count >= 0),

  available_prediction_count integer not null
    check (available_prediction_count >= 0),

  feature_version text not null
    check (
      feature_version =
      'TOP3_EXPERT_FEATURE_V1'
    ),

  payload jsonb not null
    default '{}'::jsonb,

  created_at timestamptz not null
    default now(),

  unique (
    fantagol_round_id,
    snapshot_version
  )
);

create index if not exists
  community_top3_expert_snapshot_round_idx
on public.community_top3_expert_snapshots (
  fantagol_round_id,
  snapshot_version desc
);

alter table
  public.community_top3_cohort_members
enable row level security;

alter table
  public.community_top3_expert_snapshots
enable row level security;

-- Service-role runtime writes these internal authorities.
-- No anon/authenticated policy is intentionally exposed.

update public.market_intelligence_models
set status = 'deprecated'
where model_code = 'BM_INTERPOLATED'
  and status = 'active'
  and algorithm_version = 'BM_INTERPOLATED_V1';

insert into public.market_intelligence_models (
  model_code,
  model_version,
  display_name,
  description,
  status,
  algorithm_version,
  configuration,
  metadata
)
values (
  'BM_INTERPOLATED',
  2,
  'Bookmaker Interpolated',
  'Market intelligence enriched by the frozen Top3 Punti Puri cohort of every active Community league.',
  'active',
  'BM_INTERPOLATED_V2',
  jsonb_build_object(
    'market', 'multi_market',
    'probability_normalization', 'overround_removed',
    'community_input', true,
    'top3_expert_feature', 'TOP3_EXPERT_FEATURE_V1',
    'top3_scope', 'ALL_ACTIVE_LEAGUES',
    'top3_rank_weights', jsonb_build_array(0.45, 0.33, 0.22),
    'top3_max_weight', 0.18,
    'top3_cohort_freeze', 'PREVIOUS_ROUND_CLOSE',
    'top3_prediction_refresh', 'PACKAGE_DAILY_PRE_KICKOFF_ONLY',
    'advanced_top3_policy', 'LATEST_PERSISTED_SNAPSHOT'
  ),
  jsonb_build_object(
    'activation_migration', 277,
    'frontend_projection', 'Bookmakers',
    'leader_identity_persisted_in_market_artifact', false,
    'dynamic_learning', false
  )
)
on conflict (
  model_code,
  model_version
)
do update
set
  display_name = excluded.display_name,
  description = excluded.description,
  status = excluded.status,
  algorithm_version = excluded.algorithm_version,
  configuration = excluded.configuration,
  metadata = excluded.metadata;

do $$
declare
  v_active integer;
begin
  select count(*)
  into v_active
  from public.market_intelligence_models
  where model_code = 'BM_INTERPOLATED'
    and status = 'active';

  if v_active <> 1 then
    raise exception
      'MIGRATION_277_ACTIVE_MODEL_COUNT=%',
      v_active;
  end if;
end;
$$;

commit;