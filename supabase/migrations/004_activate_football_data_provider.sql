-- ============================================================
-- FANTAGOL
-- MIGRATION 004
-- ACTIVATE FOOTBALL-DATA.ORG PROVIDER
--
-- Purpose:
--   Register football-data.org as the primary Competition,
--   Calendar and basic Live Score provider for the MVP.
--
-- Properties:
--   - idempotent
--   - non-destructive
--   - no credentials stored
-- ============================================================

begin;

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
  '00000000-0000-4000-8000-000000000404'::uuid,
  'football_data',
  'football-data.org',
  'multi',
  true,
  5,
  'https://api.football-data.org/v4',
  10
)
on conflict (code)
do update
set
  name = excluded.name,
  provider_type = excluded.provider_type,
  active = excluded.active,
  priority = excluded.priority,
  base_url = excluded.base_url,
  rate_limit_per_minute = excluded.rate_limit_per_minute;

-- Providers rejected during MVP evaluation remain registered for
-- historical/audit purposes but are disabled operationally.
update public.data_providers
set
  active = false,
  priority = 90
where code in ('api_football', 'sportmonks_football');

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
  'primary_provider_changed',
  'data_provider',
  p.id,
  null,
  jsonb_build_object(
    'code', p.code,
    'name', p.name,
    'provider_type', p.provider_type,
    'active', p.active,
    'priority', p.priority,
    'base_url', p.base_url,
    'rate_limit_per_minute', p.rate_limit_per_minute
  ),
  'football-data.org selected as MVP primary competition/calendar provider',
  '00000000-0000-4000-8000-000000000004'::uuid
from public.data_providers p
where p.code = 'football_data'
  and not exists (
    select 1
    from public.competition_audit_log cal
    where cal.action = 'primary_provider_changed'
      and cal.aggregate_type = 'data_provider'
      and cal.aggregate_id = p.id
  );

commit;
