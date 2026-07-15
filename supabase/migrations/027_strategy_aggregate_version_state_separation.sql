-- Migration 027: Strategy Aggregate / Version State Separation
-- Purpose:
--   - keep public.strategies as the lightweight lifecycle aggregate;
--   - make public.strategy_versions the only canonical store for Strategy payloads;
--   - avoid duplicating mutable JSON state in the aggregate row.
--
-- Preconditions:
--   - Migration 026 has been applied;
--   - no Strategy command RPCs are active yet;
--   - no production Strategy workspace data exists.

begin;

-- Defensive check: the correction is intended before Strategy data exists.
do $block$
begin
  if exists (select 1 from public.strategies limit 1) then
    raise exception using
      errcode = 'P0001',
      message = 'STRATEGY_AGGREGATE_REFINEMENT_REQUIRES_EMPTY_TABLE';
  end if;
end;
$block$;

alter table public.strategies
  drop constraint if exists strategies_payload_object_check;

alter table public.strategies
  drop column if exists payload;

comment on table public.strategies is
'Unified Strategy lifecycle aggregate. Workspace and official state payloads exist only as immutable rows in strategy_versions; version identifies the current workspace version and submitted_version identifies the official snapshot.';

comment on column public.strategies.version is
'Current private workspace version. Resolve its payload from strategy_versions using strategy_id and version.';

comment on column public.strategies.submitted_version is
'Latest officially submitted Strategy Snapshot version. Resolve its payload from strategy_versions using strategy_id and submitted_version.';

commit;
