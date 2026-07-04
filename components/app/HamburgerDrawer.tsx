"use client";

import { useEffect, useState } from "react";
import { supabase } from "../../lib/supabaseClient";

type HamburgerDrawerProps = {
  open: boolean;
  leagueName: string;
  displayName: string;
  inviteCode: string;
  role: string;
  onClose: () => void;
};

type DrawerLeagueData = {
  leagueName: string;
  displayName: string;
  inviteCode: string;
  role: string;
};

export default function HamburgerDrawer({
  open,
  leagueName,
  displayName,
  inviteCode,
  role,
  onClose,
}: HamburgerDrawerProps) {
  const [drawerLeague, setDrawerLeague] = useState<DrawerLeagueData>({
    leagueName,
    displayName,
    inviteCode,
    role,
  });

  useEffect(() => {
    setDrawerLeague({
      leagueName,
      displayName,
      inviteCode,
      role,
    });
  }, [leagueName, displayName, inviteCode, role]);

  useEffect(() => {
    if (!open) return;

    async function loadCurrentLeague() {
      const leagueId = getCurrentLeagueIdFromPath();
      if (!leagueId) return;

      const { data, error } = await supabase.rpc("get_my_leagues_rpc");
      if (error) return;

      const current = (data || []).find((row: any) => row.league_id === leagueId);
      if (!current) return;

      setDrawerLeague({
        leagueName: current.league_name || leagueName,
        displayName: current.display_name || displayName,
        inviteCode: current.invite_code || inviteCode,
        role: current.role || role,
      });
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
    onClose();
    window.location.href = path;
  }

  function getCurrentLeagueIdFromPath() {
    const match = window.location.pathname.match(/\/leghe\/([^\/]+)/);
    return match?.[1] || "";
  }

  function getLeagueDashboardPath() {
    const leagueId = getCurrentLeagueIdFromPath();
    return leagueId ? `/leghe/${leagueId}` : "/leghe";
  }

  const activeLeagueName = drawerLeague.leagueName || leagueName;
  const activeDisplayName = drawerLeague.displayName || displayName;
  const activeRole = drawerLeague.role || role;

  return (
    <div className="fixed inset-0 z-[100] flex justify-end bg-black/70">
      <aside className="flex h-full w-[65vw] max-w-[360px] flex-col bg-[#111417] shadow-2xl shadow-black/80">
        <div className="border-b border-gray-800 p-6">
          <button
            type="button"
            onClick={onClose}
            className="mb-6 rounded-xl border border-gray-700 px-3 py-2"
          >
            ✕
          </button>

          <h2 className="text-2xl font-black text-[#A6E824]">
            {activeLeagueName}
          </h2>

          <p className="mt-1 text-sm text-gray-400">
            Nome nella lega: {activeDisplayName}
          </p>

          <button
            type="button"
            onClick={() => goTo(getLeagueDashboardPath())}
            className="mt-5 w-full rounded-2xl bg-[#A6E824] px-4 py-3 text-left text-base font-black text-black shadow-lg shadow-[#A6E824]/20 transition hover:brightness-110"
          >
            👥 La mia Lega
          </button>
        </div>

        <nav className="flex-1 space-y-4 overflow-y-auto p-6 text-lg">
          <button onClick={() => goTo("/leghe")} className="block text-left">
            🔄 Cambia lega
          </button>

          <button onClick={() => goTo("/crea-lega")} className="block text-left">
            ➕ Crea nuova lega
          </button>

          <button
            type="button"
            onClick={copyInviteLink}
            className="block text-left"
          >
            📨 Copia link invito
          </button>

          <div className="my-5 border-t border-gray-700" />

          <button onClick={() => goTo("#")} className="block text-left">
            🎯 Pronostici
          </button>

          <button onClick={() => goTo("#")} className="block text-left">
            ⚽ Live
          </button>

          <button onClick={() => goTo("#")} className="block text-left">
            🏆 Classifiche
          </button>

          <button onClick={() => goTo("#")} className="block text-left">
            📅 Calendario
          </button>

          <div className="my-5 border-t border-gray-700" />

          <button onClick={() => goTo("/club")} className="block text-left">
            🏟 Il Mio Club
          </button>

          <button onClick={() => goTo("#")} className="block text-left">
            🏛 Hall of Fame
          </button>

          {activeRole === "owner" && (
            <>
              <div className="my-5 border-t border-gray-700" />

              <button onClick={() => goTo("#")} className="block text-left">
                ⚙️ Impostazioni Lega
              </button>
            </>
          )}

          <div className="my-5 border-t border-gray-700" />

          <button onClick={() => goTo("#")} className="block text-left">
            ❓ Supporto
          </button>

          <button
            type="button"
            onClick={logout}
            className="block text-left text-red-400"
          >
            🚪 Esci da FantaGol
          </button>
        </nav>
      </aside>
    </div>
  );
}
