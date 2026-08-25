-- =====================================================================
-- FANTAGOL - MIGRATION 271
-- COMMERCIAL CAMPAIGN CANONICAL CONFIGURATION PROJECTION
--
-- Purpose:
--   Separate immutable/governed commercial campaign configuration
--   from lifecycle/runtime mutable projection.
--
-- Runtime mutable fields intentionally excluded:
--   enabled
--   version
--   issued_claims
--   issued_passes
--   created_at
--   updated_at
--
-- R46 invariants:
--   - no reward activation
--   - no producer activation
--   - no policy activation
--   - no campaign activation
--   - no achievement emission
--   - no loyalty dispatch
--   - no reward backfill
-- =====================================================================

create or replace function public.commercial_campaign_configuration_projection_internal(
    p_campaign public.reward_campaigns
)
returns jsonb
language sql
immutable
set search_path = public, pg_temp
as $function$
    select
        to_jsonb(p_campaign)
        - array[
            'enabled',
            'version',
            'issued_claims',
            'issued_passes',
            'created_at',
            'updated_at'
          ];
$function$;

comment on function public.commercial_campaign_configuration_projection_internal(
    public.reward_campaigns
)
is
'Canonical governed reward-campaign configuration projection. Excludes lifecycle/runtime mutable state and counters.';


create or replace function public.create_commercial_campaign_version_internal(
    p_campaign_id uuid,
    p_created_by text,
    p_change_summary text default null,
    p_metadata jsonb default '{}'::jsonb,
    p_correlation_id uuid default null,
    p_causation_id uuid default null
)
returns public.commercial_campaign_versions
language plpgsql
security definer
set search_path = public, pg_temp
as $function$
declare
    v_campaign public.reward_campaigns;
    v_snapshot jsonb;
    v_version_number integer;
    v_result public.commercial_campaign_versions;
begin
    select *
    into v_campaign
    from public.reward_campaigns
    where id = p_campaign_id
    for update;

    if not found then
        raise exception
            using errcode = 'P0001',
                  message = 'COMMERCIAL_CAMPAIGN_NOT_FOUND';
    end if;

    if nullif(btrim(p_created_by), '') is null then
        raise exception
            using errcode = 'P0001',
                  message = 'COMMERCIAL_CAMPAIGN_ACTOR_REQUIRED';
    end if;

    if jsonb_typeof(coalesce(p_metadata, '{}'::jsonb)) <> 'object' then
        raise exception
            using errcode = 'P0001',
                  message = 'COMMERCIAL_CAMPAIGN_METADATA_MUST_BE_OBJECT';
    end if;

    v_snapshot :=
        public.commercial_campaign_configuration_projection_internal(
            v_campaign
        );

    select coalesce(max(version_number), 0) + 1
    into v_version_number
    from public.commercial_campaign_versions
    where campaign_id = p_campaign_id;

    insert into public.commercial_campaign_versions (
        campaign_id,
        campaign_code,
        version_number,
        version_status,
        configuration_snapshot,
        configuration_hash,
        change_summary,
        created_by,
        metadata
    )
    values (
        v_campaign.id,
        v_campaign.campaign_code,
        v_version_number,
        'draft',
        v_snapshot,
        md5(v_snapshot::text),
        p_change_summary,
        btrim(p_created_by),
        coalesce(p_metadata, '{}'::jsonb)
    )
    returning *
    into v_result;

    perform public.append_commercial_campaign_lifecycle_event_internal(
        p_campaign_id := v_campaign.id,
        p_campaign_version_id := v_result.id,
        p_activation_request_id := null,
        p_event_type := 'VERSION_CREATED',
        p_previous_state := null,
        p_resulting_state := 'draft',
        p_actor := p_created_by,
        p_reason := p_change_summary,
        p_correlation_id := p_correlation_id,
        p_causation_id := p_causation_id,
        p_payload := jsonb_build_object(
            'version_number', v_result.version_number,
            'configuration_hash', v_result.configuration_hash
        )
    );

    return v_result;
end;
$function$;


create or replace function public.approve_commercial_campaign_version_internal(
    p_campaign_version_id uuid,
    p_approved_by text,
    p_reason text default null,
    p_correlation_id uuid default null,
    p_causation_id uuid default null
)
returns public.commercial_campaign_versions
language plpgsql
security definer
set search_path = public, pg_temp
as $function$
declare
    v_version public.commercial_campaign_versions;
    v_campaign public.reward_campaigns;
    v_current_snapshot jsonb;
    v_previous_approved_id uuid;
    v_result public.commercial_campaign_versions;
begin
    select *
    into v_version
    from public.commercial_campaign_versions
    where id = p_campaign_version_id
    for update;

    if not found then
        raise exception
            using errcode = 'P0001',
                  message = 'COMMERCIAL_CAMPAIGN_VERSION_NOT_FOUND';
    end if;

    if v_version.version_status <> 'draft' then
        raise exception
            using errcode = 'P0001',
                  message = 'COMMERCIAL_CAMPAIGN_VERSION_NOT_DRAFT';
    end if;

    if nullif(btrim(p_approved_by), '') is null then
        raise exception
            using errcode = 'P0001',
                  message = 'COMMERCIAL_CAMPAIGN_ACTOR_REQUIRED';
    end if;

    select *
    into v_campaign
    from public.reward_campaigns
    where id = v_version.campaign_id
    for update;

    if not found then
        raise exception
            using errcode = 'P0001',
                  message = 'COMMERCIAL_CAMPAIGN_NOT_FOUND';
    end if;

    v_current_snapshot :=
        public.commercial_campaign_configuration_projection_internal(
            v_campaign
        );

    if md5(v_current_snapshot::text)
       <> v_version.configuration_hash then
        raise exception
            using errcode = 'P0001',
                  message = 'COMMERCIAL_CAMPAIGN_CONFIGURATION_DRIFT_DETECTED';
    end if;

    select id
    into v_previous_approved_id
    from public.commercial_campaign_versions
    where campaign_id = v_version.campaign_id
      and version_status = 'approved'
    for update;

    if v_previous_approved_id is not null then
        update public.commercial_campaign_versions
        set
            version_status = 'superseded',
            superseded_at = clock_timestamp()
        where id = v_previous_approved_id;

        perform public.append_commercial_campaign_lifecycle_event_internal(
            v_version.campaign_id,
            v_previous_approved_id,
            null,
            'VERSION_SUPERSEDED',
            'approved',
            'superseded',
            p_approved_by,
            p_reason,
            p_correlation_id,
            p_causation_id,
            jsonb_build_object(
                'superseded_by_version_id',
                v_version.id
            )
        );
    end if;

    update public.commercial_campaign_versions
    set
        version_status = 'approved',
        approved_by = btrim(p_approved_by),
        approved_at = clock_timestamp()
    where id = v_version.id
    returning *
    into v_result;

    perform public.append_commercial_campaign_lifecycle_event_internal(
        v_result.campaign_id,
        v_result.id,
        null,
        'VERSION_APPROVED',
        'draft',
        'approved',
        p_approved_by,
        p_reason,
        p_correlation_id,
        p_causation_id,
        jsonb_build_object(
            'version_number', v_result.version_number,
            'configuration_hash', v_result.configuration_hash
        )
    );

    return v_result;
end;
$function$;


create or replace function public.evaluate_commercial_campaign_readiness_internal(
    p_campaign_id uuid,
    p_campaign_version_id uuid default null,
    p_requested_start_at timestamptz default null,
    p_requested_end_at timestamptz default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $function$
declare
    v_campaign public.reward_campaigns;
    v_source public.reward_sources;
    v_version public.commercial_campaign_versions;
    v_snapshot jsonb;
    v_current_snapshot jsonb;
    v_blockers jsonb := '[]'::jsonb;
    v_warnings jsonb := '[]'::jsonb;
    v_ready boolean;
    v_effective_start timestamptz;
    v_effective_end timestamptz;
begin
    select *
    into v_campaign
    from public.reward_campaigns
    where id = p_campaign_id;

    if not found then
        return jsonb_build_object(
            'ready', false,
            'status', 'blocked',
            'blockers', jsonb_build_array('CAMPAIGN_NOT_FOUND'),
            'warnings', '[]'::jsonb,
            'evaluated_at', clock_timestamp()
        );
    end if;

    v_current_snapshot :=
        public.commercial_campaign_configuration_projection_internal(
            v_campaign
        );

    if p_campaign_version_id is null then
        select *
        into v_version
        from public.commercial_campaign_versions
        where campaign_id = p_campaign_id
          and version_status = 'approved';
    else
        select *
        into v_version
        from public.commercial_campaign_versions
        where id = p_campaign_version_id
          and campaign_id = p_campaign_id;
    end if;

    if v_version.id is null then
        v_blockers :=
            v_blockers ||
            jsonb_build_array(
                'APPROVED_CAMPAIGN_VERSION_REQUIRED'
            );

        v_snapshot := v_current_snapshot;
    else
        v_snapshot := v_version.configuration_snapshot;

        if v_version.version_status <> 'approved' then
            v_blockers :=
                v_blockers ||
                jsonb_build_array(
                    'CAMPAIGN_VERSION_NOT_APPROVED'
                );
        end if;

        if md5(v_current_snapshot::text)
           <> v_version.configuration_hash then
            v_blockers :=
                v_blockers ||
                jsonb_build_array(
                    'CAMPAIGN_CONFIGURATION_DRIFT_DETECTED'
                );
        end if;
    end if;

    select *
    into v_source
    from public.reward_sources
    where id = v_campaign.source_id;

    if v_source.id is null then
        v_blockers :=
            v_blockers ||
            jsonb_build_array(
                'REWARD_SOURCE_NOT_FOUND'
            );
    elsif coalesce(
        (to_jsonb(v_source)->>'enabled')::boolean,
        false
    ) = false then
        v_blockers :=
            v_blockers ||
            jsonb_build_array(
                'REWARD_SOURCE_DISABLED'
            );
    end if;

    if coalesce(
        (v_snapshot->>'passes_per_claim')::integer,
        0
    ) <= 0 then
        v_blockers :=
            v_blockers ||
            jsonb_build_array(
                'INVALID_PASSES_PER_CLAIM'
            );
    end if;

    v_effective_start :=
        coalesce(
            p_requested_start_at,
            nullif(
                v_snapshot->>'valid_from',
                ''
            )::timestamptz
        );

    v_effective_end :=
        coalesce(
            p_requested_end_at,
            nullif(
                v_snapshot->>'valid_until',
                ''
            )::timestamptz
        );

    if v_effective_end is not null
       and v_effective_start is not null
       and v_effective_end <= v_effective_start then
        v_blockers :=
            v_blockers ||
            jsonb_build_array(
                'INVALID_ACTIVATION_WINDOW'
            );
    end if;

    if v_effective_end is not null
       and v_effective_end <= clock_timestamp() then
        v_blockers :=
            v_blockers ||
            jsonb_build_array(
                'ACTIVATION_WINDOW_ALREADY_EXPIRED'
            );
    end if;

    v_ready :=
        jsonb_array_length(v_blockers) = 0;

    return jsonb_build_object(
        'ready', v_ready,
        'status',
            case
                when v_ready then 'ready'
                else 'blocked'
            end,
        'campaign_id', v_campaign.id,
        'campaign_code', v_campaign.campaign_code,
        'campaign_version_id', v_version.id,
        'campaign_version_number', v_version.version_number,
        'configuration_hash', v_version.configuration_hash,
        'source_id', v_campaign.source_id,
        'effective_start_at', v_effective_start,
        'effective_end_at', v_effective_end,
        'blockers', v_blockers,
        'warnings', v_warnings,
        'evaluated_at', clock_timestamp()
    );
end;
$function$;


revoke all
on function public.commercial_campaign_configuration_projection_internal(
    public.reward_campaigns
)
from public;

grant execute
on function public.commercial_campaign_configuration_projection_internal(
    public.reward_campaigns
)
to service_role;

comment on function public.evaluate_commercial_campaign_readiness_internal(
    uuid,
    uuid,
    timestamptz,
    timestamptz
)
is
'Commercial campaign readiness using canonical immutable configuration projection. Runtime lifecycle state and reward counters do not cause configuration drift.';