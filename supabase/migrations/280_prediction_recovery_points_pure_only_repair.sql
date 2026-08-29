-- ============================================================================
-- FANTAGOL - MIGRATION 280
-- PREDICTION RECOVERY: POINTS PURE ONLY REPAIR
--
-- Recovery applies ONLY to Prediction / Punti Puri.
-- Fantacalcio and One-to-One are outside Recovery.
--
-- Current improper Strategy Recovery workspaces are repaired by provenance:
--   REBOUND: remove only versions tied to currently OPEN Recovery auths and
--            restore the latest non-Recovery Strategy version.
--   CREATED: if no non-Recovery baseline ever existed, remove the transient
--            Strategy aggregate after removing its OPEN-auth Recovery versions.
--
-- Historical terminal Strategy Recovery data is never targeted.
-- ============================================================================

drop trigger if exists materialize_strategy_recovery_on_authorization_trg
on public.prediction_recovery_authorizations;

drop trigger if exists guard_strategy_recovery_version_write_trg
on public.strategy_versions;

revoke all on function public.get_my_strategy_recovery_workspace_rpc(uuid,text)
from public, anon, authenticated, service_role;
revoke all on function public.save_strategy_recovery_draft_rpc(uuid,text,jsonb)
from public, anon, authenticated, service_role;
revoke all on function public.submit_strategy_recovery_rpc(uuid,text)
from public, anon, authenticated, service_role;
revoke all on function public.materialize_strategy_recovery_defaults_internal(uuid)
from public, anon, authenticated, service_role;
revoke all on function public.materialize_strategy_recovery_on_authorization()
from public, anon, authenticated, service_role;


-- Capture exactly the Strategy aggregates polluted by a CURRENTLY OPEN
-- Prediction Recovery authorization. Never target terminal authorization history.
create temporary table migration280_strategy_targets
on commit drop
as
select distinct
    s.id as strategy_id,
    s.league_round_id,
    s.league_member_id,
    case
      when exists (
        select 1
        from public.strategy_versions base
        where base.strategy_id=s.id
          and base.source <> 'admin_recovery'
      ) then 'rebound'
      else 'created'
    end as repair_kind
from public.strategies s
where s.source='admin_recovery'
  and s.status='draft'
  and s.submitted_version is null
  and exists (
    select 1
    from public.prediction_recovery_authorizations pra
    where pra.league_round_id=s.league_round_id
      and pra.target_member_id=s.league_member_id
      and pra.status='open'
  );


-- Every admin_recovery version on a targeted transient Strategy must belong
-- to one of the member's currently OPEN authorizations. Otherwise fail closed:
-- that would mean historical terminal data shares the aggregate.
do $history_guard$
declare
    v_unsafe integer;
begin
    select count(*)::integer
    into v_unsafe
    from public.strategy_versions sv
    join migration280_strategy_targets t
      on t.strategy_id=sv.strategy_id
    where sv.source='admin_recovery'
      and not exists (
        select 1
        from public.prediction_recovery_authorizations pra
        where pra.league_round_id=t.league_round_id
          and pra.target_member_id=t.league_member_id
          and pra.status='open'
          and sv.metadata->>'recovery_authorization_id'=pra.id::text
      );

    if v_unsafe > 0 then
      raise exception using
        errcode='P0001',
        message='POINTS_PURE_ONLY_REPAIR_HISTORICAL_STRATEGY_COLLISION',
        detail=format('version_count=%s',v_unsafe);
    end if;
end;
$history_guard$;


-- Remove only transient Strategy Recovery versions tied to the open window.
-- The canonical immutability trigger explicitly permits DELETE only when this
-- transaction-local maintenance setting is ON. It automatically disappears
-- at transaction end and does not weaken normal runtime immutability.
set local fantagol.allow_strategy_version_delete = 'on';

delete from public.strategy_versions sv
using migration280_strategy_targets t
where sv.strategy_id=t.strategy_id
  and sv.source='admin_recovery'
  and exists (
    select 1
    from public.prediction_recovery_authorizations pra
    where pra.league_round_id=t.league_round_id
      and pra.target_member_id=t.league_member_id
      and pra.status='open'
      and sv.metadata->>'recovery_authorization_id'=pra.id::text
  );


-- Rebound Strategy: restore latest true non-Recovery aggregate state.
with baseline as (
    select distinct on (t.strategy_id)
      t.strategy_id,
      sv.version,
      sv.status,
      sv.source,
      sv.changed_at
    from migration280_strategy_targets t
    join public.strategy_versions sv
      on sv.strategy_id=t.strategy_id
     and sv.source <> 'admin_recovery'
    where t.repair_kind='rebound'
    order by t.strategy_id,sv.version desc
)
update public.strategies s
set
    status=b.status,
    source=b.source,
    version=b.version,
    locked_at=case when b.status='locked' then b.changed_at else null end,
    updated_at=clock_timestamp()
from baseline b
where s.id=b.strategy_id;


-- Created Strategy: no Strategy existed before the erroneous Recovery window.
-- After its transient versions have been removed, delete the empty aggregate.
do $created_guard$
declare
    v_remaining integer;
begin
    select count(*)::integer
    into v_remaining
    from migration280_strategy_targets t
    join public.strategy_versions sv
      on sv.strategy_id=t.strategy_id
    where t.repair_kind='created';

    if v_remaining > 0 then
      raise exception using
        errcode='P0001',
        message='POINTS_PURE_ONLY_REPAIR_CREATED_STRATEGY_NOT_EMPTY',
        detail=format('remaining_version_count=%s',v_remaining);
    end if;
end;
$created_guard$;

delete from public.strategies s
using migration280_strategy_targets t
where s.id=t.strategy_id
  and t.repair_kind='created';


-- Prediction-only finalizer. External signature remains compatible with 253.
create or replace function public.finalize_prediction_recovery_authorization_internal(
    p_authorization_id uuid,
    p_at timestamptz default clock_timestamp(),
    p_reason text default null
)
returns table (
    authorization_id uuid,
    league_round_id uuid,
    league_member_id uuid,
    terminal_status text,
    current_recoverable_match_count integer,
    current_official_recovery_prediction_count integer,
    voided_recovery_prediction_count integer,
    strategy_mode_count integer,
    strategy_locked_count integer,
    strategy_auto_submitted_count integer,
    strategy_official_locked_count integer,
    already_terminal boolean,
    finalized_at timestamptz
)
language plpgsql
security definer
set search_path to public, pg_temp
as $function$
declare
    v_authorization public.prediction_recovery_authorizations%rowtype;
    v_current_recoverable integer := 0;
    v_current_official integer := 0;
    v_voided_predictions integer := 0;
    v_terminal_status text;
begin
    if p_authorization_id is null then
      raise exception using errcode='P0001',
        message='PREDICTION_RECOVERY_AUTHORIZATION_REQUIRED';
    end if;

    select pra.* into v_authorization
    from public.prediction_recovery_authorizations pra
    where pra.id=p_authorization_id
    for update;

    if not found then
      raise exception using errcode='P0001',
        message='PREDICTION_RECOVERY_AUTHORIZATION_NOT_FOUND';
    end if;

    if v_authorization.status in ('used','expired','revoked') then
      return query select
        v_authorization.id,v_authorization.league_round_id,
        v_authorization.target_member_id,v_authorization.status,
        0,0,0,0,0,0,0,true,p_at;
      return;
    end if;

    if v_authorization.status <> 'open' then
      raise exception using errcode='P0001',
        message='PREDICTION_RECOVERY_AUTHORIZATION_STATE_INVALID';
    end if;

    perform pg_advisory_xact_lock(hashtextextended(
      'prediction-recovery-member:'||v_authorization.league_round_id::text||
      ':'||v_authorization.target_member_id::text,0
    ));

    select count(*)::integer into v_current_recoverable
    from public.get_prediction_recovery_match_scope_internal(
      v_authorization.league_round_id,p_at
    ) scope
    where scope.recoverable;

    select count(*)::integer into v_current_official
    from public.get_prediction_recovery_match_scope_internal(
      v_authorization.league_round_id,p_at
    ) scope
    join public.predictions p
      on p.league_round_id=v_authorization.league_round_id
     and p.league_member_id=v_authorization.target_member_id
     and p.match_id=scope.match_id
    where scope.recoverable
      and p.source='admin_recovery'
      and p.status in ('submitted','locked')
      and p.submitted_version is not null
      and p.official_submitted_at is not null;

    if p_at < v_authorization.expires_at
       and v_current_official <> v_current_recoverable then
      raise exception using errcode='P0001',
        message='PREDICTION_RECOVERY_NOT_COMPLETE',
        detail=format(
          'recoverable=%s official=%s missing=%s',
          v_current_recoverable,v_current_official,
          greatest(v_current_recoverable-v_current_official,0)
        );
    end if;

    with changed as (
      update public.predictions p
      set status='void',version=p.version+1,updated_at=p_at
      where p.league_round_id=v_authorization.league_round_id
        and p.league_member_id=v_authorization.target_member_id
        and p.source='admin_recovery'
        and p.status='draft'
        and p.submitted_version is null
      returning p.*
    ), history as (
      insert into public.prediction_versions (
        prediction_id,version,home_prediction,away_prediction,status,source,
        changed_by_user_id,changed_by_member_id,changed_at,metadata
      )
      select
        c.id,c.version,c.home_prediction,c.away_prediction,'void','admin_recovery',
        null,null,p_at,
        jsonb_build_object(
          'command','FinalizePredictionRecovery',
          'operation','recovery_close_void_unsubmitted',
          'recovery_authorization_id',v_authorization.id,
          'league_round_id',v_authorization.league_round_id,
          'match_id',c.match_id,
          'reason',coalesce(nullif(btrim(p_reason),''),'recovery_closed')
        )
      from changed c
      returning prediction_id
    )
    select count(*)::integer into v_voided_predictions from history;

    v_terminal_status :=
      case when p_at >= v_authorization.expires_at then 'expired' else 'used' end;

    update public.prediction_recovery_authorizations pra
    set
      status=v_terminal_status,
      used_at=case
        when v_terminal_status='used' then coalesce(pra.used_at,p_at)
        else pra.used_at
      end,
      updated_at=p_at,
      version=pra.version+1
    where pra.id=v_authorization.id;

    return query select
      v_authorization.id,v_authorization.league_round_id,
      v_authorization.target_member_id,v_terminal_status,
      v_current_recoverable,v_current_official,v_voided_predictions,
      0,0,0,0,false,p_at;
end;
$function$;

comment on function
public.finalize_prediction_recovery_authorization_internal(uuid,timestamptz,text)
is 'Prediction-only Recovery finalizer. Punti Puri only; Strategy counters are compatibility zeros.';

revoke all on function
public.finalize_prediction_recovery_authorization_internal(uuid,timestamptz,text)
from public,anon,authenticated;
grant execute on function
public.finalize_prediction_recovery_authorization_internal(uuid,timestamptz,text)
to service_role;


do $verify$
declare v_def text;
begin
  if exists (
    select 1 from pg_trigger
    where not tgisinternal
      and tgname in (
        'materialize_strategy_recovery_on_authorization_trg',
        'guard_strategy_recovery_version_write_trg'
      )
  ) then raise exception 'MIGRATION_280_STRATEGY_TRIGGER_SURVIVED'; end if;

  if has_function_privilege(
    'authenticated','public.get_my_strategy_recovery_workspace_rpc(uuid,text)','EXECUTE'
  ) or has_function_privilege(
    'authenticated','public.save_strategy_recovery_draft_rpc(uuid,text,jsonb)','EXECUTE'
  ) or has_function_privilege(
    'authenticated','public.submit_strategy_recovery_rpc(uuid,text)','EXECUTE'
  ) then raise exception 'MIGRATION_280_STRATEGY_RPC_SURVIVED'; end if;

  select pg_get_functiondef(
    'public.finalize_prediction_recovery_authorization_internal(uuid,timestamp with time zone,text)'::regprocedure
  ) into v_def;

  if position('strategy_versions' in lower(v_def))>0
     or position('public.strategies' in lower(v_def))>0
     or position('foreach v_mode' in lower(v_def))>0 then
    raise exception 'MIGRATION_280_FINALIZER_STILL_TOUCHES_STRATEGY';
  end if;
end;
$verify$;