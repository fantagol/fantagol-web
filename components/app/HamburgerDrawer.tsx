"use client";

import { useEffect, useState } from "react";
import { supabase } from "../../lib/supabaseClient";
import KitPreview from "../club/KitPreview";

type HamburgerDrawerProps = {
  open: boolean;
  leagueName: string;
  displayName: string;
  inviteCode: string;
  role: string;
  onClose: () => void;
};

type DrawerLeagueData = {
  leagueId: string;
  leagueName: string;
  displayName: string;
  inviteCode: string;
  role: string;
};

type DrawerClubData = {
  name: string;
  motto: string | null;
  kit_template: string;
  kit_primary_color: string;
  kit_secondary_color: string;
  kit_third_color: string;
  kit_logo_mode: string;
  kit_crest_position: string;
  stars_count: number;
};


function MenuIcon({ icon }: { icon: string }) {
  const base =
    "flex h-10 w-10 shrink-0 items-center justify-center rounded-xl border border-white/10 bg-[#071015]";

  if (icon === "plus") {
    return (
      <span className={base}>
        <span className="relative h-5 w-5">
          <span className="absolute left-1/2 top-0 h-full w-1 -translate-x-1/2 rounded-full bg-[#A6E824]" />
          <span className="absolute left-0 top-1/2 h-1 w-full -translate-y-1/2 rounded-full bg-[#A6E824]" />
        </span>
      </span>
    );
  }

  if (icon === "invite") {
    return (
      <span className={base}>
        <span className="relative h-5 w-6 rounded-md border border-[#A6E824]/70">
          <span className="absolute left-1 top-1 h-3 w-4 rotate-[-35deg] border-b border-l border-[#A6E824]/70" />
        </span>
      </span>
    );
  }

  if (icon === "target") {
    return (
      <span className={base}>
        <span className="flex h-6 w-6 items-center justify-center rounded-full border-2 border-[#A6E824]/80">
          <span className="flex h-3.5 w-3.5 items-center justify-center rounded-full border border-[#A6E824]/70">
            <span className="h-1.5 w-1.5 rounded-full bg-[#A6E824]" />
          </span>
        </span>
      </span>
    );
  }

  if (icon === "live") {
    return (
      <span className={base}>
        <span className="relative h-6 w-6 rounded-full border-2 border-[#A6E824]/80">
          <span className="absolute left-1/2 top-1/2 h-2 w-2 -translate-x-1/2 -translate-y-1/2 rounded-full bg-[#A6E824]" />
          <span className="absolute -right-1 -top-1 h-2.5 w-2.5 rounded-full bg-red-400" />
        </span>
      </span>
    );
  }

  if (icon === "ranking") {
    return (
      <span className={base}>
        <span className="relative h-7 w-7">
          <span className="absolute left-1/2 top-0 h-2 w-2 -translate-x-1/2 rounded-full bg-[#A6E824]" />
          <span className="absolute bottom-0 left-1/2 h-5 w-2.5 -translate-x-1/2 rounded-t bg-[#A6E824]" />
          <span className="absolute bottom-0 left-0 h-3.5 w-2.5 rounded-t bg-[#A6E824]/55" />
          <span className="absolute bottom-0 right-0 h-4 w-2.5 rounded-t bg-[#A6E824]/75" />
        </span>
      </span>
    );
  }

  if (icon === "control") {
    return (
      <span className="flex h-10 w-10 shrink-0 items-center justify-center rounded-xl border border-[#A6E824]/35 bg-[#A6E824]/10 shadow-[0_0_16px_rgba(166,232,36,0.18)]">
        <span className="relative h-7 w-7 rounded-lg border border-[#A6E824]/70 bg-black/40">
          <span className="absolute left-1 top-1 h-1.5 w-1.5 rounded-full bg-[#A6E824]" />
          <span className="absolute bottom-1 left-1 right-1 flex items-end gap-0.5">
            <span className="h-2 flex-1 rounded-t bg-[#A6E824]/50" />
            <span className="h-4 flex-1 rounded-t bg-[#A6E824]" />
            <span className="h-3 flex-1 rounded-t bg-[#A6E824]/70" />
          </span>
        </span>
      </span>
    );
  }

  if (icon === "stats") {
    return (
      <span className={base + " items-end gap-1 px-2 pb-2"}>
        <span className="h-3 flex-1 rounded-t bg-[#A6E824]/50" />
        <span className="h-6 flex-1 rounded-t bg-[#A6E824]" />
        <span className="h-4 flex-1 rounded-t bg-[#A6E824]/70" />
      </span>
    );
  }

  if (icon === "calendar") {
    return (
      <span className={base}>
        <span className="h-6 w-6 overflow-hidden rounded-md border border-[#A6E824]/70">
          <span className="block h-2 bg-[#A6E824]" />
          <span className="grid grid-cols-3 gap-0.5 p-1">
            <span className="h-1 rounded bg-white/40" />
            <span className="h-1 rounded bg-white/40" />
            <span className="h-1 rounded bg-white/40" />
            <span className="h-1 rounded bg-white/40" />
            <span className="h-1 rounded bg-[#A6E824]" />
            <span className="h-1 rounded bg-white/40" />
          </span>
        </span>
      </span>
    );
  }

  if (icon === "members") {
    return (
      <span className={base}>
        <span className="relative h-6 w-7">
          <span className="absolute left-2 top-0 h-3 w-3 rounded-full bg-[#A6E824]" />
          <span className="absolute bottom-0 left-1 h-3 w-5 rounded-t-full bg-[#A6E824]/80" />
          <span className="absolute right-0 top-2 h-2.5 w-2.5 rounded-full bg-white/50" />
          <span className="absolute bottom-0 right-0 h-2.5 w-4 rounded-t-full bg-white/30" />
        </span>
      </span>
    );
  }

  if (icon === "club") {
    return (
      <span className={base}>
        <span className="h-6 w-6 rounded-md border-2 border-[#A6E824]/80 bg-[#A6E824]/10">
          <span className="mx-auto mt-1 block h-3 w-3 rounded-full border border-[#A6E824]" />
        </span>
      </span>
    );
  }

  if (icon === "hall") {
    return (
      <span className={base}>
        <span className="relative h-6 w-6">
          <span className="absolute left-1/2 top-0 h-4 w-5 -translate-x-1/2 rounded-b-lg border-2 border-[#A6E824]" />
          <span className="absolute bottom-1 left-1/2 h-2 w-1 -translate-x-1/2 bg-[#A6E824]" />
          <span className="absolute bottom-0 left-1/2 h-1 w-5 -translate-x-1/2 rounded bg-[#A6E824]" />
        </span>
      </span>
    );
  }

  if (icon === "settings") {
    return (
      <span className={base}>
        <span className="flex h-6 w-6 items-center justify-center rounded-full border-2 border-[#A6E824]">
          <span className="h-2 w-2 rounded-full bg-[#A6E824]" />
        </span>
      </span>
    );
  }

  if (icon === "help") {
    return (
      <span className={base}>
        <span className="text-xl font-black text-[#A6E824]">?</span>
      </span>
    );
  }

  if (icon === "logout") {
    return (
      <span className="flex h-10 w-10 shrink-0 items-center justify-center rounded-xl border border-red-500/20 bg-red-950/20">
        <span className="relative h-5 w-5 rounded-md border-2 border-red-400">
          <span className="absolute left-3 top-2 h-1 w-3 rounded bg-red-400" />
        </span>
      </span>
    );
  }

  return <span className={base} />;
}

function DrawerMenuItem({
  icon,
  title,
  subtitle,
  danger = false,
  special = false,
  onClick,
}: {
  icon: string;
  title: string;
  subtitle?: string;
  danger?: boolean;
  special?: boolean;
  onClick: () => void;
}) {
  return (
    <button
      type="button"
      onClick={onClick}
      className={`group flex w-full items-center gap-3 rounded-2xl p-3 text-left transition ${
        special
          ? "border border-[#A6E824]/40 bg-[#A6E824]/10 shadow-[0_0_22px_rgba(166,232,36,0.10)] animate-pulse hover:border-[#A6E824]/80 hover:bg-[#A6E824]/15"
          : "border border-white/10 bg-black/25 hover:border-[#A6E824]/60 hover:bg-white/[0.03]"
      } ${danger ? "text-red-400" : "text-white"}`}
    >
      <MenuIcon icon={icon} />

      <span className="min-w-0 flex-1">
        <span className={`block truncate text-sm font-black ${danger ? "text-red-400" : "text-white"}`}>
          {title}
        </span>
        {subtitle && (
          <span className="mt-0.5 block truncate text-[11px] font-semibold text-gray-500">
            {subtitle}
          </span>
        )}
      </span>

      <span className={`shrink-0 text-lg font-black ${danger ? "text-red-400" : "text-[#A6E824]"}`}>
        →
      </span>
    </button>
  );
}

export default function HamburgerDrawer({
  open,
  leagueName,
  displayName,
  inviteCode,
  role,
  onClose,
}: HamburgerDrawerProps) {
  const [drawerLeague, setDrawerLeague] = useState<DrawerLeagueData>({
    leagueId: "",
    leagueName,
    displayName,
    inviteCode,
    role,
  });
  const [drawerLeagues, setDrawerLeagues] = useState<DrawerLeagueData[]>([]);
  const [drawerClub, setDrawerClub] = useState<DrawerClubData | null>(null);
  const [leagueOpen, setLeagueOpen] = useState(false);

  useEffect(() => {
    setDrawerLeague((current) => ({
      leagueId: current.leagueId,
      leagueName,
      displayName,
      inviteCode,
      role,
    }));
  }, [leagueName, displayName, inviteCode, role]);

  useEffect(() => {
    if (!open) return;

    async function loadCurrentLeague() {
      const leagueId = getCurrentLeagueIdFromPath();

      const { data, error } = await supabase.rpc("get_my_leagues_rpc");
      if (error) return;

      const leagues: DrawerLeagueData[] = (data || []).map((row: any) => ({
        leagueId: row.league_id || "",
        leagueName: row.league_name || "Lega FantaGol",
        displayName: row.display_name || "Club FantaGol",
        inviteCode: row.invite_code || row.league_id || "",
        role: row.role || "member",
      }));

      setDrawerLeagues(leagues);

      const current = leagues.find((item) => item.leagueId === leagueId) || leagues[0];
      if (!current) return;

      setDrawerLeague(current);

      const { data: clubData } = await supabase.rpc("get_my_club_rpc");
      const club = (clubData || [])[0];

      if (club) {
        setDrawerClub({
          name: club.name || current.displayName || "Club FantaGol",
          motto: club.motto || null,
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

    loadCurrentLeague();
  }, [open, leagueName, displayName, inviteCode, role]);

  if (!open) return null;

  async function logout() {
    const ok = confirm("Vuoi uscire da FantaGol?");
    if (!ok) return;

    await supabase.auth.signOut();
    window.location.href = "/";
  }

  function copyInviteLink() {
    const activeInviteCode = drawerLeague.inviteCode || inviteCode;
    const inviteLink = `${window.location.origin}/invito/${activeInviteCode}`;
    navigator.clipboard.writeText(inviteLink);
    alert("Link invito copiato.");
  }

  function goTo(path: string) {
    setLeagueOpen(false);
    onClose();
    window.location.href = path;
  }

  function getCurrentLeagueIdFromPath() {
    const match = window.location.pathname.match(/\/leghe\/([^\/]+)/);
    return match?.[1] || "";
  }

  function getLeagueDashboardPath(targetLeagueId?: string) {
    const leagueId = targetLeagueId || getCurrentLeagueIdFromPath();
    return leagueId ? `/leghe/${leagueId}` : "/leghe";
  }

  function getLeagueRoundPath() {
    const leagueId = drawerLeague.leagueId || getCurrentLeagueIdFromPath();
    return leagueId ? `/leghe/${leagueId}/giornata` : "/leghe";
  }

  const activeLeagueName = drawerLeague.leagueName || leagueName;
  const activeDisplayName = drawerLeague.displayName || displayName;
  const activeRole = drawerLeague.role || role;
  const selectableLeagues = drawerLeagues.filter((item) => item.leagueId);

  return (
    <div
      className="fixed inset-0 z-[300] flex justify-end bg-black/70 text-white"
      onClick={onClose}
    >
      <aside
        className="flex h-full w-[65vw] max-w-[360px] min-w-[260px] flex-col overflow-hidden bg-[#111417] text-white shadow-2xl shadow-black/80"
        onClick={(event) => event.stopPropagation()}
      >
        <div className="min-w-0 border-b border-gray-800 p-4">
          {drawerClub && (
            <button
              type="button"
              onClick={() => goTo("/club")}
              className="mb-3 flex w-full items-center gap-3 rounded-2xl border border-white/10 bg-black/35 p-3 text-left transition hover:border-[#A6E824]/60 hover:bg-white/[0.03]"
            >
              <div className="flex h-20 w-16 shrink-0 items-center justify-center overflow-hidden rounded-xl bg-[#171b1d]">
                <div className="scale-[0.38]">
                  <KitPreview
                    primary={drawerClub.kit_primary_color}
                    secondary={drawerClub.kit_secondary_color}
                    third={drawerClub.kit_third_color}
                    template={drawerClub.kit_template}
                    logoMode={drawerClub.kit_logo_mode}
                    crestPosition={drawerClub.kit_crest_position}
                    starsCount={drawerClub.stars_count}
                  />
                </div>
              </div>

              <span className="min-w-0">
                <span className="block truncate text-sm font-black text-white">
                  {drawerClub.name}
                </span>
                <span className="mt-1 line-clamp-2 block text-[11px] font-semibold leading-4 text-gray-400">
                  {drawerClub.motto || "Il tuo Club FantaGol sta per iniziare la sua storia."}
                </span>
              </span>
            </button>
          )}

          <button
            type="button"
            onClick={() => setLeagueOpen((current) => !current)}
            className="w-full rounded-2xl bg-[#A6E824] px-4 py-3 text-left text-sm font-black text-black shadow-lg shadow-[#A6E824]/20 transition hover:brightness-110"
          >
            <span className="flex items-center justify-between gap-3">
              <span className="min-w-0">
                <span className="block text-[10px] font-black uppercase tracking-[0.2em] text-black/60">Lega</span>
                <span className="block truncate">{activeLeagueName}</span>
                <span className="block truncate text-[11px] font-bold text-black/70">{activeDisplayName}</span>
              </span>
              <span className="shrink-0">{leagueOpen ? "⌃" : "⌄"}</span>
            </span>
          </button>

          {leagueOpen && selectableLeagues.length > 0 && (
            <div className="mt-2 overflow-hidden rounded-2xl border border-[#A6E824]/25 bg-[#0b1419] shadow-2xl shadow-black/50">
              {selectableLeagues.map((item) => {
                const current = item.leagueId === drawerLeague.leagueId;

                return (
                  <button
                    key={item.leagueId}
                    type="button"
                    onClick={() => goTo(getLeagueDashboardPath(item.leagueId))}
                    className={`flex w-full items-center justify-between gap-3 border-b border-white/10 px-4 py-3 text-left text-sm font-black text-white transition last:border-b-0 hover:bg-white/5 ${
                      current ? "bg-[#A6E824]/10" : ""
                    }`}
                  >
                    <span className="min-w-0">
                      <span className="block text-[10px] font-black uppercase tracking-[0.18em] text-[#A6E824]">
                        {current ? "Lega in corso" : "Lega"}
                      </span>
                      <span className="block truncate">{item.leagueName}</span>
                      <span className="block truncate text-[11px] font-bold text-gray-500">{item.displayName}</span>
                    </span>
                    <span className="shrink-0 text-[#A6E824]">→</span>
                  </button>
                );
              })}
            </div>
          )}
        </div>

        <nav className="flex-1 space-y-3 overflow-y-auto p-4 text-base text-white">
          <DrawerMenuItem
            icon="plus"
            title="Crea nuova lega"
            subtitle="Apri una nuova competizione"
            onClick={() => goTo("/crea-lega")}
          />

          <DrawerMenuItem
            icon="invite"
            title="Copia link invito"
            subtitle="Invita nuovi membri"
            onClick={copyInviteLink}
          />

          <div className="my-4 border-t border-gray-700" />

          <DrawerMenuItem
            icon="target"
            title="Pronostici"
            subtitle="Inserisci o modifica la giornata"
            onClick={() => goTo(getLeagueRoundPath())}
          />

          <DrawerMenuItem
            icon="live"
            title="Live"
            subtitle="Segui risultati e punti in tempo reale"
            onClick={() => goTo(getLeagueRoundPath())}
          />

          <DrawerMenuItem
            icon="ranking"
            title="Classifiche"
            subtitle="Punti Puri, Fantacalcio, One to One"
            onClick={() => goTo("/classifiche")}
          />

          <DrawerMenuItem
            icon="stats"
            title="Statistiche"
            subtitle="Schede e approfondimenti membri"
            onClick={() => goTo("/statistiche")}
          />

          <DrawerMenuItem
            icon="control"
            title="CONTROL ROOM"
            subtitle="Statistiche globali FantaGol"
            special
            onClick={() => goTo("/control-room")}
          />

          <DrawerMenuItem
            icon="calendar"
            title="Calendario"
            subtitle="Giornate chiuse, live e future"
            onClick={() => goTo("/calendario")}
          />

          <DrawerMenuItem
            icon="members"
            title="Membri"
            subtitle="Club, maglie e nomi reali"
            onClick={() => goTo("/membri")}
          />

          <div className="my-4 border-t border-gray-700" />

          <DrawerMenuItem
            icon="club"
            title="Il Mio Club"
            subtitle="Profilo, avatar e kit"
            onClick={() => goTo("/club")}
          />

          <DrawerMenuItem
            icon="hall"
            title="Hall of Fame"
            subtitle="Titoli, stelle e modalità vinte"
            onClick={() => goTo("/club?scrollTo=hall-of-fame")}
          />

          {activeRole === "owner" && (
            <>
              <div className="my-4 border-t border-gray-700" />

              <DrawerMenuItem
                icon="settings"
                title="Impostazioni Lega"
                subtitle="Gestione regole e configurazione"
                onClick={() => goTo("#")}
              />
            </>
          )}

          <div className="my-4 border-t border-gray-700" />

          <DrawerMenuItem
            icon="help"
            title="Supporto"
            subtitle="Aiuto e informazioni"
            onClick={() => goTo("#")}
          />

          <DrawerMenuItem
            icon="logout"
            title="Esci da FantaGol"
            subtitle="Logout account"
            danger
            onClick={logout}
          />
        </nav>
      </aside>
    </div>
  );
}
