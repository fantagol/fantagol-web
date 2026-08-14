"use client";

import { useEffect, useState } from "react";
import FantaGolLogo from "../../components/FantaGolLogo";
import HamburgerDrawer from "../../components/app/HamburgerDrawer";
import { supabase } from "../../lib/supabaseClient";
import {
  startRewardedAdLifecycle,
} from "../../lib/android-commercial/rewarded-lifecycle";

type LeagueInfo = {
  leagueName: string;
  displayName: string;
  inviteCode: string;
  role: string;
};

function ControlRoomIcon() {
  return (
    <span className="flex h-16 w-16 shrink-0 items-center justify-center rounded-2xl border border-[#A6E824]/35 bg-[#A6E824]/10 shadow-[0_0_28px_rgba(166,232,36,0.18)]">
      <span className="relative h-11 w-11 rounded-xl border border-[#A6E824]/70 bg-black/40">
        <span className="absolute left-2 top-2 h-2 w-2 rounded-full bg-[#A6E824]" />
        <span className="absolute right-2 top-2 h-2 w-2 rounded-full bg-[#A6E824]/45" />
        <span className="absolute bottom-2 left-2 right-2 flex items-end gap-1">
          <span className="h-3 flex-1 rounded-t bg-[#A6E824]/50" />
          <span className="h-7 flex-1 rounded-t bg-[#A6E824]" />
          <span className="h-5 flex-1 rounded-t bg-[#A6E824]/70" />
        </span>
      </span>
    </span>
  );
}

function VideoIcon() {
  return (
    <span className="flex h-14 w-14 items-center justify-center rounded-2xl border border-white/10 bg-[#071015]">
      <span className="ml-1 h-0 w-0 border-y-[12px] border-l-[18px] border-y-transparent border-l-[#A6E824]" />
    </span>
  );
}

function PassIcon() {
  return (
    <span className="flex h-14 w-14 items-center justify-center rounded-2xl border border-[#A6E824]/35 bg-[#A6E824]/10 shadow-[0_0_18px_rgba(166,232,36,0.16)]">
      <span className="relative h-8 w-10 rounded-xl border border-[#A6E824]/70 bg-black/40">
        <span className="absolute left-2 right-2 top-2 h-1 rounded-full bg-[#A6E824]" />
        <span className="absolute bottom-2 left-2 h-2 w-2 rounded-full bg-[#A6E824]/70" />
        <span className="absolute bottom-2 right-2 h-2 w-4 rounded-full bg-[#A6E824]/35" />
      </span>
    </span>
  );
}

function AccessIcon() {
  return (
    <span className="flex h-14 w-14 items-center justify-center rounded-2xl border border-[#A6E824]/35 bg-[#A6E824]/10 text-5xl font-black leading-none text-[#A6E824] shadow-[0_0_18px_rgba(166,232,36,0.16)]">
      ➜
    </span>
  );
}

function FeaturePill({ label }: { label: string }) {
  return (
    <span className="rounded-full border border-white/10 bg-black/30 px-3 py-2 text-xs font-black uppercase tracking-[0.12em] text-gray-300">
      {label}
    </span>
  );
}

type RewardSummaryRow = {
  reward_code: string;
  reward_label: string;
  event_count: number;
  passes_awarded: number;
};

const REWARD_DISPLAY_LABELS: Record<string, string> = {
  LEAGUE_REACHED_8_ACTIVE_MEMBERS: "Lega 8+ membri",
  CERTIFIED_EXACT_ACHIEVED: "Exact",
  CERTIFIED_CANTONATA_ACHIEVED: "Cantonata",
  CERTIFIED_GRAND_SLAM_ACHIEVED: "Grande Slam",
  PROFILE_COMPLETED_AFTER_FIRST_LEAGUE_ROUND: "Profilo completato",
  LEAGUE_SEASON_CERTIFIED_COMPLETE: "Stagione completata",
};

function getRewardDisplayLabel(reward: RewardSummaryRow) {
  const baseLabel =
    REWARD_DISPLAY_LABELS[reward.reward_code] ||
    reward.reward_label?.trim() ||
    reward.reward_code;

  return reward.event_count > 1
    ? `${reward.event_count} ${baseLabel}`
    : baseLabel;
}

export default function ControlRoomPage() {
  const [menuOpen, setMenuOpen] = useState(false);
  const [availablePasses, setAvailablePasses] = useState(0);
  const [premiumStatusLoading, setPremiumStatusLoading] = useState(true);
  const [premiumAccessStarting, setPremiumAccessStarting] = useState(false);
  const [activePremiumSessionId, setActivePremiumSessionId] = useState<string | null>(null);
  const [passPopupOpen, setPassPopupOpen] = useState(false);
  const [rewardedVideoStarting, setRewardedVideoStarting] =
    useState(false);
  const [rewardSummary, setRewardSummary] =
    useState<RewardSummaryRow[]>([]);

  useEffect(() => {
    let cancelled = false;

    async function loadPremiumStatus() {
      setPremiumStatusLoading(true);

      try {
        const { data, error } = await supabase.rpc(
          "get_my_premium_access_status_rpc",
          {
            p_resource_code: "CONTROL_ROOM",
          },
        );

        if (error) {
          throw error;
        }

        if (cancelled) return;

        const payload =
          data && typeof data === "object" && !Array.isArray(data)
            ? (data as Record<string, unknown>)
            : null;

        const passes = Number(payload?.available_passes ?? 0);

        setAvailablePasses(
          Number.isFinite(passes) && passes >= 0
            ? Math.trunc(passes)
            : 0,
        );

        const existingSessionId =
          payload?.authorized === true &&
          typeof payload?.session_id === "string"
            ? payload.session_id
            : null;

        setActivePremiumSessionId(existingSessionId);
      } catch (error) {
        console.error(
          "[Control Room] Premium status load failed.",
          error,
        );

        if (!cancelled) {
          setAvailablePasses(0);
          setActivePremiumSessionId(null);
        }
      } finally {
        if (!cancelled) {
          setPremiumStatusLoading(false);
        }
      }
    }

    void loadPremiumStatus();

    return () => {
      cancelled = true;
    };
  }, []);
  useEffect(() => {
    let cancelled = false;

    async function loadAndRevealRewards() {
      const { data: signalData, error: signalError } =
        await supabase.rpc("get_my_reward_signal_rpc");

      if (signalError) {
        console.error(
          "[Control Room] Reward signal load failed.",
          signalError,
        );
        return;
      }

      if (cancelled) return;

      const signal =
        signalData &&
        typeof signalData === "object" &&
        !Array.isArray(signalData)
          ? (signalData as Record<string, unknown>)
          : null;

      const unseen = signal?.show_badge === true;

      if (!unseen) {
        setRewardSummary([]);
        return;
      }

      const { data: summaryData, error: summaryError } =
        await supabase.rpc(
          "get_my_unseen_reward_summary_rpc",
        );

      if (summaryError) {
        console.error(
          "[Control Room] Reward summary load failed.",
          summaryError,
        );
        return;
      }

      if (cancelled) return;

      const rows = (summaryData || []) as RewardSummaryRow[];

      setRewardSummary(
        rows
          .map((row) => ({
            ...row,
            event_count: Math.max(
              0,
              Math.trunc(Number(row.event_count) || 0),
            ),
            passes_awarded: Math.max(
              0,
              Math.trunc(Number(row.passes_awarded) || 0),
            ),
          }))
          .filter(
            (row) =>
              row.event_count > 0 &&
              row.passes_awarded > 0,
          )
          .sort(
            (left, right) =>
              right.passes_awarded -
              left.passes_awarded,
          )
          .slice(0, 3),
      );

      const { error: revealError } = await supabase.rpc(
        "reveal_my_reward_updates_rpc",
      );

      if (revealError) {
        console.error(
          "[Control Room] Reward acknowledgement failed.",
          revealError,
        );
        return;
      }

      /*
       * Intentionally keep rewardSummary in local state for this visit.
       * Backend is already marked seen, so on the NEXT visit the summary
       * and notification signals disappear.
       */
    }

    void loadAndRevealRewards();

    return () => {
      cancelled = true;
    };
  }, []);

  const [leagueInfo, setLeagueInfo] = useState<LeagueInfo>({
    leagueName: "FantaGol",
    displayName: "Club FantaGol",
    inviteCode: "",
    role: "member",
  });

  useEffect(() => {
    async function loadLeagueInfo() {
      const {
        data: { session },
      } = await supabase.auth.getSession();

      if (!session?.user) {
        window.location.href = "/login";
        return;
      }

      const { data } = await supabase.rpc("get_my_leagues_rpc");
      const firstLeague = (data || [])[0];

      if (firstLeague) {
        setLeagueInfo({
          leagueName: firstLeague.league_name || "Lega FantaGol",
          displayName: firstLeague.display_name || "Club FantaGol",
          inviteCode: firstLeague.invite_code || firstLeague.league_id || "",
          role: firstLeague.role || "member",
        });
      }
    }

    loadLeagueInfo();
  }, []);

  async function handleRewardedVideo() {
    if (rewardedVideoStarting) {
      return;
    }

    setRewardedVideoStarting(true);

    try {
      await startRewardedAdLifecycle();
      setPassPopupOpen(false);
    } catch (error) {
      console.error(
        "[Control Room] Rewarded video lifecycle failed.",
        error,
      );
    } finally {
      setRewardedVideoStarting(false);
    }
  }

  return (
    <main className="min-h-screen overflow-x-hidden bg-[#061014] pt-14 text-white">
      <header className="fixed inset-x-0 top-0 z-[80] border-b border-[#A6E824]/25 bg-[#1f2427] shadow-2xl shadow-black/80">
        <div className="mx-auto flex h-14 w-full max-w-6xl items-center justify-between overflow-visible px-4 md:px-6">
          <div className="pointer-events-none relative z-0 block min-w-0 -translate-x-8 translate-y-5 md:-translate-x-20 md:translate-y-6">
            <FantaGolLogo />
          </div>

          <button
            type="button"
            onClick={() => setMenuOpen(true)}
            aria-label="Apri menu"
            className="relative shrink-0 rounded-lg border border-gray-600 bg-[#2b2f31] px-3 py-2 text-2xl leading-none text-white transition hover:border-[#A6E824]"
          >
            ☰
          </button>
        </div>
      </header>

      <HamburgerDrawer
        open={menuOpen}
        leagueName={leagueInfo.leagueName}
        displayName={leagueInfo.displayName}
        inviteCode={leagueInfo.inviteCode}
        role={leagueInfo.role}
        onClose={() => setMenuOpen(false)}
      />

      <section className="mx-auto w-full max-w-6xl px-4 pb-16 pt-8 sm:px-6 sm:pt-10">
        <section className="rounded-3xl border border-[#A6E824]/30 bg-gradient-to-br from-[#263033] via-[#15191b] to-[#080909] p-6 shadow-2xl shadow-black/70 sm:p-8">
          <div className="flex flex-col gap-5 sm:flex-row sm:items-center">
            <ControlRoomIcon />

            <div className="min-w-0">
              <p className="text-sm font-black uppercase tracking-[0.3em] text-[#A6E824]">
                FantaGol
              </p>

              <h1 className="mt-2 text-5xl font-black tracking-tight sm:text-6xl">
                Control Room
              </h1>

              <p className="mt-4 max-w-3xl text-base leading-7 text-gray-300 sm:text-lg sm:leading-8">
                La Control Room è l&apos;area avanzata dedicata alle statistiche
                globali FantaGol: dati aggregati e anonimi sulle giocate degli
                utenti, trend dei pronostici, squadre più lette, risultati più
                cercati, bonus, malus e andamento generale delle scelte della
                community a confronto con quelle dei principali bookmakers.
              </p>
            </div>
          </div>

          <div className="mt-7 flex flex-wrap gap-2">
            <FeaturePill label="Dati aggregati" />
            <FeaturePill label="Utenti anonimi" />
            <FeaturePill label="Trend pronostici" />
            <FeaturePill label="Squadre" />
          </div>
        </section>

        <section className="mt-6 rounded-3xl border border-white/10 bg-[#0b1419] p-5 shadow-xl shadow-black/30 sm:p-6">
          <h2 className="text-2xl font-black text-[#A6E824]">Cosa contiene</h2>

          <p className="mt-3 max-w-4xl text-sm leading-7 text-gray-300 sm:text-base">
            Le informazioni vengono elaborate in forma aggregata e anonima. Non
            vengono mostrati dati personali dei singoli utenti: la Control Room
            serve a leggere il comportamento generale del gioco FantaGol
            rapportato alle scelte dei principali bookmakers, confrontando
            volume delle giocate, distribuzione dei pronostici, precisione sulle
            squadre, frequenza degli exact e incidenza dei bonus/malus.
          </p>

          <div className="mt-5 grid gap-3 sm:grid-cols-2 lg:grid-cols-4">
            <div className="rounded-2xl border border-white/10 bg-black/30 p-4">
              <p className="text-[10px] font-black uppercase tracking-[0.16em] text-gray-500">
                Pronostici
              </p>
              <p className="mt-2 text-xl font-black text-white">Trend 1-X-2</p>
            </div>

            <div className="rounded-2xl border border-white/10 bg-black/30 p-4">
              <p className="text-[10px] font-black uppercase tracking-[0.16em] text-gray-500">
                Squadre
              </p>
              <p className="mt-2 text-xl font-black text-white">
                Letture globali
              </p>
            </div>

            <div className="rounded-2xl border border-white/10 bg-black/30 p-4">
              <p className="text-[10px] font-black uppercase tracking-[0.16em] text-gray-500">
                Risultati
              </p>
              <p className="mt-2 text-xl font-black text-white">
                Exact più scelti
              </p>
            </div>

            <div className="rounded-2xl border border-white/10 bg-black/30 p-4">
              <p className="text-[10px] font-black uppercase tracking-[0.16em] text-gray-500">
                Bonus/Malus
              </p>
              <p className="mt-2 text-xl font-black text-white">
                Incidenza live
              </p>
            </div>
          </div>
        </section>

        <section className="mt-6 grid grid-cols-[96px_minmax(0,1fr)] gap-2.5 sm:grid-cols-[112px_minmax(0,1fr)] sm:gap-4">
          <button
            type="button"
            onClick={async () => {
          if (premiumStatusLoading || premiumAccessStarting) {
            return;
          }

    if (activePremiumSessionId) {


      window.location.assign(


        `/control-room/${activePremiumSessionId}`,


      );


      return;


    }



    if (availablePasses <= 0) {
                setPassPopupOpen(true);
                return;
              }

              setPremiumAccessStarting(true);

    try {
      const idempotencyKey =
        typeof crypto !== "undefined" &&
        typeof crypto.randomUUID === "function"
          ? `control-room-${crypto.randomUUID()}`
          : `control-room-${Date.now()}-${Math.random()
              .toString(36)
              .slice(2)}`;

      const { data, error } = await supabase.rpc(
        "start_my_premium_access_session_rpc",
        {
          p_resource_code: "CONTROL_ROOM",
          p_idempotency_key: idempotencyKey,
        },
      );

      if (error) {
        throw error;
      }

      const payload =
        data && typeof data === "object" && !Array.isArray(data)
          ? (data as Record<string, unknown>)
          : null;

      const passes = Number(payload?.available_passes ?? availablePasses);

      if (Number.isFinite(passes) && passes >= 0) {
        setAvailablePasses(Math.trunc(passes));
      }

      if (payload?.authorized !== true) {
        if (payload?.error_code === "COMMERCIAL_INSUFFICIENT_PASSES") {
          setPassPopupOpen(true);
          return;
        }

        throw new Error(
          typeof payload?.error_code === "string"
            ? payload.error_code
            : "PREMIUM_ACCESS_NOT_AUTHORIZED",
        );
      }

      const sessionId =
        typeof payload?.session_id === "string"
          ? payload.session_id
          : null;

      if (!sessionId) {
        throw new Error("PREMIUM_ACCESS_SESSION_ID_MISSING");
      }

      window.location.assign(`/control-room/${sessionId}`);
    } catch (error) {
      console.error(
        "[Control Room] Premium session start failed.",
        error,
      );
    } finally {
      setPremiumAccessStarting(false);
    }
            }}
            className="flex min-w-0 flex-col items-center justify-center rounded-3xl border border-[#A6E824]/40 bg-[#A6E824]/10 px-2 py-4 text-center shadow-[0_0_22px_rgba(166,232,36,0.10)] transition hover:-translate-y-0.5 hover:border-[#A6E824] hover:brightness-110 sm:px-3 sm:py-5"
          >
            <AccessIcon />

            <h3 className="mt-2 text-sm font-black uppercase tracking-[0.04em] text-[#A6E824] sm:mt-3 sm:text-base">
              Accedi
            </h3>
          </button>

          <div className="min-w-0 rounded-3xl border border-white/10 bg-[#111417] p-4 text-left shadow-lg shadow-black/30 sm:p-5">
            <p className="text-[10px] font-black uppercase tracking-[0.18em] text-gray-500">
              Pass disponibili
            </p>

            <div className="mt-3 flex min-h-[64px] items-center gap-1.5">
              <div
                className={`min-w-[48px] shrink-0 text-6xl font-black leading-none ${availablePasses > 0 ? "text-[#A6E824]" : "text-gray-500"}`}
              >
                {availablePasses}
              </div>

              {rewardSummary.length > 0 && (
                <div className="min-w-0 flex-1 border-l border-white/10 pl-1.5 sm:pl-2">
                  <div className="space-y-1.5">
                    {rewardSummary.map((reward) => (
                      <div
                        key={reward.reward_code}
                        className="flex min-w-0 items-baseline gap-1 whitespace-nowrap"
                      >
                        <span
                          className="min-w-0 overflow-hidden text-ellipsis whitespace-nowrap text-[9px] font-bold tracking-[-0.02em] text-gray-300 sm:text-[11px]"
                          title={getRewardDisplayLabel(reward)}
                        >
                          {getRewardDisplayLabel(reward)}
                        </span>

                        <span className="shrink-0 text-[9px] font-black tracking-[-0.02em] text-[#A6E824] sm:text-[11px]">
                          +{reward.passes_awarded} Pass
                        </span>
                      </div>
                    ))}
                  </div>
                </div>
              )}
            </div>
          </div>
        </section>

        <section className="mt-6 grid gap-4 md:grid-cols-2">
          <button
            type="button"
            onClick={() => void handleRewardedVideo()}
            disabled={rewardedVideoStarting}
            className="rounded-3xl border border-white/10 bg-[#111417] p-6 text-left shadow-lg shadow-black/30 transition hover:-translate-y-0.5 hover:border-[#A6E824]/70 hover:brightness-110 disabled:cursor-wait disabled:opacity-60"
          >
            <VideoIcon />

            <h3 className="mt-5 text-2xl font-black">
              {rewardedVideoStarting
                ? "Preparazione video..."
                : "Guarda un video"}
            </h3>
          </button>

          <button
            type="button"
            className="rounded-3xl border border-[#A6E824]/40 bg-[#A6E824]/10 p-6 text-left shadow-[0_0_28px_rgba(166,232,36,0.12)] transition hover:-translate-y-0.5 hover:border-[#A6E824] hover:brightness-110"
          >
            <PassIcon />

            <h3 className="mt-5 text-2xl font-black text-[#A6E824]">
              Acquista Pass Control Room
            </h3>
          </button>
        </section>
      </section>
      {passPopupOpen && (
        <div
          className="fixed inset-0 z-[400] flex items-center justify-center bg-black/75 px-4 text-white"
          onClick={() => setPassPopupOpen(false)}
        >
          <div
            className="w-full max-w-md rounded-3xl border border-[#A6E824]/35 bg-[#0b1419] p-6 shadow-2xl shadow-black/80"
            onClick={(event) => event.stopPropagation()}
          >
            <p className="text-sm font-black uppercase tracking-[0.25em] text-[#A6E824]">
              Control Room
            </p>

            <h2 className="mt-3 text-3xl font-black">Pass non disponibili</h2>

            <p className="mt-4 text-sm leading-6 text-gray-300">
              Per accedere puoi guardare un video oppure acquistare un Pass
              Control Room.
            </p>

            <div className="mt-6 grid gap-3">
              <button
                type="button"
                onClick={() => void handleRewardedVideo()}
                disabled={rewardedVideoStarting}
                className="rounded-2xl border border-white/10 bg-black/30 px-5 py-4 text-left font-black transition hover:border-[#A6E824]/60 disabled:cursor-wait disabled:opacity-60"
              >
                {rewardedVideoStarting
                  ? "Preparazione video..."
                  : "Guarda un video"}
              </button>

              <button
                type="button"
                onClick={() => setPassPopupOpen(false)}
                className="rounded-2xl border border-[#A6E824]/35 bg-[#A6E824]/10 px-5 py-4 text-left font-black text-[#A6E824] transition hover:border-[#A6E824]"
              >
                Acquista Pass Control Room
              </button>

              <button
                type="button"
                onClick={() => setPassPopupOpen(false)}
                className="rounded-2xl border border-gray-700 px-5 py-3 text-center text-sm font-black text-gray-400 transition hover:border-white/20 hover:text-white"
              >
                Chiudi
              </button>
            </div>
          </div>
        </div>
      )}
    </main>
  );
}
