-- ============================================================================
-- FANTAGOL
-- Migration 316
-- League Admin Event Vocabulary Reconciliation
--
-- ROOT CAUSE
-- ----------
-- Two canonical event writers emit action types that are absent from the
-- surviving league_admin_events_action_type_check:
--
--   admin_transferred_for_account_deletion
--   prediction_recovery_cycle_armed
--
-- Migration 281 writes prediction_recovery_cycle_armed immediately after
-- creating a Prediction Recovery cycle. Because the event vocabulary did not
-- include that action type, canonical Recovery arming failed before the
-- Recovery window could be materialized.
--
-- Migration 174 also emits admin_transferred_for_account_deletion, which is
-- absent from the surviving event constraint.
--
-- SCOPE
-- -----
-- Vocabulary reconciliation only.
-- No Prediction Recovery logic changes.
-- No Account Lifecycle logic changes.
-- No frontend changes.
-- No historical event mutation.
-- ============================================================================

alter table public.league_admin_events
  drop constraint if exists league_admin_events_action_type_check;

alter table public.league_admin_events
  add constraint league_admin_events_action_type_check
  check (
    action_type = any (
      array[
        'league_created'::text,
        'member_joined'::text,
        'member_rejoined'::text,
        'roster_locked'::text,
        'roster_reopened'::text,
        'league_started'::text,
        'league_archived'::text,

        'vice_assigned'::text,
        'vice_revoked'::text,
        'admin_resigned'::text,
        'admin_inactivity_warning'::text,
        'admin_demoted_for_inactivity'::text,
        'vice_promoted_to_admin'::text,
        'admin_assigned_from_ranking'::text,
        'admin_assigned_by_seniority'::text,
        'admin_succession_blocked'::text,

        'admin_transferred_for_account_deletion'::text,

        'member_removed'::text,
        'member_reinstated'::text,
        'member_withdrawn'::text,

        'league_schedules_generated'::text,
        'league_schedules_regenerated'::text,
        'league_schedules_preserved'::text,
        'league_schedules_locked'::text,

        'prediction_recovery_cycle_armed'::text,
        'prediction_recovery_opened'::text,
        'prediction_recovery_used'::text,
        'prediction_recovery_revoked'::text,
        'prediction_recovery_expired'::text,

        'postponed_match_detected'::text,
        'postponed_match_reopened'::text,
        'postponed_match_excluded'::text,

        'calculation_preview_created'::text,
        'calculation_preview_failed'::text,

        'round_certification_committed'::text,
        'round_certification_superseded'::text,

        'scoring_profile_changed'::text,
        'league_settings_changed'::text
      ]
    )
  );

comment on constraint
league_admin_events_action_type_check
on public.league_admin_events
is
'Canonical League Admin event vocabulary, including Account Lifecycle admin transfer and Prediction Recovery cycle arming.';