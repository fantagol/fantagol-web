-- =====================================================================
-- FANTAGOL - MIGRATION 284
-- PREDICTION RECOVERY HISTORICAL DUAL-MEMBER REPAIR
--
-- ONE-OFF DATA CORRECTION.
--
-- Francesco:
--   nine scores come only from immutable Recovery draft history saved
--   before the original deadline.
--
-- Dragone97:
--   nine scores are explicit operator-supplied administrative backfill.
--
-- Both:
--   Milan-Venezia remains the single excluded/missing match.
--   logical official submission time = 2026-08-29 16:30:00+00.
--
-- No Strategy Recovery.
-- =====================================================================

do $repair$
declare
    v_round_id constant uuid :=
        '7f0c7f79-b72f-4654-b744-e8a24b4154d9'::uuid;

    v_francesco_id constant uuid :=
        '3c63f0e8-af67-449e-afef-dd98c3bc5ae3'::uuid;

    v_francesco_auth constant uuid :=
        '688d7444-9e10-4944-8edb-7b7172368adf'::uuid;

    v_dragone_id constant uuid :=
        'f3920786-aab2-47ff-806b-a04f618b1c11'::uuid;

    v_deadline constant timestamptz :=
        '2026-08-29 16:30:00+00'::timestamptz;

    v_scope_at constant timestamptz :=
        '2026-08-29 16:29:59.999999+00'::timestamptz;

    v_fantagol_round_id uuid;
    v_league_id uuid;
    v_dragone_user_id uuid;
    v_dragone_auth uuid;
    v_now timestamptz := clock_timestamp();

    v_required integer;
    v_recoverable integer;
    v_excluded integer;
    v_milan_venezia integer;

    v_fr_source integer;
    v_fr_updated integer;
    v_fr_history integer;

    v_dr_map integer;
    v_dr_inserted integer;
    v_dr_history integer;

    v_count integer;
begin
    -- Resolve league-round identity to canonical/global round identity.
    select lr.fantagol_round_id, lr.league_id
    into v_fantagol_round_id, v_league_id
    from public.league_rounds lr
    where lr.id = v_round_id
    for update;

    if v_fantagol_round_id is null or v_league_id is null then
        raise exception 'R284_LEAGUE_ROUND_NOT_FOUND';
    end if;

    -- -----------------------------------------------------------------
    -- CANONICAL ROUND / HISTORICAL RECOVERY SCOPE
    -- -----------------------------------------------------------------
    select count(*)::integer
    into v_required
    from public.fantagol_round_matches frm
    where frm.fantagol_round_id = v_fantagol_round_id
      and frm.required
      and frm.removed_at is null;

    if v_required <> 10 then
        raise exception 'R284_REQUIRED_MATCHES expected=10 actual=%', v_required;
    end if;

    select count(*)::integer
    into v_recoverable
    from public.get_prediction_recovery_match_scope_internal(
        v_round_id,
        v_scope_at
    ) s
    where s.recoverable;

    if v_recoverable <> 9 then
        raise exception 'R284_RECOVERABLE_MATCHES expected=9 actual=%', v_recoverable;
    end if;

    create temporary table _r284_excluded
    on commit drop
    as
    select
        frm.match_id,
        ht.name as home_team,
        at.name as away_team
    from public.fantagol_round_matches frm
    join public.matches m
      on m.id = frm.match_id
    join public.teams ht
      on ht.id = m.home_team_id
    join public.teams at
      on at.id = m.away_team_id
    where frm.fantagol_round_id = v_fantagol_round_id
      and frm.required
      and frm.removed_at is null
      and not exists (
          select 1
          from public.get_prediction_recovery_match_scope_internal(
              v_round_id,
              v_scope_at
          ) s
          where s.match_id = frm.match_id
            and s.recoverable
      );

    select count(*)::integer into v_excluded from _r284_excluded;

    if v_excluded <> 1 then
        raise exception 'R284_EXCLUDED_COUNT expected=1 actual=%', v_excluded;
    end if;

    select count(*)::integer
    into v_milan_venezia
    from _r284_excluded
    where (
            lower(home_team) like '%milan%'
        and lower(away_team) like '%venezia%'
    )
       or (
            lower(home_team) like '%venezia%'
        and lower(away_team) like '%milan%'
    );

    if v_milan_venezia <> 1 then
        raise exception 'R284_EXCLUDED_MUST_BE_MILAN_VENEZIA';
    end if;

    -- -----------------------------------------------------------------
    -- FRANCESCO: immutable saved Recovery intent.
    -- -----------------------------------------------------------------
    perform 1
    from public.prediction_recovery_authorizations pra
    where pra.id = v_francesco_auth
      and pra.league_round_id = v_round_id
      and pra.target_member_id = v_francesco_id
      and pra.expires_at = v_deadline
    for update;

    if not found then
        raise exception 'R284_FRANCESCO_AUTH_IDENTITY_MISMATCH';
    end if;

    create temporary table _r284_fr_source
    on commit drop
    as
    select distinct on (pv.prediction_id)
        pv.prediction_id,
        p.match_id,
        pv.version as historical_version,
        pv.home_prediction,
        pv.away_prediction,
        pv.changed_at as historical_saved_at
    from public.prediction_versions pv
    join public.predictions p
      on p.id = pv.prediction_id
    where p.league_round_id = v_round_id
      and p.league_member_id = v_francesco_id
      and pv.source = 'admin_recovery'
      and pv.status = 'draft'
      and pv.changed_at < v_deadline
      and pv.metadata->>'operation' = 'recovery_workspace_save'
      and pv.metadata->>'recovery_authorization_id' = v_francesco_auth::text
    order by pv.prediction_id, pv.changed_at desc, pv.version desc;

    select count(*)::integer
    into v_fr_source
    from _r284_fr_source;

    if v_fr_source <> 9 then
        raise exception 'R284_FRANCESCO_SOURCE expected=9 actual=%', v_fr_source;
    end if;

    select count(*)::integer
    into v_count
    from (
        (
            select match_id from _r284_fr_source
            except
            select match_id
            from public.get_prediction_recovery_match_scope_internal(
                v_round_id, v_scope_at
            )
            where recoverable
        )
        union all
        (
            select match_id
            from public.get_prediction_recovery_match_scope_internal(
                v_round_id, v_scope_at
            )
            where recoverable
            except
            select match_id from _r284_fr_source
        )
    ) mismatch;

    if v_count <> 0 then
        raise exception 'R284_FRANCESCO_SCOPE_MISMATCH count=%', v_count;
    end if;

    with changed as (
        update public.predictions p
        set
            home_prediction = src.home_prediction,
            away_prediction = src.away_prediction,
            status = 'submitted',
            source = 'admin_recovery',
            version = p.version + 1,
            submitted_at = v_deadline,
            submitted_version = p.version + 1,
            official_submitted_at = v_deadline,
            locked_at = null,
            updated_at = v_now
        from _r284_fr_source src
        where p.id = src.prediction_id
        returning
            p.id,
            p.match_id,
            p.version,
            p.home_prediction,
            p.away_prediction
    ),
    hist as (
        insert into public.prediction_versions (
            prediction_id,
            version,
            home_prediction,
            away_prediction,
            status,
            source,
            changed_by_user_id,
            changed_by_member_id,
            changed_at,
            metadata
        )
        select
            c.id,
            c.version,
            c.home_prediction,
            c.away_prediction,
            'submitted',
            'admin_recovery',
            null,
            v_francesco_id,
            v_now,
            jsonb_build_object(
                'command', 'BackfillPredictionRecoveryExpiryAutosubmit',
                'operation', 'recovery_expiry_autosubmit_historical_repair',
                'provenance', 'historical_saved_intent',
                'reason', 'complete_saved_grid_at_original_deadline',
                'recovery_authorization_id', v_francesco_auth,
                'league_round_id', v_round_id,
                'match_id', c.match_id,
                'logical_submitted_at', v_deadline,
                'historical_source_version', src.historical_version,
                'historical_saved_at', src.historical_saved_at,
                'migration', 284
            )
        from changed c
        join _r284_fr_source src
          on src.prediction_id = c.id
        returning prediction_id
    )
    select
        (select count(*)::integer from changed),
        (select count(*)::integer from hist)
    into v_fr_updated, v_fr_history;

    if v_fr_updated <> 9 or v_fr_history <> 9 then
        raise exception
            'R284_FRANCESCO_WRITE_COUNTS updated=% history=%',
            v_fr_updated, v_fr_history;
    end if;

    update public.prediction_recovery_authorizations pra
    set
        status = 'used',
        used_at = v_deadline,
        updated_at = v_now,
        version = pra.version + 1
    where pra.id = v_francesco_auth;

    -- -----------------------------------------------------------------
    -- DRAGONE97: explicit operator-supplied administrative backfill.
    -- -----------------------------------------------------------------
    select lm.user_id
    into v_dragone_user_id
    from public.league_members lm
    where lm.id = v_dragone_id
      and lm.league_id = v_league_id
    for update;

    if v_dragone_user_id is null then
        raise exception 'R284_DRAGONE_MEMBER_USER_NOT_FOUND';
    end if;

    select pra.id
    into v_dragone_auth
    from public.prediction_recovery_authorizations pra
    where pra.league_round_id = v_round_id
      and pra.target_member_id = v_dragone_id
      and pra.expires_at = v_deadline
    order by pra.opened_at desc, pra.created_at desc
    limit 1
    for update;

    if v_dragone_auth is null then
        raise exception 'R284_DRAGONE_AUTH_NOT_FOUND';
    end if;

    select count(*)::integer
    into v_count
    from public.predictions p
    where p.league_round_id = v_round_id
      and p.league_member_id = v_dragone_id
      and p.status in ('submitted', 'locked')
      and p.submitted_version is not null;

    if v_count <> 0 then
        raise exception
            'R284_DRAGONE_PREEXISTING_OFFICIAL_PREDICTIONS count=%',
            v_count;
    end if;

    create temporary table _r284_dragone_input (
        home_pattern text not null,
        away_pattern text not null,
        home_prediction integer not null,
        away_prediction integer not null
    ) on commit drop;

    insert into _r284_dragone_input (
        home_pattern,
        away_pattern,
        home_prediction,
        away_prediction
    )
    values
        ('sassuolo',   'torino',    1, 1),
        ('monza',      'udinese',   1, 2),
        ('fiorentina', 'frosinone', 3, 1),
        ('juventus',   'parma',     2, 0),
        ('napoli',     'como',      1, 1),
        ('cagliari',   'inter',     1, 3),
        ('lazio',      'genoa',     1, 1),
        ('lecce',      'roma',      0, 3),
        ('atalanta',   'bologna',   1, 1);

    create temporary table _r284_dragone_map
    on commit drop
    as
    select
        s.match_id,
        i.home_prediction,
        i.away_prediction
    from public.get_prediction_recovery_match_scope_internal(
        v_round_id,
        v_scope_at
    ) s
    join public.matches m
      on m.id = s.match_id
    join public.teams ht
      on ht.id = m.home_team_id
    join public.teams at
      on at.id = m.away_team_id
    join _r284_dragone_input i
      on lower(ht.name) like '%' || i.home_pattern || '%'
     and lower(at.name) like '%' || i.away_pattern || '%'
    where s.recoverable;

    select count(*)::integer
    into v_dr_map
    from _r284_dragone_map;

    if v_dr_map <> 9 then
        raise exception 'R284_DRAGONE_MAP expected=9 actual=%', v_dr_map;
    end if;

    select count(*)::integer
    into v_count
    from (
        (
            select match_id from _r284_dragone_map
            except
            select match_id
            from public.get_prediction_recovery_match_scope_internal(
                v_round_id, v_scope_at
            )
            where recoverable
        )
        union all
        (
            select match_id
            from public.get_prediction_recovery_match_scope_internal(
                v_round_id, v_scope_at
            )
            where recoverable
            except
            select match_id from _r284_dragone_map
        )
    ) mismatch;

    if v_count <> 0 then
        raise exception 'R284_DRAGONE_SCOPE_MISMATCH count=%', v_count;
    end if;

    select count(*)::integer
    into v_count
    from public.predictions p
    join _r284_dragone_map dm
      on dm.match_id = p.match_id
    where p.league_round_id = v_round_id
      and p.league_member_id = v_dragone_id;

    if v_count <> 0 then
        raise exception
            'R284_DRAGONE_EXISTING_AGGREGATES expected=0 actual=%',
            v_count;
    end if;

    create temporary table _r284_dragone_inserted (
        prediction_id uuid not null,
        match_id uuid not null,
        version integer not null,
        home_prediction integer not null,
        away_prediction integer not null
    ) on commit drop;

    with inserted as (
        insert into public.predictions (
            league_id,
            user_id,
            match_id,
            home_prediction,
            away_prediction,
            submitted_at,
            created_at,
            updated_at,
            league_round_id,
            league_member_id,
            status,
            submitted_version,
            official_submitted_at,
            source,
            version,
            locked_at
        )
        select
            v_league_id,
            v_dragone_user_id,
            dm.match_id,
            dm.home_prediction,
            dm.away_prediction,
            v_deadline,
            v_deadline,
            v_now,
            v_round_id,
            v_dragone_id,
            'submitted',
            1,
            v_deadline,
            'admin_recovery',
            1,
            null
        from _r284_dragone_map dm
        returning
            id,
            match_id,
            version,
            home_prediction,
            away_prediction
    )
    insert into _r284_dragone_inserted (
        prediction_id,
        match_id,
        version,
        home_prediction,
        away_prediction
    )
    select
        id,
        match_id,
        version,
        home_prediction,
        away_prediction
    from inserted;

    get diagnostics v_dr_inserted = row_count;

    if v_dr_inserted <> 9 then
        raise exception
            'R284_DRAGONE_INSERT_COUNT expected=9 actual=%',
            v_dr_inserted;
    end if;

    insert into public.prediction_versions (
        prediction_id,
        version,
        home_prediction,
        away_prediction,
        status,
        source,
        changed_by_user_id,
        changed_by_member_id,
        changed_at,
        metadata
    )
    select
        di.prediction_id,
        di.version,
        di.home_prediction,
        di.away_prediction,
        'submitted',
        'admin_recovery',
        null,
        v_dragone_id,
        v_now,
        jsonb_build_object(
            'command', 'AdministrativePredictionRecoveryHistoricalBackfill',
            'operation', 'recovery_historical_manual_admin_backfill',
            'provenance', 'explicit_operator_supplied_scores',
            'reason', 'retroactive_recovery_equivalence_correction',
            'recovery_authorization_id', v_dragone_auth,
            'league_round_id', v_round_id,
            'match_id', di.match_id,
            'logical_submitted_at', v_deadline,
            'migration', 284
        )
    from _r284_dragone_inserted di;

    get diagnostics v_dr_history = row_count;

    if v_dr_history <> 9 then
        raise exception
            'R284_DRAGONE_HISTORY_COUNT expected=9 actual=%',
            v_dr_history;
    end if;

    update public.prediction_recovery_authorizations pra
    set
        status = 'used',
        used_at = v_deadline,
        updated_at = v_now,
        version = pra.version + 1
    where pra.id = v_dragone_auth;

    -- -----------------------------------------------------------------
    -- FINAL HARD POSTCONDITIONS.
    -- -----------------------------------------------------------------
    select count(*)::integer
    into v_count
    from public.predictions p
    where p.league_round_id = v_round_id
      and p.league_member_id = v_francesco_id
      and p.status in ('submitted','locked')
      and p.submitted_version is not null
      and p.official_submitted_at = v_deadline;

    if v_count <> 9 then
        raise exception
            'R284_FRANCESCO_FINAL_OFFICIAL expected=9 actual=%',
            v_count;
    end if;

    select count(*)::integer
    into v_count
    from public.predictions p
    where p.league_round_id = v_round_id
      and p.league_member_id = v_dragone_id
      and p.status in ('submitted','locked')
      and p.submitted_version is not null
      and p.official_submitted_at = v_deadline;

    if v_count <> 9 then
        raise exception
            'R284_DRAGONE_FINAL_OFFICIAL expected=9 actual=%',
            v_count;
    end if;

    -- Excluded Milan-Venezia must have no aggregate at all for either.
    select count(*)::integer
    into v_count
    from public.predictions p
    join _r284_excluded e
      on e.match_id = p.match_id
    where p.league_round_id = v_round_id
      and p.league_member_id in (v_francesco_id, v_dragone_id);

    if v_count <> 0 then
        raise exception
            'R284_MILAN_VENEZIA_MUST_REMAIN_EMPTY_FOR_BOTH count=%',
            v_count;
    end if;
end;
$repair$;
