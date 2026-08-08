begin;

create or replace function public.get_my_unseen_reward_summary_rpc()
returns table (
  reward_code text,
  reward_label text,
  event_count integer,
  passes_awarded integer
)
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $function$
declare
  v_user_id uuid;
begin
  v_user_id := public.commercial_assert_authenticated_user();

  return query
  select
    e.event_code::text,

    case e.event_code
      when 'CERTIFIED_EXACT_ACHIEVED'
        then 'Exact'
      when 'CERTIFIED_GRAND_SLAM_ACHIEVED'
        then 'Grande Slam'
      when 'CERTIFIED_CANTONATA_ACHIEVED'
        then 'Cantonata'
      when 'LEAGUE_REACHED_8_ACTIVE_MEMBERS'
        then 'Lega completa'
      when 'LEAGUE_FIRST_ROUND_CERTIFIED'
        then 'Prima giornata'
      when 'LEAGUE_SEASON_CERTIFIED_COMPLETE'
        then 'Campionato concluso'
      when 'PROFILE_COMPLETED_AFTER_FIRST_LEAGUE_ROUND'
        then 'Profilo completato'
      when 'COMPLETE_PREDICTIONS_STREAK_5_CERTIFIED'
        then 'Pronostici completi ×5'
      when 'COMPLETE_PREDICTIONS_STREAK_10_CERTIFIED'
        then 'Pronostici completi ×10'
      when 'COMPLETE_PREDICTIONS_FULL_SEASON_CERTIFIED'
        then 'Stagione completa'
      else 'Ricompensa FantaGol'
    end::text,

    count(*)::integer,
    sum(r.passes_awarded)::integer

  from public.reward_revelations r
  join public.loyalty_reward_events e
    on e.id = r.loyalty_reward_event_id

  where r.user_id = v_user_id
    and r.revelation_status = 'unseen'
    and e.event_status = 'rewarded'

  group by e.event_code

  order by
    sum(r.passes_awarded) desc,
    count(*) desc,
    e.event_code;
end;
$function$;

comment on function public.get_my_unseen_reward_summary_rpc()
is
  'Authenticated summary of already-earned unseen rewards for temporary Control Room presentation. Hidden future reward objectives are never exposed.';

revoke all
on function public.get_my_unseen_reward_summary_rpc()
from public, anon;

grant execute
on function public.get_my_unseen_reward_summary_rpc()
to authenticated;

commit;
