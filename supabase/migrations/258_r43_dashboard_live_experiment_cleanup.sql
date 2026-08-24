begin;

/*
 * R43 experimental dashboard-clock cleanup.
 *
 * These functions were introduced during the abandoned
 * R43-R9 dashboard matchup-wrapper experiment.
 *
 * The production dashboard returns to its canonical authorities:
 *
 *   get_my_dashboard_matchups_rpc
 *   get_my_round_predictions_rpc
 *
 * No gameplay data is mutated.
 */

drop function
if exists
public.get_my_dashboard_matchups_live_rpc(uuid);

drop function
if exists
public.decorate_dashboard_live_clock_internal(jsonb);

notify pgrst, 'reload schema';

commit;