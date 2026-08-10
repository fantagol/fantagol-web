-- ============================================================
-- FANTAGOL
-- MIGRATION 218
-- CANONICAL ROUND SCHEDULE REBASE FOUNDATION
--
-- Purpose:
--   Keep provider_rounds and fantagol_rounds aligned with the
--   canonical Match kickoff window after provider fixture changes.
--
-- Source authority:
--   matches
--
-- Guarantees:
--   * no Match identity mutation
--   * no FantaGol Round match-set mutation
--   * no League schedule regeneration
--   * no Prediction mutation
--   * no Community mutation
--   * no Market Intelligence mutation
--   * already-open prediction windows are never moved later
-- ============================================================

begin;

-- ============================================================
-- 1. CANONICAL PROVIDER ROUND WINDOW
-- ============================================================

create or replace function
public.compute_provider_round_match_window(
  p_provider_round_id uuid
)
returns table(
  starts_at timestamptz,
  ends_at timestamptz,
  match_count integer
)
language sql
stable
set search_path = public
as $function$
  select
    min(m.kickoff) as starts_at,
    max(m.kickoff) as ends_at,
    count(*)::integer as match_count
  from public.matches m
  where m.provider_round_id = p_provider_round_id
    and m.active = true;
$function$;

-- ============================================================
-- 2. CANONICAL FANTAGOL ROUND WINDOW
-- ============================================================

create or replace function
public.compute_fantagol_round_match_window(
  p_fantagol_round_id uuid
)
returns table(
  starts_at timestamptz,
  ends_at timestamptz,
  match_count integer
)
language sql
stable
set search_path = public
as $function$
  select
    min(m.kickoff) as starts_at,
    max(m.kickoff) as ends_at,
    count(*)::integer as match_count
  from public.fantagol_round_matches frm
  join public.matches m
    on m.id = frm.match_id
  where frm.fantagol_round_id = p_fantagol_round_id
    and frm.removed_at is null
    and m.active = true;
$function$;

-- ============================================================
-- 3. REBASE ONE PROVIDER ROUND
-- ============================================================

create or replace function
public.rebase_provider_round_schedule_internal(
  p_provider_round_id uuid
)
returns table(
  provider_round_id uuid,
  previous_starts_at timestamptz,
  previous_ends_at timestamptz,
  rebased_starts_at timestamptz,
  rebased_ends_at timestamptz,
  match_count integer,
  changed boolean
)
language plpgsql
security definer
set search_path = public
as $function$
declare
  v_round public.provider_rounds%rowtype;
  v_starts_at timestamptz;
  v_ends_at timestamptz;
  v_match_count integer;
  v_changed boolean;
begin
  if p_provider_round_id is null then
    raise exception using
      errcode = 'P0001',
      message = 'PROVIDER_ROUND_REQUIRED';
  end if;

  select *
  into v_round
  from public.provider_rounds
  where id = p_provider_round_id
  for update;

  if not found then
    raise exception using
      errcode = 'P0001',
      message = 'PROVIDER_ROUND_NOT_FOUND';
  end if;

  select
    w.starts_at,
    w.ends_at,
    w.match_count
  into
    v_starts_at,
    v_ends_at,
    v_match_count
  from public.compute_provider_round_match_window(
    p_provider_round_id
  ) w;

  if v_match_count <= 0
     or v_starts_at is null
     or v_ends_at is null then
    raise exception using
      errcode = 'P0001',
      message = 'PROVIDER_ROUND_MATCH_WINDOW_EMPTY';
  end if;

  if v_ends_at < v_starts_at then
    raise exception using
      errcode = 'P0001',
      message = 'PROVIDER_ROUND_MATCH_WINDOW_INVALID';
  end if;

  v_changed :=
    v_round.starts_at is distinct from v_starts_at
    or v_round.ends_at is distinct from v_ends_at;

  if v_changed then
    update public.provider_rounds
    set
      starts_at = v_starts_at,
      ends_at = v_ends_at,
      synced_at = clock_timestamp()
    where id = p_provider_round_id;
  end if;

  return query
  select
    p_provider_round_id,
    v_round.starts_at,
    v_round.ends_at,
    v_starts_at,
    v_ends_at,
    v_match_count,
    v_changed;
end;
$function$;

-- ============================================================
-- 4. REBASE ONE FANTAGOL ROUND
-- ============================================================

create or replace function
public.rebase_fantagol_round_schedule_internal(
  p_fantagol_round_id uuid
)
returns table(
  fantagol_round_id uuid,
  previous_opens_at timestamptz,
  previous_lock_at timestamptz,
  previous_starts_at timestamptz,
  previous_ends_at timestamptz,
  rebased_opens_at timestamptz,
  rebased_lock_at timestamptz,
  rebased_starts_at timestamptz,
  rebased_ends_at timestamptz,
  previous_status text,
  rebased_status text,
  match_count integer,
  changed boolean
)
language plpgsql
security definer
set search_path = public
as $function$
declare
  v_round public.fantagol_rounds%rowtype;

  v_starts_at timestamptz;
  v_ends_at timestamptz;
  v_match_count integer;

  v_previous_round_ends_at timestamptz;
  v_candidate_opens_at timestamptz;
  v_opens_at timestamptz;

  v_status text;
  v_changed boolean;

  v_now timestamptz := clock_timestamp();
begin
  if p_fantagol_round_id is null then
    raise exception using
      errcode = 'P0001',
      message = 'FANTAGOL_ROUND_REQUIRED';
  end if;

  select *
  into v_round
  from public.fantagol_rounds
  where id = p_fantagol_round_id
  for update;

  if not found then
    raise exception using
      errcode = 'P0001',
      message = 'FANTAGOL_ROUND_NOT_FOUND';
  end if;

  select
    w.starts_at,
    w.ends_at,
    w.match_count
  into
    v_starts_at,
    v_ends_at,
    v_match_count
  from public.compute_fantagol_round_match_window(
    p_fantagol_round_id
  ) w;

  if v_match_count <> v_round.target_match_count then
    raise exception using
      errcode = 'P0001',
      message = 'FANTAGOL_ROUND_MATCH_COUNT_MISMATCH',
      detail = format(
        'round_id=%s expected=%s actual=%s',
        p_fantagol_round_id,
        v_round.target_match_count,
        v_match_count
      );
  end if;

  if v_starts_at is null
     or v_ends_at is null
     or v_ends_at < v_starts_at then
    raise exception using
      errcode = 'P0001',
      message = 'FANTAGOL_ROUND_MATCH_WINDOW_INVALID';
  end if;

  select previous_round.ends_at
  into v_previous_round_ends_at
  from public.fantagol_rounds previous_round
  where previous_round.edition_id = v_round.edition_id
    and previous_round.active = true
    and previous_round.sequence < v_round.sequence
  order by previous_round.sequence desc
  limit 1;

  v_candidate_opens_at :=
    case
      when v_previous_round_ends_at is not null
       and v_previous_round_ends_at < v_starts_at
        then v_previous_round_ends_at
      else v_starts_at - interval '7 days'
    end;

  -- Once an opening window has already started, a provider schedule
  -- correction must never take that access away by moving opens_at later.
  v_opens_at :=
    case
      when v_round.opens_at <= v_now
        then least(v_round.opens_at, v_candidate_opens_at)
      else v_candidate_opens_at
    end;

  -- Preserve terminal/certified lifecycle states.
  v_status :=
    case
      when v_round.status in (
        'final_official',
        'recalculated',
        'cancelled'
      )
        then v_round.status

      when v_now < v_opens_at
        then 'scheduled'

      when v_now < v_starts_at
        then 'predictions_open'

      when v_now <= v_ends_at
        then 'live'

      else 'final_calculable'
    end;

  v_changed :=
    v_round.opens_at is distinct from v_opens_at
    or v_round.lock_at is distinct from v_starts_at
    or v_round.starts_at is distinct from v_starts_at
    or v_round.ends_at is distinct from v_ends_at
    or v_round.status is distinct from v_status;

  if v_changed then
    update public.fantagol_rounds
    set
      opens_at = v_opens_at,
      lock_at = v_starts_at,
      starts_at = v_starts_at,
      ends_at = v_ends_at,
      status = v_status
    where id = p_fantagol_round_id;
  end if;

  return query
  select
    p_fantagol_round_id,
    v_round.opens_at,
    v_round.lock_at,
    v_round.starts_at,
    v_round.ends_at,
    v_opens_at,
    v_starts_at,
    v_starts_at,
    v_ends_at,
    v_round.status,
    v_status,
    v_match_count,
    v_changed;
end;
$function$;

-- ============================================================
-- 5. CANONICAL COMBINED REBASE
-- ============================================================

create or replace function
public.rebase_fantagol_round_schedule_from_matches_internal(
  p_fantagol_round_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $function$
declare
  v_round public.fantagol_rounds%rowtype;
  v_provider_round_id uuid;

  v_provider_result record;
  v_round_result record;
begin
  if p_fantagol_round_id is null then
    raise exception using
      errcode = 'P0001',
      message = 'FANTAGOL_ROUND_REQUIRED';
  end if;

  select *
  into v_round
  from public.fantagol_rounds
  where id = p_fantagol_round_id;

  if not found then
    raise exception using
      errcode = 'P0001',
      message = 'FANTAGOL_ROUND_NOT_FOUND';
  end if;

  select
    case
      when count(distinct frm.source_provider_round_id) = 1
        then min(frm.source_provider_round_id)
      else null
    end
  into v_provider_round_id
  from public.fantagol_round_matches frm
  where frm.fantagol_round_id = p_fantagol_round_id
    and frm.removed_at is null;

  if v_provider_round_id is null then
    raise exception using
      errcode = 'P0001',
      message = 'FANTAGOL_ROUND_PROVIDER_ROUND_NOT_UNIQUE';
  end if;

  select *
  into v_provider_result
  from public.rebase_provider_round_schedule_internal(
    v_provider_round_id
  );

  select *
  into v_round_result
  from public.rebase_fantagol_round_schedule_internal(
    p_fantagol_round_id
  );

  return jsonb_build_object(
    'fantagol_round_id',
    p_fantagol_round_id,

    'provider_round_id',
    v_provider_round_id,

    'provider_round_changed',
    v_provider_result.changed,

    'provider_round_starts_at',
    v_provider_result.rebased_starts_at,

    'provider_round_ends_at',
    v_provider_result.rebased_ends_at,

    'fantagol_round_changed',
    v_round_result.changed,

    'fantagol_round_opens_at',
    v_round_result.rebased_opens_at,

    'fantagol_round_lock_at',
    v_round_result.rebased_lock_at,

    'fantagol_round_starts_at',
    v_round_result.rebased_starts_at,

    'fantagol_round_ends_at',
    v_round_result.rebased_ends_at,

    'fantagol_round_status',
    v_round_result.rebased_status,

    'match_count',
    v_round_result.match_count
  );
end;
$function$;

-- ============================================================
-- 6. SECURITY
-- ============================================================

revoke all on function
public.compute_provider_round_match_window(uuid)
from public, anon, authenticated;

revoke all on function
public.compute_fantagol_round_match_window(uuid)
from public, anon, authenticated;

revoke all on function
public.rebase_provider_round_schedule_internal(uuid)
from public, anon, authenticated;

revoke all on function
public.rebase_fantagol_round_schedule_internal(uuid)
from public, anon, authenticated;

revoke all on function
public.rebase_fantagol_round_schedule_from_matches_internal(uuid)
from public, anon, authenticated;

grant execute on function
public.compute_provider_round_match_window(uuid)
to service_role;

grant execute on function
public.compute_fantagol_round_match_window(uuid)
to service_role;

grant execute on function
public.rebase_provider_round_schedule_internal(uuid)
to service_role;

grant execute on function
public.rebase_fantagol_round_schedule_internal(uuid)
to service_role;

grant execute on function
public.rebase_fantagol_round_schedule_from_matches_internal(uuid)
to service_role;

-- ============================================================
-- 7. STATIC INSTALL CERTIFICATION
-- ============================================================

do $$
begin
  if to_regprocedure(
    'public.compute_provider_round_match_window(uuid)'
  ) is null then
    raise exception
      'COMPUTE_PROVIDER_ROUND_MATCH_WINDOW_NOT_INSTALLED';
  end if;

  if to_regprocedure(
    'public.compute_fantagol_round_match_window(uuid)'
  ) is null then
    raise exception
      'COMPUTE_FANTAGOL_ROUND_MATCH_WINDOW_NOT_INSTALLED';
  end if;

  if to_regprocedure(
    'public.rebase_provider_round_schedule_internal(uuid)'
  ) is null then
    raise exception
      'REBASE_PROVIDER_ROUND_SCHEDULE_NOT_INSTALLED';
  end if;

  if to_regprocedure(
    'public.rebase_fantagol_round_schedule_internal(uuid)'
  ) is null then
    raise exception
      'REBASE_FANTAGOL_ROUND_SCHEDULE_NOT_INSTALLED';
  end if;

  if to_regprocedure(
    'public.rebase_fantagol_round_schedule_from_matches_internal(uuid)'
  ) is null then
    raise exception
      'CANONICAL_ROUND_SCHEDULE_REBASE_NOT_INSTALLED';
  end if;
end;
$$;

commit;