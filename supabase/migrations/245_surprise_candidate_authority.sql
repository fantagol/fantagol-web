-- ================================================================
-- FANTAGOL
-- Surprise Candidate Authority
--
-- Canonical rule:
--   a 1X2 outcome is a Surprise candidate when its immutable
--   Surprise Reference fair decimal odd is >= 3.80.
--
-- Boundaries:
--   * derives ONLY from surprise_reference_matches
--   * requires a READY surprise_reference_round
--   * does NOT award points
--   * does NOT mutate predictions
--   * does NOT mutate scoring
-- ================================================================

create or replace function public.surprise_candidate_signs_internal(
  p_consensus_payload jsonb
)
returns text[]
language sql
immutable
security definer
set search_path to 'public', 'pg_temp'
as $function$
  select array_remove(
    array[
      case
        when jsonb_typeof(
          p_consensus_payload #> '{fairDecimalOdds,home}'
        ) = 'number'
        and (
          p_consensus_payload #>>
          '{fairDecimalOdds,home}'
        )::numeric >= 3.80
        then '1'
      end,
      case
        when jsonb_typeof(
          p_consensus_payload #> '{fairDecimalOdds,draw}'
        ) = 'number'
        and (
          p_consensus_payload #>>
          '{fairDecimalOdds,draw}'
        )::numeric >= 3.80
        then 'X'
      end,
      case
        when jsonb_typeof(
          p_consensus_payload #> '{fairDecimalOdds,away}'
        ) = 'number'
        and (
          p_consensus_payload #>>
          '{fairDecimalOdds,away}'
        )::numeric >= 3.80
        then '2'
      end
    ]::text[],
    null
  );
$function$;

revoke all
on function public.surprise_candidate_signs_internal(jsonb)
from public, anon, authenticated;

grant execute
on function public.surprise_candidate_signs_internal(jsonb)
to service_role;

comment on function
public.surprise_candidate_signs_internal(jsonb)
is
'Canonical immutable Surprise candidate classifier. Maps frozen H2H fairDecimalOdds >= 3.80 to FantaGol signs 1/X/2. Does not score.';


create or replace function public.build_surprise_candidates_internal(
  p_fantagol_round_id uuid
)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
  v_result jsonb;
begin
  if p_fantagol_round_id is null then
    raise exception using
      errcode = 'P0001',
      message = 'FANTAGOL_ROUND_ID_REQUIRED';
  end if;

  if not exists (
    select 1
    from public.surprise_reference_rounds srr
    where srr.fantagol_round_id = p_fantagol_round_id
      and srr.status = 'ready'
      and srr.ready_at is not null
      and srr.reference_hash is not null
      and srr.required_match_count > 0
      and srr.captured_match_count =
          srr.required_match_count
  ) then
    return '{}'::jsonb;
  end if;

  select coalesce(
    jsonb_object_agg(
      x.match_id::text,
      to_jsonb(x.candidate_signs)
    ) filter (
      where cardinality(x.candidate_signs) > 0
    ),
    '{}'::jsonb
  )
  into v_result
  from (
    select
      srm.match_id,
      public.surprise_candidate_signs_internal(
        srm.consensus_payload
      ) as candidate_signs
    from public.surprise_reference_matches srm
    join public.surprise_reference_rounds srr
      on srr.id =
         srm.surprise_reference_round_id
    where srr.fantagol_round_id =
          p_fantagol_round_id
      and srr.status = 'ready'
  ) x;

  return coalesce(v_result, '{}'::jsonb);
end;
$function$;

revoke all
on function public.build_surprise_candidates_internal(uuid)
from public, anon, authenticated;

grant execute
on function public.build_surprise_candidates_internal(uuid)
to service_role;

comment on function
public.build_surprise_candidates_internal(uuid)
is
'Builds the canonical Resolution Engine p_surprise_candidates JSONB payload from the immutable READY Surprise Reference. No scoring side effects.';


create or replace function public.get_my_round_surprise_candidates_rpc(
  p_league_round_id uuid
)
returns table(
  match_id uuid,
  candidate_signs text[],
  reference_at timestamptz,
  threshold numeric,
  ready boolean
)
language plpgsql
stable
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
  v_user_id uuid := auth.uid();
  v_round public.league_rounds%rowtype;
  v_reference public.surprise_reference_rounds%rowtype;
begin
  if v_user_id is null then
    raise exception using
      errcode = 'P0001',
      message = 'AUTH_REQUIRED';
  end if;

  if p_league_round_id is null then
    raise exception using
      errcode = 'P0001',
      message = 'LEAGUE_ROUND_REQUIRED';
  end if;

  select lr.*
  into v_round
  from public.league_rounds lr
  where lr.id = p_league_round_id
    and lr.enabled = true;

  if v_round.id is null then
    raise exception using
      errcode = 'P0001',
      message = 'LEAGUE_ROUND_NOT_FOUND';
  end if;

  if not exists (
    select 1
    from public.league_members lm
    where lm.league_id = v_round.league_id
      and lm.user_id = v_user_id
      and lm.status = 'active'
  ) then
    raise exception using
      errcode = 'P0001',
      message = 'ACTIVE_LEAGUE_MEMBER_REQUIRED';
  end if;

  select srr.*
  into v_reference
  from public.surprise_reference_rounds srr
  where srr.fantagol_round_id =
        v_round.fantagol_round_id
    and srr.status = 'ready'
    and srr.ready_at is not null
    and srr.reference_hash is not null
    and srr.required_match_count > 0
    and srr.captured_match_count =
        srr.required_match_count
  limit 1;

  return query
  select
    frm.match_id,

    case
      when v_reference.id is not null
       and srm.id is not null
      then
        public.surprise_candidate_signs_internal(
          srm.consensus_payload
        )
      else
        '{}'::text[]
    end as candidate_signs,

    case
      when v_reference.id is not null
      then v_reference.reference_at
      else null::timestamptz
    end as reference_at,

    3.80::numeric as threshold,

    (v_reference.id is not null) as ready

  from public.fantagol_round_matches frm

  left join public.surprise_reference_matches srm
    on v_reference.id is not null
   and srm.surprise_reference_round_id =
       v_reference.id
   and srm.match_id = frm.match_id

  where frm.fantagol_round_id =
        v_round.fantagol_round_id
    and frm.required = true
    and frm.removed_at is null

  order by
    frm.slot_number,
    frm.match_id;
end;
$function$;

revoke all
on function public.get_my_round_surprise_candidates_rpc(uuid)
from public, anon;

grant execute
on function public.get_my_round_surprise_candidates_rpc(uuid)
to authenticated, service_role;

comment on function
public.get_my_round_surprise_candidates_rpc(uuid)
is
'Authenticated read projection for pre-live Surprise candidate UI state. Returns candidate signs derived from immutable READY Surprise Reference at threshold 3.80. Does not award bonus points.';