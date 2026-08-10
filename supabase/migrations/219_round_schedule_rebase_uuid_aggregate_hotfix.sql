-- ============================================================
-- FANTAGOL
-- MIGRATION 219
-- ROUND SCHEDULE REBASE UUID AGGREGATE HOTFIX
--
-- Fixes:
--   PostgreSQL does not provide min(uuid).
--
-- Scope:
--   Replace only
--   rebase_fantagol_round_schedule_from_matches_internal(uuid)
--
-- No operational rebase is executed by this migration.
-- ============================================================

begin;

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
  v_provider_round_count integer;

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

  -- Count distinct non-null source provider rounds.
  select
    count(distinct frm.source_provider_round_id)::integer
  into v_provider_round_count
  from public.fantagol_round_matches frm
  where
    frm.fantagol_round_id = p_fantagol_round_id
    and frm.removed_at is null
    and frm.source_provider_round_id is not null;

  if v_provider_round_count <> 1 then
    raise exception using
      errcode = 'P0001',
      message = 'FANTAGOL_ROUND_PROVIDER_ROUND_NOT_UNIQUE',
      detail = format(
        'round_id=%s distinct_provider_rounds=%s',
        p_fantagol_round_id,
        v_provider_round_count
      );
  end if;

  -- UUID-safe resolution.
  --
  -- PostgreSQL has no min(uuid), so resolve the one certified
  -- distinct provider round directly instead of aggregating UUID.
  select distinct
    frm.source_provider_round_id
  into v_provider_round_id
  from public.fantagol_round_matches frm
  where
    frm.fantagol_round_id = p_fantagol_round_id
    and frm.removed_at is null
    and frm.source_provider_round_id is not null
  limit 1;

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

revoke all on function
public.rebase_fantagol_round_schedule_from_matches_internal(uuid)
from public, anon, authenticated;

grant execute on function
public.rebase_fantagol_round_schedule_from_matches_internal(uuid)
to service_role;

do $$
begin
  if to_regprocedure(
    'public.rebase_fantagol_round_schedule_from_matches_internal(uuid)'
  ) is null then
    raise exception
      'ROUND_SCHEDULE_REBASE_UUID_HOTFIX_NOT_INSTALLED';
  end if;
end;
$$;

commit;