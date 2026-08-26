-- ============================================================
-- FANTAGOL - MIGRATION 274
-- THE ODDS API ROUND MAPPING BOOTSTRAP AUTHORITY
-- ============================================================

create or replace function public.persist_the_odds_round_mapping_bootstrap_internal(
    p_fantagol_round_id uuid,
    p_mappings jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
    v_provider_id uuid;
    v_required_count integer;
    v_input_count integer;
    v_distinct_internal integer;
    v_distinct_external integer;
    v_bad_round_members integer;
    v_bad_slots integer;
    v_missing_required integer;
    v_conflicts integer;
    v_inserted integer;
    v_mapped integer;
    v_mapped_external integer;
begin
    if p_fantagol_round_id is null then
        raise exception
            'THE_ODDS_BOOTSTRAP_ROUND_REQUIRED';
    end if;

    if
        p_mappings is null
        or jsonb_typeof(p_mappings) <> 'array'
    then
        raise exception
            'THE_ODDS_BOOTSTRAP_MAPPINGS_ARRAY_REQUIRED';
    end if;

    perform pg_advisory_xact_lock(
        hashtextextended(
            'the_odds_round_mapping_bootstrap:' ||
            p_fantagol_round_id::text,
            0
        )
    );

    select dp.id
    into v_provider_id
    from public.data_providers dp
    where dp.code = 'the_odds_api'
      and dp.active = true
    limit 1;

    if v_provider_id is null then
        raise exception
            'THE_ODDS_BOOTSTRAP_PROVIDER_NOT_ACTIVE';
    end if;

    select count(*)
    into v_required_count
    from public.fantagol_round_matches frm
    where frm.fantagol_round_id =
            p_fantagol_round_id
      and frm.required = true
      and frm.removed_at is null;

    if v_required_count <= 0 then
        raise exception
            'THE_ODDS_BOOTSTRAP_REQUIRED_MATCH_SET_EMPTY';
    end if;

    with input_rows as (
        select
            x.match_id,
            x.slot_number,
            btrim(x.external_id)
                as external_id
        from jsonb_to_recordset(
            p_mappings
        ) as x(
            match_id uuid,
            slot_number integer,
            external_id text
        )
    )
    select
        count(*),
        count(distinct match_id),
        count(distinct external_id)
    into
        v_input_count,
        v_distinct_internal,
        v_distinct_external
    from input_rows
    where match_id is not null
      and slot_number is not null
      and slot_number > 0
      and external_id is not null
      and external_id <> '';

    if
        v_input_count <> v_required_count
        or v_distinct_internal <>
            v_required_count
        or v_distinct_external <>
            v_required_count
    then
        raise exception
            'THE_ODDS_BOOTSTRAP_EXACT_CARDINALITY_FAILED:%:%:%:%',
            v_required_count,
            v_input_count,
            v_distinct_internal,
            v_distinct_external;
    end if;

    with input_rows as (
        select
            x.match_id,
            x.slot_number,
            btrim(x.external_id)
                as external_id
        from jsonb_to_recordset(
            p_mappings
        ) as x(
            match_id uuid,
            slot_number integer,
            external_id text
        )
    )
    select count(*)
    into v_bad_round_members
    from input_rows i
    left join public.fantagol_round_matches frm
      on frm.fantagol_round_id =
            p_fantagol_round_id
     and frm.match_id =
            i.match_id
     and frm.required = true
     and frm.removed_at is null
    where frm.match_id is null;

    if v_bad_round_members <> 0 then
        raise exception
            'THE_ODDS_BOOTSTRAP_NON_CANONICAL_MATCHES:%',
            v_bad_round_members;
    end if;

    with input_rows as (
        select
            x.match_id,
            x.slot_number,
            btrim(x.external_id)
                as external_id
        from jsonb_to_recordset(
            p_mappings
        ) as x(
            match_id uuid,
            slot_number integer,
            external_id text
        )
    )
    select count(*)
    into v_bad_slots
    from input_rows i
    join public.fantagol_round_matches frm
      on frm.fantagol_round_id =
            p_fantagol_round_id
     and frm.match_id =
            i.match_id
     and frm.required = true
     and frm.removed_at is null
    where frm.slot_number <>
            i.slot_number;

    if v_bad_slots <> 0 then
        raise exception
            'THE_ODDS_BOOTSTRAP_SLOT_MISMATCHES:%',
            v_bad_slots;
    end if;

    with input_rows as (
        select
            x.match_id
        from jsonb_to_recordset(
            p_mappings
        ) as x(
            match_id uuid,
            slot_number integer,
            external_id text
        )
    )
    select count(*)
    into v_missing_required
    from public.fantagol_round_matches frm
    left join input_rows i
      on i.match_id =
            frm.match_id
    where frm.fantagol_round_id =
            p_fantagol_round_id
      and frm.required = true
      and frm.removed_at is null
      and i.match_id is null;

    if v_missing_required <> 0 then
        raise exception
            'THE_ODDS_BOOTSTRAP_REQUIRED_MATCHES_MISSING:%',
            v_missing_required;
    end if;

    with input_rows as (
        select
            x.match_id,
            btrim(x.external_id)
                as external_id
        from jsonb_to_recordset(
            p_mappings
        ) as x(
            match_id uuid,
            slot_number integer,
            external_id text
        )
    )
    select count(*)
    into v_conflicts
    from public.provider_entity_maps pem
    join input_rows i
      on (
          pem.internal_id =
            i.match_id
          or pem.external_id =
            i.external_id
      )
    where pem.provider_id =
            v_provider_id
      and pem.entity_type =
            'match'
      and not (
          pem.internal_id =
            i.match_id
          and pem.external_id =
            i.external_id
      );

    if v_conflicts <> 0 then
        raise exception
            'THE_ODDS_BOOTSTRAP_EXISTING_MAPPING_CONFLICTS:%',
            v_conflicts;
    end if;

    with input_rows as (
        select
            x.match_id,
            btrim(x.external_id)
                as external_id
        from jsonb_to_recordset(
            p_mappings
        ) as x(
            match_id uuid,
            slot_number integer,
            external_id text
        )
    ),
    inserted as (
        insert into public.provider_entity_maps(
            provider_id,
            entity_type,
            internal_id,
            external_id
        )
        select
            v_provider_id,
            'match',
            i.match_id,
            i.external_id
        from input_rows i
        where not exists (
            select 1
            from public.provider_entity_maps pem
            where pem.provider_id =
                    v_provider_id
              and pem.entity_type =
                    'match'
              and pem.internal_id =
                    i.match_id
              and pem.external_id =
                    i.external_id
        )
        returning 1
    )
    select count(*)
    into v_inserted
    from inserted;

    select
        count(*),
        count(distinct pem.external_id)
    into
        v_mapped,
        v_mapped_external
    from public.fantagol_round_matches frm
    join public.provider_entity_maps pem
      on pem.provider_id =
            v_provider_id
     and pem.entity_type =
            'match'
     and pem.internal_id =
            frm.match_id
    where frm.fantagol_round_id =
            p_fantagol_round_id
      and frm.required = true
      and frm.removed_at is null;

    if
        v_mapped <> v_required_count
        or v_mapped_external <>
            v_required_count
    then
        raise exception
            'THE_ODDS_BOOTSTRAP_POSTWRITE_CERTIFICATION_FAILED:%:%:%',
            v_required_count,
            v_mapped,
            v_mapped_external;
    end if;

    return jsonb_build_object(
        'provider_code',
            'the_odds_api',
        'required_match_count',
            v_required_count,
        'mapped_match_count',
            v_mapped,
        'distinct_external_match_count',
            v_mapped_external,
        'inserted_match_count',
            v_inserted,
        'idempotent',
            v_inserted = 0
    );
end;
$$;

revoke all
on function
public.persist_the_odds_round_mapping_bootstrap_internal(
    uuid,
    jsonb
)
from public;

comment on function
public.persist_the_odds_round_mapping_bootstrap_internal(
    uuid,
    jsonb
)
is
'Atomic fail-closed The Odds API Round mapping bootstrap authority. Requires exact canonical required Match Set coverage and conflict-free idempotent activation.';
