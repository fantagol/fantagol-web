"use client";

import { useEffect, useState } from "react";
import { usePathname } from "next/navigation";
import FantaGolLogo from "../../components/FantaGolLogo";
import HamburgerDrawer from "../../components/app/HamburgerDrawer";
import { supabase } from "../../lib/supabaseClient";

type LeagueShellInfo = {
  leagueName: string;
  displayName: string;
  inviteCode: string;
  role: string;
};

export default function LegheLayout({
  children,
}: {
  children: React.ReactNode;
}) {
  const pathname = usePathname();
  const [menuOpen, setMenuOpen] = useState(false);
  const [leagueInfo, setLeagueInfo] = useState<LeagueShellInfo>({
    leagueName: "FantaGol",
    displayName: "Club FantaGol",
    inviteCode: "",
    role: "member",
  });

  useEffect(() => {
    async function loadLeagueInfo() {
      const match = pathname.match(/\/leghe\/([^\/]+)/);
      const leagueId = match?.[1];

      if (!leagueId || leagueId === "fantagol-serie-a") return;

      const { data, error } = await supabase.rpc("get_my_leagues_rpc");
      if (error) return;

      const current = (data || []).find((row: any) => row.league_id === leagueId);
      if (!current) return;

      setLeagueInfo({
        leagueName: current.league_name || "Lega FantaGol",
        displayName: current.display_name || "Club FantaGol",
        inviteCode: current.invite_code || leagueId,
        role: current.role || "member",
      });
    }

    loadLeagueInfo();
  }, [pathname]);

  return (
    <>
      <header className="fixed inset-x-0 top-0 z-[80] border-b border-[#A6E824]/25 bg-[#1f2427] shadow-2xl shadow-black/80">
        <div className="mx-auto flex h-14 max-w-6xl items-center justify-between px-4 md:px-6">
          <a
                        className="pointer-events-none relative z-0 block -translate-x-8 translate-y-5 md:-translate-x-20 md:translate-y-6"
          >
            <FantaGolLogo />
          </a>

          <button
            type="button"
            onClick={() => setMenuOpen(true)}
            aria-label="Apri menu lega"
            className="rounded-lg border border-gray-600 bg-[#2b2f31] px-3 py-2 text-2xl leading-none text-white transition hover:border-[#A6E824]"
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

      <div className="pt-14">
        {children}
      </div>
    </>
  );
}

