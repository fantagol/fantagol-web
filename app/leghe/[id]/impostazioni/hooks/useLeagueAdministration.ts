"use client";

import { useCallback, useEffect, useMemo, useState } from "react";
import { useRouter } from "next/navigation";

import { supabase } from "../../../../../lib/supabaseClient";
import type {
  AdminEvent,
  LeagueAction,
  LeagueInfo,
  LeagueLifecycleState,
  MyLeagueRpcRow,
  ScoringProfile,
  ScoringSettings,
} from "../types";
import { translateError } from "../utils";

type AdminEventRpcRow = {
  event_id: string;
  action_type: string;
  actor_display_name: string | null;
  target_display_name: string | null;
  details: Record<string, unknown> | null;
  created_at: string;
};

export function useLeagueAdministration(leagueId: string) {
  const router = useRouter();

  const [league, setLeague] = useState<LeagueInfo | null>(null);
  const [lifecycle, setLifecycle] = useState<LeagueLifecycleState | null>(null);
  const [scoringProfile, setScoringProfile] = useState<ScoringProfile | null>(
    null,
  );
  const [events, setEvents] = useState<AdminEvent[]>([]);
  const [loading, setLoading] = useState(true);
  const [action, setAction] = useState<LeagueAction>(null);
  const [errorMessage, setErrorMessage] = useState<string | null>(null);
  const [successMessage, setSuccessMessage] = useState<string | null>(null);
  const [confirmationName, setConfirmationName] = useState("");

  const loadAdministration = useCallback(async () => {
    setLoading(true);
    setErrorMessage(null);

    try {
      const {
        data: { session },
        error: sessionError,
      } = await supabase.auth.getSession();

      if (sessionError) throw sessionError;

      if (!session?.user) {
        router.replace("/login");
        return;
      }

      const { data: leaguesData, error: leaguesError } =
        await supabase.rpc("get_my_leagues_rpc");

      if (leaguesError) throw leaguesError;

      const current = ((leaguesData || []) as MyLeagueRpcRow[]).find(
        (row) => row.league_id === leagueId,
      );

      if (!current) {
        router.replace("/leghe");
        return;
      }

      const currentLeague: LeagueInfo = {
        id: current.league_id,
        name: current.league_name || "Lega FantaGol",
        displayName: current.display_name || "Club FantaGol",
        inviteCode: current.invite_code || current.league_id,
        role: current.role || "member",
        status: current.status || "active",
      };

      setLeague(currentLeague);

      const [lifecycleResult, scoringResult, eventsResult] = await Promise.all([
        supabase.rpc("get_league_lifecycle_state_rpc", {
          target_league_id: currentLeague.id,
        }),
        supabase.rpc("get_active_league_scoring_profile_rpc", {
          target_league_id: currentLeague.id,
        }),
        supabase.rpc("get_league_admin_events_rpc", {
          target_league_id: currentLeague.id,
          result_limit: 50,
        }),
      ]);

      if (lifecycleResult.error) throw lifecycleResult.error;
      if (scoringResult.error) throw scoringResult.error;
      if (eventsResult.error) throw eventsResult.error;

      setLifecycle(
        ((lifecycleResult.data || [])[0] as LeagueLifecycleState | undefined) ||
          null,
      );

      setScoringProfile(
        ((scoringResult.data || [])[0] as ScoringProfile | undefined) || null,
      );

      setEvents(
        ((eventsResult.data || []) as AdminEventRpcRow[]).map((event) => ({
          id: event.event_id,
          action_type: event.action_type,
          actor_display_name: event.actor_display_name,
          target_display_name: event.target_display_name,
          details: event.details || {},
          created_at: event.created_at,
        })),
      );
    } catch (error) {
      const message =
        error instanceof Error ? error.message : "Operazione non riuscita.";
      setErrorMessage(translateError(message));
    } finally {
      setLoading(false);
    }
  }, [leagueId, router]);

  useEffect(() => {
    const loadTimer = window.setTimeout(() => {
      void loadAdministration();
    }, 0);

    return () => window.clearTimeout(loadTimer);
  }, [loadAdministration]);

  const isAdmin = league?.role === "admin";
  const confirmationMatches =
    Boolean(league) && confirmationName === league?.name;

  const rosterChanged = useMemo(() => {
    if (!lifecycle || lifecycle.schedule_member_count === null) return false;
    return lifecycle.schedule_member_count !== lifecycle.active_member_count;
  }, [lifecycle]);

  const competitionStarted = useMemo(() => {
    if (!lifecycle) return false;

    return (
      lifecycle.first_scored_at !== null ||
      lifecycle.lifecycle_status === "active" ||
      lifecycle.lifecycle_status === "completed" ||
      lifecycle.lifecycle_status === "archived"
    );
  }, [lifecycle]);

  function beginAction(nextAction: Exclude<LeagueAction, null>) {
    setAction(nextAction);
    setErrorMessage(null);
    setSuccessMessage(null);
  }

  async function finishAndReload(message: string) {
    setSuccessMessage(message);
    setAction(null);
    await loadAdministration();
  }

  function failAction(message: string) {
    setErrorMessage(translateError(message));
    setAction(null);
  }

  async function saveScoringProfile(settings: ScoringSettings, reason: string) {
    if (!league || !isAdmin || action) return;

    beginAction("save-scoring");

    const { error } = await supabase.rpc("update_league_scoring_profile_rpc", {
      target_league_id: league.id,
      enable_surprise_bonus: settings.surprise_bonus_enabled,
      enable_goal_show_bonus: settings.goal_show_bonus_enabled,
      enable_grand_slam_bonus: settings.grand_slam_bonus_enabled,
      enable_cantonata_malus: settings.cantonata_malus_enabled,
      enable_opposite_sign_malus: settings.opposite_sign_malus_enabled,
      change_reason: reason.trim() || null,
    });

    if (error) {
      failAction(error.message);
      return;
    }

    await finishAndReload("Profilo punteggi aggiornato e versionato.");
  }

  async function runRosterAction(regenerateSchedules: boolean) {
    if (!league || !isAdmin || action) return;

    beginAction(regenerateSchedules ? "lock" : "lock-preserve");

    const { error } = await supabase.rpc("lock_league_roster_rpc", {
      target_league_id: league.id,
      regenerate_schedules: regenerateSchedules,
    });

    if (error) {
      failAction(error.message);
      return;
    }

    await finishAndReload(
      regenerateSchedules
        ? "Iscrizioni chiuse e calendari generati correttamente."
        : "Iscrizioni chiuse mantenendo i calendari esistenti.",
    );
  }

  async function reopenRoster() {
    if (!league || !isAdmin || action) return;

    beginAction("reopen");

    const { error } = await supabase.rpc("reopen_league_roster_rpc", {
      target_league_id: league.id,
    });

    if (error) {
      failAction(error.message);
      return;
    }

    await finishAndReload("Iscrizioni riaperte correttamente.");
  }

  function clearLastLeagueContext() {
    if (!league) return;

    if (window.localStorage.getItem("fantagol:last-league-id") === league.id) {
      window.localStorage.removeItem("fantagol:last-league-id");
    }
  }

  async function leaveLeague() {
    if (!league || isAdmin || action) return;

    beginAction("leave-league");

    const { error } = await supabase.rpc("leave_league_rpc", {
      target_league_id: league.id,
    });

    if (error) {
      failAction(error.message);
      return;
    }

    clearLastLeagueContext();
    router.replace("/leghe");
    router.refresh();
  }

  async function closeLeague() {
    if (!league || !isAdmin || !confirmationMatches || action) return;

    beginAction("close-league");

    const { error } = await supabase.rpc("delete_league_rpc", {
      target_league_id: league.id,
    });

    if (error) {
      failAction(error.message);
      return;
    }

    clearLastLeagueContext();
    router.replace("/leghe");
    router.refresh();
  }

  async function copyInviteLink() {
    if (!league) return;
    await navigator.clipboard.writeText(
      `${window.location.origin}/invito/${league.inviteCode}`,
    );
    setSuccessMessage("Link invito copiato.");
  }

  return {
    league,
    lifecycle,
    scoringProfile,
    events,
    loading,
    action,
    errorMessage,
    successMessage,
    confirmationName,
    isAdmin,
    confirmationMatches,
    rosterChanged,
    competitionStarted,
    setConfirmationName,
    setErrorMessage,
    runRosterAction,
    reopenRoster,
    leaveLeague,
    closeLeague,
    copyInviteLink,
    saveScoringProfile,
  };
}
