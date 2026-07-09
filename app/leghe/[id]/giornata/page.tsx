"use client";

import { useEffect, useMemo, useRef, useState, type TouchEvent } from "react";
import { useParams, useRouter } from "next/navigation";
import HamburgerDrawer from "../../../../components/app/HamburgerDrawer";
import KitPreview from "../../../../components/club/KitPreview";
import { supabase } from "../../../../lib/supabaseClient";
import { getRoundState } from "../../../../lib/roundState";

type Prediction = { home: string; away: string };

type LeagueInfo = {
  name: string;
  displayName: string;
  inviteCode: string;
  role: string;
};

type ClubInfo = {
  name: string;
  motto?: string | null;
  crest_url: string | null;
  kit_template: string;
  kit_primary_color: string;
  kit_secondary_color: string;
  kit_third_color: string;
  kit_logo_mode: string;
  kit_crest_position: string;
  stars_count: number;
};

type Match = {
  home: string;
  away: string;
  homeBadge: string;
  awayBadge: string;
  kickoffDay: string;
  kickoffHour: string;
  liveHome?: number;
  liveAway?: number;
  minute?: string;
  bonusActive?: string[];
  malusActive?: string[];
};

type RuleItem = {
  key: string;
  label: string;
  short: string;
  points: string;
  icon: string;
  tone: "green" | "orange" | "red" | "violet" | "muted";
};

const matches: Match[] = [
  { home: "Atalanta", away: "Sassuolo", homeBadge: "ATA", awayBadge: "SAS", kickoffDay: "Dom 23 Ago", kickoffHour: "13:45", liveHome: 1, liveAway: 0, minute: "62'", bonusActive: ["sign", "uo", "gg"] },
  { home: "Bologna", away: "Lazio", homeBadge: "BOL", awayBadge: "LAZ", kickoffDay: "Dom 23 Ago", kickoffHour: "13:45", liveHome: 0, liveAway: 0, minute: "HT", malusActive: ["opposite"] },
  { home: "Frosinone", away: "Juventus", homeBadge: "FRO", awayBadge: "JUV", kickoffDay: "Dom 23 Ago", kickoffHour: "13:45", liveHome: 1, liveAway: 2, minute: "77'", bonusActive: ["exact", "sign", "gg"] },
  { home: "Genoa", away: "Napoli", homeBadge: "GEN", awayBadge: "NAP", kickoffDay: "Dom 23 Ago", kickoffHour: "13:45", liveHome: 0, liveAway: 1, minute: "35'", bonusActive: ["exact", "sign"] },
  { home: "Inter", away: "Monza", homeBadge: "INT", awayBadge: "MON", kickoffDay: "Dom 23 Ago", kickoffHour: "13:45", liveHome: 2, liveAway: 0, minute: "68'", bonusActive: ["sign", "uo"] },
  { home: "Parma", away: "Cagliari", homeBadge: "PAR", awayBadge: "CAG", kickoffDay: "Dom 23 Ago", kickoffHour: "13:45", malusActive: ["bad"] },
  { home: "Roma", away: "Fiorentina", homeBadge: "ROM", awayBadge: "FIO", kickoffDay: "Dom 23 Ago", kickoffHour: "13:45", bonusActive: ["surprise"] },
  { home: "Torino", away: "Milan", homeBadge: "TOR", awayBadge: "MIL", kickoffDay: "Dom 23 Ago", kickoffHour: "13:45", bonusActive: ["gg"] },
  { home: "Udinese", away: "Como", homeBadge: "UDI", awayBadge: "COM", kickoffDay: "Dom 23 Ago", kickoffHour: "13:45", bonusActive: ["sign", "show"] },
  { home: "Pisa", away: "Cremonese", homeBadge: "PIS", awayBadge: "CRE", kickoffDay: "Lun 24 Ago", kickoffHour: "20:45" },
];

const ruleItems: RuleItem[] = [
  { key: "exact", label: "Exact", short: "EX", points: "+6", icon: "◎", tone: "muted" },
  { key: "sign", label: "Segno", short: "1X2", points: "+3", icon: "✓", tone: "green" },
  { key: "uo", label: "Over/Under", short: "U/O", points: "+1", icon: "%", tone: "muted" },
  { key: "gg", label: "Gol/NoGol", short: "G/NG", points: "+1", icon: "▣", tone: "green" },
  { key: "surprise", label: "Sorpresa", short: "SOR", points: "+2", icon: "☆", tone: "orange" },
  { key: "show", label: "Gol Show", short: "SHOW", points: "+1", icon: "✴", tone: "orange" },
  { key: "slam", label: "Grande Slam", short: "SLAM", points: "+1", icon: "◇", tone: "violet" },
  { key: "bad", label: "Cantonata", short: "CAN", points: "-2", icon: "×", tone: "red" },
  { key: "opposite", label: "Segno opposto", short: "OPP", points: "-1", icon: "↔", tone: "red" },
];

function cleanGoal(value: string) {
  if (!/^\d*$/.test(value)) return null;
  return value.slice(0, 2);
}

function TeamBadge({ label }: { label: string }) {
  return (
    <span className="flex h-5 w-5 shrink-0 items-center justify-center rounded-full border border-white/10 bg-gradient-to-br from-[#1f2d35] to-black text-[6px] font-black text-white shadow-inner shadow-white/10 sm:h-8 sm:w-8 sm:text-[8px] lg:h-11 lg:w-11 lg:text-[10px]">
      {label}
    </span>
  );
}

function RuleIcon({ item, active = false, compact = false }: { item: RuleItem; active?: boolean; compact?: boolean }) {
  const toneClass = active
    ? item.tone === "red"
      ? "border-red-500/70 text-red-400 shadow-[0_0_10px_rgba(239,68,68,0.24)]"
      : item.tone === "orange"
        ? "border-orange-400/80 text-orange-300 shadow-[0_0_10px_rgba(251,146,60,0.24)]"
        : item.tone === "violet"
          ? "border-violet-400/80 text-violet-300 shadow-[0_0_10px_rgba(167,139,250,0.24)]"
          : "border-[#A6E824]/80 text-[#A6E824] shadow-[0_0_10px_rgba(166,232,36,0.24)]"
    : "border-white/10 text-gray-600";

  return (
    <span
      className={`${compact ? "h-[18px] w-[18px] text-[11px] sm:h-6 sm:w-6 sm:text-sm" : "h-7 w-7 text-base sm:h-8 sm:w-8 sm:text-lg"} flex items-center justify-center rounded-full border bg-black/30 font-black ${toneClass}`}
      title={item.label}
    >
      {item.icon}
    </span>
  );
}

function RuleStrip() {
  return (
    <section className="mt-3 rounded-2xl border border-white/10 bg-[#0b1419] p-2 shadow-xl shadow-black/30 sm:mt-4 sm:p-3">
      <div className="mb-2 flex items-center justify-between gap-2 px-1">
        <p className="text-[10px] font-black uppercase tracking-[0.16em] text-white sm:text-sm">Bonus & Malus</p>
        <p className="text-[9px] font-bold uppercase text-gray-500 sm:text-xs">Legenda punteggi</p>
      </div>
      <div className="grid grid-cols-9 gap-1 sm:gap-2">
        {ruleItems.map((item) => (
          <div key={item.key} className="flex min-w-0 flex-col items-center justify-center rounded-xl border border-white/5 bg-black/20 px-0.5 py-1.5 sm:px-2 sm:py-2">
            <RuleIcon item={item} active={item.tone !== "muted" && item.key !== "bad" && item.key !== "opposite"} compact />
            <p className="mt-1 max-w-full truncate text-[7px] font-black uppercase text-gray-300 sm:text-[9px]">{item.short}</p>
            <p className={`text-[9px] font-black sm:text-xs ${item.points.startsWith("-") ? "text-red-400" : item.tone === "orange" ? "text-orange-300" : item.tone === "violet" ? "text-violet-300" : "text-[#A6E824]"}`}>{item.points}</p>
          </div>
        ))}
      </div>
    </section>
  );
}

function getMatchPoints(activeKeys: Set<string>) {
  if (activeKeys.has("bad")) return "-2";
  if (activeKeys.has("exact")) return "11";
  if (activeKeys.has("sign")) return activeKeys.has("uo") || activeKeys.has("gg") ? "5" : "3";
  if (activeKeys.has("uo") || activeKeys.has("gg")) return "1";
  if (activeKeys.has("opposite")) return "-1";
  return "-";
}

export default function GiornataPage() {
  const router = useRouter();
  const params = useParams<{ id: string }>();
  const leagueId = params.id;

  const [menuOpen, setMenuOpen] = useState(false);
  const [modeOpen, setModeOpen] = useState(false);
  const [clubInfo, setClubInfo] = useState<ClubInfo | null>(null);
  const [activeSwipeIndex, setActiveSwipeIndex] = useState(0);
  const swipeStartXRef = useRef<number | null>(null);
  const swipeStartYRef = useRef<number | null>(null);
  const swipeLockRef = useRef<"x" | "y" | null>(null);
  const [swipeDragX, setSwipeDragX] = useState(0);
  const [swipeTransition, setSwipeTransition] = useState(false);
  const [leagueInfo, setLeagueInfo] = useState<LeagueInfo>({
    name: "Lega FantaGol",
    displayName: "Club FantaGol",
    inviteCode: leagueId,
    role: "member",
  });

  const [submitted, setSubmitted] = useState(false);
  const [predictions, setPredictions] = useState<Prediction[]>(matches.map(() => ({ home: "", away: "" })));

  // Simulazione temporanea: quando collegheremo il backend useremo currentRound.first_kick_at.
  const round = getRoundState("2026-08-23T13:44:55");

  useEffect(() => {
    async function loadLeagueInfo() {
      const { data, error } = await supabase.rpc("get_my_leagues_rpc");
      if (error) return;

      const current = (data || []).find((row: any) => row.league_id === leagueId);
      if (!current) return;

      setLeagueInfo({
        name: current.league_name || "Lega FantaGol",
        displayName: current.display_name || "Club FantaGol",
        inviteCode: current.invite_code || leagueId,
        role: current.role || "member",
      });

      const { data: clubData } = await supabase.rpc("get_my_club_rpc");
      const club = (clubData || [])[0];

      if (club) {
        setClubInfo({
          name: club.name || current.display_name || "Club FantaGol",
          motto: club.motto || null,
          crest_url: club.crest_url || null,
          kit_template: club.kit_template || "solid",
          kit_primary_color: club.kit_primary_color || "#FFFFFF",
          kit_secondary_color: club.kit_secondary_color || "#111417",
          kit_third_color: club.kit_third_color || "#A6E824",
          kit_logo_mode: club.kit_logo_mode || "center_horizontal",
          kit_crest_position: club.kit_crest_position || "left_chest",
          stars_count: club.stars_count || 0,
        });
      }
    }

    loadLeagueInfo();
  }, [leagueId]);

  const submittedCount = useMemo(
    () => predictions.filter((prediction) => prediction.home !== "" && prediction.away !== "").length,
    [predictions]
  );

  const allComplete = submittedCount === matches.length;
  const locked = round.isLocked;
  const currentPoints = 100;

  const isLiveForSwipe = round.isLive || round.isFinished;
  const swipeProfiles = useMemo(() => [
    {
      id: "me",
      clubName: clubInfo?.name || leagueInfo.displayName || "Club FantaGol",
      motto: clubInfo?.motto || "Il tuo Club FantaGol sta per iniziare la sua storia.",
      avatarUrl: clubInfo?.crest_url || null,
      kitTemplate: clubInfo?.kit_template || "solid",
      kitPrimaryColor: clubInfo?.kit_primary_color || "#FFFFFF",
      kitSecondaryColor: clubInfo?.kit_secondary_color || "#111417",
      kitThirdColor: clubInfo?.kit_third_color || "#A6E824",
      kitLogoMode: clubInfo?.kit_logo_mode || "center_horizontal",
      kitCrestPosition: clubInfo?.kit_crest_position || "left_chest",
      starsCount: clubInfo?.stars_count || 0,
      isCurrentUser: true,
    },
    {
      id: "demo-1",
      clubName: "Real Exact",
      motto: "Precisione, coraggio e pronostici al millimetro.",
      avatarUrl: null,
      kitTemplate: "vertical_3",
      kitPrimaryColor: "#A6E824",
      kitSecondaryColor: "#111417",
      kitThirdColor: "#FFFFFF",
      kitLogoMode: "center_horizontal",
      kitCrestPosition: "left_chest",
      starsCount: 2,
    },
    {
      id: "demo-2",
      clubName: "Bonus Show",
      motto: "Ogni bonus è una dichiarazione di intenti.",
      avatarUrl: null,
      kitTemplate: "diagonal",
      kitPrimaryColor: "#1f2427",
      kitSecondaryColor: "#A6E824",
      kitThirdColor: "#FFFFFF",
      kitLogoMode: "wordmark_only",
      kitCrestPosition: "left_chest",
      starsCount: 1,
    },
  ], [clubInfo, leagueInfo.displayName]);

  const activeProfile = swipeProfiles[Math.min(activeSwipeIndex, swipeProfiles.length - 1)];
  const isFirstProfile = activeSwipeIndex === 0;
  const isLastProfile = activeSwipeIndex === swipeProfiles.length - 1;
  const isViewingSelf = activeProfile?.isCurrentUser === true;
  const viewedClubInfo: ClubInfo = {
    name: activeProfile?.clubName || "Club FantaGol",
    motto: activeProfile?.motto || null,
    crest_url: activeProfile?.avatarUrl || null,
    kit_template: activeProfile?.kitTemplate || "solid",
    kit_primary_color: activeProfile?.kitPrimaryColor || "#FFFFFF",
    kit_secondary_color: activeProfile?.kitSecondaryColor || "#111417",
    kit_third_color: activeProfile?.kitThirdColor || "#A6E824",
    kit_logo_mode: activeProfile?.kitLogoMode || "center_horizontal",
    kit_crest_position: activeProfile?.kitCrestPosition || "left_chest",
    stars_count: activeProfile?.starsCount || 0,
  };
  const canEdit = round.isOpen && isViewingSelf;
  const canViewProfileContent = isViewingSelf || isLiveForSwipe;
  const displayedPredictions = canViewProfileContent
    ? predictions
    : matches.map(() => ({ home: "", away: "" }));
  const displayedCurrentPoints = canViewProfileContent ? currentPoints : 0;

  function completeProfileSwipe(nextIndex: number, direction: "next" | "prev") {
    const bounded = Math.min(Math.max(nextIndex, 0), swipeProfiles.length - 1);
    const viewportWidth = typeof window !== "undefined" ? window.innerWidth : 420;
    const exitX = direction === "next" ? -viewportWidth : viewportWidth;
    const enterX = direction === "next" ? viewportWidth * 0.18 : -viewportWidth * 0.18;

    setSwipeTransition(true);
    setSwipeDragX(exitX);

    window.setTimeout(() => {
      setActiveSwipeIndex(bounded);
      setSwipeTransition(false);
      setSwipeDragX(enterX);

      window.requestAnimationFrame(() => {
        setSwipeTransition(true);
        setSwipeDragX(0);

        window.setTimeout(() => {
          setSwipeTransition(false);
        }, 280);
      });
    }, 170);
  }

  function bounceSwipe() {
    setSwipeTransition(true);
    setSwipeDragX(0);

    window.setTimeout(() => {
      setSwipeTransition(false);
    }, 240);
  }

  function goToProfile(nextIndex: number) {
    const bounded = Math.min(Math.max(nextIndex, 0), swipeProfiles.length - 1);

    if (bounded === activeSwipeIndex) {
      bounceSwipe();
      return;
    }

    completeProfileSwipe(bounded, bounded > activeSwipeIndex ? "next" : "prev");
  }

  function goPrevProfile() {
    if (!isFirstProfile) goToProfile(activeSwipeIndex - 1);
    else bounceSwipe();
  }

  function goNextProfile() {
    if (!isLastProfile) goToProfile(activeSwipeIndex + 1);
    else bounceSwipe();
  }

  function handlePageSwipeStart(event: TouchEvent<HTMLElement>) {
    const target = event.target as HTMLElement;
    if (target.closest("input, textarea, select")) return;

    swipeStartXRef.current = event.touches[0]?.clientX ?? null;
    swipeStartYRef.current = event.touches[0]?.clientY ?? null;
    swipeLockRef.current = null;
    setSwipeTransition(false);
  }

  function handlePageSwipeMove(event: TouchEvent<HTMLElement>) {
    if (swipeStartXRef.current === null || swipeStartYRef.current === null) return;

    const currentX = event.touches[0]?.clientX ?? swipeStartXRef.current;
    const currentY = event.touches[0]?.clientY ?? swipeStartYRef.current;
    const deltaX = currentX - swipeStartXRef.current;
    const deltaY = currentY - swipeStartYRef.current;

    if (!swipeLockRef.current) {
      if (Math.abs(deltaX) < 10 && Math.abs(deltaY) < 10) return;
      swipeLockRef.current = Math.abs(deltaX) > Math.abs(deltaY) * 1.25 ? "x" : "y";
    }

    if (swipeLockRef.current !== "x") return;

    const blockedAtStart = isFirstProfile && deltaX > 0;
    const blockedAtEnd = isLastProfile && deltaX < 0;
    const resistance = blockedAtStart || blockedAtEnd ? 0.22 : 1;

    setSwipeDragX(deltaX * resistance);
  }

  function handlePageSwipeEnd(event: TouchEvent<HTMLElement>) {
    if (swipeStartXRef.current === null) return;

    const endX = event.changedTouches[0]?.clientX ?? swipeStartXRef.current;
    const deltaX = endX - swipeStartXRef.current;
    const threshold = 70;

    swipeStartXRef.current = null;
    swipeStartYRef.current = null;
    swipeLockRef.current = null;

    if (Math.abs(deltaX) < threshold) {
      bounceSwipe();
      return;
    }

    if (deltaX < 0 && !isLastProfile) {
      completeProfileSwipe(activeSwipeIndex + 1, "next");
      return;
    }

    if (deltaX > 0 && !isFirstProfile) {
      completeProfileSwipe(activeSwipeIndex - 1, "prev");
      return;
    }

    bounceSwipe();
  }

  const swipeAbs = Math.min(Math.abs(swipeDragX), 180);
  const swipeScale = 1 - Math.min(swipeAbs / 7000, 0.026);
  const swipeOpacity = 1 - Math.min(swipeAbs / 3600, 0.045);
  const swipeGlowOpacity = Math.min(swipeAbs / 130, 1);
  const swipeNextPreview =
    swipeDragX < -8 && !isLastProfile
      ? swipeProfiles[activeSwipeIndex + 1]
      : swipeDragX > 8 && !isFirstProfile
        ? swipeProfiles[activeSwipeIndex - 1]
        : null;

  function updatePrediction(index: number, field: keyof Prediction, value: string) {
    if (!canEdit) return;
    setPredictions((current) =>
      current.map((prediction, currentIndex) => {
        if (currentIndex !== index) return prediction;
        const nextGoal = cleanGoal(value);
        if (nextGoal === null) return prediction;
        return { ...prediction, [field]: nextGoal };
      })
    );
  }

  function submitPredictions() {
    if (locked) return;

    if (!allComplete) {
      alert("Completa tutti i 10 pronostici prima di inviare.");
      return;
    }
    setSubmitted(true);
    window.scrollTo({ top: 0, behavior: "smooth" });
  }

  return (
    <main
      className="min-h-screen overflow-x-hidden bg-[#061014] text-white"
      onTouchStart={handlePageSwipeStart}
      onTouchMove={handlePageSwipeMove}
      onTouchEnd={handlePageSwipeEnd}
    >

      <HamburgerDrawer
        open={menuOpen}
        leagueName={leagueInfo.name}
        displayName={viewedClubInfo.name}
        inviteCode={leagueInfo.inviteCode}
        role={leagueInfo.role}
        onClose={() => setMenuOpen(false)}
      />

      {!isFirstProfile && (
        <button
          type="button"
          onClick={goPrevProfile}
          className="fixed left-4 top-1/2 z-[90] hidden h-14 w-14 -translate-y-1/2 items-center justify-center rounded-full border border-[#A6E824]/35 bg-black/60 text-4xl font-black text-[#A6E824] shadow-2xl shadow-black/70 transition hover:border-[#A6E824] hover:bg-[#A6E824]/10 md:flex"
          aria-label="Profilo precedente"
        >
          ‹
        </button>
      )}

      {!isLastProfile && (
        <button
          type="button"
          onClick={goNextProfile}
          className="fixed right-4 top-1/2 z-[90] hidden h-14 w-14 -translate-y-1/2 items-center justify-center rounded-full border border-[#A6E824]/35 bg-black/60 text-4xl font-black text-[#A6E824] shadow-2xl shadow-black/70 transition hover:border-[#A6E824] hover:bg-[#A6E824]/10 md:flex"
          aria-label="Profilo successivo"
        >
          ›
        </button>
      )}

      {swipeNextPreview && (
        <div
          className={`pointer-events-none fixed inset-y-0 z-[10] hidden w-[16vw] max-w-[190px] items-center px-3 md:flex ${
            swipeDragX < 0 ? "right-0 justify-end" : "left-0 justify-start"
          }`}
          style={{ opacity: swipeGlowOpacity }}
        >
          <div className="w-full rounded-[2rem] border border-[#A6E824]/25 bg-[#0b1419] p-4 shadow-[0_0_50px_rgba(166,232,36,0.10)]">
            <div className="text-[10px] font-black uppercase tracking-[0.16em] text-[#A6E824]">
              {swipeDragX < 0 ? "Prossimo" : "Precedente"}
            </div>
            <div className="mt-2 truncate text-sm font-black text-white">
              {swipeNextPreview.clubName}
            </div>
          </div>
        </div>
      )}

      <section
        className="mx-auto max-w-6xl px-2 pb-12 pt-2 sm:px-5 sm:pb-16 sm:pt-3"
        style={{
          transform: `translate3d(${swipeDragX}px, 0, 0) scale(${swipeScale})`,
          opacity: swipeOpacity,
          transition: swipeTransition
            ? "transform 260ms cubic-bezier(.22,.61,.36,1), opacity 260ms cubic-bezier(.22,.61,.36,1), filter 260ms cubic-bezier(.22,.61,.36,1)"
            : "none",
          filter: swipeDragX !== 0 ? "drop-shadow(0 28px 70px rgba(0,0,0,0.55))" : "none",
          willChange: "transform, opacity, filter",
        }}
      >
        <header className="grid grid-cols-[1.35fr_1fr_1fr_1fr] gap-2 border-b border-white/10 py-3 sm:gap-3 sm:py-5">
          <div className="rounded-2xl border border-white/10 bg-black/25 p-3">
            <div className="flex h-full items-center gap-2">
              <div className="flex h-8 w-8 shrink-0 items-center justify-center rounded-xl border border-white/10 bg-black/30 text-base">
                🏆
              </div>
              <div className="min-w-0">
                <p className="text-[9px] font-black uppercase text-gray-500 sm:text-xs">Punti</p>
                <div className="flex items-end gap-1">
                  <span className="text-[1.7rem] font-black leading-none text-[#A6E824] sm:text-4xl">
                    {displayedCurrentPoints}
                  </span>
                  <span className="pb-0.5 text-xs font-black text-white sm:text-sm">pt</span>
                </div>
              </div>
            </div>
          </div>

          <div className="rounded-2xl border border-white/10 bg-black/25 p-2">
            <div className="mx-auto flex h-16 w-12 items-center justify-center overflow-hidden rounded-xl bg-[#111417]">
              {viewedClubInfo && (
                <div className="scale-[0.32]">
                  <KitPreview
                    primary={viewedClubInfo.kit_primary_color}
                    secondary={viewedClubInfo.kit_secondary_color}
                    third={viewedClubInfo.kit_third_color}
                    template={viewedClubInfo.kit_template}
                    logoMode={viewedClubInfo.kit_logo_mode}
                    crestPosition={viewedClubInfo.kit_crest_position}
                    starsCount={viewedClubInfo.stars_count}
                  />
                </div>
              )}
            </div>

            <p className="mt-1 truncate text-center text-[9px] font-black text-white sm:text-xs">
              {viewedClubInfo.name}
            </p>
            <p className="mx-auto mt-0.5 line-clamp-2 max-w-[88px] text-center text-[7px] font-semibold leading-3 text-gray-500 sm:max-w-[120px] sm:text-[9px]">
              {viewedClubInfo.motto || "Il tuo Club FantaGol sta per iniziare la sua storia."}
            </p>
          </div>

          <div className="rounded-2xl border border-white/10 bg-black/25 p-3 text-center">
            <div className="flex items-center justify-center gap-2">
              <button className="hidden h-8 w-8 items-center justify-center rounded-xl border border-white/10 bg-black/30 text-xl text-gray-400 sm:flex">
                ‹
              </button>

              <div>
                <p className="text-[9px] font-bold uppercase text-gray-500 sm:text-xs">Giornata</p>
                <p className="text-2xl font-black text-white sm:text-3xl">2</p>
              </div>

              <button className="hidden h-8 w-8 items-center justify-center rounded-xl border border-white/10 bg-black/30 text-xl text-gray-400 sm:flex">
                ›
              </button>
            </div>
          </div>

          <button
            type="button"
            onClick={() => router.push("/statistiche")}
            className="rounded-2xl border border-white/10 bg-black/25 p-3 text-center transition hover:border-[#A6E824]/60 hover:bg-white/[0.03]"
          >
            <div className="mx-auto flex h-10 w-14 items-end gap-1 rounded-xl border border-white/10 bg-[#071015] px-2 pb-2 sm:h-12 sm:w-16">
              <span className="h-3 flex-1 rounded-t bg-[#A6E824]/50 sm:h-4" />
              <span className="h-6 flex-1 rounded-t bg-[#A6E824] sm:h-7" />
              <span className="h-4 flex-1 rounded-t bg-[#A6E824]/70 sm:h-5" />
              <span className="h-8 flex-1 rounded-t bg-[#A6E824]/90 sm:h-9" />
            </div>

            <p className="mt-1 text-[9px] font-black uppercase text-gray-500 sm:text-xs">
              Statistiche
            </p>
          </button>
        </header>

        <section className="relative z-30 mt-3 grid overflow-visible rounded-2xl border border-white/10 bg-[#0b1419] shadow-xl shadow-black/30 sm:mt-4 md:grid-cols-[1.5fr_1fr]">
          <div className="flex items-center gap-3 border-b border-white/10 p-3 sm:gap-4 sm:p-4 md:border-b-0 md:border-r">
            <div
              className={`relative flex h-12 w-12 shrink-0 items-center justify-center rounded-full border text-2xl shadow-[0_0_28px_rgba(166,232,36,0.18)] sm:h-16 sm:w-16 sm:text-3xl ${
                locked
                  ? "border-gray-500/40 bg-gray-500/10 text-gray-400 shadow-[0_0_22px_rgba(156,163,175,0.10)]"
                  : "border-[#A6E824]/40 bg-[#A6E824]/20 text-[#A6E824]"
              }`}
            >
              <span>✎</span>
              {locked && (
                <span className="absolute -bottom-1 -right-1 flex h-6 w-6 items-center justify-center rounded-full border border-gray-500/40 bg-[#071015] text-[13px] shadow-lg sm:h-7 sm:w-7 sm:text-sm">
                  🔒
                </span>
              )}
            </div>
            <div>
              <p className="text-sm font-black uppercase sm:text-lg">
                {locked ? round.label : submitted ? "Pronostici inviati" : round.label}
              </p>
              <p className="text-xs text-gray-300 sm:text-sm">
                {locked ? round.helper : submitted ? "Puoi modificare e reinviare fino al lock ufficiale" : round.helper}
              </p>
            </div>
          </div>
          <div className="relative p-3 sm:p-4">
            <button
              type="button"
              onClick={() => setModeOpen((current) => !current)}
              className="flex w-full items-center justify-between rounded-2xl border border-white/10 bg-black/20 px-3 py-3 text-left transition hover:border-[#A6E824]/50"
            >
              <div>
                <p className="text-[10px] font-bold uppercase tracking-[0.16em] text-gray-500 sm:text-xs">Modalità</p>
                <p className="text-base font-black uppercase sm:text-lg">Punti Puri</p>
              </div>
              <span className="text-2xl text-white sm:text-3xl">⌄</span>
            </button>

            {modeOpen && (
              <div className="absolute left-3 right-3 top-[calc(100%-10px)] z-50 overflow-hidden rounded-2xl border border-white/10 bg-[#10181d] shadow-2xl shadow-black/80">
                <button
                  type="button"
                  onClick={() => router.push(`/leghe/${leagueId}/fantacalcio`)}
                  className="flex w-full items-center justify-between px-4 py-3 text-left transition hover:bg-white/5"
                >
                  <span>
                    <span className="block text-sm font-black uppercase text-white sm:text-base">Modalità Fantacalcio</span>
                    <span className="block text-[11px] font-semibold text-gray-500">Vai al duello live</span>
                  </span>
                  <span className="text-xl">🏆</span>
                </button>

                <button
                  type="button"
                  onClick={() => router.push(`/leghe/${leagueId}/onetoone`)}
                  className="flex w-full items-center justify-between border-t border-white/10 px-4 py-3 text-left transition hover:bg-white/5"
                >
                  <span>
                    <span className="block text-sm font-black uppercase text-white sm:text-base">Modalità One To One</span>
                    <span className="block text-[11px] font-semibold text-gray-500">Vai alla sfida diretta</span>
                  </span>
                  <span className="text-xl">⚔️</span>
                </button>
              </div>
            )}
          </div>
        </section>

        <RuleStrip />

        <section className="mt-3 overflow-hidden rounded-2xl border border-white/10 bg-[#0b1419] shadow-2xl shadow-black/40 sm:mt-4">
          <div className="grid grid-cols-[35%_17%_14%_9%_25%] items-center gap-0 border-b border-white/10 px-1 py-2 text-center text-[8px] font-black uppercase tracking-tight text-gray-500 sm:grid-cols-[1.65fr_150px_150px_100px_190px] sm:px-4 sm:py-3 sm:text-[11px] sm:tracking-wide">
            <span>Partita</span>
            <span className="text-[#A6E824]">Pron.</span>
            <span>Ris.</span>
            <span className="text-[#A6E824]">Pt</span>
            <span>Bonus</span>
          </div>

          {matches.map((match, index) => {
            const prediction = displayedPredictions[index];
            const activeKeys = new Set([...(match.bonusActive ?? []), ...(match.malusActive ?? [])]);
            const showLiveScore = round.isLive || round.isFinished;

            return (
              <article key={`${match.home}-${match.away}`} className="border-b border-white/10 px-1 py-2 last:border-b-0 sm:px-4 sm:py-3">
                <div className="grid grid-cols-[35%_17%_14%_9%_25%] items-center gap-0 sm:grid-cols-[1.65fr_150px_150px_100px_190px] sm:gap-3">
                  <div className="min-w-0 pr-1 sm:pr-0">
                    <div className="flex min-w-0 items-center gap-1 sm:gap-2">
                      <TeamBadge label={match.homeBadge} />
                      <p className="min-w-0 truncate text-[10px] font-black leading-tight sm:text-base lg:text-lg">{match.home}</p>
                    </div>
                    <div className="my-0.5 pl-6 text-[7px] font-bold uppercase leading-none text-gray-500 sm:my-1 sm:pl-10 sm:text-[10px]">
                      {match.kickoffHour}
                    </div>
                    <div className="flex min-w-0 items-center gap-1 sm:gap-2">
                      <TeamBadge label={match.awayBadge} />
                      <p className="min-w-0 truncate text-[10px] font-black leading-tight sm:text-base lg:text-lg">{match.away}</p>
                    </div>
                  </div>

                  <div className="flex items-center justify-center gap-0.5 sm:gap-2">
                    <input
                      value={prediction.home}
                      disabled={!canEdit}
                      inputMode="numeric"
                      onChange={(event) => updatePrediction(index, "home", event.target.value)}
                      className="h-8 w-5 rounded-md border border-white/15 bg-black/35 text-center text-[12px] font-black outline-none focus:border-[#A6E824] disabled:opacity-80 sm:h-11 sm:w-14 sm:rounded-lg sm:text-lg"
                      placeholder="-"
                    />
                    <span className="text-[10px] font-black text-gray-500 sm:text-base">-</span>
                    <input
                      value={prediction.away}
                      disabled={!canEdit}
                      inputMode="numeric"
                      onChange={(event) => updatePrediction(index, "away", event.target.value)}
                      className="h-8 w-5 rounded-md border border-white/15 bg-black/35 text-center text-[12px] font-black outline-none focus:border-[#A6E824] disabled:opacity-80 sm:h-11 sm:w-14 sm:rounded-lg sm:text-lg"
                      placeholder="-"
                    />
                  </div>

                  <div className="flex items-center justify-center">
                    {showLiveScore ? (
                      <div className="flex w-full max-w-[42px] flex-col items-center rounded-lg border border-white/10 bg-black/30 px-0.5 py-1 sm:max-w-[120px] sm:rounded-xl sm:px-3 sm:py-2">
                        <span className="text-[7px] font-bold uppercase leading-none text-[#A6E824] sm:text-[10px]">{match.minute ?? "FT"}</span>
                        <span className="mt-0.5 text-[12px] font-black leading-none sm:text-xl">{match.liveHome ?? 0}-{match.liveAway ?? 0}</span>
                      </div>
                    ) : (
                      <span className="text-lg font-black text-gray-500 sm:text-2xl">-</span>
                    )}
                  </div>

                  <div className="text-center text-[13px] font-black leading-none text-white sm:text-2xl">
                    {showLiveScore && activeKeys.size ? getMatchPoints(activeKeys) : "-"}
                  </div>

                  <div className="grid grid-cols-3 justify-items-center gap-0.5 sm:flex sm:flex-wrap sm:justify-center sm:gap-1.5">
                    {ruleItems.map((item) => (
                      <RuleIcon key={item.key} item={item} active={activeKeys.has(item.key)} compact />
                    ))}
                  </div>
                </div>
              </article>
            );
          })}
        </section>

        <section className="mt-5 flex justify-center">
          <button
            type="button"
            onClick={submitPredictions}
            disabled={locked || !isViewingSelf}
            className={`w-full max-w-2xl rounded-2xl px-6 py-4 text-base font-black uppercase text-white shadow-lg transition sm:py-5 sm:text-lg ${locked ? "cursor-not-allowed bg-gray-700 text-gray-300 shadow-black/20" : "bg-[#8cc91e] shadow-[#A6E824]/20 hover:brightness-110"}`}
          >
            {!isViewingSelf ? "Pronostici visibili dal live" : locked ? "🔒 Pronostici bloccati" : submitted ? "✎ Reinvia i pronostici" : "✈ Invia i pronostici"}
          </button>
        </section>
      </section>

    </main>
  );
}
