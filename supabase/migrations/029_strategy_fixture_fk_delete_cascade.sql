-- Migration 029: Strategy Fixture FK Delete Cascade
-- Purpose:
--   - align the NOT NULL fixture identity with referential behavior;
--   - a Strategy cannot survive without its canonical League Fixture;
--   - deleting a fixture removes its Strategy aggregate and cascades to strategy_versions.

begin;

alter table public.strategies
  drop constraint if exists strategies_league_fixture_id_fkey;

alter table public.strategies
  add constraint strategies_league_fixture_id_fkey
  foreign key (league_fixture_id)
  references public.league_fixtures(id)
  on delete cascade;

comment on constraint strategies_league_fixture_id_fkey
on public.strategies
is 'A Strategy is owned by its canonical League Fixture and is deleted with it.';

commit;
