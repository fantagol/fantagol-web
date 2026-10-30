-- FANTAGOL PUSH V1-D: MANUAL POINTS PURI CONFIRMATION (ORDINARY + RECOVERY)
-- NEW isolated schema / RPC. Does not redefine existing prediction routines.
-- REVIEW BEFORE APPLYING: migration number 354 is provisional; check current migration inventory.
-- NOT APPLIED. NO NOTIFICATION DELIVERY.

create table if not exists public.push_manual_points_submissions (
  user_id uuid not null references auth.users(id) on delete cascade,
  fantagol_round_id uuid not null references public.fantagol_rounds(id) on delete cascade,
  first_league_round_id uuid not null references public.league_rounds(id),
  first_league_member_id uuid not null references public.league_members(id),
  first_confirmed_at timestamptz not null default clock_timestamp(),
  primary key (user_id, fantagol_round_id)
);

-- Private server-side evidence: no direct Data API reads or writes.
alter table public.push_manual_points_submissions enable row level security;
revoke all on table public.push_manual_points_submissions from public, anon, authenticated, service_role;

create or replace function public.submit_round_predictions_manual_rpc(
  p_league_round_id uuid
)
returns table (
  league_round_id uuid,
  league_member_id uuid,
  required_prediction_count integer,
  submitted_prediction_count integer,
  already_submitted boolean,
  submitted_at timestamptz
)
language plpgsql
security definer
set search_path = pg_catalog, public
as $fn$
declare
  v_user_id uuid := auth.uid();
  v_result record;
  v_round_id uuid;
begin
  if v_user_id is null then
    raise exception 'PUSH_MANUAL_AUTH_REQUIRED';
  end if;

  -- Existing canonical RPC validates open window, full roster, active membership,
  -- lock, official snapshot, and retries. A failed RPC aborts entire transaction.
  select * into v_result
  from public.submit_round_predictions_rpc(p_league_round_id);

  if not found
     or v_result.league_member_id is null
     or v_result.required_prediction_count is null
     or v_result.required_prediction_count < 1
     or v_result.submitted_prediction_count is distinct from v_result.required_prediction_count then
    raise exception 'PUSH_MANUAL_SUBMIT_NOT_CERTIFIED';
  end if;

  select lr.fantagol_round_id into v_round_id
  from public.league_rounds lr
  join public.league_members lm
    on lm.id = v_result.league_member_id
   and lm.league_id = lr.league_id
   and lm.user_id = v_user_id
   and lm.status = 'active'
  where lr.id = p_league_round_id and lr.enabled = true;

  if v_round_id is null then
    raise exception 'PUSH_MANUAL_ROUND_MEMBERSHIP_MISMATCH';
  end if;

  -- Commit success evidence atomically with the canonical submission.
  -- NEVER replace the initial event, even if user changes drafts later.
  insert into public.push_manual_points_submissions (
    user_id, fantagol_round_id,
    first_league_round_id, first_league_member_id
  ) values (
    v_user_id, v_round_id,
    p_league_round_id, v_result.league_member_id
  ) on conflict (user_id, fantagol_round_id) do nothing;

  return query select
    v_result.league_round_id::uuid,
    v_result.league_member_id::uuid,
    v_result.required_prediction_count::integer,
    v_result.submitted_prediction_count::integer,
    v_result.already_submitted::boolean,
    v_result.submitted_at::timestamptz;
end;
$fn$;

revoke all on function public.submit_round_predictions_manual_rpc(uuid)
from public, anon, authenticated, service_role;
grant execute on function public.submit_round_predictions_manual_rpc(uuid)
to authenticated;

comment on function public.submit_round_predictions_manual_rpc(uuid) is
  'Explicit Points Puri submit path only: canonical submit plus first-ever manual intent evidence. Do not call from automation or heartbeat.';


-- Recovery manual action only. Reuses the canonical Recovery RPC atomically.
-- Never invoked by the automatic Recovery lifecycle or expiry auto-submit.
create or replace function public.submit_prediction_recovery_manual_rpc(
  p_league_round_id uuid
)
returns table (
  league_round_id uuid,
  league_member_id uuid,
  authorization_id uuid,
  current_recoverable_match_count integer,
  submitted_prediction_count integer,
  newly_submitted_prediction_count integer,
  voided_started_recovery_draft_count integer,
  already_submitted boolean,
  submitted_at timestamptz
)
language plpgsql
security definer
set search_path = pg_catalog, public
as $fn$
declare
  v_user_id uuid := auth.uid();
  v_result record;
  v_round_id uuid;
begin
  if v_user_id is null then
    raise exception 'PUSH_MANUAL_AUTH_REQUIRED';
  end if;

  select * into v_result
  from public.submit_prediction_recovery_rpc(p_league_round_id);

  if not found
     or v_result.league_member_id is null
     or v_result.authorization_id is null
     or v_result.current_recoverable_match_count is null
     or v_result.current_recoverable_match_count < 1
     or v_result.submitted_prediction_count
        is distinct from v_result.current_recoverable_match_count then
    raise exception 'PUSH_MANUAL_RECOVERY_NOT_CERTIFIED';
  end if;

  select lr.fantagol_round_id into v_round_id
  from public.league_rounds lr
  join public.league_members lm
    on lm.id = v_result.league_member_id
   and lm.league_id = lr.league_id
   and lm.user_id = v_user_id
   and lm.status = 'active'
  where lr.id = p_league_round_id
    and lr.enabled = true;

  if v_round_id is null then
    raise exception 'PUSH_MANUAL_RECOVERY_MEMBERSHIP_MISMATCH';
  end if;

  insert into public.push_manual_points_submissions (
    user_id, fantagol_round_id,
    first_league_round_id, first_league_member_id
  ) values (
    v_user_id, v_round_id,
    p_league_round_id, v_result.league_member_id
  ) on conflict (user_id, fantagol_round_id) do nothing;

  return query select
    v_result.league_round_id::uuid,
    v_result.league_member_id::uuid,
    v_result.authorization_id::uuid,
    v_result.current_recoverable_match_count::integer,
    v_result.submitted_prediction_count::integer,
    v_result.newly_submitted_prediction_count::integer,
    v_result.voided_started_recovery_draft_count::integer,
    v_result.already_submitted::boolean,
    v_result.submitted_at::timestamptz;
end;
$fn$;

revoke all on function public.submit_prediction_recovery_manual_rpc(uuid)
from public, anon, authenticated, service_role;
grant execute on function public.submit_prediction_recovery_manual_rpc(uuid)
to authenticated;

comment on function public.submit_prediction_recovery_manual_rpc(uuid) is
  'Explicit Points Puri Recovery click only: canonical Recovery submit plus irreversible first manual confirmation. Not used by auto-cycle/expiry.';
