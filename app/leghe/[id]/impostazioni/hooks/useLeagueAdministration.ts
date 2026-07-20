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
} from "../types";
import { translateError } from "../utils";

export function useLeagueAdministration(leagueId: string) {
  const router = useRouter();

  const [league, setLeague] = useState<LeagueInfo | null>(null);
  const [lifecycle, setLifecycle] =
    useState<LeagueLifecycleState | null>(null);
  const [scoringProfile, setScoringProfile] =
    useState<ScoringProfile | null>(null);
  const [events, setEvents] = useState<AdminEvent[]>([]);
  const [loading, setLoading] = useState(true);
  const [action, setAction] = useState<LeagueAction>(null);
  const [errorMessage, setErrorMessage] = useState<string | null>(null);
  const [successMessage, setSuccessMessage] = useState<string | null>(null);
  const [confirmationName, setConfirmationName] = useState("");

  const loadAdministration = useCallback(async () => {
    setLoading(true);
    setErrorMessage(null);

    const {
      data: { session },
    } = await supabase.auth.getSession();

    if (!session?.user) {
      router.replace("/login");
      return;
    }

    const { data: leaguesData, error: leaguesError } = await supabase.rpc(
      "get_my_leagues_rpc"
    );

    if (leaguesError) {
      setErrorMessage(translateError(leaguesError.message));
      setLoading(false);
      return;
    }

    const current = ((leaguesData || []) as MyLeagueRpcRow[]).find(
      (row) => row.league_id === leagueId
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
      supabase
        .from("league_scoring_profiles")
        .select(
          "id, version, surprise_bonus_enabled, goal_show_bonus_enabled, grand_slam_bonus_enabled, cantonata_malus_enabled, opposite_sign_malus_enabled, active, created_at, reason"
        )
        .eq("league_id", currentLeague.id)
        .eq("active", true)
        .order("version", { ascending: false })
        .limit(1)
        .maybeSingle(),
      supabase
        .from("league_admin_events")
        .select("id, action_type, details, created_at")
        .eq("league_id", currentLeague.id)
        .order("created_at", { ascending: false })
        .limit(12),
    ]);

    if (lifecycleResult.error) {
      setErrorMessage(translateError(lifecycleResult.error.message));
    } else {
      setLifecycle(
        ((lifecycleResult.data || [])[0] as
          | LeagueLifecycleState
          | undefined) || null
      );
    }

    if (scoringResult.error) {
      setErrorMessage(
        (currentMessage) =>
          currentMessage || translateError(scoringResult.error.message)
      );
    } else {
      setScoringProfile(
        (scoringResult.data as ScoringProfile | null) || null
      );
    }

    if (eventsResult.error) {
      setErrorMessage(
        (currentMessage) =>
          currentMessage || translateError(eventsResult.error.message)
      );
    } else {
      setEvents((eventsResult.data || []) as AdminEvent[]);
    }

    setLoading(false);
  }, [leagueId, router]);

  useEffect(() => {
    const loadTimer = window.setTimeout(() => {
      void loadAdministration();
    }, 0);

    return () => {
      window.clearTimeout(loadTimer);
    };
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

  async function runRosterAction(regenerateSchedules: boolean) {
    if (!league || !isAdmin || action) return;

    setAction(regenerateSchedules ? "lock" : "lock-preserve");
    setErrorMessage(null);
    setSuccessMessage(null);

    const { error } = await supabase.rpc("lock_league_roster_rpc", {
      target_league_id: league.id,
      regenerate_schedules: regenerateSchedules,
    });

    if (error) {
      setErrorMessage(translateError(error.message));
      setAction(null);
      return;
    }

    setSuccessMessage(
      regenerateSchedules
        ? "Iscrizioni chiuse e calendari generati correttamente."
        : "Iscrizioni chiuse mantenendo i calendari esistenti."
    );
    setAction(null);
    await loadAdministration();
  }

  async function reopenRoster() {
    if (!league || !isAdmin || action) return;

    setAction("reopen");
    setErrorMessage(null);
    setSuccessMessage(null);

    const { error } = await supabase.rpc("reopen_league_roster_rpc", {
      target_league_id: league.id,
    });

    if (error) {
      setErrorMessage(translateError(error.message));
      setAction(null);
      return;
    }

    setSuccessMessage("Iscrizioni riaperte correttamente.");
    setAction(null);
    await loadAdministration();
  }

  async function permanentlyDeleteLeague() {
    if (!league || !isAdmin || !confirmationMatches || action) return;

    setAction("delete");
    setErrorMessage(null);
    setSuccessMessage(null);

    const { error } = await supabase.rpc(
      "delete_league_permanently_rpc",
      {
        p_league_id: league.id,
        p_confirmation_name: confirmationName,
      }
    );

    if (error) {
      setErrorMessage(translateError(error.message));
      setAction(null);
      return;
    }

    router.replace("/leghe");
    router.refresh();
  }

  async function copyInviteLink() {
    if (!league) return;

    const inviteLink = `${window.location.origin}/invito/${league.inviteCode}`;
    await navigator.clipboard.writeText(inviteLink);
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
    permanentlyDeleteLeague,
    copyInviteLink,
  };
}
