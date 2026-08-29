-- =====================================================================
-- FANTAGOL - MIGRATION 283
-- PREDICTION RECOVERY EXPIRY AUTO-SUBMIT AUTHORITY
-- Points Pure / Predictions only
--
-- Contract continuity with normal pre-match:
-- - complete persisted Recovery grid = authoritative intent
-- - explicit submit before expiry remains unchanged
-- - at expiry, auto-submit only if the entire grid that was recoverable
--   immediately before the deadline is present and fully scored
-- - evaluate completeness at expires_at - 1 microsecond
-- - logical official submission timestamp = expires_at
-- - successful expiry auto-submit terminates authorization as USED
-- - incomplete expiry preserves EXPIRED + void-unsubmitted behavior
-- - no Strategy Recovery behavior
-- =====================================================================

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
    v_scope_at timestamptz;
    v_current_recoverable integer := 0;
    v_current_official integer := 0;
    v_deadline_required integer := 0;
    v_deadline_scored integer := 0;
    v_deadline_official integer := 0;
    v_auto_submitted integer := 0;
    v_auto_submit boolean := false;
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

    if p_at >= v_authorization.expires_at then
      v_scope_at := v_authorization.expires_at - interval '1 microsecond';

      select count(*)::integer
      into v_deadline_required
      from public.get_prediction_recovery_match_scope_internal(
        v_authorization.league_round_id,v_scope_at
      ) scope
      where scope.recoverable;

      select count(*)::integer
      into v_deadline_scored
      from public.get_prediction_recovery_match_scope_internal(
        v_authorization.league_round_id,v_scope_at
      ) scope
      join public.predictions p
        on p.league_round_id=v_authorization.league_round_id
       and p.league_member_id=v_authorization.target_member_id
       and p.match_id=scope.match_id
      where scope.recoverable
        and p.source='admin_recovery'
        and p.home_prediction is not null
        and p.away_prediction is not null
        and (
          (
            p.status='draft'
            and p.submitted_version is null
            and p.official_submitted_at is null
          )
          or (
            p.status in ('submitted','locked')
            and p.submitted_version is not null
            and p.official_submitted_at is not null
          )
        );

      v_auto_submit :=
        v_deadline_required > 0
        and v_deadline_scored = v_deadline_required;

      if v_auto_submit then
        with eligible as (
          select p.id
          from public.get_prediction_recovery_match_scope_internal(
            v_authorization.league_round_id,v_scope_at
          ) scope
          join public.predictions p
            on p.league_round_id=v_authorization.league_round_id
           and p.league_member_id=v_authorization.target_member_id
           and p.match_id=scope.match_id
          where scope.recoverable
            and p.source='admin_recovery'
            and p.status='draft'
            and p.submitted_version is null
            and p.official_submitted_at is null
            and p.home_prediction is not null
            and p.away_prediction is not null
        ),
        changed as (
          update public.predictions p
          set
            status='submitted',
            source='admin_recovery',
            version=p.version+1,
            submitted_at=coalesce(p.submitted_at,v_authorization.expires_at),
            submitted_version=p.version+1,
            official_submitted_at=coalesce(
              p.official_submitted_at,
              v_authorization.expires_at
            ),
            locked_at=null,
            updated_at=p_at
          where p.id in (select e.id from eligible e)
          returning p.*
        ),
        history as (
          insert into public.prediction_versions (
            prediction_id,version,home_prediction,away_prediction,status,source,
            changed_by_user_id,changed_by_member_id,changed_at,metadata
          )
          select
            c.id,c.version,c.home_prediction,c.away_prediction,
            'submitted','admin_recovery',
            null,v_authorization.target_member_id,p_at,
            jsonb_build_object(
              'command','FinalizePredictionRecovery',
              'operation','recovery_expiry_auto_submit',
              'recovery_authorization_id',v_authorization.id,
              'league_round_id',v_authorization.league_round_id,
              'match_id',c.match_id,
              'logical_submitted_at',v_authorization.expires_at,
              'reason','complete_saved_grid_at_deadline'
            )
          from changed c
          returning prediction_id
        )
        select count(*)::integer
        into v_auto_submitted
        from history;

        select count(*)::integer
        into v_deadline_official
        from public.get_prediction_recovery_match_scope_internal(
          v_authorization.league_round_id,v_scope_at
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

        if v_deadline_official <> v_deadline_required then
          raise exception using errcode='P0001',
            message='PREDICTION_RECOVERY_EXPIRY_AUTOSUBMIT_INVARIANT_FAILED',
            detail=format(
              'required=%s scored=%s official=%s auto_submitted=%s',
              v_deadline_required,v_deadline_scored,
              v_deadline_official,v_auto_submitted
            );
        end if;

        v_current_recoverable := v_deadline_required;
        v_current_official := v_deadline_official;
        v_terminal_status := 'used';

      else
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
            c.id,c.version,c.home_prediction,c.away_prediction,
            'void','admin_recovery',
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
        select count(*)::integer
        into v_voided_predictions
        from history;

        v_terminal_status := 'expired';
      end if;

    else
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
          c.id,c.version,c.home_prediction,c.away_prediction,
          'void','admin_recovery',
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
      select count(*)::integer
      into v_voided_predictions
      from history;

      v_terminal_status := 'used';
    end if;

    update public.prediction_recovery_authorizations pra
    set
      status=v_terminal_status,
      used_at=case
        when v_terminal_status='used'
          then coalesce(
            pra.used_at,
            case
              when p_at >= v_authorization.expires_at
                then v_authorization.expires_at
              else p_at
            end
          )
        else pra.used_at
      end,
      updated_at=p_at,
      version=pra.version+1
    where pra.id=v_authorization.id;

    return query select
      v_authorization.id,
      v_authorization.league_round_id,
      v_authorization.target_member_id,
      v_terminal_status,
      v_current_recoverable,
      v_current_official,
      v_voided_predictions,
      0,0,0,0,
      false,
      p_at;
end;
$function$;

comment on function
public.finalize_prediction_recovery_authorization_internal(uuid,timestamptz,text)
is 'Prediction-only Recovery finalizer. Complete persisted Recovery grid auto-submits at expiry using deadline scope; incomplete grid expires fail-closed. Strategy counters are compatibility zeros.';

revoke all on function
public.finalize_prediction_recovery_authorization_internal(uuid,timestamptz,text)
from public,anon,authenticated;

grant execute on function
public.finalize_prediction_recovery_authorization_internal(uuid,timestamptz,text)
to service_role;

do $verify$
declare
  v_def text;
begin
  select pg_get_functiondef(
    'public.finalize_prediction_recovery_authorization_internal(uuid,timestamp with time zone,text)'::regprocedure
  )
  into v_def;

  if position('recovery_expiry_auto_submit' in lower(v_def))=0 then
    raise exception 'MIGRATION_283_AUTOSUBMIT_MARKER_MISSING';
  end if;

  if position('expires_at - interval ''1 microsecond''' in lower(v_def))=0 then
    raise exception 'MIGRATION_283_DEADLINE_SCOPE_MARKER_MISSING';
  end if;

  if position('complete_saved_grid_at_deadline' in lower(v_def))=0 then
    raise exception 'MIGRATION_283_COMPLETE_GRID_MARKER_MISSING';
  end if;

  if position('strategy_versions' in lower(v_def))>0
     or position('public.strategies' in lower(v_def))>0 then
    raise exception 'MIGRATION_283_STRATEGY_RECOVERY_REINTRODUCED';
  end if;
end;
$verify$;
