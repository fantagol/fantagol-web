-- ============================================================================
-- FANTAGOL
-- MIGRATION 281
-- PREDICTION RECOVERY AUTOMATIC CYCLE AUTHORITY
--
-- PRODUCT CONTRACT
-- - Recovery applies ONLY to Punti Puri / Predictions.
-- - One Admin decision arms the League Round Recovery cycle once.
-- - Technical member-scoped authorization windows may repeat automatically.
-- - Each window expires at the next recoverable kickoff.
-- - No new window while a started required match is materially unsettled.
-- - A member that successfully closes a Recovery window (status=used) exits
--   the cycle permanently for that League Round.
-- - Expired members may receive a later window only when future required
--   matches still lack an official Prediction.
-- - No Strategy / Fantacalcio / One-to-One Recovery authority is introduced.
-- ============================================================================

create table if not exists public.prediction_recovery_cycles (
    id uuid primary key default gen_random_uuid(),
    league_id uuid not null references public.leagues(id) on delete cascade,
    league_round_id uuid not null references public.league_rounds(id) on delete cascade,
    armed_by_member_id uuid not null references public.league_members(id) on delete restrict,
    status text not null default 'active',
    armed_at timestamptz not null default now(),
    completed_at timestamptz null,
    reason text null,
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now(),
    version integer not null default 1,
    constraint prediction_recovery_cycles_round_unique unique (league_round_id),
    constraint prediction_recovery_cycles_status_check
      check (status in ('active','completed','revoked')),
    constraint prediction_recovery_cycles_version_positive_check
      check (version > 0),
    constraint prediction_recovery_cycles_dates_check
      check (completed_at is null or completed_at >= armed_at)
);

create index if not exists prediction_recovery_cycles_status_idx
on public.prediction_recovery_cycles(status,league_round_id);

comment on table public.prediction_recovery_cycles is
'Admin consent authority for Prediction Recovery. One row per League Round; technical member authorization windows remain in prediction_recovery_authorizations. Punti Puri only.';


-- --------------------------------------------------------------------------
-- Current-future Prediction need.
-- Physical row existence is NOT enough: an official submitted/locked
-- Prediction must exist for every currently recoverable match.
-- --------------------------------------------------------------------------
create or replace function public.member_needs_prediction_recovery_internal(
    p_league_round_id uuid,
    p_league_member_id uuid,
    p_at timestamptz default clock_timestamp()
)
returns boolean
language sql
stable
security definer
set search_path to public, pg_temp
as $function$
    select exists (
        select 1
        from public.get_prediction_recovery_match_scope_internal(
            p_league_round_id,
            p_at
        ) scope
        where scope.recoverable
          and not exists (
              select 1
              from public.predictions p
              where p.league_round_id=p_league_round_id
                and p.league_member_id=p_league_member_id
                and p.match_id=scope.match_id
                and p.status in ('submitted','locked')
                and p.submitted_version is not null
                and p.official_submitted_at is not null
          )
    );
$function$;

comment on function
public.member_needs_prediction_recovery_internal(uuid,uuid,timestamptz)
is 'True only when at least one currently recoverable required match lacks an official Prediction for the member.';


-- --------------------------------------------------------------------------
-- Kickoff race guard.
--
-- Provider status may lag kickoff. Therefore automatic Recovery must not
-- reopen immediately after expires_at merely because a match is still marked
-- scheduled. Any required match whose kickoff has passed blocks advancement
-- until its status is terminal/non-playing.
-- --------------------------------------------------------------------------
create or replace function public.has_unsettled_started_prediction_match_internal(
    p_league_round_id uuid,
    p_at timestamptz default clock_timestamp()
)
returns boolean
language sql
stable
security definer
set search_path to public, pg_temp
as $function$
    select exists (
        select 1
        from public.league_rounds lr
        join public.fantagol_round_matches frm
          on frm.fantagol_round_id=lr.fantagol_round_id
         and frm.required
         and frm.removed_at is null
        join public.matches m
          on m.id=frm.match_id
        where lr.id=p_league_round_id
          and m.kickoff <= p_at
          and lower(coalesce(m.status,'')) not in (
              'finished',
              'cancelled',
              'canceled',
              'postponed',
              'awarded'
          )
    );
$function$;

comment on function
public.has_unsettled_started_prediction_match_internal(uuid,timestamptz)
is 'Fail-closed kickoff guard for automatic Prediction Recovery advancement; blocks while any started required match is not terminal/non-playing.';


-- --------------------------------------------------------------------------
-- Technical window materializer.
-- Caller is internal authority: it receives the already-authorized Admin
-- member id from prediction_recovery_cycles.
-- --------------------------------------------------------------------------
create or replace function public.open_prediction_recovery_window_internal(
    p_league_round_id uuid,
    p_opened_by_member_id uuid,
    p_reason text default null,
    p_at timestamptz default clock_timestamp()
)
returns table (
    league_id uuid,
    league_round_id uuid,
    opened_by_member_id uuid,
    authorization_count integer,
    missing_member_count integer,
    recoverable_match_count integer,
    excluded_started_match_count integer,
    expires_at timestamptz,
    already_opened boolean
)
language plpgsql
security definer
set search_path to public, pg_temp
as $function$
declare
    v_league_id uuid;
    v_round_status text;
    v_recoverable_match_count integer := 0;
    v_required_match_count integer := 0;
    v_excluded_count integer := 0;
    v_expires_at timestamptz;
    v_existing_count integer := 0;
    v_missing_member_count integer := 0;
    v_inserted_count integer := 0;
begin
    perform pg_advisory_xact_lock(
      hashtextextended(
        'prediction-recovery-open:'||p_league_round_id::text,
        0
      )
    );

    select lr.league_id,lr.status
    into v_league_id,v_round_status
    from public.league_rounds lr
    where lr.id=p_league_round_id
      and lr.enabled
    for update;

    if v_league_id is null then
      raise exception using errcode='P0001',
        message='LEAGUE_ROUND_NOT_FOUND';
    end if;

    if v_round_status not in (
      'predictions_locked',
      'live',
      'waiting_postponed'
    ) then
      raise exception using errcode='P0001',
        message='PREDICTION_RECOVERY_ROUND_NOT_ELIGIBLE',
        detail=format('round_status=%s',v_round_status);
    end if;

    if not exists (
      select 1
      from public.league_members lm
      where lm.id=p_opened_by_member_id
        and lm.league_id=v_league_id
        and lm.status='active'
        and lm.role='admin'
    ) then
      raise exception using errcode='P0001',
        message='PREDICTION_RECOVERY_ADMIN_MEMBER_INVALID';
    end if;

    select
      count(*)::integer,
      count(*) filter(where scope.recoverable)::integer,
      count(*) filter(where not scope.recoverable)::integer,
      min(scope.kickoff) filter(where scope.recoverable)
    into
      v_required_match_count,
      v_recoverable_match_count,
      v_excluded_count,
      v_expires_at
    from public.get_prediction_recovery_match_scope_internal(
      p_league_round_id,p_at
    ) scope;

    if coalesce(v_recoverable_match_count,0)=0
       or v_expires_at is null then
      return query
      select
        v_league_id,p_league_round_id,p_opened_by_member_id,
        0,0,0,coalesce(v_excluded_count,0),null::timestamptz,false;
      return;
    end if;

    select count(*)::integer
    into v_existing_count
    from public.prediction_recovery_authorizations pra
    where pra.league_round_id=p_league_round_id
      and pra.status='open';

    if v_existing_count>0 then
      select count(*)::integer
      into v_missing_member_count
      from public.league_members lm
      where lm.league_id=v_league_id
        and lm.status='active'
        and public.member_needs_prediction_recovery_internal(
          p_league_round_id,lm.id,p_at
        )
        and not exists (
          select 1
          from public.prediction_recovery_authorizations used_auth
          where used_auth.league_round_id=p_league_round_id
            and used_auth.target_member_id=lm.id
            and used_auth.status='used'
        );

      return query
      select
        v_league_id,p_league_round_id,p_opened_by_member_id,
        v_existing_count,v_missing_member_count,
        v_recoverable_match_count,v_excluded_count,
        v_expires_at,true;
      return;
    end if;

    if public.has_active_prediction_recovery_live_phase_internal(
      p_league_round_id
    ) or public.has_unsettled_started_prediction_match_internal(
      p_league_round_id,p_at
    ) then
      return query
      select
        v_league_id,p_league_round_id,p_opened_by_member_id,
        0,0,v_recoverable_match_count,v_excluded_count,
        v_expires_at,false;
      return;
    end if;

    select count(*)::integer
    into v_missing_member_count
    from public.league_members lm
    where lm.league_id=v_league_id
      and lm.status='active'
      and public.member_needs_prediction_recovery_internal(
        p_league_round_id,lm.id,p_at
      )
      and not exists (
        select 1
        from public.prediction_recovery_authorizations used_auth
        where used_auth.league_round_id=p_league_round_id
          and used_auth.target_member_id=lm.id
          and used_auth.status='used'
      );

    if v_missing_member_count=0 then
      return query
      select
        v_league_id,p_league_round_id,p_opened_by_member_id,
        0,0,v_recoverable_match_count,v_excluded_count,
        v_expires_at,false;
      return;
    end if;

    insert into public.prediction_recovery_authorizations (
      league_id,
      league_round_id,
      target_member_id,
      opened_by_member_id,
      status,
      opened_at,
      expires_at,
      reason,
      eligible_match_count,
      excluded_started_match_count,
      created_at,
      updated_at,
      version
    )
    select
      v_league_id,
      p_league_round_id,
      lm.id,
      p_opened_by_member_id,
      'open',
      p_at,
      v_expires_at,
      nullif(btrim(p_reason),''),
      v_recoverable_match_count,
      v_excluded_count,
      p_at,
      p_at,
      1
    from public.league_members lm
    where lm.league_id=v_league_id
      and lm.status='active'
      and public.member_needs_prediction_recovery_internal(
        p_league_round_id,lm.id,p_at
      )
      and not exists (
        select 1
        from public.prediction_recovery_authorizations used_auth
        where used_auth.league_round_id=p_league_round_id
          and used_auth.target_member_id=lm.id
          and used_auth.status='used'
      )
      and not exists (
        select 1
        from public.prediction_recovery_authorizations open_auth
        where open_auth.league_round_id=p_league_round_id
          and open_auth.target_member_id=lm.id
          and open_auth.status='open'
      );

    get diagnostics v_inserted_count=row_count;

    if v_inserted_count<>v_missing_member_count then
      raise exception using errcode='P0001',
        message='PREDICTION_RECOVERY_WINDOW_INVARIANT_FAILED',
        detail=format(
          'expected_missing_members=%s inserted_authorizations=%s',
          v_missing_member_count,v_inserted_count
        );
    end if;

    return query
    select
      v_league_id,p_league_round_id,p_opened_by_member_id,
      v_inserted_count,v_missing_member_count,
      v_recoverable_match_count,v_excluded_count,
      v_expires_at,false;
end;
$function$;

comment on function
public.open_prediction_recovery_window_internal(uuid,uuid,text,timestamptz)
is 'Internal Prediction-only technical Recovery window materializer. Never touches Strategy.';


-- --------------------------------------------------------------------------
-- Cycle advancement.
--
-- ACTIVE cycle + no OPEN window + no live/unsettled started match:
--   - no future recoverable scope => complete cycle;
--   - no member needing future official Prediction => complete cycle;
--   - otherwise open next technical member windows.
-- --------------------------------------------------------------------------
create or replace function public.advance_prediction_recovery_cycles_internal(
    p_at timestamptz default clock_timestamp()
)
returns table (
    processed_cycle_count integer,
    opened_authorization_count integer,
    completed_cycle_count integer,
    blocked_cycle_count integer,
    processed_at timestamptz
)
language plpgsql
security definer
set search_path to public, pg_temp
as $function$
declare
    v_cycle record;
    v_window record;
    v_processed integer := 0;
    v_opened integer := 0;
    v_completed integer := 0;
    v_blocked integer := 0;
    v_recoverable integer := 0;
    v_needed integer := 0;
begin
    for v_cycle in
      select prc.*
      from public.prediction_recovery_cycles prc
      where prc.status='active'
      order by prc.armed_at,prc.id
      for update
    loop
      v_processed:=v_processed+1;

      perform pg_advisory_xact_lock(
        hashtextextended(
          'prediction-recovery-cycle:'||v_cycle.league_round_id::text,
          0
        )
      );

      if exists (
        select 1
        from public.prediction_recovery_authorizations pra
        where pra.league_round_id=v_cycle.league_round_id
          and pra.status='open'
      ) then
        continue;
      end if;

      if public.has_active_prediction_recovery_live_phase_internal(
           v_cycle.league_round_id
         )
         or public.has_unsettled_started_prediction_match_internal(
           v_cycle.league_round_id,p_at
         ) then
        v_blocked:=v_blocked+1;
        continue;
      end if;

      select count(*)::integer
      into v_recoverable
      from public.get_prediction_recovery_match_scope_internal(
        v_cycle.league_round_id,p_at
      ) scope
      where scope.recoverable;

      if coalesce(v_recoverable,0)=0 then
        update public.prediction_recovery_cycles prc
        set
          status='completed',
          completed_at=coalesce(prc.completed_at,p_at),
          updated_at=p_at,
          version=prc.version+1
        where prc.id=v_cycle.id
          and prc.status='active';

        v_completed:=v_completed+1;
        continue;
      end if;

      select count(*)::integer
      into v_needed
      from public.league_members lm
      where lm.league_id=v_cycle.league_id
        and lm.status='active'
        and public.member_needs_prediction_recovery_internal(
          v_cycle.league_round_id,lm.id,p_at
        )
        and not exists (
          select 1
          from public.prediction_recovery_authorizations used_auth
          where used_auth.league_round_id=v_cycle.league_round_id
            and used_auth.target_member_id=lm.id
            and used_auth.status='used'
        );

      if coalesce(v_needed,0)=0 then
        update public.prediction_recovery_cycles prc
        set
          status='completed',
          completed_at=coalesce(prc.completed_at,p_at),
          updated_at=p_at,
          version=prc.version+1
        where prc.id=v_cycle.id
          and prc.status='active';

        v_completed:=v_completed+1;
        continue;
      end if;

      select *
      into v_window
      from public.open_prediction_recovery_window_internal(
        v_cycle.league_round_id,
        v_cycle.armed_by_member_id,
        coalesce(v_cycle.reason,'automatic_recovery_cycle'),
        p_at
      );

      v_opened:=v_opened+coalesce(v_window.authorization_count,0);
    end loop;

    return query
    select v_processed,v_opened,v_completed,v_blocked,p_at;
end;
$function$;

comment on function
public.advance_prediction_recovery_cycles_internal(timestamptz)
is 'Heartbeat-safe automatic Prediction Recovery cycle advancement. Punti Puri only.';


-- --------------------------------------------------------------------------
-- Admin RPC now means ARM THE CYCLE ONCE.
-- Existing OPEN member authorizations are adopted as the current technical
-- window. Existing cycle row makes the action idempotent.
-- --------------------------------------------------------------------------
create or replace function public.open_missing_predictions_recovery_rpc(
    p_league_round_id uuid,
    p_reason text default null
)
returns table (
    league_id uuid,
    league_round_id uuid,
    opened_by_member_id uuid,
    authorization_count integer,
    missing_member_count integer,
    recoverable_match_count integer,
    excluded_started_match_count integer,
    expires_at timestamptz,
    already_opened boolean
)
language plpgsql
security definer
set search_path to public, pg_temp
as $function$
declare
    v_user_id uuid := auth.uid();
    v_league_id uuid;
    v_round_status text;
    v_admin_member_id uuid;
    v_cycle public.prediction_recovery_cycles%rowtype;
    v_window record;
    v_now timestamptz := clock_timestamp();
    v_existing_open integer := 0;
begin
    if v_user_id is null then
      raise exception using errcode='P0001',message='AUTH_REQUIRED';
    end if;

    perform pg_advisory_xact_lock(
      hashtextextended(
        'prediction-recovery-cycle:'||p_league_round_id::text,
        0
      )
    );

    select lr.league_id,lr.status
    into v_league_id,v_round_status
    from public.league_rounds lr
    where lr.id=p_league_round_id
      and lr.enabled
    for update;

    if v_league_id is null then
      raise exception using errcode='P0001',message='LEAGUE_ROUND_NOT_FOUND';
    end if;

    select lm.id
    into v_admin_member_id
    from public.league_members lm
    where lm.league_id=v_league_id
      and lm.user_id=v_user_id
      and lm.status='active'
      and lm.role='admin'
    limit 1;

    if v_admin_member_id is null then
      raise exception using errcode='P0001',message='LEAGUE_ADMIN_REQUIRED';
    end if;

    if v_round_status not in (
      'predictions_locked','live','waiting_postponed'
    ) then
      raise exception using errcode='P0001',
        message='PREDICTION_RECOVERY_ROUND_NOT_ELIGIBLE',
        detail=format('round_status=%s',v_round_status);
    end if;

    select *
    into v_cycle
    from public.prediction_recovery_cycles prc
    where prc.league_round_id=p_league_round_id
    for update;

    if not found then
      insert into public.prediction_recovery_cycles (
        league_id,league_round_id,armed_by_member_id,status,
        armed_at,reason,created_at,updated_at,version
      )
      values (
        v_league_id,p_league_round_id,v_admin_member_id,'active',
        v_now,nullif(btrim(p_reason),''),v_now,v_now,1
      )
      returning * into v_cycle;

      perform public.write_league_admin_event(
        v_league_id,
        v_admin_member_id,
        v_user_id,
        'member',
        'prediction_recovery_cycle_armed',
        null,
        p_league_round_id,
        jsonb_build_object(
          'scope','points_pure_predictions_only',
          'automatic_windows',true,
          'armed_at',v_now,
          'reason',nullif(btrim(p_reason),'')
        )
      );
    end if;

    select count(*)::integer
    into v_existing_open
    from public.prediction_recovery_authorizations pra
    where pra.league_round_id=p_league_round_id
      and pra.status='open';

    if v_existing_open>0 then
      select *
      into v_window
      from public.open_prediction_recovery_window_internal(
        p_league_round_id,
        v_cycle.armed_by_member_id,
        coalesce(v_cycle.reason,p_reason),
        v_now
      );

      return query
      select
        v_window.league_id,
        v_window.league_round_id,
        v_window.opened_by_member_id,
        v_window.authorization_count,
        v_window.missing_member_count,
        v_window.recoverable_match_count,
        v_window.excluded_started_match_count,
        v_window.expires_at,
        true;
      return;
    end if;

    if v_cycle.status<>'active' then
      return query
      select
        v_league_id,p_league_round_id,v_cycle.armed_by_member_id,
        0,0,0,0,null::timestamptz,true;
      return;
    end if;

    select *
    into v_window
    from public.open_prediction_recovery_window_internal(
      p_league_round_id,
      v_cycle.armed_by_member_id,
      coalesce(v_cycle.reason,p_reason),
      v_now
    );

    return query
    select
      v_window.league_id,
      v_window.league_round_id,
      v_window.opened_by_member_id,
      v_window.authorization_count,
      v_window.missing_member_count,
      v_window.recoverable_match_count,
      v_window.excluded_started_match_count,
      v_window.expires_at,
      false;
end;
$function$;

comment on function
public.open_missing_predictions_recovery_rpc(uuid,text)
is 'Admin arms one Prediction Recovery cycle per League Round. Technical windows then advance automatically. Punti Puri only.';


-- --------------------------------------------------------------------------
-- Expiry sweep remains heartbeat contract-compatible and now advances cycles
-- after terminalizing due member windows.
-- --------------------------------------------------------------------------
create or replace function public.expire_due_prediction_recoveries_internal(
    p_at timestamptz default clock_timestamp()
)
returns table (
    processed_authorization_count integer,
    expired_authorization_count integer,
    strategy_locked_count integer,
    strategy_auto_submitted_count integer,
    voided_recovery_prediction_count integer,
    processed_at timestamptz
)
language plpgsql
security definer
set search_path to public, pg_temp
as $function$
declare
    v_item record;
    v_result record;
    v_advance record;
    v_processed integer := 0;
    v_expired integer := 0;
    v_voided_predictions integer := 0;
begin
    for v_item in
      select pra.id
      from public.prediction_recovery_authorizations pra
      where pra.status='open'
        and pra.expires_at<=p_at
      order by pra.expires_at,pra.id
    loop
      select *
      into v_result
      from public.finalize_prediction_recovery_authorization_internal(
        v_item.id,p_at,'recovery_window_expired'
      );

      v_processed:=v_processed+1;

      if v_result.terminal_status='expired' then
        v_expired:=v_expired+1;
      end if;

      v_voided_predictions:=
        v_voided_predictions+
        coalesce(v_result.voided_recovery_prediction_count,0);
    end loop;

    select *
    into v_advance
    from public.advance_prediction_recovery_cycles_internal(p_at);

    return query
    select
      v_processed,
      v_expired,
      0,
      0,
      v_voided_predictions,
      p_at;
end;
$function$;

comment on function
public.expire_due_prediction_recoveries_internal(timestamptz)
is 'Prediction-only Recovery expiry plus automatic cycle advancement. Strategy compatibility counters remain zero.';


-- --------------------------------------------------------------------------
-- Adopt currently OPEN technical windows.
-- This preserves the Admin decision already made before migration 281 and
-- prevents requiring a second click merely because cycle authority is new.
-- --------------------------------------------------------------------------
insert into public.prediction_recovery_cycles (
    league_id,
    league_round_id,
    armed_by_member_id,
    status,
    armed_at,
    reason,
    created_at,
    updated_at,
    version
)
select
    pra.league_id,
    pra.league_round_id,
    min(pra.opened_by_member_id::text)::uuid,
    'active',
    min(pra.opened_at),
    min(pra.reason),
    min(pra.opened_at),
    clock_timestamp(),
    1
from public.prediction_recovery_authorizations pra
where pra.status='open'
group by pra.league_id,pra.league_round_id
on conflict (league_round_id) do nothing;


-- Privileges: public-facing Admin RPC remains authenticated.
revoke all on table public.prediction_recovery_cycles
from public,anon,authenticated;

revoke all on function
public.member_needs_prediction_recovery_internal(uuid,uuid,timestamptz)
from public,anon,authenticated;
grant execute on function
public.member_needs_prediction_recovery_internal(uuid,uuid,timestamptz)
to service_role;

revoke all on function
public.has_unsettled_started_prediction_match_internal(uuid,timestamptz)
from public,anon,authenticated;
grant execute on function
public.has_unsettled_started_prediction_match_internal(uuid,timestamptz)
to service_role;

revoke all on function
public.open_prediction_recovery_window_internal(uuid,uuid,text,timestamptz)
from public,anon,authenticated;
grant execute on function
public.open_prediction_recovery_window_internal(uuid,uuid,text,timestamptz)
to service_role;

revoke all on function
public.advance_prediction_recovery_cycles_internal(timestamptz)
from public,anon,authenticated;
grant execute on function
public.advance_prediction_recovery_cycles_internal(timestamptz)
to service_role;

revoke all on function
public.expire_due_prediction_recoveries_internal(timestamptz)
from public,anon,authenticated;
grant execute on function
public.expire_due_prediction_recoveries_internal(timestamptz)
to service_role;

revoke all on function
public.open_missing_predictions_recovery_rpc(uuid,text)
from public,anon;
grant execute on function
public.open_missing_predictions_recovery_rpc(uuid,text)
to authenticated,service_role;


-- --------------------------------------------------------------------------
-- Static fail-closed verification.
-- --------------------------------------------------------------------------
do $verify$
declare
    v_def text;
begin
    if not exists (
      select 1
      from information_schema.tables
      where table_schema='public'
        and table_name='prediction_recovery_cycles'
    ) then
      raise exception 'MIGRATION_281_CYCLE_TABLE_MISSING';
    end if;

    select pg_get_functiondef(
      'public.advance_prediction_recovery_cycles_internal(timestamp with time zone)'::regprocedure
    ) into v_def;

    if position('public.strategies' in lower(v_def))>0
       or position('strategy_versions' in lower(v_def))>0
       or position('fantacalcio' in lower(v_def))>0
       or position('one_to_one' in lower(v_def))>0 then
      raise exception 'MIGRATION_281_STRATEGY_RECOVERY_REF_DETECTED';
    end if;

    select pg_get_functiondef(
      'public.expire_due_prediction_recoveries_internal(timestamp with time zone)'::regprocedure
    ) into v_def;

    if position('advance_prediction_recovery_cycles_internal' in lower(v_def))=0 then
      raise exception 'MIGRATION_281_HEARTBEAT_ADVANCE_BINDING_MISSING';
    end if;
end;
$verify$;
