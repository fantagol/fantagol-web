begin;

-- ============================================================================
-- FANTAGOL - MIGRATION 258
-- OFFICIAL MATCH ODDS V2 CONSUMER HARDENING
--
-- DEPENDS ON
--   264_official_match_odds_authority_v2.sql
--
-- PURPOSE
--
--   Make every canonical Official Match Odds consumer explicitly obey
--   the V2 authority model.
--
--   V2 read authority:
--
--       get_active_official_match_odds_snapshot_internal(match_id)
--
--   V2 source evidence validator:
--
--       assert_real_official_odds_source_internal(
--           match_id,
--           odds_market_snapshot_id
--       )
--
-- TARGETS
--
--   1. freeze_match_odds_snapshot_rpc
--   2. evaluate_match_certification_readiness_rpc
--   3. certify_match_result_rpc
--   4. build_community_snapshot_rpc
--
-- SAFETY
--
--   - exact baseline fragments are required
--   - each patch anchor must occur exactly once
--   - migration fails closed on baseline drift
--   - no scoring
--   - no certification execution
--   - no job enqueue
--   - no job claim
--   - no publication
-- ============================================================================


-- ============================================================================
-- 0. DEPENDENCY ASSERTIONS
-- ============================================================================

do $migration$
begin

    if to_regprocedure(
        'public.get_active_official_match_odds_snapshot_internal(uuid)'
    ) is null then

        raise exception using
            errcode = 'P0001',
            message =
                'MIGRATION_257_ACTIVE_ODDS_RESOLVER_REQUIRED';

    end if;


    if to_regprocedure(
        'public.assert_real_official_odds_source_internal(uuid,uuid)'
    ) is null then

        raise exception using
            errcode = 'P0001',
            message =
                'MIGRATION_257_REAL_ODDS_VALIDATOR_REQUIRED';

    end if;

end;
$migration$;


-- ============================================================================
-- 1. FREEZE CONSUMER
-- ============================================================================

do $migration$
declare
    v_signature regprocedure :=
        'public.freeze_match_odds_snapshot_rpc(uuid,timestamp with time zone,text,text)'::regprocedure;

    v_definition text;
    v_old text;
    v_new text;
    v_count integer;
begin

    select pg_get_functiondef(v_signature)
    into v_definition;


    -- Existing authority must resolve through V2.

    v_old := $old$
  select *
    into v_existing
  from public.official_match_odds_snapshots omos
  where omos.match_id = p_match_id;
$old$;

    v_new := $new$
  v_existing :=
    public.get_active_official_match_odds_snapshot_internal(
      p_match_id
    );
$new$;

    v_count :=
        (
            length(v_definition)
            -
            length(replace(v_definition, v_old, ''))
        )
        /
        nullif(length(v_old), 0);

    if v_count <> 1 then
        raise exception using
            errcode = 'P0001',
            message =
                'M258_FREEZE_EXISTING_AUTHORITY_BASELINE_DRIFT',
            detail =
                jsonb_build_object(
                    'occurrence_count',
                    v_count
                )::text;
    end if;

    v_definition :=
        replace(
            v_definition,
            v_old,
            v_new
        );


    -- Candidate selection excludes synthetic / test / E2E evidence.

    v_old := $old$
  where oms.match_id = p_match_id
    and oms.collected_at <= p_freeze_at
    and oms.consensus_payload is not null
    and coalesce((oms.quality_payload ->> 'hasConsensus')::boolean, false) = true
  order by oms.collected_at desc, oms.created_at desc
  limit 1;
$old$;

    v_new := $new$
   where oms.match_id = p_match_id
     and oms.collected_at <= p_freeze_at
     and oms.consensus_payload is not null
     and coalesce((oms.quality_payload ->> 'hasConsensus')::boolean, false) = true
     and coalesce((oms.quality_payload ->> 'synthetic')::boolean, false) = false
     and nullif(oms.quality_payload ->> 'testScope', '') is null
     and coalesce((oms.provider_payload ->> 'synthetic')::boolean, false) = false
     and nullif(oms.provider_payload ->> 'testScope', '') is null
     and oms.external_match_id not ilike 'e2e-%'
   order by oms.collected_at desc, oms.created_at desc, oms.id desc
   limit 1;
$new$;

    v_count :=
        (
            length(v_definition)
            -
            length(replace(v_definition, v_old, ''))
        )
        /
        nullif(length(v_old), 0);

    if v_count <> 1 then
        raise exception using
            errcode = 'P0001',
            message =
                'M258_FREEZE_SOURCE_SELECTION_BASELINE_DRIFT',
            detail =
                jsonb_build_object(
                    'occurrence_count',
                    v_count
                )::text;
    end if;

    v_definition :=
        replace(
            v_definition,
            v_old,
            v_new
        );


    -- Candidate is centrally revalidated before official hash creation.

    v_old := $old$
  if v_source.id is null then
    raise exception
      'no valid odds snapshot available for match % at or before %',
      p_match_id,
      p_freeze_at;
  end if;

  v_official_hash := encode(
$old$;

    v_new := $new$
   if v_source.id is null then
     raise exception
       'no valid odds snapshot available for match % at or before %',
       p_match_id,
       p_freeze_at;
   end if;

   v_source :=
     public.assert_real_official_odds_source_internal(
       p_match_id,
       v_source.id
     );

   v_official_hash := encode(
$new$;

    v_count :=
        (
            length(v_definition)
            -
            length(replace(v_definition, v_old, ''))
        )
        /
        nullif(length(v_old), 0);

    if v_count <> 1 then
        raise exception using
            errcode = 'P0001',
            message =
                'M258_FREEZE_VALIDATOR_BASELINE_DRIFT',
            detail =
                jsonb_build_object(
                    'occurrence_count',
                    v_count
                )::text;
    end if;

    v_definition :=
        replace(
            v_definition,
            v_old,
            v_new
        );


    execute v_definition;

end;
$migration$;


-- ============================================================================
-- 2. READINESS CONSUMER
-- ============================================================================

do $migration$
declare
    v_signature regprocedure :=
        'public.evaluate_match_certification_readiness_rpc(uuid,integer,boolean,uuid)'::regprocedure;

    v_definition text;
    v_old text;
    v_new text;
    v_count integer;
begin

    select pg_get_functiondef(v_signature)
    into v_definition;


    v_old := $old$
  select o.*
    into v_odds
  from public.official_match_odds_snapshots o
  where o.match_id = p_match_id
  order by o.frozen_at desc, o.created_at desc, o.id desc
  limit 1;
$old$;

    v_new := $new$
   v_odds :=
     public.get_active_official_match_odds_snapshot_internal(
       p_match_id
     );

   if p_require_official_odds and v_odds.id is not null then
     perform
       public.assert_real_official_odds_source_internal(
         p_match_id,
         v_odds.odds_market_snapshot_id
       );
   end if;
$new$;

    v_count :=
        (
            length(v_definition)
            -
            length(replace(v_definition, v_old, ''))
        )
        /
        nullif(length(v_old), 0);

    if v_count <> 1 then
        raise exception using
            errcode = 'P0001',
            message =
                'M258_READINESS_AUTHORITY_BASELINE_DRIFT',
            detail =
                jsonb_build_object(
                    'occurrence_count',
                    v_count
                )::text;
    end if;

    v_definition :=
        replace(
            v_definition,
            v_old,
            v_new
        );

    execute v_definition;

end;
$migration$;


-- ============================================================================
-- 3. CERTIFICATION CONSUMER
-- ============================================================================

do $migration$
declare
    v_signature regprocedure :=
        'public.certify_match_result_rpc(uuid,integer,boolean,text,text,text,uuid)'::regprocedure;

    v_definition text;
    v_old text;
    v_new text;
    v_count integer;
begin

    select pg_get_functiondef(v_signature)
    into v_definition;


    v_old := $old$
  select o.* into v_odds
  from public.official_match_odds_snapshots o
  where o.match_id = p_match_id
  order by o.frozen_at desc, o.created_at desc, o.id desc
  limit 1;
$old$;

    v_new := $new$
   v_odds :=
     public.get_active_official_match_odds_snapshot_internal(
       p_match_id
     );

   if p_require_official_odds and v_odds.id is not null then
     perform
       public.assert_real_official_odds_source_internal(
         p_match_id,
         v_odds.odds_market_snapshot_id
       );
   end if;
$new$;

    v_count :=
        (
            length(v_definition)
            -
            length(replace(v_definition, v_old, ''))
        )
        /
        nullif(length(v_old), 0);

    if v_count <> 1 then
        raise exception using
            errcode = 'P0001',
            message =
                'M258_CERTIFY_AUTHORITY_BASELINE_DRIFT',
            detail =
                jsonb_build_object(
                    'occurrence_count',
                    v_count
                )::text;
    end if;

    v_definition :=
        replace(
            v_definition,
            v_old,
            v_new
        );

    execute v_definition;

end;
$migration$;


-- ============================================================================
-- 4. COMMUNITY INTELLIGENCE CONSUMER
-- ============================================================================

do $migration$
declare
    v_signature regprocedure :=
        'public.build_community_snapshot_rpc(uuid,text,text,uuid,boolean)'::regprocedure;

    v_definition text;
    v_old text;
    v_new text;
    v_count integer;
begin

    select pg_get_functiondef(v_signature)
    into v_definition;


    v_old := $old$
            select oms.odds_market_snapshot_id,
                   jsonb_build_object(
                       'market_available', true,
                       'official_snapshot_id', oms.id,
                       'odds_market_snapshot_id', oms.odds_market_snapshot_id,
                       'frozen_at', oms.frozen_at,
                       'policy_version', oms.policy_version,
                       'consensus', om.consensus_payload,
                       'quality', om.quality_payload,
                       'collected_at', om.collected_at
                   )
              into v_market_snapshot_id, v_market_context
              from public.official_match_odds_snapshots oms
              join public.odds_market_snapshots om
                on om.id = oms.odds_market_snapshot_id
             where oms.match_id = v_match.match_id
             limit 1;
$old$;

    v_new := $new$
             select oms.odds_market_snapshot_id,
                    jsonb_build_object(
                        'market_available', true,
                        'official_snapshot_id', oms.id,
                        'odds_market_snapshot_id', oms.odds_market_snapshot_id,
                        'authority_version', oms.authority_version,
                        'authority_status', oms.status,
                        'frozen_at', oms.frozen_at,
                        'policy_version', oms.policy_version,
                        'consensus', om.consensus_payload,
                        'quality', om.quality_payload,
                        'collected_at', om.collected_at
                    )
               into v_market_snapshot_id, v_market_context
               from public.official_match_odds_snapshots oms
               join public.odds_market_snapshots om
                 on om.id = oms.odds_market_snapshot_id
              where oms.id = (
                  public.get_active_official_match_odds_snapshot_internal(
                      v_match.match_id
                  )
              ).id;

             if v_market_snapshot_id is not null then
                 perform
                     public.assert_real_official_odds_source_internal(
                         v_match.match_id,
                         v_market_snapshot_id
                     );
             end if;
$new$;

    v_count :=
        (
            length(v_definition)
            -
            length(replace(v_definition, v_old, ''))
        )
        /
        nullif(length(v_old), 0);

    if v_count <> 1 then
        raise exception using
            errcode = 'P0001',
            message =
                'M258_COMMUNITY_AUTHORITY_BASELINE_DRIFT',
            detail =
                jsonb_build_object(
                    'occurrence_count',
                    v_count
                )::text;
    end if;

    v_definition :=
        replace(
            v_definition,
            v_old,
            v_new
        );

    execute v_definition;

end;
$migration$;


-- ============================================================================
-- 5. POST-INSTALL CONTRACT
-- ============================================================================

do $migration$
declare
    v_freeze text;
    v_readiness text;
    v_certify text;
    v_community text;
begin

    select pg_get_functiondef(
        'public.freeze_match_odds_snapshot_rpc(uuid,timestamp with time zone,text,text)'::regprocedure
    )
    into v_freeze;

    select pg_get_functiondef(
        'public.evaluate_match_certification_readiness_rpc(uuid,integer,boolean,uuid)'::regprocedure
    )
    into v_readiness;

    select pg_get_functiondef(
        'public.certify_match_result_rpc(uuid,integer,boolean,text,text,text,uuid)'::regprocedure
    )
    into v_certify;

    select pg_get_functiondef(
        'public.build_community_snapshot_rpc(uuid,text,text,uuid,boolean)'::regprocedure
    )
    into v_community;


    if
        position(
            'get_active_official_match_odds_snapshot_internal'
            in v_freeze
        ) = 0
        or
        position(
            'assert_real_official_odds_source_internal'
            in v_freeze
        ) = 0
        or
        position(
            'external_match_id not ilike ''e2e-%'''
            in v_freeze
        ) = 0
    then
        raise exception using
            errcode = 'P0001',
            message =
                'M258_FREEZE_CONTRACT_INCOMPLETE';
    end if;


    if
        position(
            'get_active_official_match_odds_snapshot_internal'
            in v_readiness
        ) = 0
        or
        position(
            'assert_real_official_odds_source_internal'
            in v_readiness
        ) = 0
    then
        raise exception using
            errcode = 'P0001',
            message =
                'M258_READINESS_CONTRACT_INCOMPLETE';
    end if;


    if
        position(
            'get_active_official_match_odds_snapshot_internal'
            in v_certify
        ) = 0
        or
        position(
            'assert_real_official_odds_source_internal'
            in v_certify
        ) = 0
    then
        raise exception using
            errcode = 'P0001',
            message =
                'M258_CERTIFY_CONTRACT_INCOMPLETE';
    end if;


    if
        position(
            'get_active_official_match_odds_snapshot_internal'
            in v_community
        ) = 0
        or
        position(
            'assert_real_official_odds_source_internal'
            in v_community
        ) = 0
        or
        position(
            '''authority_version'''
            in v_community
        ) = 0
        or
        position(
            '''authority_status'''
            in v_community
        ) = 0
    then
        raise exception using
            errcode = 'P0001',
            message =
                'M258_COMMUNITY_CONTRACT_INCOMPLETE';
    end if;

end;
$migration$;


-- ============================================================================
-- 6. SECURITY PRESERVATION
-- ============================================================================

revoke all
on function
public.freeze_match_odds_snapshot_rpc(
    uuid,
    timestamptz,
    text,
    text
)
from public, anon, authenticated;


revoke all
on function
public.evaluate_match_certification_readiness_rpc(
    uuid,
    integer,
    boolean,
    uuid
)
from public, anon, authenticated;


revoke all
on function
public.certify_match_result_rpc(
    uuid,
    integer,
    boolean,
    text,
    text,
    text,
    uuid
)
from public, anon, authenticated;


revoke all
on function
public.build_community_snapshot_rpc(
    uuid,
    text,
    text,
    uuid,
    boolean
)
from public, anon, authenticated;


grant execute
on function
public.freeze_match_odds_snapshot_rpc(
    uuid,
    timestamptz,
    text,
    text
)
to service_role;


grant execute
on function
public.evaluate_match_certification_readiness_rpc(
    uuid,
    integer,
    boolean,
    uuid
)
to service_role;


grant execute
on function
public.certify_match_result_rpc(
    uuid,
    integer,
    boolean,
    text,
    text,
    text,
    uuid
)
to service_role;


grant execute
on function
public.build_community_snapshot_rpc(
    uuid,
    text,
    text,
    uuid,
    boolean
)
to service_role;


comment on function
public.evaluate_match_certification_readiness_rpc(
    uuid,
    integer,
    boolean,
    uuid
)
is
'Match certification readiness hardened for Official Match Odds Authority V2. Resolves only the active official authority and validates its source as real production evidence.';


comment on function
public.certify_match_result_rpc(
    uuid,
    integer,
    boolean,
    text,
    text,
    text,
    uuid
)
is
'Match result certification hardened for Official Match Odds Authority V2. Certification evidence can bind only the active official authority backed by validated real production market evidence.';


commit;