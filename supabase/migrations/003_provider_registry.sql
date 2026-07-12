-- ============================================================
-- FANTAGOL
-- MIGRATION 003
-- PROVIDER REGISTRY
--
-- Purpose:
--   Register the external data providers selected for the MVP.
--
-- Providers:
--   - API-Football: primary calendar and live-score provider
--   - The Odds API: primary odds provider
--   - Sportmonks: fallback calendar and live-score provider
--
-- Properties:
--   - idempotent
--   - non-destructive
--   - no API credentials stored
--   - no plan-specific limits hardcoded
-- ============================================================

begin;

-- ------------------------------------------------------------
-- 1. API-FOOTBALL / API-SPORTS
-- Primary Competition, Calendar and Live Score provider
-- ------------------------------------------------------------

insert into public.data_providers (
  id,
  code,
  name,
  provider_type,
  active,
  priority,
  base_url,
  rate_limit_per_minute
)
values (
  '00000000-0000-4000-8000-000000000401'::uuid,
  'api_football',
  'API-Football',
  'multi',
  true,
  10,
  'https://v3.football.api-sports.io',
  null
)
on conflict (code)
do update
set
  name = excluded.name,
  provider_type = excluded.provider_type,
  active = excluded.active,
  priority = excluded.priority,
  base_url = excluded.base_url;

-- ------------------------------------------------------------
-- 2. THE ODDS API
-- Primary pre-match odds provider
-- ------------------------------------------------------------

insert into public.data_providers (
  id,
  code,
  name,
  provider_type,
  active,
  priority,
  base_url,
  rate_limit_per_minute
)
values (
  '00000000-0000-4000-8000-000000000402'::uuid,
  'the_odds_api',
  'The Odds API',
  'odds',
  true,
  10,
  'https://api.the-odds-api.com/v4',
  null
)
on conflict (code)
do update
set
  name = excluded.name,
  provider_type = excluded.provider_type,
  active = excluded.active,
  priority = excluded.priority,
  base_url = excluded.base_url;

-- ------------------------------------------------------------
-- 3. SPORTMONKS FOOTBALL API
-- Calendar and Live Score fallback provider
-- ------------------------------------------------------------

insert into public.data_providers (
  id,
  code,
  name,
  provider_type,
  active,
  priority,
  base_url,
  rate_limit_per_minute
)
values (
  '00000000-0000-4000-8000-000000000403'::uuid,
  'sportmonks_football',
  'Sportmonks Football API',
  'multi',
  true,
  20,
  'https://api.sportmonks.com/v3/football',
  null
)
on conflict (code)
do update
set
  name = excluded.name,
  provider_type = excluded.provider_type,
  active = excluded.active,
  priority = excluded.priority,
  base_url = excluded.base_url;

-- ------------------------------------------------------------
-- 4. AUDIT
-- One append-only event for this registry installation
-- ------------------------------------------------------------

insert into public.competition_audit_log (
  actor_id,
  action,
  aggregate_type,
  aggregate_id,
  before_json,
  after_json,
  reason,
  correlation_id
)
select
  null,
  'provider_registry_seeded',
  'data_provider',
  p.id,
  null,
  jsonb_build_object(
    'code', p.code,
    'name', p.name,
    'provider_type', p.provider_type,
    'active', p.active,
    'priority', p.priority,
    'base_url', p.base_url
  ),
  case p.code
    when 'api_football'
      then 'Primary Competition, Calendar and Live Score provider'
    when 'the_odds_api'
      then 'Primary pre-match Odds provider'
    when 'sportmonks_football'
      then 'Fallback Calendar and Live Score provider'
  end,
  '00000000-0000-4000-8000-000000000003'::uuid
from public.data_providers p
where p.code in (
  'api_football',
  'the_odds_api',
  'sportmonks_football'
)
and not exists (
  select 1
  from public.competition_audit_log cal
  where cal.action = 'provider_registry_seeded'
    and cal.aggregate_type = 'data_provider'
    and cal.aggregate_id = p.id
);

commit;