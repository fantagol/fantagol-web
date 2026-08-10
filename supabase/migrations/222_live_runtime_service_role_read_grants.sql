begin;

-- FantaGol A8D.6.7E
-- Minimal service_role read contract required by the
-- Football Data aggregated live-runtime execution path.
--
-- Intentionally grants SELECT only.
-- No mutation privilege is introduced.

grant select
on table public.matches
to service_role;

grant select
on table public.league_rounds
to service_role;

comment on table public.matches is
'Canonical football Match registry. service_role SELECT is required by the certified live-runtime provider ingestion path.';

comment on table public.league_rounds is
'League round runtime state. service_role SELECT is required by the certified live-runtime scheduling and ingestion path.';

commit;